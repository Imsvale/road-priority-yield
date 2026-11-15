Here are the steps for checklist item 6, in a suggested order with the cheapest first. They're written for a dev build, so `traceLanes` and the other trace switches are on.

**For every test, check:**
- **Log:** `Priority road from segment …: N segments, M junctions (Y yield, S skipped, A applied)`, then `applied: A ok, 0 failed`. A skipped junction has a reason in the tooltip.
- **Phases:** a lab junction dump at each junction. Every lane connection should be green in a phase: priority road in, #1; side roads in, #2. A connection green in no phase strands cars.
- **Traffic:** a couple of minutes unpaused, looking at the priority road and the side roads.
- **Signs:** a yield sign on each yielding approach, priority signs along the road, nothing in the roadway or inside buildings.
- **Removal:** remove by click and check the junction goes back to the game (its own lights or none) with all signs gone.

**1. One-way roads**
- **a. One-way side road leading into the priority road:**
  1. Apply.
  2. **Expect:** it yields, with a yield sign.
- **b. One-way side road leading away from the priority road:**
  1. Apply.
  2. **Expect:** no traffic comes in from it, so it shouldn't yield. If it was the junction's only side road, the junction is skipped ("no side road leads in").
- **c. One-way priority road with two-way side roads:**
  1. Apply.
  2. **Expect:** the tool follows the road. Priority signs face only the direction of travel.
  3. **Known edge case:** the last stretch after the last junction doesn't count as part of the road. Check that clicking it removes nothing it shouldn't.
- **d. A one-way pair (dual carriageway built as two one-way roads) as the priority road:**
  1. Apply each carriageway.
  2. **Expect:** the junction where they meet a side road handles both. Note anything odd.

**2. The priority road turning at a junction**
1. Build an L-shaped main road with a side road continuing straight on at the corner.
2. Hover the main road.
3. **Expect:** the tool follows the straightest road (at most 45° off), so it goes straight into the side road, not round the corner. That's by design. Note it if that's not what a player would want, since it's a design question rather than a bug.
4. Try a gentle bend (under 45°) at a junction too. The tool should follow it.

**3. 5+ arms**
1. Build a junction with five or six arms, with the priority road straight through.
2. **Expect:** all three or four side roads yield and each gets a yield sign. Check the phases with the lab dump.
3. Repeat with "Overwrite lanes" on, and look for `NO GREEN` in the `traceLanes` lines.

**4. Tram tracks and bus lanes**
1. **a.** A road with tram tracks as the priority road, with a tram line running. **Expect:** trams get priority with the cars and never wait at side roads.
2. **b.** A road with tram tracks as a side road. **Expect:** trams yield with the cars and aren't stranded.
3. **c.** A road with bus lanes, as the priority road and as a side road. **Expect:** buses keep their lane and get green.
4. Repeat a–c with "Overwrite lanes" on. The lane rules weren't made with tram or bus lanes in mind, so read the `traceLanes` before/after lines for anything odd, e.g. a car lane connected into a tram or bus lane.

**5. Highway ramps**
1. Hover a highway, then hover an on-ramp or off-ramp where it meets a street.
2. **Expect** one of two outcomes. Either the tool doesn't treat highway merges as junctions it can apply (log and tooltip say why), or it applies and the phases still let traffic merge. Merges with a light on them would be bad for a highway. Note what happens.
3. Signs must not be placed on the highway shoulder in odd ways.

**6. A rail level crossing next to a junction**
1. Build a level crossing 10–30 m from a junction on the priority road.
2. **Expect:** the tool follows the road across it, since a level crossing is a plain node to the road. The junction still applies.
3. Check that the priority signs don't land on the tracks or inside the crossing. There's no obstacle check, and refused signs are built anyway with `ignoreErrors`.

**7. Junctions very close together**
1. Build two junctions 15–30 m apart on the priority road.
2. **Expect:** both yield. Only one priority sign for the pair, after the last of them (the minimum gap rule). Yield signs don't collide with each other.

**8. Asymmetric roads and noise barriers** (the "Also" line)
- **a. A road with different lane counts each way:**
  1. Apply.
  2. **Expect:** signs land just past the curb on both sides. The curb is assumed symmetric about the centre line (`notes.md`, "Sign placement"), so a sign might land in a lane or too far out.
- **b. A road with noise barriers:**
  1. Apply.
  2. **Expect:** signs on the road side of the barrier, not behind it or inside it.

Tell me the node ids and test numbers where something looks off, and I'll read the log for them.