-- Copy / Paste for the game's traffic light window (the junction's entity window).
--
-- Replaces the window's exported recipe, DoubleSlipSwitchContent (gui/entity_window/
-- double_slip_switch.tl), with a wrapper: on a junction it puts a Copy / Paste row above the
-- original content, which it renders unchanged through react.CallOriginalRecipe. Nothing of
-- the game's code is copied, so game updates to the window carry through.
--
-- Copy keeps the junction's phases (lockedLanes, duration, min duration, skipping), light type
-- and light preference, plus what's needed to map them: each road's direction and lane count,
-- the lane connections and the crosswalks.
--
-- Paste maps them onto the target junction:
-- - Roads are paired in the same circular order, choosing the rotation that turns them least
--   (so a junction with the same orientation maps road to road by compass direction). Paired
--   roads must have the same number of lanes.
-- - Lane connection lane numbers are node-relative, so a connection maps by its pair of roads
--   and its lane numbers. Every copied connection must exist at the target and the counts
--   must match, otherwise nothing is pasted (e.g. a junction with edited lanes onto a default one).
-- - Crosswalks map through their road if the crosswalk entity is one of the junction's roads,
--   otherwise by position in the list (logged).
-- Then it applies the phases with createTrafficLightProposal, as the window itself does.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local view_manager_util = ug_require "::/gui/entity_window/view_manager_util.tl"
local original = ug_require "::/gui/entity_window/double_slip_switch.tl"

local VERSION = "yield light copy 1 (from the Smart traffic lights lab, light copy 1)"
local CT = api.type.ComponentType
local EVENT = "imsvaleYieldLightClipboardChanged"

local function log(fmt, ...)
	local args = { ... }
	pcall(function()
		print("[yield] " .. string.format(fmt, (table.unpack or unpack)(args)))
	end)
end

-- GUI module state persists for the session: one clipboard shared by all light windows.
local clipboard = nil

---------------------------------------------------------------------------
-- Geometry: the junction's roads by direction
---------------------------------------------------------------------------

local function wrapAngle(a)
	while a > math.pi do a = a - 2 * math.pi end
	while a < -math.pi do a = a + 2 * math.pi end
	return a
end

-- The node's roads, sorted by the compass angle at which they leave the node.
local function describeRoads(node)
	local roads = {}
	for _, seg in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(node)) do
		local e = api.engine.getComponent(seg, CT.BASE_EDGE)
		local t = e.node0 == node and e.tangent0 or e.tangent1
		local sign = e.node0 == node and 1 or -1
		roads[#roads + 1] = {
			segment = seg,
			angle = (math.atan2 or math.atan)(sign * t.y, sign * t.x),
			lanes = #e.laneConfigs,
		}
	end
	table.sort(roads, function(a, b) return a.angle < b.angle end)
	return roads
end

