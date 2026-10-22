# Yield

Split off from the Traffic Lab (`../traffic-lab`) on 2026-10-16. The lab stays the place for experiments; this mod is what came out of the yielding one.

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
  - **Phases at each junction:** #1 traffic from the priority road green, 60 s, 0 s minimum, skipping allowed (it ends as soon as the priority road is empty and someone waits). #2 side roads green, 1 s, same; on roundabouts plus the exits (ring onto a side road). Ordinary junctions leave the exits red in #2 (see below).
    - The side phase needs the short cap: skipping only ends a phase early when its own lanes empty, and a long side queue never empties, so 60 s there would hold the priority road for a minute (run B: the entry phase always ran its full 6 s with 150+ cars queued).
    - Crosswalks are green in both phases (user, 2026-10-20). Until priority road 44 they had a phase #3 of their own; the lab's studies ran with pedestrians green throughout.
  - **Priority isn't geometry** (user, 2026-10-20): a main road can turn at a near-90° corner where a side road joins, and priority goes on with the main road. So when a priority arm is bulldozed, the junction is dropped (priority signs after it removed) rather than guessing a new priority pair from the shape. The player clicks the road again.
  - **Junctions with no side road leading in** (exits only) get no light.
  - **Click** applies. If every junction already has it, click removes it (preference Auto and type -1 since priority road 67: the junction is the game's again; earlier custom lights are not restored).
  - **Not handled:** the engine's precedence flags. Auto can give a town-road spoke (610) right of way over a native roundabout's one-way ring (410/430), so the road you click is always the priority road.

- `content/infrastructure/traffic_light/imsvale_yield_invisible.trl.lua` ("Yield (invisible)"): type A's standard light layout with every model shrunk to 1/1000. A type that places no models at all makes the engine drop the light, as if the type were None.
- Copy / Paste in the traffic light window started here and moved to its own mod, `../traffic-light-copy` (2026-10-17).

## Multi-lane rings: a heads-up from Roadcraft

Roadcraft refuses the test roundabout (2026-10-17 log) at node 940:
- **Their rule:** on a multi-lane ring they only let entry lanes join the curb lane (their "outer": outside of the ring by radius, the rightmost lane with right-hand traffic).
- **The problem there:** the ring has three lanes there, and the two-lane entry 12301 has lane 2 connected only to the median lane (`12301:2 -> 652:1`; outbound lane numbers count from the median side, so `652:3` is the curb lane). Their rule would strand that lane.
- **For us now:** we don't rewrite lane connections, so it doesn't apply.
- **For later:** if we adopt multi-lane handling (curb lane must exit, the other lanes stay green during the entry phase), a two-lane entry must keep a lane to go to. Either let it feed more than the curb lane, keeping those lanes red during the entry phase, or rewrite its lanes onto the outer lane instead of dropping them.

## Prior art: Roadcraft: Priority roundabouts (mod.io 6443728, by ueberleitung)

Inspected 2026-10-16 (`C:\Users\Public\mod.io\10640\mods\6443728`, modId `roadcraft_roundabouts`, revision 34). It uses the same trick: two-phase lights with hidden light models, minDuration 0, skipping allowed.

What it does that we don't:
- **One-click tool for a whole roundabout:** it detects a closed one-way loop, applies to every junction on it, and removes again. The original junction settings are journalled in game-script state, so removal restores them (phases remapped if roads were replaced).
- **Phase presets:** ring phase 60, 2, 5, 10 or 20 s; entry phase 1, 3 or 5 s; an extra pedestrian phase where there are crosswalks.
- **Multi-lane rings:**
  - It rewrites lane connections: at exits the curb lane must leave; at entries the ring moves toward the median, so the entry joins a free curb lane.
  - Through traffic in the lanes nearer the median stays green during the entry phase, so only the lane the entry merges into stops.
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

Problems it addresses that we may need to solve too. These are not things to copy: work out our own solution from the base game and the API docs (user, 2026-10-18).
- Keeping the median-side lanes green on multi-lane rings, and the exit / entry lane rewrites.
- Restoring the original settings on removal.
- Hiding helper light types in `postRunFn`.
- Development lock and parcel blocker for the ring.

## Sign placement (2026-10-18)

How the Priority Road tool places signs, what the user saw in game, and what is still open. The aim is to work everything out from the roads involved and hard-code as little as possible.

**Rule (priority road 14):**
- **Which sign:** a yield sign on each yielding approach; on a roundabout, the combined sign (yield triangle on top, round blue roundabout sign below). No priority diamonds at junctions.
- **Along the road:** `SIGN_BACK` = 0.5 m back from the junction edge. The junction edge is where the approach's lane curves end, which already moves out with a bigger junction (a wider crossing / priority road).
- **Across the road:** on the right of the incoming traffic (right-hand traffic), past the curb. The curb is the outer edge of the outermost lane that isn't for pedestrians (driving lanes, and shoulders without transport modes as on highways). The sign stands 0.5 m past the curb on a raised sidewalk, otherwise 1.0 m.
- **Facing:** the oncoming traffic.

**Observed in game:**
- **16 m town road** (2 × 3 m raised sidewalks, 10 m of driving lanes), with priority road 13: well placed sideways (5.5 m from the centre). Along the road it stood 2-3 m too far back. In reality it would stand right before a crosswalk that sits as close to the junction as it can, so `SIGN_BACK` went from 3 m to 0.5 m. Still to check: whether that lands it before the crosswalk.
- **Roundabout entry, 4-lane two-way country road** (country_new_medium: 2 m level pedestrian strips, then 5 + 4 m driving lanes each side) into a 2-lane ring, with priority road 13: about 2 m too far out. The cause: there is no raised sidewalk, so the old rule put the sign 1 m outside the whole 22 m road (12 m out). The curb (the driving lanes' edge) is at 9 m. The new rule gives 10 m.
- **Roundabout entries along a noise barrier:** the sign ends up inside the barrier.

**Open:**
1. **Crosswalks:** read where the junction's crosswalks are and put the sign just before them, instead of a fixed distance from the junction edge. Needs a way to find a crosswalk's position (`BASE_NODE_CONFIG.crosswalks` lists the crosswalk entities).
2. **The crossing road's size:** the user expects it to matter most at the entry. Check whether the junction edge already captures it well enough, across small and large crossings.
3. **Pedestrian lanes on built roads:** the tool recognises them by their `PERSON` transport mode, trying the enum value, its name and 0, since the stored form isn't documented. Its log line per sign ("curb … m from the centre") shows what it read; on the country road it should say 9 m.
4. **Asymmetric roads** (one-way roads, roads with different sides): the curb is taken as symmetric about the centre line. The right-hand side's actual lanes are better.
5. **Left-hand traffic:** the sign side and the roundabout sign's arrows assume right-hand traffic.
6. **Noise barriers and other things beside the road:** options the user named: a sign mounted on the barrier, hiding the barrier's last section, or a gantry.
7. **Multi-lane approaches and one-way entries:** a second sign on the left (median) side may be expected; one-way roads would need one there.
8. **Priority diamonds:** done (priority road 25): at the start of a priority road and 60 m after junctions, skipped between close junctions (see CLAUDE.md). Later: the speed limit + diamond combination common in Norway.

## Ideas

- **Lane configuration as part of the setup** (user 2026-10-17):
  - Done (2026-10-19): ordinary junctions (see "Lanes at ordinary junctions" below) and roundabouts (`roundaboutLanes`, the user's rules: the ring steps one lane toward the exits at each junction; see CLAUDE.md). The roundabout rule isn't measured yet.
  - The phases must match: every lane connection green in some phase. Otherwise cars choose a lane for a turn its connections allow, never get a green, and are stranded.
  - Lanes and phases go in one proposal.

- Yield sign models: a light type whose models are yield signs instead of shrunk lights. The engine needs some models to keep the light; whether signs work as "light" models (no red/green animation) is untested.
- A "Make yield" button in the light window: phase #1 green for the connections with `precedence=true`, phase #2 for the rest. The engine already says who should have right of way, so it would work at any junction, not just roundabouts.
- Phase durations: what works best for the entry phase (short, skipping allowed) is untested beyond the first setup.

## Ordinary junctions (T and 4-way), from the lab (2026-10-19)

Studied in the lab (`../traffic-lab/docs/studies/2026-10-18_give-way-junctions.md`) with paired runs on two-lane roads, measuring forced entries (a car entering while one it should give way to is close) and needless waits.

- **Phase #2 without the exits** ("side" in the study) is the best plan found:
  - At a 4-way the exits (the priority road's turns into the side roads) cross or merge with the side roads' traffic. Leaving them red in #2 cut forced side road entries from 33 to 25 in 15 minutes, at 28% more side road waiting and no cost to the priority road.
  - At a T it made no difference.
  - The tool now does this for everything but roundabouts. Roundabouts keep their own plan, unchanged.
- **Tried and worse:**
  - more phases: a phase per conflicting side movement, or the side roads' left turns apart. Each phase change adds conflicts: cars still crossing, and priority cars arriving a few seconds after the switch;
  - priority road movements kept green in the side phase;
  - a shorter phase #1.
- **Engine limits, beyond what phases can do:**
  - A phase holds while anything green in it has traffic, so phase #1 can't end on a gap in just the direction a side road movement conflicts with.
  - The engine only notices approaching cars a few seconds out: side cars pull out with a priority car about 1.5–4 s away.
  - About a quarter of the side road's cars at a 4-way still enter forced.
- **Junctions already set up** keep their old phases until the yielding is removed and applied again with the tool.

- **Phase #2's maximum is a balance knob, not something to optimise** (user, 2026-10-19). Raising it moves throughput to the side road at a small cost to the priority road. 1 s is the default because it gives the clearest yielding. A side road congested at 1 s is a sign the junction needs upgrading to one built for traffic from all directions, not a reason to lengthen the side phase.

## Lanes at ordinary junctions (2026-10-19)

Two opt-in tool settings, both default No:
- **"Overwrite lanes":** each turn lands in its own lane instead of fanning out into every lane of the road it turns into. Right turns map their lanes curb first onto the road's lanes curb first, left turns median first onto median first. Which lanes turn stays as it was; straight on and U-turns are untouched.
- **"Dedicated turn lanes"** (only with the first on): straight on is dropped from lanes that turn, as long as another lane still goes straight on.

Every lane still reaches every road it reached before, so routes stay valid. Lanes and phases are set together in one node config proposal.

**Why**, from the lab's paired runs (`../traffic-lab/docs/studies/2026-10-18_give-way-junctions.md`, runs 15–25), forced entries:

| Junction | Game lanes | Overwrite | Dedicated |
|---|---|---|---|
| 4-lane priority road, 2-lane side roads | 125 | 124 | – |
| All 4-lane | 161 | 149 | – |
| 6-lane priority road, 4-lane side roads | 227 | 185 | 184 |
| All 6-lane | 243 | 220 | 221 |

- **What the lanes fix:** turns that merged into the same lane. The priority road's left turns gain most, about a third fewer forced on wide roads.
- **What they can't fix:** the side roads' left turns cross the opposite straight-on traffic, so they stay forced nearly every time. That's where a player upgrades to a signalled junction (user).
- **Dedicated turn lanes:** cost no throughput in these tests. Their known risk is cars changing lanes into a queue that reaches the last upstream node: −32% at the lab's node 2010 (2026-10-15), though with protected-left phases there.
- **Roundabouts have their own rule** (`roundaboutLanes`), not this one.
- **Removing the yielding** leaves the rewritten lanes in place.

## Follow lane edits (2026-10-19; always on since priority road 47, no switch)

A player who edits a yielding junction's lanes by hand can leave connections without a green: new or recreated connections end up red in every phase (lab finding). With the tool's "Follow lane edits" on, the game script watches the junctions the tool set up and rebuilds their phases after a lane edit, keeping the player's lanes. See CLAUDE.md for how it works. Experimental until it proves stable and reliable (user).

