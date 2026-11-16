*Latest update: Controller compatibility*

The game has no yield. And there's no way to mod it. There, I said it.

Now, we *can* approximate it really, really well for roundabouts. And a little bit less well for normal intersections. That's what this mod does.

For roundabouts it works so well that you'd never know the difference. Most importantly, it makes roundabouts flow like they are supposed to, without entering cars disrupting it.

Cosmetics: It also places yield signs at intersections, stacked yield + roundabout signs at roundabout entries, and priority signs at intervals along priority roads.

## How to use
The tool is found under Road → Tools. The icon is a large priority diamond sign with small yield and roundabout signs. Select the tool, then click a roundabout or near a junction on a stretch of road you want to give priority.

* Normal click targets any junction visible on screen along the same stretch of road, picking the direction by the road nearest the cursor.
* Hold Shift (RB/R1) for a single junction.
* Hold Ctrl (LB/L1) for the entire road with no limit.

## Options

A settings window allows you to configure certain aspects of what the mod does.

### General
* Sign style: International (default) or Norwegian
* Overwrite lanes (default: on)
* Dedicated turn lanes (default: off)
* Uninstall: For safe removal of the mod.

### Roundabouts
* Two styles of exit configurations for the lanes.
* Style A (default): The outer lane is the only exit lane.
* Style B: Additional exit lanes based on relative lane count between roundabout and exit road.

### Priority signs
* Spacing: How far from a junction the sign is placed.
* Variation: Adds a bit of randomness to the sign placement.
* Minimum segment length: Only place a sign if the distance from junction to junction is at least this.

If a segment is between **minimum length** and **2x spacing**, the sign is placed halfway along the segment instead.

Signs on both sides of a road are always placed right across from each other, with the same variation.

## How it works
The faux-yielding is achieved using a neat trick with traffic lights – which are technically present, but invisible. This works surprisingly well thanks to how the traffic lights function in the game. The combination of (max) phase duration and phase skipping lets us emulate yielding extremely well for roundabouts, allowing them to work as they should, and a bit less well for normal intersections (because there are more lanes involved). I can't make the behavior perfectly realistic, but it gets reasonably close, and the important thing is the cars on side roads yield. They will still sometimes misjudge how much time they have.

**Roundabouts specifically:** The outer lane is *always* exit-only. This is a conscious choice that, while not strictly realistic, makes a huge difference in the flow. Feel free to experiment with alternative lane config schemes, including allowing the rightmost lane to also go forward. You will see that cars exiting from this lane now still make entering cars wait, because they're in a lane that has a green light going forward, which conflicts with the entering lane connections, and therefore blocks the skipping of the traffic light phase. The game does not distinguish traffic based on where they're actually going, only which lane they're in. As such it clashes with the trick we're using to emulate yielding.

## Uninstall
The mod is **not** safe to remove without first removing everything the mod has added to your save (that is, signs and junction configurations). An uninstall function is provided for safe removal. A warning is given on disabling the mod to remind you.

Even if you disabled the mod and then saved the game, you can still re-enable it to bring back the uninstall function. This will restore everything back to a stable configuration.

Once you have run the uninstall tool (Remove All), the warning can be ignored and the mod safely removed.

**Placeholder models**
An extra function is included to remove any placeholder models in the world. This will also remove placeholders left from any other mod.

**Technical details**: If you disable the mod without first running the uninstall, and with things from the mod still in the save, sign assets will be replaced with placeholders (harmless, but a nuisance), and a stale traffic light index is left behind in junction configs (this is bad). If you try to modify roads near junctions previously configured with priority, the game will crash. To prevent this, the traffic light type index at that junction must first be reset back to a valid value that exists after the mod's invisible traffic light is removed (or to -1, signifying the default for the map's climate).

Because of technical limitations (always fun), re-enabling the mod on a save with placeholders, will not result in those placeholders being reverted back to signs. The game deletes those references when the mod is removed, so there's no way to know for sure which placeholders were signs from the mod.

### Changelog

[See what's changed](https://github.com/Imsvale/road-priority-yield/blob/main/CHANGELOG.md).

### Contact
* GitHub: ttps://github.com/Imsvale/road-priority-yield
* Reddit: [u/Imsvale](https://www.reddit.com/user/Imsvale)
* Discord: `imsvale`