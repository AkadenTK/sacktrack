_addon.name = 'sacktrack'

_addon.author = 'Akaden, Zohno'

_addon.version = '0.9'

_addon.commands = {'inv','sacktrack','track'}


require('tables')
require('sets')
require('lists')
require('logger')
require('functions')
texts = require('texts')
config = require('config')
res = require('resources')
require('pack')

defaults = {
	base_text = {
		bg={alpha=128,red=0,green=0,blue=0,},
		flags={bold=false,bottom=false,draggable=true,italic=false,right=false},
		padding=2,
		pos={x=0,y=0},
		text={
			alpha=255,red=255,green=255,blue=255,
			font='Lucida Console',size=9, 
			stroke={alpha=128,red=0,green=0,blue=0,width=0},
		},
	},
	windows = {
		['default'] = {
			settings={pos={x=0,y=0},},
			text="<![CDATA[Inventory: ${inventory:$freespace}]]>",
		}
	},
	workspaces = {
		['default'] = 'default,',
	},
	autoload_job = true,
	autoload_zone = true,
}

settings = config.load(defaults)

trackers = T{}
al_trackers = T{}

variable_cache = T{}

bag_ids = res.bags:rekey('english'):key_map(string.lower):map(table.get-{'id'})

done_zoning            = windower.ffxi.get_info().logged_in

function update_variable_cache(tracker, tracker_name)
	variable_cache[tracker_name] = S{}
    for variable in tracker:it() do
        local bag_name, search = variable:match('(.*):(.*)')

        local bag = bag_name == 'all' and 'all' or bag_ids[bag_name:lower()]
        if not bag and bag_name ~= 'all' then
            warning('Unknown bag: %s':format(bag_name))
        else
            if not S{'$freespace', '$usedspace', '$maxspace'}:contains(search:lower()) then
                local items = S(res.items:name(windower.wc_match-{search})) + S(res.items:name_log(windower.wc_match-{search}))
                if items:empty() then
                    warning('No items matching "%s" found.':format(search))
                else
                    variable_cache[tracker_name]:add({
                        name = variable,
                        bag = bag,
                        type = 'item',
                        ids = items:map(table.get-{'id'}),
                        search = search,
                    })
                end
            else
                variable_cache[tracker_name]:add({
                    name = variable,
                    bag = bag,
                    type = 'info',
                    search = search,
                })
            end
        end
    end
end

function search_bag(bag, ids)
    return bag:filter(function(item)
        return type(item) == 'table' and ids:contains(item.id)
    end):reduce(function(acc, item)
        return type(item) == 'table' and item.count + acc or acc
    end, 0)
end

function update_item_cache()
    local update = T{}

    local items = T{}

    for name, tracker in pairs(trackers) do
	    for variable in variable_cache[name]:it() do
	        if variable.type == 'info' then
	            local info
	            if variable.bag == 'all' then
	                info = {
	                    max = 0,
	                    count = 0
	                }
	                for bag_info in T(windower.ffxi.get_bag_info()):it() do
	                    info.max = info.max + bag_info.max
	                    info.count = info.count + bag_info.count
	                end
	            else
	                info = windower.ffxi.get_bag_info(variable.bag)
	            end

	            update[variable.name] =
	                variable.search == '$freespace' and (info.max - info.count)
	                or variable.search == '$usedspace' and info.count
	                or variable.search == '$maxspace' and info.max
	                or nil
	        elseif variable.type == 'item' then
	            if variable.bag == 'all' then
	                for id in bag_ids:it() do
	                    if not items[id] then
	                        items[id] = T(windower.ffxi.get_items(id))
	                    end
	                end
	            else
	                if not items[variable.bag] then
	                    items[variable.bag] = T(windower.ffxi.get_items(variable.bag))
	                end
	            end

	            update[variable.name] = variable.bag ~= 'all' and search_bag(items[variable.bag], variable.ids) or items:reduce(function(acc, bag)
	                return acc + search_bag(bag, variable.ids)
	            end, 0)
	        end
	    end

	    if not update:empty() then
	        tracker:update(update)
	    end
	end
end

function deep_copy(from, to)
	for k, v in pairs(from) do
		if type(v) == 'table' then
			to[k] = T{}
			deep_copy(v, to[k])
		else
			to[k] = v
		end
	end
end

function combine_settings(t1, t2)
	local n = T{}
	
	deep_copy(t1, n)
	deep_copy(t2, n)

	return n
end

function load_tracker(name)
	local s = settings.windows[name]
	if not s then 
		log('Tracker not found! ("'..name..'")')
		return false
	end
	local tracker = texts.new(s.text, combine_settings(settings.base_text, s.settings))
	if trackers[name] then
		trackers[name]:hide()
	end
	update_variable_cache(tracker, name)
	update_item_cache()
	tracker:show()
	trackers[name] = tracker
	return true
