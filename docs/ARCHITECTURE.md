# cosmic2d — architecture

The technical design. DECISIONS.md records *why* each choice was made and when
to revisit; this file describes *what is*. Keep it current when code changes.

## The two layers

```
┌────────────────────────────────────────────────────────────┐
│  Lua 5.4 (loaded from disk, hot-reloadable, user-editable) │
│                                                            │
│  projects/<name>/   game code + assets ("cartridge")       │
│  engine/            engine: state, gfx orchestration, ui,  │
│                     physics, input map, editor, tools      │
├────────────────────────────────────────────────────────────┤
│  PAL — platform abstraction layer (per-platform C binary)  │
│                                                            │
│  SDL3: window, input events, audio device                  │
│  SDL_GPU (Vulkan): quad batcher, internal target, present  │
│  Lua VM (vendored 5.4, deterministic seed)                 │
│  named typed buffers ("console RAM"), file IO, PNG, hash   │
│  later: FM synth inner loop, perf kernels (numpy model)    │
└────────────────────────────────────────────────────────────┘
```

- The PAL is the "console hardware": small, dumb, powerful, carefully tuned.
  It owns the main loop and the Lua VM, nothing else. Porting the engine =
  porting the PAL only.
- Lua is everything else, including the editor. The engine never needs the
  binary recompiled except when the PAL itself grows a primitive.
- Perf-critical hot loops migrate **down** into PAL kernels that operate on
  the same typed buffers Lua reads/writes (the numpy model). Migration is an
  optimization, never an architecture change.

### Boot flow

1. `cosmic [project_dir] [flags…]` — C parses nothing; argv is handed to Lua
   as `pal.argv`. Before the handoff `main` self-locates the repo root (chdir
   to the dir holding `engine/boot.lua`, found via `SDL_GetBasePath`), so the
   binary runs when launched from anywhere — `bin/cosmic`, or a packaged
   `cosmic.exe` beside `engine/`. On Windows the UTF-8 SDL base path crosses
   this one platform seam through `SetCurrentDirectoryW`, so non-ASCII archive
   paths remain lossless. Windows builds cross-compile from the flake (`nix
   build .#cosmic-windows`; mingw + cross SDL3) (D038/D069).
2. PAL creates the Lua state and runs `engine/boot.lua` — a deliberately thin
   shim that defines the **cm module system** and hands off to `cm.main`.
3. `cm.main.boot()` parses flags, decodes `<project>/project.lua` through the
   canonical `cm.project` empty-environment/plain-data model—a table containing
   name/version/author/description, internal w/h, window scale, entry, seed,
   and project-local icon/controls/credits/licenses release references—calls
   `pal.gfx_init{…}`, applies the project PNG through
   `pal.x_window_icon`, requires the project entry module, and dispatches
   `--record`/`--verify` modes.

4. C loop: each iteration calls the global `cm_tick()` under `pcall`.
   Lua decides everything inside the tick (sim steps, drawing, reload polls).

`cm.project` also owns D070's referenced-byte contract: injected file I/O lets
the editor and host packager apply the same size/type/content checks to the
square 32–1024 px PNG icon and bounded non-empty controls, credits, and license
texts. A metadata table with no release references is an ordinary draft; once
one reference is configured, settings require the complete packet and refuse
publication until every saved project-local file validates (D072).

`cm.export` is the D075 self-contained player builder. It combines any open
project root with the host-matching runtime already carried by a public editor,
then streams deterministic stored ZIP (Windows) or tar inside uncompressed
deflate/gzip (Linux) entries through PAL file primitives. It adds the canonical
player README/quick-start/icon, complete extracted-tree `SHA256SUMS`, and
runtime inventory. One coroutine step owns one file; cancellation and failure
remove the sibling temp, while `pal.x_file_publish` is the sole authoritative
archive transition. The project-window operation state is ephemeral render/dev
state and its preflight requires every editor working asset to match disk.

### The module system (cm.require)

- `cm.*` names map to `engine/cm/` (`cm.math` → `engine/cm/math.lua`) and
  attach to the `cm` global on load; other names map into the project dir.
  Dotted-segment validation means module paths can never escape their root.
- A module file returns a table. The loader **retains every chunk's source
  text** (`cm.modules()` = the content-addressed D012 bundle) and watches
  every loaded file for the crash parachute.
- Hot reload (`cm.reload`, polled by cm.main outside capped runs) re-executes
  a changed chunk and repopulates the original table in place — references
  held by other modules stay valid. Chunks are called with
  `(name, prev_table)`; loop-owning modules like cm.main keep state across
  their own reload via `local M = select(2, ...) or {}`. Module-local
  upvalues reset on reload: sim state lives in named buffers / the doc tree.
- Snapshot restore runs code **from the bundle** (`cm.restore_bundle`) and
  pauses disk reload until `cm.adopt_disk()` — D012's explicit adoption step.
- `game.init()` must be **reload-idempotent** (named buffers persist); the
  same contract makes it restore-safe: every restore is followed by
  `game.init()`.

### Error containment (no typo death spirals)

Two nets, engine first (D023):

- **Engine containment** (live sessions; `--frames`/`--verify` stay
  fail-fast): cm.main runs require/init/step/draw guarded. A game error
  logs the traceback, pauses the sim, stops any active recording (the trace
  stays valid up to the last good frame) and opens the console with an
  error banner; the REPL drains immediately while paused, so state can be
  inspected mid-autopsy. Any successful hot reload resumes (re-running the
  reload-idempotent `game.init`); if the entry itself never loaded, the
  require is retried every poll until the file parses. Game errors never
  kill the session (M2 exit criterion).
- **C parachute** (engine bugs): the C loop pcalls the tick. On error: the
  traceback goes to the log, the PAL enters **error state** — window alive,
  magenta clear, watch list (`pal.watch_add`ed files) polled every 250 ms.
  When a watched file changes, the PAL **reboots the Lua VM from scratch**.
  Named buffers live on the C side, so sim state survives the reboot.
- Inside a healthy session, the *engine* (not the PAL) hot-reloads edited
  modules itself; the PAL watch list is only the crash parachute.
- Live-reload orphans are acceptable by design; the inspector offers manual
  cleanup and a full restart is never precious.

## State model — what "the sim" is

The cardinal rule: **the Lua heap is never the source of truth for sim
state.** Snapshotting arbitrary Lua (closures, coroutines) is a tar pit;
instead, all sim state lives in things the PAL can snapshot byte-exactly:

1. **Named buffers** — `pal.buf(name, size)` returns a typed view over
   C-owned memory (u8/u16/i32/u32/f32/f64 accessors, fill/copy/hash/save).
   Named buffers persist across Lua reboots and are enumerable
   (`pal.buf_list()`) for snapshot/inspection. Bulk data lives here:
   physics arrays, particle pools, tilemaps, synth state, PRNG state, the
   frame counter. Anonymous buffers (`pal.buf(nil, size)`) are scratch:
   not persistent, not snapshot. `cm.state.buf_poke/buf_peek(name, kind,
   off[, v])` edit/read one typed cell by buffer name — the tools' eval
   unit (D027): live writes route through cm.repl like any sim edit.
2. **The doc tree** — one Lua table of plain data (tables/numbers/strings/
   booleans, no functions/userdata) for irregular state: entity definitions,
   knob values, inventory-ish data. Serialized canonically (sorted keys) by
   the engine for snapshots and hashing. Convenient but slower — bulk data
   belongs in buffers.