-- Source road -> target road, from the circular rotation that turns the roads least.
local function mapRoads(src, tgt)
	if #src ~= #tgt then
		return nil, string.format("the junctions have %d and %d roads", #src, #tgt)
	end
	local n = #src
	local best, bestCost
	for r = 0, n - 1 do
		local cost = 0
		for i = 1, n do
			local j = (i - 1 + r) % n + 1
			if src[i].lanes ~= tgt[j].lanes then cost = nil break end
			cost = cost + math.abs(wrapAngle(tgt[j].angle - src[i].angle))
		end
		if cost and (not bestCost or cost < bestCost) then best, bestCost = r, cost end
	end
	if not best then return nil, "the roads' lane counts don't match" end
	local map = {}
	for i = 1, n do map[src[i].segment] = tgt[(i - 1 + best) % n + 1].segment end
	return map, math.deg(bestCost / n)
end

---------------------------------------------------------------------------
-- Copy and paste
---------------------------------------------------------------------------

local function connKey(seg0, lane0, seg1, lane1)
	return string.format("%d.%d>%d.%d", seg0, lane0, seg1, lane1)
end

local function copy(node)
	local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
	if not cfg then return nil, "this junction has no lane configuration" end
	local clip = {
		node = node,
		roads = describeRoads(node),
		conns = {},
		crosswalks = {},
		states = {},
		lightType = cfg.trafficLightConfig.trafficLightType,
		preference = cfg.trafficLightPreference,
	}
	for i, c in ipairs(cfg.laneConnections) do
		clip.conns[i] = { c.segment0, c.lane0, c.segment1, c.lane1 }
	end
	for i, x in ipairs(cfg.crosswalks) do clip.crosswalks[i] = x end
	for i, s in ipairs(cfg.trafficLightConfig.states) do
		local locked = {}
		for j, l in ipairs(s.lockedLanes) do locked[j] = l end
		clip.states[i] = { locked = locked, duration = s.duration, minDuration = s.minDuration, canSkip = s.canSkip }
	end
	return clip
end

-- Source lane number (lockedLanes numbering: connections, then crosswalks) -> target's.
local function mapLanes(clip, node, cfg)
	local roadMap, turn = mapRoads(clip.roads, describeRoads(node))
	if not roadMap then return nil, turn end

	if #cfg.laneConnections ~= #clip.conns then
		return nil, string.format("the junctions have %d and %d lane connections", #clip.conns, #cfg.laneConnections)
	end
	local index = {}
	for i, c in ipairs(cfg.laneConnections) do
		index[connKey(c.segment0, c.lane0, c.segment1, c.lane1)] = i - 1
	end
	local laneMap, missing = {}, 0
	for i, c in ipairs(clip.conns) do
		local j = index[connKey(roadMap[c[1]] or -1, c[2], roadMap[c[3]] or -1, c[4])]
		if j then laneMap[i - 1] = j else missing = missing + 1 end
	end
	if missing > 0 then
		return nil, string.format("%d of %d lane connections have no match here", missing, #clip.conns)
	end

	if #cfg.crosswalks ~= #clip.crosswalks then
		return nil, string.format("the junctions have %d and %d crosswalks", #clip.crosswalks, #cfg.crosswalks)
	end
	local crossIndex = {}
	for i, x in ipairs(cfg.crosswalks) do crossIndex[x] = i end
	local n0, n1 = #clip.conns, #cfg.laneConnections
	for i, x in ipairs(clip.crosswalks) do
		local j = roadMap[x] and crossIndex[roadMap[x]]
		if not j then
			log("crosswalk %s isn't one of the junction's roads: mapped by position (%d)", tostring(x), i)
			j = i
		end
		laneMap[n0 + i - 1] = n1 + j - 1
	end
	return laneMap, turn
end

local function paste(clip, node, done)
	local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
	if not cfg then return done(false, "this junction has no lane configuration") end
	local laneMap, info = mapLanes(clip, node, cfg)
	if not laneMap then return done(false, info) end

	local tl = cfg.trafficLightConfig:clone()
	local states = {}
	for _, s in ipairs(clip.states) do
		local st = api.type.TrafficLightState.new()
		local locked = {}
		for _, l in ipairs(s.locked) do
			if laneMap[l] then locked[#locked + 1] = laneMap[l] end
		end
		st.lockedLanes = locked
		st.duration = s.duration
		st.minDuration = s.minDuration
		st.canSkip = s.canSkip
		states[#states + 1] = st
	end
	tl.states = states
	tl.trafficLightType = clip.lightType

	local proposal = api.engine.util.proposal.createTrafficLightProposal(node, tl, clip.preference)
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true), function(_, success)
		log("paste node %d -> %d: %s (%d phases, roads turned %.0f deg on average)",
			clip.node, node, success and "ok" or "refused", #states, info)
		done(success, success
			and string.format("Pasted %d phases%s", #states, info > 20 and string.format(" (roads turned ~%.0f°)", info) or "")
			or "The game refused the change")
	end)
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function useClipboard()
	local state = react.useState(clipboard)
	react.onEvent(EVENT, function()
		state:set(clipboard)
	end)
	return state:old()
end

local function textButton(text, tooltip, enabled, onClick)
	return builtin.Button{
		meta = { class = "secondary", enabled = enabled, tooltip = tooltip },
		content = builtin.TextView{ text = text, meta = { class = "font-scale-body" } },
		onClick = onClick,
	}
end

local Content = react.RegisterRecipe("ImsvaleYieldLightCopyContent", function(param)
	local clip = useClipboard()
	local message = react.useState(nil)

	if not view_manager_util.baseNodeCanConfigTrafficLight(param.keyEntity) then
		return react.CallOriginalRecipe(original, param)
	end
	local node = param.keyEntity

	local row = builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			textButton("Copy", "Copy this junction's traffic light phases", true, function()
				local ok, c, err = pcall(copy, node)
				if ok and c then
					clipboard = c
					log("copied node %d: %d phases, %d lane connections", node, #c.states, #c.conns)
					message:set(string.format("Copied %d phases", #c.states))
					react.fireEvent(nil, EVENT, nil)
				else
					message:set("Copy failed: " .. tostring(ok and err or c))
				end
			end),
			textButton("Paste", clip
				and string.format("Paste the phases copied from junction %d", clip.node)
				or "Copy a junction's phases first", clip ~= nil, function()
				if not clipboard then return end
				local ok, err = pcall(paste, clipboard, node, function(success, text)
					message:set(success and text or ("Can't paste: " .. tostring(text)))
				end)
				if not ok then message:set("Paste failed: " .. tostring(err)) end
			end),
			builtin.TextView{
				text = message:old() or (clip and string.format("Clipboard: junction %d", clip.node) or ""),
				meta = { class = "font-scale-annotation" },
			},
		},
	}

	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			row,
			react.CallOriginalRecipe(original, param),
		},
	}
end)

return {
	VERSION = VERSION,
	original = original,
	Content = Content,
}
