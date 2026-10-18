-- A sign as a free-standing construction: just its model (collider NONE, so it can stand right
-- beside the road). Placed by the Priority Road tool (SimpleProposal.constructionsToAdd at a world
-- transform); once built the game keeps it as a plain asset, whose id the tool stores.
--
-- Not an edge object: on streets the engine only takes stops as edge objects (an edge object
-- without streetTerminal data crashed it in street_util::GetEdgeObjectCategory, 2026-10-18), and
-- a SimpleProposal can only attach edge objects to segments it adds itself.
function data()
	return {
		availability = { yearFrom = 0, yearTo = 0 },
		description = {
			name = "Yield sign (Norwegian)",
			description = "",
		},
		menuCategory = { categories = {} },
		updateScript = {
			fileName = "imsvale_sign.script@updateFn",
			params = { model = "imsvale_road_priority_yield::/models/model/imsvale_yield_sign_no/imsvale_yield_sign_no.mdl" },
		},
		params = {},
	}
end
