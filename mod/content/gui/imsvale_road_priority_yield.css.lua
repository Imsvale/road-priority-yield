local ssu = require "::/gui/main/stylesheetutil.lua"

-- The Priority Road tool's hover icons (IconOverlay in imsvale_priority_road_tool.script.lua)
-- sit in a FloatingLayout whose children are placed by fractions of the layout. Without a
-- gravity of {-1, -1} (fill) the layout collapses at the left edge and every icon piles up
-- there (2026-10-17). The game gives its CalloutContainer's FloatingLayout the same rule
-- (::/gui/main/callout_container.css.lua).

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	a("R::ImsvaleRoadPriorityIcons FloatingLayout", {
		gravity = { -1.0, -1.0 },
	})

	return result
end
