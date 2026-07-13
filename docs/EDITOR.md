# the editor shell — the R3 design (D050) + R4 windows (D051)

> The REVAMP §3.4/§6 design doc for **R3 — editor shell**: the infinite
> canvas + floating-window system in Lua, the ALT interaction grammar, and
> the unsaved-persists + undo-forever model. The D036/STUDIO.md successor.
> §12 extends it with **R4 — the windows** (code ed / playable game /
> console / asset pick / sprite ed). Binding ADRs: **D050** (shell),
> **D051** (windows). Prior art: `../teidraw` (the interaction tuning is
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
- **Pan**: **middle-drag only** (live round 3, D054 — a left-drag on
  empty canvas is a marquee now); space+left-drag still pans from
  anywhere (teidraw's hand tool). A right-drag is nothing (the spawn
  menu stays on the right still-click).
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
  kind glyph + name + the unsaved dot. The header **is a drag handle**
  (live round 3, D054 — the human kept reaching for it): a plain
  left-drag on the title strip moves the window, a plain still-click
  selects it; the strip lightens on hover. The zone occupied by header
  *buttons* (reset, history arrows, edit toggles — each kind's `header`
  hook returns its consumed width, recorded per frame) keeps its
  clicks. ALT-move (§5) remains for grabbing a window anywhere.
  Content is inset and clipped (`x_ig_clip_push`).
- **Focus** = the most recently selected (or content-clicked) window;
  keyboard asset commands (§7 hotkeys) apply to it. Focus is captured
  state (it's visible: the focused window reads brighter).
- **Edge resize**: an **asymmetric band biased outward** — 10 screen-px
  outside the border, 4 inside (live rounds 1+2: the original ±3 was
  unhittable, and a symmetric band fought the ALT grammar for the
  interior). The band wins **whether ALT is held or not** — "dragging
  edges resizes" rides the same layer as the move grammar; the interior
  moves (ALT) or routes to content (plain). Hover brightens the border
  and accents the exact grabbed edge(s). Min size clamped (64×48 world).
  Corners resize both axes.
- **No auto-raise**: interacting with content does not reorder z;
  bring-to-front is explicit (§5 hotkeys) — mirroring teidraw.
- Selected windows draw an accent outline; fades run 120 ms in / 150 ms
  out (teidraw's pill timing).

## 5. The ALT grammar (the board's spec, exact)

Input routing priority, evaluated per event:

1. An **active `x_ig_edit` widget** owns mouse/kb/text while imgui says
   so (`ig.mouse/kb/text` capture flags) — except ALT-gated events,
   which the shell takes first (you can always A-drag a window whose
   editor is focused; realized as `pal.x_ig_mouse(false)` while ALT is
   held — the pointer is filtered off imgui in C, widgets render
   unchanged).
2. **Selection mode** (`alt+V`, live round 3): while armed, a left
   press can ONLY select — it outranks even the edge bands. A
   still-click selects the window under it (window or not), a drag
   marquees. The mode **disarms itself the moment a select lands
   something**; an empty select keeps it armed; Esc/alt+V exits. A
   top-center chip shows it. (Exists because plain click-select only
   lives on empty canvas — this is the "select anything anywhere"
   escape hatch.)
3. **Edge bands** resize, ALT held or not (§4) — the band outranks both
   the move grammar and content.
4. **ALT held → the shell owns the mouse.** Content sees nothing.
5. **Title strip** (no modifier, left of the header buttons): drag
   moves, still-click selects (§4).
6. Otherwise events route to the **window content** under the cursor.
7. **Empty canvas** (live round 3): a left press is a **marquee** —
   drag selects the intersecting set, a still-click clears the
   selection. Panning is the **middle button** (or space+drag); wheel
   zooms; right still-click (< 4 px) opens the spawn menu (§8).

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

**What the game sees in editor mode: nothing — unless a game window is
focused.** The sim keeps running (the live-game window is the point);
the shell swallows input before `cm.input.feed`, except the §12.3
playable path: focused game window = keys pass + mouse remaps through
the image rect (R4, `cm.ed.filter_events`).

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
- **The legacy chrome quirk** (IMGUI.md §11): the legacy ui-canvas
  panels render UNDER the opaque ig canvas. Both dev surfaces now have
  canvas citizens instead: scrub = the R6d rewind pill/bar, perf = the
  **perf window kind** (rclick menu; cm.ed.win.perf over cm.perf's warm
  rings — the F3 panel keeps serving play sessions). The R3 console
  gate is GONE (R4c): the console is a canvas window; grave
  spawns/focuses it, and a legacy overlay opened under the canvas (the
  error notify) is adopted into a window.
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
  rule: an occluded window draws inert instead of submitting a live
  widget. **R4 dissolved most of it** (§12.1): ghost widgets draw no
  glyphs, so an occluded window skips an *invisible* widget and renders
  pixel-identical — the rule survives only as "don't submit occluded
  widgets" (their selection highlight would bleed through).
- **Two edit widgets, one frame** — `x_ig_edit` ids are per-window;
  the SDL3-backend text-input conflict (IMGUI.md §11) stays a
  keep-out-of-the-same-frame rule with `pal.text_input` (console), which
  the §8 console gate already enforces structurally.
- **WSLg flake** — feel iteration needs the live window; when wayland
  drops, `--win` captures keep the visual loop alive but the taste pass
  waits.

## 12. R4 — the windows (D051)

R4 fills the shell with the serious citizens (REVAMP §6 R4): **code ed**,
the **playable game**, the **console** re-hosted, **asset pick**, and
**sprite ed** — and the F2 studio dies (D046 Q4). The R3 state model is
unchanged: every new durable field passes the §2 review test and lives in
`cm.ed.doc`; bulky working state stays keyed by asset path.

### 12.1 The ghost-widget split (the widget-z fix, and the code-ed shape)

The one structural idea of R4: **`x_ig_edit` stops drawing text.** A code
editor needs syntax color, a gutter, and a caret the widget can't give us
— so Lua draws *every visible glyph* on the drawlist (which already obeys
canvas z), and the widget becomes an invisible input machine: caret math,
selection, mouse picking, clipboard, IME, key repeat — all the D049
"miserable to hand-roll" machinery — rendered as nothing but the
selection highlight. The §11 widget-z trap thereby dissolves: an occluded
window simply skips its (invisible) widget and looks pixel-identical;
there is no interleaved-z story left to design.

Additive `x_ig_edit` opts (x_ tier, no api bump):

- `ghost` — push a transparent text color around the widget (glyphs +
  imgui's caret invisible; the `TextSelectedBg` highlight still draws).
- `scroll_x, scroll_y` — when present, force the widget's scroll (the
  multiline child window + `state->Scroll.x`) — session restore and
  link jumps.
- `enter` — `EnterReturnsTrue` (the console input line).
- `focus` — grab keyboard focus this frame (`SetKeyboardFocusHere`).
- `set` — adopt the passed `text` even while active (history nav, undo
  while focused — the buffer normally re-syncs only when inactive).

New 4th return: a state table `{sx, sy, caret, sa, sb, submit}` — scroll
in px (read from the multiline child window, which persists while
inactive), caret/selection **byte offsets** while active (from
`GetInputTextState`; nil when inactive), and the enter flag. The child
window is found by its 1.92.4 name shape (`"host/##t_%08X"`) — a
vendored-pin-internal, revisited on any imgui bump.

### 12.2 code ed (the text window grows up; kind stays `text`)

- **Visible layer, all Lua drawlist**: line-number gutter (mono, dim,
  right-aligned; the active line bright), per-line syntax color, our own
  caret (blink on the wall clock, mono column metrics), current-line
  tint. **Font: 15 px default** (rounds 4–5: 26 tried and reverted,
  then one tick up from the original 13), adjusted per window by the
  `a−`/`a+` header buttons or **ctrl+wheel over the content** (step 2,
  clamp 8–64); the override lives in `win.px` (captured — rides the
  session, rewinds honestly). Ctrl+wheel over an assets window dials
  its preview size the same way (win.tile, the header slider's 48–160
  range).
- **Find/replace (UX round 5)**: **Ctrl+F** opens a bar at the top of
  the window (works mid-typing — Ctrl+S/Ctrl+F are pre-gate hotkeys,
  fired even while the widget owns the keyboard). Plain-text literal
  find, per line; live first-match jump as you type; Enter/`<`/`>`
  cycle (wrapping, scroll-to-match), `repl` replaces the current
  match, `all` replaces every match — each replace is one journaled
  undo step. Match highlights draw under the glyphs, the current one
  accented. Esc (or `x`) closes. Bar state is ephemeral (`ed.g.fr`);
  the cap is 2000 matches. Only visible lines draw (scroll + line height = px); tokens memo
  per line keyed by the line's string (interning makes the lookup cheap;
  the cache is ephemeral).
- **`cm.ed.lex`** — pure per-line tokenizers, selftestable: `lua`
  (comments incl. long brackets via a per-line carry flag, strings,
  numbers, keywords, punctuation), `md` (headings, code spans/fences,
  links, emphasis markers), plain. Comment/string carry state is a
  per-line-start array recomputed on change (cheap, correct across
  multi-line strings).
- **Docs are a special *code* format, not a rendered view**: .md keeps
  the mono grid (the ghost overlay must match the widget's layout
  glyph-for-glyph), but headings/links/code spans get faces. **Links**:
  Ctrl+click any token that resolves to a project file (md link targets,
  `require`-style dotted module names, bare relative paths) → **opens a
  new code window** at the pointer (the board's rule). Each window keeps
  **back/fwd history** (`win.hist`/`win.hpos`, captured): header ◀ ▶
  buttons + mouse buttons 4/5 navigate the window through the files it
  has visited (re-targeting the same window, teidraw-style).
- Wheel over the content scrolls (the imgui child already captures it);
  ALT+wheel always zooms the canvas (§12.6).

### 12.3 The playable game window

- **Focused = playing** (heuristics-for-intent: content-click focuses,
  so *clicking into the game plays it*; clicking anywhere else stops).
  Unfocused stays watch-only. The header reads `game — playing / live`.
- `cm.ed.filter_events(events)` replaces cm.main's blanket swallow:
  while a game window is focused (and ALT is up, and imgui doesn't want
  the keyboard) **key events pass through to `cm.input.feed`**, and
  motion/button events over the window's letterboxed image remap
  `wx,wy → FOV px` through the image rect (recorded each draw,
  ephemeral). Wheel over it feeds the sim. Everything else is swallowed
  as before. Synthesized input rides the normal `cm.input` record path —
  recorded, replayable, deterministic by construction.
- **Plain-key shell hotkeys suspend while a game window is focused**
  (`]`/`[`, arrows, shift+digit fits — they'd collide with gameplay);
  the ALT layer, Esc, and Ctrl combos stay the shell's. Esc-to-shell is
  the one deliberate theft (universal "get out").
- **The `restart` header button (D056)**: boot state at the current
  frame — buffers/doc/rand reset, `game.init` re-runs, but the frame
  counter keeps counting (it's the rewind timeline, D055: the restart
  is a recorded delta, so the past survives and the restart itself
  rewinds). Routed through the recorded EVAL path; walled while
  parked. Editor boots also **resume the stream's last frame** (D056),
  so quitting and reopening continues the same run.
- **Sizing is always aspect-locked, and it drives the game's FOV**
  (live round 3, D054). The supported game resolution range: **height
  is fixed** at the project's internal height; width runs **4:3 →
  16:9** of it (base 540 → 720..960), widened to include the project's
  own design width so odd-aspect projects never get a forced res
  change. A **horizontal** edge drag walks the FOV width through that
  range at constant scale, then scales aspect-locked past the ends;
  **vertical** edges and **corners** always scale at the current
  width. **CTRL snaps the scale to integers** — the window lands on
  exact multiples of the res. Mechanism: `kind.constrain` (threaded
  through `wm.resize` via the inp snapshot) recomputes the window size
  as `image(FOV×s) + chrome pads`; the chosen width lives in `win.fw`
  (captured), reaches the target as `cm.view.canvas_fov` →
  `pal.x_fov` before the next frame's game draw (render-only, D036 —
  never sim state; goldens/verify never see it).
- **Pixel-perfect**: the window spawns at `native + pads` so the image
  sits 1:1; when the drawn scale lands on an integer (100% canvas zoom
  × a res-multiple window — or any integer product) the draw snaps
  scale and origin to exact px. Zero letterbox whenever the aspect
  constraint holds.

### 12.4 The console window (the §8 gate dies)

- Kind `console`: scrollback pulled from the same `pal.log_lines` ring
  the legacy console reads (shared incremental poll on the shell's g;
  the ring is the source of truth — a rewound frame shows the live log,
  which is honest: logs aren't editor state), filter + input line as
  single-line ghost edits, Enter (`enter/focus/set` opts) submits to
  `cm.repl` — the same recorded EVAL path; up/down walk `repl.history`.
- In editor mode **grave spawns/focuses a console window** (and is
  consumed); the legacy overlay stays for non-editor sessions. The §8
  skip-ig-frame interim gate is deleted — the last legacy-chrome
  coexistence hack goes with it. Contained-error notify opens/focuses
  the console window when the shell is on.

### 12.5 asset pick (+ the image window)

- Kind `assets`: **no folders** — one flat list of project files
  (filtered walk; `.ed`/`.git` pruned), **type chips** (all · code ·
  image · sound) + **fuzzy search** (subsequence scorer, best-first),
  a **size slider** (tile size 48–160 px-at-zoom), grid of tiles:
  image files preview via `cm.gfx.texture` (`.spr` shows its baked
  `.png` sibling), everything else a kind glyph + name.
- **Double-click opens the right window**: text-ish → code ed, `.spr` →
  sprite ed, image → the trivial `image` kind (texture view,
  aspect-locked — also the drop preview for ref images), sound → none
  yet (M9 never landed; glyph only).
- **Drag-out = rebind**: dragging a tile ghosts a thumb on the overlay;
  released over a window whose kind `accepts(win, path)` → that window
  **re-targets to the file** (code ed opens it into its history; sprite
  ed re-binds; image swaps); over empty canvas → spawns the right window
  there.
- **Drag-in from the OS = add to project**: new PAL event
  `{type="drop", path, wx, wy}` (SDL_EVENT_DROP_FILE; additive event
  kind, absent headless). Dropped **onto an assets window**, the file is
  copied into the project (image → `art/`, sound → `sound/`, code/text →
  the root; name collisions suffix `_2`), the list refreshes, the tile
  flashes. Drops anywhere else are ignored (R4; window-targeted drops =
  replace-the-asset can come later with the same event).

### 12.6 sprite ed (the studio's successor; the F2 studio dies)

- Kind `sprite`, bound to a `.spr` path. **Read-only by default** — the
  composited current frame on a checkerboard, fit to the content rect —
  with an **edit toggle in the header** (the board's "obvious toggle").
- **The working state is the CSPR bytes** — `doc.assets[path] = { spr =
  <bytes>, jpos }` — so the §6 three-layer model applies verbatim: dirty
  = bytes ≠ disk, the journal entries are .spr snapshots, Ctrl+Z/Y walk
  them, revert is an edit, restart survival rides session.dat. The
  decoded `cm.sprite` doc + its textures are ephemeral plumbing keyed by
  path (anonymous buffers — the reserved `ed.*` prefix stays unused).
  One paint gesture (stroke/fill/toggle) = one encode + one journal
  push, replacing the studio's in-memory undo entirely.
- **Edit-mode roster (v1, deliberately lean)**: pencil / eraser / bucket
  / eyedropper, the doc palette + add-color (hex field), layer list
  (select, eye, add/del), frame strip (select/add/dup/del), sprite-view
  zoom (wheel over content) + middle-drag pan. Ctrl+S = `cm.sprite.save`
  (writes `.spr` + bakes `.png`/`.anim`/`.meta` — the game hot-reloads
  on its own, closing the paint→see-it loop inside the canvas).
- **Not in v1** (the .spr format carries them; the window just doesn't
  expose them yet): gradients editing, marquee/transforms/brushes/curve,
  clips/onion (animation is its own window later, per the board), HSV
  picker, image-size modal, pivot/slice editing. The studio's authoring
  depth returns window-by-window as content work demands it — D051
  records the accepted gap.
- **Journal growth** (§11): sprite journals cap at **512 entries**
  (journal.open gets a per-open cap; text keeps 4096).
- **`cm.studio` + `--studio` + F2 are deleted** (D046 Q4 — no
  coexistence; `pre-revamp` + git history keep the code). cm.paint /
  cm.sprite / cm.anim are untouched. cm.editor (the F1 *world* editor)
  is NOT R4 scope — it dies when maps become a canvas window (now
  designed: **docs/MAPS.md**, D057/R8 — the `map`/`tmap` kinds, the
  `kind.drop` place-on-drag-in hook, the CTRL-snap grammar).

### 12.7 Wheel routing (closing the R3 scope note)

Priority per wheel event: **ALT held → canvas zoom, always.** Else
**CTRL held → the hovered kind's size dial** when it has one
(`kind.ctrl_wheel`: code-ed font px, assets preview size — UX round
4b; CTRL also gates the pointer off imgui like ALT does, so the code
child can't scroll under the dial). Else if the cursor is over a
window's content and the kind takes the wheel (game-focused → sim;
sprite → sprite zoom; text/console/assets → their scroll, via imgui
capture or `kind.wheel`) → the content takes it. Else → canvas zoom.
(Pans/edge bands are unaffected.)

**The focus view lock (`kind.own_view`, R8c — the human's ask,
settled over four rounds)**: a focused window whose kind answers
`own_view(win)` (the map window, when bound) treats its WHOLE window
rect — header, view, inspector strip — as the view's input surface:
wheel and ctrl+wheel zoom/dial the map wherever they land on the
window (a wheel over non-view chrome anchors at the view center),
middle-drag inside pans the view, and the tool claims the plain keys
(`wants_keys`). The locked window draws an unmissable cue (accent
border + EDITING chip, the PLAYING-chip idiom).

The lock's whole contract is **focus is the ONE gate, and anything
outside the window releases it at the moment it happens**:

- an unfocused own_view window's view is INERT — no hover wheel/MMB
  fallback (`wheel`/`ctrl_wheel` decline with false,
  `takes_middle(win, ed)` answers false) — so unfocusing visibly AND
  actually lets go;
- a LMB/MMB press outside the window releases the lock at PRESS time
  (MMB pans the canvas, LMB marquees/moves/focuses as ever); the one
  exception is the window's own resize band (banded hit) — resizing
  the focused window keeps the lock;
- a WHEEL outside the window releases the lock right there and routes
  normally (canvas zoom / the hovered content);
- Esc unfocuses through the usual cascade (gesture cancel → selection
  clear → unfocus), and every other canvas action (space-pan, the
  spawn menu, focusing another window) releases it too.

ALT stays the canvas layer throughout: ALT+wheel zooms the canvas and
ALT gestures move/select without releasing the lock (deliberate
overrides, not canvas "actions"). An imgui-captured wheel (code-ed
scroll under the cursor) still wins over everything.

### 12.9 cm.ed.winview — captured view state is WORLD units

The rule, learned three times (code ed at UX round 6, then the asset
grid, map and sprite windows all drifting under canvas zoom in their
own ways): **a window's captured view fields — zoom, pan, scroll —
are stored in WORLD units (canvas units), never screen px**, so the
canvas zoom cancels out and content stays glued to its frame.
`cm.ed.winview` owns the math so the footgun is gone by construction:
`view()` (frame transform: win.zoom = world units per content px,
win.px/py = world-unit pan, nil = fit+center), `wheel_zoom()`
(zoom-at-anchor), `pan()` (middle-drag), `reset()` (shift+1), and
`scroll_px`/`scroll_by` for 1-D grids (the asset picker's win.sy).
The code ed stores lines and the console stores rows — content units
by another name. New kinds use winview instead of rolling their own.

### 12.8 R4 build order + exit

1. **R4-pal**: the §12.1 edit extension + the drop event + absence KATs.
2. **R4a code ed** (lex + gutter + links + history), **R4b game window**
   (filter_events), **R4c console**, **R4d asset pick (+image)**,
   **R4e sprite ed + studio removal** — each a commit + captures.
3. **R4f proof**: selftest suites (lex, fuzzy, filter_events remap,
   journal cap), `nix run .#test` green (goldens untouched by
   construction), windows native selftest + trace verify + `--edit`
   capture, llm-feed set, STATUS/docs.

**Exit (REVAMP §6 R4)**: one real session without leaving the canvas —
open the game and *play it in its window*, edit a script in code ed
(highlighted, Ctrl+S hot-reloads the running game), tweak a sprite in
sprite ed, drag an asset in from the OS — and the F2 studio is gone.
