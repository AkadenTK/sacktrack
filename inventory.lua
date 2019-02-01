_addon.name = 'inventory'

_addon.author = 'Akaden'

_addon.version = '0.9'

_addon.command = 'inv'


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
		['welcome'] = {
			settings={pos={x=150,y=150},},
			text="Welcome! See the settings file for configuration."
		}
	},
	workspaces = {
		['default'] = 'welcome,',
	},
	bags = 'inventory,wardrobe,wardrobe2,wardrobe3,wardrobe4,satchel'
}

settings = config.load(defaults)

trackers = {}

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

function load_new_tracker(name)
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

windower.register_event('prerender', function()
    update_trackers()
end)

windower.register_event('load', function(...)
	if windower.ffxi.get_player() then
		update_item_cache()
	end
end)
windower.register_event('login', function(...)
	update_item_cache()
end)

windower.register_event('addon command', function(...)

    local args = T{...}
    local cmd = args[1]
	args:remove(1)

	if S{'load','l'}:contains(cmd) then
		if load_new_tracker(args[1]) then
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
			local windows = settings.workspaces[args[1]]:split(',')
			for _,w in ipairs(windows) do
				load_new_tracker(w)
			end
			log('Opened workspace: '..args[1])
		end
	end
end)

local inventory_changed_packets = S{0x1d,0xd2,0xd3,0x1c,0x1e,0x1f,0x20,0x23,0x25,0x26}
--windower.register_event('incoming chunk',function(id,org,_modi,_is_injected,_is_blocked)
--    if inventory_changed_packets:contains(id) then
--        update_item_cache()
--        update_trackers()
--    end
--end)
windower.register_event('incoming chunk', function(id,original,modified,injected,blocked)
    local seq = original:unpack('H',3)
	if (next_sequence and seq == next_sequence) and done_zoning then
		update_item_cache()
		update_trackers()
        next_sequence = nil
	end

	if id == 0x00B then -- Last packet of an old zone
        done_zoning = false
    elseif id == 0x00A then -- First packet of a new zone, redundant because someone could theoretically load findAll between the two
		done_zoning = false
	elseif id == 0x01D and not done_zoning then
	-- This packet indicates that the temporary item structure should be copied over to
	-- the real item structure, accessed with get_items(). Thus we wait one packet and
	-- then trigger an update.
        done_zoning = true
		next_sequence = (seq+11)%0x10000 -- 128 packets is about 1 minute. 22 packets is about 10 seconds.
    elseif inventory_changed_packets:contains(id) and done_zoning then
    -- Inventory Finished packets aren't sent for trades and such, so this is more
    -- of a catch-all approach. There is a subtantial delay to avoid spam writing.
    -- The idea is that if you're getting a stream of incoming item packets (like you're gear swapping in an intense fight),
    -- then it will keep putting off triggering the update until you're not.
        next_sequence = (seq+11)%0x10000
	end
end)


local last_check = 0

windower.register_event('prerender', function()
    if os.clock() - last_check < 0.25 then
        return
    end
    last_check = os.clock()
    update_item_cache()
end)