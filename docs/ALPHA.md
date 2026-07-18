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
- [x] Complete artifact identity, diagnostics, and release metadata:
  - [x] Add a canonical application icon and embed multi-resolution icon plus
    version resources in every Windows executable.
  - [x] Define a documented crash-log/report location and stable project/
    history-stream/frame envelope for A7.
  - [x] Carry licenses/notices and checksums in the artifacts; document the
    signing expectations for an unsigned alpha.
- [x] Test extract-and-run in clean Windows and Linux VMs/containers, including
  paths with spaces/non-ASCII and read-only install locations.
- [x] Make the play-only bundle player-facing: project title/icon/version,
  controls, credits, and licenses rather than the engine authoring README.

Exit: both clean-machine smoke tests pass from a downloaded archive with no
developer toolchain; the first picker shows only intentional content.

### A3 — project lifecycle and in-editor export

Goal: project work never requires filesystem or Nix knowledge for normal use.

**Complete (D071–D081).** Boot, picker, packaging, and the
editor share one declarative `cm.project` codec plus release byte validator.
The picker opens arbitrary folders in place, refreshes and atomically
maintains recents, repairs/removes stale roots, reveals ready recent folders,
collision-safely renames/moves them on one filesystem after the active editor
has released ownership, duplicates them through a staged, cancellable copy
published by one no-replace rename that omits machine/editor state, archives
them as dated no-replace backups that re-import through open folder, and
deletes them behind a typed (or archive-armed) confirmation that keeps the
recent tile as the recovery handle until the tree is gone. It is reachable
through an explicit recovery-safe editor action.
The project window edits identity, window defaults, and release files, then its
**Build/Export** tab streams the saved external project with the matching
carried Linux/Windows runtime. Target/output choice, progress, cancellation,
checksums, explicit atomic replacement, and actionable preflight errors require
neither a terminal nor a Nix source-tree project. The picker grid now scrolls
past any window, filters by search, sorts by recency or name, shows declared
project icons, and is fully drivable without a mouse — the modal button rows
included. "+ New project" opens a starter chooser: an instantly editable
random three-word name plus blank/platformer/top-down/arcade templates
scaffolded from stock sources through the same atomic rollback contract.

- [x] Picker: create, import/open folder, refresh, sort/search, keyboard nav,
  thumbnails, missing-project repair, and large-list scrolling.
- [x] Project actions: settings, same-filesystem rename/move, reveal in the
  file manager, and recovery-safe return to picker.
- [x] Project actions: duplicate from a ready tile (staged cancellable copy,
  progress, no-replace publication, machine/editor state omitted).
- [x] Project actions: archive/delete with confirmation (dated no-replace
  backup; typed or archive-armed confirm, tile-anchored, always finishable).
- [x] Project settings edit name, author, version, description, resolution,
  window defaults, icon, controls/credits files, and export configuration.
- [x] Add Build/Export to the launcher/project surface with target, output
  location, progress, validation, and actionable failures.
- [x] Export arbitrary opened projects, not only names captured in the Nix
  source tree.
- [x] Offer Blank, Platformer, Top-down, and Arcade starter templates. Random
  three-word names remain the instant default but are editable immediately.

Exit: from a fresh archive, a user can create/import, rename, edit, play, and
export a project without a terminal.

### A4 — input, settings, and player storage

Goal: exported desktop games meet basic player expectations.

- [x] Design input record v2/additive chunks for gamepad buttons and quantized
  axes without invalidating v1 traces; document the determinism decision.
  (D082: tagged extensions after the frozen 10 v1 bytes; live-side
  deadzone/quantization; `cm.input.pad` buffer; hot-plug is live-only.)
- [x] SDL gamepad discovery/hot-plug, standard buttons/axes, deadzones, device
  assignment, and keyboard fallback. (D083: PAL API 18 owns device lifetime;
  first-connected-lowest-slot policy, `pad_sync` at boot, and the editor
  focus rules live in Lua; virtual pads + `projects/padtest` are the
  headless proof vehicle; templates read pad 1 beside their key maps.)
