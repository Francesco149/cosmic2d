# HELPDOCS — the in-engine help polish program

> Status: **queued** (scoped 2026-07-22). One session per queue row, in
> order, each committed with proof. Check a row off here when its session
> lands; STATUS.md carries the running handoff as usual.

The ask (the human, 2026-07-21): every tool's help starts with a **sizable,
detailed, engaging tutorial** that makes something meaningful with the tool,
plus a **complete reference of every single knob and button** split out as
its own doc and **linked at the top**. A good amount of **screenshots** —
both "the UI should look like this at this step" and "this is the visual
result". The **project presets** get the same treatment. Tutorials are
**tested live** (drive tapes) while being screenshotted; UX rough edges
found en route are fixed, not documented around.

Prior art this builds on: the D127 getting-started tape (execute the doc as
written through the shipped UI), the D144 walkthrough pass (short power
walkthroughs in eight tool docs), the D120 KAT-pinned findability sweep
(the completeness-guard pattern), and the six existing `media/` captures.

## 1. The per-tool contract (what "done" means)

A tool's docs session is complete when ALL of these hold:

1. **`win-<tool>.md` is the tutorial.** Structure: title → one-line pitch →
   the reference link (see 2) → the tutorial. The tutorial makes one
   meaningful, named artifact (a game-ready sprite, a playable level, a
   full song loop…), 8–15 numbered steps, written to be followed exactly —
   every click, key, and expected on-screen response named. Existing
   workflow/recipe prose survives by being folded into the tutorial or
   moved to the reference; nothing valuable is deleted.
2. **`ref-<tool>.md` is the complete reference**, linked in the tutorial's
   first three content lines ("Every knob and button: [the <tool>
   reference](engine/stock/docs/ref-<tool>.md)") and linking back. It
   covers **every** header chip, tool, rail control, strip dial, panel
   row, hotkey, drag/drop affordance, left/right/middle-click and wheel
   behavior, and the asset format notes — organized by UI region (header
   → rails → strips → canvas gestures → hotkeys → formats), so a user
   holding the window can find the thing under their cursor. The source
   of truth is the window's code (`engine/cm/ed/win/<tool>.lua`: the
   `hotkeys` kit table, header/panel draws, gesture arms), not memory.
3. **Screenshots**: captured from the real editor by the session's drive
   tape at named tutorial steps — UI-state shots for steps where the
   screen must be confirming ("the fill dials now read…"), result shots
   for visual payoffs. Named `media/<tool>-<slug>.png`, cropped to the
   window, visually inspected by the agent, montage pushed to llm-feed
   with title+note. Budget: media ships in every archive — keep shots
   lean (window crops, not full desktops; the whole dir should stay
   modest, currently 436K).
4. **The tape is the test.** A drive tape (`tools/drive/drive.lua`) on a
   fresh smoke copy (fresh scaffold for preset sessions) executes the
   tutorial **as written**. A step that cannot be performed exactly as
   the doc says is a bug — in the doc or in the UX. UX rough edges found
   en route are fixed at class level in the same session (own commit) or
   honestly deferred in the session's ADR/STATUS note.
5. **Guards stay green**: the completeness sweeps (see 3), the D127
   reader-constraint KATs, `nix run .#test` ALL GREEN, goldens
   byte-identical (docs+media+chrome only), `tools/build-windows.sh`
   refreshed, STATUS updated, committed in logical units.

## 2. Reader constraints (every session must respect these)

- No `|` markdown tables — the reader renders them literal (D127,
  KAT-guarded). Use aligned preformatted blocks or prose lists.
- Inline `**bold**` / backtick spans must balance **per source line**
  (D127 KAT); mind them when rewrapping.
- Images are **block-level, one per source line**, `![alt](media/x.png)`;
  relative paths resolve against the doc root, out-of-tree projects fall
  back to the engine root (D145).
- Links use reader-resolvable paths (`engine/stock/docs/…`), the existing
  convention.

## 3. Shared scaffolding (built in the first completed session — H7, which the human pulled forward)

