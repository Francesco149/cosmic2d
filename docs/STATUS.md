# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-10
**Milestone**: M1 — draw + state + determinism: **DONE** (`nix run .#test`
green). Next: M2 — UI core + console.

## What works right now

Everything from M0 (boot, windowed + headless live sessions, crash
parachute, hot reload), plus the full M1 stack:

- **PAL API v2** (additive): `pal.draw_quads` bulk path (12 f32/quad,
  frozen layout), `pal.png_read`, `pal.hash` (fnv1a-64),
  `pal.buf_delta1`/`buf_apply_delta1` (frozen XOR-run codec, versioned
  kernel), `pal.quit(code)`/`pal.quitting`/`pal.exit_on_error`, buf views
  grew i8/i16. API table in ARCHITECTURE.
- **Module system**: boot.lua = thin shim; `pt.require` retains chunk
  sources (= D012 bundles via `pt.modules()`), hot-reloads in place with
  table identity preserved, watches everything for the parachute.
  `pt.restore_bundle`/`pt.adopt_disk` run snapshot code vs disk code.
- **State model**: `pt.state` — doc tree + canonical binary serializer
  (D016), PSNP snapshots (code bundle + all named buffers + doc), restore
  verified incl. PRNG stream position and buffer create/free/resize.
  `pt.sim` buffer: frame counter + xoshiro state (layout frozen).
- **Determinism kit**: `pt.rand` (xoshiro256++, bit-identical to reference
  C, state in pt.sim), `pt.math` (fdlibm-style sin/cos/tan/atan/atan2/
  asin/acos/exp2, ~1-2 ulp, pure IEEE ops), `pt.ease` (31 name-addressable
  curves, D020 — names are sim-state safe, functions are not).
- **Input**: `pt.input` action map; frozen 10-byte per-frame records;
  pressed/released edges live in the `pt.input` buffer (snapshot-correct);
  sticky taps; quit interceptable via `game.on_quit` (M0 debt cleared).
- **Text/gfx**: baked spleen 5x8 + 8x16 atlases (committed, BSD-2),
  `pt.text.draw/measure`, `pt.gfx` camera/parallax layers + PNG textures
  + sprites.
- **Traces (D014)**: `--record` writes PTRC (snapshot + per-frame input
  records & state deltas + keyframes + code epochs on mid-record reload);
  `--verify` is the golden runner — re-sims inputs, byte-compares every
  frame, reports first divergent frame/buffer/bytes, exit 0/1. Verified:
  divergence localization works (corrupted input record pinpointed to the
  byte), epochs replay, bundle code beats disk code (old goldens stay
  green after sim changes — observed in production this session).
- **Tests**: `nix run .#test` = packaged console (packages.pettan) running
  selftest (22k checks: PRNG KATs, trig/exp2 accuracy sweeps, serializer/
  snapshot/input/ease invariants, pixel-exact glyph render) + byte-exact
  replay of 3 committed goldens (sandbox pre-ease, sandbox_ease, churn
  fixture covering buffer create/free/resize + doc churn). ALL GREEN.
- **Sandbox demo**: 1024-particle playground — PRNG + pt.math + eased
  speed/fade knobs in the doc tree + input actions (arrows/wasd push,
  space/click bursts, esc quits) + parallax starfield + HUD. ~1.1ms/frame
  sim cost at ~280 live particles (lavapipe). Montage + font preview on
  llm-feed.

## Verified

- Agent-verified this session: everything above (selftest, golden suite,
  live reload/parachute/epoch sessions, visual inspection of demo/fonts).
- Human-verified: M0 windowed smoothness ("on point"). M1 windowed feel
  (input actions, bursts) NOT yet human-tested — needs a windowed run.

## Next step (M2 — UI core + console; see PLAN.md)

1. Panel/widget core (stacks, scroll, collapse, search, text input) —
   review API against "could Godot's inspector be built on this?" before
   building further (PLAN risk list).
2. Log console + Lua REPL panel (pal.log ring buffer already exists C-side;
   needs a `pal.log_tail` getter or engine-side ring).
3. Error overlay routed through the console (replace magenta screen);
   Lua errors should never kill the session once the console exists.
4. Perf panel: frame graph + draw stats (needs pal.* counters — additive).
5. Text input events (additive input record type per D018 revisit note).

## Known small items / debts

- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Freed-buffer husks leak by design; texture re-creates leak on VM reboot
  (live-reload-leaks pillar; inspector cleans up in M4).
- Trace recorder buffers in memory, writes at stop — fine for short
  recordings; M5 ring-trace replaces it (D019 revisit note).
- Recording survives quit paths but not crashes (M5 ring-trace fixes).
- `pt.require` bundle restore leaves modules loaded by newer code present
  (unreferenced) — harmless, revisit if it ever confuses the inspector.

## Open questions for the human

- None blocking. When convenient: run `bin/pettan projects/sandbox`
  windowed and judge the feel (push the emitter, spam space bursts, click
  around; the speed/fade curves are doc knobs — edit projects/sandbox/
  main.lua's knob defaults live to taste).
