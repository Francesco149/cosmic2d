# cosmic2d — plan

The distilled project vision and the milestone roadmap. This file replaces the
original SEED brainstorm; nothing from it was dropped, only organized.
`docs/STATUS.md` tracks where we currently are against this plan.

> **2026-07-12 — THE REVAMP (D045)**: the M-series below is paused at its
> 2026-07 state. The active roadmap is **docs/REVAMP.md** (R0–R7): the
> teidraw-style infinite-canvas editor, the repo split (engine / demos /
> game), the script-engine gate, and the rewind feature. The pillars and
> product decisions below still bind; game-driven milestones (old M11–M15)
> resume in `../cosmic2d-game` after the revamp core lands, re-scoped as
> needed.

## What this is

A tiny 2D pixel-art engine / fantasy console. One self-contained folder is the
whole world: the engine, its editor and tools, the documentation, and the game
projects. You share a game by zipping the folder; the recipient can play it,
edit it, and build their own game with the same binary. MIT licensed, public.

The engine now has a flagship game it is **built around**: **cosmic** (see
`GAME.md`) — a cute/cozy, occasionally cosmic-dread action-exploration game
starring the `cosmic`-universe antagonist mecha girl (a spin-off / prequel).
MapleStory-style movement and self-contained maps + portals, power-fantasy
slice-through-hordes spectacle, and a Garry's-Mod-flavored physics sandbox; the
art targets a Wadanohara-like pixel style. The engine's batteries are proven by
dogfooding this game, and its feel/art requirements drive the roadmap below.

The game's cozy **hub** doubles as the live-editable **testbed** (the old M3/M4
"platformer sandbox", now with a purpose): a playground where we spawn/grab/
throw props, paint maps, and edit Lua with hot reload while it runs. The engine
stays general — you can still zip the folder and build your own game — but
cosmic is the thing we steer by.

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
M6 onward was **re-sequenced 2026-06-27** to build the cosmic game (GAME.md).
M0–M5 above are done. The human's calls: **Windows first** (so all feel-testing
happens natively on the win11 host), and the engine is steered by the game's
needs. Numbers shifted (old M6 audio → M9, old M7 windows → M6, etc.).

- **M6 — windows port** *(DONE 2026-06-27, commit `6b39cf6`; D038)*: cross-built
  via `nix build .#cosmic-windows` (pkgsCross.mingwW64 + nixpkgs cross SDL3 —
  pure Nix). The PAL being pure SDL3 meant near-zero source change (SDL_main +
  a self-locating `fixup_cwd`, which also closed the cwd=repo-root debt). Agent-
  verified on win11 via WSL interop: selftest 22308 PASS; **byte-exact
  cross-platform parity** (linux↔windows `--verify` both ways + byte-identical
  traces); Vulkan renders headless. *Pending*: human runs it windowed.
- **M7 — movement overhaul** *(next)* (the heart; D035, GAME.md §4): rip out the old
  controller; build the full MapleStory moveset (walk / jump / flash-jump /
  up-jump / hop / flutter / grapple / teleport / continuous-attack) as live
  knobs in the hub cartridge; calibrate CW/CH so 6 CW ≈ ⅓ screen; one-way
  platforms throughout; VFX stubs (sonic-boom ring, teleport trail). Re-cut
  the attract demo + goldens (D025) against the new moveset. Pure cartridge
  policy — no PAL change. *Exit*: the moveset feels right (human sign-off,
  native on win11), every knob live-tunable, deterministic, golden-pinned.
  *(M7/M8 may swap — movement is first as the identity-defining feel system,
  now feel-testable natively.)*
- **M8 — viewport & editor UX** (D036): variable-FOV internal target
  (≤480×270, integer-upscaled to a game-viewport rect), the window-resize
  ladder (aspect/FOV snapping, borderless-on-match), **editor-only UI scale**
  independent of game scale, a movable/resizable game viewport snapping to
  pixel-perfect multiples. The sim stays independent of FOV/window (goldens at
  a fixed FOV). Plus multi-file Lua conventions + project subdirs verified at
  scale (the loader already supports nested paths). *Exit*: a 1080p window with
  the game at 2× and editor chrome at 1× around it; the resize ladder snaps
  correctly; deep hot-reload across many project files.
- **M9 — audio** (was M6): FM synth core in PAL (voices × 4-op, envelopes,
  feedback, a few algorithms), patches/sequencing in Lua, sfx for jump/land/
  flash-jump/slice/teleport, music, PCM-hash audio goldens.
