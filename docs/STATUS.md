# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-11
**Milestone**: M4 — editor mode v0: increment 1 (mode switch, painting,
collider overlay, map.dat) **human-verified** ("feels great"); increment
2 DONE — **entity list + inspector (pt.inspect, D027) + knobs persisted
per project (knobs.dat, D028)**. 8 goldens + 22241 selftest checks
green; shots on llm-feed. **Next: prop spawn palette** — and the human
feel-tuning session is now unblocked (knobs persist).

## What works right now

Everything from M0–M3 (boot, live sessions, hot reload, parachute, PAL
draw/state/input/trace stack, determinism kit, goldens, pt.ui/console/
repl/perf, error containment, pt.tilemap, the platformer sandbox with
the air kit, attract demo, --eval) plus M4 so far:

- **pt.editor** (D026): F1 toggles editor chrome over the running game;
  map painting / erasing as recorded EVAL pokes, collider overlay, tile
  swatches, save/reset. `editor = false` in project.lua = play-mode
  lockdown.
- **pt.inspect** (D027 — toolbar `inspect` checkbox, on by default): the
  searchable state tree over the doc tree + every named buffer.
  - Doc numbers drag-edit (speed ~1% of magnitude/px; integers stay
    integers, floats stay floats — literals keep `.0`), bools toggle,
    tables collapse, strings read-only v0. Search = flat full-path
    leaf rows, editors live.
  - Buffers expand to typed lens views (u8..f64 per buffer), every
    cell drag-editable; free button = reload-husk cleanup (hidden for
    `pt.*` engine buffers).
  - Every write is a pt.repl submission (`doc.knobs.move.run = 142.0`,
    `pt.state.buf_poke("sandbox.player","f32",0,920.0)`,
    `pal.buf_free("husk")`) — sessions record + verify byte-exact.
    Works mid-autopsy too (repl drains while paused).
- **pt.state.buf_poke/buf_peek**: by-name typed buffer cell access, the
  generic sibling of pt.tilemap.poke (the inspector's buffer eval unit).
- **pt.ui opts.rect**: label/button/checkbox/slider/number place at an
  explicit rect — editors inside virtualized ui.list rows.
- **knobs.dat** (D028): editor save button (and `game.save_knobs()`)
  persists doc.knobs as canonical doc bytes next to project.lua; empty
  boots (fresh VM / parachute reboot) seed from it before the defaults
  merge; live doc always wins; corrupt file → defaults + log. Tuning
  now survives reboots and travels with a zip. No knobs.dat (or
  map.dat) is committed: the repo's sandbox boots stock.

## Verified

- Agent-verified: `nix run .#test` ALL GREEN — selftest **22241**
  (+33: buf_poke lenses/errors/eval-string, ui rect placement, inspect
  path/literal builders incl. keyword keys + float `.0` + inf,
  built-command exec round trip, read-only render in tree + search
  modes) + **8 goldens** (new: **inspectpoke**, 600 f — knob eval +
  buf_poke teleport + husk create/free derail the demo into the crate
  pit deterministically). knobs.dat save → corrupt → fresh-boot-adopt
  loop exercised headless. 3 inspector shots on llm-feed (2026-06-11).
- Human verification PENDING for inspector feel — see open questions.

## Next step (M4 continues)

1. **Prop spawn palette** (crates first; doc-tree prop defs later) —
   the last M4 PLAN bullet. Spawning must be an eval (probably a
   `game.props.spawn_eval(x, y)`-shaped cartridge command) like paint
   and inspect writes.
2. **Human feel-tuning session** — unblocked: F1 → inspect → drag
   knobs live, save persists. Carried agenda from M3: knob pass over
   run/jump/gravity/camera/throw defaults; cam.look_lerp during boost.
   Retuning movement knobs means re-choreographing the demo (D025) —
   goldens are unaffected (they replay bundled code + knobs).
3. M2 wishlist: inertial/bouncy scroll for editor chrome.

## Known small items / debts

- Inspector drags echo one eval per changed frame — long drags are
  chatty in the console, same family as paint pokes (deliberate v0; a
  quiet submit variant in pt.repl if it grates). The per-frame evals
  are CORRECT for traces: each intermediate value steers that frame.
- Inspector strings read-only; no add/delete of doc keys (console does
  it). No sliders yet — bounded sliders want real range metadata via
  the attach surface (D027 revisit), heuristics would cage values.
- Dragging a buffer cell the sim rewrites every frame "fights" (poke
  lands at frame start, sim then runs): nudging positions works,
  pinning velocities doesn't. Live-edit semantics, documented.
- Freeing a buffer a module still writes = contained game error +
  console autopsy (free is for orphaned husks; pt.* hidden anyway).
- Paint pokes still echo per cell; swatch strip still single-row (M8
  will force a palette panel).
- Editor mouse capture is all-or-nothing while editor mode is on.
- Demo choreography assumes procedural map + default knobs (D025):
  painted maps / tuned knobs derail `game.demo(1)` — that's what the
  editpaint + inspectpoke goldens ARE. Reset first for the real tour.
- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Texture re-create leaks on VM reboot persist by design; buffer husks
  now have the inspector free button.
- Trace recorder buffers in memory; M5 ring-trace replaces it (D019).
- repl env caveat (D022): pre-recording env assignments don't travel.
- props separation can squeeze a crate into a wall in pathological
  piles; belly slide keeps the standing hitbox (slide under a painted
  1-tile gap won't fit until the cancel pop gets an overhead check).

## Open questions for the human

- **Try the inspector windowed** (F1 → inspect): drag-number speed
  (~1% of value per pixel — too twitchy? too slow near zero?), row
  density/readability at 480x270, lens strip usability. Is the panel
  width (186px) right next to the painting viewport?
- **Tuning session whenever you like**: drag knobs.move/dive/dj/cam
  live, hit save — knobs.dat keeps it. Want sliders with real ranges
  for specific knobs first (which ones?), or are drag numbers enough?
- Carried: keep the repo's sandbox map procedural until the prop
  palette + second tileset exist? (Committing your painted map.dat +
  tuned knobs.dat makes them the shipped stock level/feel.)