- [x] Rebind UI/API with multiple bindings per action and conflict handling;
  starter templates display the actual current bindings. (D084: key/pad/axis
  bindings feed the frozen v1 action bits live-side; the Esc menu's controls
  page captures/steals/resets; overrides persist per machine in the
  project's `input.dat`; HUDs read `input.label`.)
- [x] Options: master/music/SFX volume, bindings, fullscreen/window sizes that
  fit the current display, and extensibility for project-specific settings.
  (D085: volumes are device-output gains — goldens never hear them; window
  sizes derive from `x_display_size`; stick knobs ride input.dat, volumes +
  `cm.options.add` project settings ride video.dat via contributor hooks.)
- [x] Add namespaced atomic player storage outside the install/project folder:
  profiles/slots, schema version, migration, reset, and error reporting.
  (D086: `cm.save` under `<user root>/saves/<save_id>/`; save_id declared in
  project.lua, scaffolded + settings-editable; reads feed the sim only via
  idempotent init or the recorded eval-channel load door, so replays never
  need a machine's saves.)
- [x] Prove input recording, rewind, resume, replay, and cross-platform verify
  with keyboard, mouse, and gamepad records. (D087: `projects/inputproof` +
  the committed 258-frame `inputproof_a4exit` ring export — all three
  domains, both save doors, and a scrub rewind/resume seam in one recorded
  session, byte-exact on Linux and native Windows.)

Exit: controller and keyboard can complete every bundled demo; rebindings and
save data survive restart; deterministic traces cover all supported inputs.
**A4 exit walked and closed (D087):** route bots completed the demo by
keyboard and by virtual SDL controller (identical frame 2688, Linux AND
native Windows) over the demo's new real pad bindings; a rebind override and
a written save both survived real restarts; kitcheck + padtest + inputproof
cover every supported input domain.

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

- [x] Polish the current platformer into the canonical side-view mini-demo.
  (The A5 retrofits made it the showpiece — cm.camera/D092, parallax/D093,
  cm.hud/D096 — with real pad bindings since D087; README at D099.)
- [x] Build a one/two-room top-down action mini-demo: analog movement,
  interaction/trigger, depth sort, room transition, one persistent pickup.
  (D088: `projects/cellar`, retrofitted onto box/depth/hud/move at A5.)
- [x] Build a one-screen arcade mini-demo: waves, pooled/lightweight actors,
  projectiles/overlaps, juice, score/high score, instant restart.
  (D089: `projects/swarm`, retrofitted onto actor/tween/move at A5.)
- [x] Give every demo a short `README`/welcome note: controls, concepts, file
  tour, modification prompts, and matching starter-template provenance.
  (D099: all three demos.)
- [x] Add picker thumbnails and metadata; keep assets small and project-local.
  (D099: gameplay-cut 128px icons + author/version/description + the full
  player-packaging file set for cellar and swarm.)
- [x] Add headless state/pixel/audio smoke coverage without turning demos into
  brittle exhaustive goldens. (Committed traces carry deep state coverage —
  cellar_clear, swarm_runs, demo_camtour — plus one boot-frame pixel golden
  per promoted demo at D099; the demos' sim mixes ride the trace hashes, so
  no separate audio golden.)
- [x] Write a puzzle/board recipe and use it as a gap audit; add a fourth demo
  only if it reveals a materially different shared capability. (D099: the
  shipped guide's recipe, built verbatim against shipped modules — nothing
  missing, no fourth demo.)

Exit: platformer, top-down, and arcade demos are playable with keyboard and
gamepad, editable end to end, export cleanly, and are readable starter sources.
**A6 exit walked and closed (D099):** all three ship in the public archives
(clean-machine matrices re-proven on Debian 13 and native Windows), export
cleanly as full player archives on both hosts, and are completed by committed
traces under keyboard and virtual-pad input.

### A7 — rewind/replay product UI

Goal: turn the existing mechanics into a flagship debugging and recording tool.

- [x] Replace the hover slider with a persistent full-width timeline tray:
  default to the ten minutes ending at live, wheel-zoom at cursor,
  middle-drag pan, frame-level near zoom, and full-history far zoom.
- [x] Capture/display roughly one presented-frame thumbnail per minute and a
  log-scaled max-per-pixel state-activity envelope, split into sim, editor, and
  project-file/asset deltas so one-frame significant events survive zoom-out.
  The activity envelope (sim/editor/files) is built and persisted per segment
  (D100) so it draws the whole retained window including adopted cross-session
  history; the presented-frame thumbnails (`THMB`, D101) fill the PREVIEWS lane
  from a live game-FOV sample, one per segment, decimated at wide zoom. Adopted
  cross-session previews (the durable `THMB` blob scan) ride the packaging packet.
- [~] Show current/live/retention markers plus input transitions, code epochs,
  asset saves/imports, restarts/session boundaries, errors, and crashes without
  requiring state reconstruction to draw the timeline. Current/live/retention
  markers, input transitions, code epochs, asset saves, restarts, session
  boundaries, and contained errors draw from the persisted digest (D100); a
  dropped crash report draws its own failed-frame boundary wall (D106). Asset
  *imports* remain the last marker awaiting a packet.
- [x] Visible disk budget/use, retention controls, pause/clear, and recovery
  behavior across state, thumbnails, audio, and deduplicated project blobs;
  long sessions remain bounded and understandable. (D102: the tray head is a
  control — a live disk-use meter, a persisted disk-budget knob, pause-recorder,
  and a two-click clear that drops state + previews and resumes cleanly.
  Dedup-blob and captured-audio *recovery* ride the §14 packaging packet, named
  honestly rather than claimed.)
- [x] Implement the exact live-history scrub grammar: click seeks; left-drag
  selects an inclusive A/B range and loops it; Esc clears the loop/clip mode;
  Esc again closes rewind immediately. Active clips cannot disappear through
  hover timeout, F4, or outside clicks.
- [x] Clock replay/A-B transport to wall time: default 1× replays the recorded
  60 Hz moment in real time, 2×/4×/8× are explicit, and a late renderer drops
  intermediate presentation frames instead of slowing the transport clock.
- [ ] Extend that dismissal guard to export progress and dropped-replay modes
  when those modes exist. Export progress is guarded now; dropped replay awaits
  its mode.
- [~] Give live history, replay files, and crash-focused views immutable
  timeline sources. Dragging a replay into any editor view opens/fits/loops it;
  dismissing it restores the untouched live ring and present rather than
  adopting the replay's future. (D105: the **replay-file** drag-in ships — a
  dropped `.ctrace` opens a non-destructive editor clip, mounts its bundled
  project as the editor root under the parked write wall, and Esc/eject restores
  the untouched live ring + present + real root without adopting. D106 adds the
  **crash-focus** entry point and D107 the **trust prompt**: an untrusted
  dragged-in clip parks an UNTRUSTED REPLAY confirm at the tray — nothing runs
  until the user says so; a same-session self-export never prompts. Live history
  already stashes/restores via park; first-class source *objects* remain a
  refactor cut.)
- [~] Generalize the history store and additive `.ctrace` packaging around the
  same segment + content-addressed project-blob model. A new clip is standalone:
  exact A state through inclusive B, editor state, code, **all project source
  and assets**, file epochs, events, previews, metadata, and captured audio when
  available. Legacy traces remain readable and clearly dependency-bound.
  D103 landed the store foundation: a content-addressed project-blob store
  (`.ed/history/blobs`) and a per-segment project manifest (the complete tree at
  each keyframe, deduplicated), persisted through spill and recovered on
  adoption — so any retained range, **including an adopted cross-session one, is
  now materialization-ready**. D104 landed the clip: `write_trace`'s standalone
  mode embeds `MFST` (the tree at A) + one `BLOB` per referenced file version +
  `LOOP` (the A/B bounds) — additive, so a plain export stays byte-identical;
  `M.export_clip` is the live-range door; `ring_load` materializes the tree into
  an isolated ephemeral replay workspace and `M.materialize_clip` previews it
  without touching the ring. D108 closed **adopted-range** standalone export:
  `reconstruct_bundle` rebuilds the SNAP code from the segment's captured manifest
  (project `.lua` at its frozen source) + the host engine `cm.*`, so `export_clip`
  no longer refuses a cross-session range — only legacy pre-manifest / spill-off
  history does. Remaining under this item: **captured-audio embedding**.
- [~] Export a selected clip atomically to a timestamped file in `replays/`
  beside `engine/`, then reveal/select it in Explorer/the platform file manager;
  offer an actionable writable-location path when the engine root is read-only.
  D104: the tray's "export replay" button writes `<project>-clip-<A>-<B>.ctrace`
  (free-suffixed) atomically to `replays/` beside `engine/` and reveals the
  folder; a read-only engine root falls back to `<user_path>replays/`, named in
  the flash. Deferred: a wall-clock name (needs a PAL date door) and
  select-the-exact-file reveal (needs `explorer /select,` and has no portable
  Linux twin) — the folder reveal is §15's stated fallback.
- [x] Make structured crash reports locate an exact history stream/frame. A
  drop opens and loops up to one minute before the crash, preferring an embedded
  tail and otherwise resolving local retained history; evicted/missing tails
  explain the failed identity instead of guessing by time. (D106: dropping a
  `.ccrash` routes in `filter_events` beside `.ctrace`; `trace.crash_resolve`
  matches the report's stream+frame against the live/adopted ring by identity and
  returns the pre-roll bounds; `rewind.drop_crash` parks the live source in place,
  loops the safe pre-roll, and draws the failed-frame boundary — export-the-pre-roll
  and resume-here stay live. D109: the report now **embeds its one-minute tail** as
  a self-contained clip, preferred on drop and opened through the D107 trust-gated
  clip door, so a report from another machine / after local eviction still carries
  its timeline. Remaining refinement: cross-process native-failure next-launch
  synthesis — a PAL crash has no live process to embed a tail.)
- [ ] Export recording-friendly image/video/frame/audio paths only after the
  replay artifact is stable; avoid embedding a full video editor.

Exit: a user can spot a high-activity moment in ten minutes of history, seek or
A/B-loop it, export it, drag the standalone replay into a fresh editor and poke
around its bundled project, dismiss back to the untouched live session, and
reach the preceding minute from a crash report while understanding storage use.

### A8 — documentation, accessibility, and release candidate

Goal: validate the whole promise, not isolated subsystems.

- [x] In-engine Getting Started completes create → modify code/art/map/audio →
  play/debug/rewind → export, using only shipped UI. (D127: getting-started.md
  is the guided "Your first game" path, every step executed by a scripted UI
  tape against a fresh scaffold through to a published player archive; the
  tape also found and fixed the chooser Enter leak, dead right-button paint,
  and the missing new-text-file door.)
- [x] Searchable public API/task reference covers every supported module,
  project schema, determinism rules, common failures, and compatibility policy.
  (D110 substrate; D111–D113 reader; D119 the 3D modules; D120 per-module
  2D sections + the KAT-pinned every-module-findable sweep.)
- [~] Accessibility pass: scalable legible UI, keyboard-reachable core flows,
  visible focus, non-color-only states, reduced flash/shake options, and
  controller navigation where player-facing. (D128: the player-facing Esc
  menu drives keyboard-only AND pad-only — cm.ui nav cursor with a visible
  focus ring, pad back/select as the pad Esc; the picker was already
  keyboard-complete. D129: reduced flash/shake ship as user-wide Esc-menu
  toggles enforced at the engine's render-only effect doors
  (camera.offset / tween.wobble / tween.flash) with
  options.shake_scale/flash_scale for hand-rolled effects. Remaining:
  editor keyboard gaps (focus-cycle/close), non-color-only polish on the
  rewind meter + unsaved dot.)
- [x] Add independent machine-local sizing for canvas-window text/content and
  fixed chrome (including rewind), with 1080p-compatible defaults and automatic
  SDL-DPI/4K scaling. The broader keyboard/focus/player accessibility gate above
  remains open.
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
