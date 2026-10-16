-- Entry point for the react-replacement-config (replacements.res.lua), as in the line-ui mod.
-- Runs once before the game UI starts; afterwards recipes can no longer be replaced.

local light_copy = ug_require "/gui/imsvale_yield/light_copy.lua"

local function doReplace(replacementApi)
	print("[yield] replacing DoubleSlipSwitchContent (" .. light_copy.VERSION .. ")")
	replacementApi.ReplaceRecipe(light_copy.original, light_copy.Content)
end

function data()
	return { doReplace = doReplace }
end
