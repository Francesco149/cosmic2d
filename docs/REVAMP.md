# cosmic2d — the revamp (the UX reboot)

> **Source of truth**: the human's teidraw board `cosmic2d`
> (`/mnt/f/Documents/teidraw/cosmic2d` — see CLAUDE.md "Diagrams" for how to
> export it). This doc distills that board into a plan; when in doubt,
> re-export the board — the human edits it as thinking evolves. Roadmap
> milestones are **R0…R7** (the M-series is paused; game-driven M11+ work
> resumes in the game repo after the revamp core lands). Binding ADR: D045.

## 1. What the revamp is

A big multi-session reboot of the engine's UX around a now well-defined idea:
**the editor becomes a teidraw** — an infinite canvas in a resizable maximized
window, with the tools as **floating windows on the canvas** (code editors,
asset picker, sprite editor, and the **live playable game** itself as a
window). Same heuristics-for-intent philosophy as teidraw. The engine stays
the two-layer deterministic machine it is; the shell around it is rebuilt.

What stays (proven, keep):

- **Two layers + determinism iron rules** (ARCHITECTURE.md): small platform
  binary + hot-reloadable script engine; fixed timestep, engine PRNG, named
  buffers / doc tree, trace record→verify. The revamp *deepens* this (rewind).
- **The numpy model** — perf-critical work migrates down into portable
  C/C++ helpers operating on shared buffers (the board keeps this explicitly:
  "portable C/C++ helpers • performance heavy lifting" feeding a
  "platform layer • os/cpu specific stuff • as small as possible").
- **The movement feel** (M7, feel-approved) — carried into the game graybox
  verbatim.
- **Pure asset/tool modules** — cm.paint / cm.sprite / cm.anim (and the
  procart generators) are shell-independent and get re-hosted, not rewritten.

What is replaced or rebooted:

- The **editor shell** (cm.editor's docked chrome + the studio's dedicated
  full-window mode) → one infinite-canvas editor with floating windows.
- The **repo layout** → three repos (engine / demos / game), §4.
- The **game prototype** → graybox with true placeholder assets, §5.
- Possibly the **scripting language** → QuickJS spike, §3 R1.
- **Breaking API changes are explicitly okay** (the human's call, on the
  board). The old engine survives as a backup branch, not as compatibility.

## 2. The target UX (distilled from the board)

### Project picker
- teidraw-style picker (the board grid teidraw shows on Ctrl+O) as the
  engine's front door.
- **Shipped game = thin launcher exe**: `cosmic.exe` beside the project
  launches the project with the same name as itself, editor/console disabled.
  A shipped game can still be opened through the editor for people who want
  to poke around.

### Game window
- Standalone (launcher) run: default **half-1080p (960×540) window**;
  **fullscreen = upscale**. (This simplifies the M8 resize-ladder world —
  design pass needed on what survives of cm.view.)

### Editor
- **Resizable, maximized window; infinite canvas with floating windows;
  written in the scripting language.**
- **Very long undo history for every editable asset.** Changes not explicitly
  saved with Ctrl+S **persist across sessions** but don't take effect, and
  clearly indicate unsaved; a button resets unsaved changes.
- **Subset of teidraw UX, same heuristics-for-intent philosophy**:
  - main action = interacting with the window's content; **movement and
    selection live behind ALT**; no draggable title bars.
  - A-click = select group; A-click again on an element = select the element
    and move it within the group; A-drag = move element (prioritize the
    selected one if overlapping); A-rightclick = close window.
  - bring-to-front hotkeys mirroring teidraw; dragging edges resizes.
- **imgui is pulled in** to avoid maintaining complex UI machinery (code
  editor text rendering, wrapping, etc.). PAL grows a C++ dependency —
  the "portable C/C++ helpers" box already blesses C++.

### The windows (on the canvas)
- **code ed** — basic intuitive micro-style controls; **1 file per window, no
  tabs**; simple syntax highlighting, **no autocomplete**; line numbers +
  clearly signal unsaved. **Documentation is a special code format** with
  clickable links and fwd/back navigation; Ctrl+click a link → opens in a new
  code-editor window. Intent-driven UX where appropriate.
- **asset pick** — a file manager with previews: big previews + a size
  slider; **drag from here onto a window = replace the file that window is
  handling**; **drag a file from the OS onto it = add to project** (code,
  sound, image only for now — mostly ref images and sound samples);
  double-click = open the appropriate window; **filter by type + fuzzy
  search, no folders**.
