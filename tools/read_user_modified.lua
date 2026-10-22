-- Console utility (read-only): for every junction the Priority Road tool registered, print the
-- node's BASE_NODE_CONFIG flags userModifiedLaneConnections / userModifiedTrafficLightStates, its
-- phase count and light type. Optionally also one more node: set NODE.
-- Paste into the in-game console (it has no dofile). Output goes to the game log (stdout.txt),
-- lines starting with "[usermod]".
--
-- Why: to learn which actions set the flags (2026-10-22). Lane following rebuilds the phases
-- after a lane edit, which also reverts the player's own phase edits; the flag could tell them
-- apart, if our own light proposals don't set it as well.

local NODE = nil -- a node id to read as well, e.g. one never touched by the tool

local CT = api.type.ComponentType
local function flags(node)
	local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
	if not cfg then return "no BASE_NODE_CONFIG" end
	return string.format("lanes=%s phases=%s states=%d type=%s", tostring(cfg.userModifiedLaneConnections),
		tostring(cfg.userModifiedTrafficLightStates), #cfg.trafficLightConfig.states,
		tostring(cfg.trafficLightConfig.trafficLightType))
end

pcall(function()
	local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(
		"imsvale_road_priority_yield::/game_mechanics/imsvale_yield_signs/imsvale_yield_signs.gs")
	local state = entity and api.engine.getComponent(entity, CT.GAME_SCRIPT).state
	local n = 0
	for key, j in pairs(type(state) == "table" and state.junctions or {}) do
		n = n + 1
		local ok, msg = pcall(flags, tonumber(key))
		print(string.format("[usermod] junction %s: %s%s", key, ok and msg or ("error " .. tostring(msg)),
			(j.repair or j.gone or j.check) and " (marked for the tool)" or ""))
	end
	print("[usermod] " .. n .. " registered junctions")
end)

if NODE then
	local ok, msg = pcall(flags, NODE)
	print(string.format("[usermod] node %d: %s", NODE, ok and msg or ("error " .. tostring(msg))))
end
