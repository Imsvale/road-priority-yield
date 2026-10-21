# Before release (2026-10-20)

What to test or fix before the mod goes public, most important first. Tick items off with the version and date, and put the findings in `notes.md` or `CLAUDE.md`.

1. **Done (priority road 47, 2026-10-20): bulldozing at a yielding junction.** Confirmed in game: no signs left behind, on junctions new to the tool and on newly built ones. Follow road edits assumes every removed segment gets a replacement. When there is none (a side road, a priority segment or a whole junction bulldozed):
   - the junction stays marked `repair` for good, and lane following skips it;
   - each session logs "not repaired (its node or segments are gone)" once;
   - its yield signs stay standing, and so do the priority signs beside the removed road.

   Wanted: drop the junction and remove its signs; or, if a usable junction remains (a 4-way bulldozed to a T), apply it again. Test: bulldoze a side road, a priority segment, and a whole junction.

   **Tested in game (priority road 44, 2026-10-20):** all seven cases behaved as below, except that a priority sign stayed when a priority arm was bulldozed. Retested on 45: still there. It was the start sign at the far end of a road left with no yielding junction. And a junction marked `gone` while its repair was under way was never handed over (the watcher remembered junctions by node, not by mark). Both fixed in 46. Decided: the "Follow road edits" switch is gone, and edits at our junctions are always repaired (user, 2026-10-20; priority road 47, code archived in `archive/follow-switch.md`). Retested on 46: test 3 unchanged (the road had no junction left, so `planFrom` found nothing); test 4 left more signs (a repair still under way put them back after the drop). Fixed in 47: the road is walked instead, and the watcher waits between hand-overs.

   **Built (priority road 43):**
   - The game script now records road edits at registered junctions whether "Follow road edits" is on or off.
   - A junction whose node is gone, or whose priority segment was removed without a replacement, is dropped: our light off, its yield signs removed, unregistered.
   - A side road change repairs the junction (following on) or checks it (following off). Either way it's dropped if no side road is left.
   - Not done: re-applying what's left after a priority arm is bulldozed. A 4-way bulldozed to a T keeps no yielding; the player clicks the road again.
2. **Removing the mod from a save. Hard requirement: `severityRemove` must state the real consequences of removing the mod** (user, 2026-10-20). A save that used the mod has traffic lights of its invisible type and sign assets built from its models. Load such a save with the mod disabled and record what happens: lights fall back or vanish, signs go missing or turn into placeholders, the game warns or crashes. Then set `severityRemove` to match.

   **Tested (priority road 47, 2026-10-20):**
   - The save loads. A Loading Report lists the three sign models as missing, and their instances become placeholder boxes. Harmless, but they stay boxes after the mod is enabled again, and applying again doesn't remove them (the tool no longer knows them): bulldoze them by hand.
   - The game removes the yield game script's entity, state and all: the sign records, the junction registry, the priority sign settings. Re-enabled, it starts empty, so earlier junctions aren't repaired after edits until they're applied again.
   - Lights, phases and lanes are native and stayed (seen after re-enabling).
   - With the mod off, the lights stay invisible and their phases keep working: their models are the base game's type A, already built (shrunk) in the save. The traffic light window opens and lists only the game's types.
   - **Crash:** with the mod off, the road tool at a yielding junction (choosing a road type and hovering there) crashed the game: `ResTypeRep<TrafficLightType>::Get` assertion, "Actual: 4 >= 4". A node stores its light type as an index into the type list; without the mod, our type's index is past the end, and rebuilding the light looks it up.
   - **`severityRemove` is `Critical`** (2026-10-20).
   - **Built: Uninstall** (priority road 48, to test): a checkbox under General opens a window with counts (junctions on our light type, signs) and "Remove all". Removed lights, by Uninstall, by click or by a drop, now get the game's type A, so no node keeps our index. Test: Remove all, then disable the mod and load the save, then use the road tool at a former yielding junction: no crash, no Loading Report.
   - **Placeholders** (priority road 56, 2026-10-21, user's idea: a universal cleanup): the Uninstall window's Find searches the world for asset groups made only of placeholder models (any mod's), reports the count, and Remove N removes them. Tested: 92 found and removed, 0 left; none mixed with real models.
   - Was: to offer a way to uninstall cleanly, removing the yielding (lights back to a game type, signs removed) from every junction before the mod is disabled; the description must tell players to use it. Also worth knowing: with another set of mods, the index could point at a different light type instead of past the end.
3. **Towns rebuilding their own roads.** Towns upgrade and extend streets as they grow.
   - Do the build events (`onPreBuildProposal` / `onPostBuildProposal`) fire for town upgrades, or only for the player's builds? If they don't, yielding quietly breaks in growing towns.
   - A town street built onto a priority road makes a junction nothing makes yield, like a player-built side road.
4. **A fresh start:** a new game with the mod, and adding the mod to an existing save that never had it. The game script subscribes to events once per save, and the junction registry and settings start from empty state. Most testing so far was on one long-lived save.
5. **Removing yielding with a click.** With "Overwrite lanes" ticked, the rewritten lanes stay. A junction that had the player's own traffic light before applying gets the game's defaults back, not the player's light (restoring it is open work 2 in `CLAUDE.md`). At least know what happens, and mention it in the description if it stays.
6. **Junction shapes not tried yet:**
   - one-way roads, as the priority road and as a side road;
   - the priority road turning at a junction;
   - 5+ arms;
   - tram tracks or bus lanes;
   - highway ramps;
   - a rail crossing next to a junction;
   - junctions very close together.

   Also asymmetric roads and noise barriers (sign placement, `notes.md`).
7. **Left-hand traffic.** Sign sides, roundabout arrows and the roundabout lane rules assume right-hand traffic. Decide: make it work, or have the tool refuse with "Right-hand traffic only".
8. **Scale.** A long priority road (50+ junctions) and a save with a few hundred yielding junctions. Watch:
   - how slow applying and removing are;
   - stutter, because the lane check (every 3 s) and the road edits watcher (every 30 frames) both read the whole stored state.
9. **Heavy traffic on the priority road.** With phase #2 at 1 s, do side roads still get out under sustained priority traffic?
10. **Other traffic mods on the same save or junction:**
    - **Smart Lanes:** look at what it does. Does it conflict with ours, or can they coexist, the player using whichever mod they like to configure the lanes? Following lane edits would then rebuild our phases after Smart Lanes changes the lanes.
    - **Roadcraft: Priority roundabouts:** both mods set traffic lights at the junction. Compare only, never copy (`CLAUDE.md`).

    The outcome decides what the description says about them.

**The description:** now `_metadata/description.html` (2026-10-20; `modinfo.json`'s `description` is ignored when it exists, so it was removed). It has the old text, migrated as is, and the "Savegame compatibility" section in the user's words: keep that section as written. Still missing: lane overwriting, priority signs, and that edited and bulldozed junctions are kept right. Write it in the user's voice (`../CLAUDE.md`).

**Item 2 confirmed (priority road 49):** after Uninstall, with the mod disabled, upgrading at the junction that crashed before works: no crash; the junction had no light, and the new road got the game's standard lights with default phases.
