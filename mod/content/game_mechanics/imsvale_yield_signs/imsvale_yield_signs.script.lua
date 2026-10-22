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
--   junctions = { ["<node>"] = { a, b, round, typeId, fp, ph, handEdited, pending, settings, repair (always) | gone | check } },
--   newJunctions = { ["<node>"] = { split = old segment, toward = our junction } }: junctions that
--     appeared on a priority road when a road was joined onto it (a segment split), not yielding;
--     only recorded so far (priority road 68, 2026-10-22),
--   splitting = { ... }: between a build's before and after events, the priority segments it removes,
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

-- Before a build: the removed segments that end at a registered junction (priority or side road),
-- with their nodes and directions away from each end. And the removed segments that are part of a
-- priority road (the next junction along the road either way is ours and the road arrives there
-- on a priority segment), to find new junctions on it afterwards (2026-10-22: towns join new
-- streets onto existing ones by splitting a segment).
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
		if seg and e then
			pcall(function()
				for _, from in ipairs({ e.node0, e.node1 }) do
					local j, arriving = nextJunction(seg, from)
					local entry = j and s.junctions[tostring(j)]
					if entry and not entry.gone and (arriving == entry.a or arriving == entry.b) then
						local p0 = api.engine.getComponent(e.node0, CT.BASE_NODE).position
						local p1 = api.engine.getComponent(e.node1, CT.BASE_NODE).position
						s.splitting = s.splitting or {}
						s.splitting[tostring(seg)] = { node0 = e.node0, node1 = e.node1, toward = j,
							p0 = { x = p0.x, y = p0.y }, p1 = { x = p1.x, y = p1.y },
							t0 = { x = e.tangent0.x, y = e.tangent0.y }, t1 = { x = e.tangent1.x, y = e.tangent1.y } }
						return
					end
				end
			end)
		end
	end
end

-- Distance from (x, y) to a segment's curve (cubic Hermite from its end positions and tangents).
local function distanceToCurve(c, x, y)
	local best = math.huge
	for i = 0, 32 do
		local s = i / 32
		local s2, s3 = s * s, s * s * s
		local h00, h10, h01, h11 = 2 * s3 - 3 * s2 + 1, s3 - 2 * s2 + s, -2 * s3 + 3 * s2, s3 - s2
		local px = h00 * c.p0.x + h10 * c.t0.x + h01 * c.p1.x + h11 * c.t1.x
		local py = h00 * c.p0.y + h10 * c.t0.y + h01 * c.p1.y + h11 * c.t1.y
		best = math.min(best, math.sqrt((px - x) ^ 2 + (py - y) ^ 2))
	end
	return best
end

-- After a build: new junctions on a priority road, where a removed priority segment (`splitting`)
-- was split by a road joining it. They don't yield: logged and recorded (`newJunctions`) for now.
local function findNewJunctions(s, street)
	if not s.splitting or next(s.splitting) == nil then return end
	local nodes = {}
	for _, x in ipairs(items(street.addedSegments)) do
		local e = x.comp
		if x.entity and x.entity >= 0 and e then nodes[e.node0] = true nodes[e.node1] = true end
	end
	for node in pairs(nodes) do
		if not s.junctions[tostring(node)] and api.engine.entityExists(node)
			and #items(api.engine.system.streetSystem.getNodeStreetSegments(node)) >= 3 then
			local p = api.engine.getComponent(node, CT.BASE_NODE).position
			for segKey, c in pairs(s.splitting) do
				if node ~= c.node0 and node ~= c.node1 and distanceToCurve(c, p.x, p.y) < 2.0 then
					s.newJunctions = s.newJunctions or {}
					s.newJunctions[tostring(node)] = { split = tonumber(segKey), toward = c.toward }
					log("new junction %d on the priority road (segment %s split), next to junction %d", node, segKey, c.toward)
					break
				end
			end
		end
	end
	s.splitting = nil
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
	j.ph = phases.phaseFingerprint(cfg.laneConnections, cfg.crosswalks, states)
	return nil
end

-- The junction's phases as they are now (phases.phaseFingerprint).
local function currentPhases(node)
	local cfg = api.engine.getComponent(node, CT.BASE_NODE_CONFIG)
	return phases.phaseFingerprint(cfg.laneConnections, cfg.crosswalks, cfg.trafficLightConfig.states)
end

local function follow(s)
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
			if name == "onPreBuildProposal" then
				beforeBuild(s, street)
			else
				afterBuild(s, street)
				findNewJunctions(s, street)
			end
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
