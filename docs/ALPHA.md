# cosmic2d — alpha release program

> **Active roadmap as of 2026-07-15.** `STATUS.md` says exactly where work
> stopped; this file says what remains and in what order. `REVAMP.md` and the
> M-series in `PLAN.md` are historical design context, not active queues.

## 1. Alpha promise

The distributed engine is one ready-to-use folder: extract it, launch the
editor, choose a bundled demo or create a project, and make and export a small
2D game without assembling a toolchain. Authoring uses the infinite-canvas,
intent-driven grammar consistently across code, art, maps, audio, debugging,
and project operations.

An exported game remains an inspectable cosmic2d project and includes the
engine and authoring tools. Its normal named-launcher path boots directly into
play mode with the editor disabled (the existing D052 lock), but a curious
player can deliberately open the included editor and poke around. “Play-only”
below describes the default launch experience, not removal of tooling or
source assets.

Alpha means the supported paths are trustworthy, documented, and complete.
It does not mean every possible 2D subsystem is built. Unsupported paths must
be named honestly rather than implied by "batteries included."

The release supports Windows and Linux desktop. macOS, mobile, web, consoles,
3D, networking, and a second rendering backend are outside this alpha.

## 2. Game-family coverage

We optimize shared primitives for several families instead of growing a
genre-specific monolith. The alpha must make these games pleasant to author:

| Family | Bundled proof | Load-bearing needs |
|---|---|---|
| Side-view platformer/action | current two-room demo | slopes/one-ways, kinematic mover, follow camera, animation, particles/feedback |
| Top-down action/adventure | new mini-demo | 4/8-way and analog movement, solid/trigger collision, depth ordering, rooms/portals, interactions |
| Arcade shooter / arena game | new mini-demo | many lightweight actors, projectiles, overlap queries, waves/timers, shake/flash, score/restart |
| Puzzle / board / tactics | documented recipe; promote to a demo only if shared APIs leave it awkward | mouse/touch-like pointing, grids, tweening, turn/state flow, UI, save/undo |

The three bundled playable demos stay deliberately small and readable. They
are templates and regression fixtures, not showcase games. Internal projects
(`selftest`, `smoke`, `igcanvas`, `uigallery`) do not appear in release builds.

### Shared batteries required by those families

- Keyboard, mouse, and hot-plugged gamepads through one rebindable action map;
  digital actions plus deterministic 1D/2D axes and deadzones.
- Collision/query ergonomics for swept bodies, solids, one-ways, triggers,
  circles/AABBs, layers/masks, and overlap/raycast-style queries.
- A small actor/world pattern: stable IDs, spawn/despawn, iteration order,
  tags/groups, timers, and a documented snapshot story. Prefer a composable
  module and examples over imposing a full ECS.
- Cameras: follow, bounds, coordinate conversion, pixel snap, shake, and
  simple transitions. Rendering helpers cover layers/depth sorting and
  parallax without forcing a scene graph.
- Animation events, reusable effects/particles, easing/tweens, hit pause,
  flashes, and basic screen feedback.
- Runtime UI recipes/components for HUDs, menus, focus/navigation, dialogue,
  and pause/options. Editor UI and game UI may share primitives without
  sharing visual policy.
- Atomic player storage with named profiles/slots, versioning/migrations, and
  a platform-correct writable location.
- Project metadata, icons, credits/licenses, build configuration, and an
  in-editor export path.

## 3. Release gates

### A0 — roadmap and documentation reset

Goal: a new session or contributor can identify current truth in minutes.

- [x] Create this alpha roadmap and make it the active pointer.
- [x] Compress `STATUS.md` to a short current handoff; move completed session
  history to `docs/history/STATUS-2026-07.md` without losing it.
- [x] Add a docs index with `active`, `contract`, and `historical` labels.
- [x] Audit every repo and in-engine link; remove references to moved or dead
  projects and superseded UI.
