--[[

	TechAge
	=======

	Copyright (C) 2019 Joachim Stolberg

	GPL v3
	See LICENSE.txt for more information
	
	TA4 Doser

]]--

local S2P = minetest.string_to_pos
local P2S = minetest.pos_to_string
local M = minetest.get_meta
local S = techage.S
local Pipe = techage.LiquidPipe
local networks = techage.networks
local liquid = techage.liquid
local recipes = techage.recipes

local Liquids = {}  -- {hash(pos) = {name = outdir},...}

local STANDBY_TICKS = 4
local COUNTDOWN_TICKS = 4
local CYCLE_TIME = 10

-- to mark the pump source and destinstion node
local DebugCache = {}

local function set_starter_name(pos, clicker)
	local key = minetest.hash_node_position(pos)
	DebugCache[key] = {starter = clicker:get_player_name(), count = 10}
end

local function get_starter_name(pos)
	local key = minetest.hash_node_position(pos)
	local def = DebugCache[key]
	if def then
		def.count = (def.count or 0) - 1
		if def.count > 0 then
			return def.starter
		end
		DebugCache[key] = nil
	end
end

local function formspec(self, pos, mem)
	return "size[8,7]"..
		default.gui_bg..
		default.gui_bg_img..
		default.gui_slots..
		recipes.formspec(0, 0, "ta4_doser", mem)..
		"image_button[6,1;1,1;".. self:get_state_button_image(mem) ..";state_button;]"..
		"tooltip[6,1;1,1;"..self:get_state_tooltip(mem).."]"..
		"list[current_player;main;0,3.3;8,4;]" ..
		default.get_hotbar_bg(0, 3.5)
end

local function get_liquids(pos)
	local hash = minetest.hash_node_position(pos)
	if Liquids[hash] then
		return Liquids[hash]
	end
	-- determine the available input liquids
	local tbl = {}
	for outdir = 1,4 do
		local name, num = liquid.peek(pos, outdir)
		if name then
			tbl[name] = outdir
		end
	end
	Liquids[hash] = tbl
	return Liquids[hash]
end
	
local function del_liquids(pos)
	local hash = minetest.hash_node_position(pos)
	Liquids[hash] = nil
end
	
local function reactor_cmnd(pos, cmnd, payload)
	return techage.transfer(
		pos, 
		6,  -- outdir
		cmnd,  -- topic
		payload,  -- payload
		Pipe,  -- network
		{"techage:ta4_reactor_fillerpipe"})
end


local function can_start(pos, mem, state)
	-- check reactor
	local res = reactor_cmnd(pos, "check")
	if not res then
		return S("reactor defect")
	end
	res = reactor_cmnd(pos, "can_start")
	if not res then
		return S("reactor defect or no power")
	end
	return true
end

local function start_node(pos, mem, state)
	reactor_cmnd(pos, "start")
	del_liquids(pos)
	mem.running = true
end

local function stop_node(pos, mem, state)
	reactor_cmnd(pos, "stop")
	mem.running = false
end

local State = techage.NodeStates:new({
	node_name_passive = "techage:ta4_doser",
	node_name_active = "techage:ta4_doser_on",
	cycle_time = CYCLE_TIME,
	standby_ticks = STANDBY_TICKS,
	formspec_func = formspec,
	infotext_name = "TA4 Doser",
	can_start = can_start,
	start_node = start_node,
	stop_node = stop_node,
})

local function dosing(pos, mem, elapsed)
	-- trigger reactor (power)
	if not reactor_cmnd(pos, "power") then
		if not mem.techage_countdown or mem.techage_countdown < 3 then
			reactor_cmnd(pos, "stop")
			State:nopower(pos, mem, S("reactor has no power"))
		end
		State:idle(pos, mem)
		return
	end
	-- check from time to time
	mem.check_cnt = (mem.check_cnt or 0) + 1
	if mem.check_cnt >= 4 then
		mem.check_cnt = 0
		local res = reactor_cmnd(pos, "check")
		if not res then
			State:fault(pos, mem, S("reactor defect"))
			reactor_cmnd(pos, "stop")
			return
		end
	end
	-- available liquids
	local liquids = get_liquids(pos)
	local recipe = recipes.get(mem, "ta4_doser")
	if not liquids or not recipe then return end
	-- inputs
	local starter = get_starter_name(pos)
	for _,item in pairs(recipe.input) do
		if item.name ~= "" then
			local outdir = liquids[item.name]
			if not outdir then
				State:standby(pos, mem)
				reactor_cmnd(pos, "stop")
				return
			end
			if liquid.take(pos, outdir, item.name, item.num, starter) < item.num then
				State:standby(pos, mem)
				reactor_cmnd(pos, "stop")
				return
			end
		end
	end
	-- output
	local leftover
	leftover = reactor_cmnd(pos, "output", {
			name = recipe.output.name, 
			amount = recipe.output.num})
	if not leftover or (tonumber(leftover) or 1) > 0 then
		State:blocked(pos, mem)
		reactor_cmnd(pos, "stop")
		return
	end
	if recipe.waste.name ~= "" then
		leftover = reactor_cmnd(pos, "waste", {
				name = recipe.waste.name, 
				amount = recipe.waste.num})
		if not leftover or (tonumber(leftover) or 1) > 0 then
			State:blocked(pos, mem)
			reactor_cmnd(pos, "stop")
			return
		end
	end
	State:keep_running(pos, mem, COUNTDOWN_TICKS)
