# the editor shell — the R3 design (D050)

> The REVAMP §3.4/§6 design doc for **R3 — editor shell**: the infinite
> canvas + floating-window system in Lua, the ALT interaction grammar, and
> the unsaved-persists + undo-forever model. The D036/STUDIO.md successor.
> Binding ADR: **D050**. Prior art: `../teidraw` (the interaction tuning is
> lifted from its source, constants and all) and the human's `cosmic2d`
> board (the ALT grammar is *its* spec — teidraw itself has no ALT layer,
> because there the canvas IS the main action; in our editor the main
> action is window content, so movement/selection hide behind ALT).
> `projects/igcanvas` is the proven sketchpad this grows out of.

## 1. What the editor shell is

One maximized window; an infinite canvas; the tools are floating windows
*on* the canvas — code editors, asset pickers, sprite editors, the live
game. R3 builds the shell: canvas + windows + grammar + persistence, with
a small roster of real-but-simple windows. R4 fills in the serious
citizens (code ed / asset pick / sprite ed / playable game).

Everything is Lua drawing on the `pal.x_ig_*` drawlist (D049): chrome,
grammar, hit-testing are ours; imgui contributes text rasterization and
the `x_ig_edit` hard widget, nothing else. The deterministic machine below
is untouched — the editor is a *shell around* the engine, and the sim
never reads a byte of it.

The one genuinely new idea R3 must get right (REVAMP §8): **editor state
is snapshottable by design** — the exact opposite of the D040 studio's
"no determinism tax" exemption — because R6 replays the whole engine
*including the editor*, frame by frame. That constraint shapes §2; get it
wrong and R6 is a rewrite.

## 2. The state model (the R6-critical piece)

R6 rewind is **state capture, not re-simulation**: browsing a frame is a
read-only reconstruction from per-frame deltas (ARCHITECTURE traces).
So editor code does NOT need to be deterministic (it may read the wall
clock, float through eases, react to native mouse px) — but everything a
rewound frame must be able to *show* must live in delta-able state.

### The captured/ephemeral line

- **Captured** = what a rewound frame must show: the camera, the window
  list (kind, rect, z, asset bindings), selection + drill, per-asset
  working state (unsaved text, journal cursor), per-window content state
  worth restoring (scroll offsets). All of it lives in **`cm.ed.doc`** —
  a plain-data doc tree, `cm.state.canon`-clean (integers/floats/strings/
  booleans, tree-shaped, no NaN), owned by `cm.ed`, separate from the sim
  doc. Captured state is a pure function of "what you see": an in-flight
  camera ease writes the camera into the doc every frame, so capture
  needs no knowledge of the animation.
- **Ephemeral** = how it was mid-gesture: drag anchors, hover, fade
  alphas, ease bookkeeping (t0/from/to), the marching of any dashed line.
  Module-local, never captured, dies with the frame. Rewind browsing is
  interactive-but-ephemeral anyway (D046 §7b) — nobody needs a rewound
  drag anchor.

### The second state domain

The sim state domain (cm.state: named buffers + sim doc) stays exactly
what it is; goldens and `--verify` never see the editor. The editor
domain is structurally parallel:

- **`cm.ed.doc`** — the editor doc tree (above). Serialized with the same
  canonical codec (`cm.state.canon`), so hashing/deltas/round-trip come
  free and R6 can XOR-delta it per frame exactly like the sim doc.
- **`ed.*` named buffers — reserved now, used later**: R4's sprite-ed
  will want bulk pixel working state in buffers. Buffer names with the
  `ed.` prefix belong to the editor domain: `cm.state.snapshot`/
  `restore_tables` and the trace recorder **exclude them** (a name-prefix
  filter; no current buffer uses the prefix, so every existing golden is
  byte-identical). A selftest KAT pins the exclusion from day one so R4
  can't accidentally leak editor bulk into a trace.
- The editor never writes sim state except through `cm.repl` (the D022
  EVAL path) like every other tool; the sim never reads `cm.ed.doc`.

### Persistence: the session file