- [x] Rewrite the in-engine scripting guide into a real public API/task guide.
- [x] Reconcile claims such as "self-contained," "undo forever," and current
  alpha status with actual behavior.

Exit: `STATUS.md` + this file are sufficient orientation; all shipped help
links resolve; historical docs cannot be mistaken for active work.

### A1 — durability and storage trust

Goal: power loss, disk-full, or a damaged cache cannot silently destroy work.

- [x] Add an atomic write primitive (same-directory temp, flush/close, rename)
  and use it for project metadata, assets, editor sessions, journals, options,
  recents, traces, and player saves.
- [x] Make multi-output assets transactional (`.spr` source plus baked
  `.png`/`.anim`/`.meta`); report every failure in the editor.
- [x] Keep and recover from last-known-good session/journal metadata.
- [x] Define `.ed` cache ownership, compatibility/version behavior, and safe
  clear/rebuild operations.
- [x] Add disk-full/interrupted/corrupt-file tests at the persistence seams.

Exit: injected failures never replace a valid file with a partial file; the UI
explains recovery; source and baked assets cannot claim a false successful save.

### A2 — real distributions and clean first run

Goal: artifacts work on clean supported machines exactly as advertised.

- [x] Split dev/test, editor, and default-play manifests. Release picker
  contains only bundled demos and user projects; exported games still carry
  the engine/editor and editable project, with the named launcher locked to
  play mode by default.
- [x] Produce a portable Linux artifact (AppImage or bundled-libs/RPATH
  tarball) that has no Nix-store runtime dependency.
- [x] Ship Windows GUI-subsystem launchers; retain a separate console/headless
  executable for diagnostics and CI.
- [ ] Add icons, version resources, a documented crash-log/report location and
  stable project/history-stream/frame envelope for A7, licenses/notices, and
  artifact checksums. Decide signing expectations for an unsigned alpha.
- [ ] Test extract-and-run in clean Windows and Linux VMs/containers, including
  paths with spaces/non-ASCII and read-only install locations.
- [ ] Make the play-only bundle player-facing: project title/icon/version,
  controls, credits, and licenses rather than the engine authoring README.

Exit: both clean-machine smoke tests pass from a downloaded archive with no
developer toolchain; the first picker shows only intentional content.

### A3 — project lifecycle and in-editor export

Goal: project work never requires filesystem or Nix knowledge for normal use.

- [ ] Picker: create, import/open folder, refresh, sort/search, keyboard nav,
  thumbnails, missing-project repair, and large-list scrolling.
- [ ] Project actions: settings, rename/move, duplicate, archive/delete with
  confirmation, reveal in file manager, and return to picker.
- [ ] Project settings edit name, author, version, description, resolution,
  window defaults, icon, controls/credits files, and export configuration.
- [ ] Add Build/Export to the launcher/project surface with target, output
  location, progress, validation, and actionable failures.
- [ ] Export arbitrary opened projects, not only names captured in the Nix
  source tree.
- [ ] Offer Blank, Platformer, Top-down, and Arcade starter templates. Random
  three-word names remain the instant default but are editable immediately.

Exit: from a fresh archive, a user can create/import, rename, edit, play, and
export a project without a terminal.

### A4 — input, settings, and player storage

Goal: exported desktop games meet basic player expectations.

- [ ] Design input record v2/additive chunks for gamepad buttons and quantized
  axes without invalidating v1 traces; document the determinism decision.
- [ ] SDL gamepad discovery/hot-plug, standard buttons/axes, deadzones, device
  assignment, and keyboard fallback.
- [ ] Rebind UI/API with multiple bindings per action and conflict handling;
  starter templates display the actual current bindings.
- [ ] Options: master/music/SFX volume, bindings, fullscreen/window sizes that
  fit the current display, and extensibility for project-specific settings.
- [ ] Add namespaced atomic player storage outside the install/project folder:
  profiles/slots, schema version, migration, reset, and error reporting.
- [ ] Prove input recording, rewind, resume, replay, and cross-platform verify
  with keyboard, mouse, and gamepad records.

