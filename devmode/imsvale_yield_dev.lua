-- Dev switches, the dev build's version (dev mode copies it over
-- mod/content/scripts/imsvale_yield_dev.lua, whose committed version has them all off).
return {
	traceBuilds = true, -- game script: one log line per build proposal (segments added / removed)
	traceFollow = true, -- game script: why lane following rebuilt a junction or left its phases alone
	watchAhead = true, -- game script: find junctions joined onto a priority stretch and make them yield (priority road 71; not in a release until tested and its cost approved, user 2026-11-07)
	traceLanes = true, -- tool: per junction the lane rules touch, the side read from the roads and the lane connections before and after
	menuFirst = true, -- tool: first in the Roads > tools list, easier to reach while testing (user, 2026-11-16)
}
