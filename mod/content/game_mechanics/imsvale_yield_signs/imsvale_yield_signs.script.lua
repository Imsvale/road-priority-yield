-- The Priority Road tool's memory, in the game script's state (saved with the game).
--
-- Signs: which sign assets the tool placed at which junction. The signs are built as
-- constructions but become plain assets (ASSET_GROUP) once built, and asset groups can't be
-- looped over, so the tool keeps their ids here to remove them again (2026-10-18).
--
-- Junctions and "Follow lane edits" (experimental, 2026-10-19): every junction the tool applied
-- yielding to, with its priority road segments, kind, light type and a fingerprint of its lane
-- connections. With the tool's switch on, every CHECK_EVERY seconds the junctions' lanes are
-- compared with the fingerprint; a change that stays the same over two checks in a row (the edit
-- has settled) rebuilds the phases from the new lanes with the same plan (phases module), lanes
-- untouched. Phase edits alone don't trigger it. A junction drops out when its node or priority
-- segments are gone, its light was removed or switched to another type, or no side road leads in.
--
-- State: {
--   signs = { ["<node>"] = { ids = { asset ids }, style = "intl" | "no", round = bool } },
--   diamonds = { ["<node>"] = { asset ids } }: priority signs along a priority road, under the
--     junction they follow or the road end they start at (2026-10-19),
--   junctions = { ["<node>"] = { a, b, round, typeId, fp, pending } },
--   follow = bool, nextCheck = seconds, t = seconds,
-- }
-- (before 2026-10-18 evening a sign entry was the bare id list; the tool reads both).
--
-- The tool (GUI) writes with api.cmd.makeScriptingSendEventCmd(GAME_SCRIPT, EVENT_ID, SIGNS_EVENT, param)
-- (script-doc cmd.md: broadcast to all subscribed scripts, `src` naming the game script it
-- pretends to come from), param.kind saying what it is:
-- - nil (signs) { node, signs = { ... }, style, round }: an empty list clears the entry;
-- - "diamonds" { node, ids = { ... } }: an empty list clears the entry;
-- - "junction" { node, a, b, round, typeId, fp } or { node, remove = true };
-- - "follow" { on = bool };
-- - "diamondSettings" { values = { start, startHalf, repeatAt, jitter, minGap } }: the priority
--   sign settings, per save.
-- One event for all: a save keeps the subscriptions it was saved with (GameScript.eventSubscriptions
-- is part of the component), and this script only subscribes when it has none, so an event added
-- in a later version never arrived in an older save (priority signs weren't stored, 2026-10-19).
-- It reads the state back with api.engine.system.gameScriptSystem.getEntityForGameScript(GAME_SCRIPT)
-- and that entity's GAME_SCRIPT component, field `state` (script-doc engine/system.md, engine.md).
--
-- Subscribing: as the base game's own scripts do (e.g. game_mechanics/arrival_tracker), in
-- update whenever state:hasEventSubscriptions() is false. Subscriptions are the engine's
-- (GameScript.eventSubscriptions), not part of the saved state, so a "subscribed" flag in the
-- state could outlive them across a savegame load and never subscribe again.
--
-- Sending commands from here: without a callback (callbacks are disallowed in the engine state).

-- Loaded under pcall: if it fails, following is off but the signs still work.
local phasesOk, phases = pcall(ug_require, "/scripts/imsvale_yield_phases.lua")

local EVENT_ID = "imsvale_road_priority_yield"
local SIGNS_EVENT = "imsvale_yield_signs.set"
local CHECK_EVERY = 3.0 -- game seconds between lane checks

local CT = api.type.ComponentType

local function log(fmt, ...)
	local args = { ... }
	pcall(function() print("[yield] " .. string.format(fmt, (table.unpack or unpack)(args))) end)
end

-- Why a registered junction can't be followed any more, or nil.
local function gone(node, j)
	if not api.engine.entityExists(node) then return "node gone" end
	local segs = {}
	for _, seg in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(node)) do segs[seg] = true end
	if not segs[j.a] or not segs[j.b] then return "priority road rebuilt" end
	local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
	if not cfg or not api.engine.getComponent(node, CT.BASE_NODE_TRAFFIC_LIGHT) then return "light removed" end
	if j.typeId ~= nil and cfg.trafficLightConfig.trafficLightType ~= j.typeId then return "light type changed" end
	return nil
