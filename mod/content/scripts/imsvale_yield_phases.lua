-- Phase plans and phase building for yielding junctions, shared by the Priority Road tool (GUI)
-- and the yield game script (engine state: "Follow lane edits" rebuilds the phases when a
-- junction's lanes change). Loaded with ug_require "/scripts/imsvale_yield_phases.lua" (a path
-- starting with "/" resolves inside the calling mod, as the base game's own game scripts load
-- "/scripts/...").

local M = {}

-- Phase plans: one for roundabouts, one for everything else (user, 2026-10-19). Maxima in
-- seconds; every phase has a 0 s minimum and may be skipped.
-- - priority: phase #1; it ends early when the priority road is empty;
-- - yield: phase #2; short, or a long side queue would hold the priority road (1 s: user, 2026-10-17);
-- - crosswalks are green in both phases: no pedestrian phase (user, 2026-10-20; the lab's studies
--   ran with pedestrians green throughout);
-- - exitsInYield: exits (priority road onto a side road) also green in phase #2;
-- - lanes: the lane rule "Overwrite lanes" applies ("roundabout": roundaboutLanes; "junction":
--   rewriteLanes, with "Dedicated turn lanes"; both in the tool).
M.PLANS = {
	roundabout = { priority = 60.0, yield = 1.0, exitsInYield = true, lanes = "roundabout" },
	junction = { priority = 60.0, yield = 1.0, exitsInYield = false, lanes = "junction" },
}

-- Phases for one junction, or nil and why not. `a`, `b`: the priority road's segments; `round`:
-- a roundabout; `conns`: the lane connections the phases are for (default: the junction's own).
-- Returns states, why, side road segments.
function M.junctionStates(node, a, b, cfg, round, conns)
	local p = round and M.PLANS.roundabout or M.PLANS.junction
	local priority = { [a] = true, [b] = true }
	conns = conns or cfg.laneConnections
	local nConn = #conns
	local nCross = #cfg.crosswalks
	local sideIn, sideSegs = 0, {}
	for _, c in ipairs(conns) do
		if not priority[c.segment0] then sideIn = sideIn + 1 sideSegs[c.segment0] = true end
	end
	if sideIn == 0 then return nil, "No side road leads in", sideSegs end
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
		phase(p.priority, function(c, cross) return cross ~= nil or priority[c.segment0] end),
		phase(p.yield, function(c, cross)
			return cross ~= nil or not priority[c.segment0] or (p.exitsInYield and not priority[c.segment1])
		end),
	}
	return states, nil, sideSegs
end

-- The junction's lane connections as a string, in their order (the phases' lockedLanes count
-- them by position, so a reorder matters too), plus the crosswalk count.
function M.fingerprint(cfg)
	local parts = {}
	for _, c in ipairs(cfg.laneConnections) do
		parts[#parts + 1] = c.segment0 .. ":" .. c.lane0 .. ">" .. c.segment1 .. ":" .. c.lane1
	end
	parts[#parts + 1] = "x" .. #cfg.crosswalks
	return table.concat(parts, " ")
end

-- The phases as written, to tell the player's phase edits from what a lane edit alone does
-- (2026-10-22). BASE_NODE_CONFIG.userModifiedTrafficLightStates can't: our own proposals set it
-- too. { timing = "duration/min/skip;...", green = { [connection or "x<crosswalk>"] = "12" } }:
-- for each lane connection (by what it connects, not its position) and crosswalk (by its entity:
-- the crosswalks' order changed over a save reload, 2026-10-22), the phases it's green in. From the
-- given connections, crosswalks and states, so a rebuild can store what it sends before the engine
-- has applied it.
function M.phaseFingerprint(conns, crosswalks, states)
	local timing, green = {}, {}
	local keys = {}
	for i, c in ipairs(conns) do keys[i - 1] = c.segment0 .. ":" .. c.lane0 .. ">" .. c.segment1 .. ":" .. c.lane1 end
	for i, x in ipairs(crosswalks) do keys[#conns + i - 1] = "x" .. tostring(x) end
	for _, key in pairs(keys) do green[key] = "" end
	for p, st in ipairs(states) do
		timing[#timing + 1] = string.format("%g/%g/%s", st.duration, st.minDuration, tostring(st.canSkip))
		local locked = {}
		for _, l in ipairs(st.lockedLanes) do locked[l] = true end
		for idx, key in pairs(keys) do
			if not locked[idx] then green[key] = green[key] .. p end
		end
	end
	return { timing = table.concat(timing, ";"), green = green }
end

-- Whether the phases now differ from `old` (a phaseFingerprint) by more than a lane edit makes:
-- a lane edit keeps the phases of the connections that survive, makes new ones red in every phase
-- (lab, 2026-10-19) and drops removed ones. So: other timings or phase count, a surviving
-- connection green in other phases, or a new one green anywhere.
-- Returns edited, and why (for the log).
function M.phasesEdited(old, now)
	if type(old) ~= "table" or type(old.green) ~= "table" then return false, "no phases recorded" end
	if old.timing ~= now.timing then return true, "timings " .. tostring(old.timing) .. " -> " .. now.timing end
	for key, g in pairs(now.green) do
		local was = old.green[key]
		if was == nil then
			if g ~= "" then return true, "new " .. key .. " green in " .. g end
		elseif was ~= g then
			return true, key .. " green in " .. (was == "" and "none" or was) .. " -> " .. (g == "" and "none" or g)
		end
	end
	return false, "only what the lane edit explains"
end

-- The roads (segment ids) a lane fingerprint's connections use, as a sorted string.
function M.fingerprintRoads(fp)
	local set, list = {}, {}
	for a, b in tostring(fp or ""):gmatch("(%d+):%d+>(%d+):%d+") do
		set[a], set[b] = true, true
	end
	for s in pairs(set) do list[#list + 1] = tonumber(s) end
	table.sort(list)
	for i, s in ipairs(list) do list[i] = tostring(s) end
	return table.concat(list, " ")
end

return M