end	

local function node_timer(pos, elapsed)
	local mem = tubelib2.get_mem(pos)
	dosing(pos, mem, elapsed)
	return State:is_active(mem)
end	

local function on_rightclick(pos)
	local mem = tubelib2.get_mem(pos)
	M(pos):set_string("formspec", formspec(State, pos, mem))
end

local function on_receive_fields(pos, formname, fields, player)
	if minetest.is_protected(pos, player:get_player_name()) then
		return
	end
	
	local mem = tubelib2.get_mem(pos)
	if not mem.running then	
		recipes.on_receive_fields(pos, formname, fields, player)
	end
	set_starter_name(pos, player)
	State:state_button_event(pos, mem, fields)
	M(pos):set_string("formspec", formspec(State, pos, mem))
end

local nworks = {
	pipe = {
		sides = techage.networks.AllSides, -- Pipe connection sides
		ntype = "pump",
	},
}


minetest.register_node("techage:ta4_doser", {
	description = S("TA4 Doser"),
	tiles = {
		-- up, down, right, left, back, front
		"techage_filling_ta4.png^techage_frame_ta4_top.png^techage_appl_hole_pipe.png",
		"techage_filling_ta4.png^techage_frame_ta4.png",
		"techage_filling_ta4.png^techage_frame_ta4.png^techage_appl_pump_up.png",
	},

	after_place_node = function(pos, placer)
		local meta = M(pos)
		local mem = tubelib2.init_mem(pos)
		local number = techage.add_node(pos, "techage:ta4_doser")
		meta:set_string("node_number", number)
		meta:set_string("owner", placer:get_player_name())
		meta:set_string("formspec", formspec(State, pos, mem))
		meta:set_string("infotext", S("TA4 Doser").." "..number)
		State:node_init(pos, mem, number)
		Pipe:after_place_node(pos)
	end,
	tubelib2_on_update2 = function(pos, dir, tlib2, node)
		liquid.update_network(pos, dir)
		del_liquids(pos)
	end,
	after_dig_node = function(pos, oldnode, oldmetadata, digger)
		techage.remove_node(pos)
		Pipe:after_dig_node(pos)
		tubelib2.del_mem(pos)
	end,
	on_receive_fields = on_receive_fields,
	on_rightclick = on_rightclick,
	on_timer = node_timer,
	networks = nworks,

	paramtype2 = "facedir",
	on_rotate = screwdriver.disallow,
	groups = {cracky=2},
	is_ground_content = false,
	sounds = default.node_sound_metal_defaults(),
})

minetest.register_node("techage:ta4_doser_on", {
	description = S("TA4 Doser"),
	tiles = {
		-- up, down, right, left, back, front
		"techage_filling_ta4.png^techage_frame_ta4_top.png^techage_appl_hole_pipe.png",
		"techage_filling_ta4.png^techage_frame_ta4.png",
		{
			image = "techage_filling8_ta4.png^techage_frame8_ta4.png^techage_appl_pump_up8.png",
			backface_culling = false,
			animation = {
				type = "vertical_frames",
				aspect_w = 32,
				aspect_h = 32,
				length = 2.0,
			},
		},
	},

	tubelib2_on_update2 = function(pos, dir, tlib2, node)
		liquid.update_network(pos)
		del_liquids(pos)
	end,
	on_receive_fields = on_receive_fields,
	on_rightclick = on_rightclick,
	on_timer = node_timer,
	networks = nworks,
	
	paramtype2 = "facedir",
	on_rotate = screwdriver.disallow,
	diggable = false,
	groups = {not_in_creative_inventory=1},
	is_ground_content = false,
	sounds = default.node_sound_metal_defaults(),
})

techage.register_node({"techage:ta4_doser", "techage:ta4_doser_on"}, {
	on_recv_message = function(pos, src, topic, payload)
		local resp = State:on_receive_message(pos, topic, payload)
		if resp then
			return resp
		else
			return "unsupported"
		end
	end,
	on_node_load = function(pos)
		State:on_node_load(pos)
	end,
})

Pipe:add_secondary_node_names({"techage:ta4_doser", "techage:ta4_doser_on"})


if minetest.global_exists("unified_inventory") then
	unified_inventory.register_craft_type("ta4_doser", {
		description = S("TA4 Reactor"),
		icon = 'techage_reactor_filler_plan.png',
		width = 2,
		height = 2,
	})
end

minetest.register_craft({
	output = "techage:ta4_doser",
	recipe = {
		{"", "techage:ta3_pipeS", ""},
		{"techage:ta3_pipeS", "techage:t4_pump", "techage:ta3_pipeS"},
		{"", "techage:ta4_wlanchip", ""},
	},
})