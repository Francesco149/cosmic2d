# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-12
**Milestone**: M5 — time machine: **code-complete, every PLAN bullet
done and agent-verified**; human taste check on the scrubber panel
pending (screenshot on the feed). The ring IS the recorder (D032):
every live session keeps the last 30 s scrubbable, F4 opens the time
machine, rewind/export/replay all ride the same segment ring, and the
suite now runs under `nix flake check` with pixel goldens.
**Next: M6 — audio** (FM synth core in PAL, patches/sequencing in Lua,
sfx in the sandbox, PCM-hash audio goldens).

## What works right now

Everything from M0–M4 (boot, live sessions, hot reload, parachute, PAL
draw/state/input/trace stack, determinism kit, goldens, pt.ui/console/
repl/perf, error containment, pt.tilemap, the platformer sandbox, the
editor + inspector + prop palette, the LOCKED stock feel D029/D030,
tour v2) plus M5:

- **The segment ring (D032, pt.trace)**: always-on in live sessions —
  segments of kf=60 frames (keyframe captured from the delta mirrors +
  a bundle ref + the same EVAL/FRAM/EPOC bytes PTRC v1 always had),
  whole-segment eviction past `pt.trace.ring.seconds` (default 30,
  console-tunable, never in traces). Bounded: 31 segs / ~1 MB after
  2400 sandbox frames. `--record` is now a PIN over the ring;
  record_stop writes byte-identical files to the old linear recorder
  (validated chunk-by-chunk against a pre-change worktree recording of
  the same session — only SNAP.CODE differed, engine sources changed).
  Out-of-band restores auto-reset the ring via the pt.sim counter
  discontinuity watch. Ring session state lives on the module table
  (survives trace.lua self-reload, dies with the VM by design).
- **The time machine (pt.scrub, F4)**: sim freezes, a bottom panel
  scrubs the ring — timeline slider, |< −60 < play > +60 >| transport,
  arrow-key steps, the frame's held actions decoded from its input
  record. The playhead state is written straight into the live
  buffers/doc (state.restore_tables; no game code runs — game.draw
  renders the past, the F1 inspector reads it). `close` returns to the
  present, timeline intact; `rewind here` truncates the future
  (trace.rewind restores the bundle as of that frame if it differs,
  pt.main.after_restore re-runs init and clears an error pause — the
  debugging loop is crash → F4 → scrub back → watch it coming);
  `save .ptrace` exports the ring to the project dir (gitignored).
- **Replay playback**: `pt.scrub.open_replay("file.ptrace")` loads a
  trace INTO the ring (trace.ring_load: SNAP → state+code restore,
  KEYF → segment boundaries, EPOCs folded into per-segment bundles)
  and auto-plays it state-per-frame, no re-sim — committed goldens
  replay through their own bundled code epochs. "play from here" /
  "finish" adopt the trace's timeline at the playhead/end; live play
  then records onward from inside the replay. The load is deferred to
  the chrome phase so the triggering console eval can't poison the
  timeline (in a verify re-sim it's a recorded no-op).
- **Suite under `nix flake check`** (checks.goldens) sharing the same
  script as `nix run .#test`: selftest (22308 checks) + 17 trace
  goldens + **3 pixel goldens** on pinned lavapipe
  (tests/pixels/<name>.png + .args sidecar, one argv token per line,
  byte-compared: sandbox attract f120, tour mid-flight f600,
  uigallery chrome f30).

## Verified

- Agent-verified (this session): suite ALL GREEN both via `nix run
  .#test` and `nix flake check`. Old-vs-new recorder byte-identity
  (573 chunks, same session, worktree A/B). Headless scripted flows:
  open/scrub/close resumes the present seamlessly; rewind truncates
  and the sim continues on the rewound timeline; export at f300 →
  replay in a fresh session → seek → adopt at f150 → ring records
  onward; kitcheck golden (older code epoch) replays via its bundle.
  t_ring selftests pin eviction, state_at (bufs/counter/doc/input),
  export chunk order, rewind+resume, discontinuity reset, EPOC
  pass-through, pin SNAP == live snapshot bytes.
- Human-verified: M4 feel locks (D029/D030/D031) carry over; nothing
  new since the 2026-06-12 prop-palette check.

## Next step (M6 — audio)

1. Read PLAN M6 + DECISIONS for prior audio notes; design the PAL FM
   synth core (voices × 4-op, envelopes, feedback, a few algorithms)
   — PAL API addition, so: ADR + API table update + `pal.x_` prefix
   per the stability contract.
2. Patches/sequencing in Lua (synth state is sim state; commands
   timestamped in the sample domain from the frame counter), sandbox
   sfx (jump/land/throw), PCM-hash audio goldens.

## Known small items / debts

- Calling `pt.trace.rewind()` (or `pt.scrub.rewind_here()`) from the
  console mid-play records that eval into the very timeline it
  rewrites — exported traces re-execute it on verify. Use F4; only
  `open_replay` is deferred-safe. (Panel-only guard if it ever bites.)
- Scrubbing previews the past with CURRENT draw code; only rewind
  restores the frame's bundle. Visual-only quirk after mid-ring
  reloads.
- Adopting a replay (or any snapshot restore) enters bundle mode: disk
  hot reload stays paused until `pt.adopt_disk()` (existing D012
  semantics, now reachable via the scrubber).
- Pinned recordings (`--record`) exempt segments from eviction — long
  recordings grow memory like the old recorder did (D032 revisit:
  pal.x_append_file streaming).
- Inspector drags echo one eval per changed frame; strings read-only;
  no add/delete; no sliders (range metadata via attach, D027).
- Dragging a sim-rewritten buffer cell "fights" (live-edit semantics).
- Demo choreography assumes the procedural map + LOCKED stock knobs
  (D025); reset + stock for the real tour.
- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Texture re-create leaks on VM reboot persist by design; buffer husks
  have the inspector free button.
- repl env caveat (D022): pre-recording env assignments don't travel.
- props separation can squeeze a crate into a wall in pathological
  piles; belly slide keeps the standing hitbox.

## Open questions for the human

- **Time machine on the feed** (2026-06-12): panel screenshot pushed —
  layout/readability ok? Best checked live: play a bit, F4, drag the
  timeline, rewind mid-jump. Does the freeze→scrub→resume loop feel
  right?
- Carried over (2026-06-12): the inertial-scroll rubber-band montage
  and the tour-finale re-cut montage are still on the feed awaiting a
  taste check; `game.demo(1)` after `game.level.reset()` for the full
  tour v2 read.