- **sprite ed** — mainly tailored for pixel art; revise the studio UX where
  appropriate (maybe split animation into a separate window); **read-only by
  default with an obvious toggle to make it editable**.
- **live playable game** — the game runs as a window on the canvas.

### Rewind (the flagship engine feature)
- Always **~1 GB of engine state history cached (adjustable), streamed from
  disk**.
- **Replay the whole engine state _including the editor_ frame by frame**;
  any frame can be **browsed as if you were in the editor** infinite canvas —
  everything **read-only**.
- **Bring back an asset from the past** (overwrites if it still exists,
  re-adds if missing).
- **Switch between game and editor mode while rewinding** (e.g. to record /
  watch gameplay footage specifically).
- UI: a small **pill in the top right**; hovering shows the rewind UI (a
  full-width bar at the top) with a timeout, like teidraw's video pill.

## 3. Architecture deltas (each gets a design doc / ADR before build)

1. **imgui in the binary** (R2): PAL (or a layer beside it) hosts Dear ImGui
   and exposes a scripting-side surface for the hard widgets (text editing /
   wrapping / clipping); the canvas + window chrome + heuristics stay
   script-side. Decide the split carefully — imgui must not become a second
   UI philosophy leaking everywhere. Note teidraw itself is imgui ≥1.92 with
   the dynamic font atlas (crisp text at any zoom) — that's the prior art,
   and `../teidraw` is reference source we can crib from.
2. **Script engine** (R1, decision gate): Lua 5.4 (current) vs **QuickJS**
   (appealing: friendlier to the masses, still small; bellard's upstream
   recently landed a major perf uplift, so a fork is probably unnecessary).
   Must prove: **performance** on representative workloads and
   **determinism** (bit-exact record→verify story — integer semantics, hash /
   iteration order, NaN handling) before anything is migrated. The editor
   rewrite is written in whatever wins — this gate goes FIRST so we never
   write the editor twice.
3. **Rewind / state history** (R6, but the state-model constraints bind from
   R2 on): extends the M5 trace machinery from "last N seconds in RAM" to a
   **disk-streamed ~1 GB delta history**. Browsing a frame = read-only
   reconstruction from deltas (no re-sim), which is how the *editor* can be
   replayed too: **editor state (window layout, open docs, unsaved buffers)
   must live in named/snapshottable state**, unlike the old studio (D040
   exempted it). Asset bring-back = the history also captures asset-file
   epochs. This is the deepest determinism-model change of the revamp —
   full design doc before build.
