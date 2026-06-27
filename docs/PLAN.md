# cosmic2d — plan

The distilled project vision and the milestone roadmap. This file replaces the
original SEED brainstorm; nothing from it was dropped, only organized.
`docs/STATUS.md` tracks where we currently are against this plan.

## What this is

A tiny 2D pixel-art engine / fantasy console. One self-contained folder is the
whole world: the engine, its editor and tools, the documentation, and the game
projects. You share a game by zipping the folder; the recipient can play it,
edit it, and build their own game with the same binary. MIT licensed, public.

The stock experience is a **live-editable platformer sandbox** (Garry's Mod
spirit): a MapleStory-style character controller in a blank-slate map with a
prop pit — spawn, grab, throw physics objects, paint the map, edit the game's
Lua code with hot reload, all while the game runs.

## Pillars (in priority order)

1. **Determinism is the foundation, not a feature.** Given any frame snapshot,
   the sim can resume or rewind to that exact moment, emulator style. This
   powers the rewind/time-scrub debugger, input-trace regression tests against
   state goldens, and pixel-golden tests for the platform layer. Every system
   that touches sim state is designed deterministic-first (see
   ARCHITECTURE.md "Determinism").
2. **Two layers, numpy model.** A deliberately small per-platform C binary
   ("PAL") provides powerful high-performance primitives (GPU quad batching,
   typed memory buffers, files, input, audio device, synth inner loop).
   Everything else — engine, physics, editor, tools — is Lua loaded from disk,
   editable and hot-reloadable without recompiling the binary. Engine upgrades
   should rarely touch the PAL. Perf-critical work migrates *down* into PAL
   kernels operating on shared typed buffers, like Python calling numpy.
3. **Batteries included.** Sprite/animation editor, map editor, FM synth +
   tracker, procedural sprite generator, debugger/inspector, docs browser —
   all inside the one editor binary. A user makes and ships a game without
   leaving it.
4. **Spectacle / game feel.** The sandbox must feel *extra* smooth and
   satisfying: rigid-body prop pit, flash-jump-through-the-pit moments,
   particles, parallax, squash & stretch, screen feedback. Every feel
   parameter is an exposed, live-tunable knob so the human can dial it in
   once the engine and UI are fleshed out.
5. **Editor UX that scales.** Introspection for everything: perf, entities,
   colliders, state, timeline. Flexible collapsible/scrollable/searchable
   panels like Godot/Unity. The UI core is designed carefully up front —
   cheaping out here causes immediate, severe UX debt.

## Product decisions (from seed, binding unless revisited in DECISIONS.md)

- **Aesthetic range**: both hi-res pixel art (Fortune Summoners / MapleStory)
  and chunky low-res. A project configures its internal resolution; the
  framebuffer is integer-upscaled to the window. Base art style until stock
  assets exist: 2x scale (e.g. 480x270 internal → 960x540 window).
- **LUT color grading**: sprites are authored neutral / low contrast; a LUT
  post pass tunes the whole game's look without re-editing sprites.
- **Procedural assets**: generator with noise layers, shapes, gradients,
  bevels, blend ops — mainly for environment/background sprites; characters
  stay hand-drawn.
- **Audio**: small FM synth (Cave Story spirit — simple, characterful, stock
  presets) for both sfx and music. Deterministic and snapshottable.
- **Modes**: `editor` mode (everything unlocked) vs `play` mode (map editing /
  spawning locked unless the game code enables it). Play mode is the default
  when a game is shared with end users; a project option sets the startup
  project + mode so a zip can boot straight into the game, with an opt-in
  door back into the editor.
- **Controls**: keyboard now, gamepad later. All input goes through a
  rebindable action map from day one — no code assumes "keyboard only".
- **Platforms**: Linux + Windows desktop now (dev box is NixOS on WSL2 and can
  run both Linux and Windows binaries). GL 1.x/2.x and a software renderer are
  later stretch goals — the engine-side renderer interface stays narrow so
  backends are swappable. First backend: Vulkan (via SDL_GPU).
- **Live-reload leaks are fine.** Rug-pulling systems live can orphan state;
  the entity inspector provides manual cleanup, and restarting the engine is
  always cheap. We do not contort the design for reload edge cases.
