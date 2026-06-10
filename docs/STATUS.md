# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-10
**Milestone**: M0 — boot: **DONE**. Next: M1 — draw + state + determinism.

## What works right now

- `nix develop -c make -C pal` → `bin/pettan` (SDL3 + SDL_GPU vulkan, embedded
  vendored Lua 5.4.7 with fixed string-hash seed).
- `bin/pettan projects/sandbox` — windowed demo (animated quads, 480x270 @2x),
  runs on dzn/RTX 5060 under WSLg. vsync paced.
- `--headless --frames N --shot out.png` — offscreen render + PNG; on
  lavapipe (`VK_DRIVER_FILES="$PETTAN_LVP_ICD"`) output is bit-identical
  across runs (verified; D007 holds).
- Hot reload: edit `projects/sandbox/main.lua` while running → engine reloads
  it, frame-counter state survives in the named buffer.
- Crash parachute: runtime error → traceback in log + magenta window, PAL
  reboots the Lua VM when a watched file changes; named buffers (C-owned)
  survive the reboot. Verified end-to-end.
- Interactive headless sessions (D013): `--headless` without `--frames` =
  paced 60 Hz live session with reload + parachute, no window. This is how
  the agent runs live tests from now on (verified; no desktop popups).
- llm-feed has the M0 milestone screenshot ("pettan2d M0: first light").

## Verified

- Agent-verified: rendering correctness (screenshot inspected), determinism,
  reload, parachute, recovery.
- Human-verified: windowed smoothness on dzn/RTX 5060 ("on point",
  2026-06-10).

## Next step (M1 — see PLAN.md for full scope)

1. Engine module system (reload-aware `pt.require` over `pal.read_file`)
   that **retains chunk sources** — snapshots embed a content-addressed code
   bundle per D012 (human call: state alone can't pin a trajectory when code
   is live-editable).
2. `pt.state`: doc tree + canonical serializer + snapshot save/load of all
   named buffers + code bundle; frame counter + PRNG (xoshiro) in a sim
   buffer.
3. `pt.math` deterministic trig; input action map over `pal.poll_events`.
4. Bulk quad path `pal.draw_quads(tex, f32buf, count)` + spleen font bake →
   text rendering (`PETTAN_SPLEEN_DIR` has the BDFs).
5. Trace recorder v1 (D014): inputs + per-frame state deltas (sparse XOR
   runs; `pal.buf_delta`/`pal.buf_apply_delta` C kernels) + keyframes + code
   epochs. Golden runner = re-sim inputs, byte-diff vs recorded deltas,
   report first divergent frame/bytes; wire `nix run .#test` (lavapipe env;
   nix-sandbox headless path may need the SDL offscreen fallback already in
   main.c).

## Known small items / debts

- `pal.quit()` semantics when game code intercepts "quit" events: engine
  currently quits unconditionally — revisit with the input map (M1).
- Windowed mode requires cwd = repo root (shader/engine paths are relative);
  fine for now, fix with SDL_GetBasePath at packaging (M10).
- buf views: freed named buffers leak a husk struct by design (live-reload
  leaks are acceptable, D-pillar); inspector cleanup lands with the editor.

## Open questions for the human

- none blocking. M1 starts next session.
