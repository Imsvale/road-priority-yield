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
-- Icons while the tool is open: a priority / yield icon on every approach of every junction
-- configured with this mod, near the camera. Hovering a road previews its junctions instead:
-- new icons; on removal the existing ones crossed out; where a configured junction's role
-- changes, the old icon crossed out beside the new one.
--
-- Per junction (3+ roads) on the priority road, numbering lockedLanes as the game does
-- (lane connections, then crosswalks):
-- - phase #1: connections coming from the priority road's two segments green;
-- - phase #2: connections coming from the side roads green, and those leaving the priority
--   road onto a side road (exits): they don't cross the entering traffic, so they stay green;
-- - phase #3, only with crosswalks: crosswalks green (PEDESTRIAN_SECONDS, skipping allowed).
-- Junctions where no side road leads in (exits only) get no light.
--
-- Road direction comes from the junction's lane connections (which segment leads to which),
-- not from the lanes' transport mode flags.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local color_util = ug_require "::/gui/main/color_util.tl"
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl"
local styleutil = ug_require "::/gui/main/styleutil.tl"

local VERSION = "priority road 18 (no info callout when switching the sign style)"
local CT = api.type.ComponentType

local PRIORITY_SECONDS = 60.0  -- phase #1 maximum; it ends early when the priority road is empty
local YIELD_SECONDS = 1.0      -- phase #2 maximum; short, or a long side queue would hold the priority road
local PEDESTRIAN_SECONDS = 6.0 -- phase #3, only where there are crosswalks
local MAX_TURN = 45            -- degrees: how far the priority road may bend at a junction
local ROUND_TOLERANCE = 0.12   -- a loop is a roundabout if every sample is within 12 % of the mean radius
local MAX_SEGMENTS = 400       -- stop following a road after this many segments
local LIGHT_TYPE = "imsvale_yield_invisible" -- matched against the light type resource names

-- Icons, drawn on screen at each approach's junction edge (see IconOverlay): on every junction
-- already configured with this mod, and the hovered road's preview.
local ICON_BACK = 6.0          -- metres back from the junction edge along the approach
local ICON_LIFT = 1.5          -- metres above the road
local ICON_SIZE = 32           -- pixels at ICON_REF_DISTANCE from the camera
local ICON_REF_DISTANCE = 150  -- metres
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
	remove = "imsvale_road_priority_yield::/gui/remove-x.tga", -- drawn over an icon that goes away ("x" style)
}
-- How an icon that goes away is marked: "highlight" = the bulldozer's look (a box of translucent
-- gold with a stronger gold outline, in the game's own Bulldozer colour), "x" = ICONS.remove on top.
local REMOVAL_STYLE = "highlight"
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
		phase(YIELD_SECONDS, function(c) return c and (not priority[c.segment0] or not priority[c.segment1]) end),
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

	local plan = { segs = segs, loop = loop, junctions = {}, skipped = 0, applied = 0, entries = 0, yieldSegs = {}, icons = {} }
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
				-- Roles before and after, for the icons: the approaches that lead in get one.
				local leadsIn = {}
				for _, c in ipairs(cfg.laneConnections) do leadsIn[c.segment0] = true end
				j.old = has and configuredRoles(cfg) or {}
				j.new = {}
				if states then
					if leadsIn[n.a] then j.new[n.a] = "priority" end
					if leadsIn[n.b] then j.new[n.b] = "priority" end
					for s in pairs(sideSegs) do j.new[s] = "yield" end
				end
			end
		end
	end
	plan.remove = plan.applied > 0 and plan.applied == plan.entries

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
			for s, kind in pairs(j.old) do icon(j, s, kind, plan.remove) end
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

-- Build signs for the given approaches of one junction; done(asset ids).
local function placeSigns(node, segs, file, done)
	local con = signCon(file)
	if not con or #segs == 0 then return done({}) end
	local proposal = api.type.SimpleProposal.new()
	local list = {}
	for _, seg in ipairs(segs) do
		local t = signTransf(seg, node)
		if t then
			local ce = api.type.SimpleProposal.ConstructionEntity.new()
			ce.fileName = con
			ce.transf = t
			ce.params = { seed = 0 }
			ce.name = "Yield sign"
			ce.playerEntity = api.engine.util.getPlayer()
			list[#list + 1] = ce
		end
	end
	if #list == 0 then return done({}) end
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
			if not success then log("node %d: signs refused", node) end
			done(ids)
		end)
	end
	send(false)
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
			if j.has and old then
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
-- - Size falls with the distance from the camera (ICON_SIZE at ICON_REF_DISTANCE, clamped).
--   Icons further from the camera's centre than the range (which grows with the camera's
--   height) are hidden, and fade out before that, so close in the horizon stays clear.
-- - An icon that goes away gets a second element at the same place, drawn on top: the
--   bulldozer-style highlight box, or ICONS.remove (REMOVAL_STYLE).
-- - Re-projected every step, so the icons follow the camera.
-- param: planIcons (the hovered road's preview), planNodes (its junctions, whose configured
-- icons the preview replaces).
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
				local scaled = ICON_SIZE * ICON_REF_DISTANCE / math.max(dist, 1)
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
		local parts = { tostring(configured.version) }
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
		image(i, "", p, ICONS[p.kind])
		if p.cross then
			if REMOVAL_STYLE == "x" then
				image(i, "x", p, ICONS.remove)
			else
				highlight(i, p)
			end
		end
	end
	return builtin.FloatingLayout{ meta = { mouseTransparent = true }, children = children }
end)

local lastStyle = nil -- the drop-down's value last seen (GUI module state)

local PriorityRoadAction = react.RegisterRecipe("ImsvalePriorityRoadAction", function(params)
	local revision = react.useState(0)
	local message = react.useState(nil)
	local pending = react.useState(false)

	local function currentStyle()
		local raw = nil
		pcall(function() raw = params.getCurrentParams()[SIGN_STYLE_PARAM] end)
		return SIGN_STYLES[raw] or SIGN_STYLES[1], raw
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
		if suppressNextStep:get() then
			suppressNextStep:set(false)
			react.fireEvent(nil, "constructionSetSuppressCallout", true)
		end
		if not params.isActive then return end
		local style = currentStyle()
		if lastStyle ~= nil and style ~= lastStyle then
			local ok, err = pcall(restyleAll, style)
			if not ok then log("restyle failed: %s", tostring(err)) end
		end
		lastStyle = style
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
		children[#children + 1] = builtin.FullScreenComponent{
			recipe = IconOverlay,
			param = { planIcons = plan and plan.icons or {}, planNodes = plan and plan.nodes or {} },
		}

		children[#children + 1] = builtin.Selector{
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
					p.remove and p.applied or p.entries)
				apply(p, function(okCount, failCount)
					configuredChanged()
					local style, raw = currentStyle()
					log("sign style parameter %s -> %s", tostring(raw), style)
					local signsOk, signsErr = pcall(updateSigns, p, style)
					if not signsOk then log("signs failed: %s", tostring(signsErr)) end
					log("%s: %d ok, %d failed", p.remove and "removed" or "applied", okCount, failCount)
					message:set(failCount > 0 and string.format("Refused at %d junctions", failCount) or nil)
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
				group = SIGN_STYLE_PARAM,
				key = SIGN_STYLE_PARAM,
				name = "Sign style",
				values = { "International", "Norwegian" },
				defaultIndex = 1,
				resetOnCategoryChange = false,
				uiType = api.type.enum.ScriptParamType.ComboBox,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Default,
				preserveValueInAllCategories = true,
			},
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
	}
end
