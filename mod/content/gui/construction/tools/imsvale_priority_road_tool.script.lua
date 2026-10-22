-- Priority Road: make the side roads yield along a road, or around a roundabout, in one click.
--
-- Cars in TF3 never give way (the engine's per-connection `precedence` flag only drives the
-- markings, 2026-10-16). A two-phase light without all-red phases makes a good proxy: the
-- priority road is green as long as it has traffic (phase #1: 60 s, 0 s minimum, skipping
-- allowed, so it ends as soon as the priority road is empty and someone waits), then the side
-- roads get a short turn (phase #2: see PLANS, same) and the priority road is back. With the
-- invisible light type nobody sees the lights. Paired test on a roundabout: stopping on the ring
-- −96%, and the ring never broke down (docs/notes.md).
--
-- Use: hover a road. The tool follows it through junctions in both directions, always to the
-- connected road that continues straightest (at most MAX_TURN off), until there is none, or
-- until it is back where it started: a loop. A loop that is round (every sample within
-- ROUND_TOLERANCE of the average radius) is a roundabout, anything else a priority road; the
-- yielding is the same, only the label (and later the signs) differ. Blue: the priority road;
-- red: the approaches that yield (gold: a road about to lose it). Click to apply to every
-- junction on it; if they all have it already, click removes it (light preference Auto, type -1:
-- the junction is the game's again, its own light where the roads call for one).
--
-- Icons while the tool is open: a priority / yield icon on every approach of every junction
-- configured with this mod, near the camera. Hovering a road previews its junctions instead:
-- new icons; on removal the existing ones crossed out; where a configured junction's role
-- changes, the old icon crossed out beside the new one.
--
-- Per junction (3+ roads) on the priority road, numbering lockedLanes as the game does
-- (lane connections, then crosswalks), with the plan for its kind (PLANS: roundabouts and
-- ordinary junctions are configured apart, so a change for one can't reach the other):
-- - phase #1: connections coming from the priority road's two segments green;
-- - phase #2: connections coming from the side roads green; on a roundabout also those leaving
--   the ring onto a side road (exits): they don't cross the entering traffic. At ordinary
--   junctions the exits stay red in #2: at a 4-way the priority road's turns cross or merge
--   with the side roads' traffic (lab study, paired runs 2026-10-19: forced side road entries
--   33 -> 25, priority road unaffected; at a T no difference);
-- - crosswalks green in both phases, no pedestrian phase (user, 2026-10-20; until priority
--   road 44 a phase #3 for them).
-- Junctions where no side road leads in (exits only) get no light.
--
-- Lanes (opt-in; see LANE_PARAM): "Overwrite lanes" sets each junction's lanes by its plan's
-- rule. Ordinary junctions: each turn lands in its own lane instead of fanning out into every lane
-- of the road it turns into; "Dedicated turn lanes" on top of it makes turning lanes turn-only
-- where another lane still goes straight on. Roundabouts: their own rule (roundaboutLanes: the
-- ring steps toward the exits). Lanes and phases are then set together in one node config
-- proposal, so every connection has a green. Removing the yielding leaves the lanes as they are. Measured in the lab (../traffic-lab,
-- docs/studies/2026-10-18_give-way-junctions.md, runs 15-25): never worse than the game's lanes,
-- up to 19% fewer forced entries on wide roads.
--
-- Road direction comes from the junction's lane connections (which segment leads to which),
-- not from the lanes' transport mode flags.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local color_util = ug_require "::/gui/main/color_util.tl"
local constructionColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/construction/construction_colors.gres")).data
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl"
local styleutil = ug_require "::/gui/main/styleutil.tl"

local VERSION = "priority road 69 (lane changes with other roads are road edits, rebuilt; follow trace on dev)"
local CT = api.type.ComponentType

-- Phase plans and phase building, shared with the yield game script ("Follow lane edits").
local phases = ug_require "/scripts/imsvale_yield_phases.lua"
local PLANS = phases.PLANS
local MAX_TURN = 45            -- degrees: how far the priority road may bend at a junction
local ROUND_TOLERANCE = 0.12   -- a loop is a roundabout if every sample is within 12 % of the mean radius
local MAX_SEGMENTS = 400       -- stop following a road after this many segments
local LIGHT_TYPE = "imsvale_yield_invisible" -- matched against the light type resource names
-- The road lines drawn while hovering (user, 2026-10-21; compared with the game's road tool on
-- screenshots): as wide as the game's highlight of a hovered road, half opaque.
local LINE_WIDTH = 3.06         -- all three lines
local LINE_ALPHA = 0.5          -- opacity of all three lines
local LINE_PRIORITY = constructionColors.Modifier.Valid    -- the priority road: the game's blue
local LINE_YIELD = { 170 / 255, 45 / 255, 40 / 255 }       -- the roads that yield: a dull red
local LINE_REMOVE = constructionColors.Bulldozer           -- a road about to lose priority: the game's gold

-- Icons, drawn on screen at each approach's junction edge (see IconOverlay): on every junction
-- already configured with this mod, and the hovered road's preview.
local ICON_BACK = 6.0          -- metres back from the junction edge along the approach
local ICON_LIFT = 1.5          -- metres above the road
local ICON_SIZE = 32           -- pixels at ICON_REF_DISTANCE from the camera
local ICON_REF_DISTANCE = 150  -- metres
local ICON_TAPER = 0.5         -- how fast icons shrink with distance: size ~ (ICON_REF_DISTANCE / distance) ^ this
                               -- (1 shrank them too fast; 0.5 is half the rate on a log scale, user 2026-10-19)
local ICON_MIN_SIZE = 14       -- pixels
local ICON_MAX_SIZE = 48       -- pixels
local RANGE_MIN = 250          -- metres from the camera's centre (horizontally) where icons always show
local RANGE_PER_HEIGHT = 6     -- the range grows with the camera's height: max(RANGE_MIN, height * this)
local FADE_FROM = 0.7          -- icons fade out from this share of the range to its end, then hide
local REPLACED_SHIFT = 0.6     -- a replaced icon and its replacement sit this many icon widths left / right
local MAX_ICONS = 300          -- icons drawn at most
local CONFIGURED_REFRESH = 3.0 -- seconds between scans for configured junctions
local ICONS = {
	priority = "imsvale_road_priority_yield::/gui/priority-diamond.tga",
	yield = "imsvale_road_priority_yield::/gui/yield.tga",
}
-- Icons per sign style, where a style has its own (made from the user's artwork by
-- tools/make_gui_icons.py); anything missing falls back to ICONS (international).
local STYLE_ICONS = {
	no = { yield = "imsvale_road_priority_yield::/gui/yield-no.tga" },
}
local function iconFor(kind, style)
	return (STYLE_ICONS[style] or {})[kind] or ICONS[kind]
end
-- The sign style the icons show: set every step by the tool from its setting, read every step by
-- the overlay, so a change shows at once (it was only passed in when the action was rebuilt,
-- which a setting change doesn't do; 2026-10-19). GUI module state.
local iconStyle = "intl"
-- An icon that goes away is marked with the bulldozer's look: a box of translucent gold with a
-- stronger gold outline, in the game's own Bulldozer colour.
local HIGHLIGHT_FILL = 0.35    -- opacity of the highlight's fill
local HIGHLIGHT_BORDER = 0.9   -- opacity of its outline
local HIGHLIGHT_WIDTH = 2      -- outline width, pixels
local HIGHLIGHT_PAD = 1.2      -- box size relative to the icon

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

-- Where an approach meets the junction: the mean of its lane curves' ends at `node` (a
-- segment's lanes stop at the junction's edge), moved ICON_BACK out along the road.
local function approachPoint(seg, node)
	local tn = api.engine.getComponent(seg, CT.TRANSPORT_NETWORK)
	local np = api.engine.getComponent(node, CT.BASE_NODE).position
	local calc = api.engine.util.transport.calcPosition
	local sx, sy, sz, n = 0, 0, 0, 0
	for _, e in ipairs(tn and tn.edges or {}) do
		local a, b = calc(e.geometry, 0), calc(e.geometry, 1)
		local p = ((a.x - np.x) ^ 2 + (a.y - np.y) ^ 2 <= (b.x - np.x) ^ 2 + (b.y - np.y) ^ 2) and a or b
		sx, sy, sz, n = sx + p.x, sy + p.y, sz + p.z, n + 1
	end
	if n == 0 then return nil end
	local d = leaving(seg, node)
	return { x = sx / n + d.x * ICON_BACK, y = sy / n + d.y * ICON_BACK, z = sz / n }
end

-- The centre of an approach where it meets the junction (the mean of its lane curves' ends at
-- `node`), and the direction out along the road. Shared idea with approachPoint, without the
-- icon's offset.
local function junctionEdge(seg, node)
	local p = approachPoint(seg, node)
	if not p then return nil end
	local d = leaving(seg, node)
	return { x = p.x - d.x * ICON_BACK, y = p.y - d.y * ICON_BACK, z = p.z }, d
end

-- Roles of a configured junction's approaches, read from its phases: a segment with a
-- connection green in phase #1 is the priority road, one green only in phase #2 yields.
local function configuredRoles(cfg)
	local states = cfg.trafficLightConfig.states
	if #states < 2 then return {} end
	local function lockedSet(st)
		local set = {}
		for _, l in ipairs(st.lockedLanes) do set[l] = true end
		return set
	end
	local locked1, locked2 = lockedSet(states[1]), lockedSet(states[2])
	local roles = {}
	for i, c in ipairs(cfg.laneConnections) do
		if not locked1[i - 1] then
			roles[c.segment0] = "priority"
		elseif not locked2[i - 1] and roles[c.segment0] == nil then
			roles[c.segment0] = "yield"
		end
	end
	return roles
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

-- From `node` out along `seg`, through plain nodes (two segments), to the first junction or dead
-- end. Returns that node and the segments on the way (the last one ends at it).
local function stretchFrom(seg, node)
	local path, cur = { seg }, seg
	local _, far = leaving(seg, node)
	for _ = 1, MAX_SEGMENTS do
		local around = {}
		for _, s in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(far)) do around[#around + 1] = s end
		if #around ~= 2 then break end
		local nxt = around[1] == cur and around[2] or around[1]
		if nxt == seg then break end -- a loop without junctions
		path[#path + 1] = nxt
		local _, f = leaving(nxt, far)
		cur, far = nxt, f
	end
	return far, path
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

-- The type every light we take off gets: -1, the game's "no type chosen" (its own managed lights
-- and junctions without a light have it; a light added there later is the climate's default).
-- A node keeps its light type index even without a light, and without this mod our index points
-- past the end of the list, which crashed the game when the road tool rebuilt such a node
-- (2026-10-20). -1 doesn't: Uninstall, mod disabled, road upgraded at a former junction, the
-- game's usual lights there (user's test, 2026-10-22). Priority road 48-64 used the climate's
-- Type A instead, found by name and climate category.
local TAKEN_OFF_TYPE = -1
-- And its preference: AUTO, as at a junction the game manages itself, so taking ours off resets
-- the junction with no further assumptions: the game puts its own light there where the roads
-- call for one (user, 2026-10-22; until priority road 66 it was NO, never a light).
local TAKEN_OFF_PREFERENCE = api.type.enum.TrafficLightPreference.AUTO
-- The preference to leave at a node we take our type off where the light may be gone already:
-- AUTO while our light is still on; where the player switched it off (no light, our type still
-- stored), theirs, or the game would put a light back that they removed.
local function takenOffPreference(node, cfg)
	if api.engine.getComponent(node, CT.BASE_NODE_TRAFFIC_LIGHT) then return TAKEN_OFF_PREFERENCE end
	return cfg.trafficLightPreference
end

local junctionStates = phases.junctionStates -- (node, a, b, cfg, round, conns)

-- Everything the hovered segment leads to: the priority road, its junctions, what yields.
local chainOf -- (plan): the road's segments in order and its nodes; defined with the priority signs

local function planFrom(seg)
	if not isEdge(seg) then return nil, "not a road" end
	local e = api.engine.getComponent(seg, CT.BASE_EDGE)
	local visited = { [seg] = true }
	local fwdSegs, fwdNodes, loop = walk(seg, e.node1, seg, visited)
	local segs, nodes = { seg }, {}
	for _, s in ipairs(fwdSegs) do segs[#segs + 1] = s end
	for _, n in ipairs(fwdNodes) do nodes[#nodes + 1] = n end
	local backSegs = {}
	if not loop then
		local backNodes
		backSegs, backNodes = walk(seg, e.node0, nil, visited)
		for _, s in ipairs(backSegs) do segs[#segs + 1] = s end
		for _, n in ipairs(backNodes) do nodes[#nodes + 1] = n end
	end

	local plan = { segs = segs, loop = loop, junctions = {}, skipped = 0, applied = 0, ours = 0, entries = 0, yieldSegs = {}, icons = {},
		seg0 = seg, fwdSegs = fwdSegs, backSegs = loop and {} or backSegs }
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
				local states, why, sideSegs = junctionStates(n.node, n.a, n.b, cfg, plan.round)
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
				-- Roles before and after, for the icons: the approaches that lead in get one.
				local leadsIn = {}
				for _, c in ipairs(cfg.laneConnections) do leadsIn[c.segment0] = true end
				j.old = has and configuredRoles(cfg) or {}
				-- This road is the priority road here (not a side road of another one).
				j.ours = has and (j.old[n.a] == "priority" or j.old[n.b] == "priority")
					and j.old[n.a] ~= "yield" and j.old[n.b] ~= "yield"
				if j.ours then plan.ours = plan.ours + 1 end
				j.new = {}
				if states then
					if leadsIn[n.a] then j.new[n.a] = "priority" end
					if leadsIn[n.b] then j.new[n.b] = "priority" end
					for s in pairs(sideSegs) do j.new[s] = "yield" end
				end
			end
		end
	end
	-- Remove first, extend after (user, 2026-10-19), decided by the hovered segment itself.
	-- Priority belongs to a junction approach (traffic arriving at a yielding junction on a
	-- segment), so it's directional: a link (the road between two junctions, across plain nodes)
	-- can be a priority approach at one end and yield at the other (a T where the road ends, or a
	-- crossing where another priority road has the junction). Membership of the priority road is
	-- worked out from the junctions, not stored: a link belongs to it if it's a priority approach
	-- at one of our junctions (the tool's light, this road through it) at either of its ends.
	-- Stored marks went stale with road type changes, crossings re-applied by another road and the
	-- player's own light edits (user's review, 2026-10-19).
	-- - The hovered segment's link belongs: the click removes the stretch of links connected
	--   through our junctions around it, up to the first junction that isn't ours, and our
	--   junctions on it.
	-- - It doesn't: the click applies to the whole road.
	local chainSegs, chainNodes = chainOf(plan)
	local n = #chainSegs
	local byNode = {}
	for _, j in ipairs(plan.junctions) do byNode[j.node] = j end
	-- A loop starts at one of its junctions, so no link runs across where it closes.
	if plan.loop then
		local r = nil
		for i = 1, n do if byNode[chainNodes[i]] then r = r or i end end
		if r and r > 1 then
			local segs2, nodes2 = {}, {}
			for i = 1, n do
				segs2[i] = chainSegs[(r - 1 + i - 1) % n + 1]
				nodes2[i] = chainNodes[(r - 1 + i - 1) % n + 1]
			end
			nodes2[n + 1] = nodes2[1]
			chainSegs, chainNodes = segs2, nodes2
		end
	end
	-- Links: runs of segments between junction nodes (chainNodes[i] is between segments i-1 and i).
	local linkOf, links = {}, {}
	local current = nil
	for i = 1, n do
		if current == nil or byNode[chainNodes[i]] then
			current = { first = i, last = i, startNode = chainNodes[i] }
			links[#links + 1] = current
		end
		current.last = i
		current.endNode = chainNodes[i + 1]
		linkOf[i] = #links
	end
	-- Is link k a priority approach at our junction at node `node`, through segment `seg`?
	local function priorityAt(node, seg)
		local j = byNode[node]
		return j ~= nil and j.ours and j.old[seg] == "priority"
	end
	local function belongs(k)
		local l = links[k]
		return priorityAt(l.startNode, chainSegs[l.first]) or priorityAt(l.endNode, chainSegs[l.last])
	end
	local hoveredIdx = nil
	for i, x in ipairs(chainSegs) do if x == seg then hoveredIdx = i end end
	plan.remove = hoveredIdx ~= nil and belongs(linkOf[hoveredIdx])
	if plan.remove then
		-- Grow from the hovered link through our junctions.
		local inStretch = { [linkOf[hoveredIdx]] = true }
		local function grow(k, step)
			for _ = 1, #links do
				local l = links[k]
				local node = step > 0 and l.endNode or l.startNode
				local j = byNode[node]
				if not (j and j.ours) then return end
				k = k + step
				if k > #links then if plan.loop then k = 1 else return end end
				if k < 1 then if plan.loop then k = #links else return end end
				if inStretch[k] then return end
				inStretch[k] = true
			end
		end
		grow(linkOf[hoveredIdx], 1)
		grow(linkOf[hoveredIdx], -1)
		local stretch, list = {}, {}
		for i = 1, n do
			if inStretch[linkOf[i]] then
				stretch[chainSegs[i]] = true
				list[#list + 1] = chainSegs[i]
			end
		end
		plan.removeSegs = list
		plan.ours = 0
		for _, j in ipairs(plan.junctions) do
			j.removeHere = (j.ours and (stretch[j.a] or stretch[j.b])) and true or false
			if j.removeHere then plan.ours = plan.ours + 1 end
		end
	end

	-- Icons: removing crosses out what's there; applying shows the new roles, and where a
	-- configured junction's role changes, the old icon crossed out to the left of the new one.
	plan.nodes = {}
	local function icon(j, seg, kind, cross, shift)
		local p = approachPoint(seg, j.node)
		if p then
			p.kind, p.cross, p.shift = kind, cross, shift or 0
			plan.icons[#plan.icons + 1] = p
		end
	end
	for _, j in ipairs(plan.junctions) do
		plan.nodes[j.node] = true
		if plan.remove or not j.states then
			for s, kind in pairs(j.old) do icon(j, s, kind, plan.remove and j.removeHere) end
		else
			local segsHere = {}
			for s in pairs(j.old) do segsHere[s] = true end
			for s in pairs(j.new) do segsHere[s] = true end
			for s in pairs(segsHere) do
				local old, new = j.old[s], j.new[s]
				if new and (old == nil or old == new) then
					icon(j, s, new, false)
				elseif new then
					icon(j, s, old, true, -1)
					icon(j, s, new, false, 1)
				else
					icon(j, s, old, true)
				end
			end
		end
	end
	if #plan.junctions == 0 then return nil, plan.kind .. " with no junctions on it" end
	if not typeId then return nil, "the Yield (invisible) light type wasn't found" end
	return plan
end

---------------------------------------------------------------------------
-- Applying
---------------------------------------------------------------------------

-- Lane rules, ported from the lab's tools/set_lanes.lua. Right-hand traffic; lane numbers as
-- seen from the node: inbound 1 = curb, outbound the highest number = curb.
-- - Which inbound lanes make which turn stays as it is (the game's or the player's choice).
-- - Per approach and road turned into: a right turn maps its inbound lanes, curb first, onto the
--   road's outbound lanes, curb first, one to one; a left turn the same from the median side.
--   More inbound lanes than outbound ones: the extra ones share the last outbound lane.
-- - Straight on and U-turns stay as they are.
-- - dedicated: then straight on is dropped from the lanes that turn, as long as another lane of
--   the approach still goes straight on without turning.
-- Every inbound lane still reaches every road it reached before, so routes stay valid.
local function turnKind(node, a, b)
	local da, db = leaving(a, node), leaving(b, node)
	local hx, hy = -da.x, -da.y
	local angle = math.deg((math.atan2 or math.atan)(hx * db.y - hy * db.x, hx * db.x + hy * db.y))
	if math.abs(angle) < 30 then return "straight" end
	if math.abs(angle) > 150 then return "U-turn" end
	return angle > 0 and "left" or "right"
end

local function rewriteLanes(node, cfg, dedicated)
	local old = cfg.laneConnections -- copies
	local kinds = {}
	for i, c in ipairs(old) do kinds[i] = turnKind(node, c.segment0, c.segment1) end
	local outLanes = {}
	for _, c in ipairs(old) do
		outLanes[c.segment1] = outLanes[c.segment1] or {}
		outLanes[c.segment1][c.lane1] = true
	end
	local groups, order = {}, {}
	for i, c in ipairs(old) do
		if kinds[i] == "left" or kinds[i] == "right" then
			local key = c.segment0 .. ">" .. c.segment1
			local g = groups[key]
			if not g then
				g = { kind = kinds[i], lanes = {}, byLane = {} }
				groups[key], order[#order + 1] = g, key
			end
			if not g.byLane[c.lane0] then
				g.byLane[c.lane0] = c
				g.lanes[#g.lanes + 1] = c.lane0
			end
		end
	end
	local new = {}
	for i, c in ipairs(old) do
		if kinds[i] ~= "left" and kinds[i] ~= "right" then new[#new + 1] = c end
	end
	for _, key in ipairs(order) do
		local g = groups[key]
		local outs = {}
		for lane in pairs(outLanes[g.byLane[g.lanes[1]].segment1]) do outs[#outs + 1] = lane end
		if g.kind == "right" then
			table.sort(g.lanes)                                    -- curb first
			table.sort(outs, function(x, y) return x > y end)     -- curb first
		else
			table.sort(g.lanes, function(x, y) return x > y end)  -- median first
			table.sort(outs)                                       -- median first
		end
		for i, lane0 in ipairs(g.lanes) do
			local c = g.byLane[lane0]
			c.lane1 = outs[math.min(i, #outs)]
			new[#new + 1] = c
		end
	end
	if dedicated then
		local turns, straightLanes = {}, {}
		for _, c in ipairs(new) do
			local kind = turnKind(node, c.segment0, c.segment1)
			if kind == "left" or kind == "right" then turns[c.segment0 .. ":" .. c.lane0] = true end
			if kind == "straight" then
				straightLanes[c.segment0] = straightLanes[c.segment0] or {}
				straightLanes[c.segment0][c.lane0] = true
			end
		end
		local keepOne = {}
		for seg, lanes in pairs(straightLanes) do
			for lane in pairs(lanes) do
				if not turns[seg .. ":" .. lane] then keepOne[seg] = true end
			end
		end
		local kept = {}
		for _, c in ipairs(new) do
			local drop = keepOne[c.segment0] and turns[c.segment0 .. ":" .. c.lane0]
				and turnKind(node, c.segment0, c.segment1) == "straight"
			if not drop then kept[#kept + 1] = c end
		end
		new = kept
	end
	return new
end

-- Roundabout lanes (user's rules, 2026-10-19), at a ring junction with one side road. Ring lanes
-- counted from the curb (the outside of the ring), right-hand traffic. Exits by `exitStyle`
-- (the "Roundabout exit" setting):
-- - "A" (default): only the curb lane exits, into every outbound lane of the side road. It spreads
--   traffic better over the ring lanes: on a 3-lane ring, one lane per exit, where with two lanes
--   exiting the next lanes (the middle one most) were underused (user, 2026-10-19).
-- - "B": the side road's outbound lanes take as many ring lanes, curb first, one to one: those exit.
-- - Exiting lanes don't go on along the ring, except the leftmost exiting lane: no lane goes on
--   to the right of an exiting lane.
-- - Going on, a lane steps one lane to the right (towards the exits); the median lane also keeps
--   its own lane. So every lane gets one lane closer to the exit at each junction.
-- - Entries: each entry lane takes a block of ring lanes, curb first; when there are fewer entry
--   lanes than ring lanes, the extra ring lanes go to the leftmost entry lanes (the game gives
--   them to the right one; the left gives a better balance between the lanes, user). More entry
--   lanes than ring lanes: the curb-side ones share the curb lane.
-- - A one-lane ring: its lane exits and goes on. No exit at this junction: lane to lane.
-- Returns the new connections, or nil when the junction isn't one ring in, one ring out, one side
-- road.
local function roundaboutLanes(node, cfg, a, b, exitStyle)
	local old = cfg.laneConnections -- copies
	local ringIn, ringOut
	for _, c in ipairs(old) do
		if c.segment0 == a and c.segment1 == b then ringIn, ringOut = a, b end
		if c.segment0 == b and c.segment1 == a then ringIn, ringOut = b, a end
	end
	if not ringIn then return nil end
	local spoke = nil
	for _, seg in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(node)) do
		if seg ~= a and seg ~= b then
			if spoke then return nil end -- two side roads at one node: left alone
			spoke = seg
		end
	end
	if not spoke then return nil end
	-- Lanes as the connections use them; inbound curb first (1 = curb), outbound curb first
	-- (the highest number = curb).
	local sets = { ringIn = {}, ringOut = {}, spokeOut = {}, entry = {} }
	local template = old[1]
	for _, c in ipairs(old) do
		if c.segment0 == ringIn then sets.ringIn[c.lane0] = true end
		if c.segment1 == ringOut then sets.ringOut[c.lane1] = true end
		if c.segment1 == spoke then sets.spokeOut[c.lane1] = true end
		if c.segment0 == spoke and c.segment1 == ringOut then sets.entry[c.lane0] = true end
	end
	local function sorted(set, inbound)
		local l = {}
		for lane in pairs(set) do l[#l + 1] = lane end
		table.sort(l, inbound and function(x, y) return x < y end or function(x, y) return x > y end)
		return l
	end
	local ringInL, ringOutL = sorted(sets.ringIn, true), sorted(sets.ringOut, false)
	local spokeOutL, entryL = sorted(sets.spokeOut, false), sorted(sets.entry, true)
	if #ringInL == 0 or #ringOutL == 0 then return nil end
	local new = {}
	local function add(s0, l0, s1, l1)
		local c = nil
		pcall(function() c = api.type.LaneConnection.new() end)
		if c == nil then c = api.engine.getComponent(node, CT.BASE_NODE_CONFIG).laneConnections[1] end
		c.segment0, c.lane0, c.segment1, c.lane1 = s0, l0, s1, l1
		pcall(function() c.withRoad, c.withTram = template.withRoad, template.withTram end)
		new[#new + 1] = c
	end
	local n, nOut = #ringInL, #ringOutL
	local function ringLane(i) return ringOutL[math.max(1, math.min(i, nOut))] end
	local m -- ring lanes that exit
	if exitStyle == "B" then
		m = math.min(#spokeOutL, n)
		for i = 1, m do add(ringIn, ringInL[i], spoke, spokeOutL[i]) end
	else
		m = math.min(#spokeOutL, 1)
		if m == 1 then
			for _, l in ipairs(spokeOutL) do add(ringIn, ringInL[1], spoke, l) end
		end
	end
	if n == 1 then
		add(ringIn, ringInL[1], ringOut, ringLane(1))
	elseif m == 0 then
		for i = 1, n do add(ringIn, ringInL[i], ringOut, ringLane(i)) end -- no exit here: lane to lane
	else
		for i = 2, n do
			if i >= m then add(ringIn, ringInL[i], ringOut, ringLane(i - 1)) end
		end
		add(ringIn, ringInL[n], ringOut, ringLane(n))
	end
	local k = #entryL
	if k > 0 then
		if k >= nOut then
			for j = 1, k do add(spoke, entryL[j], ringOut, ringOutL[math.max(1, j - (k - nOut))]) end
		else
			local base, extra = math.floor(nOut / k), nOut % k
			local next = 1
			for j = 1, k do
				local count = base + ((j > k - extra) and 1 or 0)
				for _ = 1, count do
					add(spoke, entryL[j], ringOut, ringOutL[next])
					next = next + 1
				end
			end
		end
	end
	return new
end

-- Lanes and phases in one street proposal (the node config replaced), so no connection is left
-- without a green.
local function sendNodeConfig(node, cfg, conns, tl, done)
	local nc = api.type.BaseNodeLaneConnectionAndEntity.new()
	nc.entity = node
	local comp = nc.comp
	comp.laneConnections = conns
	comp.crosswalks = cfg.crosswalks
	comp.trafficLightPreference = api.type.enum.TrafficLightPreference.YES
	comp.doubleSlipSwitch = false
	comp.trafficLightConfig = tl
	pcall(function() comp.userModifiedLaneConnections = true end)
	pcall(function() comp.userModifiedTrafficLightStates = true end)
	nc.comp = comp
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodeConfigsToAdd = { nc }
	proposal.streetProposal.nodeConfigsToRemove = { node }
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true), function(_, success)
		done(success)
	end)
end

local function send(node, tl, preference, done)
	local proposal = api.engine.util.proposal.createTrafficLightProposal(node, tl, preference)
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true), function(_, success)
		done(success)
	end)
end

-- Apply (or remove) at every junction; `done(okCount, failCount)` once all have answered.
-- `lanes`: { overwrite = bool, dedicated = bool } from the tool's settings. `onJob(job, success)`
-- after each junction (job: node, a, b, round, remove).
local function apply(plan, done, lanes, onJob)
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
			if j.removeHere then
				local tl = cfg.trafficLightConfig:clone()
				tl.states = {}
				tl.trafficLightType = TAKEN_OFF_TYPE
				jobs[#jobs + 1] = { node = j.node, tl = tl, pref = TAKEN_OFF_PREFERENCE, remove = true }
			end
		elseif j.states then
			local tl = cfg.trafficLightConfig:clone()
			tl.states = j.states
			tl.trafficLightType = plan.typeId
			local job = { node = j.node, tl = tl, pref = api.type.enum.TrafficLightPreference.YES,
				a = j.a, b = j.b, round = plan.round or false, typeId = plan.typeId }
			local planHere = plan.round and PLANS.roundabout or PLANS.junction
			local conns = nil
			if lanes and lanes.overwrite then
				if planHere.lanes == "junction" then
					conns = rewriteLanes(j.node, cfg, lanes.dedicated)
				elseif planHere.lanes == "roundabout" then
					conns = roundaboutLanes(j.node, cfg, j.a, j.b, lanes.exitStyle)
					if not conns then log("node %d: roundabout lanes left as they are", j.node) end
				end
			end
			if conns then
				local states = junctionStates(j.node, j.a, j.b, cfg, plan.round, conns)
				if states then
					tl.states = states
					job.conns, job.cfg = conns, cfg
				end
			end
			jobs[#jobs + 1] = job
		end
	end
	if #jobs == 0 then return done(0, 0) end
	pending = #jobs
	for _, job in ipairs(jobs) do
		local function finished(success)
			if onJob then
				local ok, e = pcall(onJob, job, success)
				if not ok then log("node %d: %s", job.node, tostring(e)) end
			end
			answered(success)
		end
		local sent, err
		if job.conns then
			sent, err = pcall(sendNodeConfig, job.node, job.cfg, job.conns, job.tl, finished)
		else
			sent, err = pcall(send, job.node, job.tl, job.pref, finished)
		end
		if not sent then
			log("node %d: %s", job.node, tostring(err))
			answered(false)
		end
	end
end

---------------------------------------------------------------------------
-- Signs
---------------------------------------------------------------------------
-- A yield sign on each yielding approach (on a roundabout the yield + roundabout sign), as the
-- constructions imsvale_yield_sign.con / imsvale_yield_roundabout_sign.con (just the model). Once built it is a plain asset (ASSET_GROUP), not a construction (2026-10-18), and asset
-- groups can't be looped over, so the asset ids are kept in the game script's state (saved with
-- the game; game_mechanics/imsvale_yield_signs) and removed by id. Best effort: a sign that
-- fails is logged, it never undoes the yielding. Signs bulldozed by hand just drop out.

-- Sign style: the drop-down SIGN_STYLE_PARAM ("Sign style": International / Norwegian) in the
-- construction menu's parameter list, read with getCurrentParams(). That function returns the menu's
-- own parameters only: as a Toolbar parameter it read back nil (2026-10-18). Values are the 1-based
-- index of the chosen entry (the game's getParamDefaultValue returns defaultIndex as is). Changing
-- it while the tool is open restyles every junction's signs (restyleAll).
local SIGN_STYLE_PARAM = "imsvaleSignStyle"
-- Lane settings (see the header): checkboxes (a Yes / No setting is most compact as a checkbox,
-- user 2026-10-19), unticked by default: read 1 = unticked, 2 = ticked. Opt-in (user,
-- 2026-10-19): a player who doesn't look at the settings never loses their own lane work.
local LANE_PARAM = "imsvaleOverwriteLanes"
local DEDICATED_PARAM = "imsvaleDedicatedTurnLanes"
-- "Uninstall" (checkbox, General; priority road 48, 2026-10-20): while ticked, a window counts what
-- the mod has placed in the save and offers to remove all of it (removeAll), so the mod can be
-- disabled safely. A tool can't offer a plain button (../docs/GUI.md), hence the window.
local UNINSTALL_PARAM = "imsvaleUninstall"
-- Tabs (user, 2026-10-19), as the game's road tool switches its panel with icon buttons at the
-- top: SECTION_PARAM picks General / Roundabouts / Priority signs, and every other parameter is
-- shown only under its tab (checkEnabledFn returning "Hidden", as the game's street builder
-- hides parameters by mode, construction_react_util.tl).
local SECTION_PARAM = "imsvaleSection"
local SECTIONS = { general = 1, roundabout = 2, priority = 3 }
local function inSection(section)
	return function(values)
		return (values[SECTION_PARAM] or 1) == SECTIONS[section] and "Enabled" or "Hidden"
	end
end
-- "Roundabout exit": Style A (default) / Style B, see roundaboutLanes. The tooltips name the
-- right lane: with left-hand traffic support they must say "left" instead.
local EXIT_PARAM = "imsvaleRoundaboutExit"
local SIGN_STYLES = { "intl", "no" }          -- by parameter index; "no": Norwegian, tighter corners
local SIGN_BACK = 0.5          -- metres back from the junction edge along the approach (3 m stood
                               -- 2-3 m too far back on a 16 m town road, 2026-10-18)
local CLEAR_RAISED = 0.5       -- metres past the curb onto a raised sidewalk
local CLEAR_LEVEL = 1.0        -- metres past the curb where there is no raised sidewalk (a level
                               -- pedestrian strip, a shoulder's edge, or nothing)
local SIGN_GAME_SCRIPT = "imsvale_road_priority_yield::/game_mechanics/imsvale_yield_signs/imsvale_yield_signs.gs"
local SIGN_EVENT_ID = "imsvale_road_priority_yield"
local SIGN_EVENT_NAME = "imsvale_yield_signs.set"

-- Registered construction names by file name ("imsvale_yield_sign.con" etc.).
local signConNames = {}
local function signCon(file)
	if signConNames[file] then return signConNames[file] end
	for _, name in pairs(api.res.constructionRep.getAll(true)) do
		if tostring(name):sub(-#file - 1) == "/" .. file then signConNames[file] = name return name end
	end
end

-- Stored sign ids per junction node (string keys), read from the game script's state.
local function storedSigns()
	local ok, signs = pcall(function()
		local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(SIGN_GAME_SCRIPT)
		local comp = entity and api.engine.getComponent(entity, CT.GAME_SCRIPT)
		local state = comp and comp.state
		return type(state) == "table" and state.signs or nil
	end)
	local out = {}
	for key, entry in pairs(ok and type(signs) == "table" and signs or {}) do
		if type(entry) == "table" then
			-- { ids, style, round }; entries stored before priority road 17 were bare id lists.
			out[key] = entry.ids and entry or { ids = entry, style = "intl", round = false }
		end
	end
	return out
end

local function storeSigns(node, ids, style, round)
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(SIGN_GAME_SCRIPT, SIGN_EVENT_ID, SIGN_EVENT_NAME,
		{ node = node, signs = ids, style = style, round = round or false }))
end

-- "Follow lane edits" (experimental): the game script keeps the junctions this tool applied
-- yielding to, with a fingerprint of their lanes, and when the switch is on rebuilds a
-- junction's phases after its lanes change. The switch's value lives in the game script's state
-- (saved with the game): the tool sends it when it changes, and on every apply.
-- All messages go on the signs event with a `kind`: a save keeps the game script's subscriptions
-- from the version it was saved with, and the game script only subscribes when it has none, so
-- an event added later would never arrive in older saves (the diamonds didn't, 2026-10-19).

-- settings: what the junction was applied with ({ overwrite, dedicated, exitStyle, style, diamonds }),
-- for repairs after road edits.
local function registerJunction(job, settings)
	local param
	if job.remove then
		param = { node = job.node, remove = true }
	else
		local cfg = api.engine.getComponent(job.node, CT.BASE_NODE_CONFIG)
		param = { node = job.node, a = job.a, b = job.b, round = job.round, typeId = job.typeId,
			fp = phases.fingerprint(cfg), settings = settings,
			ph = phases.phaseFingerprint(cfg.laneConnections, cfg.crosswalks, cfg.trafficLightConfig.states) }
	end
	param.kind = "junction"
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(SIGN_GAME_SCRIPT, SIGN_EVENT_ID, SIGN_EVENT_NAME, param))
end

local function signFile(style, round)
	return (round and "imsvale_yield_roundabout_sign" or "imsvale_yield_sign") .. (style == "no" and "_no" or "") .. ".con"
end

-- A lane config carries pedestrians: its transport modes include PERSON. How a built road's
-- LaneConfig.transportModes is keyed isn't documented, so try the enum value, its name and the
-- number 0 (PERSON is the enum's first value); a raised lane (sidewalk) counts too.
local PERSON = nil
pcall(function() PERSON = api.type.enum.TransportMode.PERSON end)
local function isPedestrian(lc)
	if (lc.height or 0) > 0.05 then return true end
	local found = false
	pcall(function()
		local m = lc.transportModes
		for _, k in ipairs({ PERSON, "PERSON", 0 }) do
			if k ~= nil and m[k] and m[k] ~= 0 then found = true end
		end
	end)
	return found
end

-- How far from the road's centre line the curb is: the outer edge of the outermost lane that
-- isn't for pedestrians (driving lanes, and shoulders without transport modes, as on highways),
-- and whether a raised sidewalk lies beyond it. Assumes the road is symmetric about its centre.
local function curb(laneConfigs)
	local width = 0
	for _, lc in ipairs(laneConfigs) do width = width + lc.width end
	local left, outer, raised = -width / 2, 0, false
	for _, lc in ipairs(laneConfigs) do
		local right = left + lc.width
		if isPedestrian(lc) then
			if (lc.height or 0) > 0.05 then raised = true end
		else
			outer = math.max(outer, math.abs(left), math.abs(right))
		end
		left = right
	end
	return outer, raised, width
end

-- Where a sign stands for traffic coming in on `seg` towards `node`: SIGN_BACK back from the
-- junction edge (the approach's lanes end there, so bigger junctions push it out by themselves),
-- on the right of that traffic (right-hand traffic) just past the curb, facing the traffic (the
-- model's face is its -Y).
local function signTransf(seg, node)
	local edge, d = junctionEdge(seg, node)
	if not edge then return nil end
	local e = api.engine.getComponent(seg, CT.BASE_EDGE)
	local outer, raised, width = curb(e.laneConfigs)
	local lateral = outer + (raised and CLEAR_RAISED or CLEAR_LEVEL)
	log("sign on segment %d at node %d: road %.1f m, curb %.1f m from the centre, raised sidewalk %s -> %.1f m",
		seg, node, width, outer, tostring(raised), lateral)
	local right = { x = -d.y, y = d.x }
	local x = edge.x + d.x * SIGN_BACK + right.x * lateral
	local y = edge.y + d.y * SIGN_BACK + right.y * lateral
	local angle = (math.atan2 or math.atan)(d.x, -d.y)
	return api.type.Mat4f.rotZTransl(angle, api.type.Vec3f.new(x, y, edge.z))
end

-- Build sign constructions `file` at the given transforms, in one proposal; done(asset ids).
-- `label` names them in the log.
local function placeAt(transfs, file, name, label, done)
	local con = signCon(file)
	if not con or #transfs == 0 then return done({}) end
	local proposal = api.type.SimpleProposal.new()
	local list = {}
	for _, t in ipairs(transfs) do
		local ce = api.type.SimpleProposal.ConstructionEntity.new()
		ce.fileName = con
		ce.transf = t
		ce.params = { seed = 0 }
		ce.name = name
		ce.playerEntity = api.engine.util.getPlayer()
		list[#list + 1] = ce
	end
	proposal.constructionsToAdd = list
	-- As the player would build it first; refused (e.g. a collision with something by the road),
	-- again with ignoreErrors, as the game's mission code builds its constructions.
	local function send(ignoreErrors)
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, ignoreErrors, false), function(_, success, results)
			if not success and not ignoreErrors then return send(true) end
			local ids = {}
			for _, r in ipairs(results or {}) do
				local ent = type(r) == "table" and r[1] or r
				if api.engine.getComponent(ent, CT.ASSET_GROUP) then ids[#ids + 1] = ent end
			end
			if not success then log("%s: signs refused", label) end
			done(ids)
		end)
	end
	send(false)
end

-- Build signs for the given approaches of one junction; done(asset ids).
local function placeSigns(node, segs, file, done)
	local transfs = {}
	for _, seg in ipairs(segs) do
		local t = signTransf(seg, node)
		if t then transfs[#transfs + 1] = t end
	end
	placeAt(transfs, file, "Yield sign", "node " .. node, done)
end

-- Remove sign assets by id, in one proposal: the full api.type.Proposal's `toRemove` list takes
-- any entity, assets included. (api.engine.util.proposal.createProposalRemove is for
-- constructions: on a sign asset it failed an engine assertion, GetComponentDataIndex, 2026-10-18.)
local function removeSigns(ids)
	local list = {}
	for _, e in ipairs(ids or {}) do
		if api.engine.entityExists(e) and api.engine.getComponent(e, CT.ASSET_GROUP) then list[#list + 1] = e end
	end
	if #list == 0 then return end
	local proposal = api.type.Proposal.new()
	proposal.toRemove = list
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, true, false), function(_, success)
		if not success then log("signs %s: removal refused", table.concat(list, ",")) end
	end)
end

-- After the lights: each junction's signs follow its yielding. On removal (and before
-- re-placing) the stored ones go; yielding approaches get new ones.
local function updateSigns(plan, style)
	local stored = storedSigns()
	for _, j in ipairs(plan.junctions) do
		local key = tostring(j.node)
		local old = stored[key]
		if plan.remove then
			if j.removeHere and old then
				removeSigns(old.ids)
				storeSigns(j.node, {})
			end
		elseif j.states then
			if old then removeSigns(old.ids) end
			local segs = {}
			for seg, role in pairs(j.new or {}) do
				if role == "yield" then segs[#segs + 1] = seg end
			end
			local node, round = j.node, plan.round or false
			placeSigns(node, segs, signFile(style, round), function(ids)
				log("node %d: %d signs", node, #ids)
				storeSigns(node, ids, style, round)
			end)
		end
	end
end

-- Every stored junction whose signs are in another style gets them replaced (the style
-- drop-down changed). Junctions no longer using our light type are left alone; their entries
-- go when the yielding is removed with the tool.
local function restyleAll(style)
	local typeId = invisibleType()
	local count = 0
	for key, entry in pairs(storedSigns()) do
		local node = tonumber(key)
		if entry.style ~= style and node and api.engine.entityExists(node) then
			local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
			if cfg and typeId and api.engine.getComponent(node, CT.BASE_NODE_TRAFFIC_LIGHT)
					and cfg.trafficLightConfig.trafficLightType == typeId then
				local segs = {}
				for seg, role in pairs(configuredRoles(cfg)) do
					if role == "yield" then segs[#segs + 1] = seg end
				end
				removeSigns(entry.ids)
				local round = entry.round or false
				placeSigns(node, segs, signFile(style, round), function(ids)
					storeSigns(node, ids, style, round)
				end)
				count = count + 1
			end
		end
	end
	log("sign style %s: restyled %d junctions", style, count)
end

---------------------------------------------------------------------------
-- Priority signs along priority roads (2026-10-19, rules agreed with the user)
---------------------------------------------------------------------------
-- Diamonds (imsvale_priority_sign.con) on the right of each direction of travel, facing it, just
-- past the curb as the yield signs. Distances along the road, across plain nodes:
-- Distances between junction edges (see diamondPlaces), not node centres. One rule for every sign
-- (simplified by the user, 2026-10-19): min(spacing, gap / 2) from where the stretch begins (the
-- previous junction's edge, or the road's start), gap = the stretch's visible length to the next
-- junction's edge or the road's end; +- jitter, fixed per node from its id, kept inside the stretch.
-- - start: where the priority road begins (each end, for traffic driving onto it), always;
-- - repeat: after every junction, unless the stretch ahead is shorter than DIAMOND_MIN_GAP: a run
--   of close junctions gets one sign, after its last junction.
-- Not on roundabouts. No end-of-priority signs: the game has no right-hand rule to return to.
-- Stored per node in the game script, apart from the yield signs (the style switch leaves them
-- alone): repeats under their junction, start signs under the road's end node.
local DIAMOND_FILE = "imsvale_priority_sign.con"
local DIAMOND_SPACING = 60.0     -- metres from the start of the stretch (halfway on a stretch under twice this)
local DIAMOND_JITTER = 2.0       -- +- metres, fixed per node
local DIAMOND_MIN_GAP = 60.0     -- a stretch shorter than this gets no repeat sign (a 90 m block is
                                 -- very roughly 60 m of road between junction edges, user)
local DIAMOND_STEP = 2.0         -- metres between samples of the road's curve

-- Priority sign settings: sliders under the tool's Priority signs tab (user, 2026-10-19; they were
-- in a window of their own first, see ../docs/GUI.md). The DIAMOND_* values above are the
-- defaults. Panel values are GUI session state: they last while the game runs, not with a save
-- (a tool can't set its panel values, so a saved value couldn't be shown). The tool reads them
-- every step into panelDiamonds; placement reads that. A change that has settled rebuilds every
-- road's signs (DIAMOND_REBUILD_STEPS).
local DIAMOND_SETTINGS = {
	{ key = "spacing", name = "Spacing", default = DIAMOND_SPACING, min = 10, max = 200, step = 5 },
	{ key = "jitter", name = "Variation", default = DIAMOND_JITTER, min = 0, max = 20, step = 1 },
	{ key = "minGap", name = "Minimum segment length", default = DIAMOND_MIN_GAP, min = 0, max = 300, step = 5 },
}
for _, d in ipairs(DIAMOND_SETTINGS) do d.param = "imsvaleDiamond_" .. d.key end
local DIAMOND_REBUILD_STEPS = 90 -- GUI steps a changed setting must stay put before signs are rebuilt (~1.5 s)

local panelDiamonds = nil -- the sliders' values, read by the tool every step (GUI module state)

local function diamondSettings()
	local out = {}
	for _, d in ipairs(DIAMOND_SETTINGS) do
		out[d.key] = panelDiamonds and tonumber(panelDiamonds[d.key]) or d.default
	end
	return out
end

-- The sliders, for getDefinition: numbers from min to max by step, default at the nearest number.
local function diamondParams()
	local out = {}
	for _, d in ipairs(DIAMOND_SETTINGS) do
		local numbers, default, best = {}, 1, math.huge
		for v = d.min, d.max, d.step do
			numbers[#numbers + 1] = v + 0.0
			if math.abs(v - d.default) < best then best, default = math.abs(v - d.default), #numbers end
		end
		out[#out + 1] = {
			group = d.param,
			key = d.param,
			name = d.name,
			numbers = numbers,
			defaultIndex = default,
			resetOnCategoryChange = false,
			uiType = api.type.enum.ScriptParamType.Slider,
			yearFrom = 0,
			yearTo = 0,
			location = api.type.enum.ScriptParamLocation.Default,
			preserveValueInAllCategories = true,
			checkEnabledFn = inSection("priority"),
			formatValueFn = function(v) return (d.key == "jitter" and "± " or "") .. math.floor(v + 0.5) .. " m" end,
		}
	end
	return out
end

local function storedDiamonds()
	local ok, d = pcall(function()
		local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(SIGN_GAME_SCRIPT)
		local comp = entity and api.engine.getComponent(entity, CT.GAME_SCRIPT)
		local state = comp and comp.state
		return type(state) == "table" and state.diamonds or nil
	end)
	return ok and type(d) == "table" and d or {}
end

local function storeDiamonds(node, ids)
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(SIGN_GAME_SCRIPT, SIGN_EVENT_ID, SIGN_EVENT_NAME,
		{ kind = "diamonds", node = node, ids = ids }))
end

-- The priority road's segments in order from one end to the other, and the nodes between them
-- (#nodes = #segs + 1; on a loop the last node is the first).
function chainOf(plan) -- assigns the local declared before planFrom
	local segs = {}
	for i = #plan.backSegs, 1, -1 do segs[#segs + 1] = plan.backSegs[i] end
	segs[#segs + 1] = plan.seg0
	for _, s in ipairs(plan.fwdSegs) do segs[#segs + 1] = s end
	local function ends(seg)
		local e = api.engine.getComponent(seg, CT.BASE_EDGE)
		return e.node0, e.node1
	end
	local a0, a1 = ends(segs[1])
	local start = a0
	if #segs > 1 then
		local b0, b1 = ends(segs[2])
		start = (a0 == b0 or a0 == b1) and a1 or a0
	end
	local nodes, cur = { start }, start
	for i, seg in ipairs(segs) do
		local n0, n1 = ends(seg)
		cur = (n0 == cur) and n1 or n0
		nodes[i + 1] = cur
	end
	return segs, nodes
end

-- Samples along the chain: { x, y, z, s (metres from the start), seg }, and each node's s.
local function sampleChain(segs, nodes)
	local pts, nodeS = {}, { 0 }
	local total = 0
	for i, seg in ipairs(segs) do
		local e = api.engine.getComponent(seg, CT.BASE_EDGE)
		local forward = e.node0 == nodes[i]
		local len = e.distance and e.distance > 0 and e.distance
			or math.sqrt((e.position1.x - e.position0.x) ^ 2 + (e.position1.y - e.position0.y) ^ 2)
		local n = math.max(2, math.ceil(len / DIAMOND_STEP))
		local prev = nil
		for k = 0, n do
			local u = k / n
			local t = forward and u or 1 - u
			local q = hermite(e.position0, e.position1, e.tangent0, e.tangent1, t)
			local z = e.position0.z + (e.position1.z - e.position0.z) * t
			if prev then total = total + math.sqrt((q.x - prev.x) ^ 2 + (q.y - prev.y) ^ 2) end
			if k > 0 or i == 1 then pts[#pts + 1] = { x = q.x, y = q.y, z = z, s = total, seg = seg } end
			prev = q
		end
		nodeS[i + 1] = total
	end
	return pts, nodeS, total
end

-- Position and unit direction (towards increasing s) at s, and the segment there.
local function pointAt(pts, s)
	for k = 2, #pts do
		if pts[k].s >= s or k == #pts then
			local a, b = pts[k - 1], pts[k]
			local span = math.max(b.s - a.s, 1e-6)
			local f = math.max(0, math.min(1, (s - a.s) / span))
			local dx, dy = b.x - a.x, b.y - a.y
			local l = math.max(math.sqrt(dx * dx + dy * dy), 1e-6)
			return { x = a.x + dx * f, y = a.y + dy * f, z = a.z + (b.z - a.z) * f }, { x = dx / l, y = dy / l }, b.seg
		end
	end
	return nil
end

-- A sign at s for traffic heading dir (+1: increasing s, -1: decreasing): on that traffic's
-- right just past the curb, facing it (the model's face is its -Y).
local function diamondTransf(pts, s, dir)
	local p, t, seg = pointAt(pts, s)
	if not p then return nil end
	local h = { x = t.x * dir, y = t.y * dir }
	local outer, raised = curb(api.engine.getComponent(seg, CT.BASE_EDGE).laneConfigs)
	local lateral = outer + (raised and CLEAR_RAISED or CLEAR_LEVEL)
	local x, y = p.x + h.y * lateral, p.y - h.x * lateral
	local angle = (math.atan2 or math.atan)(-h.x, h.y)
	return api.type.Mat4f.rotZTransl(angle, api.type.Vec3f.new(x, y, p.z))
end

-- Where the diamonds go: { ["node:segment"] = { { s, dir }, ... } }, keyed by the node they
-- hang on and the road segment they stand beside (the one leaving that node in their direction),
-- so two priority roads crossing at a node keep their signs apart. Also every such key along
-- the road (for clearing it).
local function diamondPlaces(plan)
	local cfg = diamondSettings()
	local jitter = math.floor(cfg.jitter + 0.5)
	local segs, nodes = chainOf(plan)
	local pts, nodeS, L = sampleChain(segs, nodes)
	local loop = plan.loop
	-- Distances go between junction edges, where the segments' lanes end and the junction's paved
	-- area begins, not between node centres: the visible road between two junctions (user,
	-- 2026-10-19). reach: how far a junction extends into a segment from its node.
	local function reach(seg, node)
		local ok, d = pcall(function()
			local p = junctionEdge(seg, node)
			local np = api.engine.getComponent(node, CT.BASE_NODE).position
			return p and math.sqrt((p.x - np.x) ^ 2 + (p.y - np.y) ^ 2) or 0
		end)
		return ok and d or 0
	end
	local function isJunction(node)
		return #api.engine.system.streetSystem.getNodeStreetSegments(node) >= 3
	end
	-- Junctions along the chain: { s (node), sIn / sOut (its edges along the road), node, i }.
	local js = {}
	local function junctionAt(i)
		local segIn = segs[i - 1] or segs[#segs]
		js[#js + 1] = { s = nodeS[i], node = nodes[i], i = i,
			sIn = nodeS[i] - reach(segIn, nodes[i]), sOut = nodeS[i] + reach(segs[i], nodes[i]) }
	end
	if loop and isJunction(nodes[1]) then junctionAt(1) end
	for i = 2, #nodes - 1 do
		if isJunction(nodes[i]) then junctionAt(i) end
	end
	-- Where the road itself begins and ends: a junction's edge, or the node at a dead end.
	local startS = (not loop and isJunction(nodes[1])) and reach(segs[1], nodes[1]) or 0
	local endS = (not loop and isJunction(nodes[#nodes])) and L - reach(segs[#segs], nodes[#nodes]) or L
	local places = {}
	-- The segment leaving node i in direction dir.
	local function segFrom(i, dir)
		if dir > 0 then return segs[i] end
		return segs[i - 1] or segs[#segs]
	end
	local function add(i, s, dir)
		if loop then s = s % L end
		if s > 0 and s < L then
			local key = nodes[i] .. ":" .. segFrom(i, dir)
			places[key] = places[key] or {}
			table.insert(places[key], { s = s, dir = dir })
		end
	end
	local keys = {}
	for i, seg in ipairs(segs) do
		keys[#keys + 1] = nodes[i] .. ":" .. seg
		keys[#keys + 1] = nodes[i + 1] .. ":" .. seg
	end
	-- Distance from the start of a stretch `gap` long: min(spacing, gap / 2), +- the node's jitter,
	-- kept inside the stretch.
	local function from(gap, node)
		local d = math.min(cfg.spacing, gap / 2) + (node % (2 * jitter + 1)) - jitter
		return math.max(1, math.min(gap - 1, d))
	end
	if not loop then
		local first, lastJ = js[1], js[#js]
		local toFirst = (first and first.sIn or endS) - startS
		add(1, startS + from(toFirst, nodes[1]), 1)
		local fromLast = endS - (lastJ and lastJ.sOut or startS)
		add(#nodes, endS - from(fromLast, nodes[#nodes]), -1)
	end
	for k, j in ipairs(js) do
		local nextIn = js[k + 1] and js[k + 1].sIn or (loop and js[1].sIn + L) or endS
		local ahead = nextIn - j.sOut
		if ahead >= cfg.minGap then add(j.i, j.sOut + from(ahead, j.node), 1) end
		local prevOut = js[k - 1] and js[k - 1].sOut or (loop and js[#js].sOut - L) or startS
		local behind = j.sIn - prevOut
		if behind >= cfg.minGap then add(j.i, j.sIn - from(behind, j.node), -1) end
	end
	return places, pts, nodes, keys
end

-- After the lights: the road's diamonds follow its yielding. The road's own diamonds (keys of
-- its nodes and segments) go; on applying, new ones are placed. Entries stored per node only
-- (priority road 25-26) are cleared for every node of the road.
local function updateDiamonds(plan)
	if plan.round then return end
	local stored = storedDiamonds()
	local places, pts, nodes, keys = diamondPlaces(plan)
	local clear = {}
	if plan.remove then
		-- Only the removed stretch: its segments' keys, and per-node entries of its nodes.
		local removed, nodeSet = {}, {}
		for _, x in ipairs(plan.removeSegs or {}) do
			removed[tostring(x)] = true
			local e = api.engine.getComponent(x, CT.BASE_EDGE)
			if e then nodeSet[e.node0] = true nodeSet[e.node1] = true end
		end
		for _, key in ipairs(keys) do
			if removed[key:match(":(.*)$") or ""] then clear[#clear + 1] = key end
		end
		for node in pairs(nodeSet) do clear[#clear + 1] = tostring(node) end
	else
		for _, key in ipairs(keys) do clear[#clear + 1] = key end
		for _, node in ipairs(nodes) do clear[#clear + 1] = tostring(node) end
	end
	for _, key in ipairs(clear) do
		local old = stored[key]
		if type(old) == "table" and #old > 0 then
			removeSigns(old)
			storeDiamonds(key, {})
			stored[key] = nil
		end
	end
	if plan.remove then return end
	local count = 0
	for key, list in pairs(places) do
		local transfs = {}
		for _, place in ipairs(list) do
			local t = diamondTransf(pts, place.s, place.dir)
			if t then transfs[#transfs + 1] = t end
		end
		count = count + #transfs
		placeAt(transfs, DIAMOND_FILE, "Priority sign", "diamonds at " .. key, function(ids)
			storeDiamonds(key, ids)
		end)
	end
	log("priority signs: %d", count)
end

-- Place every road's priority signs again with the current settings (the settings window's
-- Rebuild). Roads are found through the stored signs: each key's segment gives the road (planFrom),
-- each road once. A road still yielding gets new signs; one whose yielding is gone only loses its
-- leftover signs.
local function rebuildAllDiamonds()
	local done, roads = {}, 0
	for key in pairs(storedDiamonds()) do
		local seg = tonumber(tostring(key):match(":(%d+)$") or "")
		if seg and not done[seg] and isEdge(seg) then
			local ok, plan = pcall(planFrom, seg)
			if ok and plan and not plan.round then
				for _, x in ipairs(plan.segs) do done[x] = true end
				local applied = false
				for _, j in ipairs(plan.junctions) do if j.ours then applied = true end end
				plan.remove = not applied
				plan.removeSegs = plan.segs
				local dOk, err = pcall(updateDiamonds, plan)
				if not dOk then log("rebuild at segment %d: %s", seg, tostring(err)) end
				roads = roads + 1
			end
		end
	end
	log("priority signs rebuilt on %d roads", roads)
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

local transparency = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/transparency.gres")).data
local selectionGres = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/selection_colors.gres")).data

local lastLog = nil -- plans are worked out on every redraw: log one only when it changes

-- Configured junctions (light type = ours) and their icons, rescanned every
-- CONFIGURED_REFRESH seconds and right after an apply / remove. GUI module state persists for
-- the session. getEntitiesWithComponent can't loop over traffic lights, so scan the street
-- node map.
local configured = { time = nil, version = 0, junctions = {} }

local function refreshConfigured()
	local now = api.util.getApplicationTime()
	if configured.time and now - configured.time < CONFIGURED_REFRESH then return end
	configured.time = now
	configured.version = configured.version + 1
	local typeId = invisibleType()
	local list = {}
	if typeId then
		for node, segs in pairs(api.engine.system.streetSystem.getNode2SegmentMap()) do
			if #segs >= 3 and api.engine.getComponent(node, CT.BASE_NODE_TRAFFIC_LIGHT) then
				local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
				if cfg and cfg.trafficLightConfig.trafficLightType == typeId then
					local icons = {}
					for seg, kind in pairs(configuredRoles(cfg)) do
						local p = approachPoint(seg, node)
						if p then
							p.kind, p.cross, p.shift = kind, false, 0
							icons[#icons + 1] = p
						end
					end
					list[#list + 1] = { node = node, icons = icons }
				end
			end
		end
	end
	configured.junctions = list
end

local function configuredChanged()
	configured.time = nil
end

-- The icon layer: a full-screen, mouse-transparent layer (as the town window's legend, via
-- builtin.FullScreenComponent in the ActionDescriptor) with images placed at screen positions.
-- - A FloatingLayoutChild's h / v place it as fractions of the layout (0..1, as the positions
--   the game's CalloutContainer gets from getPosition), and the item's anchorPoint is the part
--   of it placed there. world2Screen gives pixels, so divide by api.gui.camera.getSize().
-- - The layout fills the screen only through CSS (gravity {-1, -1} in
--   imsvale_road_priority_yield.css.lua; StyleSheet has no gravity). Without it the layout
--   collapsed at the left edge and the icons piled up there (2026-10-17).
-- - Every element is mouse-transparent (meta.mouseTransparent; react.setMouseTransparent only
--   covers the recipe's own component): hovering an image made the tool flicker (2026-10-17).
-- - Size falls with the distance from the camera (ICON_SIZE at ICON_REF_DISTANCE, ICON_TAPER, clamped).
--   Icons further from the camera's centre than the range (which grows with the camera's
--   height) are hidden, and fade out before that, so close in the horizon stays clear.
-- - An icon that goes away gets a second element at the same place, drawn on top: the
--   bulldozer-style highlight box.
-- - Re-projected every step, so the icons follow the camera.
-- param: planIcons (the hovered road's preview), planNodes (its junctions, whose configured
-- icons the preview replaces). The sign style comes from iconStyle.
local UninstallPresence -- (param { gameCtx }): defined with Uninstall below, mounted here
local IconOverlay = react.RegisterRecipe("ImsvaleRoadPriorityIcons", function(param)
	react.setMouseTransparent(true)

	local function layout()
		refreshConfigured()
		local icons = {}
		for _, ic in ipairs(param.planIcons or {}) do icons[#icons + 1] = ic end
		local planNodes = param.planNodes or {}
		for _, j in ipairs(configured.junctions) do
			if not planNodes[j.node] then
				for _, ic in ipairs(j.icons) do icons[#icons + 1] = ic end
			end
		end
		local cam = api.gui.camera
		local size = cam.getSize()
		local w, h = math.max(size.x, 1), math.max(size.y, 1)
		local eye, centre = cam.getEye(), cam.getCenter()
		local range = math.max(RANGE_MIN, (cam.getHeightAboveTerrain() or 0) * RANGE_PER_HEIGHT)
		local placed = {}
		for _, ic in ipairs(icons) do
			if #placed >= MAX_ICONS then break end
			local horizontal = math.sqrt((ic.x - centre.x) ^ 2 + (ic.y - centre.y) ^ 2)
			if horizontal <= range then
				local z = ic.z + ICON_LIFT
				local dist = math.sqrt((ic.x - eye.x) ^ 2 + (ic.y - eye.y) ^ 2 + (z - eye.z) ^ 2)
				local scaled = ICON_SIZE * (ICON_REF_DISTANCE / math.max(dist, 1)) ^ ICON_TAPER
				local px = math.floor(math.max(ICON_MIN_SIZE, math.min(ICON_MAX_SIZE, scaled)) + 0.5)
				local alpha = horizontal <= range * FADE_FROM and 1 or (range - horizontal) / (range * (1 - FADE_FROM))
				alpha = math.floor(alpha * 20 + 0.5) / 20
				local s = cam.world2Screen(api.type.Vec3f.new(ic.x, ic.y, z))
				local fx = (s.x + ic.shift * REPLACED_SHIFT * px) / w
				local fy = s.y / h
				if alpha > 0 and fx >= 0 and fx <= 1 and fy >= 0 and fy <= 1 then
					placed[#placed + 1] = { x = fx, y = fy, size = px, alpha = alpha, kind = ic.kind, cross = ic.cross }
				end
			end
		end
		return placed
	end

	local placed = layout()
	local key = react.useState("")
	react.onStep(function()
		local parts = { tostring(configured.version), iconStyle }
		for _, p in ipairs(layout()) do
			parts[#parts + 1] = string.format("%.4f,%.4f,%d,%.2f", p.x, p.y, p.size, p.alpha)
		end
		local k = table.concat(parts, ";")
		if k ~= key:old() then key:set(k) end
	end)

	local children = {}
	local function image(i, part, p, path)
		children[#children + 1] = builtin.FloatingLayoutChild{
			localKey = "icon" .. i .. part,
			h = p.x,
			v = p.y,
			item = builtin.ImageView{
				path = path,
				meta = {
					mouseTransparent = true,
					styleSheet = styleutil.makeStyle{
						anchorPoint = { 0.5, 0.5 },
						size = { p.size, p.size },
						color = { 1, 1, 1, p.alpha },
					},
				},
			},
		}
	end
	-- The bulldozer's highlight look: the engine draws it; its colour is the game's
	-- construction_colors.gres Bulldozer (gold #FFD700, its selection circle at 0.75 opacity).
	local function highlight(i, p)
		local box = math.floor(p.size * HIGHLIGHT_PAD + 0.5)
		local w = HIGHLIGHT_WIDTH
		children[#children + 1] = builtin.FloatingLayoutChild{
			localKey = "icon" .. i .. "highlight",
			h = p.x,
			v = p.y,
			item = builtin.Component{
				meta = {
					mouseTransparent = true,
					styleSheet = styleutil.makeStyle{
						anchorPoint = { 0.5, 0.5 },
						size = { box, box },
						backgroundColor = color_util.withTransparency(constructionColors.Bulldozer, HIGHLIGHT_FILL * p.alpha),
						borderColor = color_util.withTransparency(constructionColors.Bulldozer, HIGHLIGHT_BORDER * p.alpha),
						borderWidth = { w, w, w, w },
					},
				},
			},
		}
	end
	for i, p in ipairs(placed) do
		image(i, "", p, iconFor(p.kind, iconStyle))
		if p.cross then highlight(i, p) end
	end
	-- Uninstall's window: its presence is mounted inside this overlay, because an action may have
	-- only one FullScreenComponent ("Must not specify more than 1 FullScreenComponent", a crash,
	-- 2026-10-20).
	if UninstallPresence and param.gameCtx then
		children[#children + 1] = builtin.FloatingLayoutChild{
			localKey = "uninstall",
			h = 0,
			v = 0,
			item = UninstallPresence({ gameCtx = param.gameCtx }),
		}
	end
	return builtin.FloatingLayout{ meta = { mouseTransparent = true }, children = children }
end)

local lastStyle = nil -- the drop-down's value last seen (GUI module state)
-- The panel's values as last seen, per key (GUI module state). getCurrentParams() leaves out the
-- parameters hidden by the tabs (construction.tl getCurrentValues(false)), so a setting on another
-- tab read as missing: applying from the Roundabouts tab took "Overwrite lanes" as unticked
-- (2026-10-19). A setting can only change while its tab shows, so its last seen value is current.
-- After a UI reload this is empty until each tab has been shown: until then a setting counts as
-- its default.
local seenParams = {}
local function panel(params)
	pcall(function()
		for k, v in pairs(params.getCurrentParams()) do seenParams[k] = v end
	end)
	return seenParams
end
local diamondWatch = {} -- the sliders' values last seen, and steps since they changed (GUI module state)

---------------------------------------------------------------------------
-- Uninstall (priority road 48, 2026-10-20)
---------------------------------------------------------------------------
-- Removing the mod from a save leaves every sign a placeholder box and every junction on our
-- light type, which crashes the game when it rebuilds one (docs/release-checklist.md, item 2).
-- removeAll takes it all out first: every node on our light type (found by scanning all street
-- nodes, not the registry, which may be incomplete) gets its light removed and the game's own type;
-- every recorded sign goes; the game script's records are cleared. Lanes stay as they are.

-- What the mod has in the save: nodes on our light type, recorded sign assets.
local function uninstallCounts()
	local typeId = invisibleType()
	local nodes = {}
	if typeId then
		for node in pairs(api.engine.system.streetSystem.getNode2SegmentMap()) do
			local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
			if cfg and cfg.trafficLightConfig.trafficLightType == typeId then nodes[#nodes + 1] = node end
		end
	end
	local signs = 0
	for _, entry in pairs(storedSigns()) do
		for _, e in ipairs(entry.ids or {}) do
			if api.engine.entityExists(e) then signs = signs + 1 end
		end
	end
	for _, ids in pairs(storedDiamonds()) do
		for _, e in ipairs(type(ids) == "table" and ids or {}) do
			if api.engine.entityExists(e) then signs = signs + 1 end
		end
	end
	return nodes, signs
end

local function removeAll()
	local nodes = uninstallCounts()
	local base, refused = TAKEN_OFF_TYPE, 0
	for _, node in ipairs(nodes) do
		local ok, err = pcall(function()
			local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
			local tl = cfg.trafficLightConfig:clone()
			tl.states = {}
			tl.trafficLightType = base
			send(node, tl, takenOffPreference(node, cfg), function(success)
				if not success then
					refused = refused + 1
					log("uninstall: node %d refused", node)
				end
			end)
		end)
		if not ok then log("uninstall: node %d: %s", node, tostring(err)) end
	end
	local ids = 0
	for _, entry in pairs(storedSigns()) do
		removeSigns(entry.ids)
		ids = ids + #(entry.ids or {})
	end
	for _, list in pairs(storedDiamonds()) do
		if type(list) == "table" then
			removeSigns(list)
			ids = ids + #list
		end
	end
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(SIGN_GAME_SCRIPT, SIGN_EVENT_ID, SIGN_EVENT_NAME, { kind = "reset" }))
	configuredChanged()
	log("uninstall: %d junctions, %d signs", #nodes, ids)
end

local UNINSTALL_RECOUNT = 60 -- steps between counts while the window is open

-- Placeholders (priority road 55, 2026-10-21; user: a universal cleanup, two steps like Traffic
-- Light Tools' Remove all): every asset group in the world whose models are all placeholders.
-- A model the game can't load (its mod removed) is shown as a placeholder model, whose file is
-- under ::/placeholders/ (as base/model_metadata_util.lua tells them apart). They can't be traced
-- back to the model they replace, so this takes every mod's, not just ours. Asset groups can't be
-- looped over: the world is searched with the octree (one box over everything). A group holding
-- placeholders among real models (e.g. a forest with one missing tree model) is only counted.
local PLACEHOLDER_PREFIX = "::/placeholders/"
local WORLD_EXTENT = 100000 -- m, half the search box's side; far beyond any map
local REMOVE_BATCH = 200    -- asset groups per removal command
local placeholders = { ids = nil, mixed = 0, error = nil } -- the last search (GUI module state)

local function findPlaceholders()
	local isPlaceholder = {} -- model id -> bool, cached
	local function placeholder(modelId)
		local v = isPlaceholder[modelId]
		if v == nil then
			local name = ""
			pcall(function() name = tostring(api.res.modelRep.getName(modelId)) end)
			v = name:sub(1, #PLACEHOLDER_PREFIX) == PLACEHOLDER_PREFIX
			isPlaceholder[modelId] = v
		end
		return v
	end
	local ids, mixed, seen = {}, 0, {}
	-- api.type.Box3f is nil in GUI scripts and the console (2026-10-21), and the game's scripts
	-- never build one; they read them from BOUNDING_VOLUME. So borrow one from any entity that has
	-- a bounding volume (a street segment, else a construction) and stretch it over the world.
	local box = nil
	if api.type.Box3f then box = api.type.Box3f.new() end
	local function borrow(entity)
		if box then return end
		local bv = api.engine.getComponent(entity, CT.BOUNDING_VOLUME)
		if bv and bv.bbox then box = bv.bbox end
	end
	for _, segs in pairs(api.engine.system.streetSystem.getNode2SegmentMap()) do
		for _, seg in ipairs(segs) do borrow(seg) end
		if box then break end
	end
	if not box then
		for _, e in ipairs(api.engine.getEntitiesWithComponent(CT.CONSTRUCTION)) do
			borrow(e)
			if box then break end
		end
	end
	if not box then error("no bounding box to borrow") end
	box.min = api.type.Vec3f.new(-WORLD_EXTENT, -WORLD_EXTENT, -WORLD_EXTENT)
	box.max = api.type.Vec3f.new(WORLD_EXTENT, WORLD_EXTENT, WORLD_EXTENT)
	api.engine.system.octreeSystem.findIntersectingEntities(box, function(entity)
		if seen[entity] then return end
		seen[entity] = true
		if not api.engine.getComponent(entity, CT.ASSET_GROUP) then return end
		local list = api.engine.getComponent(entity, CT.MODEL_INSTANCE_LIST)
		if not list then return end
		local total, found = 0, 0
		for _, inst in ipairs(list.fatInstances or {}) do
			total = total + 1
			if placeholder(inst.modelId) then found = found + 1 end
		end
		for _, inst in ipairs(list.thinInstances or {}) do
			total = total + 1
			if placeholder(inst.modelId) then found = found + 1 end
		end
		if found > 0 and found == total then
			ids[#ids + 1] = entity
		elseif found > 0 then
			mixed = mixed + 1
		end
	end)
	log("placeholders: %d asset groups, %d more mixed with other models (left alone)", #ids, mixed)
	return ids, mixed
end

local function removePlaceholders(ids)
	for i = 1, #ids, REMOVE_BATCH do
		local list = {}
		for k = i, math.min(#ids, i + REMOVE_BATCH - 1) do
			if api.engine.entityExists(ids[k]) then list[#list + 1] = ids[k] end
		end
		if #list > 0 then
			local proposal = api.type.Proposal.new()
			proposal.toRemove = list
			api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, true, false), function(_, success)
				if not success then log("placeholders: removal of %d refused", #list) end
			end)
		end
	end
	log("placeholders: removing %d", #ids)
end

local UninstallContent = react.RegisterRecipe("ImsvaleRoadPriorityUninstallContent", function()
	local counts = react.useState(nil)
	local steps = react.useRef(0)
	react.onStep(function()
		local n = steps:get()
		steps:set(n + 1)
		if n % UNINSTALL_RECOUNT ~= 0 then return end
		local ok, nodes, signs = pcall(uninstallCounts)
		if ok then
			local c = { junctions = #nodes, signs = signs }
			local old = counts:old()
			if not old or old.junctions ~= c.junctions or old.signs ~= c.signs then counts:set(c) end
		end
	end)
	local c = counts:old() or { junctions = 0, signs = 0 }
	local found = react.useState(0) -- bumped after each search or removal, to redraw
	local rows = {
		builtin.TextView{ meta = { class = "imsvale-setting-row" }, text = string.format("Junctions: %d", c.junctions) },
		builtin.TextView{ meta = { class = "imsvale-setting-row" }, text = string.format("Signs: %d", c.signs) },
		builtin.Button{
			meta = { class = "imsvale-setting-button, imsvale-uninstall-button" },
			content = builtin.TextView{ text = "Remove all" },
			onClick = function()
				local ok, err = pcall(removeAll)
				if not ok then log("uninstall failed: %s", tostring(err)) end
				steps:set(1) -- recount after the commands have had a moment
			end,
		},
	}
	-- Placeholders: Find, then Remove (N).
	local text
	if placeholders.error then
		text = "Placeholders: search failed"
	elseif placeholders.ids == nil then
		text = "Placeholders: ?"
	else
		text = string.format("Placeholders: %d", #placeholders.ids)
	end
	rows[#rows + 1] = builtin.TextView{ meta = { class = "imsvale-uninstall-section" }, text = text }
	if placeholders.ids and #placeholders.ids > 0 then
		rows[#rows + 1] = builtin.Button{
			meta = { class = "imsvale-setting-button, imsvale-uninstall-button" },
			content = builtin.TextView{ text = string.format("Remove %d", #placeholders.ids) },
			onClick = function()
				local ok, err = pcall(removePlaceholders, placeholders.ids)
				if not ok then log("placeholders: %s", tostring(err)) end
				placeholders.ids = nil
				found:set(found:old() + 1)
			end,
		}
	else
		rows[#rows + 1] = builtin.Button{
			meta = { class = "imsvale-setting-button, imsvale-uninstall-button" },
			content = builtin.TextView{ text = "Find" },
			onClick = function()
				local ok, ids, mixed = pcall(findPlaceholders)
				if ok then
					placeholders.ids, placeholders.mixed, placeholders.error = ids, mixed, nil
				else
					placeholders.ids, placeholders.error = nil, tostring(ids)
					log("placeholders: search failed: %s", tostring(ids))
				end
				found:set(found:old() + 1)
			end,
		}
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = rows }
end)

-- The window's state (GUI module state): `wanted` is the checkbox as the action last read it,
-- `dismissed` the window's X (until the box is unticked), `open` whether it's up.
local uninstall = { wanted = false, dismissed = false, open = false, wc = nil }

local UninstallWindow = react.RegisterWrapperRecipe("ImsvaleRoadPriorityUninstallWindow", builtin.Window, function(param)
	return builtin.Window{
		meta = { class = "imsvale-uninstall" },
		title = "Uninstall",
		closable = true,
		onClose = function() uninstall.dismissed = true end,
		movable = true,
		content = UninstallContent{},
	}
end)

local function closeUninstall()
	if uninstall.open and uninstall.wc then
		pcall(function() uninstall.wc.removeAllWindows(UninstallWindow) end)
	end
	uninstall.open = false
end

-- Mounted in the icon overlay for as long as the tool is in use. Each step it follows the
-- checkbox: ticked opens the window, unticked or the window's X closes it; unmounting (the tool
-- closed) closes it too. Mounting it only while ticked didn't close the window on untick
-- (priority road 49-52, 2026-10-21): the overlay's param isn't refreshed by a panel change alone.
UninstallPresence = react.RegisterRecipe("ImsvaleRoadPriorityUninstallPresence", function(param)
	react.setMouseTransparent(true)
	react.onMount(function()
		pcall(function() uninstall.wc = param.gameCtx.windowContainer:get():getApi() end)
		if not uninstall.wc then log("uninstall: no window container") end
	end)
	react.onStep(function()
		if not uninstall.wanted then uninstall.dismissed = false end
		local show = uninstall.wanted and not uninstall.dismissed
		if show and not uninstall.open and uninstall.wc then
			local ok, err = pcall(function() uninstall.wc.addSingletonWindow(UninstallWindow, {}) end)
			if ok then uninstall.open = true else log("uninstall window: %s", tostring(err)) end
		elseif not show and uninstall.open then
			closeUninstall()
		end
	end)
	react.onUnmount(closeUninstall)
	return builtin.FloatingLayout{ meta = { mouseTransparent = true }, children = {} }
end)

local PriorityRoadAction = react.RegisterRecipe("ImsvalePriorityRoadAction", function(params)
	local revision = react.useState(0)
	local message = react.useState(nil)
	local pending = react.useState(false)

	local function currentStyle()
		local raw = nil
		pcall(function() raw = panel(params)[SIGN_STYLE_PARAM] end)
		return SIGN_STYLES[raw] or SIGN_STYLES[1], raw
	end

	local function laneSettings()
		local cur = {}
		pcall(function() cur = panel(params) end)
		return { overwrite = cur[LANE_PARAM] == 2, dedicated = cur[DEDICATED_PARAM] == 2,
			exitStyle = cur[EXIT_PARAM] == 2 and "B" or "A" }
	end

	-- The game opens the tool's info callout whenever a parameter in the menu's list changes
	-- (construction.tl changeParam: ScriptParamLocation.Default fires
	-- "constructionOpenCalloutFromParams"; Toolbar ones fire "constructionSetSuppressCallout" true
	-- instead). Switching the sign style popped it up over the settings (2026-10-18), so while this
	-- tool is active answer it with the suppress event the game uses for toolbar parameters: from
	-- the event, and again on the next step in case the game's own handler ran after ours and
	-- cleared it (the callout then closes within its grace period).
	local suppressNextStep = react.useRef(false)
	react.onEvent("constructionOpenCalloutFromParams", function()
		if not params.isActive then return end
		react.fireEvent(nil, "constructionSetSuppressCallout", true)
		suppressNextStep:set(true)
	end)

	-- A change of the drop-down restyles the existing signs (not on the first look).
	react.onStep(function()
		pcall(function() uninstall.wanted = panel(params)[UNINSTALL_PARAM] == 2 end)
		if suppressNextStep:get() then
			suppressNextStep:set(false)
			react.fireEvent(nil, "constructionSetSuppressCallout", true)
		end
		if not params.isActive then return end
		-- The priority sign sliders; a change that has settled rebuilds every road's signs.
		local cur = {}
		pcall(function() cur = panel(params) end)
		local values, parts = {}, {}
		for _, d in ipairs(DIAMOND_SETTINGS) do
			values[d.key] = tonumber(cur[d.param]) or d.default
			parts[#parts + 1] = tostring(values[d.key])
		end
		panelDiamonds = values
		local key = table.concat(parts, ",")
		if diamondWatch.key == nil then
			diamondWatch.key = key
		elseif key ~= diamondWatch.key then
			diamondWatch.key, diamondWatch.steps = key, 0
		elseif diamondWatch.steps then
			diamondWatch.steps = diamondWatch.steps + 1
			if diamondWatch.steps >= DIAMOND_REBUILD_STEPS then
				diamondWatch.steps = nil
				local ok, err = pcall(rebuildAllDiamonds)
				if not ok then log("rebuild failed: %s", tostring(err)) end
			end
		end
		local style = currentStyle()
		if lastStyle ~= nil and style ~= lastStyle then
			local ok, err = pcall(restyleAll, style)
			if not ok then log("restyle failed: %s", tostring(err)) end
		end
		lastStyle = style
		iconStyle = style
	end)

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
			local blue = color_util.withTransparency(LINE_PRIORITY, LINE_ALPHA)
			local red = color_util.withTransparency(LINE_YIELD, LINE_ALPHA)
			local removing = color_util.withTransparency(LINE_REMOVE, LINE_ALPHA)
			for _, s in ipairs(plan.remove and (plan.removeSegs or {}) or plan.segs) do
				local e = builtin.type.EdgeRenderable.Edge.new(segmentGeometry(s))
				e.colors = { plan.remove and removing or blue }
				e.width = LINE_WIDTH
				e.offsetZ = 0.5
				e.stepSize = 2
				edges[#edges + 1] = e
			end
			if not plan.remove then
				for _, s in ipairs(plan.yieldSegs) do
					local e = builtin.type.EdgeRenderable.Edge.new(segmentGeometry(s))
					e.colors = { red }
					e.width = LINE_WIDTH
					e.offsetZ = 0.5
					e.stepSize = 2
					edges[#edges + 1] = e
				end
			end
			children[#children + 1] = builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
		end
		children[#children + 1] = builtin.FullScreenComponent{
			recipe = IconOverlay,
			param = { planIcons = plan and plan.icons or {}, planNodes = plan and plan.nodes or {},
				gameCtx = params.gameCtx },
		}

		-- No hover outline: the lines above show what a click does (user, 2026-10-21).
		local none = color_util.withTransparency(constructionColors.Modifier.Valid, 0)
		children[#children + 1] = builtin.Selector{
			selectionColor = none,
			selectionOutlineColor = none,
			selectionOutlineColor1 = none,
			onHover = function(entity)
				local s = isEdge(entity) and entity or nil
				if s ~= hovered:old() then hovered:set(s) end
			end,
			onSelect = function(entity)
				if pending:old() then return true end
				local ok, p, w = pcall(planFrom, entity)
				if not ok or not p then
					message:set(tostring(ok and w or p))
					return true
				end
				pending:set(true)
				log("%s from segment %d: %s at %d junctions", p.kind, entity, p.remove and "removing" or "applying",
					p.remove and p.ours or p.entries)
				local lanes = laneSettings()
				log("lanes: overwrite %s, dedicated %s, roundabout exit %s", tostring(lanes.overwrite),
					tostring(lanes.dedicated), lanes.exitStyle)
				local applied = { overwrite = lanes.overwrite, dedicated = lanes.dedicated, exitStyle = lanes.exitStyle,
					style = (currentStyle()), diamonds = diamondSettings() }
				apply(p, function(okCount, failCount)
					configuredChanged()
					local style, raw = currentStyle()
					log("sign style parameter %s -> %s", tostring(raw), style)
					local signsOk, signsErr = pcall(updateSigns, p, style)
					if not signsOk then log("signs failed: %s", tostring(signsErr)) end
					local dOk, dErr = pcall(updateDiamonds, p)
					if not dOk then log("priority signs failed: %s", tostring(dErr)) end
					log("%s: %d ok, %d failed", p.remove and "removed" or "applied", okCount, failCount)
					message:set(failCount > 0 and string.format("Refused at %d junctions", failCount) or nil)
					pending:set(false)
					revision:set(revision:old() + 1)
				end, lanes, function(job, success)
					if success then registerJunction(job, applied) end
				end)
				return true
			end,
			filter = function(entity)
				return isEdge(entity)
			end,
		}

		-- Tooltip: kept to a word or a short reason; the highlights and icons show the rest.
		local text, good = nil, nil
		if plan then
			text, good = plan.kind, true
		elseif seg and why then
			text, good = why, false
		end
		if message:old() then text = text and (message:old() .. "\n" .. text) or message:old() end
		if text then
			children[#children + 1] = builtin.ActionTooltip{
				recipe = construction_react_util.SimpleTooltipRecipe,
				param = { message = { message = text, good = good } },
			}
		end

		return builtin.ActionDescriptor{
			onBack = function() params.abort() end,
			children = children,
			terrainCirclePolicy = "Never",
		}
	end

	params.setActionFn(actionFn, "imsvale_priority_road_" .. tostring(revision:old()))
end)

-- A junction that can't yield any more (bulldozed, no side road left, its light type changed or
-- its light removed): our light goes (if the node is still there with our light type), its yield
-- signs go, and it's unregistered.
-- roadEnds (every drop handed over by the game script, priority road 64): its priority signs are
-- sorted out too:
-- - the signs leading toward it go (the ones at the far end of each stretch from it, priority road 64);
-- - the signs after it (keys "<node>:<segment>"): all of them if the node or a priority segment is
--   gone (user, 2026-10-20: a priority road ending at a T whose through road yields isn't a
--   thing); otherwise those whose next junction ahead doesn't yield;
-- - for each remaining priority segment (`segs`): if the road it belongs to has no yielding
--   junction left, all its priority signs go, the start sign at its far end included (priority
--   road 46).
-- Without roadEnds (a repair finding no side road left) they stay.
-- Road edits: the watcher's state (FollowRoadEdits below; repair checks `handed`).
local FOLLOW_EVERY = 30
-- After a hand-over, wait this many steps before the next: a repair's commands and sign
-- placements answer asynchronously, and a drop handed over meanwhile (the junction bulldozed
-- right after an edit) raced it: the repair put signs back after the drop had cleared them
-- (priority road 46, 2026-10-20).
local FOLLOW_SETTLE = 120
local follow = { steps = 0, handed = {}, settle = 0 } -- GUI module state

-- The junctions registered in the game script's state, by node (string keys).
local function registeredJunctions()
	local ok, j = pcall(function()
		local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(SIGN_GAME_SCRIPT)
		local comp = entity and api.engine.getComponent(entity, CT.GAME_SCRIPT)
		return comp and comp.state and comp.state.junctions
	end)
	return ok and type(j) == "table" and j or {}
end

local function drop(node, why, typeId, roadEnds, segs)
	log("follow road edits: node %s dropped (%s)", tostring(node), why)
	local old = storedSigns()[tostring(node)]
	if old then
		removeSigns(old.ids)
		storeSigns(node, {})
	end
	if roadEnds then
		local registered = registeredJunctions()
		-- still yielding: registered and not about to be dropped itself
		local function yielding(n)
			local j = registered[tostring(n)]
			return type(j) == "table" and not j.gone
		end
		local diamonds = storedDiamonds()
		local function clear(key)
			local ids = diamonds[key]
			if type(ids) == "table" then
				removeSigns(ids)
				storeDiamonds(key, {})
				diamonds[key] = nil
			end
		end
		local exists = node and api.engine.entityExists(node)
		local armGone = false
		for _, seg in ipairs(segs or {}) do
			if not isEdge(seg) then armGone = true end
		end
		if exists then
			-- A priority sign says: priority at the next junction ahead. So the signs leading toward
			-- this junction go: each hangs on the junction (or road end) at the far end of the
			-- stretch, keyed with the stretch's last segment (user, 2026-10-22). With the junction
			-- and both arms still there (its light type changed, say), its own signs, leading away,
			-- stay where the next junction ahead still yields.
			for _, seg in ipairs(segs or {}) do
				if isEdge(seg) then
					local ok, err = pcall(function()
						local far, path = stretchFrom(seg, node)
						clear(far .. ":" .. path[#path])
						if not armGone and not yielding(far) then clear(node .. ":" .. seg) end
					end)
					if not ok then log("follow road edits: priority signs toward node %d: %s", node, tostring(err)) end
				end
			end
		end
		if not exists or armGone then
			-- the junction, or the priority road through it, is gone: everything that hung on it
			-- (a priority road ending at a T whose through road yields isn't a thing: user, 2026-10-20)
			local prefix = tostring(node) .. ":"
			for key in pairs(diamonds) do
				if tostring(key):sub(1, #prefix) == prefix then clear(key) end
			end
		end
		for _, seg in ipairs(segs or {}) do
			if isEdge(seg) then
				local ok, err = pcall(function()
					-- The road on from this segment, both ways (the straightest road at each node,
					-- as the tool follows a road; planFrom returns nothing for a road with no
					-- junctions left).
					local chain, nodes = { [seg] = true }, {}
					local e = api.engine.getComponent(seg, CT.BASE_EDGE)
					for _, start in ipairs({ e.node0, e.node1 }) do
						nodes[start] = true
						local more, passed = walk(seg, start, nil, { [seg] = true })
						for _, x in ipairs(more) do chain[x] = true end
						for _, p in ipairs(passed) do nodes[p.node] = true end
						for _, x in ipairs(more) do
							local xe = api.engine.getComponent(x, CT.BASE_EDGE)
							if xe then nodes[xe.node0] = true nodes[xe.node1] = true end
						end
					end
					for n in pairs(nodes) do
						-- this junction is being unregistered: it doesn't count
						if n ~= node and yielding(n) then return end
					end
					local count = 0
					for key in pairs(diamonds) do -- (clearing an entry while traversing is allowed)
						local s = tonumber(tostring(key):match(":(%d+)$") or "")
						if s and chain[s] then
							clear(key)
							count = count + 1
						end
					end
					log("follow road edits: no yielding junction left on the road at segment %d: %d priority sign entries removed", seg, count)
				end)
				if not ok then log("follow road edits: priority signs at segment %d: %s", seg, tostring(err)) end
			end
		end
	end
	if node and api.engine.entityExists(node) then
		local ok, err = pcall(function()
			local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
			if cfg and typeId and cfg.trafficLightConfig.trafficLightType == typeId then
				local tl = cfg.trafficLightConfig:clone()
				tl.states = {}
				tl.trafficLightType = TAKEN_OFF_TYPE
				send(node, tl, takenOffPreference(node, cfg), function(success)
					if not success then log("follow road edits: node %d: light removal refused", node) end
				end)
			end
		end)
		if not ok then log("follow road edits: node %d: %s", node, tostring(err)) end
	end
	registerJunction({ node = node, remove = true })
end

-- After a road edit, for the junctions the game script marked (see FollowRoadEdits below).
-- todo: { { node, a, b, round, typeId, settings, mode }, ... }; a / b are already the new segments.
-- - mode "drop": bulldozed (node gone, or a priority segment removed without a replacement).
-- - mode "repair" (always, since priority road 47; before, only with the "Follow road edits"
--   switch on: docs/archive/follow-switch.md): the junction gets its yielding
--   again with the settings it was applied with (light, phases, lanes, yield signs) and is
--   re-registered; then the affected roads' priority signs are placed again. If it can't yield
--   any more (no side road left), it's dropped.
-- Priority signs stored under a segment that no longer exists are removed first: they stood
-- beside the old or removed road.
local function repair(todo)
	local typeId = invisibleType()
	if not typeId then log("follow road edits: the Yield (invisible) light type wasn't found") return end
	-- Leftover priority signs of replaced segments.
	for key, ids in pairs(storedDiamonds()) do
		local seg = tonumber(tostring(key):match(":(%d+)$") or "")
		if seg and not isEdge(seg) and type(ids) == "table" then
			removeSigns(ids)
			storeDiamonds(key, {})
		end
	end
	local roads = {}
	for _, item in ipairs(todo) do
		local node, settings = item.node, type(item.settings) == "table" and item.settings or {}
		if item.mode == "drop" then
			-- why: set when lane following found it can't keep the junction (light type changed or
			-- removed, no side road left); otherwise a road edit removed its road
			drop(node, item.why or "its road was removed", typeId, true, { item.a, item.b })
		elseif node and api.engine.entityExists(node) and isEdge(item.a) and isEdge(item.b) then
			local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
			local states, why, sideSegs = junctionStates(node, item.a, item.b, cfg, item.round)
			if not states then
				drop(node, tostring(why), typeId)
			else
				local j = { node = node, a = item.a, b = item.b, states = states, has = true,
					new = { [item.a] = "priority", [item.b] = "priority" } }
				for seg in pairs(sideSegs) do j.new[seg] = "yield" end
				local plan = { junctions = { j }, round = item.round or false, typeId = typeId, remove = false }
				local lanes = { overwrite = settings.overwrite == true, dedicated = settings.dedicated == true,
					exitStyle = settings.exitStyle == "B" and "B" or "A" }
				local style = settings.style or SIGN_STYLES[1]
				apply(plan, function(okCount)
					log("follow road edits: node %d %s", node, okCount > 0 and "repaired" or "repair refused")
					-- Signs only for a repair that went through and wasn't overtaken by a later
					-- mark (e.g. the junction bulldozed meanwhile: its drop handles the signs).
					if okCount == 0 or follow.handed[tostring(node)] ~= "repair" then return end
					local ok, err = pcall(updateSigns, plan, style)
					if not ok then log("follow road edits: signs at node %d: %s", node, tostring(err)) end
				end, lanes, function(job, success)
					if success then registerJunction(job, settings) end
				end)
				if not item.round then roads[#roads + 1] = { seg = item.a, diamonds = settings.diamonds } end
			end
		else
			drop(node, "its node or priority road is gone", typeId, true, { item.a, item.b })
		end
	end
	-- Priority signs: each affected road once, with the settings it was applied with.
	local done = {}
	for _, r in ipairs(roads) do
		if not done[r.seg] and isEdge(r.seg) then
			local ok, plan = pcall(planFrom, r.seg)
			if ok and plan and not plan.round then
				for _, x in ipairs(plan.segs) do done[x] = true end
				plan.remove = false
				local saved = panelDiamonds
				if type(r.diamonds) == "table" then panelDiamonds = r.diamonds end
				local dOk, err = pcall(updateDiamonds, plan)
				panelDiamonds = saved
				if not dOk then log("follow road edits: priority signs: %s", tostring(err)) end
			end
		end
	end
end

-- Mounted for the whole session through the game's ModEntryPointExtension (plugin resource
-- gui/imsvale_follow_road_edits.res.lua), whether or not the tool is open. Every FOLLOW_EVERY steps
-- it reads the yield game script's state and hands marked junctions to repair(), each once per
-- session and mark (a junction marked `gone` while its repair was under way is handed over
-- again; priority road 46). repair re-registers or unregisters them, which clears the mark:
-- `gone` to drop, any other mark to repair (always, since priority road 47). The game script's own
-- guiUpdate couldn't do this: game scripts run in their own environment and don't see the tool's
-- code (2026-10-20).
local function followRoadEdits()
	local ok, s = pcall(function()
		local entity = api.engine.system.gameScriptSystem.getEntityForGameScript(SIGN_GAME_SCRIPT)
		local comp = entity and api.engine.getComponent(entity, CT.GAME_SCRIPT)
		return comp and comp.state
	end)
	if not ok or type(s) ~= "table" or type(s.junctions) ~= "table" then return end
	-- (`check`: a mark from priority road 44-46 saves, now repaired like the rest)
	local function marked(j) return type(j) == "table" and (j.gone or j.repair or j.check) end
	local todo = {}
	for key, j in pairs(s.junctions) do
		local mode = marked(j) and (j.gone and "drop" or "repair")
		if mode and follow.handed[key] ~= mode then
			follow.handed[key] = mode
			todo[#todo + 1] = { node = tonumber(key), a = j.a, b = j.b, round = j.round, typeId = j.typeId,
				settings = j.settings, mode = mode, why = j.why }
		end
	end
	for key in pairs(follow.handed) do
		if not marked(s.junctions[key]) then follow.handed[key] = nil end
	end
	if #todo > 0 then
		follow.settle = FOLLOW_SETTLE
		local rOk, err = pcall(repair, todo)
		if not rOk then log("follow road edits: repair failed: %s", tostring(err)) end
	end
end

local entryOk, mod_entry_point = pcall(ug_require, "::/gui/main/mod_entry_point.tl")
local FollowRoadEdits = nil
if entryOk and mod_entry_point and mod_entry_point.ModEntryPointExtension then
	FollowRoadEdits = react.RegisterPluginRecipe(mod_entry_point.ModEntryPointExtension, "ImsvaleFollowRoadEdits", function()
		react.onStep(function()
			follow.steps = follow.steps + 1
			if follow.settle > 0 then follow.settle = follow.settle - 1 return end
			if follow.steps < FOLLOW_EVERY then return end
			follow.steps = 0
			followRoadEdits()
		end)
		return nil
	end)
else
	log("follow road edits: no mod entry point (%s)", tostring(mod_entry_point))
end

log("loaded: %s", VERSION)

local function getDefinition(constructionDefinition, _repository, _params)
	return {
		resName = constructionDefinition,
		icon = { icon = "imsvale_road_priority_yield::/gui/priority-triple.tga" },
		previewIcon = { icon = "imsvale_road_priority_yield::/gui/priority-triple.tga" },
		name = "Priority Road",
		description = "Side roads yield to the road or roundabout you click.",
		action = "ACTION_CUSTOM",
		availability = { yearFrom = 0, yearTo = 0 },
		params = {
			{
				group = SECTION_PARAM,
				key = SECTION_PARAM,
				name = "Section",
				values = {
					"::/gui/main/icons/symbol_gear_28.tga",
					"imsvale_road_priority_yield::/gui/tab-roundabout.tga",
					"imsvale_road_priority_yield::/gui/tab-priority.tga",
				},
				tooltips = { "General", "Roundabouts", "Priority signs" },
				defaultIndex = 1,
				hideLabel = true,
				resetOnCategoryChange = false,
				uiType = api.type.enum.ScriptParamType.IconButton,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Default,
				preserveValueInAllCategories = true,
			},
			{
				group = SIGN_STYLE_PARAM,
				key = SIGN_STYLE_PARAM,
				name = "Sign style",
				values = { "International", "Norwegian" },
				defaultIndex = 1,
				resetOnCategoryChange = false,
				displayMode = api.type.enum.ScriptParamDisplayMode.Horizontal,
				uiType = api.type.enum.ScriptParamType.ComboBox,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Default,
				preserveValueInAllCategories = true,
				checkEnabledFn = inSection("general"),
			},
			{
				group = LANE_PARAM,
				key = LANE_PARAM,
				name = "Overwrite lanes",
				values = { "Yes" },
				defaultIndex = 1,
				resetOnCategoryChange = false,
				uiType = api.type.enum.ScriptParamType.CheckBox,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Default,
				preserveValueInAllCategories = true,
				checkEnabledFn = inSection("general"),
			},
			{
				group = DEDICATED_PARAM,
				key = DEDICATED_PARAM,
				name = "Dedicated turn lanes",
				values = { "Yes" },
				defaultIndex = 1,
				resetOnCategoryChange = false,
				uiType = api.type.enum.ScriptParamType.CheckBox,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Default,
				preserveValueInAllCategories = true,
				checkEnabledFn = inSection("general"),
			},
			{
				group = UNINSTALL_PARAM,
				key = UNINSTALL_PARAM,
				name = "Uninstall",
				values = { "Yes" },
				defaultIndex = 1,
				resetOnCategoryChange = false,
				uiType = api.type.enum.ScriptParamType.CheckBox,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Default,
				preserveValueInAllCategories = false,
				checkEnabledFn = inSection("general"),
			},
			{
				group = EXIT_PARAM,
				key = EXIT_PARAM,
				name = "Roundabout exit",
				values = { "Style A", "Style B" },
				tooltips = { "Exit from right lane only", "More exit lanes" },
				defaultIndex = 1,
				resetOnCategoryChange = false,
				displayMode = api.type.enum.ScriptParamDisplayMode.Horizontal,
				uiType = api.type.enum.ScriptParamType.Button,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Default,
				preserveValueInAllCategories = true,
				checkEnabledFn = inSection("roundabout"),
			},
			(table.unpack or unpack)(diamondParams()),
		},
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
		FollowRoadEdits = FollowRoadEdits,
	}
end