- **The hotkey sweep KAT**: a declared kind→ref-doc mapping table; for
  every mapped kind, each `kind.hotkeys` entry's key and hint must be
  findable in its `ref-*.md`; a kind that ships hotkeys but has no
  mapping refuses once its queue row is checked off. (The D120 pattern.)
- **The link sweep KAT**: every mapped `win-*.md` links its `ref-*.md`
  within the first three content lines.
- **The image sweep KAT**: every `![](media/…)` target in
  `engine/stock/docs/` exists on disk — a renamed capture can't ship a
  dead image.
- **The capture recipe** documented as a comment in the H1 tape
  (`tools/drive/tape-sprite-tutorial.lua` — HELPDOCS tapes ship in-repo
  as of H1): fresh smoke copy → drive the tutorial → `--shot` at named
  steps → crop to the window → stage under `engine/stock/docs/media/`.
- **Shots capture at 2x** (D163, the human's report: 1x captures
  rasterize glyphs at sizes no scaled display ever shows). Tapes declare
  `D.shot_zoom(name, frame, kind)`; per-shot reruns set `SHOT=<name>` so
  the camera zooms ×2 two frames before the shot (input always runs at
  z = 1 — shots sit at gesture-quiet frames). Files ship as
  `media/<name>@2x.png`: the reader lays an `@2x` image out at half its
  intrinsic pixels and samples screenshots linearly, so the budget is
  layout size ≤700x550 (intrinsic ≤1400x1100).

## 4. The queue — one focused session per row

Order: 2D art chain first (sprite is the exemplar that builds the
scaffolding), then files, world tools, audio, 3D, project/shell, then the
presets last (they cross-link finished tool docs and reuse their media).

- [x] **H1 — the sprite editor**. DONE 2026-07-22 (D161). The
  "paint the hero" tutorial (silhouette → flood → masked linear
  cel-shade → bake → face → *mul* shadow layer → *add* light layer →
  duplicated frames for H2), `ref-sprite.md` with the complete surface
  (fill recipes moved there), four taped screenshots, the `REF_DOCS`
  sprite row. The UX fix the session surfaced: the cursor `x,y`
  readout (named positions were unfollowable without it); the doc bug
  the tape caught: the bucket has no brush strip, step 8 returns to
  the pen first. The tape SHIPS at `tools/drive/tape-sprite-tutorial.lua`
  carrying the §3 capture recipe — the convention for every next row.
- [x] **H2 — the animation window**. DONE 2026-07-22 (D162). The
  "bring the hero to life" tutorial (exhale + blink frames painted,
  then idle/walk/blink cut with the timing lessons — uneven idle,
  even-tempo march, once-blink from code), `ref-anim.md` with the
  complete surface, four taped screenshots, the `REF_DOCS` anim row.
  The UX fixes the session surfaced: the clip **name** field (clips
  were stuck as clipN), the space/l kit hotkeys (the old doc promised
  space), paused-preview freshness on cross-window commits. The tape
  chains on H1's saved hero (`tools/drive/tape-anim-tutorial.lua`,
  20/20 VERDICTs; fresh copy per shot rerun — the recipe is in the
  header).
- [x] **H3 — the palette window**. DONE 2026-07-22 (D164). The
  "color-script a moonlit vale" tutorial makes one cohesive 16-color
  artifact: five-shade night-violet, moss-teal, and lantern-gold ramps,
  one shared shadow stored once, and one rose accent; then saves it,
  stacks it in the sprite window, and repaints H1's hero without losing
  the lighting layers. `ref-palette.md` covers the complete surface and
  `.pal`/runtime contracts; five tightly fitted taped @2x shots replace
  the old 1x ramps card; and `REF_DOCS` grows the palette row. The UX fix
  this session surfaced:
  every drag slider now has a stable exact-value bay (degrees, percent,
  byte channel, or count), and paste/add/dup/ramp operations stop at the
  format's honest 256-color ceiling instead of letting the save encoder
  hide excess working swatches. The shipped tape chains on H1
  (`tools/drive/tape-palette-tutorial.lua`, 23/23 VERDICTs) and proves the
  saved palette through the real asset-drag and sprite-paint payoff.
