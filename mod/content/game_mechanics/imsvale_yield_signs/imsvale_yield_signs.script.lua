-- Remembers which sign assets the Priority Road tool placed at which junction, in the game
-- script's state (saved with the game). The signs are built as constructions but become plain
-- assets (ASSET_GROUP) once built, and asset groups can't be looped over, so the tool keeps their
-- ids here to remove them again (2026-10-18).
--
-- State: { signs = { ["<node>"] = { ids = { asset ids }, style = "intl" | "no", round = bool } } }
-- (before 2026-10-18 evening an entry was the bare id list; the tool reads both).
--
-- The tool (GUI) writes with api.cmd.makeScriptingSendEventCmd(GAME_SCRIPT, EVENT_ID, EVENT_NAME,
-- { node = <node>, signs = { ... }, style = ..., round = ... }) (script-doc cmd.md: broadcast to all subscribed scripts,
-- `src` naming the game script it pretends to come from); an empty list clears the entry. It
-- reads the state back with api.engine.system.gameScriptSystem.getEntityForGameScript(GAME_SCRIPT)
-- and that entity's GAME_SCRIPT component, field `state` (script-doc engine/system.md, engine.md).
--
-- Subscribing: as the base game's own scripts do (e.g. game_mechanics/arrival_tracker), in
-- update whenever state:hasEventSubscriptions() is false. Subscriptions are the engine's
-- (GameScript.eventSubscriptions), not part of the saved state, so a "subscribed" flag in the
-- state could outlive them across a savegame load and never subscribe again.

local EVENT_ID = "imsvale_road_priority_yield"
local EVENT_NAME = "imsvale_yield_signs.set"

local function log(fmt, ...)
	local args = { ... }
	pcall(function() print("[yield] " .. string.format(fmt, (table.unpack or unpack)(args))) end)
end

local function update(_userParams, state, _dt)
	if not state:hasEventSubscriptions() then
		state:subscribeToEvent(EVENT_NAME)
	end
end

local function handleEvent(_userParams, state, _src, id, name, param)
	if id ~= EVENT_ID or name ~= EVENT_NAME or type(param) ~= "table" or param.node == nil then return end
	local s = state:get() or {}
	s.signs = s.signs or {}
	local key = tostring(param.node)
	local signs = {}
	for _, e in ipairs(param.signs or {}) do signs[#signs + 1] = e end
	s.signs[key] = #signs > 0 and { ids = signs, style = param.style, round = param.round or false } or nil
	state:set(s)
	log("signs at node %s: %d (%s%s)", key, #signs, tostring(param.style), param.round and ", roundabout" or "")
end

function data()
	return { update = update, handleEvent = handleEvent }
end
