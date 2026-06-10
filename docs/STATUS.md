# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-11
**Milestone**: M3 — sandbox platformer v0: **agent-done** (`nix run .#test`
green, 5 goldens; montage + hero shot on llm-feed). Awaiting the human
windowed feel pass, then knob-dialing together. Next: M4 — editor mode v0.

## What works right now

Everything from M0–M2 (boot, live sessions, hot reload, parachute, PAL
draw/state/input/trace stack, determinism kit, goldens, pt.ui/console/
repl/perf, error containment), plus M3:

- **pt.tilemap** (D024): tile grids as self-describing named buffers
  (w/h/tile header + u16 cells), tile classes (solid/one-way) in a code
  table, camera-windowed bulk rendering, and an axis-separated swept-AABB
  mover — boundary-scanning (no tunneling), one-ways collide only on row
  entry from above, `drop` opt for down+jump, OOB = side/bottom walls +
  open sky. Selftested (+37 checks, 22179 total).
- **projects/sandbox = the platformer** (the M1 particle playground is
  retired; it lives on inside the old goldens' code bundles). Modules:
  `level` (procedural tileset + map built at chunk top-level → editing
  the level file hot-rebuilds it; parallax mountains/hills/clouds),
  `player` (MapleStory vocabulary: run accel/decel + air control, jump
  buffer + coyote, release-cut variable height, drop-through, grab/throw,
  squash & stretch + land/footfall dust), `props` (crate pit: tilemap
  collision, bounce/friction, stack-settling pairwise separation, thrown
  crates shove the pile), `fx` (256-particle pool, dust/spark palettes),
  `demo` (attract mode, D025), `pix` (procedural placeholder art).
- **Feel knobs all live** in `doc.knobs.{move,cam,throw,prop,fx,feel}` —
  tune from the console while playing; knob-merge in init grows new keys
  into old docs.
- **Attract mode / demo** (D025): `game.demo(1)` (console or `--eval`)
  plays a ~23 s scripted tour: left plank tower → balcony → plateau →
  pillar long-jump → pit dive → crate grab → carry out (full jump over
  the 2-tile wall) → throw back in from the stair plank → drop-through →
  run home. Any real press takes control back. Pure f(frame): replays
  byte-exact, drives goldens and montages.
- **pt.main --eval CODE** (repeatable): queues console lines for sim
  frame 1 via the D022 path — recorded as EVAL chunks, so headless
  recordings can flip doc switches.
- **Tests**: `nix run .#test` ALL GREEN — selftest (22179) + 5 goldens
  (churn, evalfix, sandbox, sandbox_ease, **platformer**: 1400 frames of
  the demo, ~1 MB). The two M1 sandbox goldens still replay their bundled
  particle-playground code against the rewritten cartridge — D012 doing
  its job.

## Verified

- Agent-verified this session: selftest + full golden suite on lavapipe;
  demo choreography probed numerically (positions/grounded/carry at 30 f
  intervals) end to end; prop pile settles to rest (stacks of 2–3, all
  velocities zero); 12-frame montage + hero shot inspected and pushed to
  llm-feed.
- Human: **not yet** — M3 exit wants the windowed feel pass (below).

## Next step

1. **Human feel pass** (windowed `bin/pettan projects/sandbox`): run,
   jump heights, drop-through, grab/throw arcs, camera follow, squash &
   stretch amount. Knobs are console-live (`doc.knobs.move.jump = 320`
   etc.) — dial together and bake the keepers into KNOBS in main.lua.
   Also try `game.demo(1)` windowed: the attract loop is the quickest
   tour. (Console fixes from 2026-06-11 get a free re-check here.)
2. Then **M4 — editor mode v0** (PLAN): editor/play mode switch, map
   painting (retires the code-built map, D024 note), prop spawn palette,
   entity list + inspector over the doc tree + buffers, collider debug
   draw, knobs persisted per project. The uigallery dry-run already
   shaped the widgets; pt.tilemap's header makes maps tool-openable.

## Known small items / debts

- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Freed-buffer husks + texture re-create leaks on VM reboot persist by
  design (inspector cleans up in M4).
- Trace recorder buffers in memory; M5 ring-trace replaces it (D019).
- Console line wrap = none; dim-timestamp polish possible (M2 note).
- repl env caveat (D022): pre-recording env assignments don't travel.
- UI feel wishlist (human, 2026-06-11): inertial/bouncy scroll regions —
  scheduled with M4 editor polish.
- Demo choreography is calibrated against default move knobs (D025):
  retuning movement after the human pass means re-walking the timeline
  (probe pattern: temp print in game.step at %30 frames) and re-recording
  the platformer golden deliberately (pre-1.0 break rules, PROCESS).
- Player/prop interaction is one-way by design v0: crates never block
  the player; thrown crates don't hit the player. Revisit when the prop
  pit gets physics love (post-M10 rotation solver).
- props separation can squeeze a crate into a wall in pathological piles
  (positional pushes are mover-clamped, but two crates + wall can still
  pin); watch for it once map painting lets users build cruel pits.

## Open questions for the human

- Feel pass: are run speed (130), jump (280/cut 0.45), gravity (700),
  camera (lerp 0.10, lookahead 26, deadzone 26), throw (260/200) in the
  right neighborhood? Squash 0.55 too cartoony or not enough?
- Art direction check on the procedural placeholders (tiles, kid sprite,
  crates, parallax palette) — placeholder-fine, or worth one more pass
  before M4 screenshots start accumulating?
