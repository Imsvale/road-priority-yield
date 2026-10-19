-- Mounts the Priority Road tool's FollowRoadEdits for the whole session (experimental "Follow road
-- edits"; see the tool's script). ModEntryPointExtension is the game's slot for mod components in
-- the game UI.
function data()
	return {
		type = "react-plugin ::ModEntryPointExtension",
		data = {
			filePath = "imsvale_road_priority_yield::/gui/construction/tools/imsvale_priority_road_tool.script@FollowRoadEdits",
		}
	}
end
