# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-11
**Milestone**: M4 — editor mode v0: increments 1+2 (mode switch,
painting, collider overlay, map.dat; inspector + knobs.dat)
**human-verified** ("editor loop feels great", "knobs ui feels pretty
solid"). Increment 3 DONE — **jump-feel curve knobs (D029), dive boost
cap, editor paint toggle, dive rule changes** (all human-requested):
dives spend the dj charge, cancel flips get dive.cancel_grav, the dive
is dead while a boost lasts (no infinite boost chains). 12 goldens +
22241 selftest checks green; shots on llm-feed. **The human is doing
the feel dial-in next** ("at least until we have the real assets") —
then prop spawn palette.

## What works right now

Everything from M0–M3 (boot, live sessions, hot reload, parachute, PAL
draw/state/input/trace stack, determinism kit, goldens, pt.ui/console/
repl/perf, error containment, pt.tilemap, the platformer sandbox with
the air kit, attract demo, --eval) plus M4 so far:

- **pt.editor** (D026): F1 editor chrome over the running game; painting
  as recorded EVAL pokes, collider overlay, swatches, save/reset. NEW:
  a `paint` checkbox in the swatch row (default on) — off disarms the
  brush AND releases the world's mouse to the game (panels still
  capture): inspect/tune without stray clicks editing the map.
  `editor = false` in project.lua = play-mode lockdown.
- **pt.inspect** (D027, toolbar `inspect` toggle): searchable state
  tree over the doc tree + every named buffer; drag-number/checkbox
  editors, typed buffer lens views (u8..f64), husk free button. Every
  write is a pt.repl submission — sessions record + verify byte-exact.
  pt.state.buf_poke/buf_peek are the by-name cell eval unit; pt.ui
  widgets take opts.rect for virtualized rows.
- **knobs.dat** (D028): editor save persists doc.knobs (canonical doc
  bytes) next to project.lua; empty boots seed from it, live doc wins,
  corrupt file → defaults. Nothing committed: repo boots stock.
- **Jump-feel curve** (D029, human ask): knobs.move.jump_h (px) +
  apex_t (frames) derive rise gravity + impulse (stock 56/24 == the
  retired jump=280/gravity=700 **bit-exactly** — demo tour verified
  byte-identical through the finale); fall_mul scales falling gravity;
  hang_speed/hang_mul make a floaty apex window (airborne, non-dive).
  dive.boost_max caps steering while boosted (stock 900 ≈ old uncapped
  behavior). Props fall under their own knobs.prop.gravity/fall_max.
  The defaults merge prunes retired keys (no dead inspector rows).
- **Dive rules** (human ask): a dive SPENDS the double-jump charge —
  no dj out of a dive or its cancel (the space-space chain is gone;
  landing restores; dj→dive still allowed). The cancel flip-out arc
  has its own gravity multiplier, dive.cancel_grav (stock 1.0),
  decoupled from the jump's fall_mul/hang — jump tuning never reshapes
  the flip; the committed dive keeps dive.grav. And the dive button is
  DEAD while a boost lasts — no boost→dive→boost chains for infinite
  fast movement; the touchdown that evaporates the boost unlocks it.
  Tour byte-identical at stock through all of it. demo.lua grew
  **timeline 2, the kit check** (`game.demo(2)`): choreographed
  air-move coverage for goldens (hop-dive, jump-cancel, the
  must-not-fire dj attempt, flop-slide-flip, and the boost coda with
  its mid-boost dead dive press).

## Verified

- Human-verified: editor loop (increment 1) and the inspector knob UI
  ("pretty solid") — windowed, 2026-06-11.
- Agent-verified: `nix run .#test` ALL GREEN — selftest **22241** + **12
  goldens** (new today: **jumpfeel** 700 f, floaty-curve evals derail
  the tour; **boostcap** 420 f, demo_t0-offset finale + teleport, cap
  360 vs 900 confirmed divergent before recording; **divecancel**
  280 f, kit check + cancel_grav=0.7 — the dj attempt window confirmed
  airborne frame-by-frame, cancel_grav 0.7 vs 1.0 confirmed divergent;
  **boostlock** 360 f, the kit check's boost coda at stock knobs — the
  mid-boost dive press confirmed dead by pose + trail + speed in the
  frame series). Stock-default bit-exactness of D029 AND every dive
  rule proven by byte-identical tour PNGs at frames 400/900/1500/1650.
  knobs.dat round trip exercised. On llm-feed today: 5 shots + 2
  kit-check montages.

## Next step (M4 continues)

1. **Human feel dial-in — in progress** ("at least until we have the
   real assets"): jump_h/apex_t/fall_mul/hang_*, dive.grav/cancel_grav/
   boost_max + the rest, paint-off mode keeps the mouse safe, save
   persists to knobs.dat. Carried agenda: cam.look_lerp during boost.
   AFTER the dial-in: decide whether the tuned knobs.dat ships as the
   committed stock feel (then defaults in main.lua should be updated to
   match and the demo tour re-choreographed — D025; goldens are
   unaffected either way, they bundle code + knobs).
2. **Prop spawn palette** (crates first; doc-tree prop defs later) —
   the last M4 PLAN bullet. Spawning must be an eval (a
   `game.props.spawn_eval(x, y)`-shaped cartridge command) like paint
   and inspector writes (D026/D027).
3. M2 wishlist: inertial/bouncy scroll for editor chrome.

## Known small items / debts

- Inspector drags echo one eval per changed frame — chatty on long
  drags (deliberate v0; quiet submit variant in pt.repl if it grates).
  Per-frame evals are CORRECT for traces (each value steers its frame).
- Inspector strings read-only; no add/delete of doc keys; no sliders —
  bounded sliders want range metadata via the attach surface (D027).
- Dragging a buffer cell the sim rewrites every frame "fights" (poke at
  frame start, sim then runs): nudge positions yes, pin velocities no.
- Freeing a still-written buffer = contained game error + autopsy.
- Editor mouse capture all-or-nothing only while `paint` is ON now;
  paint-off hands the world mouse to the game (mouse games playable
  under the editor).
- Demo choreography assumes procedural map + STOCK knobs (D025): a
  painted map, tuned knobs.dat, or knob evals derail `game.demo(1)` —
  that's what editpaint/inspectpoke/jumpfeel/boostcap goldens ARE.
- apex_t guarded against 0 (no NaN); negative jump_h floats upward —
  tuning freedom, not a bug. hang window also shapes double-jump arcs
  (generic |vy| window) — intended.
- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Texture re-create leaks on VM reboot persist by design; buffer husks
  have the inspector free button.
- Trace recorder buffers in memory; M5 ring-trace replaces it (D019).
- repl env caveat (D022): pre-recording env assignments don't travel.
- props separation can squeeze a crate into a wall in pathological
  piles; belly slide keeps the standing hitbox (slide under a painted
  1-tile gap won't fit until the cancel pop gets an overhead check).

## Open questions for the human

- **Tune away**: defaults reproduce the old feel exactly; jump_h/apex_t
  /fall_mul/hang_speed/hang_mul + dive.boost_max are live in the
  inspector, paint checkbox off keeps the mouse safe, save persists.
  Typical starting points if you want them: fall_mul 1.4–1.8,
  hang_speed 40–70, hang_mul 0.4–0.6, boost_max 380–450.
- Sliders with real ranges for specific knobs (which ones?), or are
  drag numbers enough for the session?
- Carried: keep the repo's sandbox map procedural until the prop
  palette + second tileset exist? (Committing your painted map.dat +
  tuned knobs.dat makes them the shipped stock level/feel.)
