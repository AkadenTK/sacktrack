_addon.name = 'inventory'

_addon.author = 'Akaden'

_addon.version = '0.9'

_addon.command = 'inv'


require('tables')
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

item_cache = T{}

done_zoning            = windower.ffxi.get_info().logged_in

function update_item_cache()
	item_cache = T{}
	local bags = windower.ffxi.get_items()
	for _,key in ipairs(settings.bags:split(',')) do
		key = key:trim()
		if bags[key] then
			for slot, i in ipairs(bags[key]) do
				local item = res.items[i.id]
				if item then
					local item_key = key:lower()..':'..item.name:lower()
					item_cache[item_key] = item_cache[item_key] or 0
					item_cache[item_key] = item_cache[item_key] + i.count
				end
			end
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
	tracker:update(item_cache)
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