# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-12
**Milestone**: M4 — editor mode v0: **COMPLETE** (every PLAN bullet
done and verified; the feel is LOCKED IN per D029/D030, prop palette
D031). Post-M4 cleanup also done this session: (1) M2-wishlist
**inertial scroll** with edge rubber-band in pt.ui (selftest-covered,
montage on the feed); (2) the **kit-check boost coda re-timed** for
the locked knobs + a new **kitcheck golden** pinning the full air-kit
rule set including the boost; (3) the **tour finale re-cut** — real
DIVE BOOST beat + a vertical-tower flare closer (montage on the feed,
taste check pending). 17 goldens + 22244 selftest checks green.
**Next: M5 — time machine** (ring trace D019, scrubber).

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
  and the finale: flop-cancel DIVE BOOST riding the lowland to the
  plateau wall, no-cancel belly flop, then a vertical jump→dj tower
  into a swoop with a low-flare landing. 2719 frames.
- **Inertial scroll** (pt.ui, M2 wishlist; human-verified "feels
  pretty good"): a wheel notch is velocity now (same 3-row total
  travel), edges rubber-band (overshoot, spring return that snaps
  dead AT the edge). Thumb drags / scroll_set / scroll_to_bottom stay
  instant. Dev-chrome only — never sim, never in traces; rows render
  on a rounded offset so pixel text stays crisp mid-glide. Feel knobs
  on **ui.style.scroll** ({inertia, elastic, fric, fric_out, spring},
  console-tunable, NOT doc-tree — UI state stays out of traces);
  inertia=false = classic jumps, elastic=false = hard edges.
- **Orphaned-focus fix**: a text field focused inside chrome that
  stops drawing (editor toggled off with a focused search box) used
  to hold cap_keys forever — the game went deaf to key-downs.
  frame_end now releases focus when the focused widget didn't draw
  that frame.
- **Choreography tooling**: `--eval "_G.DEMO_DBG=30"` prints a player
  track every N frames (x/y/vy/dive/charge/carry; reads+prints only);
  demo.lua exports TIMELINE/KITCHECK for boundary dumps. The tuning
  loop that works: telemetry run → align against a Lua boundary dump →
  fix rows → repeat; settle-dead rows and wall-press overruns are the
  two re-sync primitives.
- **Prop spawn palette** (D031): the attach surface's optional `props`
  list puts cartridge spawnables in the swatch strip (icon = atlas
  sub-rect). While an entry holds the brush, LMB/RMB press edges submit
  its spawn/erase eval formatted with the world mouse. Sandbox:
  `game.props.spawn(x,y)` (crate centered on the click, capacity =
  actual buffer size, 48 on fresh boots), `game.props.despawn_at(x,y)`
  (topmost free crate under the point; held refuses). Despawn
  swap-compacts; player.step self-heals its carry index by re-finding
  the held flag. props.init now adopts an existing buffer at its own
  size (restore/reload safe across capacity changes).

## Verified

- Human-verified: editor loop, inspector knob UI, the locked knob
  values themselves (their dial-in, folded verbatim — canon-hash-equal
  to their saved knobs.dat before it was retired), and the prop spawn
  palette ("feels good", 2026-06-12).
- Agent-verified (this session): `nix run .#test` ALL GREEN — selftest
  **22244** + **17 goldens** (new: **kitcheck**, 560 f demo(2) on a
  fresh procedural boot — pins spent-press, no-dj-after-dive,
  flop-slide-flip, the BOOST from the young slide, dive dead
  mid-boost, boost dies at touchdown, neutral high cancel = plain
  flip, dive dead post-cancel, grounded jump→dj closer). Scroll
  physics tuned offline, then frame-by-frame in-engine (notch glides
  to exactly 3 rows; fling at an edge: overshoot −27.7 px, snap dead
  at 0 in 7 f, zero drift). Finale re-cut verified beat-by-beat via
  the TRK eval-chain telemetry on the procedural map: flop f2378,
  boost f2380 (sl=2), wall-kiss anchor x=470, flare at x=428, bow at
  x=434 (36 px clear of the wall).
- Earlier (2026-06-11): tour v2 verified beat-by-beat via telemetry +
  20-shot montage; dj.speed→scale migration tested live; mantle A/B
  verified (0 falls, 4 lands) before its golden.

## Next step (M5 — time machine)

1. Read D019 + ARCHITECTURE on the trace format, then design the
   **always-on ring trace** (last N seconds, replacing the in-memory
   recorder's grow-forever buffering) — snapshot story to DECISIONS.
2. Then the timeline scrubber UI (read state straight from trace
   deltas, no re-sim), rewind & resume, trace export ("save what just
   happened"), replay playback. Pixel goldens land this milestone too
   (pinned lavapipe).

## Known small items / debts

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

- **Two montages on the feed** (2026-06-12): (1) the inertial-scroll
  rubber-band — also just wheel the console/inspector in a live
  session, especially at an edge; (2) the finale re-cut — does the
  boost's plateau wall-kiss read as deliberate (it's also the beat's
  re-sync anchor), and does the vertical-tower flare closer land as
  a finale? Beats are cheap to re-cut (telemetry + boundary tooling).
- **Watch tour v2** (`game.demo(1)` after a `game.level.reset()` if
  your painted map.dat is loaded): does the full choreography read as
  deliberate showmanship in the locked feel?
- RESOLVED (2026-06-12): the stock level stays procedural — no
  committed map.dat until in-editor sprite/background design tools
  (M8 era) and the rest of the editor features are fleshed out. The
  human's painted map.dat stays local.
- RESOLVED (2026-06-12): the finale's boost — found the robust setup
  (flop-cancel within boost_win of the slide start); both the kit
  check and the tour now show a real boost.
