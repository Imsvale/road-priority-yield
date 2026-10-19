local ssu = require "::/gui/main/stylesheetutil.lua"

-- The Priority Road tool's hover icons (IconOverlay in imsvale_priority_road_tool.script.lua)
-- sit in a FloatingLayout whose children are placed by fractions of the layout. Without a
-- gravity of {-1, -1} (fill) the layout collapses at the left edge and every icon piles up
-- there (2026-10-17). The game gives its CalloutContainer's FloatingLayout the same rule
-- (::/gui/main/callout_container.css.lua).

function data()
	local result = {}
	local a = ssu.makeAdder(result)
	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data

	a("R::ImsvaleRoadPriorityIcons FloatingLayout", {
		gravity = { -1.0, -1.0 },
	})

	-- The priority sign settings window (DiamondSettingsWindow): padding inside, as the game's
	-- popover windows have (::/gui/main/popover_react_util.css.lua), and fixed label and value
	-- columns so the sliders line up. padding / margin: { top, right, bottom, left }.
	-- Centred on screen, as the game centres its dialog popovers: without a position the window
	-- opened in the top left corner every time (2026-10-19).
	a("Window!imsvale-sign-settings", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
	})
	a("Window!imsvale-sign-settings Window::Content", {
		padding = { 8, 12, 12, 12 },
	})
	-- The game's horizontal slider fills its parent's width (gravity -1, size -1); in a row of
	-- its own it collapsed to a dot (2026-10-19).
	a("Slider!imsvale-setting-slider", {
		minSize = { 180, 16 },
	})
	-- A plain Button has an invisible background (it shows only on hover, builtin.css.lua); give
	-- ours the unselected toggle buttons' background so they read as buttons.
	a("Button!imsvale-setting-button", {
		backgroundColor1 = colorDefault.BaseMedium,
		padding = { 6, 12, 6, 12 },
	})
	a("BoxLayout!imsvale-setting-row", {
		margin = { 2, 0, 2, 0 },
	})
	a("TextView!imsvale-setting-label", {
		minSize = { 150, -1 },
		margin = { 0, 8, 0, 0 },
	})
	a("TextView!imsvale-setting-value", {
		minSize = { 60, -1 },
		margin = { 0, 0, 0, 8 },
	})
	a("BoxLayout!imsvale-setting-buttons", {
		margin = { 8, 0, 0, 0 },
	})
	a("BoxLayout!imsvale-setting-buttons Button", {
		margin = { 0, 8, 0, 0 },
	})

	return result
end