Engine modules may put an ergonomic Lua handle over those two forms, but the
handle is never a third source of truth. `cm.state.participate(name, hooks)` is
the single lifecycle boundary: name-sorted `capture()` hooks flush handles into
ordinary named buffers/doc before snapshots, ring frames, and verification;
name-sorted `restore()` hooks rebuild derived wrappers after every
`restore_tables`. A capture hook returning private bytes is not supported — it
must publish them through the normal state model, so every snapshot/trace path
gets the state without module-specific plumbing. `cm.map` is the first user:
its stable slot owns a collider buffer plus canonical map-runtime buffer, while
decoded placements/lookups/world wrappers are rebuildable glue.

A **snapshot** = all named buffers + serialized doc tree + frame counter
**+ the code bundle**: a content-addressed copy of every loaded source file
(engine + project). Code is live-editable, so state alone doesn't pin the
trajectory — restoring or rewinding against newer code would silently
diverge. The engine module loader retains the source text of every chunk it
loads to make this cheap; bundles dedupe by content hash, and an input trace
references the bundle(s) it was recorded against (a mid-recording reload
starts a new code epoch in the trace). Restore runs code **from the bundle**,
not from disk; "adopt current disk code instead" is an explicit, separate
operation.

### Traces (the recorded-session artifact)

One file format serves replay sharing, frame-by-frame debugging, and
regression testing (D014). A **trace** is an append-only stream of frame
records over a starting snapshot:

- **input record** per frame (compact action/event encoding) — what re-sim
  needs;
- **state delta** per frame: bytewise XOR vs the previous frame's named
  buffers + canonical doc-tree bytes, stored as sparse non-zero runs —
  what direct inspection needs. Sim state changes little per frame, so
  this stays small ("simple compression", not a codec dependency);
- **keyframe** every N frames: full compressed snapshot, so seeking is
  O(delta-window) instead of O(session);
- **code epoch record** when a hot reload happens mid-recording: the
  content-addressed bundle entries for changed files only (D012).

What this buys:

- **Replay/showcase sharing**: a trace plays back by restoring state per
  frame and calling draw — no re-simulation, so playback works even on a
  machine/driver where determinism would wobble. Traces live inside the
  project folder and travel with the zip (v1 assumes the matching project;
  embedding assets for fully standalone replays is not built yet). A7/D065
  specifies the additive, content-addressed standalone exporter without
  changing this description of today's v1 files.
- **Time-machine debugging**: the scrubber random-accesses any frame's full
  state for inspection without executing game code.