4. **Undo-forever + unsaved-persists** (R3): every editable asset carries a
   very long cross-session undo journal (teidraw's `undo.jsonl` is the shape)
   and an unsaved working state distinct from the saved file.
5. **Window/viewport model** (R2): editor = maximized resizable canvas at UI
   scale; game = a canvas window (editor) or a real window (launcher,
   960×540 default, fullscreen upscales). Re-derive what's left of
   cm.view's ladder/FOV rules in this world.

## 4. Repo split (R0)

- **`cosmic2d` (this repo) = engine only** — PAL + engine modules + engine
  docs + selftest/goldens.
- **`../cosmic2d-demos`** — experiments/demos (procart and future demo
  cartridges live here).
- **`../cosmic2d-game`** — the cosmic game (game code + GAME/STORY/maps docs
  + art). The graybox revamp (§5) happens here.
- **Old demos/assets: archive for now**, revisit/adapt later if needed.
  **Copy the current branch to a local backup** (branch `pre-revamp` +
  keep-forever) so old engine stuff is retrievable. Breaking API changes are
  fine from then on.
- Open detail: how the split repos consume the engine (sibling-path checkout
  is the simplest and matches the board's `../` naming; decide in R0).

## 5. The game prototype revamp (cosmic2d-game)

- **Keep the movement feel we have right now** (the feel-approved M7 kit).
- **Assets become actual placeholders**: soft checkerboards, the player is a
  rect.
- **Graybox the core gameplay loop and make it feel good** — to the point
  the rects almost feel like they have personality.
- **The human fills in art as we go** (procart + sprite ed feed this later;
  no art gate on the graybox).

## 6. Roadmap

Same rules as PLAN.md: exit criteria are the definition of done; each
milestone ends with STATUS updated, committed, visuals on llm-feed. Order may
flex except: **R0 first** (everything else lands in the right repo) and
**R1 before R3** (don't write the editor twice).

- **R0 — the split**: `pre-revamp` backup branch; create `../cosmic2d-demos`
  (procart + sandbox-as-demo move here) and `../cosmic2d-game` (projects/
  cosmic + GAME/STORY/maps docs move here); this repo goes engine-only with a
  minimal smoke project for selftest/goldens. *Exit*: engine repo builds +
  selftest green; game repo boots the cosmic greybox against the sibling
  engine; demos repo boots procart; old tree reachable via the backup branch.
- **R1 — script-engine spike (decision gate)**: QuickJS vs Lua 5.4 bench on
  representative workloads (sim tick, quad-batch prep, UI immediate-mode
  churn) + determinism audit (record→verify bit-exactness, integer semantics,
  iteration order, GC timing independence) + embedding-size/hot-reload story.
  *Exit*: an ADR — migrate (with a port plan) or stay on Lua; numbers in the
  doc, not vibes.
- **R2 — platform layer revamp**: imgui hosted in the binary + the
  script-side surface for it; the new window model (maximized editor window /
  960×540 game window / fullscreen upscale); C/C++ helper layer formalized;
  PAL API break blessed (version bump, contract table rewritten). *Exit*:
  a script-driven imgui hello-canvas at display refresh; game window model
  works windowed + fullscreen; selftest green on the new contract.
- **R3 — editor shell**: the infinite canvas + floating-window system in the
  scripting language — pan/zoom, window chrome, the ALT interaction grammar
  (A-click/A-drag/A-rightclick, drill-down select, bring-to-front, edge
  resize), unsaved-persists + undo-forever journals. Design doc first
  (EDITOR.md — the D036/STUDIO.md successor). *Exit*: canvas with dummy
  windows feels teidraw-smooth (human taste pass); undo/unsaved survives a
  restart.
- **R4 — the windows**: **code ed** (imgui text stack: micro-style controls,
  highlighting, line numbers, unsaved signal; the docs format + link
  navigation) · **asset pick** (previews, size slider, drag-in/drag-out
  semantics, fuzzy search) · **sprite ed** (re-host cm.paint/cm.sprite/
  cm.anim tools in a floating window; read-only default + edit toggle;
  animation possibly its own window) · **live playable game** window.
  *Exit*: a real session — open the game, edit a script in code ed, tweak a
  sprite, drag an asset in from the OS — without leaving the canvas.
- **R5 — project picker + launcher**: teidraw-style picker as the front
  door; the thin same-name launcher exe (editor/console disabled); shipped
  game openable through the editor. *Exit*: zip a game, double-click the exe
  on win11, it plays; open the same zip in the editor and poke around.
- **R6 — rewind**: the disk-streamed ~1 GB delta history; frame browse of
  everything including the editor (read-only); resume from any frame;
  game/editor mode switch while rewinding; asset bring-back; the pill +
  top-bar UI. Design doc first (extends D014/M5). *Exit*: scrub an hour-long
  session, watch gameplay back, pull yesterday's sprite out of the past.
- **R7 — game graybox revamp** (in cosmic2d-game; can start any time after
  R0, interleaved): movement kit carried over, checkerboard/rect
  placeholders, core-loop graybox iterated to "the rects have personality"
  (human taste pass). Art fills in as we go.

## 7. Open questions (for the human, none blocking R0)

1. **Sequencing after R0**: engine-first as ordered above, or interleave R7
   (game graybox) early for a morale/feel anchor while the editor is rebuilt?
2. **Sandbox project**: demo (cosmic2d-demos) or the engine-repo smoke
   project? (R0 proposes: moveset testbed → game repo territory; a minimal
   new smoke cartridge stays in-engine for selftest/goldens.)
3. **Goldens through the revamp**: keep selftest green throughout (proposed:
   yes, always); pixel/trace goldens re-cut at R2 when the PAL contract
   breaks (proposed: re-cut once, on the new smoke project).
4. **The old studio's full-window mode**: kill immediately at R4 when the
   sprite-ed window lands, or keep both until the window reaches parity?

## 8. Risks / watch list (revamp-specific)

- **imgui as a second UI philosophy** — contain it to complex widgets inside
  windows; the canvas grammar stays ours. Review the R2 surface against
  "could teidraw's feel be built on this?".
- **QuickJS determinism** — JS numbers are doubles (no integer subtype like
  Lua 5.4); bit-exact sim + record→verify must be *proven* in R1, not
  assumed. A failed spike is a cheap, good outcome: stay on Lua.
- **Editor state entering the determinism domain** (rewind) — the exact
  opposite of D040's "no determinism tax" studio. The R3 state model must be
  designed with R6's capture in mind or R6 becomes a rewrite.
- **Revamp scope** — the counter is the R-series gates: each milestone is
  independently shippable, and the game graybox (R7) doesn't wait for the
  editor.