Exit: controller and keyboard can complete every bundled demo; rebindings and
save data survive restart; deterministic traces cover all supported inputs.

### A5 — genre-neutral runtime ergonomics

Goal: the mini-demos are concise because shared engine APIs carry routine work.

Implement only after writing each demo naively enough to expose its real pain.

- [ ] Define the actor/world, query/collision, camera, layer/depth, transition,
  tween/effect, and runtime-UI slices listed in §2.
- [ ] Keep deterministic state in doc/named buffers; specify stable iteration,
  lifetime, reload, snapshot, and rewind behavior for every new module.
- [ ] Add focused selftests and at least one trace for each sim-touching slice.
- [ ] Provide task-based examples and defaults; advanced users can stay close
  to primitives and opt out.
- [ ] Audit performance with representative actor/projectile counts and set
  honest supported envelopes for alpha.

Exit: each bundled demo's game-specific code mostly expresses its rules, not
camera math, lifetime bookkeeping, input plumbing, or storage boilerplate.

### A6 — bundled demo and starter matrix

Goal: opening the archive immediately demonstrates breadth and teaches by copy.

- [ ] Polish the current platformer into the canonical side-view mini-demo.
- [ ] Build a one/two-room top-down action mini-demo: analog movement,
  interaction/trigger, depth sort, room transition, one persistent pickup.
- [ ] Build a one-screen arcade mini-demo: waves, pooled/lightweight actors,
  projectiles/overlaps, juice, score/high score, instant restart.
- [ ] Give every demo a short `README`/welcome note: controls, concepts, file
  tour, modification prompts, and matching starter-template provenance.
- [ ] Add picker thumbnails and metadata; keep assets small and project-local.
- [ ] Add headless state/pixel/audio smoke coverage without turning demos into
  brittle exhaustive goldens.
- [ ] Write a puzzle/board recipe and use it as a gap audit; add a fourth demo
  only if it reveals a materially different shared capability.

Exit: platformer, top-down, and arcade demos are playable with keyboard and
gamepad, editable end to end, export cleanly, and are readable starter sources.

### A7 — rewind/replay product UI

Goal: turn the existing mechanics into a flagship debugging and recording tool.

- [x] Replace the hover slider with a persistent full-width timeline tray:
  default to the ten minutes ending at live, wheel-zoom at cursor,
  middle-drag pan, frame-level near zoom, and full-history far zoom.
- [ ] Capture/display roughly one presented-frame thumbnail per minute and a
  log-scaled max-per-pixel state-activity envelope, split into sim, editor, and
  project-file/asset deltas so one-frame significant events survive zoom-out.
- [ ] Show current/live/retention markers plus input transitions, code epochs,
  asset saves/imports, restarts/session boundaries, errors, and crashes without
  requiring state reconstruction to draw the timeline.
- [ ] Visible disk budget/use, retention controls, pause/clear, and recovery
  behavior across state, thumbnails, audio, and deduplicated project blobs;
  long sessions remain bounded and understandable.
- [x] Implement the exact live-history scrub grammar: click seeks; left-drag
  selects an inclusive A/B range and loops it; Esc clears the loop/clip mode;
  Esc again closes rewind immediately. Active clips cannot disappear through
  hover timeout, F4, or outside clicks.
- [ ] Extend that dismissal guard to export progress and dropped-replay modes
  when those modes exist.
- [ ] Give live history, replay files, and crash-focused views immutable
  timeline sources. Dragging a replay into any editor view opens/fits/loops it;
  dismissing it restores the untouched live ring and present rather than
  adopting the replay's future.
- [ ] Generalize the history store and additive `.ctrace` packaging around the
  same segment + content-addressed project-blob model. A new clip is standalone:
  exact A state through inclusive B, editor state, code, **all project source
  and assets**, file epochs, events, previews, metadata, and captured audio when
  available. Legacy traces remain readable and clearly dependency-bound.
