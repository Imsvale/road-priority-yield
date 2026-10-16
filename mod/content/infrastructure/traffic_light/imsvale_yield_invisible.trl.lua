-- Invisible traffic light: a light type that places no models, for faking yielding with a
-- light (e.g. a two-phase light without all-red phases at a roundabout entry).
-- The model script runs the game's standard layout (type A's models) and shrinks every model
-- to 1/1000 size. Placing no models at all made the engine drop the light (2026-10-16).

function data()
	return {
		availability = {
			yearFrom = 0,
		},
		description = {
			name = "Yield (invisible)",
			icon = "::/infrastructure/traffic_light/traffic_light_non.tga",
		},
		tryOpposite = false,
		modelScript = {
			fileName = "imsvale_yield_invisible.script@modelFn",
			params = {
				models = {
					trafficLightPole = "::/infrastructure/traffic_light/traffic_light_a/pole.mdl",
					pedestrianPole = "::/infrastructure/traffic_light/traffic_light_a/pedestrian_pole.mdl",
					beam = {
						"::/infrastructure/traffic_light/traffic_light_a/beam_1.mdl",
						"::/infrastructure/traffic_light/traffic_light_a/beam_r.mdl",
					},
					trafficLight = {
						"::/infrastructure/traffic_light/traffic_light_a/traffic_light_1.mdl",
						"::/infrastructure/traffic_light/traffic_light_a/traffic_light_r.mdl",
					},
					pedestrianLight = "::/infrastructure/traffic_light/traffic_light_a/pedestrian_light.mdl",
				},
				params = {
					offset = -0.25,
					beamWidth = { 6 + .25, 3 },
					lightOffset = { 4.5, 1.5 },
					poleTrafficLight = true,
				},
			},
		},
		categoryList = {
			categories = {
				"temperate.clima", "subarctic.clima", "dry.clima", "tropical.clima",
			},
		},
	}
end