- **Assets**: placeholders now; the human designs stock assets in-engine once
  tools are good enough.
- **Docs in-engine** eventually (batteries included); repo docs are the
  source they'll be generated from.

## Milestones

Each milestone ends with: docs/STATUS.md updated, work committed, and where
visual, a screenshot/montage pushed to llm-feed. Exit criteria are the
definition of done. Order may flex; pillars don't.

- **M0 — boot** *(current)*: repo + flake + docs; PAL binary: SDL3 window,
  SDL_GPU clear + untextured quad batch, embedded Lua 5.4, C-owned loop with
  protected engine tick, headless mode, PNG screenshot, named persistent
  buffers, hot reload with error-state recovery. Sandbox project draws
  animated quads. *Exit*: `cosmic projects/sandbox` shows motion at 60 fps;
  edit main.lua → visual change without restart; broken code → error overlay
  → fix → recovers; headless screenshot pushed to llm-feed.
- **M1 — draw + state + determinism core**: textures + atlas basics, bulk
  quad path, camera/layers, scissor clip, baked bitmap font text, fixed 60 Hz
  sim step, input events → action map, doc-tree + typed-buffer state model,
  PRNG + deterministic math, snapshot/restore with code bundles (D012),
  trace recorder v1 (inputs + per-frame state deltas + keyframes + code
  epochs, D014), golden runner = re-sim vs recorded deltas with
  first-divergence report (`nix run .#test` green).
- **M2 — UI core + console**: panel/widget system (stacks, scroll, collapse,
  search, text input), log console + Lua REPL panel, error overlay routed
  through console, perf panel (frame graph, draw stats). Lua errors never
  kill the session.
- **M3 — sandbox platformer v0**: tilemap render+collide, AABB character
  controller (run, jump, variable height, one-way platforms), props with
  grab/throw (rotation later), camera follow with feel knobs, particles v0,
  parallax layers. First "game feel" build; montage to llm-feed.
- **M4 — editor mode v0**: editor/play mode switch, map painting, prop
  spawn palette, entity list + inspector (live edit), collider debug draw,
  knobs persisted per project.
- **M5 — time machine**: always-on ring trace of the last N seconds,
  timeline scrubber UI reading state straight from trace deltas (inspect any
  frame without re-sim), rewind & resume from any scrubbed frame, "save what
  just happened" trace export, replay playback of shared traces (showcases);
  golden trace suite wired into `nix flake check`; pixel goldens on pinned
  lavapipe.
- **M6 — audio**: FM synth core in PAL (voices × 4-op, envelopes, feedback,
  a few algorithms), patches/sequencing in Lua, sfx hooked into sandbox
  (jump/land/throw), PCM-hash audio goldens.
- **M7 — windows**: mingw cross build from the flake, SDL3.dll packaging,
  run .exe via WSL interop, state-golden parity vs linux.
- **M8 — procedural sprites**: noise/shape/gradient/bevel/blend primitives →
  texture bake API + generator panel; upgrade placeholder art.
- **M9 — LUT + look**: LUT post pass, stock LUTs, palette/LUT editor panel,
  parallax/feedback polish pass with the human dialing knobs.
- **M10 — self-contained shipping**: committed per-platform binaries, project
  zip flow, startup project/mode config, rebindable-controls UI, in-engine
  docs browser v0, sprite/animation editor v0.

Beyond M10: physics with rotation (box2d-lite-style solver), slopes/ladders
(Maple/Fortune Summoners movement vocabulary), tracker UI for music, gamepad,
GL/software backends, more editor tooling. Roadmap grows as we learn.

## Risks / watch list

- **PUC Lua perf ceiling** for physics/particles at scale → mitigation is the
  numpy model (PAL kernels over typed buffers); measure in the perf panel
  before migrating anything. Don't guess.
- **dzn (Vulkan-on-D3D12) quirks under WSLg** for live dev → lavapipe is the
  always-works fallback; the human can also run the Windows build natively.
  Goldens always run on pinned lavapipe regardless.
- **Editor UI scope creep** → UI core API is reviewed against "could Godot's
  inspector be built on this?" before M4 begins.
- **Determinism erosion** — every new sim-touching system must state its
  snapshot story in DECISIONS.md; golden suite is the enforcement.