- [ ] Export a selected clip atomically to a timestamped file in `replays/`
  beside `engine/`, then reveal/select it in Explorer/the platform file manager;
  offer an actionable writable-location path when the engine root is read-only.
- [ ] Make structured crash reports locate an exact history stream/frame. A
  drop opens and loops up to one minute before the crash, preferring an embedded
  tail and otherwise resolving local retained history; evicted/missing tails
  explain the failed identity instead of guessing by time.
- [ ] Export recording-friendly image/video/frame/audio paths only after the
  replay artifact is stable; avoid embedding a full video editor.

Exit: a user can spot a high-activity moment in ten minutes of history, seek or
A/B-loop it, export it, drag the standalone replay into a fresh editor and poke
around its bundled project, dismiss back to the untouched live session, and
reach the preceding minute from a crash report while understanding storage use.

### A8 — documentation, accessibility, and release candidate

Goal: validate the whole promise, not isolated subsystems.

- [ ] In-engine Getting Started completes create → modify code/art/map/audio →
  play/debug/rewind → export, using only shipped UI.
- [ ] Searchable public API/task reference covers every supported module,
  project schema, determinism rules, common failures, and compatibility policy.
- [ ] Accessibility pass: scalable legible UI, keyboard-reachable core flows,
  visible focus, non-color-only states, reduced flash/shake options, and
  controller navigation where player-facing.
- [ ] Fresh-user usability pass on both platforms; record time-to-first-change
  and every point where external knowledge was required.
- [ ] Clean-machine artifact matrix, upgrade/open-old-project tests, corrupt
  state recovery, long-session soak, performance budgets, and full goldens.
- [ ] Freeze an alpha version, changelog, known limitations, issue template,
  and reproducible release checklist.

Exit: every alpha promise in §1 has direct evidence and no P0/P1 release issue
is open. The README changes from alpha candidate to alpha only here.

## 4. Ordering and session-sized execution

Default order is **A0 → A1 → A2 → A3 → A4 → A5/A6 together → A7 → A8**.
Durability precedes broader authoring; distribution precedes polishing a false
first run; mini-demos drive shared API design instead of arriving afterward.
Independent documentation and clean-machine probes may run earlier.

Each working session takes one bounded packet, normally one vertical behavior
with its tests and docs—not an entire gate. Examples:

1. Atomic-write primitive + failure KATs.
2. Migrate editor session and recents to atomic writes + recovery UX.
3. Migrate one multi-output asset family transactionally.
4. Release manifest + clean picker fixture.
5. Portable Linux artifact + clean-container smoke script.
6. Project settings model + one editable settings window.
7. Input-record design/ADR + PAL gamepad event spike.
8. Top-down naive prototype + written ergonomics findings.

### Session hygiene contract

At session start:

1. Read the first screen of `STATUS.md`, then the relevant gate here.
2. Read `git log --oneline -10` and confirm a clean/understood worktree.
3. State one packet and its exit test; do not silently expand to the next gate.

During the session:

- Commit coherent units; keep new decisions in `DECISIONS.md`.
- Update the gate checkboxes only for proven outcomes.
- Run focused tests during work and the full suite when a shared/runtime seam
  changes. Inspect visual outputs before asking for a taste check.

At session end:

- Replace the compact current section at the top of `STATUS.md`: what changed,
  proof, exact next packet, and any human-only verification. Do not append a
  full diary there; archive detailed histories under `docs/history/`.
- Ensure code, tests, docs, and status agree and are committed.
- Stop at the packet boundary and suggest `/clear`; the next session must be
  able to resume from the repo alone.

## 5. Alpha backlog outside the gates

These are intentionally not alpha promises unless a mini-demo proves them
necessary: localization tooling, custom font authoring, navigation/pathfinding,
advanced physics/rigid bodies, visual scripting, networking, mobile/touch,
web export, mod/package management, and additional renderer backends. Record a
revisit trigger instead of smuggling one into an active packet.