- [x] **H4 — the assets + stock windows**. DONE 2026-07-22 (D165). The
  paired "curate the moonlit courier kit" story is split at the natural
  window boundary: Assets moves H1's complete sprite family into
  `art/characters/` while the open window, dirty state, journal and bakes
  follow, then routes `plank.png` first to bare canvas and then the sprite
  stamp well; Stock filters/auditions a noir song as an unsaved copy,
  adopts and renames it, direct-copies/auditions/renames `fm-glass`, and
  binds that local voice into the saved arrangement. `ref-assets.md` and
  `ref-stock.md` cover every visible control, pointer/key door, preview,
  file-family rule, copy/import path, rewind wall and honest limitation;
  four fitted @2x captures show rename, carry, filter, and unsaved states.
  The session's UX fix makes `.song` and `.ins` real members of Assets'
  **sound** family and routes OS-dropped instruments to `ins/`. The shipped
  `tools/drive/tape-assets-stock-tutorial.lua` chains H1 and passes 20/20
  VERDICTs through the final local instrument binding.
- [x] **H5 — the map window**. DONE 2026-07-22 (D166). The 13-step
  "build Moonlit Crossing" tutorial authors one complete playable route:
  a closed solid chain with two true 45-degree banks, a one-way bridge,
  a circle query hazard, fully described spawn/goal markers, a generated
  graybox skin, and freehand plus CTRL-aligned plank art; it then saves,
  loads through the smoke console, walks the slopes, and proves the hazard
  reset. `ref-map.md` covers the complete window and CMAP/runtime contract;
  four inspected @2x shots show COL chains, marker fields, a live snap carry,
  and the running route; `REF_DOCS` grows the map row. The exact lesson
  surfaced three UX truths: the view now reports authored `x,y`, Graybox
  creates a fresh nested map's parent directory before its first save, and
  the selected-collider hint names the **closed** chip instead of promising
  a nonexistent "c closes" shortcut. The shipped
  `tools/drive/tape-map-tutorial.lua` passes 21/21 VERDICTs through authored
  bytes, saved assets, runtime collision, slope traversal, and hazard reset.
- [x] **H6 — the tilemap window**. DONE 2026-07-22 (D167). The 13-step
  "build the Moonlit Gate" lesson sizes a 7x6 CTLM, fills its wall mass,
  carves a doorway with right-button Fill, dresses six stock-tile roles,
  picks from authored cells, chips the ruin with both eraser doors, and
  proves undo/save/view. It then drops the one `.tm` into H5's Moonlit
  Crossing twice, assigns the duplicate an exact position, opens the shared
  source from Map, and proves one saved cap edit refreshes both placements.
  `ref-tmap.md` covers the complete editing/view/map/CTLM surface; three
  inspected @2x shots show the live carve, finished ruin, and both refreshed
  copies; `REF_DOCS` grows the tilemap row. The lesson's UX fix adds exact
  zero-based `cell x,y · tile N · zoom` hover feedback while preserving the
  compact off-grid zoom readout. The shipped
  `tools/drive/tape-tmap-tutorial.lua` chains the H5 setup and passes 23/23
  VERDICTs through saved source bytes, placement duplication, double-open,
  shared editing, and both-copy refresh.
