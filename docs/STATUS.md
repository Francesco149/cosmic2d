# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-11
**Milestone**: M4 — editor mode v0: increments 1–3 human-verified
(editor loop, inspector, feel knobs). Increment 4 DONE — **the feel is
LOCKED IN**: the human's dial-in is the stock KNOBS default
(canon-hash-verified fold, knobs.dat retired), mantle leniency (D030),
dive rules finalized (one dive per airtime, dj spends on dive, boost
cap + lockout, cancel_grav), dj scales the jump curve, and the attract
tour is **re-choreographed for the locked feel** (platformer_locked,
2780 f). 15 goldens + 22241 selftest checks green; tour montage on
llm-feed. **Next: prop spawn palette** (last M4 bullet), then M2
wishlist inertial scroll.

## What works right now

Everything from M0–M3 (boot, live sessions, hot reload, parachute, PAL
draw/state/input/trace stack, determinism kit, goldens, pt.ui/console/
repl/perf, error containment, pt.tilemap, the platformer sandbox)
plus M4 so far:

- **pt.editor** (D026): F1 chrome, paint/erase as EVAL pokes, collider
  overlay, save/reset, `paint` checkbox (off = brush disarmed + world
  mouse back to the game). `editor = false` = play-mode lockdown.
- **pt.inspect** (D027): searchable doc-tree + named-buffer tree with
  in-place editors (drag numbers, checkboxes, typed u8..f64 buffer lens
  views, husk free button). Every write is a pt.repl eval — records +
  verifies byte-exact. pt.state.buf_poke/buf_peek; pt.ui opts.rect.
- **knobs.dat** (D028): editor save persists doc.knobs; boot seeds from
  it when the doc is empty. (No file in the repo: the locked values ARE
  the code defaults now — a knobs.dat would shadow future default
  changes, so the redundant one was removed post-fold.)
- **The LOCKED stock feel** (D029 + lock-in): run 76, jump_h 34.685 px
  / apex_t 24 f with a real apex hang (×0.51 under |vy| 30.2), cut
  0.20, fall_mul 1.0, glide-class dives (grav ×0.093), boost 135 (cap
  203.6, window 3), dj.scale 0.8756, prop gravity split from player
  feel. Placeholder-art feel — revisit with real assets (M9).
- **Air-kit rules** (human-locked): jump → double jump (dj.scale × the
  jump impulse) → ONE dive per airtime → one cancel (boost if
  in-window, holding the dive direction) → touchdown resets the kit.
  A dive spends the dj charge; the dive button is dead after a cancel
  or during a boost until you touch ground; the cancel flip has its
  own gravity (dive.cancel_grav); release-cut applies to both jumps.
- **Mantle leniency** (D030, knobs.move.mantle = 4 px): a descending
  near-miss at a lip — overlap or side-bonk flush — lands ON the
  platform; the synthesized hit.down runs the full touchdown logic.
  Caveat that matters for choreography AND play: a flush vertical rise
  gets no mantle (no overlap, no inward motion) — hold INTO the face
  to drift over the lip, or stack a dj.
- **The tour v2** (`game.demo(1)`): re-choreographed to SPEAK the
  locked vocabulary — full-hold tower hops, balcony jump→dj stack,
  balcony-height glide to the plateau, pillar glide-crash perch, glide
  into the crate pile, carry + stair throw, drop-through, the slow
  crate-floor crossing, wall-hugging dj-stack mounts home, glide back,
  and a glide-cancel / flop-flip / jump→dj→glide finale. ~2730 frames.
- **Choreography tooling**: `--eval "_G.DEMO_DBG=30"` prints a player
  track every N frames (x/y/vy/dive/charge/carry; reads+prints only);
  demo.lua exports TIMELINE/KITCHECK for boundary dumps. The tuning
  loop that works: telemetry run → align against a Lua boundary dump →
  fix rows → repeat; settle-dead rows and wall-press overruns are the
  two re-sync primitives.

## Verified

- Human-verified: editor loop, inspector knob UI, and the locked knob
  values themselves (their dial-in, folded verbatim — canon-hash-equal
  to their saved knobs.dat before it was retired).
- Agent-verified: `nix run .#test` ALL GREEN — selftest **22241** +
  **15 goldens** (this session: jumpfeel, boostcap, divecancel,
  boostlock, djscale, mantle, **platformer_locked** — the full v2 tour,
  2780 f). The whole dial-in lands bit-exact at stock (tour PNGs
  byte-identical at every step until the lock-in itself). Tour v2
  verified beat-by-beat via telemetry + 20-shot montage (on llm-feed).
- dj.speed→scale migration tested live; mantle A/B verified (0 falls,
  4 lands) before its golden.

## Next step (M4 continues)

1. **Prop spawn palette** (crates first; doc-tree prop defs later) —
   the last M4 PLAN bullet. Spawning must be an eval (a
   `game.props.spawn_eval(x, y)`-shaped cartridge command) like paint
   and inspector writes (D026/D027).
2. M2 wishlist: inertial/bouncy scroll for editor chrome.
3. Cleanup candidates while in the area: re-time the kit-check boost
   coda for the locked knobs (boost_win 3 + glide sink means the old
   cancel timing no longer boosts — boostlock's bundled copy still
   verifies forever, but FUTURE kit-check recordings lost that
   coverage); the finale's "late cancel" boost is currently a plain
   flip for the same reason (cosmetic).

## Known small items / debts

- Kit-check codas are mistimed for the locked knobs (above) — the kit
  check still runs deterministically; only boost coverage in future
  recordings is affected.
- Inspector drags echo one eval per changed frame (correct for traces;
  quiet submit variant if it grates). Strings read-only; no add/delete;
  no sliders (range metadata via attach, D027).
- Dragging a sim-rewritten buffer cell "fights" (live-edit semantics).
- Demo choreography assumes the procedural map + LOCKED stock knobs
  (D025): painted maps or knob evals derail it — that's what the
  derail goldens are. Reset + stock for the real tour.
- apex_t guarded against 0; negative jump_h floats upward (tuning
  freedom). Hang shapes dj arcs too (generic |vy| window) — intended.
- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Texture re-create leaks on VM reboot persist by design; buffer husks
  have the inspector free button.
- Trace recorder buffers in memory; M5 ring-trace replaces it (D019).
- repl env caveat (D022): pre-recording env assignments don't travel.
- props separation can squeeze a crate into a wall in pathological
  piles; belly slide keeps the standing hitbox.

## Open questions for the human

- **Watch tour v2** (montage on the feed, or `game.demo(1)` after a
  `game.level.reset()` if your painted map.dat is loaded): does the
  new choreography read as deliberate showmanship in the locked feel?
  Beats worth a re-cut are cheap now (telemetry + boundary tooling).
- Your painted map.dat is still local/uncommitted: commit it as the
  stock level when the prop palette + second tileset exist, or keep
  procedural?
- The finale has no real BOOST beat under the locked knobs (window 3
  is genuinely hard open-loop). Fine to leave as flip, or want me to
  hunt a boost-able setup (e.g. a scripted dive from a specific ledge
  height) for the showcase?
