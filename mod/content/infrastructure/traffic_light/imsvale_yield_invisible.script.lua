-- Model script for imsvale_yield_invisible.trl.lua: the game's standard light layout with every
-- model shrunk to 1/1000 size.
-- Emptying the groups instead (version 1) made the engine drop the light altogether, as if
-- the light type were None: no phases in the window, no BASE_NODE_TRAFFIC_LIGHT (2026-10-16).
local trafficlightutil = require "::/infrastructure/traffic_light/trafficlightutil.lua"

local SCALE = 0.001

local standard = trafficlightutil.standardLights()

-- Scale the rotation/scale part of a 4x4 column-major matrix (16 numbers), keeping the
-- position (entries 13..15).
local function shrink(t)
	for _, i in ipairs({ 1, 2, 3, 5, 6, 7, 9, 10, 11 }) do
		t[i] = t[i] * SCALE
	end
	return t
end

local function modelFn(captureParams, args)
	local result = standard(captureParams, args)
	local ok, err = pcall(function()
		for _, group in ipairs(result.models) do
			for _, model in ipairs(group) do
				model.transf = shrink(model.transf)
			end
		end
	end)
	if not ok then print("[yield] shrinking failed, lights stay visible: " .. tostring(err)) end
	return result
end

function data()
	return { modelFn = modelFn }
end