`<project>/.ed/session.dat` = a `CEDS` chunk container wrapping the
ed-doc canon bytes (+ a version chunk). Saved on a **400 ms debounce**
after any doc mutation (teidraw's autosave shape); loaded at editor boot.
This single file is what makes layout + unsaved work survive a restart —
half of the R3 exit criterion. `.ed/` is per-project, untracked
(gitignored by the engine's default project scaffolding).

## 3. The canvas

Straight from igcanvas + teidraw's tuning (constants lifted from
teidraw's source; they are taste-approved by construction):

- **Coordinates**: world = canvas space, screen = window px.
  `screen = (world - cam) * zoom` (igcanvas's w2s/s2w stay).
- **Zoom**: wheel, **1.16× per notch**, clamped **0.02–64**, always
  anchored at the cursor (the world point under the cursor stays put).
- **Pan**: left- or middle-drag on empty canvas; space+left-drag pans
  from anywhere (teidraw).
- **Zoom-to-fit**: Shift+1 = fit all windows, Shift+2 = fit selection,
  Shift+0 = 100%, animated over **280 ms ease-in-out-quart** (ephemeral
  ease; the camera lands in the doc every frame).
- **Grid**: teidraw's adaptive dot grid — base 32 world units, pitch
  doubled/halved to stay in the 18–44 screen-px comfort band, alpha
  fading in across the band. (igcanvas's grid upgrades to this.)
- **HUD** (screen-space, `x_ig_overlay`): top-left project pill,
  top-right zoom pill. The top-right *corner* is reserved for the R6
  rewind pill (the zoom pill sits left of it from day one so R6 doesn't
  reshuffle the HUD).

## 4. Windows

- **Model**: one flat array in `cm.ed.doc` — draw order = z order
  (teidraw's Doc shape). A window: `{ id, kind, x, y, w, h, parent,
  … kind fields }`, world coords. `parent` (0 = top level) is carried
  from day one so window *groups* can arrive later without a model
  change; R3 windows are all top-level leaves.
- **Chrome**: rounded panel, 1 px edge, a slim header strip with the
  kind glyph + name + the unsaved dot. The header is a **label, not a
  handle** — there are no draggable title bars; movement lives behind
  ALT (§5). Content is inset and clipped (`x_ig_clip_push`).
- **Focus** = the most recently selected (or content-clicked) window;
  keyboard asset commands (§7 hotkeys) apply to it. Focus is captured
  state (it's visible: the focused window reads brighter).
- **Edge resize**: a **6 screen-px band** on borders + corners resizes
  on plain drag (no ALT — the band is chrome, not content; it sits ON
  the border, never inside content). Hover brightens the edge (no OS
  cursor swap in v1). Min size clamped (64×48 world). Corners resize
  both axes.
- **No auto-raise**: interacting with content does not reorder z;
  bring-to-front is explicit (§5 hotkeys) — mirroring teidraw.
- Selected windows draw an accent outline; fades run 120 ms in / 150 ms
  out (teidraw's pill timing).

## 5. The ALT grammar (the board's spec, exact)

Input routing priority, evaluated per event:

1. An **active `x_ig_edit` widget** owns mouse/kb/text while imgui says
   so (`ig.mouse/kb/text` capture flags) — except ALT-gated events,
   which the shell takes first (you can always A-drag a window whose
   editor is focused).
2. **ALT held → the shell owns the mouse.** Content sees nothing.
3. **Edge bands** (no ALT): plain drag resizes (§4).
4. Otherwise events route to the **window content** under the cursor.
5. **Empty canvas**: drag pans, wheel zooms, right-click (still-click,
   < 4 px) opens the spawn menu (§8).

The grammar itself (click = release within **4 px** of press; drag =
crossing 4 px; double-click = **320 ms / 6 px**, teidraw's thresholds):

- **A-click** on a window → select it (selection = that id). On an item
  *inside* a selected group → drill: select the element within the group
  (teidraw's `resolve_target`/`g_drill` walk, kept generic over the
  `parent` links; with R3's flat windows this simply selects the
  window). Click outside a drilled group pops the drill.
- **A-drag** → move. Target priority when overlapping: the **selected**
  item first, else the topmost hit. Dragging an unselected item selects
  it as the drag begins. Movement is in world coords (zoom-corrected).
- **A-rightclick** on a window → **close it**. No confirm dialog —
  closing is *non-destructive by construction*: the asset's working
  state + journal live keyed by asset (§7), not by window, so reopening
  the asset restores exactly where you were. (The unsaved-persists model
  is what makes fearless close possible; this is a feature, state it in
  the UI copy.)
- **A-drag on empty canvas** → marquee-select windows (teidraw's
  marquee; cheap, and the grammar slot is obviously right).
- **Bring-to-front hotkeys** (selection): `]` forward one, `[` backward
  one, `Shift+]` to front, `Shift+[` to back.
- **Esc**: pop drill if drilled, else clear selection.
- **Arrow keys** nudge the selection 1 world unit (Shift = 10); bursts
  within 600 ms coalesce into one journal-ish step (teidraw's nudge
  rule) — layout nudges live in the session doc, not a journal, so
  coalescing only matters for feel here; the rule matters at R4.

**What the game sees in editor mode: nothing.** The sim keeps running
(the live-game window is the point — igcanvas proved it), but the shell
swallows all input before `cm.input.feed`. Synthesizing sim input for a
*focused, playable* game window is R4 design, not R3.

## 6. Unsaved-persists + undo-forever (the journal)

The board's spec: very long undo history for every editable asset;
unsaved changes persist across sessions but don't take effect; unsaved
is clearly indicated; a button resets to saved.

### The model

Three layers per editable asset, keyed by **project-relative path**:

1. **The file on disk** — the saved truth. The engine/game only ever
   loads this. "Unsaved changes don't take effect" falls out for free.
2. **The working state** — `cm.ed.doc.assets[path] = { text, jpos, … }`.
   What the editor shows and edits. Survives restart via session.dat.
   **Dirty is computed, never tracked**: `working ~= disk bytes`
   (hash-compared at gesture rate) — no marker to desync.
3. **The journal** — `<project>/.ed/journal/<key>.jrn` where `<key>` =
   the path with `/` → `__`. The undo-forever history.

### The journal file (teidraw's undo.jsonl, translated)

A `CJRN` chunk container whose entries are appended over time — the
cm.chunk stream format is already append-friendly (magic, then chunks
until EOF), so appending one serialized `ENTR` chunk is a valid file.
`ENTR` v1 payload: `<i64 wall-ms> <u8 flags (bit0 = was-saved)>
<s4 asset bytes>` — a **full snapshot** per entry (teidraw's shape:
full document per line, dedupe if identical to tip, no deltas — proven,
simple, and journals stay debuggable). For text assets the bytes are
the text; R4 asset kinds define their own canonical bytes (`.spr` docs
already have them).

- **Load**: whole file on asset open (teidraw), entries capped at
  **4096** (configurable) — truncate oldest past the cap.
- **Push** on gesture end: edit-widget deactivate, 600 ms idle while
  active, window close, session end. Identical-to-tip pushes are
  dropped.
- **Undo/redo** (Ctrl+Z / Ctrl+Y or Ctrl+Shift+Z, focused window): move
  `jpos`, apply the entry to the working state. Editing while rewound
  **truncates the tail and rewrites the file** (teidraw's branch rule —
  linear history, no tree).
- **Append needs a PAL primitive**: `pal.x_file_append(path, bytes)` —
  portable C, a few lines, additive `x_` entry (no api bump; x_ names
  are the unfrozen tier by contract rule 3). Without it every push would
  rewrite a multi-MB file.
- **Ctrl+S**: write the working bytes to the real file (the game's
  hot-reload/asset-epoch machinery reacts on its own), push a journal
  entry flagged saved. **Revert-to-saved** (the header's unsaved-dot
  button): set working = disk bytes — *as a normal edit*, so revert
  itself is undoable.

## 7. The R3 window roster (dummy-but-real citizens)

Small on purpose; each exists to prove one slice of the shell:

- **note** — a sticky note (`x_ig_edit` multiline, sans font). Content
  lives only in `cm.ed.doc` (canvas furniture — no file, no journal).
  Proves chrome + edit capture + session persistence.
- **text** — a real project file in a mono edit widget. Journal-backed:
  unsaved dot, revert, Ctrl+S/Z/Y across restarts. The code-ed
  precursor — no highlighting/line numbers/links (R4).
- **game** — the live game target (`x_ig_image(-1)`), aspect-locked to
  the project's internal size, watch-only. Proves the sim-runs-below
  story.

Spawn menu (right-click on empty canvas): note · text file (tiny fuzzy
path picker over the project dir — a `pal.list_dir` walk; the R4 asset
picker replaces it) · game window. New windows spawn at the click point.

## 8. Hosting

- **Boot**: `bin/cosmic <project> --edit` — forces `maximized` windowed,
  requires the ig surface, loads session.dat, enters the shell.
  Live + `--win` capture only; under `--verify`/plain-headless it is a
  no-op (the D049 absence contract already guarantees `x_ig_frame` nil).
  F-key toggling in/out of a running game session is *not* R3 (the R5
  picker/launcher decides the mode story; --edit is enough to build on).
- **Frame flow**: `cm.ed.frame()` runs from cm.main right after
  `game.draw` (before the legacy ui-canvas panels). While the editor is
  on: `cm.view.mode = "canvas"` (no game blit, D049), events are
  consumed by the shell, the sim keeps stepping.
- **The legacy chrome quirk** (IMGUI.md §11): console/perf/scrub render
  UNDER the opaque ig canvas. R3 interim: **while the console overlay is
  open, the shell skips its ig frame entirely** (one gate) — canvas
  hidden, legacy chrome fully visible + interactive, come back with the
  same session. Honest and cheap; the console re-hosts as a canvas
  window at R4.
- **Hot reload**: cm.ed modules keep state on `M` (prev-table
  convention) like everything else; `cm.ed.doc` lives in the doc tree so
  a reload never loses layout. The editor is its own best test subject —
  edit `cm/ed/*.lua` in a text window, watch the shell reload live.

## 9. Module decomposition

- **`cm.ed`** — the shell: mode enter/exit, the frame loop, input
  routing (§5 priority), HUD, spawn menu; owns `cm.ed.doc`.
- **`cm.ed.cam`** — camera math: w2s/s2w, zoom-at-cursor, clamps, fit,
  eases, the adaptive grid pitch. Pure (table in, table out) →
  selftestable headless.
- **`cm.ed.wm`** — window list ops (spawn/close/reorder/move/resize),
  hit-testing (content/edge/corner, z, overlap priority), the grammar
  state machine (fed synthetic input records in selftest — click vs
  drag vs double-click, drill, marquee). Pure core, drawlist-free.
- **`cm.ed.journal`** — the §6 codec + push/undo/redo/branch/cap +
  dirty calc. Pure over byte strings + pal file I/O → selftestable.
- **`cm.ed.win.note` / `.text` / `.game`** — the roster; each registers
  a kind: `draw(win, ctx)` + `input(win, ctx)` + doc-schema.
- **`cm.ed.session`** — session.dat save/load + the 400 ms debounce.

selftest additions (all headless, no ig): cam KATs (round-trip,
zoom-anchor invariant, fit), wm KATs (hit priority, threshold state
machine, drill/marquee), journal KATs (round-trip, branch-truncate,
cap, dedupe, dirty, was-saved flag), ed-doc canon round-trip + session
byte-stability, the `ed.*` snapshot/trace exclusion, and the --edit
absence no-op. Goldens: untouched by construction (nothing in the sim
domain moves).

## 10. Build plan + exit

1. **R3a — canvas + session**: `--edit`, cm.ed + cm.ed.cam +
   cm.ed.session; pan/zoom/grid/HUD at teidraw tuning; camera survives
   restart. Captures → llm-feed.
2. **R3b — windows + grammar**: cm.ed.wm + chrome + note/game windows +
   spawn menu; the full §5 grammar including edge resize, `[`/`]`,
   marquee. The feel milestone — iterate against teidraw side by side.
3. **R3c — journal + text window**: `pal.x_file_append`, cm.ed.journal,
   the text window end to end (dirty dot, revert, Ctrl+S/Z/Y, restart
   survival). The exit-criterion half.
4. **R3d — proof + docs**: selftest suite, `nix run .#test` green,
   windows cross build, captures + a short interaction screen-recording
   note on llm-feed, STATUS/ARCHITECTURE/CLAUDE pointers.

**Exit (REVAMP §6 R3)**: the canvas with dummy windows feels
teidraw-smooth (human taste pass — the one true gate), and undo/unsaved
survive a restart, demonstrably: edit a text window, quit without
saving, relaunch → the unsaved text + its undo history + the layout are
all back.

## 11. Traps / watch list

- **The R6 leak** — any durable editor state that sneaks into a
  module-local instead of `cm.ed.doc` is invisible to rewind later. The
  review test for every field: *"would a rewound frame look wrong
  without it?"* → doc. Mid-gesture-only → local.
- **Grammar creep** — the ALT layer is the board's spec verbatim; resist
  inventing extra modifier combos. New interactions must map to
  heuristics-for-intent, not chords.
- **imgui leakage** — the shell adds zero `x_ig_*` surface in R3a/R3b;
  if a window kind seems to need an imgui feature, re-run the D049 §2
  shape test before touching the PAL.
- **Journal growth** — full-snapshot entries × 4096 cap: a 100 KB text
  file journal tops out ~400 MB worst-case. Fine for R3 texts; R4
  sprite docs may want per-kind caps or delta entries — decide there,
  the format has room (`ENTR` v2).
- **Widget z vs canvas z** — imgui widgets (`x_ig_edit`) always render
  above the background drawlist, whatever our window order says. The R3
  rule (found + fixed in build): a window overlapped by a higher window
  draws its text **inert** (drawlist text — correct-looking, it's behind
  anyway) instead of submitting a live widget. The fully interleaved
  story (per-window imgui hosts, ordered by our z) is R4 code-ed design.
- **Two edit widgets, one frame** — `x_ig_edit` ids are per-window;
  the SDL3-backend text-input conflict (IMGUI.md §11) stays a
  keep-out-of-the-same-frame rule with `pal.text_input` (console), which
  the §8 console gate already enforces structurally.
- **WSLg flake** — feel iteration needs the live window; when wayland
  drops, `--win` captures keep the visual loop alive but the taste pass
  waits.
