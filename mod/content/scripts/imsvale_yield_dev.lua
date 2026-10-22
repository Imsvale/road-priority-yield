-- Dev switches. Committed with all of them off, which is what a release has; on the dev branch,
-- dev mode puts devmode/imsvale_yield_dev.lua here instead (devmode/devmode.conf, ../RELEASING.md).
return {
	traceBuilds = false, -- game script: one log line per build proposal (segments added / removed)
	traceFollow = false, -- game script: why lane following rebuilt a junction or left its phases alone
}
