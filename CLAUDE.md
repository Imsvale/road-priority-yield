# Road Priority & Yield (folder `road-priority-yield`, modId `imsvale_road_priority_yield`)

Makes side traffic yield at junctions and roundabouts. TF3 cars never give way; this mod fakes it with two-phase traffic lights whose models are invisible. Handed off from the lab (`../Smart traffic lights`), which holds the experiments and measurements behind it. Read `docs/notes.md` first: background, results, design, the comparison with Roadcraft, and ideas.

## The mechanism

At each junction on a priority road:
- **Phase #1:** connections coming from the priority road green. 60 s maximum, 0 s minimum, skipping allowed: it ends as soon as the priority road is empty and someone waits.
- **Phase #2:** side roads green. On roundabouts also the exits (ring onto a side road: no conflict with entering traffic); at ordinary junctions not, since at a 4-way the priority road's turns cross the side roads (lab, 2026-10-19). Roundabouts and junctions have separate plans (`PLANS` in the tool), so a change for one can't break the other (user). 1 s maximum (user's choice, 2026-10-17), same otherwise. Keep this cap short: skipping only ends a phase early when its own lanes empty, so a long side queue would otherwise hold the priority road for the full duration.
- **Pedestrian phase** only where there are crosswalks. No all-red phases.
- **Lanes (opt-in):** with the tool setting "Overwrite lanes" on, each plan's lane rule applies (`PLANS.*.lanes`). Lanes and phases are set in one node config proposal. Removing the yielding leaves the lanes.
  - **Ordinary junctions** (`rewriteLanes`): each turn lands in its own lane instead of fanning out into every lane of the road it turns into. With "Dedicated turn lanes" also on, turning lanes become turn-only where another lane still goes straight on.
  - **Roundabouts** (`roundaboutLanes`, user's rules 2026-10-19), ring lanes counted from the curb:
    - the curb lane exits only;
    - as many ring lanes as the side road has outbound lanes exit; exiting lanes don't go on, except the leftmost exiting one, so no lane goes on to the right of an exiting lane;
    - lanes going on step one lane right, and the median lane also keeps its own lane;
    - entry lanes take blocks of ring lanes curb first, with the leftmost entry lanes getting the extra ones.
    - A one-lane ring exits and goes on; a junction without an exit keeps lane to lane. Ring junctions with two side roads at one node are left alone.
    - "Dedicated turn lanes" doesn't apply.

Measured in the lab (paired runs on a roundabout): stopping on the ring −96%, all stopping −33%, throughput +2%, and the ring never broke down.

## Files

- `mod/content/gui/construction/tools/imsvale_priority_road_tool.script.lua`, the Priority Road tool (Roads > tools):
  - **Following the road:** hover a road; the tool follows it through junctions in both directions, always on to the straightest connected road (at most `MAX_TURN` 45° off).
  - **Kind:** a loop within `ROUND_TOLERANCE` (12%) of its mean radius is a roundabout; otherwise it's a priority road. Same rules either way; the kind is for entry signs.
  - **Preview:** blue for the priority road, gold for the approaches that yield.
  - **Click** applies; if every junction already has it, click removes it (preference None, default phases; previous custom lights are not restored).
- **Icons** (working since priority road 6, 2026-10-17; positions were first checked with `EdgeRenderable` outlines, removed in 7): a priority diamond on each priority approach and a yield triangle on each yielding approach, at the junction edge. Since priority road 9 (UX agreed with the user):
  - **Configured junctions:** while the tool is open, every junction using our light type near the camera shows its icons. Roles are read from its phases: green in phase #1 = priority, otherwise yield. The list comes from a scan of the street node map, every 3 s and right after an apply / remove.
  - **Hovering an unconfigured road:** the new icons.
  - **Hovering a configured road (removal):** its icons marked for removal. Since priority road 10 (`REMOVAL_STYLE = "highlight"`) this is the bulldozer look: a box of translucent gold with a stronger gold outline over the icon. The engine draws the real bulldozer highlight; only its colour is in the game scripts (`construction_colors.gres` `Bulldozer`, gold #FFD700). `REMOVAL_STYLE = "x"` draws `remove-x.tga` on top instead.
  - **Tooltip:** only the kind ("Roundabout", "Priority road"), a short reason when it can't apply, and failures. No instructions: the highlights and icons carry it (user, 2026-10-17).
  - **Hovering a road whose junction is configured with other roles** (a crossing road done earlier): the old icon crossed out to the left of the new one.
  - **Distance:** size falls with distance from the camera (32 px at 150 m, clamped 14–48). Icons hide beyond a range from the camera's centre of max(250 m, 6 × camera height) and fade over its last 30%, so close in the horizon stays clear.
  - **Constants** at the top of the script.
  - **Position:** the mean of the approach's lane curve ends at the node, 6 m back along the road, 1.5 m up.
  - **Drawing:** screen-space images. `builtin.FullScreenComponent{ recipe = IconOverlay, … }` among the ActionDescriptor's children (as the town window shows its legend) holds a mouse-transparent `FloatingLayout`.
    - Each `FloatingLayoutChild` has `h` / `v` set to the pixel position from `api.gui.camera.world2Screen`; the image's `meta.styleSheet = styleutil.makeStyle{ anchorPoint = {0.5, 0.5}, size = {32, 32} }`. The game's `::/gui/main/callout_container.tl` positions callouts the same way.
    - `react.onStep` re-projects the icons every step, so they follow the camera.
  - **Images:** `mod/content/gui/priority-diamond.tga` (the user's) and `yield.tga` (a generated placeholder: 64×64, 32-bit with alpha).
  - In-world sign models are a separate, later matter.
  - **Settled with the user (2026-10-17):** the screen overlay is the way to show the hover icons. The other options:
    - `EdgeRenderable` geometry has no images, so it's only for tests and proofs of concept.
    - The HUD icon system gives one icon at an entity's centre, not one per approach.
    - Sign models are an addition for later: physical signs alongside the larger icons shown while the tool is active.
    - The CSS rule (gravity {-1, -1}) is the game's own way to make the layer fill the screen.
- `mod/content/infrastructure/traffic_light/imsvale_yield_invisible.{trl,script}.lua`, the "Yield (invisible)" light type: type A's standard layout with every model shrunk to 1/1000. A type that places no models makes the engine drop the light.

## Models (Blender pipeline, since 2026-10-18)

- **Source:** `assets/signs.blend`, built by `tools/blender_build_signs.py` (run inside Blender; re-running rebuilds): collections "TF3 Yield Sign", "TF3 Yield Roundabout Sign" (yield triangle on top, round roundabout sign below), "TF3 Priority Sign" (diamond). Blender is reachable through the Blender MCP (`execute_blender_code` etc.); the user keeps it open. Objects must sit at the origin when exporting: the exporter bakes world transforms.
- **Export:** `tools/blender_export_tf3.py`, run inside Blender (`exec(src, {"CONFIG": {"collection": ..., "name": ...}})`). It writes the `.msh` + `.msh.blob`, `.mdl` and `.mtl` into `mod/content/models/<kind>/<name>/`. Models: `imsvale_yield_sign`, `imsvale_yield_roundabout_sign`, `imsvale_priority_sign`, and the Norwegian `imsvale_yield_sign_no`, `imsvale_yield_roundabout_sign_no` (collections "... NO"). The tool's drop-down "Sign style" (International / Norwegian, key `imsvaleSignStyle`, `ScriptParamType.ComboBox`, location Default) picks the variant; changing it while the tool is open restyles every stored junction's signs. `getCurrentParams()` only returns the construction menu's own parameters: as a Toolbar parameter it read back nil (2026-10-18). Values are 1-based indices. The game script stores `{ ids, style, round }` per junction.
- **Corner radius:** the plate follows the artwork, so pointiness is the artwork's. Measured (tip-to-edge distance = radius for a 60 degree corner): international about 63 mm, Norwegian about 31 mm on a 900 mm sign. Specify changes as "corner radius X mm on a 900 mm sign".
- **Plate shapes:** traced from the user's artwork by `tools/trace_sign_outlines.py` into `assets/sign_outlines.json` (convex hull of the opaque pixels, simplified; artwork padded to a square). Each vertex's UV is its own image coordinate at one uniform scale, set by the sharp shape the artwork was rounded from (straight sides extended to meet): yield 0.9 m sides including the white rim, diamond 0.6 m sides, disc 0.6 m. Fitting a rounded shape's bounding box onto a sharp plate misaligned it (2026-10-18).
  - **Format** (read off existing mesh files, checked byte for byte, confirmed by our exports in game): float32 positions / normals / uv0 / tangents (w = bitangent sign), then uint32 indices per submesh; `.msh` offsets and counts in bytes; one vertex per triangle corner; Z up; Blender UVs unchanged.
  - **Materials:** each Blender material names its TF3 material with the custom property `tf3_mtl`. Materials are `PHYSICAL_NRML_MAP`, with neutral base-game metal/gloss/AO and normal maps.
- **Textures:** `tools/make_sign_textures.py` writes uncompressed 32-bit DDS with mipmaps (the game reads those) into the shared `textures/models/imsvale_signs/`: yield, roundabout and priority faces plus plain metal. The faces come from the user's artwork (3840 px TGAs in `D:\My Documents\Games\Transport Fever 3\Graphics\yield`), cropped to the opaque area, scaled to 256 px (enough for the closest gameplay zoom, about 55 px on screen at 1080p), transparent surroundings filled with the edge colour. Run it with the project's `.venv` (Pillow, NumPy); without the artwork it writes generated placeholders. Each face texture draws its shape filling the image; the plates' UVs map their bounding box onto it.
- **Constructions:** `construction/imsvale_yield_sign.con`, `imsvale_yield_roundabout_sign.con`, `imsvale_priority_sign.con`, sharing `imsvale_sign.script.lua` (the model comes from `updateScript.params.model`).
- **In game (priority road 12):** the tool places a yield sign on each yielding approach after applying, and removes them with the yielding.
  - **What a sign is:** the construction `construction/imsvale_yield_sign.con`, whose `updateFn` must put the model inside `subconstructions`; a top-level `models` gave the game's stand-in box. Once built it is a plain asset (`ASSET_GROUP` + `MODEL_INSTANCE_LIST`), not a construction, and bulldozable like any decoration.
  - **Keeping track:** asset groups can't be looped over, so the asset ids are stored per junction node in the game script `game_mechanics/imsvale_yield_signs` (state, saved with the game). The tool writes through `makeScriptingSendEventCmd` and reads back via `gameScriptSystem.getEntityForGameScript(...)` → `GAME_SCRIPT` component → `.state` (documented API: script-doc `cmd.md`, `engine/system.md`). The game script subscribes in `update` whenever `state:hasEventSubscriptions()` is false, as the base game's arrival tracker does; subscriptions aren't part of the saved state.
  - **Placement** (priority road 14; details and open questions in `docs/notes.md`, "Sign placement"): 0.5 m back from the junction edge, on the right of the incoming traffic, just past the curb (the outer edge of the outermost non-pedestrian lane): 0.5 m onto a raised sidewalk, otherwise 1.0 m. Facing the oncoming traffic. Roundabouts get the yield + roundabout sign. The tool logs its curb reading per sign.
  - **Building:** the proposal is sent normally first, and again with `ignoreErrors` if refused.
  - **Removal:** a full `api.type.Proposal.new()` with the asset ids in `toRemove`. (`createProposalRemove` is for constructions; on a sign asset it failed an engine assertion, `GetComponentDataIndex`, 2026-10-18.)
  - **Dead ends** (see `../CLAUDE.md`): street edge objects (stops only), and models added by a light type's model script (it can't tell which approaches yield; the test was removed).
- **Test tool:** `tools/test_sign_construction.lua` places / lists one sign by hand.
- **Open:** see `docs/notes.md`, "Sign placement". The priority diamond is modelled but not placed yet (not at junctions; maybe at intervals along a priority road, never on roundabouts).

## Engine facts that matter here

- **Lights:**
  - Phases are `BASE_NODE_CONFIG.trafficLightConfig.states`. `lockedLanes` numbers the lane connections from 0, then the crosswalks after them.
  - Apply with `api.engine.util.proposal.createTrafficLightProposal(node, config, preference)` and `api.cmd.makeWorldBuildProposalCmd`.
  - `getComponent` returns copies: build the new list, then assign it.
- **Precedence:** `BaseEdgeStreet.precedenceNode0/1` (YES = 0, NO = 1, AUTO = 2) resolve to `Edge.precedence` per lane connection, by road template `priority`. Cars ignore it.
  - Don't use it to pick the priority road at a roundabout: the native roundabout's one-way ring (410/430) ranks below a town road spoke (610).
- **Road direction:** read it from the junction's lane connections (which segment leads to which).
- **Light type model scripts:** an edit needs a savegame reload (the shortcut keys don't reload it), and built lights keep their old models until rebuilt.
- **Light changes reroute traffic:** a phase or lane change at a node drops and re-plans the routes through it for about a minute.

## Open work (see docs/notes.md, "Ideas" and the Roadcraft section)

1. **Signs:** a yield sign at every yielding entry, plus the blue roundabout sign at roundabout entries; no lane signs on the ring.
   - A light needs some model to exist. Roadcraft keeps one invisible model per light group plus its signs.
   - A model script only knows its position, not which approach it serves. Roadcraft pre-generates one light type per entry-direction pattern (about 2,700 files) and hides them with `trafficLightTypeRep.setVisible(id, false)` in `postRunFn`. Look for a simpler way first.
2. **Removal:** restore the junction's previous light settings, saved on apply (Roadcraft journals them in game-script state).
3. **Multi-lane rings:** lanes done (`roundaboutLanes`, 2026-10-19: curb lane exits, the ring steps toward the exits, entries feed every ring lane, the leftmost entry lanes getting the extra ones). Not adopted: keeping the median-side lanes green during the entry phase (Roadcraft's approach). It needs entries to join only the curb lane, which is exit-only at the next exit. Entering cars that aren't leaving there must then change lanes somewhere, and they get in the way of ring traffic wherever they do: on entry, or at the next node (which may be the next exit, where plain nodes in between were removed to stop lane changes). So they may as well do it on entry. And changing lanes leftward on a roundabout is out (user, 2026-10-19). Hence entries feed every ring lane.
   - Wording: say curb lane / median lane, not outer / inner, which reads both ways. On a ring the curb lane is the outside by radius in both left- and right-hand traffic. Lane numbers in lane connections run left to right as seen from the node looking out along the segment: with right-hand traffic, inbound lane 1 = curb lane, outbound highest = curb lane (see `../CLAUDE.md`).
   - Roadcraft ("outer" = curb lane) only lets entries join the curb lane, which strands a two-lane entry whose second lane goes only to the median lane (its log, test roundabout node 940, three-lane ring: `12301:2 -> 652:1`). Don't repeat that.
4. **Tool icon:** `mod/content/gui/priority-triple.tga` (64×64, RLE 24-bit, no alpha), used for both `icon` and `previewIcon` for now. The menu preview would like a 512×288 image; 32-bit with alpha lets the icon have a transparent background. The base game's own GUI images include RLE and uncompressed TGA, 24- and 32-bit.

5. **Lane configuration as part of the setup** (user, 2026-10-17; testing on different lane combinations comes later):
   - **The goal:** applying priority / yield also sets the junctions' lane connections, starting with roundabouts.
   - **The rules:** either general ones that work for any combination of ring and approach lanes, or one hard-coded layout per combination.
   - **Phases must match the lanes:** every lane connection must be green in some phase. Otherwise cars use a lane because its connections allow a turn, find no green for it, and are stranded; that lane connection is effectively orphaned.
   - **Done for ordinary junctions (priority road 20, 2026-10-19):** the settings "Overwrite lanes" (Yes / No buttons, default No: a player never loses their own lane work by not looking at the settings) and "Dedicated turn lanes" (only with the first on). `rewriteLanes` and `sendNodeConfig` in the tool, ported from the lab's `tools/set_lanes.lua` (rules "nofan" and "dedicated"; `../Smart traffic lights/docs/design/2026-10-19_lane-rules.md`). Measured on T and 4-way junctions up to all 6-lane roads: never worse than the game's lanes, up to 19% fewer forced entries. Roundabouts done too (priority road 22, `roundaboutLanes`). Still to do: left-hand traffic.
   - **Hand edits after applying:** connections that survive keep their phases, new or recreated ones are red in every phase (lab, 2026-10-19). The player's business: no warnings (user).
   - **So:** set lanes and phases together, in one proposal (`nodeConfigsToAdd` with both, as the lab's `tools/set_layout.lua` does), and check that every connection is unlocked in at least one phase.

## Roadcraft: compare, never copy

Roadcraft: Priority roundabouts (another author's mod, notes in `docs/notes.md`) is prior art to compare against, not a source. Don't copy its code or adopt its approaches as they are (user, 2026-10-18). Anything it suggests must be checked against the base game's own code (`../../modding-api/game-src`) and the API docs (`script-doc`) and built our own way. It has been wrong before: storing an event-subscription flag in saved state, where the base game checks `hasEventSubscriptions()` instead.

## Working with the user

- The user tests in game and reads the game log (path in `../CLAUDE.md`). Log lines are tagged `[yield]`, and the tool logs `loaded: <VERSION>`: bump `VERSION` with every change.
- **After editing a loaded script,** end the reply with a line naming the reload: GUI script Right Alt + Shift + R; new files a full restart; light type model scripts a savegame reload.
- Refer to phases as #1..#n (1-based, as in the UI).
- **Measuring something:** the lab has the recorder and paired-run tooling. Do experiments there.
- Git: this folder is its own repository. Commit only when asked.
