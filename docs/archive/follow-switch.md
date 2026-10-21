# Archived: the "Follow road edits" switch (removed in priority road 47, 2026-10-20)

Until priority road 46 the tool had a checkbox under General, "[Experimental] Follow road edits" (first "Follow lane edits"). With it on, the game script rebuilt a yielding junction's phases after its lanes were edited, and the tool re-applied a junction after a road edit (a type change). With it off, a road edit only got the junction checked: dropped if it couldn't yield any more, otherwise left with the game's reverted config.

Why it went (user, 2026-10-20): an edit and a bulldozing make the game revert our config alike, so the action shouldn't decide whether it's fixed. And the switch was one value per save, sent on every apply, while players read it as a setting for the roads they click (the last apply's value counted for all). Now every road and lane edit at our junctions is repaired.

To bring it back: put these pieces back where they were, and restore the `s.follow` conditions (the game script's lane check in `update` and the `repair` / `check` choice in `afterBuild`; the tool's watcher chose `repair` only with `s.follow` or `j.always`, else `check`).

## The parameter key

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
local FOLLOW_PARAM = "imsvaleFollowLaneEdits" -- checkbox, as the lane settings
```

## Sending the switch to the game script

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
local function sendFollow(on)
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(SIGN_GAME_SCRIPT, SIGN_EVENT_ID, SIGN_EVENT_NAME, { kind = "follow", on = on }))
end

```

## Last value sent (module state)

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
local lastFollow = nil -- "Follow lane edits" last sent
```

## Reading the checkbox (in the action recipe)

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
	local function followSetting()
		local on = false
		pcall(function() on = panel(params)[FOLLOW_PARAM] == 2 end)
		return on
	end

```

## Sending it on change (in the action recipe's onStep)

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
		-- The switch as shown, sent on the first look and on every change.
		local follow = followSetting()
		if follow ~= lastFollow then
			local ok, err = pcall(sendFollow, follow)
			if ok then lastFollow = follow else log("follow lane edits: %s", tostring(err)) end
		end
```

## Sending it on every apply (onSelect, after apply)

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
				pcall(sendFollow, followSetting())
```

## The checkbox in the parameter list

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
			{
				group = FOLLOW_PARAM,
				key = FOLLOW_PARAM,
				name = "[Experimental] Follow road edits",
				tooltip = "Experimental",
				tooltips = { "Experimental: re-apply the yielding after the road or its lanes are edited" },
				values = { "Yes" },
				defaultIndex = 1,
				resetOnCategoryChange = false,
				uiType = api.type.enum.ScriptParamType.CheckBox,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Default,
				preserveValueInAllCategories = true,
				checkEnabledFn = inSection("general"),
			},
```

## registerJunction: clearing a check mark

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
	elseif job.checked then
		param = { node = job.node, checked = true }
```

## repair(): the check mode (following off)

`gui/construction/tools/imsvale_priority_road_tool.script.lua`

```lua
			elseif item.mode == "check" then
				log("follow road edits: node %d checked, still yields (following off: not re-applied)", node)
				registerJunction({ node = node, checked = true })
```

## Game script update(): lane following only with the switch on

`game_mechanics/imsvale_yield_signs/imsvale_yield_signs.script.lua`

```lua
	if dt <= 0 then return end
	if not s.follow then return end
```

## Game script afterBuild(): repair only with the switch on, else check

`game_mechanics/imsvale_yield_signs/imsvale_yield_signs.script.lua`

```lua
			elseif s.follow then
				j.repair, mark = true, "repair"
			else
				j.check, mark = true, "check (following off)"
			end
```

## Game script handleEvent(): the switch message

`game_mechanics/imsvale_yield_signs/imsvale_yield_signs.script.lua`

```lua
	elseif kind == "follow" then
		local on = param.on == true
		if on ~= (s.follow == true) then log("follow lane edits: %s", on and "on" or "off") end
		s.follow = on
```

## Game script handleEvent(): clearing a check mark

`game_mechanics/imsvale_yield_signs/imsvale_yield_signs.script.lua`

```lua
		elseif param.checked then
			if s.junctions[key] then s.junctions[key].check = nil end
```

