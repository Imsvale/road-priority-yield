-- Dev switches, the dev build's version (dev mode copies it over
-- mod/content/scripts/imsvale_yield_dev.lua, whose committed version has them all off).
return {
	traceBuilds = true, -- game script: one log line per build proposal (segments added / removed)
	traceFollow = true, -- game script: why lane following rebuilt a junction or left its phases alone
}
