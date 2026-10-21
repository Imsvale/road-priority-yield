The game has no yield. And there's no way to mod it. There, I said it.

Now, we *can* approximate it really, really well for roundabouts. And a little bit less well for normal intersections. That's what this mod does: One-click setups for roundabouts and priority roads.

For roundabouts it works so well that you'd never know the difference. Most importantly, it makes roundabouts flow like they are supposed to, without entering cars disrupting it.

It also places yield signs at intersections, stacked yield + roundabout signs at roundabout entries, and priority signs at intervals along priority roads. Because it looks nicer that way.

## How to use
The tool is found under Road → Tools. The icon is a large priority diamond sign with small yield and roundabout signs. Select the Road Priority and Yield tool, then click a roundabout or a stretch of road you want to have priority. That's it. Click again to remove it.

By default, the mod does nothing to your lane config. It works with whatever you give it. This is to avoid inadvertently messing up your own carefully constructed lane configs, or those of another mod. If you want, I have provided my suggestion for a better lane config than vanilla (which... is insane). To use this instead, tick **Overwrite lanes** in the settings window before you apply the tool. I have lane rules for both roundabouts and normal intersections that should give you a much more sensible distribution of lane connections.

## Options

A settings window allows you to configure certain aspects of what the mod does.

### General
* Sign style: International or Norwegian (default: International)
* Overwrite lanes (**default: off**) **← Note!**
* Dedicated turn lanes (default: off)
* Uninstall: For safe removal of the mod.

### Roundabouts
* Two styles of exit configurations for the lanes (default: Style A)
* Style A: Rightmost lane is the only exit lane. 
* Style B: Additional exit lanes based on relative lane count between roundabout and exit road.

### Priority signs
* Spacing: How far from a junction the sign is placed
* Variation: Adds a bit of randomness to the sign placement
* Minimum segment length: Only place a sign if the distance from junction to junction is at least this.

If a segment is between **minimum length** and **2x spacing**, the sign is placed halfway along the segment instead.

Signs on both sides of a road are always placed right across from each other, with the same variation.

## How it works
The faux-yielding is achieved using a neat trick with traffic lights – which are technically present, but invisible, so you'd never know. Unless you know. Which you now do. This works surprisingly well thanks to how the traffic lights function in the game. The combination of (max) phase duration and phase skipping lets us emulate yielding extremely well for roundabouts, allowing them to work as they should (yes, really!), and a bit less well for normal intersections (because there are more lanes involved). But still pretty good. I can't make the behavior perfectly realistic, but it gets reasonably close, and the important thing is the cars on side roads yield. Don't look too close at exactly what happens in certain situations, and it creates a pretty good illusion that, hey, they're just yielding like they should. That's about the best we can do with the tools the devs gave us.

**Roundabouts specifically:** The rightmost lane is *always* exit-only. This is a conscious choice that, while strictly not realistic, makes a huge difference in the flow. Feel free to experiment with alternative lane config schemes, including allowing the rightmost lane to also go forward. You will see that cars exiting from this lane now still makes entering cars wait, because they're in a lane that has a green light going forward, which conflicts with the entering lane connections, and therefore blocks the skipping of the traffic light phase. The game does not distinguish traffic based on where they're actually going, only which lane they're in. As such it clashes with the trick we're using to emulate yielding.

## Uninstall
The mod is **not** safe to remove without first removing everything the mod has added to your save (that is, signs and junction configurations). An uninstall function is provided for safe removal. A warning is given on disabling the mod to remind you.

Even if you disabled the mod and then saved the game, you can still re-enable it to bring back the uninstall function. This will still restore everything back to a stable configuration. An extra function to remove any placeholder models in the world is also included. This will also remove placeholders left from any other mod.

Once you have run the uninstall tool, the warning can be safely ignored and the mod safely removed.

**Technical details**: If you disable the mod without first running the uninstall, and with things from the mod still in the save, sign assets will be replaced with placeholders (harmless, but a nuisance), and a stale traffic light index is left behind in junction configs (this is bad). If you try to modify roads near junctions previously configured with priority, the game will crash. To prevent this, the traffic light type index at that junction must first be reset back to a valid value that exists after the mod's invisible traffic light is removed.

Because of technical limitations (always fun), re-enabling the mod on a save with placeholders, will not result in those placeholders being reverted back to signs. The game deletes those references when the mod is removed, so there's no way to know for sure which placeholders were signs from the mod.