end

local function rebuild(node, j)
	local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
	local states, why = phases.junctionStates(node, j.a, j.b, cfg, j.round)
	if not states then return why end
	local tl = cfg.trafficLightConfig:clone()
	tl.states = states
	local proposal = api.engine.util.proposal.createTrafficLightProposal(node, tl, api.type.enum.TrafficLightPreference.YES)
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true))
	return nil
end

local function follow(s)
	for key, j in pairs(s.junctions or {}) do
		local node = tonumber(key)
		local why = "bad entry"
		if node then why = gone(node, j) end
		if why then
			log("follow lane edits: node %s dropped (%s)", key, why)
			s.junctions[key] = nil
		else
			local fp = phases.fingerprint(api.engine.getComponent(node, CT.BASE_NODE_CONFIG))
			if fp == j.fp then
				j.pending = nil
			elseif fp ~= j.pending then
				j.pending = fp -- changed: wait one more check for the edit to settle
			else
				local failed = rebuild(node, j)
				if failed then
					log("follow lane edits: node %d dropped (%s)", node, failed)
					s.junctions[key] = nil
				else
					j.fp, j.pending = fp, nil
					log("follow lane edits: node %d phases rebuilt for its new lanes", node)
				end
			end
		end
	end
end

local function update(_userParams, state, dt)
	if not state:hasEventSubscriptions() then
		state:subscribeToEvent(SIGNS_EVENT)
	end
	if dt <= 0 then return end
	local s = state:get() or {}
	if not s.follow then return end
	if not phasesOk then
		if s.lastError ~= "module" then log("follow lane edits: phases module failed to load: %s", tostring(phases)) end
		s.lastError = "module"
		state:set(s)
		return
	end
	s.t = (s.t or 0) + dt
	if s.t < (s.nextCheck or 0) then
		state:set(s)
		return
	end
	s.nextCheck = s.t + CHECK_EVERY
	local ok, err = pcall(follow, s)
	if not ok and tostring(err) ~= s.lastError then log("follow lane edits failed: %s", tostring(err)) end
	s.lastError = not ok and tostring(err) or nil
	state:set(s)
end

local function handleEvent(_userParams, state, _src, id, name, param)
	if id ~= EVENT_ID or name ~= SIGNS_EVENT or type(param) ~= "table" then return end
	local s = state:get() or {}
	local kind = param.kind
	if kind == nil and param.node ~= nil then
		s.signs = s.signs or {}
		local key = tostring(param.node)
		local signs = {}
		for _, e in ipairs(param.signs or {}) do signs[#signs + 1] = e end
		s.signs[key] = #signs > 0 and { ids = signs, style = param.style, round = param.round or false } or nil
		log("signs at node %s: %d (%s%s)", key, #signs, tostring(param.style), param.round and ", roundabout" or "")
	elseif kind == "diamonds" and param.node ~= nil then
		s.diamonds = s.diamonds or {}
		local ids = {}
		for _, e in ipairs(param.ids or {}) do ids[#ids + 1] = e end
		s.diamonds[tostring(param.node)] = #ids > 0 and ids or nil
		log("priority signs at node %s: %d", tostring(param.node), #ids)
	elseif kind == "junction" and param.node ~= nil then
		s.junctions = s.junctions or {}
		local key = tostring(param.node)
		if param.remove then
			s.junctions[key] = nil
		else
			s.junctions[key] = { a = param.a, b = param.b, round = param.round or false, typeId = param.typeId, fp = param.fp }
		end
	elseif kind == "diamondSettings" and type(param.values) == "table" then
		local v = {}
		for k, x in pairs(param.values) do
			if type(x) == "number" then v[k] = x end
		end
		s.diamondSettings = v
	elseif kind == "follow" then
		local on = param.on == true
		if on ~= (s.follow == true) then log("follow lane edits: %s", on and "on" or "off") end
		s.follow = on
	else
		return
	end
	state:set(s)
end

function data()
	return { update = update, handleEvent = handleEvent }
end
