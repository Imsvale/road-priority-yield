-- Priority Road: make the side roads yield along a road, or around a roundabout, in one click.
--
-- Cars in TF3 never give way (the engine's per-connection `precedence` flag only drives the
-- markings, 2026-10-16). A two-phase light without all-red phases makes a good proxy: the
-- priority road is green as long as it has traffic (phase #1: 60 s, 0 s minimum, skipping
-- allowed, so it ends as soon as the priority road is empty and someone waits), then the side
-- roads get a short turn (phase #2: 5 s, same) and the priority road is back. With the
-- invisible light type nobody sees the lights. Paired test on a roundabout: stopping on the ring
-- −96%, and the ring never broke down (docs/notes.md).
--
-- Use: hover a road. The tool follows it through junctions in both directions, always to the
-- connected road that continues straightest (at most MAX_TURN off), until there is none, or
-- until it is back where it started: a loop. A loop that is round (every sample within
-- ROUND_TOLERANCE of the average radius) is a roundabout, anything else a priority road; the
-- yielding is the same, only the label (and later the signs) differ. Blue: the priority road;
-- gold: the approaches that yield. Click to apply to every junction on it; if they all have it
-- already, click removes it (light preference None, phases reset to the game's default).
--
-- Per junction (3+ roads) on the priority road, numbering lockedLanes as the game does
-- (lane connections, then crosswalks):
-- - phase #1: connections coming from the priority road's two segments green;
-- - phase #2: connections coming from the side roads green;
-- - phase #3, only with crosswalks: crosswalks green (PEDESTRIAN_SECONDS, skipping allowed).
-- Junctions where no side road leads in (exits only) get no light.
--
-- Road direction comes from the junction's lane connections (which segment leads to which),
-- not from the lanes' transport mode flags.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local color_util = ug_require "::/gui/main/color_util.tl"
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl"

local VERSION = "priority road 1 (first version)"
local CT = api.type.ComponentType

local PRIORITY_SECONDS = 60.0  -- phase #1 maximum; it ends early when the priority road is empty
local YIELD_SECONDS = 5.0      -- phase #2 maximum; short, or a long side queue would hold the priority road
local PEDESTRIAN_SECONDS = 6.0 -- phase #3, only where there are crosswalks
local MAX_TURN = 45            -- degrees: how far the priority road may bend at a junction
local ROUND_TOLERANCE = 0.12   -- a loop is a roundabout if every sample is within 12 % of the mean radius
local MAX_SEGMENTS = 400       -- stop following a road after this many segments
local LIGHT_TYPE = "imsvale_yield_invisible" -- matched against the light type resource names

local function log(fmt, ...)
	local args = { ... }
	pcall(function()
		print("[yield] " .. string.format(fmt, (table.unpack or unpack)(args)))
	end)
end

local function isEdge(entity)
	return entity ~= nil and entity >= 0 and api.engine.entityExists(entity)
		and api.engine.getComponent(entity, CT.BASE_EDGE) ~= nil
		and api.engine.getComponent(entity, CT.BASE_EDGE_STREET) ~= nil
end

local function v2(x, y) return api.type.Vec2f.new(x, y) end

---------------------------------------------------------------------------
-- Following the road
---------------------------------------------------------------------------

-- Horizontal direction in which `seg` leaves `node` (unit vector), and its far node.
local function leaving(seg, node)
	local e = api.engine.getComponent(seg, CT.BASE_EDGE)
	local t, far
	if e.node0 == node then
		t, far = e.tangent0, e.node1
	else
		t, far = { x = -e.tangent1.x, y = -e.tangent1.y }, e.node0
	end
	local l = math.sqrt(t.x * t.x + t.y * t.y)
	if l < 1e-9 then return { x = 0, y = 0 }, far end
	return { x = t.x / l, y = t.y / l }, far
end

-- Pairs "a>b" of segments joined by a lane connection at `node` (a leads to b).
local function connections(node)
	local pairs_, cfg = {}, api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
	for _, c in ipairs(cfg and cfg.laneConnections or {}) do
		pairs_[c.segment0 .. ">" .. c.segment1] = true
	end
	return pairs_, cfg ~= nil and #cfg.laneConnections > 0
end

-- From segment `seg`, arriving at `node`: walk on through the straightest connected road at
-- each node. Returns the segments after `seg`, the nodes passed through (each with the segment
-- arriving and the one leaving), and whether the walk came back to `stopAt`.
local function walk(seg, node, stopAt, visited)
	local segs, nodes = {}, {}
	local current = seg
	for _ = 1, MAX_SEGMENTS do
		local arrive = leaving(current, node)
		arrive = { x = -arrive.x, y = -arrive.y } -- direction of travel into the node
		local joined, known = connections(node)
		local best, bestTurn, bestFar = nil, MAX_TURN, nil
		for _, cand in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(node)) do
			if cand ~= current and (not known or joined[current .. ">" .. cand] or joined[cand .. ">" .. current]) then
				local d, far = leaving(cand, node)
				local cos = math.max(-1, math.min(1, arrive.x * d.x + arrive.y * d.y))
				local turn = math.deg(math.acos(cos))
				if turn <= bestTurn then best, bestTurn, bestFar = cand, turn, far end
			end
		end
		if not best then return segs, nodes, false end
		nodes[#nodes + 1] = { node = node, a = current, b = best }
		if best == stopAt then return segs, nodes, true end
		if visited[best] then return segs, nodes, false end
		visited[best] = true
		segs[#segs + 1] = best
		current, node = best, bestFar
	end
	return segs, nodes, false
end

local function hermite(p0, p1, t0, t1, s)
	local s2, s3 = s * s, s * s * s
	local h00, h10, h01, h11 = 2 * s3 - 3 * s2 + 1, s3 - 2 * s2 + s, -2 * s3 + 3 * s2, s3 - s2
	return {
		x = h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x,
		y = h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y,
	}
end

-- Round: every sample along the loop within ROUND_TOLERANCE of the mean distance from the
-- centroid. Returns round, mean radius, largest relative deviation.
local function roundness(segs)
	local pts = {}
	for _, seg in ipairs(segs) do
		local e = api.engine.getComponent(seg, CT.BASE_EDGE)
		for i = 0, 3 do pts[#pts + 1] = hermite(e.position0, e.position1, e.tangent0, e.tangent1, i / 4) end
	end
	local cx, cy = 0, 0
	for _, p in ipairs(pts) do cx, cy = cx + p.x / #pts, cy + p.y / #pts end
	local radii, mean = {}, 0
	for i, p in ipairs(pts) do
		radii[i] = math.sqrt((p.x - cx) ^ 2 + (p.y - cy) ^ 2)
		mean = mean + radii[i] / #pts
	end
	local worst = 0
	for _, r in ipairs(radii) do worst = math.max(worst, math.abs(r - mean) / mean) end
	return worst <= ROUND_TOLERANCE, mean, worst
end

---------------------------------------------------------------------------
-- The plan: which junctions, which connections yield
---------------------------------------------------------------------------

local lightTypeId = nil
local function invisibleType()
	if lightTypeId then return lightTypeId end
	local rep = api.res.trafficLightTypeRep
	local ok, all = pcall(function() return rep.getAll(true) end)
	if ok and type(all) == "table" then
		for id, name in pairs(all) do
			if tostring(name):find(LIGHT_TYPE, 1, true) then lightTypeId = id return id end
		end
	end
	for id in pairs(rep.getAll()) do
		local t = rep.get(id)
		local file = t and t.modelScript and tostring(t.modelScript.fileName) or ""
		if file:find(LIGHT_TYPE, 1, true) then lightTypeId = id return id end
	end
	return nil
end

-- Phases for one junction, or nil and why not.
local function junctionStates(node, a, b, cfg)
	local priority = { [a] = true, [b] = true }
	local conns, nConn = cfg.laneConnections, #cfg.laneConnections
	local nCross = #cfg.crosswalks
	local sideIn, sideSegs = 0, {}
	for _, c in ipairs(conns) do
		if not priority[c.segment0] then sideIn = sideIn + 1 sideSegs[c.segment0] = true end
	end
	if sideIn == 0 then return nil, "no side road leads in", sideSegs end
	local function phase(duration, green)
		local st = api.type.TrafficLightState.new()
		local locked = {}
		for i, c in ipairs(conns) do
			if not green(c, nil) then locked[#locked + 1] = i - 1 end
		end
		for i = 1, nCross do
			if not green(nil, i) then locked[#locked + 1] = nConn + i - 1 end
		end
		st.lockedLanes = locked
		st.duration = duration
		st.minDuration = 0
		st.canSkip = true
		return st
	end
	local states = {
		phase(PRIORITY_SECONDS, function(c) return c and priority[c.segment0] end),
		phase(YIELD_SECONDS, function(c) return c and not priority[c.segment0] end),
	}
	if nCross > 0 then
		states[#states + 1] = phase(PEDESTRIAN_SECONDS, function(c, cross) return cross ~= nil end)
	end
	return states, nil, sideSegs
end

-- Everything the hovered segment leads to: the priority road, its junctions, what yields.
local function planFrom(seg)
	if not isEdge(seg) then return nil, "not a road" end
	local e = api.engine.getComponent(seg, CT.BASE_EDGE)
	local visited = { [seg] = true }
	local fwdSegs, fwdNodes, loop = walk(seg, e.node1, seg, visited)
	local segs, nodes = { seg }, {}
	for _, s in ipairs(fwdSegs) do segs[#segs + 1] = s end
	for _, n in ipairs(fwdNodes) do nodes[#nodes + 1] = n end
	if not loop then
		local backSegs, backNodes = walk(seg, e.node0, nil, visited)
		for _, s in ipairs(backSegs) do segs[#segs + 1] = s end
		for _, n in ipairs(backNodes) do nodes[#nodes + 1] = n end
	end

	local plan = { segs = segs, loop = loop, junctions = {}, skipped = 0, applied = 0, entries = 0, yieldSegs = {} }
	if loop and #segs >= 3 then
		plan.round, plan.radius, plan.roundness = roundness(segs)
	end
	plan.kind = plan.round and "Roundabout" or (loop and "Priority loop" or "Priority road")
	local typeId = invisibleType()
	plan.typeId = typeId
	for _, n in ipairs(nodes) do
		if #api.engine.system.streetSystem.getNodeStreetSegments(n.node) >= 3 then
			local cfg = api.engine.getComponent(n.node, CT.BASE_NODE_CONFIG)
			if cfg then
				local states, why, sideSegs = junctionStates(n.node, n.a, n.b, cfg)
				local has = api.engine.getComponent(n.node, CT.BASE_NODE_TRAFFIC_LIGHT) ~= nil
					and typeId ~= nil and cfg.trafficLightConfig.trafficLightType == typeId
				local j = { node = n.node, a = n.a, b = n.b, states = states, why = why, has = has }
				plan.junctions[#plan.junctions + 1] = j
				if states then
					plan.entries = plan.entries + 1
					for s in pairs(sideSegs) do plan.yieldSegs[#plan.yieldSegs + 1] = s end
				else
					plan.skipped = plan.skipped + 1
				end
				if has then plan.applied = plan.applied + 1 end
			end
		end
	end
	plan.remove = plan.applied > 0 and plan.applied == plan.entries
	if #plan.junctions == 0 then return nil, plan.kind .. " with no junctions on it" end
	if not typeId then return nil, "the Yield (invisible) light type wasn't found" end
	return plan
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

local function send(node, tl, preference, done)
	local proposal = api.engine.util.proposal.createTrafficLightProposal(node, tl, preference)
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true), function(_, success)
		done(success)
	end)
end

-- Apply (or remove) at every junction; `done(okCount, failCount)` once all have answered.
local function apply(plan, done)
	local pending, ok, failed = 0, 0, 0
	local function answered(success)
		if success then ok = ok + 1 else failed = failed + 1 end
		pending = pending - 1
		if pending == 0 then done(ok, failed) end
	end
	local jobs = {}
	for _, j in ipairs(plan.junctions) do
		local cfg = api.engine.getComponent(j.node, CT.BASE_NODE_CONFIG)
		if plan.remove then
			if j.has then
				local tl = cfg.trafficLightConfig:clone()
				tl.states = {}
				jobs[#jobs + 1] = { node = j.node, tl = tl, pref = api.type.enum.TrafficLightPreference.NO }
			end
		elseif j.states then
			local tl = cfg.trafficLightConfig:clone()
			tl.states = j.states
			tl.trafficLightType = plan.typeId
			jobs[#jobs + 1] = { node = j.node, tl = tl, pref = api.type.enum.TrafficLightPreference.YES }
		end
	end
	if #jobs == 0 then return done(0, 0) end
	pending = #jobs
	for _, job in ipairs(jobs) do
		local sent, err = pcall(send, job.node, job.tl, job.pref, answered)
		if not sent then
			log("node %d: %s", job.node, tostring(err))
			answered(false)
		end
	end
end

---------------------------------------------------------------------------
-- The tool
---------------------------------------------------------------------------

local function segmentGeometry(seg)
	local e = api.engine.getComponent(seg, CT.BASE_EDGE)
	local p0, p1, t0, t1 = e.position0, e.position1, e.tangent0, e.tangent1
	local cs = api.type.EdgeGeometry.CubicSpline.new()
	cs.pos = { v2(p0.x, p0.y), v2(p1.x, p1.y) }
	cs.tangent = { v2(t0.x, t0.y), v2(t1.x, t1.y) }
	local g = api.type.EdgeGeometry.new()
	g.type = api.type.EdgeGeometry.Type.CUBIC_SPLINE
	g.cubicSpline = cs
	g.height = v2(p0.z, p1.z)
	g.tangent = v2(t0.z, t1.z)
	g.length = e.distance and e.distance > 0 and e.distance or math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
	g.width = 0
	return g
end

local constructionColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/construction/construction_colors.gres")).data
local transparency = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/transparency.gres")).data
local selectionGres = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/selection_colors.gres")).data

local lastLog = nil -- plans are worked out on every redraw: log one only when it changes

local PriorityRoadAction = react.RegisterRecipe("ImsvalePriorityRoadAction", function(params)
	local revision = react.useState(0)
	local message = react.useState(nil)
	local pending = react.useState(false)

	react.setForceFocusable(true)
	react.setRestrictMouseFocus(true)

	if not params.isActive then
		return
	end

	local function actionFn()
		local hovered = react.useState(nil)

		local seg = hovered:old()
		local plan, why = nil, nil
		if seg and not pending:old() then
			local ok, p, w = pcall(planFrom, seg)
			if ok then plan, why = p, w else why = "error: " .. tostring(p) end
		end
		if plan then
			local line = string.format("%s from segment %d: %d segments, %d junctions (%d yield, %d skipped, %d applied)%s",
				plan.kind, seg, #plan.segs, #plan.junctions, plan.entries, plan.skipped, plan.applied,
				plan.radius and string.format(", radius %.0f m, roundness %.3f", plan.radius, plan.roundness) or "")
			if line ~= lastLog then log("%s", line) lastLog = line end
		end

		local children = {}
		if plan then
			local edges = {}
			local blue = color_util.withTransparency(constructionColors.Modifier.Valid, 0.75)
			local gold = color_util.withTransparency(constructionColors.Bulldozer, 0.75)
			for _, s in ipairs(plan.segs) do
				local e = builtin.type.EdgeRenderable.Edge.new(segmentGeometry(s))
				e.colors = { blue }
				e.width = 1.5
				e.offsetZ = 0.5
				e.stepSize = 2
				edges[#edges + 1] = e
			end
			if not plan.remove then
				for _, s in ipairs(plan.yieldSegs) do
					local e = builtin.type.EdgeRenderable.Edge.new(segmentGeometry(s))
					e.colors = { gold }
					e.width = 1.0
					e.offsetZ = 0.5
					e.stepSize = 2
					edges[#edges + 1] = e
				end
			end
			children[#children + 1] = builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
		end

		children[#children + 1] = builtin.Selector{
			onHover = function(entity)
				local s = isEdge(entity) and entity or nil
				if s ~= hovered:old() then hovered:set(s) end
			end,
			onSelect = function(entity)
				if pending:old() then return true end
				local ok, p, w = pcall(planFrom, entity)
				if not ok or not p then
					message:set("Not applied: " .. tostring(ok and w or p))
					return true
				end
				pending:set(true)
				log("%s from segment %d: %s at %d junctions", p.kind, entity, p.remove and "removing" or "applying",
					p.remove and p.applied or p.entries)
				apply(p, function(okCount, failCount)
					log("%s: %d ok, %d failed", p.remove and "removed" or "applied", okCount, failCount)
					message:set(string.format("%s %s at %d junctions%s", p.kind, p.remove and "removed" or "applied",
						okCount, failCount > 0 and string.format(" (%d refused by the game)", failCount) or ""))
					pending:set(false)
					revision:set(revision:old() + 1)
				end)
				return true
			end,
			filter = function(entity)
				return isEdge(entity)
			end,
			selectionColor = color_util.toVec4(selectionGres.default.selectionColor),
			selectionOutlineColor = color_util.withTransparency(selectionGres.default.selectionOutlineColor, transparency.Low),
			selectionOutlineColor1 = color_util.toVec4(selectionGres.default.selectionOutlineColor),
		}

		local text, good = "Hover a road or roundabout: its side roads will yield to it", nil
		if plan then
			if plan.remove then
				text, good = string.format("%s: yielding set at all %d junctions. Click to remove it.", plan.kind, plan.applied), true
			else
				text, good = string.format("%s: %d junctions where side roads yield%s. Click to apply.", plan.kind, plan.entries,
					plan.skipped > 0 and string.format(" (%d with no side road leading in)", plan.skipped) or ""), true
			end
		elseif seg and why then
			text, good = "Can't apply here: " .. why, false
		end
		if message:old() then text = message:old() .. "\n" .. text end
		children[#children + 1] = builtin.ActionTooltip{
			recipe = construction_react_util.SimpleTooltipRecipe,
			param = { message = { message = text, good = good } },
		}

		return builtin.ActionDescriptor{
			onBack = function() params.abort() end,
			children = children,
			terrainCirclePolicy = "Never",
		}
	end

	params.setActionFn(actionFn, "imsvale_priority_road_" .. tostring(revision:old()))
end)

log("loaded: %s", VERSION)

local function getDefinition(constructionDefinition, _repository, _params)
	return {
		resName = constructionDefinition,
		icon = {
			icon = "::/gui/construction/tools/lane_control.tga",
			lockedIcon = "::/gui/construction/tools/lane_control_locked.tga",
		},
		previewIcon = {
			icon = "::/gui/construction/tools/lane_control_preview.tga",
			lockedIcon = "::/gui/construction/tools/lane_control_preview.tga",
		},
		name = "Priority Road",
		description = "Make side roads yield: click a road or a roundabout, and at every junction along it, traffic from the side waits for a gap. Uses invisible traffic lights. Click again to remove.",
		action = "ACTION_CUSTOM",
		availability = { yearFrom = 0, yearTo = 0 },
		params = {},
		builderAudioRes = {},
		customAction = { recipe = PriorityRoadAction },
		menuCategory = {
			categories = {
				{ category = "roads_tools", order = 1250 },
			},
		},
	}
end

function data()
	return {
		getDefinition = getDefinition,
	}
end
