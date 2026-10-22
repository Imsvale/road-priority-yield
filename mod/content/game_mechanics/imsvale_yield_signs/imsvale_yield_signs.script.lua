-- The Priority Road tool's memory, in the game script's state (saved with the game).
--
-- Signs: which sign assets the tool placed at which junction. The signs are built as
-- constructions but become plain assets (ASSET_GROUP) once built, and asset groups can't be
-- looped over, so the tool keeps their ids here to remove them again (2026-10-18).
--
-- Junctions and lane edits (2026-10-19; always on since priority road 47, before only with the
-- tool's "Follow road edits" switch: docs/archive/follow-switch.md): every junction the tool applied
-- yielding to, with its priority road segments, kind, light type and a fingerprint of its lane
-- connections. Every CHECK_EVERY seconds the junctions' lanes are
-- compared with the fingerprint; a change that stays the same over two checks in a row (the edit
-- has settled) rebuilds the phases from the new lanes with the same plan (phases module), lanes
-- untouched. Phase edits alone don't trigger it. Unless the player also edited the phases (they
-- differ from the ones written, `ph`, by more than the lane edit explains): then the junction is
-- marked handEdited and its phases are left alone from then on, until it's applied again
-- (2026-10-22). A junction drops out when its node or priority segments are gone, its light was
-- removed or switched to another type (by the player, or by the game taking the light over), or
-- no side road leads in: it's marked `gone` (with `why`) and the tool drops it as after a road
-- edit, its signs included (until 2026-10-22 only the entry was deleted and the signs stayed).
-- Checks run on the wall clock where the sandbox has one (os.time), so edits made while the game
-- is paused are followed too; otherwise on game time.
--
-- State: {
--   signs = { ["<node>"] = { ids = { asset ids }, style = "intl" | "no", round = bool } },
--   diamonds = { ["<node>"] = { asset ids } }: priority signs along a priority road, under the
--     junction they follow or the road end they start at (2026-10-19),
--   junctions = { ["<node>"] = { a, b, round, typeId, fp, ph, handEdited, pending, settings,
--     ahead = { a = { seg, node }, b = { seg, node } }, repair (always) | gone | check } },
--   nextCheck = seconds, t = seconds, (follow = bool: the old switch, ignored since priority road 47)
-- }
-- (before 2026-10-18 evening a sign entry was the bare id list; the tool reads both).
--
-- The tool (GUI) writes with api.cmd.makeScriptingSendEventCmd(GAME_SCRIPT, EVENT_ID, SIGNS_EVENT, param)
-- (script-doc cmd.md: broadcast to all subscribed scripts, `src` naming the game script it
-- pretends to come from), param.kind saying what it is:
-- - nil (signs) { node, signs = { ... }, style, round }: an empty list clears the entry;
-- - "diamonds" { node, ids = { ... } }: an empty list clears the entry;
-- - "junction" { node, a, b, round, typeId, fp, settings } or { node, remove = true };
-- - "reset" {}: the tool's Uninstall removed everything; all records go;
-- - "diamondSettings" { values = { start, startHalf, repeatAt, jitter, minGap } }: the priority
--   sign settings, per save.
-- One event for all: a save keeps the subscriptions it was saved with (GameScript.eventSubscriptions
-- is part of the component), and this script only subscribes when it has none, so an event added
-- in a later version never arrived in an older save (priority signs weren't stored, 2026-10-19).
-- It reads the state back with api.engine.system.gameScriptSystem.getEntityForGameScript(GAME_SCRIPT)
-- and that entity's GAME_SCRIPT component, field `state` (script-doc engine/system.md, engine.md).
--
-- Subscribing: as the base game's own scripts do (e.g. game_mechanics/arrival_tracker), in
-- update whenever state:hasEventSubscriptions() is false. The subscriptions are saved with the game
-- (GameScript.eventSubscriptions is part of the component, 2026-10-19), so later additions use a
-- flag in the state, saved along with them (buildSubscribed).
--
-- Road edits (2026-10-19; always since priority road 47): a road type change replaces the
-- segments and resets the node configs, our light included (lab findings, "Road upgrades").
-- - Engine part, the game's build events ("apply_command"): before a build, the removed segments
--   that end at a registered junction (priority or side road) are recorded with their nodes and
--   their direction at each end (s.replaced); after it, priority segments are matched to their
--   replacements (same two nodes, else the new segment at the junction pointing the same way: a
--   split), and every junction touched is marked: `gone` when its node is gone or a priority
--   segment was removed without a replacement (bulldozed); else `repair` (a side road removed or
--   replaced, or a priority segment replaced: the tool drops the junction if it can't yield any
--   more). Each edit is logged ("road edit at node ..."), so a test's log says what
--   was done. Lane following skips marked junctions.
-- - GUI part: the Priority Road tool's FollowRoadEdits (mounted all session through the game's
--   ModEntryPointExtension) reads the marks from this state and applies the yielding again with the
--   settings it was applied with (lights, lanes, signs), re-registering each junction, which clears
--   the mark. Not this script's guiUpdate: game scripts run in their own environment and can't
--   reach the tool's code (2026-10-20).
--
-- Sending commands from here: without a callback (callbacks are disallowed in the engine state).

