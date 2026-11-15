local ssu = require "::/gui/main/stylesheetutil.lua"
local color_util = require "::/gui/main/color_util.tl"

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
	-- The Uninstall window (priority road 48): centred like the old settings window.
	a("Window!imsvale-uninstall", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
	})
	a("Window!imsvale-uninstall Window::Content", {
		padding = { 8, 12, 12, 12 },
		minSize = { 200, -1 },
	})
	-- Its buttons in the theme's blue, so a lone button stands out (user, 2026-11-15): AccentMedium,
	-- the game's selected toggle buttons' colour (builtin.css.lua), with its hover and pressed
	-- shades. Only this class: with imsvale-setting-button as well, that rule (later in this file,
	-- BaseMedium) won, and the buttons showed no background until hovered (priority road 86).
	a("Button!imsvale-uninstall-button", {
		margin = { 8, 0, 0, 0 },
		padding = { 6, 12, 6, 12 },
		backgroundColor1 = colorDefault.AccentMedium,
	})
	a("Button!imsvale-uninstall-button:hover", {
		backgroundColor1 = color_util.getHoverFromRaw(colorDefault.AccentMedium),
	})
	a("Button!imsvale-uninstall-button:active", {
		backgroundColor1 = color_util.getActiveFromRaw(colorDefault.AccentMedium),
	})
	-- The Uninstall button (priority road 91): an element of the tool's icon overlay, placed by the
	-- tool at the Settings window's bottom right corner (settingsCorner). 87-90 put it in a window of
	-- its own, which blocked Back while the tool was open.
	-- The dimmer kind (user, 2026-11-15: it needn't stand out): the unselected toggle buttons'
	-- BaseMedium, with the game's own hover border (Button:hover, builtin.css.lua).
	a("Button!imsvale-uninstall-proxy-button", {
		padding = { 6, 12, 6, 12 },
		backgroundColor1 = colorDefault.BaseMedium,
	})
	a("TextView!imsvale-uninstall-section", {
		margin = { 12, 0, 0, 0 },
	})
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