- [x] **H7 — the synth (+ the sound player feeder)**. DONE 2026-07-22
  (ran first at the human's call; D160). The "four-sound chip kit"
  tutorial (lead / bass / kick / jump), `ref-synth.md` with every knob
  + all 53 stock presets reverse-engineered into family recipes,
  `ref-sound.md`, five taped screenshots, the §3 sweep KATs, and the
  UX fix the session surfaced: the op panels' missing `dtn` and `fix`
  sliders (patch/kernel/preset knobs the UI never exposed).
- [ ] **H8 — the music window**. Tutorial: arrange a two-pattern,
  four-track loop with a stereo mix — tracks + instruments, the roll's
  round-13 grammar (keys column, hold-to-audition, select/move/ghost
  paste), clips on the rail, volume/pan per track (grow the D144
  4-track walkthrough). Shots: the roll with the keys column mid-
  audition, the arrangement rail, the mix rows. Reference:
  `ref-music.md` — the rail, the roll gestures (add/select/move/resize/
  duplicate/delete/octave/paste), the velocity lane, mix, transport,
  every hotkey. Note: win-music.md is the freshest doc (D157–D159
  rewrites) — this session is mostly restructuring + shots. Sources:
  `win/music.lua`.
- [ ] **H9 — the terrain window**. Tutorial: sculpt the lakeside vale —
  heights, the noise brush, texture paint, water, props, a route
  (grow the D144 walkthrough; `media/terrain-vale.png` exists as the
  result shot — add the step shots). Reference: `ref-terr.md`.
  Sources: `win/terr.lua`, EDITOR3D.md.
- [ ] **H10 — the mesh window**. Tutorial: model and texture a watchtower —
  box → extrude → detail, then the uv tab: checkers, bind a `.spr`,
  place islands, per-vertex tweaks, animated texture frames (the D155
  garage mechanism). Shots: each modeling stage, the uv tab with an
  island mid-drag, the textured result turning. Reference:
  `ref-mesh.md` — every tab, the uv panel dials (snap/grid/fr), gizmos,
  hotkeys. Sources: `win/mesh.lua`, EDITOR3D.md §5, D155.
- [ ] **H11 — the figure window**. Tutorial: a critter from the mascot —
  rig, pose, walk cycle, the sprite bake into a game-ready strip.
  Shots: the rig, two walk phases, the baked strip in the sprite
  window. Reference: `ref-figure.md`. Sources: `win/figure.lua`,
  COSMIC3D.md figures.
- [ ] **H12 — the project window (+ the settings publish flow)**.
  Tutorial: wire a project for players — project.lua options with
  defaults (D133 data declarations), controls/credits/license text
  files, save-values-as-defaults from the settings window (D136), and
  publish the portable player. Shots: the options list, the settings
  window with the publish button live, the built archive. Reference:
  `ref-project.md`. Sources: `win/project.lua`, `win/settings.lua`.
- [ ] **H13 — the editor shell** (editor.md as the complete shell
  reference). Tutorial already exists (getting-started.md, D127-taped);
  this session completes editor.md into the full reference — canvas ALT
  grammar, spawn menu, launcher (Ctrl+Space), window focus grammar
  (Ctrl+Tab/W, Alt+arrows), rewind, console, code window, game window,
  the F1 player menu, settings — and adds shell screenshots to both.
  Sources: EDITOR.md, `ed/` shell modules, the D121–D136 grammar ADRs.
- [ ] **H14 — preset: the platformer starter** (make-platformer.md).
  Tutorial: make it YOURS — run it, tour every shipped file, change
  gravity/jump feel live, add a double-jump, author a new room with the
  H5 map skills, reskin the hero with H1/H2 skills, swap the song.
  Reference section: everything the template ships (files, options,
  markers, songs, the collision setup). Tape on a fresh scaffold.
- [ ] **H15 — preset: the top-down starter** (make-topdown.md). Same
  shape: tour, tweak movement, add an NPC/pickup, a second screen,
  reskin. `media/template-topdown.png` exists; add step shots.
- [ ] **H16 — preset: the arcade starter** (make-arcade.md). Same shape:
  tour, tweak difficulty curve, add a pickup/enemy pattern, juice
  (tween/flash through the D129 doors), reskin.
- [ ] **H17 — preset: the 3D explorer starter** (getting-started-3d.md).
  Same shape: tour, resculpt the vale (H9 skills), add a landmark mesh
  (H10), a mascot critter (H11), presentation presets.
- [ ] **H18 — preset: blank** (getting-started.md). Mostly lands via
  D127/D145 — this session re-tapes it against the current UI, adds the
  missing screenshots, and links the finished ref-docs where steps
  touch tools.

## 5. Session protocol reminders

Each session: read this doc's row + the tool's current `win-*.md` + the
window source; write the tutorial + reference; cut the tape that drives
the tutorial as written, shooting the screenshots; fix or honestly defer
UX findings (own commits; ADR if a binding choice); run the sweeps + full
suite; build-windows; llm-feed montage; check the row off HERE; update
STATUS; commit; suggest `/clear`.