end

function load_workspace(name)
	local windows = settings.workspaces[name]:split(',')
	for _,w in ipairs(windows) do
		load_tracker(w)
	end
end

function clear_trackers(tracker_name)
	if tracker_name then
		if trackers[tracker_name] then
			trackers[tracker_name]:hide()
			trackers[tracker_name] = nil
		end
	else
		for name, tracker in pairs(trackers) do
			tracker:hide()
			trackers[name] = nil
		end
	end
end

function update_trackers()
	local pos_changed = false
	for name, tracker in pairs(trackers) do
		tracker:update(item_cache)
		local x, y = tracker:pos()
		if x ~= settings.windows[name].settings.pos.x or y ~= settings.windows[name].settings.pos.y then
			settings.windows[name].settings.pos.x = x
			settings.windows[name].settings.pos.y = y
			pos_changed = true
		end
	end
	if pos_changed then
		settings:save()
	end
end

function get_fuzzy(name)
	if not name then return name end
	if type(name) ~= 'string' then
		print(debug.traceback())
	end
	return name:lower():gsub("%s", ""):gsub("%p", "")
end

function autoload_trackers(auto_names)
	local auto_loaded = T{}
	local announce_windows = T{}

	local best_name = nil
	for name, workspace in pairs(settings.workspaces) do
		local l_name = name:lower()
		if auto_names:contains(l_name) and (not best_name or name:len() > best_name:len()) then
			best_name = name
		end
	end
	for name, tracker in pairs(settings.windows) do
		local l_name = name:lower()
		if auto_names:contains(l_name) and (not best_name or name:len() > best_name:len()) then
			best_name = name
		end
	end	

	if best_name then
		if settings.workspaces[best_name] then
			local windows = settings.workspaces[best_name]:split(',')
			for _,w in ipairs(windows) do
				if w then
					if not trackers[best_name] then
						announce_windows:append(best_name)
					end
					if load_tracker(w) then
						al_trackers:append(w)
						auto_loaded:append(w)
					end
				end
			end
		elseif settings.windows[best_name] then
			if not trackers[best_name] then
				announce_windows:append(best_name)
			end
			if load_tracker(best_name) then
				al_trackers:append(best_name)
				auto_loaded:append(best_name)
			end
		end	
	end

	return auto_loaded, announce_windows
end

function check_autoload()
	local auto_loaded = T{}
	local announce_windows = T{}

	-- load a default workspace or window
	local al, aw = autoload_trackers(S{'default'})
	auto_loaded:extend(al)
	announce_windows:extend(aw)

	if settings.autoload_job then
		local player = windower.ffxi.get_player()
		local auto_names = S{player.name:lower()..'_'..player.main_job:lower()..'_'..player.sub_job:lower(), 
							 player.name:lower()..'_'..player.main_job:lower(), 
							 player.main_job:lower()}

		local al, aw = autoload_trackers(auto_names)
		auto_loaded:extend(al)
		announce_windows:extend(aw)
	end

	if settings.autoload_zone then
		local info = windower.ffxi.get_info()
		local fuzzy_zone = get_fuzzy(res.zones[info.zone].en)

		local al, aw = autoload_trackers(S{fuzzy_zone})
		auto_loaded:extend(al)
		announce_windows:extend(aw)
	end

	for i,name in ipairs(al_trackers) do
		if not auto_loaded:contains(name) then
			clear_trackers(name)
			al_trackers:remove(i)
		end
	end
	if not announce_windows:empty() then
		log('Auto-loaded: '..announce_windows:concat(', '))
	end
end

windower.register_event('load', function(...)
	if windower.ffxi.get_player() then
		check_autoload()
		update_item_cache()
	end
end)
windower.register_event('login', function(...)
	check_autoload()
	update_item_cache()
end)
windower.register_event('zone change', function(...)
	check_autoload()
end)
windower.register_event('job change', function(...)
	check_autoload()
end)

windower.register_event('addon command', function(...)

    local args = T{...}
    local cmd = args[1]
	args:remove(1)

	if S{'load','l'}:contains(cmd) then
		if load_tracker(args[1]) then
			log('Loaded window: '..args[1])
		end
	elseif S{'clear','close','c'}:contains(cmd) then
		if args[1] then
			clear_trackers(args[1])
			log('Closed window: '..args[1])
		else
			clear_trackers()
			log('Cleared workspace.')
		end
	elseif S{'open','o'}:contains(cmd) then
		if settings.workspaces[args[1]] then
			if load_workspace(args[1]) then
				log('Opened workspace: '..args[1])
			else
				log('Could not find workspace: '..args[1])
			end
		end
	end
end)

local last_check = 0

windower.register_event('prerender', function()
    if os.clock() - last_check < 0.25 then
        return
    end
    last_check = os.clock()
    update_item_cache()
    update_trackers()
end)

