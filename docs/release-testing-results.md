# Release testing: results

Results of the tests in `release-checklist.md` item 6 (junction shapes), in more detail than the
checklist keeps. Line numbers refer to the game log of that session. Dev builds, so the trace
switches and the dev-only watch for new junctions (`watchAhead`) were on.

Standard method (user, 2026-11-15): build the main road and the side roads first (in any order),
then apply the tool. One junction on the main road is enough. Building onto a road already applied
is a different test (a section of its own, still to do).

## 1. One-way roads (2026-11-15, priority road 79-81)

- **a. One-way side roads into a priority road** (first 7816, 8311 built onto an applied road;
  then again on fresh builds from log line 1244): pass on fresh builds, a yield sign on each.
  On the applied road, 8311, joined right next to 7816, wasn't found by the dev-only watch: the road
  edit replaced 7816's priority segment and the watch took that for a first look. Fixed in 80.
- **b. A one-way road leading away** (8477; fresh, line 1302): no yield sign, correct. The game
  puts its own light there (preference Auto, a junction it manages); not this mod's business (user).
  Since 80 the dev-only watch doesn't take on a junction with no side road leading in.
- **c. A one-way priority road** (11059; fresh, line 1316): priority signs stood against the traffic
  too. Since 80 a sign only for traffic driving that way (from the lanes' `forward` flags), on both
  sides of a one-way stretch, both facing the traffic. Retested: pass.
- **d. A dual carriageway as two one-way roads, with a side road** (line 1088; fresh, line 1400):
  priority signs as in c, fixed by 80. The side road joins the first carriageway at 17323 and crosses
  the median on a short link (17768) to 17354: that link got a yield sign at each end. Since 81 no
  yield sign on an approach under 15 m (junction edge to junction edge) from the next junction
  (`SHORT_LINK`); the phases are unchanged. Retested: pass.
- Dual carriageways need no special case: each carriageway is a one-way priority road with its own
  signs. Yield signs on side roads apply everywhere; priority signs where the diamond is used (most
  of Europe, Norway), each carriageway its own; the UK and US have no priority road sign (general
  knowledge, not checked against the regulations).

## 2. The priority road turning at a junction (2026-11-15, priority road 81, from line 2001)

### a. An L-shaped road, then a road joined straight on at the corner

- Built the L and applied it: the tool follows a road only through turns of at most 45°
  (`MAX_TURN`), so the L became two priority roads, 25433 (junction 25701) and 25418 (junction
  25991), each ending at the corner node 25396 with a start sign there.
- Then joined a road at the corner, straight on from leg 25418: 25396 became a junction that isn't
  ours, so nothing happened there (in a release, new junctions mid-road are the player's).
  Hovering 25418 afterwards: "4 segments, 2 junctions (2 yield, 0 skipped, 1 applied)": the road
  now runs straight on into the new road, 25396 not applied. Clicking would make the other leg
  (25433) yield at 25396.
- **The conflict (user):** a priority road ending at another priority road yields to it, so the
  straight road wins and the L's turning leg loses its priority there; the L is no longer one
  priority route.
- **Suggestions (not built):**
  - **Real roads do this.** In the countries using the diamond, a priority road can turn at a
    junction: the diamond gets a supplementary plate showing the priority route's shape (Germany's
    "abknickende Vorfahrt"; general knowledge, check for Norway), and every other arm yields,
    including the one straight on.
  - **The phases already allow it:** `junctionStates` takes any two arms as the priority road.
    Only the tool's following (the straightest arm, at most 45° off) and membership stand in the way.
  - **(A) Leave it** for the release: a turning priority road is two roads; where they meet, the
    player decides by clicking. Document it.
  - **(B) Join two ends:** where two of our priority roads both end at the same junction, treat
    them as one route turning there: those two arms get phase #1, the rest yield. Decided at apply
    (event-driven), no polling. Open questions: what a click on one of them removes; which pair wins
    when three roads end at one junction.
  - **(C) Choose the turn:** a modifier or a second click picks the arm the road turns into.
    More explicit, more interaction to design.
  - Either B or C wants the supplementary plate under the diamond (a new sign model), and the
    yield signs as they are.
  - My recommendation: A for the release, B after it.
  - **Decided (user, 2026-11-15):** turning priority roads after the release; a limitation of the
    first version. The user's ideas for it: Shift-click to mark single segments (as other tools
    in the game do), as a stop-gap; later, Shift-drawing a line through two or more segments to set
    the priority road's route through a junction, every other road into that junction yielding
    (whatever its status upstream).

### b. A bend of about 41°, then a near-straight side road joined at the bend

- Built: a straight road with a junction upstream (16357), going on round a bend of about 41°.
  Applied from 8239: "3 segments, 1 junctions": the road was 8239 (from its end at 8205), through
  16357, then 7827 and 7882 to the bend's node 8093, and stopped there: the walk didn't follow the
  41° continuation. Measured from the segments' tangents at the node, the turn apparently came out
  over 45° (`MAX_TURN`); the log doesn't say. So 8093 was the road's end, with a start sign
  ("8093:7882") near the node, for traffic driving onto the priority road from the continuation.
- Then a near-straight side road joined at 8093: it became a junction, and the start sign stood
  inside it (screenshot `2026-11-15 04_58_06.png`). Nothing revisits a road's signs when a junction
  appears on it.
- No yield sign at the new junction: as in a, a new junction mid-road. The dev-only watch didn't
  take it on either: at 8093 the arm straight on is now the side road, so the walk no longer leads
  to the junction it remembered.
- **Suggestions (not built):**
  - **Signs where the player builds: built in 82** (user, 2026-11-15: "remove those signs that are
    too close to the junction on either side, then reapply signs as per existing rules"). After the
    player's build, a new junction on a road with our priority signs gets those roads' signs redone:
    the ones near it move, the rest are kept; only on the applied road's own links. Event-driven;
    doesn't cover towns. **Retest** with the 2b setup: the sign at the bend should move out of the
    junction.
  - **The bend:** log the turn angle where the walk stops (a dev trace), to see whether 41° on the
    ground measures over 45° at the node, and whether `MAX_TURN` should be larger or measured
    further from the node.
  - **A start sign at a plain node** (a road "ending" where it only bends too sharply): no junction
    there, so a sign for traffic entering the priority road reads oddly. Could skip start signs at
    plain nodes.

## 3. 5+ arms (2026-11-15, priority road 81)

- **3.1-3.2:** pass. Signs right; lab dump (line 2185): phase #1 with every side road locked, so
  every side road yields, which is all the plan asks.
- **3.3, "Overwrite lanes" on:** pass, no `NO GREEN` in the `traceLanes` lines (up to line 2307).
