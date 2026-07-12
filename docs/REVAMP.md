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
  any frame can be **browsed as if you were in the editor** infinite canvas.
  Browsing is **interactive but ephemeral** (§7b): move windows, open assets
  as they were at that moment — all of it discarded the instant you scrub to
  another frame; the history itself is immutable.
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
   **DESIGNED (2026-07-12, ADR D049 + docs/IMGUI.md)**: vendored 1.92.4,
   one C++ host TU behind extern "C", Lua gets a native-res drawlist +
   hard widgets at explicit rects + capture flags — never imgui
   windows/layout/styling. PAL API v7.
2. **Script engine** (R1, decision gate): Lua 5.4 (current) vs **QuickJS**
   (appealing: friendlier to the masses, still small; bellard's upstream
   recently landed a major perf uplift, so a fork is probably unnecessary).
   Must prove: **performance** on representative workloads and
   **determinism** (bit-exact record→verify story — integer semantics, hash /
   iteration order, NaN handling) before anything is migrated. The editor
   rewrite is written in whatever wins — this gate goes FIRST so we never
   write the editor twice.
   **RESOLVED (2026-07-12, ADR D047 + D048): stay on Lua 5.4.** Retested
   on upstream 2026-06-04 (the human's catch — D047 had tested the older
   nixpkgs pin): general workloads are now near parity (sim tick 1.34×,
   UI ~1.05×, per-call quads even; typed arrays even beat Lua's bulk
   path), but 64-bit integer work stays 6.5–8× slower (cm.rand under the
   sim), the embed is 3.5× bigger, and the determinism audit's semantic
   hazards are language spec, not speed: 53-bit ceiling, 32-bit bitwise,
   trunc-signed div/mod, no int/float subtype for cm.state.canon.
   Bit-exactness in QuickJS was *proven achievable* — the blockers are
   the integer story + a whole-engine rewrite for no net gain. Harness
   kept re-runnable: `tools/r1_scriptbench/`.
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
   **DESIGNED (2026-07-12, ADR D050 + docs/EDITOR.md)**: three layers keyed
   by asset path (disk file / working state in the captured editor doc /
   CJRN full-snapshot journal); dirty computed, never tracked; the R3
   state model is R6-capturable by construction (`cm.ed.doc` + the
   reserved `ed.*` buffer domain).
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
  (procart moves here) and `../cosmic2d-game` (projects/cosmic + GAME/STORY/
  maps docs move here); this repo goes engine-only with the **minimal smoke
  project** (a cut-down cosmic demo: one room, a couple of platforms, the
  movement code) which becomes the golden/selftest carrier — trace/pixel
  goldens re-cut on it here, once (§7 Q3). The old sandbox testbed retires to
  the backup branch. *Exit*: engine repo builds + selftest + goldens green on
  the smoke project; game repo boots the cosmic greybox against the sibling
  engine; demos repo boots procart; old tree reachable via the backup branch.
- **R1 — script-engine spike (decision gate)** ✅ **DONE (D047/D048: stay
  on Lua 5.4)**: QuickJS vs Lua 5.4 bench on
  representative workloads (sim tick, quad-batch prep, UI immediate-mode
  churn) + determinism audit (record→verify bit-exactness, integer semantics,
  iteration order, GC timing independence) + embedding-size/hot-reload story.
  *Exit*: an ADR — migrate (with a port plan) or stay on Lua; numbers in the
  doc, not vibes.
- **R2 — platform layer revamp** ✅ **DONE (2026-07-12, D049 +
  docs/IMGUI.md)**: imgui hosted in the binary + the
  script-side surface for it; the new window model (maximized editor window /
  960×540 game window / fullscreen upscale); C/C++ helper layer formalized;
  PAL API break blessed (version bump, contract table rewritten). *Exit*:
  a script-driven imgui hello-canvas at display refresh; game window model
  works windowed + fullscreen; selftest green on the new contract.
  *(Hit: `projects/igcanvas` — pan/zoom canvas, crisp text at any zoom,
  edit widget, live game as a canvas image; PAL api 6→7 additive (no
  golden regenerated); selftest 22545 + traces + pixels ALL GREEN;
  windows cross build clean.)*
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
  animation possibly its own window) · **live playable game** window. The
  old studio's full-window mode (F2) **dies here** — no coexistence (§7 Q4).
  *Exit*: a real session — open the game, edit a script in code ed, tweak a
  sprite, drag an asset in from the OS — without leaving the canvas; the F2
  studio is gone.
