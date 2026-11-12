-- Dev switches. Committed with all of them off, which is what a release has; on the dev branch,
-- dev mode puts devmode/imsvale_yield_dev.lua here instead (devmode/devmode.conf, ../RELEASING.md).
return {
	traceBuilds = false, -- game script: one log line per build proposal (segments added / removed)
	traceFollow = false, -- game script: why lane following rebuilt a junction or left its phases alone
	watchAhead = false, -- game script: find junctions joined onto a priority stretch and make them yield (priority road 71; not in a release until tested and its cost approved, user 2026-11-07)
	traceLanes = false, -- tool: per junction the lane rules touch, the side read from the roads and the lane connections before and after
}