-- Loaded under pcall: if it fails, following is off but the signs still work.
local phasesOk, phases = pcall(ug_require, "/scripts/imsvale_yield_phases.lua")
-- Dev switches (all off in a release; on the dev branch, dev mode fills them in).
local devOk, dev = pcall(ug_require, "/scripts/imsvale_yield_dev.lua")
if not devOk or type(dev) ~= "table" then dev = {} end

local EVENT_ID = "imsvale_road_priority_yield"
local SIGNS_EVENT = "imsvale_yield_signs.set"
local CHECK_EVERY = 3.0 -- game seconds between lane checks

local CT = api.type.ComponentType

local function log(fmt, ...)
	local args = { ... }
	pcall(function() print("[yield] " .. string.format(fmt, (table.unpack or unpack)(args))) end)
end

-- A list from the engine: a Lua array, or a native vector (size() / at(i)).
local function items(list)
	local out = {}
	if list == nil then return out end
	local ok = pcall(function() for _, v in ipairs(list) do out[#out + 1] = v end end)
	if not ok or #out == 0 then
		pcall(function() for i = 1, list:size() do out[#out + 1] = list:at(i) end end)
	end
	return out
end

local function unit(x, y)
	local l = math.sqrt(x * x + y * y)
	if l < 1e-9 then return { x = 0, y = 0 } end
	return { x = x / l, y = y / l }
end

-- From `node` out along `seg`, through plain nodes (two street segments), to the next junction
-- or dead end: that node and the segment arriving at it.
local function nextJunction(seg, node)
	local cur, at = seg, node
	for _ = 1, 400 do
		local e = api.engine.getComponent(cur, CT.BASE_EDGE)
		if not e then return nil end
		local far = e.node0 == at and e.node1 or e.node0
		local around = items(api.engine.system.streetSystem.getNodeStreetSegments(far))
		if #around ~= 2 then return far, cur end
		local nxt = around[1] == cur and around[2] or around[1]
		if nxt == seg then return nil end -- a loop without junctions
		cur, at = nxt, far
	end
	return nil
end

-- Unit direction in which `seg` leaves `node`.
local function leavingDir(seg, node)
	local e = api.engine.getComponent(seg, CT.BASE_EDGE)
	if e.node0 == node then return unit(e.tangent0.x, e.tangent0.y) end
	return unit(-e.tangent1.x, -e.tangent1.y)
end

-- The segment at `node` that goes straight on from `seg` (arriving there), at most 45 degrees off;
-- nil if none.
local function straightOn(seg, node)
	local d = leavingDir(seg, node)
	local best, bestDot = nil, math.cos(math.rad(45))
	for _, cand in ipairs(items(api.engine.system.streetSystem.getNodeStreetSegments(node))) do
		if cand ~= seg then
			local c = leavingDir(cand, node)
			local dot = -(c.x * d.x + c.y * d.y)
			if dot >= bestDot then best, bestDot = cand, dot end
		end
	end
	return best
end

-- Before a build: the removed segments that end at a registered junction (priority or side road),
-- with their nodes and directions away from each end.
local function beforeBuild(s, street)
	local watched = {}
	for key in pairs(s.junctions or {}) do
		local node = tonumber(key)
		if node then watched[node] = true end
	end
	for _, x in ipairs(items(street.removedSegments)) do
		local seg, e = x.entity, x.comp
		if seg and e and (watched[e.node0] or watched[e.node1]) then
			s.replaced = s.replaced or {}
			s.replaced[tostring(seg)] = {
				node0 = e.node0, node1 = e.node1,
				dir0 = unit(e.tangent0.x, e.tangent0.y), dir1 = unit(-e.tangent1.x, -e.tangent1.y),
			}
		end
	end
end

-- After it: replacements for the recorded segments; their junctions marked for repair.
local function afterBuild(s, street)
	if not s.replaced or next(s.replaced) == nil then return end
	local added = {}
	for _, x in ipairs(items(street.addedSegments)) do
		local e = x.comp
		if x.entity and x.entity >= 0 and e then
			added[#added + 1] = { seg = x.entity, node0 = e.node0, node1 = e.node1,
				dir0 = unit(e.tangent0.x, e.tangent0.y), dir1 = unit(-e.tangent1.x, -e.tangent1.y) }
		end
	end
	local function replacement(old, node)
		local oldDir = old.node0 == node and old.dir0 or old.dir1
		local far = old.node0 == node and old.node1 or old.node0
		local best, bestDot = nil, -2
		for _, n in ipairs(added) do
			if (n.node0 == node and n.node1 == far) or (n.node1 == node and n.node0 == far) then return n.seg end
			if n.node0 == node or n.node1 == node then
				local d = n.node0 == node and n.dir0 or n.dir1
				local dot = d.x * oldDir.x + d.y * oldDir.y
				if dot > bestDot then best, bestDot = n.seg, dot end
			end
		end
		return bestDot > 0.9 and best or nil
	end
	for key, j in pairs(s.junctions or {}) do
		local node = tonumber(key)
		local touched, lost, sideRemoved = false, false, false
		local priority = {}
		for _, field in ipairs({ "a", "b" }) do
			local segKey = j[field] and tostring(j[field])
			local old = segKey and s.replaced[segKey]
			if old and node then
				priority[segKey] = true
				local new = replacement(old, node)
				if new then
					log("road edit at node %d: priority segment %d replaced by %d", node, j[field], new)
					j[field] = new
				else
					log("road edit at node %d: priority segment %d removed", node, j[field])
					lost = true
				end
				touched = true
			end
		end
		for segKey, old in pairs(s.replaced) do
			if node and not priority[segKey] and (old.node0 == node or old.node1 == node) then
				touched = true
				local new = replacement(old, node)
				if new then
					log("road edit at node %d: side segment %s replaced by %d", node, segKey, new)
				else
					log("road edit at node %d: side segment %s removed", node, segKey)
					sideRemoved = true
				end
			end
		end
		if touched then
			local mark
			if lost or not node or not api.engine.entityExists(node) then
				j.gone, mark = true, "gone"
			elseif sideRemoved then
				j.repair, mark = true, "repair (side road removed)"
			else
				j.repair, mark = true, "repair"
			end
			j.pending = nil
			log("road edit at node %s: marked %s", key, mark)
		end
	end
	s.replaced = nil
end

-- Why a registered junction can't be followed any more, or nil.
-- A priority segment that's gone but has a successor leaving the junction the same way (a road
-- joined it right next to the junction, which splits it into new segments, or an upgrade, with no
-- build event, as by a town) isn't a reason: the junction is marked `repair` with the new segment
-- instead (2026-10-22). For that, the direction each priority segment leaves the junction is
-- remembered (`dirs`) while it's there.
local function gone(node, j)
	if not api.engine.entityExists(node) then return "node gone" end
	local segs = {}
	for _, seg in ipairs(api.engine.system.streetSystem.getNodeStreetSegments(node)) do segs[seg] = true end
	j.dirs = type(j.dirs) == "table" and j.dirs or {}
	local replaced = {}
	for _, field in ipairs({ "a", "b" }) do
		local seg, d = j[field], j.dirs[field]
		if segs[seg] then
			if not d or d.seg ~= seg then
				local u = leavingDir(seg, node)
				j.dirs[field] = { seg = seg, x = u.x, y = u.y }
			end
		else
			local other = j[field == "a" and "b" or "a"]
			local best, bestDot = nil, 0.9
			for cand in pairs(segs) do
				if d and cand ~= other then
					local u = leavingDir(cand, node)
					local dot = u.x * d.x + u.y * d.y
					if dot > bestDot then best, bestDot = cand, dot end
				end
			end
			if not best then return "priority road rebuilt" end
			replaced[field] = best
		end
	end
	if next(replaced) then
		for field, new in pairs(replaced) do
			log("road edit at node %d (no build event): priority segment %d replaced by %d: marked repair", node, j[field], new)
			j[field] = new
		end
		j.repair, j.pending = true, nil
		return nil
	end
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
	j.ph = phases.phaseFingerprint(cfg.laneConnections, cfg.crosswalks, states)
	return nil
end

-- The junction's phases as they are now (phases.phaseFingerprint).
local function currentPhases(node)
	local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
	return phases.phaseFingerprint(cfg.laneConnections, cfg.crosswalks, cfg.trafficLightConfig.states)
end

-- New junctions on a priority road. Towns join streets onto a stretch without raising build events
-- (2026-10-22), so: remember the next junction along each priority segment (`ahead`, through plain
-- nodes), and when the walk now stops at a node that isn't ours, has 3+ roads and leads straight on
-- to the junction remembered, a road has joined the stretch there. It's registered with this
-- junction's settings and marked `repair`, which makes the tool apply it (adopt: { node = entry }).
local function watchAhead(s, node, j, adopt)
	j.ahead = type(j.ahead) == "table" and j.ahead or {}
	for _, field in ipairs({ "a", "b" }) do
		local seg = j[field]
		local next_, arriving = nextJunction(seg, node)
		local was = j.ahead[field]
		if not next_ then
			j.ahead[field] = nil
		elseif not was or was.seg ~= seg or next_ == was.node then
			j.ahead[field] = { seg = seg, node = next_ } -- first look, or a new priority segment
		elseif not s.junctions[tostring(next_)] and not adopt[next_]
			and #items(api.engine.system.streetSystem.getNodeStreetSegments(next_)) >= 3 then
			local on = straightOn(arriving, next_)
			local beyond = on and nextJunction(on, next_)
			if beyond == was.node then
				log("new junction %d on the priority road between %d and %d: marked repair", next_, node, was.node)
				adopt[next_] = { a = arriving, b = on, round = j.round, typeId = j.typeId, settings = j.settings,
					repair = true }
			end
			j.ahead[field] = { seg = seg, node = next_ }
		else
			j.ahead[field] = { seg = seg, node = next_ } -- one of ours, or not inserted: the new next
		end
	end
end

local function follow(s)
	local adopt = {}
	for key, j in pairs(s.junctions or {}) do
		local node = tonumber(key)
		local why = "bad entry"
		if node then why = gone(node, j) end
		local marked = j.repair or j.gone or j.check
		if marked then why = false end -- the tool handles it (and removes its signs)
		if why and not node then
			log("follow lane edits: entry %s dropped (%s)", key, why)
			s.junctions[key] = nil
		elseif why then
			-- the tool drops it: our signs removed, our light (if it still is) off, unregistered
			log("follow lane edits: node %s handed over to drop (%s)", key, why)
			j.gone, j.why = true, why
		elseif marked then
			-- the tool repairs, drops or checks it
		else
			local aOk, aErr = pcall(watchAhead, s, node, j, adopt)
			if not aOk then log("watching ahead of node %d: %s", node, tostring(aErr)) end
			local fp = phases.fingerprint(api.engine.getComponent(node, CT.BASE_NODE_CONFIG))
			if fp == j.fp then
				j.pending = nil
			elseif fp ~= j.pending then
				j.pending = fp -- changed: wait one more check for the edit to settle
			else
				-- A road edit (other roads in the connections: a road joined, removed or replaced,
				-- by the player or a town growing, whose builds raise no build events, 2026-10-22)
				-- isn't a phase edit: the tool repairs the junction as after a road edit (phases,
				-- lanes, yield signs for the new arm). Only with the same roads do changed phases
				-- mean the player's (towns joining streets read as hand edits before).
				local oldRoads, newRoads = phases.fingerprintRoads(j.fp), phases.fingerprintRoads(fp)
				local verdict, why
				if j.handEdited then
					verdict, why = "left alone", "phases edited by hand before"
				elseif oldRoads ~= newRoads then
					verdict, why = "road edit", "roads " .. oldRoads .. " -> " .. newRoads
				else
					local edited
					edited, why = phases.phasesEdited(j.ph, currentPhases(node))
					verdict = edited and "phases edited" or "rebuild"
				end
				if dev.traceFollow then log("trace: node %d lanes changed (%s): %s", node, verdict, why) end
				if verdict == "road edit" then
					log("road edit at node %d (no build event; %s): marked repair", node, why)
					j.repair = true
					j.fp, j.pending = fp, nil
				elseif verdict ~= "rebuild" then
					-- the player's own phases: theirs from now on (until applied again); lanes followed
					-- only so this doesn't fire again
					if not j.handEdited then log("follow lane edits: node %d phases edited by hand, left alone", node) end
					j.handEdited = true
					j.fp, j.pending, j.ph = fp, nil, nil
				else
					local failed = rebuild(node, j)
					if failed then
						log("follow lane edits: node %d handed over to drop (%s)", node, failed)
						j.gone, j.why = true, failed
					else
						j.fp, j.pending = fp, nil
						log("follow lane edits: node %d phases rebuilt for its new lanes", node)
					end
				end
			end
		end
	end
	-- (added after the loop: adding keys while traversing isn't allowed)
	for node, entry in pairs(adopt) do s.junctions[tostring(node)] = entry end
end

local function update(_userParams, state, dt)
	if not state:hasEventSubscriptions() then
		state:subscribeToEvent(SIGNS_EVENT)
	end
	local s = state:get() or {}
	if not s.buildSubscribed then
		state:subscribeToEvent("onPreBuildProposal")
		state:subscribeToEvent("onPostBuildProposal")
		s.buildSubscribed = true
		state:set(s)
	end
	local wall = nil
	pcall(function() wall = os.time() end)
	if dt <= 0 and not wall then return end
	if not phasesOk then
		if s.lastError ~= "module" then log("follow lane edits: phases module failed to load: %s", tostring(phases)) end
		s.lastError = "module"
		state:set(s)
		return
	end
	local clock = wall and "wall" or "game"
	if s.clock ~= clock then
		s.clock = clock
		log("follow lane edits: checks on the %s clock", clock)
	end
	s.t = (s.t or 0) + math.max(dt, 0)
	local now = wall or s.t
	-- far ahead: a wall clock time read back on game time (or the clock changed)
	if (s.nextCheck or 0) > now + 10 * CHECK_EVERY then s.nextCheck = nil end
	if now < (s.nextCheck or 0) then
		if dt > 0 then state:set(s) end
		return
	end
	s.nextCheck = now + CHECK_EVERY
	local ok, err = pcall(follow, s)
	if not ok and tostring(err) ~= s.lastError then log("follow lane edits failed: %s", tostring(err)) end
	s.lastError = not ok and tostring(err) or nil
	state:set(s)
end

local function handleEvent(_userParams, state, _src, id, name, param)
	if id == "apply_command" and (name == "onPreBuildProposal" or name == "onPostBuildProposal") then
		local s = state:get() or {}
		if dev.traceBuilds then
			pcall(function()
				local street = param[1] and param[1].proposal
				log("build %s: %d segments added, %d removed", name == "onPreBuildProposal" and "before" or "after",
					#items(street and street.addedSegments), #items(street and street.removedSegments))
			end)
		end
		if not s.junctions or next(s.junctions) == nil then return end
		local ok, err = pcall(function()
			local street = param[1] and param[1].proposal
			if not street then return end
			if name == "onPreBuildProposal" then beforeBuild(s, street) else afterBuild(s, street) end
		end)
		if not ok then log("follow road edits: %s", tostring(err)) end
		state:set(s)
		return
	end
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
			s.junctions[key] = { a = param.a, b = param.b, round = param.round or false, typeId = param.typeId, fp = param.fp,
				settings = type(param.settings) == "table" and param.settings or nil,
				ph = type(param.ph) == "table" and param.ph or nil }
		end
	elseif kind == "reset" then
		s.signs, s.diamonds, s.junctions, s.replaced = nil, nil, nil, nil
		log("uninstall: records cleared")
	elseif kind == "diamondSettings" and type(param.values) == "table" then
		local v = {}
		for k, x in pairs(param.values) do
			if type(x) == "number" then v[k] = x end
		end
		s.diamondSettings = v
	else
		return
	end
	state:set(s)
end

function data()
	return { update = update, handleEvent = handleEvent }
end
