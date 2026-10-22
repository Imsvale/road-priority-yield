-- Console utility (CHANGES THE SAVE when FIX is true): find street nodes whose stored traffic
-- light type no longer exists, and give them a valid one.
-- Paste into the in-game console (it has no dofile). Output goes to the game log (stdout.txt),
-- lines starting with "[rescue]".
--
-- Why: a node keeps its light type as an index into the game's light type list
-- (BASE_NODE_CONFIG.trafficLightConfig.trafficLightType), with or without a light. When a mod
-- that added a light type is removed (Road Priority & Yield without running Uninstall first),
-- the index points past the end of the list, and the game crashes the next time it rebuilds that
-- node, e.g. on a road upgrade there (2026-10-20). Removing the light doesn't help: the index
-- stays (Traffic Light Tools' Remove all sets the preference to NO and leaves the type as is).
--
-- What it does, per stale node: the light's phases are emptied, the type set to -1 (the game's default)
-- and, where a light is on, the preference to AUTO (the game decides whether it gets a light;
-- where it's off, the player's preference stays), sent as a traffic light proposal, the same
-- change the Priority Road tool's Uninstall makes. Lanes are left as they are.
--
-- Use:
--   1. Paste as is (FIX = false): it only lists the stale nodes.
--   2. Set FIX = true. LIMIT = 1 fixes one node first: if the game rejects or crashes on it, the
--      rest are untouched. Then raise LIMIT (or set it to nil for all).

local FIX = false
local LIMIT = 1

print("[rescue] Stale traffic light types: " .. (FIX and "fixing" or "listing only"))

local CT = api.type.ComponentType
local rep = api.res.trafficLightTypeRep

-- The light types that exist now, by index, with their names.
local valid, names, count = {}, {}, 0
local ok, err = pcall(function()
	for id, name in pairs(rep.getAll(true)) do
		valid[id] = true
		names[id] = tostring(name)
		count = count + 1
	end
end)
if not ok then print("[rescue] reading the light types failed: " .. tostring(err)) end
print("[rescue] light types: " .. count)
for id, name in pairs(names) do print("[rescue]   " .. id .. ": " .. name) end

-- The replacement: -1, the game's "no type chosen" (its own managed lights and junctions without
-- a light have it), as the tool gives every light it takes off since priority road 65. -1 isn't
-- in the type list, but it isn't stale either.
local base = -1
print("[rescue] replacement type: -1 (the game's default)")

-- The stale nodes.
local stale = {}
ok, err = pcall(function()
	for node in pairs(api.engine.system.streetSystem.getNode2SegmentMap()) do
		local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
		local t = cfg and cfg.trafficLightConfig.trafficLightType
		if t ~= nil and t ~= -1 and not valid[t] then
			local lit = api.engine.getComponent(node, CT.BASE_NODE_TRAFFIC_LIGHT) ~= nil
			stale[#stale + 1] = { node = node, cfg = cfg, type = t, lit = lit }
		end
	end
end)
if not ok then print("[rescue] scanning the nodes failed: " .. tostring(err)) end
print("[rescue] stale nodes: " .. #stale)
for _, x in ipairs(stale) do
	print(string.format("[rescue]   node %d: type %d, %s, preference %s", x.node, x.type,
		x.lit and "light" or "no light", tostring(x.cfg.trafficLightPreference)))
end

-- The fix.
if FIX then
	local sent = 0
	for _, x in ipairs(stale) do
		if LIMIT and sent >= LIMIT then break end
		local sOk, sErr = pcall(function()
			local tl = x.cfg.trafficLightConfig:clone()
			tl.states = {}
			tl.trafficLightType = base
			-- AUTO where a light is on; where it's off, the player's choice stays
			local proposal = api.engine.util.proposal.createTrafficLightProposal(x.node, tl,
				x.lit and api.type.enum.TrafficLightPreference.AUTO or x.cfg.trafficLightPreference)
			api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true), function(_, success)
				local now = api.engine.getComponent(x.node, CT.BASE_NODE_CONFIG)
				print(string.format("[rescue] node %d: %s, type now %s", x.node, success and "fixed" or "REJECTED",
					tostring(now and now.trafficLightConfig.trafficLightType)))
			end)
		end)
		if sOk then sent = sent + 1 else print("[rescue] node " .. x.node .. ": " .. tostring(sErr)) end
	end
	print("[rescue] sent: " .. sent .. " of " .. #stale)
end
