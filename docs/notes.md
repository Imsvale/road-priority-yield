# Yield

Split off from the Smart traffic lights lab (`../Smart traffic lights`) on 2026-10-16. The lab stays the place for experiments; this mod is what came out of the yielding one.

## Why a light

- Cars never give way. The engine does work out precedence per lane connection: `Edge.precedence` on a junction's network edges, resolved from `BaseEdgeStreet.precedenceNode0/1` (YES / NO / AUTO). AUTO follows the road templates' `priority`, a relative precedence scale between road types. But cars don't act on it: at a roundabout without lights, entering cars cut in and the ring backs up. The flag seems to drive only the junction markings.
- A two-phase light at each entry (ring green / entry green, no all-red, skipping allowed) makes the entry wait for gaps in the ring. An invisible light type hides it.

Results (paired runs, details in the lab's `docs/studies/2026-10-15_traffic-manager-feasibility.md`, section 4):
- Steady traffic: stopping on the ring −96%, all stopping −33%, throughput +2%, and the ring never broke down (without lights it did after ~8 minutes).
- Starting from a clogged roundabout: cleared within ~8 minutes, against a slow recovery without lights. Throughput +12%, ring stopping −96%.

## What's in it

- **Priority Road tool** (`content/gui/construction/tools/imsvale_priority_road_tool.script.lua`, added 2026-10-16):
  - **Following the road:** hover a road, and the tool follows it through junctions in both directions, always on to the straightest connected road (at most 45° off).
  - **Roundabout or road:** if that comes back to the start it's a loop, and a round loop (all samples within 12% of the mean radius) is a roundabout. Otherwise it's a priority road. The rules are the same either way; the distinction is for entry signs later.
  - **Phases at each junction:** #1 traffic from the priority road green, 60 s, 0 s minimum, skipping allowed (it ends as soon as the priority road is empty and someone waits). #2 side roads green, 5 s, same.
    - The side phase needs the short cap: skipping only ends a phase early when its own lanes empty, and a long side queue never empties, so 60 s there would hold the priority road for a minute (run B: the entry phase always ran its full 6 s with 150+ cars queued).
    - #3, only with crosswalks: pedestrians.
  - **Junctions with no side road leading in** (exits only) get no light.
  - **Click** applies. If every junction already has it, click removes it (preference None, phases reset to the game's default; earlier custom lights are not restored).
  - **Not handled:** the engine's precedence flags. Auto can give a town-road spoke (610) right of way over a native roundabout's one-way ring (410/430), so the road you click is always the priority road.

- `content/infrastructure/traffic_light/imsvale_yield_invisible.trl.lua` ("Yield (invisible)"): type A's standard light layout with every model shrunk to 1/1000. A type that places no models at all makes the engine drop the light, as if the type were None.
- `content/gui/imsvale_yield/`: Copy / Paste in the traffic light window. It is a `react-replacement-config` wrapping the window's exported recipe, `DoubleSlipSwitchContent` from `gui/entity_window/double_slip_switch.tl`. Paste maps the roads by rotation, the lane connections by road pair and node-relative lane numbers, and the crosswalks through their road.

## Compatibility

The lab mod (`imsvale_smart_traffic_lights`) has the same pieces under other names. With both enabled you get two invisible light types, and one Copy / Paste row: replacements are applied in order and the last one wins. Use one or the other.

## Prior art: Roadcraft: Priority roundabouts (mod.io 6443728, by ueberleitung)

Inspected 2026-10-16 (`C:\Users\Public\mod.io\10640\mods\6443728`, modId `roadcraft_roundabouts`, revision 34). It uses the same trick: two-phase lights with hidden light models, minDuration 0, skipping allowed.

What it does that we don't:
- **One-click tool for a whole roundabout:** it detects a closed one-way loop, applies to every junction on it, and removes again. The original junction settings are journalled in game-script state, so removal restores them (phases remapped if roads were replaced).
- **Phase presets:** ring phase 60, 2, 5, 10 or 20 s; entry phase 1, 3 or 5 s; an extra pedestrian phase where there are crosswalks.
- **Multi-lane rings:**
  - It rewrites lane connections: at exits the outer lane must leave; at entries the ring moves inward, so the entry joins a free outer lane.
  - Inner-lane through traffic stays green during the entry phase, so only the lane the entry merges into stops.
- **Signs:** real models (yield sign plus German 215 / 209 / 214 lane signs). A light model script only knows its position, not which approach is the entry, so the mod pre-generates one light type per combination of entrance compass sectors (32 sectors, ~1,000 types) and hides them from the light-type list in `postRunFn` (`trafficLightTypeRep.setVisible(id, false)`).
- **Hidden lights:** it keeps one invisible model (`inner_blocker.mdl`) per light group plus the signs. It found the same thing we did: emptying the groups loses the light.
- **Ring protection:** `roadDevelopmentLocked` and an invisible edge decoration with `preventParcels` stop towns building inside the ring or rebuilding the ring roads.
- Gamepad support, and lots of verification and diagnostics.

What we have that it doesn't:
- **Any junction, not just roundabouts:** it only handles closed one-way loops (no trams or bus lanes, at most two entrances per junction). With the invisible type and Copy / Paste, any junction can be set up, e.g. a side road yielding to a main road.
- **The engine's precedence flags:** it says there's no addressable priority system. We found the engine resolves `Edge.precedence` per lane connection (from road template `priority`); cars just ignore it. That could pick the priority movements automatically at any junction (the "Make yield" idea below).
- **Copy / Paste** of any light phases between junctions, with roads matched by direction.
- **Node Swatter:** removing the ring's corner nodes, where lane changes otherwise pile up.
- **Measured results** (paired runs).

Worth borrowing:
- Keeping the inner lanes green on multi-lane rings, and the exit / entry lane rewrites.
- Restoring the original settings on removal.
- Hiding helper light types in `postRunFn`.
- Development lock and parcel blocker for the ring.

## Ideas

- Yield sign models: a light type whose models are yield signs instead of shrunk lights. The engine needs some models to keep the light; whether signs work as "light" models (no red/green animation) is untested.
- A "Make yield" button in the light window: phase #1 green for the connections with `precedence=true`, phase #2 for the rest. The engine already says who should have right of way, so it would work at any junction, not just roundabouts.
- Phase durations: what works best for the entry phase (short, skipping allowed) is untested beyond the first setup.
