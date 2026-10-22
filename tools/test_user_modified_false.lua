-- Console utility (CHANGES THE SAVE when SET is true): rewrite one node's config unchanged except
-- BASE_NODE_CONFIG.userModifiedTrafficLightStates = FLAG, then read it back; with SET false, only
-- read. Paste into the in-game console (it has no dofile). Output goes to the game log
-- (stdout.txt), lines starting with "[flagtest]".
--
-- Why (2026-10-22): our own light proposals set userModifiedTrafficLightStates true, so it can't
-- tell the player's phase edits from ours. Writing it false ourselves would make it usable, if the
-- game then leaves our phases alone. To find out, set it false on a junction with our phases and
-- watch what the game does: does the flag stay false (read again later), do the phases survive a
-- save reload, a lane edit, a road edit next to it, the player opening and editing the phases
-- (does the flag turn true)?
--
-- The write is a street proposal replacing the node config (nodeConfigsToAdd / ToRemove), as the
-- Priority Road tool's sendNodeConfig does, with everything else copied from the current config.

local NODE = 2712 -- the junction to test
local SET = true  -- false: read only
local FLAG = false

local CT = api.type.ComponentType
local function report(when)
	pcall(function()
		local cfg = api.engine.getComponent(NODE, CT.BASE_NODE_CONFIG)
		local tl = cfg.trafficLightConfig
		local parts = {}
		for p, st in ipairs(tl.states) do
			local locked = {}
			for _, l in ipairs(st.lockedLanes) do locked[#locked + 1] = tostring(l) end
			parts[#parts + 1] = string.format("#%d %gs locked %s", p, st.duration, table.concat(locked, " "))
		end
		print(string.format("[flagtest] node %d %s: userModifiedTrafficLightStates %s, preference %s, type %s, light %s, %d phases: %s",
			NODE, when, tostring(cfg.userModifiedTrafficLightStates), tostring(cfg.trafficLightPreference),
			tostring(tl.trafficLightType), tostring(api.engine.getComponent(NODE, CT.BASE_NODE_TRAFFIC_LIGHT) ~= nil),
			#tl.states, table.concat(parts, "; ")))
	end)
end

report(SET and "before" or "now")

if SET then
	local ok, err = pcall(function()
		local cfg = api.engine.getComponent(NODE, CT.BASE_NODE_CONFIG)
		local nc = api.type.BaseNodeLaneConnectionAndEntity.new()
		nc.entity = NODE
		local comp = nc.comp
		comp.laneConnections = cfg.laneConnections
		comp.crosswalks = cfg.crosswalks
		comp.trafficLightPreference = cfg.trafficLightPreference
		comp.doubleSlipSwitch = cfg.doubleSlipSwitch
		comp.trafficLightConfig = cfg.trafficLightConfig
		comp.userModifiedTrafficLightStates = FLAG
		nc.comp = comp
		local proposal = api.type.SimpleProposal.new()
		proposal.streetProposal.nodeConfigsToAdd = { nc }
		proposal.streetProposal.nodeConfigsToRemove = { NODE }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true), function(_, success)
			print("[flagtest] proposal " .. (success and "applied" or "refused"))
			report("after")
		end)
	end)
	if not ok then print("[flagtest] failed: " .. tostring(err)) end
end