- **R5 — project picker + launcher**: teidraw-style picker as the front
  door; the thin same-name launcher exe (editor/console disabled); shipped
  game openable through the editor. *Exit*: zip a game, double-click the exe
  on win11, it plays; open the same zip in the editor and poke around.
- **R6 — rewind**: the disk-streamed ~1 GB delta history; frame browse of
  everything including the editor (interactive-but-ephemeral, §7b); resume
  from any frame; game/editor mode switch while rewinding; asset bring-back;
  the pill + top-bar UI. Design doc first (extends D014/M5). *Exit*: scrub an
  hour-long session, watch gameplay back, pull yesterday's sprite out of the
  past; poke a rewound frame and confirm the poking evaporates on scrub.
- **R7 — game graybox revamp** (in cosmic2d-game; **after the editor phase**
  per the human — the smoke project is the testbed until then): movement kit
  carried over, checkerboard/rect placeholders, core-loop graybox iterated to
  "the rects have personality" (human taste pass). Art fills in as we go.

## 7. Open questions — RESOLVED (human, 2026-07-12; ADR D046)

1. **Sequencing after R0**: **engine-first.** The minimal smoke project is
   the testbed through the editor-rewrite phase (R1–R4); the game graybox
   (R7) comes after — the current greybox is a placeholder anyway.
2. **The smoke project**: the engine keeps a **minimal smoke = a cut-down
   version of the cosmic demo** — just a room with a couple of platforms
   plus the movement code. (The old sandbox moveset-testbed doesn't move
   anywhere; it's reachable via the `pre-revamp` branch.)
3. **Goldens through the revamp**: selftest stays green throughout; the
   trace/pixel goldens are re-cut **once, at R0, on the smoke project**
   (moving the golden-bearing projects out forces it at the split, not R2 —
   a deliberate re-cut, not a regenerated failure).
4. **The old studio's full-window mode**: **dies** when the sprite-ed window
   lands at R4 — no parity coexistence period.

## 7b. Rewind gate — browsing semantics (human, 2026-07-12; ADR D046)

How do we handle poking around a rewound frame? **Interactive but
ephemeral**: while parked on a frame you can poke around — move windows,
open assets *as they were at that point in time* — but every such change is
**discarded the moment you scrub to another frame**. No reconciliation ever
happens (assets deleted since, windows closed since, etc. are non-problems
because nothing you do while parked outlives the frame). The only doors out
of the past are explicit: **bring back an asset** (§2 rewind) and **resume
from this frame**. This replaces the earlier blanket "everything read-only"
phrasing: the *history* is immutable, the *viewing* is interactive.

## 8. Risks / watch list (revamp-specific)

- **imgui as a second UI philosophy** — contain it to complex widgets inside
  windows; the canvas grammar stays ours. Review the R2 surface against
  "could teidraw's feel be built on this?".
- ~~**QuickJS determinism**~~ — RESOLVED at R1 (D047/D048): determinism
  was proven achievable; general perf reached near-parity on upstream
  2026-06-04 but 64-bit integer work stays 6.5–8× slower and the integer
  semantic hazards are spec-level. Staying on Lua; the risk is closed
  (revisit triggers in D048).
- **Editor state entering the determinism domain** (rewind) — the exact
  opposite of D040's "no determinism tax" studio. The R3 state model must be
  designed with R6's capture in mind or R6 becomes a rewrite.
- **Revamp scope** — the counter is the R-series gates: each milestone is
  independently shippable, and the game graybox (R7) doesn't wait for the
  editor.
