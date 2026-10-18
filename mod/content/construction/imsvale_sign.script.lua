-- updateFn shared by the sign constructions (imsvale_*_sign.con): one subconstruction with just
-- the sign model given in the .con's updateScript.params (`model`), at the construction's origin.
-- No colliders and no terrain alignment, so it neither blocks nor digs. (TF3 takes models only
-- inside `subconstructions`; a top-level `models` list gave the game's stand-in box, sunk into a
-- hole, 2026-10-18.) Once built, the game keeps a sign as a plain asset (ASSET_GROUP).

local function updateFn(captureParams, _params)
	return {
		subconstructions = {
			{
				tag = 1,
				models = {
					{
						id = captureParams.model,
						transf = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
					},
				},
				colliders = {},
				terrainAlignmentLists = {},
			},
		},
		cost = 0,
	}
end

function data()
	return { updateFn = updateFn }
end