- **M10 — sprite & procedural art tools** (folds old M8 procgen + M9 LUT + the
  sprite editor; **pulled ahead of M9** 2026-06-28 — the editor unblocks all
  content authoring, so it comes before audio. Design bible: **STUDIO.md**; the
  binding ADR: **D040**): in-engine **sprite/animation editor** ("the studio",
  `cm.studio` — portraits + sprites + gradients, a dedicated full-window mode
  over native layered docs that bake to the strip atlas; assets are render-only,
  so the studio carries no determinism tax),
  **procedural sprite generator** (noise/shape/gradient/bevel/blend)
  for particles/liquids/dust + environment, **LUT post pass** + palette/LUT
  editor. Begin upgrading placeholders → real Wadanohara-style assets (human
  authors, agent integrates). *Exit*: the human authors a character sprite +
  portrait in-engine; particles/liquids/dust are procedural; the LUT dials each
  area's look. **Status (2026-06-28): the sprite/animation editor is DONE —
  Phases 1–4 (paint · layers/shapes/selection/transforms · gradients ·
  animation) shipped, and the exit *proof* is hit (the sandbox player draws a
  studio-authored, clip-animated sprite, `record→verify` byte-exact). Phase 5 in
  progress — **pivots + named slices DONE** (studio tools + a `.meta` sidecar +
  the game anchors the pivot; D041); LUT pass · headless `--bake` + the human
  authoring real assets remain. The **procedural sprite generator** expanded
  into the standalone **procart experiment** (2026-07-03, D044,
  **PROCART.md**): `projects/procart/` — procedural characters with a
  personality dial + terrain materials that tile cleanly and marry at borders;
  promote / mine / abandon on the human's taste pass.** See STATUS.md.
- **M11 — rotational physics & destruction**: a box2d-lite-style rigid-body
  solver — deterministic, born a versioned PAL kernel (`name@1`, contract rule
  4) — plus breakables, knock-over props, throw. *Exit*: throwing/knocking
  props feels great, deterministic, golden-pinned.
- **M12 — combat & enemies**: continuous-attack slicing, trash-enemy hordes
  (deterministic AI), juicy death anims + particle trails, hitstop/screen
  feedback; **HP + natural regen**; **currency/farmable drops** (engine PRNG);
  a boss-fight framework for the **~3–5 hand-crafted** bosses (cheese-able via
  potions, D037). *Exit*: carving a horde feels satisfying (human sign-off); a
  boss is a real fight; drops land.
- **M13 — world: portals, hubs, save, economy, navigation** (D037): portal map
  transitions, **two hubs** with **death→nearest-hub respawn, no rollback**,
  persistent autosaved progression (on the snapshot infra), the **world map +
  fast-travel** to visited maps, the **quest arrow**, the **optional economy**
  (shop; dual-sourced abilities incl. the secrets **radar** and extended
  flutter-range; cheese consumables), area-completion → prop-spawn unlock, and
  per-save **stats** (toward verifiable challenge runs). *Exit*: traverse
  hub↔areas by portal + world map; die and respawn without losing progress;
  buy/earn an ability; secrets + radar work.
- **M14 — sandbox tool (2D gmod)**: grab / float / move / rotate / throw + a
  small constraint set (weld / axle / rope), prop discovery → unlock, spawn in
  hub + completed areas. Builds on M11. *Exit*: the sandbox is fun in the hub
  (human sign-off).
- **M15 — shipping & content build-out** (was M10): committed per-platform
  binaries, project zip flow, startup project/mode config, rebindable-controls
  UI, in-engine docs browser v0 — and the **ongoing story/maps authoring** (the
  actual game), interleaved from here once hub + movement exist.

Sequencing: order may flex; **Windows → movement is fixed** per the human.
M9–M14 are ordered by dependency (audio + art tools enable spectacle; physics
precedes the sandbox; world precedes shipping) but interleave with content
authoring. Still later: slopes/ladders if wanted, tracker UI for music,
gamepad, GL/software backends. Roadmap grows as we learn.

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
  snapshot story in DECISIONS.md; golden suite is the enforcement. Two new
  fronts: the **variable FOV** (M8) must stay render-only (sim never reads
  window/FOV; goldens at a fixed FOV), and the **rotational physics solver**
  (M11) lands as a versioned kernel, golden-pinned, measured in perf first.
- **Movement feel is make-or-break** — the whole game is the moveset (M7).
  Mitigation: Windows-first so feel-testing is native, every value a live knob,
  and the trace scrubber for debugging arcs frame-by-frame. The human is the
  taste check.
- **Scope** — the full game (combat, world, save, sandbox, content) is a long
  road. Mitigation: ship the **hub + movement loop** first and prove it's fun
  before layering enemies/world/sandbox; content authoring is the interleaved
  long tail, not a milestone gate.