- **Determinism oracle**: the golden runner re-simulates the input records
  and byte-diffs each frame against the recorded deltas — the first
  divergent frame *and the exact bytes* are reported, which is the tool you
  want when hunting a determinism bug (hashes alone can't localize).
- **Rewind during play** = an always-on in-memory ring trace of the last N
  seconds; "save what just happened" exports it. As of M5 this is real:
  the ring IS the recorder (D032, cm.trace), F4 opens the scrubber
  (cm.scrub) over it, and a loaded .ctrace replays through the same panel
  (state-per-frame playback; exiting adopts the trace's timeline).
- **Durable history identity** (A2/D067): `<project>/.ed/history/stream` is a
  `CHST` container whose `STRM v1` payload is an opaque `hs1-…` ID. It survives
  contiguous cross-session adoption and rotates when derived history is
  cleared or a fork cannot rejoin. Crash lookup matches project + stream +
  committed frame exactly; timestamps are display metadata only.

Cosmetic state (particles, camera shake) is still deterministic sim state —
pixel goldens depend on it. "Cosmetic" only means the game rules don't read it.

### Concrete M1/M2 formats (v1, all little-endian)

Source of truth for byte layouts: the headers of `engine/cm/chunk.lua`,
`state.lua`, `input.lua`, `trace.lua`. Summary:

- **Containers** (cm.chunk): `<magic 4cc>` then chunks of
  `<tag 4cc, u32 version, u32 len, payload>`; unknown tags/versions are
  skipped, truncation errors loudly. Snapshot magic `CSNP`, trace `CTRC`.
- **Canonical doc bytes** (cm.state.canon): type-tagged values — 0x00 nil,
  0x01/02 false/true, 0x03 i64, 0x04 f64 bits, 0x05 u32-len string,
  0x06 u32-count table with integer keys ascending then string keys
  bytewise. NaN, shared subtables, fractional/boolean keys rejected.
  Equal trees ⇒ identical bytes (hashing + deltas rely on this).
- **Snapshot** (`CSNP`): CODE (the D012 bundle: name/path/source triples),
  BUFS (every named buffer, sorted), DOCT (canonical doc bytes). Trace
  keyframes reuse the format without CODE.
- **Input record** (cm.input): 10 frozen v1 bytes — u32 action down-bits in
  definition order (≤32 actions), i16 mouse x/y in internal pixels, u8
  mouse-button bits, i8 wheel steps — then zero or more additive v2
  extensions framed `u8 tag, u8 len, payload` (D082; unknown tags skip,
  malformed framing errors). Tag 1 = PAD: complete gamepad state, up to
  four ascending slots of u32 SDL-numbered buttons + six i8 axes,
  deadzoned and quantized on the live side only. Applied state (cur+prev)
  lives in the `cm.input` and (pad records/readers only) `cm.input.pad`
  buffers, so edges (pressed/released) are snapshot-consistent.
  Live sampling has "sticky tap": a sub-frame press+release still lands one
  frame's bit (keys and pad buttons alike).
- **Trace** (`CTRC`): HEAD (keyframe interval, project, action names), SNAP
  (full starting snapshot), per-frame FRAM (input record + per-buffer
  records: kind 0 = `delta1` vs previous frame, 1 = created/resized with
  full bytes, 2 = freed + canonical doc bytes when changed), EVAL before a
  FRAM (console commands drained at the start of that sim frame — D022;
  verify re-executes them via cm.repl.exec, delta playback ignores them),
  KEYF every N frames (code-less snapshot, cross-checked on verify), EPOC
  (changed sources on mid-recording hot reload, applied at the same frame
  on replay), TAIL (frame count). v1 lists every buffer every frame.
- **Engine sim buffers**: `cm.sim` = `[0]` i64 frame counter, `[8..39]`
  xoshiro256++ s0..s3, rest reserved. `cm.input` and `cm.input.pad` =
  documented in input.lua.

## Determinism (iron rules)

The sim must produce bit-identical state given the same initial snapshot and
input trace — across runs, machines, and eventually platforms.

- Fixed timestep: 60 sim frames/sec, integer frame counter. Rendering may
  interpolate later; the sim never sees wall-clock time.
- All randomness from the engine PRNG (xoshiro-family, state in a named
  buffer). `math.random`/`os.time`/`os.clock` are **banned in sim code**
  (engine/editor convenience code may use them; never inside `sim_step`).
- No libm transcendentals in sim paths: `cm.math` provides sin/cos/atan2/etc
  with our own implementations (pure IEEE arithmetic is bit-exact across
  platforms; libm is not). Plain `+ - * /` and `sqrt` on f64 are safe.
- Lua 5.4 integers are exact; prefer them for counters/ids/fixed-point.
- Never depend on hash-table iteration order in sim logic: iterate arrays,
  or sorted keys. (Vendored Lua also has a fixed string-hash seed so
  same-binary runs behave identically even if someone slips — but the rule
  stands because pointer-keyed order still varies.)
- Input is sampled into a compact per-frame record (the **input trace**
  format); the sim consumes only these records, never raw events. Record &
  replay are therefore symmetrical.
- Audio: synth state is sim state; note/parameter commands are timestamped in
  the sample domain derived from the frame counter; PCM out is a pure
  function of (state, commands) → audio goldens hash PCM.

**Testing** (M1+): a golden = a recorded trace checked into `tests/`. The
runner replays the input records headless and byte-diffs the re-simulated
state against the trace's recorded deltas frame by frame; the first
divergent frame (with offending byte ranges) is reported and openable in
the timeline scrubber.
Pixel goldens render on **pinned lavapipe** (software Vulkan from the flake)
so they're machine-independent; dzn/hardware drivers are never golden sources.

## Rendering

- **Internal target**: fixed-size RGBA8 texture from project config (e.g.
  480x270). All game/UI rendering goes here at 1:1 pixels. Present =
  integer-scale blit to the window with letterboxing (fractional/stretch as a
  later option). Headless mode skips window+present; the internal target is
  still rendered and readable.
- **Colors are raw bytes**: no sRGB conversion anywhere in the chain (UNORM
  all the way). Pixel art + LUTs want untouched values; it's also one less
  determinism hazard.
- **Draw API is immediate**: each frame Lua submits quads; the PAL
  accumulates CPU-side (vertex scratch + draw segments keyed by texture /
  scissor / camera), uploads once, renders in one pass at present. Two
  submission paths:
  - `pal.quad(...)` — per-call, ergonomic, fine for hundreds.
  - `pal.draw_quads(tex, f32buf, count)` — bulk from a typed buffer, for
    tiles/particles/text (M1).
- **Camera** is per-layer state subtracted CPU-side at submit time (no
  shader work) — parallax = layers with camera multipliers.
- **Scissor clip** (`pal.clip`) segments the batch; the UI depends on it.
- **LUT pass** (M9): final composite samples the internal target through a
  color LUT before/while scaling to the window; goldens read back post-LUT.
- One pipeline: textured alpha-blended quads, nearest sampling; a 1x1 white
  texture makes solid quads the same path. Text = quads from a baked bitmap
  font atlas (spleen, baked at build time into an engine asset).
- The engine-side renderer interface is deliberately narrow (init, textures,
  quads, clip, camera, present, read) so GL1/software backends can implement
  it later without touching engine code.

### Shaders

GLSL sources in `pal/shaders/`, compiled to SPIR-V with glslang at build time;
the `.spv` files are **committed** so users of the self-contained folder never
need a shader compiler. Engine/user code cannot define custom shaders (that's
what keeps backends swappable and the procgen CPU-side).

SDL_GPU SPIR-V binding convention: vertex samplers set 0 / uniforms set 1;
fragment samplers set 2 / uniforms set 3.

## Input

PAL delivers raw events (`pal.poll_events()`): key scancode up/down, mouse,
window, utf-8 text (while `pal.text_input` is on), and device-level gamepad
events (`gpad`/`gpadbtn`/`gpadaxis`, API v18 — the PAL owns SDL device
open/close on hot-plug). The engine UI sees raw events first (`cm.ui.frame`
filters what the game may sample — see UI below); keys fold into **actions**
via the rebindable action map (project + user bindings), and gamepads map
device→slot 1..4 in `cm.input` (first-connected takes the lowest free slot)
before entering the recorded PAD extension (D082/D083). The sim reads
actions and slot-addressed pad state only.

## Engine UI (cm.ui — M2)

Immediate mode: panels and widgets are plain function calls every frame;
the only retained state is a per-id table (scroll offsets, collapse flags,
text cursors) keyed by a hierarchical id path (`push_id`/`pop_id`).
**Dev/render class by iron rule**: cm.ui never touches named buffers, the
doc tree or cm.rand — UI chrome state survives hot reload (module table),
resets on VM reboot, and is never recorded. What a widget *edits* (a doc
knob, say) is the caller's write.

- Frame protocol: `ui.frame(events)` at tick start returns the events the
  game may see, filtered by last tick's capture flags (one-frame imgui
  latency); key/button **ups always pass** so games never see stuck keys.
  Widgets run during the draw phase; `ui.frame_end()` resolves hover
  (topmost = drawn last) and the next tick's captures.
- Core: clip-stack scroll regions (wheel innermost-wins + draggable thumb),
  virtualized fixed-row lists, weighted row columns, collapsing headings,
  `canvas` (raw rect) and `hit` (invisible button) escape hatches for
  custom widgets. Style table centralizes colors/metrics. Widgets
  (label/button/checkbox/slider/number) also take `opts.rect` to place
  explicitly instead of flowing — editors inside virtualized list rows
  (the inspector's cell views).
- Built on it: **cm.console** (` toggle: log scrollback from the pal ring,
  filter, REPL line → cm.repl, error banner), **cm.perf** (F3: frame
  graph vs 16.7 ms budget, sim/draw split, `pal.frame_stats`) and
  **cm.editor** (F1 — see "Editor" below). `, F3 and F1 are
  engine-reserved keys; `editor = false` in project.lua (shipped zips)
  disables all three toggles — the M4 play-mode lockdown — while
  contained-error banners still open the console programmatically.
- Editor world tools add two frame-protocol hooks: `ui.capture_mouse()`
  (this frame's overlay owns ALL mouse downs, panels or not — the game
  still gets up-events) and `ui.over_panel` (was the mouse on chrome as
  of the last frame_end, for "clicks on the world, not the toolbar").
- The console REPL is deterministic-by-construction: commands queue and
  drain at the start of the next sim frame, and recordings store them as
  EVAL records (D022) — a knob-tweaking session replays byte-exact.
  `--eval CODE` (repeatable) queues a line at boot through the same path,
  so headless capped runs can flip doc switches replayably.

## Tilemaps (cm.tilemap — M3)

A tile grid in a named buffer, self-describing for tools (D024):
`[0] u32 w | [4] u32 h | [8] u32 tile px | [12] reserved`, then u16 ids
row-major. `new{name,w,h,tile,tiles}` creates or adopts (same shape keeps
cells — init stays idempotent; a shape change frees + rebuilds); `open`
adopts purely from the header. Tile *meaning* is the `tiles` table in
code (travels in bundles): per id `solid=true` / `oneway=true` + atlas
`u,v` and optional tint for `tm:draw`, which packs the camera-visible
window into one bulk `pal.draw_quads` call.

Collision: AABBs are half-open pixel rects; `tm:move(x,y,w,h,dx,dy,opts)`
sweeps axis-separated (x then y), scanning every cell boundary crossed —
nothing tunnels at any speed. One-way platforms collide only when a
falling body enters their row from at-or-above; `opts.drop` disables them
for down+jump drop-through; they never block sideways or rising movement.
Outside the map: side/bottom walls, open sky. The mover never ejects an
already-overlapping AABB (don't spawn inside walls). Pure Lua, pure
IEEE arithmetic (f64 `+ - * /`, floor/ceil) — deterministic everywhere;
if profiling ever demands, it migrates down as a versioned PAL kernel
per the numpy model.

M4 statics (tools): `poke(name,tx,ty,id)` / `peek(name,tx,ty)` edit one
cell by buffer name — the editor's eval unit (D026; live writes go
through cm.repl). `save(name,path)` / `load(name,path)` move the raw
self-describing bytes to/from disk (load is boot-time-only by rule:
file bytes are not sim input). `cell_line(x0,y0,x1,y1,fn)` walks an
8-connected Bresenham line (brush drag continuity). `new` returns a
second value `fresh` — true when cells did not survive (created or
shape-rebuilt), the "seed a first boot" signal.

## Editor (cm.editor — M4)

Editor mode v0: F1 toggles editor/play chrome over the running game (the
sim keeps stepping; keyboard stays with the game, the mouse belongs to
the editor — unless the swatch-row `paint` checkbox disarms the brush,
which hands the world's mouse back to the game while panels keep
capturing over themselves). Dev/render class like all cm.ui chrome (D021) — and by D026
it owns no sim state and never writes any directly: **every edit is a
cm.repl submission** (`cm.tilemap.poke(...)` per painted cell, the
cartridge's `reset_eval` string for the reset button), so editing
records as D022 EVAL chunks and replays/verifies byte-exact. The
editpaint golden pins this.

Cartridges opt in from `game.init`: `cm.editor.attach(fn)`, where fn()
is called once per editor frame and returns the live, read-only surface:
`{ tm, atlas, camx, camy, colliders(), save, reset_eval, props }`. The
toolbar offers tile swatches built from `tm.tiles` + atlas (id 0 = the
eraser), LMB paints / RMB erases with cell-line drag continuity, a
collider overlay (solid fills / one-way top stripes walked from the
visible tm window, plus AABB outlines from `colliders()`), and
save/reset actions. The optional `props` list (D031) is the spawn
palette: entries `{ name, icon = atlas sub-rect, spawn/erase = eval
format strings }` join the swatch strip; while one holds the brush,
click press edges submit the entry's eval formatted with the world
mouse — spawning is a cartridge command (sandbox:
`game.props.spawn(x,y)` / `game.props.despawn_at(x,y)`) and records
like everything else. The editpaint and propspawn goldens pin both.

**The inspector** (cm.inspect, toolbar `inspect` toggle, D027) is the
M4 entity list + inspector: a searchable tree over exactly what sim
state can be (D005) — the doc tree and every named buffer. Doc numbers
drag-edit (magnitude-scaled speed; integers stay integers, floats stay
floats), booleans toggle, strings are read-only v0, tables collapse;
searching shows matching leaves flat with full-path labels. Buffers
expand to a typed lens view (u8..f64 per buffer) of every cell,
drag-editable, plus a free button (husk cleanup; hidden for `cm.*`
engine buffers). Reads are direct; **every write is a cm.repl
submission** — `doc.knobs.move.run = 142.0`,
`cm.state.buf_poke("sandbox.player","f32",0,920.0)`,
`pal.buf_free("husk")` — so inspector sessions record and verify like
console sessions (the inspectpoke golden pins all three shapes). The
panel also works while a contained error has the sim paused (the repl
drains immediately): poke the wreckage with a mouse.

Project persistence: `save` persists what the cartridge decides (pure
reads, called directly). The sandbox writes the raw tilemap bytes to
map.dat AND `doc.knobs` as canonical doc bytes to knobs.dat (D028),
both next to project.lua. Boot adopts live state first, then seeds
from files, then falls back to the procedural build / code defaults
(sandbox: `game.level.reset()`, also the reset button's eval; the
knobs defaults merge fills keys the file predates). File reads are
boot-time-only by rule: file bytes are not sim input.

The current native infinite-canvas shell (`cm.ed`, D050+) has two additional
machine-local accessibility multipliers. `editor_scale` composes with the
captured logical camera zoom at every world/screen transform, so canvas-window
geometry and text grow together without mutating or recording the camera.
`chrome_scale` gives the project picker and fixed HUD/menu/launcher/rewind
surfaces a virtual coordinate space through `cm.ed.chrome`: coordinates and
glyph sizes multiply at the PAL boundary while pointer coordinates divide by
the same value. Auto policy is resolved from `x_ig_frame().dpi` plus window
pixel density; manual values and the auto flag persist in per-user `editor.dat`
below `pal.user_path()`, shared by the picker and every project. They are
render/dev state, never simulation, editor-document, trace, or packaged-project
state (D074).

## Audio (R9b, D058 — the M6/M9 sketch, landed)

PAL owns the audio device and the voice inner loop (C, fixed-point,
deterministic — pal/src/snd.c); Lua owns patches, sequencing, and mixing
decisions (cm.snd). Voice state lives in the named buffer `snd.bank`;
commands are frame-locked (the sim mutates the bank inside the step) and
`pal.snd_render()` advances exactly 800 samples per sim frame into an
SPSC FIFO the audio callback drains — PCM is a pure function of the bank
bytes, so replays regenerate identical PCM (the selftest pins a
committed PCM hash, byte-exact linux + windows). The render-only
**editor bank** (x_snd_ed_*) is the audition path, rendered in the
callback itself. Full design: **docs/AUDIO.md**.

## Directory layout

```
cosmic2d/
  CLAUDE.md            agent orientation (session-start checklist)
  README.md  LICENSE  flake.nix
  docs/                PLAN, ARCHITECTURE, DECISIONS, PROCESS, STATUS
  pal/
    src/               C11 sources (main, gfx, lua bindings, buf) +
                       ig.cpp (the C++ imgui host, D049)
    vendor/            lua-5.4.x (patched seed), stb headers,
                       imgui 1.92.4 + fonts (Inter, JetBrains Mono; OFL)
    shaders/           *.vert/*.frag GLSL + committed *.spv
    Makefile
  engine/
    boot.lua           thin shim: module system + handoff to cm.main
    cm/                engine modules (main, state, input, rand, math,
                       ease, gfx, text, trace, chunk, ui, console, repl,
                       perf, tilemap, export, editor, inspect, scrub; assets/ =
                       baked fonts)
  projects/
    smoke/             the minimal test cartridge (R0/D046: one room + the
                       M7 moveset; the golden/selftest carrier)
    selftest/          engine invariants cartridge (PRNG KATs, trig
                       accuracy, serializer/snapshot/input/ui/tilemap)
    uigallery/         living cm.ui reference, shaped like the M4 inspector
    igcanvas/          living pal.x_ig_* reference (the R2 hello-canvas)
  tools/               dev scripts (bake_spleen, feed helpers)
  tests/
    traces/            golden traces (replay-forever, contract rule 6)
    pixels/            pixel goldens (.png + .args sidecar; pinned lavapipe)
    cartridges/        test fixtures (churn: trace-format edge cases)
  bin/                 built PAL binaries (gitignored until release packaging)
```

The repo root is the development form of the console and `projects/` holds its
cartridges. Release bundles preserve that one-folder model. Download-shaped
Windows and Linux editor archives plus developer-built play exports pass the
clean-machine matrix in D069. D075 adds the same player-facing construction as
a shell-free, arbitrary-opened-project editor job on both native hosts. D070
makes the play archive itself player-facing: project metadata
generates its root README/quick-start/icon, a root launcher boots the selected
project locked to play, and the deliberate editor entrance stays under `bin/`.
Linux retargets the root ELF to `$ORIGIN/lib`; Windows uses a project-resourced
Unicode delegating launcher while its same-named engine under `bin/` retains
cosmic2d identity and the D052 basename lock.

The project picker also remembers arbitrary external roots in `.recent.dat`;
opening does not copy or take ownership of them. Native chooser paths normalize
to forward slashes, pass through `cm.project`'s exact boot validator, and enter
recents atomically before the project-switch reboot. A stale recent entry can
be atomically replaced with a newly chosen root or removed without touching
project files. The editor uses `cm.main.switch_project` for its explicit return
to the picker, after its recovery state and history cross their durability
barriers. A ready recent tile can also reveal its folder, rename/move it on
the same filesystem, or duplicate it. `cm.project_location` refuses the active
editor root, aliases, missing/invalid sources, existing or nested
destinations, and unwritable parents before PAL API v16's collision-safe
directory rename. Only after that succeeds does one atomic recents replacement
advance the pointer; if it fails, the old stale tile deliberately remains as a
repair handle. Duplicate (D078) is a cancellable coroutine copy job: the saved
project minus machine/editor state (`.ed`, `video.dat`) streams into a unique
dot-prefixed staging sibling that `pal.list_dir` pruning keeps invisible, the
staged root revalidates through the boot contract, and publication is the same
no-replace rename followed by an atomic recents note. Failures and cancel
clean staging and never write the source; a post-publication recents failure
reports the exact new root for **open folder** repair.

## Conventions

- C: C11, `-Wall -Wextra`, prefix `pal_`, no global mutable state outside the
  PAL context struct (the buffer registry lives there too).
- C++ (D049): allowed ONLY for vendored C++ libraries and their host TUs
  (`pal/src/*.cpp`, C++17); each exposes an `extern "C"` interface declared
  in pal.h — no C++ types, exceptions, or RTTI cross the boundary. The link
  driver is `$(CXX)` (mingw cross: `-static-libgcc -static-libstdc++`, no
  new DLLs). First citizen: `ig.cpp` (the Dear ImGui host — docs/IMGUI.md).
  The numpy model is language-agnostic: kernels stay pure state-in/state-out
  over named buffers, versioned names, C or C++ alike.
- Lua: engine namespace `cm` (e.g. `cm.gfx`, `cm.state`, `cm.ui`); modules
  loaded through the engine's own loader (reload-aware, project-jailed
  paths, forward slashes everywhere).
- The PAL Lua API (`pal.*`) is the **porting contract**: keep it small,
  document every function's semantics + determinism class
  (sim-safe / render-only / dev-only) in this file as it grows.

### The PAL stability contract

The PAL is the console's hardware spec. Traces bundle the code that recorded
them (D012), so engine/game evolution can never invalidate a trace — the only
thing that can is a PAL whose primitives behave differently. Therefore the
PAL surface gets constitutional treatment from day one, and **1.0 freezes
it**: after 1.0 there is almost never a change that makes traces and a PAL
binary incompatible, in either direction (D015).

1. **Mechanism, not policy.** pal.* moves bytes, pixels, samples and events;
   *meaning* lives in Lua, which travels inside traces. When a primitive
   could either "do something smart" or "expose the dumb stable thing",
   expose the dumb stable thing — policy in C is what creates breaking
   pressure later.
2. **Additive evolution only after 1.0.** New functions may appear; an
   existing name never changes semantics, argument meaning, or determinism
   class. Better semantics = new name; the old name keeps working forever.
   Old PAL + newer engine Lua works whenever the engine doesn't need a new
   primitive — and says so clearly when it does (rule 7).
3. **Experimental namespace.** Post-1.0, new primitives are born as
   `pal.x_<name>`; promotion to `pal.<name>` is the freeze event. The trace
   recorder warns when sim code touched `x_` primitives. (Pre-1.0,
   everything is implicitly experimental — breaking is free *now*, which is
   why base semantics get declared now, while it's cheap to fix them.)
4. **Versioned kernels.** Every future C kernel that touches sim state
   (physics solve, particle update, synth voices, delta codec) is born with
   a version in its name (e.g. `"aabb_solve@1"`). Improvements ship as
   `@2`; `@1` stays callable forever, because old code bundles call the
   kernel they were recorded against. Kernels are pure state-in/state-out
   by construction.
5. **Frozen base semantics** (declared now):
   - little-endian for all multi-byte data — a big-endian port swaps inside
     the PAL, never in engine code or stored data;
   - IEEE-754 binary32/64; Lua **5.4 language semantics** (vendored — a Lua
     version bump is a constitutional event, expected never);
   - the pal.buf view model: flat bytes, current accessor/bounds semantics;
   - `buf:hash()` is fnv1a-64 forever (new algorithms get new names);
   - trace/snapshot containers: tagged chunks, each chunk format
     version-stamped, unknown chunks skippable — readers read what they
     know and never guess;
   - input scancodes: SDL/USB-HID numbering;
   - scene draw semantics: pixel-space quads, raw-byte colors (D009),
     src-alpha-over blend, nearest sampling. Integer-aligned opaque quads
     with integer uvs render exactly; subpixel coverage is stable per
     backend and pinned by per-platform pixel goldens, not cross-backend
     exact.
6. **Compatibility is enforced, not promised.** Every golden trace ever
   recorded lives in `tests/` forever and must replay byte-exact on every
   future PAL build — the suite *is* the contract's test, and a PAL change
   that breaks an old trace is by definition a bug (no statute of
   limitations). Pre-1.0 breaks are allowed but each one deliberately
   regenerates goldens and gets a DECISIONS entry.
7. **Feature detection, loud refusal.** Engine code checks
   `pal.version.api` / function presence and refuses with a clear
   "needs PAL api >= N" message; it never silently degrades sim-relevant
   behavior.

### PAL API v0 (M0 scope)

| fn | class | notes |
| --- | --- | --- |
| `pal.argv`, `pal.platform` | dev | argv after binary name; "linux"/"windows" |
| `pal.version` | — | `{major, api}`; see stability contract rule 7 |
| `pal.log(s)` | dev | timestamped stderr + ring buffer for console; live interactive processes also flush to `pal.log_path` |
| `pal.time_ns()` | render-only | monotonic; **never** in sim logic |
| `pal.sleep_ms(n)` | dev | paces interactive headless sessions |
| `pal.quit([code])` | — | request loop exit; `code` = process exit code (default 0) |
| `pal.gfx_init{w,h,scale,title,headless,vsync}` | — | once at boot |
| `pal.x_window_icon(png_bytes)` → `true` or `nil,error` | render/dev | API v12: decode a project PNG and apply it to the live OS window; headless still validates the bytes |
| `pal.begin_frame(r,g,b,a)` | render | clear internal target, reset batch |
| `pal.quad(x,y,w,h, r,g,b,a [,tex,u0,v0,u1,v1])` | render | pixels, top-left origin |
| `pal.clip(x,y,w,h)` / `pal.clip()` | render | scissor on internal target |
| `pal.camera(x,y)` | render | subtracted from subsequent quads |
| `pal.present()` | render | upload, render, scale-blit, (headless: render only) |
| `pal.read_pixels()` | dev/test | internal target → string (RGBA8), post-render |
| `pal.png_write(path, str, w, h)` | dev | screenshot/golden output |
| `pal.png_encode(str, w, h)` → PNG bytes | dev | API v10: in-memory encoding so a multi-file asset can durably stage a complete generation before publishing any output |
| `pal.tex_create(w,h, pixels_str)` / `pal.tex_free(id)` | render | RGBA8; id 0 = builtin white |
| `pal.buf(name_or_nil, size)` | sim | named = persistent + snapshot; view userdata; size mismatch with a live name errors |
| `pal.buf_list()` | sim | iterate named buffers (snapshot/inspector) |
| `pal.buf_free(name)` | sim | drop a named buffer (restore/resize paths); true if it existed |
| buf views: `:u8/:i8/:u16/:i16/:u32/:i32/:i64/:f32/:f64(off [,v])`, `:fill`, `:copy`, `:hash`, `:size`, `:str(off,len)`, `:setstr(off,s)` | sim | bounds-checked, error on OOB (i8/i16 added in v2) |
| `pal.read_file(p)` / `pal.write_file(p,s)` / `pal.list_dir(p)` / `pal.mtime(p)` / `pal.mkdir(p)` | dev/io | engine enforces project-relative paths |
| `pal.write_file_atomic(p,s)` → `true` or `nil,error` | dev/io | API v9: unique same-directory temp → complete write → stream flush → OS file sync → close → atomic replace; a pre-replace failure removes the temp and preserves an existing destination |
| `pal.x_write_file_pair_atomic_async(p1,s1,p2,s2)` → job or `nil,error`; `pal.x_write_file_atomic_poll()`; `pal.x_write_file_atomic_drain()` | dev/io | API v13: bounded FIFO worker copies and durably publishes an ordered atomic pair; file 2 is attempted only after file 1, and a file-2 failure removes file 1. Poll never waits; drain is an explicit quit/crash/structural barrier, never a sim operation |
| `pal.sha256(s)` / `pal.sha256_file(p)` / `pal.crc32(s[,prior])` | dev/io | API v14: platform-identical release-integrity primitives; SHA-256 returns canonical lowercase hex and CRC-32 accepts a prior result for streaming archive construction |
| `pal.x_path_info(p)` / `pal.x_file_publish(temp,dest[,opts])` / `pal.x_windows_exe_identity(...)` | dev/io | API v14: path type/size plus link detection; publication syncs a complete sibling temp and renames it to a previously absent artifact name (or atomically replaces one only with explicit `_replace`), leaving the temp non-authoritative and any old artifact intact on failure. Windows can brand a private GUI-engine copy with validated project icon/version resources before it enters the ZIP; Linux reports that target-specific seam unavailable |
| `pal.x_folder_dialog([default])` / `pal.x_folder_dialog_poll()` | dev/io | API v15: begin one asynchronous native folder chooser, then poll its `idle`/`pending`/`cancelled`/`selected,path`/`error,message` mailbox from the live main thread. The SDL callback may run on another thread but never enters Lua; headless use is refused |
| `pal.x_path_move(source,dest[,opts])` / `pal.x_path_reveal(path[,opts])` | dev/io | API v16: move a directory with an atomic **no-replace** operation (Linux `renameat2(RENAME_NOREPLACE)`, Windows `MoveFileExW` without replacement) or open it in the native file manager (UTF-16 path on Windows, percent-encoded UTF-8 `file:` URI on Linux). Existing destinations are never mutated; cross-filesystem/volume moves fail explicitly pending a later recursive-copy packet |
| `pal.user_path()` → path or `nil,error` | dev/io | API v11: SDL-selected absolute per-user writable root for the fixed `cosmic2d/engine` identity; created on demand, platform separator retained |
| `pal.poll_events()` | input | array of event tables, drained each tick |
| `pal.pad_list()` | input | API v18: currently connected gamepads `{id=,name=}` (SDL instance ids, ascending = connect order); the project-boot reseed source since SDL only announces hot-plug as events |
| `pal.x_pad_virtual()` / `x_pad_virtual_remove(id)` / `x_pad_virtual_button(id,btn,down)` / `x_pad_virtual_axis(id,axis,v)` / `x_events_pump()` | dev | API v18: attach/poke/detach a virtual standard-layout SDL gamepad and drain SDL synchronously — the headless test vehicle; virtual pads ride the exact event path physical controllers do |
| events `{type="gpad", id, connected}` / `{type="gpadbtn", id, button, down}` / `{type="gpadaxis", id, axis, value}` | input | API v18: device-level gamepad events (SDL standard numbering, raw i16 axes); the PAL opens/closes devices on hot-plug, `cm.input.feed` owns id→slot policy |
| `pal.x_snd_gain(master,music,sfx)` | render/dev | API v19: device-output volume, 0..128 each (128 unity), clamped. music/sfx gain the sim bank's voice categories (music 32..47, sfx 0..31; 48..63 master-only) on the **device copy** only, composing with the editor's monitor mutes; master scales the whole callback output, editor bank included. The full mix / PCM hash / goldens never hear any of it |
| `pal.x_snd_dev_tap()` | dev/test | API v19: the last device-pushed sim frame's PCM (the full mix through mutes + category gains, pre-master) — equals `x_snd_tap` under a neutral policy; the headless KAT seam for the gain math |
| `pal.x_display_size()` → `dw,dh` or `nil` | render/dev | API v19: desktop size of the display the window occupies — the options menu derives window-size candidates that fit the screen; nil when SDL has no display (callers keep a static fallback) |
| `pal.watch_add(path)` | dev | crash-parachute reload list |

### PAL API v2 additions (M1)

| fn | class | notes |
| --- | --- | --- |
| `pal.draw_quads(tex, buf, count [,byte_off])` | render | bulk path: `count` quads of 12 f32 LE (`x,y,w,h, u0,v0,u1,v1, r,g,b,a`, colors 0..1 clamped, same rounding as `pal.quad`) from a buffer view; camera/clip apply. Layout **frozen** |
| `pal.png_read(bytes)` | dev/asset | decode PNG (vendored stb) → `pixels, w, h` (RGBA8); `nil, err` on failure |
| `pal.hash(s)` | sim | fnv1a-64 of a string (same fn as `buf:hash()`); content addressing for code bundles |
| `pal.buf_delta1(prev, cur)` | sim | **versioned kernel** (contract rule 4): sparse XOR delta of two equal-size views. Format frozen: runs of `{u32 off LE, u32 len LE, len XOR bytes}`; a run ends at the last differing byte followed by ≥8 equal bytes; `""` = identical |
| `pal.buf_apply_delta1(view, delta)` | sim | XOR runs into view (self-inverse: applying twice undoes); errors on malformed/OOB runs |
| `pal.exit_on_error(b)` | dev | when set, a Lua error exits the process with code 1 instead of parachuting (capped runs, golden verify) |
| `pal.quitting()` | dev | true once quit was requested — cm.main flushes recordings on any quit path |

### PAL API v3 additions (M2)

| fn | class | notes |
| --- | --- | --- |
| `pal.log_lines(after_seq)` | dev | ring of the last 256 `pal.log` lines (C-owned: survives VM reboots, so boot/parachute errors reach the console). Returns `{seq=,t=,text=}` entries newer than `after_seq`, oldest first; a gap (first seq > after_seq+1) means the ring overwrote under flood |
| `pal.text_input(on)` | dev | enable/disable text events (SDL text input: layout + IME aware). Headless no-op |
| event `{type="text", text=utf8}` | input | delivered between key events while text input is on; long IME commits split at utf-8 boundaries (≤39 bytes/event) |
| `pal.frame_stats()` | dev | `{quads, segs, vbytes}` from the last present + live `{textures, bufs, buf_bytes}` counts |

### PAL API v4 additions (M6)

| fn | class | notes |
| --- | --- | --- |
| `pal.watch_mtime(path)` | dev | cached mtime of a watched path, refreshed by a background **file-watcher thread** (spawned lazily on first call, live sessions only). The hot-reload poll uses this so it never stats on the main thread — that caused rhythmic frame spikes over a slow FS (WSL 9p / drvfs). Falls back to a direct stat for an unwatched path. Never sim state |

The watcher thread (`pal/src/main.c`) stats the append-only `pal.watch_add`
list off-thread and caches each `cur_mtime` under a mutex; `cm.reload` reads
`pal.watch_mtime` instead of `pal.mtime`. It is dev-only and spawns only when
the reload poll runs (never in capped/verify runs, so determinism is
untouched). The crash parachute keeps its own inline stat (error-state only),
so reboot-on-edit still works even when the thread never started (e.g. a
boot-time engine crash).

### PAL API v5 additions (M8 — viewport, D036)

The viewport surface: a **variable game FOV** + a **two-target composite** (game
viewport + a separate editor/UI canvas at its own scale). All born in the `x_`
experimental namespace (contract rule 3; pre-1.0 the shapes can still move).
Every entry is render/dev class — **the sim never reads window/FOV/viewport**
(D036 iron rule), so nothing here is recorded or snapshotted, and headless /
verify runs never call them (the engine drives them live-only), keeping the
golden suite + determinism untouched.

| fn | class | notes |
| --- | --- | --- |
| `pal.x_window_size()` | render/dev | real swapchain px `sw,sh`, cached each present (headless: the created `w*scale`). The resize ladder (cm.view) reads this |
| `pal.x_fov(w,h)` → `w,h` | render/dev | resize the game internal target — the **variable FOV** (visible world in internal px). Grows the readback buffer if needed; no-op if unchanged. Flows into `gfx_size`/scene projection/`read_pixels`. The 480×270 policy cap lives in Lua, not here |
| `pal.x_set_window_size(w,h)` | render/dev | resize the OS window (windowed only; live-only, headless no-op) — for the options menu |
| `pal.x_set_fullscreen(on)` | render/dev | borderless-desktop fullscreen / windowed (mode NULL → OS res untouched; live-only) |
| `pal.x_ui_target(w,h)` → `w,h` | render/dev | create/resize the **editor/UI canvas** (the second target). `w==0\|\|h==0` frees it (no ui layer = shipped game) |
| `pal.x_target("game"\|"ui")` | render | route subsequent quads to a target; every `begin_frame` resets to `"game"`. Segments carry a target id; one shared vertex buffer, two filtered scene passes |
| `pal.x_compose{x,y,scale,ui_scale}` | render/dev | define the present composite: the game target blits to `(x,y)` at integer `scale`; if `ui_scale>0` and a ui target exists, the ui canvas blits over the whole window at that integer scale, alpha-over the game. `pal.x_compose()` (no arg) → centered letterbox, no ui layer |
| `pal.x_capture(w,h)` | render/dev | enable an offscreen capture target sized `w×h`; present composites into it instead of a swapchain (`0,0` frees + disables). Lets a headless `--shot` capture the editor-around-game composite that otherwise lives only in the window |
| `pal.x_capture_read()` → `pixels,w,h` | dev/test | the capture target as RGBA8 (top-left, tight), post-present |
| event `ui_x,ui_y` (motion/button) | input | the ui-canvas-space mouse, alongside game-space `x,y`. The editor chrome hit-tests `ui_x/ui_y`; the world overlay + the recorded sim mouse stay `x,y` |

### PAL API v6 additions (M10 — render-only 2D compositor primitives)

The studio composited / cleared / re-uploaded large images with per-pixel Lua
loops, which made half-1080p editing crawl (an ~800 ms recomposite per stroke).
These three C primitives move that bulk pixel work into one call each. They are
**render/dev class** (the studio is render-only, D040) but the blend math is the
exact integer source-over of `cm.paint.over`, so a C-accelerated composite/bake
is **byte-identical** to the old Lua — the baked `.png` the game loads, and the
selftest KATs, do not shift. Reusable engine-wide (any 2D blit/clear/dynamic
texture), not editor-specific.

| fn | class | notes |
| --- | --- | --- |
| `pal.blit32(dst,dw,dh, dx,dy, src,sw,sh, sx,sy, w,h, mode [,op])` | render | clipped RGBA8 rectangular blit between two `pal.buf`s. mode 0 copy / 1 src-over (== `cm.paint.over`) / 2 stamp (copy where srcA≠0); `op` 0..255 scales source alpha (per-layer opacity). Clips the window to **both** buffers; the one reusable compositor (layer flatten, bake, brush, paste, resize) |
| `buf:fill32(byte_off, count, value)` | sim | write `count` native-endian u32s (a 32-bit `:fill`); `byte_off` 4-aligned. Clears / solid-fills an image in one call |
| `pal.tex_update(id, buf, w, h)` → bool | render | re-upload pixels straight from a `pal.buf` into an existing same-size texture in place (no GPU realloc, no Lua-string copy). Returns false if the slot is free or the size differs — caller then `tex_free` + `tex_create` |

`present()` is factored into `scene_pass(target,id,clear)` (game → game target,
opaque clear; ui segs → ui canvas, transparent clear so the viewport shows
through) + `blit_layer()` (each target → its window rect). The blit pipeline is
alpha-blended; the game layer is opaque so it composites unchanged. The window
→ game-viewport → FOV mouse map (`G.lay_*`) is set by the composite each present.
See **D039** for the two-target rationale and **cm.view** for the resize ladder.

### PAL API v7 additions (REVAMP R2 — the imgui host, D049)

v7 is the revamp-era baseline: the PAL grows its one C++ TU (`pal/src/ig.cpp`)
hosting **Dear ImGui 1.92.4** (vendored, SDL3 + SDLGPU3 backends) as a third,
topmost render layer at **native window resolution** — above the game target
and the ui canvas, straight into the present pass. Full design + the
one-UI-philosophy containment rules: **docs/IMGUI.md**; the living reference
cartridge is `projects/igcanvas`. No existing name changed semantics — the
break R2 blesses turned out to be purely additive, and every pre-v7 golden
replays byte-exact.

The whole `x_ig_*` surface is **render/dev, live windowed + `--win` capture
only**: in plain headless / `--verify`, `x_ig_frame` returns nil and every
other call is a safe no-op (selftest pins this), so imgui can never touch the
deterministic machine. Coordinates are window px; colors `0xRRGGBBAA`.

| fn | class | notes |
| --- | --- | --- |
| `pal.x_ig_frame()` → nil \| `{mouse,kb,text,dpi,w,h}` | render/dev | begin the imgui frame (lazy init). nil = unavailable. The flags = imgui wants that input this frame; Lua policy filters what the game sees |
| `pal.x_ig_line/rect/rect_fill/circle/circle_fill(…)` | render/dev | drawlist primitives (stroke thickness, corner rounding) |
| `pal.x_ig_poly(pts,rgba[,thick,closed])` / `x_ig_poly_fill` | render/dev | flat `{x1,y1,…}` array; polyline / filled convex poly |
| `pal.x_ig_text(x,y,px,rgba,text[,font,wrap_w])` | render/dev | text at ANY px: rasters ≤320 px (bounded atlas), vertex-scales above — crisp at every zoom. `font` 0 = Inter, 1 = JetBrains Mono (`pal/vendor/fonts/`) |
| `pal.x_ig_text_size(text,px[,font,wrap_w])` → w,h | render/dev | measurement (nil while unavailable) |
| `pal.x_ig_image(tex,x,y,w,h[,uv…,rgba])` | render/dev | a PAL texture on the drawlist; `tex == -1` = the game internal target (the live-game canvas window) |
| `pal.x_ig_clip_push(x,y,w,h)` / `x_ig_clip_pop()` | render/dev | drawlist clip stack |
| `pal.x_ig_overlay(on)` | render/dev | route subsequent drawlist calls to the foreground layer (above widgets — HUD pills); off = background (under widgets) |
| `pal.x_ig_mouse(on)` | render/dev | gate mouse events to imgui (default on; the R3 ALT layer turns it off so widgets render unchanged but never take the pointer) |
| `pal.x_ig_edit{id,x,y,w,h,text,px[,font,readonly,multiline]}` → text,changed,active | render/dev | the hard widget: imgui text editing at an explicit rect. Host keeps a per-id buffer; `text` re-syncs it while not active; chrome stays the caller's |
| `pal.x_clipboard([s])` → s | dev | OS clipboard get/set (plain SDL; "" headless) |
| `pal.gfx_init{…, maximized}` | — | open the window maximized (the editor-session shape; policy in Lua/project.lua) |
| event `wx,wy` (motion/button) | input | raw window px alongside game `x,y` + ui `ui_x,ui_y`; cm.ui keeps them on `inp.wx/wy` |
| `pal.x_compose{scale=0,…}` | render/dev | scale 0 = don't blit the game layer (the ig canvas draws the target itself via `x_ig_image(-1)`) |
| `pal.x_file_append(path,bytes)` → bool | file I/O | append (create if missing) — the R3 undo journals' primitive (D050); portable SDL_IOStream |

R3 (D050, docs/EDITOR.md) rides v7 additively with `x_file_append` and
reserves the **`ed.` named-buffer prefix** as the editor state domain:
cm.state snapshots/restores and cm.trace recordings **exclude** `ed.*`
buffers (selftest-pinned) — the editor's captured state (cm.ed.doc +
future `ed.*` buffers) is delta-able by R6 rewind without ever entering
the sim's determinism domain.

The cosmic3d merge (D114) adds a second excluded prefix on the same
mechanism (D3D-012): **`rc.` is the render-class domain** — named buffers
holding bytes only the renderer ever reads (baked terrain-chunk vertex
streams, the per-tile terrain atlas's pixels, figure→sprite-sheet
texture-id registries, per-frame draw scratch). `cm.state.sim_buffer`
returns false for both `ed.*` and `rc.*`, so neither enters a snapshot or
a `cm.trace` recording, and sim code must never read an `rc.*` buffer.
That split is what lets the streaming-world demo page thousands of
terrain chunks into `rc.*` buffers, and the RO demo bake its 1088² terrain
atlas a few tiles per frame, while a golden trace — which pins only the
player/entity *sim* buffers — stays byte-identical under any chunk radius
or bake budget (D3D-025).

cm.view grows **`mode = "canvas"`** (the ig-canvas session): full-window ui
canvas for the legacy dev chrome (which renders UNDER the ig layer until
R3/R4 re-host it), `x_compose{scale=0}`, game FOV stays the project's fixed
size. The classic ladder/two-target model is unchanged for play mode and
shipped games (960×540 default window, fullscreen = upscale — the blessed
launcher shape).

### PAL API v11 additions (A2 diagnostics — D067)

`pal.user_path()` is the one engine-wide per-user writable root. Its fixed SDL
organization/application pair is compatibility state and must not change;
engine modules namespace beneath it. Live interactive processes expose
`pal.diagnostics_dir` and `pal.log_path` and flush every PAL log line to a
unique UTC/PID file. `--frames` and `--verify` do not create diagnostic files.
This is observer/dev state only and never enters snapshots, traces, or sim
logic. `cm.crash` builds the versioned `CCRP` report codec and atomic publisher
above this primitive; `docs/REWIND.md` §16 freezes its A7 locator envelope.

### PAL API v12 additions (A2 player identity — D070)

`pal.x_window_icon(png_bytes)` decodes RGBA through the PAL's existing stb
boundary and applies the resulting SDL surface to the live OS window. It
returns `true` or `nil,error`; headless calls still decode and validate so CI
does not silently bless different bytes. This is observer/render state only.
`cm.main` calls it after every project boot/switch, using the project-local
`icon` path when safe and the carried canonical cosmic2d PNG otherwise, so a
surviving picker window never retains the previous project's icon.

### PAL API v20 additions (the cosmic3d merge — retro-3D pipeline, D114)

The retro-3D triangle pipeline lands additively beside the 2D quad
renderer (docs/COSMIC3D.md §2); a pure-2D frame never touches it, so its
bytes are byte-identical. All four primitives are render/dev — the sim
never reads any of them (D036).

- `pal.x_view3d{ mvp={m0..m15}, fog_start=, fog_end=, fog={r,g,b}, fog_on= }`
  appends one 3D camera/fog setup for subsequent `x_tris` calls; `mvp` is a
  column-major `proj*view*model` (matrix and lighting policy stay in Lua —
  the PAL is a dumb consumer, vertex colors arrive pre-lit). No-arg =
  identity mvp + fog off (the sky pass's NDC passthrough). Up to
  `PAL_MAX_VIEW3D` (64) views per frame; segments bind the latest at call
  time.
- `pal.x_tris(tex, buf, count[, off[, flags]])` draws `count` triangles of
  3 packed verts (24 B each: xyz f32, uv f32, rgba u8x4 pre-lit) from a
  buffer view at byte `off`, under the latest `x_view3d`. `flags`:
  1 = alpha-test cutout, 2 = nearest (default three-point), 4 = alpha blend
  + no depth write (decals).
- `pal.x_grade{…, quant= }` gains a `quant` field: bits per channel
  (0 = off), a Bayer-4 dithered quantize after the grade — `quant=5` is the
  retro 5551-framebuffer look. The grade is a post-pass baked INTO the
  internal game target before readback + composite, so a headless `--shot`
  and the pixel goldens see it (unchanged from D036: still never sim).
- `pal.x_soft(on)` is VI-soft presentation: the game-target blit resamples
  bilinearly with a mild one-dest-pixel horizontal smear (the N64 preset's
  adopted default look). It touches only the composite blit — the internal
  target that readback and the pixel goldens see is untouched. Reset every
  `begin_frame` like the grade.

### PAL API v21 additions (relative mouse — D116)

`pal.x_mouse_capture(on) -> captured` enters/leaves SDL relative-mouse mode
(the captured-cursor look): the OS cursor hides and stops moving while
motion events keep delivering real `rx/ry` game-pixel deltas. No-arg queries
without changing. It is live-side chrome policy — a headless run has no
window and stays uncaptured. Motion events carry the per-frame relative
delta; the recorded, sim-legal form is the MREL input-record extension
(tag 2), so **sim code reads `cm.input.mouse_rel()`, never this capture
state.** Additive: a v1 recording with no MREL replays as (0,0), so every
historical trace is unaffected.

### PAL API v22 additions (baked figures — D117)

`pal.x_figverts(blob, nv, xf, nxf, sun, ambient, col[, alpha]) -> bytes`
runs the baked-figure transform+light+pack loop (the `cm.gb.emit_baked`
inner loop) in C: `blob` is 64 bytes per vertex of packed doubles
(`lx,ly,lz, nlx,nly,nlz, u,v`, built once at bake time), and it returns `nv`
24-byte lit vertices ready for `x_tris`. Every operation mirrors the Lua
reference in double precision and expression order, so the output is
byte-IDENTICAL (pinned by a selftest KAT and the standing pixel goldens);
the Lua path stays the fallback when the primitive is absent. Render-class:
it reads only its arguments and owns nothing. Little-endian hosts only.

Everything else (snapshot save/load helpers, audio, kernels) lands in M2+ and
gets documented here when it does.
