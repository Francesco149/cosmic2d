# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-10
**Milestone**: M2 — UI core + console: **DONE** (`nix run .#test` green,
4 goldens). Next: M3 — sandbox platformer v0.

## What works right now

Everything from M0/M1 (boot, live sessions, hot reload, parachute, PAL
draw/state/input/trace stack, determinism kit, goldens), plus the M2 stack:

- **PAL API v3** (additive): `pal.log_lines` (C-owned 256-line ring —
  survives VM reboots, so boot errors reach the console), `pal.text_input`
  + `{type="text"}` utf-8 events (IME commits split at glyph boundaries),
  `pal.frame_stats` (last-present quads/segs/vbytes + live texture/buffer
  counts). Table in ARCHITECTURE.
- **pt.ui** (D021): immediate-mode core — id-path widget state (survives
  reload, never snapshot), one-frame capture latency event filtering
  (up-events always pass), hot/active/focus, clip-stack scroll regions
  with wheel + thumb drag, virtualized lists, weighted rows, collapsing
  headings, label/button/checkbox/slider/drag-number/text-input (utf-8
  editing), `canvas` + `hit` escape hatches, style table. Iron rule:
  pt.ui never touches buffers/doc/PRNG.
- **pt.console**: grave-toggled drop-down (eased slide) over the running
  game — log scrollback from the pal ring with color coding, substring
  filter, REPL input with history, stick-to-bottom, PageUp/Down. Mouse
  below the console still reaches the game (tune knobs live). ` and F3
  engine-reserved until M4.
- **pt.repl + EVAL records** (D022): console commands drain at the start
  of the next sim frame and are recorded as EVAL chunks; verify re-executes
  them — knob-tweaking sessions replay byte-exact. Env sugar (`doc`,
  `game`) with _G shielded from bare assignments. `print` joins the log.
- **Error containment** (D023): game require/init/step/draw guarded in
  live sessions; errors pause the sim, stop recording (trace valid up to
  last good frame), auto-open the console with a banner; REPL drains
  immediately while paused. Resume on any successful reload; entry-load
  failures retry until the file parses. `--frames`/`--verify` stay
  fail-fast. Verified live both ways (mid-run error + boot syntax error).
- **pt.perf**: F3 overlay — 180-tick frame graph vs 16.7 ms budget line,
  sim/draw split, frame_stats, buffer/texture/Lua-heap numbers.
- **projects/uigallery**: living pt.ui reference shaped like the M4
  inspector (searchable virtualized selectable list + property sections).
  The PLAN risk-gate review ("could Godot's inspector be built on this?")
  passed — gaps are additive widgets, recorded in D021.
- **Tests**: selftest now 22142 checks (+ui interaction via synthetic
  events, +repl exec semantics, +console toggle/error logic); golden
  suite grew tests/traces/evalfix.ptrace (EVAL records end-to-end,
  tamper-tested). ALL GREEN.

## Verified

- Agent-verified this session: full suite, containment soak tests
  (error→pause→edit→resume; boot-fail→retry→resume), console/perf/gallery
  screenshots inspected + pushed to llm-feed (console over particles,
  perf overlay, gallery).
- Human-verified: M1 windowed feel — **"feels good"** (2026-06-10). Human
  notes a Windows-native build will feel even smoother → that's M7,
  roadmap unchanged. M2 windowed feel (typing in the console, history,
  filter, error flow, F3) not yet human-tested.

## Next step (M3 — sandbox platformer v0; see PLAN.md)

1. Tilemap: render from a named buffer (bulk quad path) + AABB collide.
2. Character controller: run/jump/variable height/one-way platforms
   (MapleStory vocabulary; feel knobs in the doc tree from day one).
3. Props with grab/throw (no rotation yet), camera follow with knobs.
4. Particles v0 + parallax reuse from sandbox; squash & stretch hooks.
5. First real game-feel build — montage + windowed human check; knobs
   tunable live through the new console.

## Known small items / debts

- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Freed-buffer husks + texture re-create leaks on VM reboot persist by
  design (inspector cleans up in M4).
- Trace recorder buffers in memory; M5 ring-trace replaces it (D019).
- Sim-visible text input records (a game asking the player to type) still
  deferred per D018 note — console needed none of it (EVAL records cover
  the dev path); revisit when a game wants it.
- Console scrollback timestamps colored with their line (dim-timestamp
  polish possible); console line wrap = none (long lines clip; filter
  finds them).
- repl env caveat (D022): pre-recording env assignments don't travel.

## Open questions for the human

- None blocking. When convenient: windowed run — open the console with `,
  type a few commands (try `doc.knobs.gravity = 400`), arrow-key history,
  filter box, break the sandbox on purpose (edit main.lua to a typo while
  it runs) and watch it pause + resume on fix; F3 for the perf graph.
