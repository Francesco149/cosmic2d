# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-11
**Milestone**: M4 — editor mode v0: **first increment DONE** (mode
switch, map painting, collider overlay, map persistence; D026; 7
goldens green; shots on llm-feed; agent-verified, human check
requested). **Next: entity list + inspector** (then prop palette,
knob persistence through the inspector, inertial scroll polish).

## What works right now

Everything from M0–M3 (boot, live sessions, hot reload, parachute, PAL
draw/state/input/trace stack, determinism kit, goldens, pt.ui/console/
repl/perf, error containment, pt.tilemap, the platformer sandbox with
the air kit, attract demo, --eval), plus the M4 increment:

- **pt.editor** (D026 — "the editor is a repl client"): F1 toggles
  editor chrome over the *running* game (sim keeps stepping; keyboard
  stays with the game, mouse belongs to the editor). It owns no sim
  state: every edit is a pt.repl submission — `pt.tilemap.poke` per
  painted cell, the cartridge's `reset_eval` for reset — so editing
  records as D022 EVAL chunks and **verifies byte-exact** (proven by a
  record→verify round trip and the new editpaint golden).
  - Toolbar: tile swatches from the cartridge's tiles table + atlas
    (id 0 = eraser), LMB paint / RMB erase with 8-connected cell-line
    drag continuity, hovered-cell ghost, colliders checkbox, save +
    reset buttons, status (map name/shape, hovered cell).
  - Collider overlay: solid cells tinted, one-way top stripes, AABB
    outlines from the cartridge (player cyan / crates orange / held
    yellow in the sandbox).
  - Cartridge contract: `pt.editor.attach(fn)` in game.init; fn() runs
    once per editor frame, read-only, returns {tm, atlas, camx, camy,
    colliders(), save, reset_eval}.
  - Play-mode lockdown: `editor = false` in project.lua disables F1
    AND the ` console / F3 perf toggles (shipped zips); error banners
    still open the console programmatically.
- **pt.tilemap M4 statics**: poke/peek by name (the eval edit unit,
  OOB-inert), save/load of the raw self-describing bytes, cell_line,
  and `new` returning a `fresh` second value (cells did not survive).
- **The sandbox map is no longer code-built**: whatever sandbox.map
  buffer exists is adopted as-is — painting survives hot reloads, VM
  reboots and snapshot restores. An empty boot seeds from map.dat
  (next to project.lua, written by the editor's save button via
  level.save) else the procedural build, which lives on as
  `game.level.reset()` — the reset button's eval / console command.
  No map.dat is committed yet: the repo's sandbox boots procedural.
- **pt.ui additions**: `capture_mouse()` (overlay owns all mouse downs;
  game still gets ups) and `over_panel` (chrome hit test, one-frame
  latency like hot/active).
- **Tests**: `nix run .#test` ALL GREEN — selftest **22208** (+29: fresh
  flag, poke/peek, save/load round trip, cell_line connectivity) + **7
  goldens** (churn, evalfix, sandbox, sandbox_ease, platformer,
  platformer_dive, **editpaint** [500 f: frame-1 pokes build a tower in
  the demo runway + erase plank cells; the choreography derails against
  the painted geometry deterministically]).

## Verified

- Agent-verified: full suite green on lavapipe (all 6 pre-M4 goldens
  byte-exact through the level.lua restructure — D012 bundles); paint →
  save → fresh-boot-adopts-map.dat loop exercised end to end; collider
  overlay + painting screenshots inspected and pushed to llm-feed
  (3 images, 2026-06-11).
- Human verification PENDING for editor feel — see open questions.

## Next step (M4 continues)

1. **Entity list + inspector** over the doc tree and named buffers —
   uigallery dry-ran the widget set (search, virtualized lists,
   collapsing sections, drag numbers; D021 gaps are additive). Chosen
   next because the human's deferred feel-tuning pass wants knob
   sliders, and knob persistence (item 3) rides on the same panel.
   Inspector WRITES to sim state must go through the repl path like
   paint does (D026) — e.g. `doc.knobs.move.run = 142` strings.
2. **Knobs persisted per project** (file next to project.lua, like
   map.dat) — then the human tuning session.
3. **Prop spawn palette** (crates first; doc-tree prop defs later).
4. M2 wishlist: inertial/bouncy scroll for editor chrome.

## Known small items / debts

- Paint pokes echo as `> pt.tilemap.poke(...)` lines in the console
  scrollback — long strokes are chatty. Deliberate v0 (it teaches the
  eval model); add a quiet submit variant if it grates.
- Paint latency is one sim frame (repl drains at frame start) —
  imperceptible at 60 Hz.
- Swatch strip is a single row — fine to ~15 tiles, becomes a palette
  panel when tilesets grow (M8 procgen will force it).
- Editor mouse capture is all-or-nothing while editor mode is on: a
  cartridge that READS the mouse gets nothing in editor mode. Fine
  until a mouse game exists.
- Demo choreography assumes the procedural map (D025): on a painted
  map `game.demo(1)` will happily walk into walls (that's what the
  editpaint golden is). Reset first if you want the real tour.
- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Freed-buffer husks + texture re-create leaks on VM reboot persist by
  design (inspector cleans up — next increment).
- Trace recorder buffers in memory; M5 ring-trace replaces it (D019).
- repl env caveat (D022): pre-recording env assignments don't travel.
- props separation can squeeze a crate into a wall in pathological
  piles — watch for it now that map painting can build cruel pits.
- Belly slide keeps the standing hitbox (sprite-only flattening); the
  map has no low gaps yet, but painting can now make them — slide
  under a 1-tile gap will NOT fit until the cancel pop gets an
  overhead check.

## Open questions for the human

- **Try the editor windowed**: F1 → paint/erase/drag feel, swatch
  clicking, save + reset, then F1 back to play. Is one-frame paint
  latency invisible as expected? Does the collider overlay read well
  on top of the art (alpha/colors), or too loud?
- F1 as the editor key OK? (Esc was taken by sandbox quit; ` and F3
  stay console/perf. Logged in D026 — cheap to rebind.)
- Keep the repo's sandbox map procedural for now, or start painting
  the real stock level once the prop palette + a second tileset pass
  exist? (map.dat next to project.lua becomes the shipped level the
  moment it's committed.)
- Carried from M3 (waiting on the inspector era): feel-knob pass over
  run/jump/gravity/camera/throw defaults; cam.look_lerp during boost.
