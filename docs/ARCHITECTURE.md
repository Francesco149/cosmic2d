# pettan2d — architecture

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

1. `pettan [project_dir] [flags…]` — C parses nothing except `--help`; argv is
   handed to Lua as `pal.argv`.
2. PAL creates the Lua state, loads `engine/boot.lua`, calls `boot()`.
3. Lua reads `<project>/project.lua` (plain Lua table: name, internal w/h,
   window scale, entry file, startup mode), calls `pal.gfx_init{…}`, requires
   the project entry.
4. C loop: each iteration calls the global `pt_tick()` under `pcall`.
   Lua decides everything inside the tick (sim steps, drawing, reload polls).

### Error containment (no typo death spirals)

- The C loop pcalls the tick. On error: the traceback goes to the log, the
  PAL enters **error state** — it keeps the window alive, shows the failure
  (magenta clear + message in M0; routed into the console UI from M2), and
  polls the watch list (`pal.watch_add`ed files) every 250 ms.
- When a watched file changes, the PAL **reboots the Lua VM from scratch**.
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
   not persistent, not snapshot.
2. **The doc tree** — one Lua table of plain data (tables/numbers/strings/
   booleans, no functions/userdata) for irregular state: entity definitions,
   knob values, inventory-ish data. Serialized canonically (sorted keys) by
   the engine for snapshots and hashing. Convenient but slower — bulk data
   belongs in buffers.

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

Rewind = snapshot ring (every N frames) + input trace replay from the
nearest snapshot to the exact target frame — emulator-style, and it makes
the timeline scrubber cheap.

Cosmetic state (particles, camera shake) is still deterministic sim state —
pixel goldens depend on it. "Cosmetic" only means the game rules don't read it.

## Determinism (iron rules)

The sim must produce bit-identical state given the same initial snapshot and
input trace — across runs, machines, and eventually platforms.

- Fixed timestep: 60 sim frames/sec, integer frame counter. Rendering may
  interpolate later; the sim never sees wall-clock time.
- All randomness from the engine PRNG (xoshiro-family, state in a named
  buffer). `math.random`/`os.time`/`os.clock` are **banned in sim code**
  (engine/editor convenience code may use them; never inside `sim_step`).
- No libm transcendentals in sim paths: `pt.math` provides sin/cos/atan2/etc
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

**Testing** (M1+): a golden trace = initial snapshot + input trace + per-frame
(or checkpoint) state hashes. The runner replays headless and diffs hashes;
first divergent frame is reported and openable in the timeline scrubber.
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
window. The engine folds them into **actions** via the rebindable action map
(project + user bindings); the sim reads actions only. Gamepad later = new
event types + map entries, zero sim changes.

## Audio (M6 sketch, kept in mind from day one)

PAL owns the audio device and the FM voice inner loop (C, deterministic);
Lua owns patches, sequencing, and mixing decisions. Voice state lives in a
named buffer. The sim emits timestamped commands; the audio thread renders
ahead by a small fixed latency. Replays regenerate identical PCM.

## Directory layout

```
pettan2d/
  CLAUDE.md            agent orientation (session-start checklist)
  README.md  LICENSE  flake.nix
  docs/                PLAN, ARCHITECTURE, DECISIONS, PROCESS, STATUS
  pal/
    src/               C11 sources (main, gfx, lua bindings, buf, fs)
    vendor/            lua-5.4.x (patched seed), stb headers
    shaders/           *.vert/*.frag GLSL + committed *.spv
    Makefile
  engine/              Lua engine (boot.lua entry; ui/, editor/ inside)
  projects/
    sandbox/           the stock cartridge (project.lua + main.lua + assets)
  tools/               dev scripts (golden runner, font bake, feed helpers)
  tests/               traces/ + goldens/
  bin/                 built PAL binaries (gitignored until release packaging)
```

The repo root **is** the self-contained environment ("the console"). Sharing
a game = zipping this folder. `projects/` holds cartridges; a config picks the
startup project + mode for end-user shipping.

## Conventions

- C: C11, `-Wall -Wextra`, prefix `pal_`, no global mutable state outside the
  PAL context struct (the buffer registry lives there too).
- Lua: engine namespace `pt` (e.g. `pt.gfx`, `pt.state`, `pt.ui`); modules
  loaded through the engine's own loader (reload-aware, project-jailed
  paths, forward slashes everywhere).
- The PAL Lua API (`pal.*`) is the **porting contract**: keep it small,
  document every function's semantics + determinism class
  (sim-safe / render-only / dev-only) in this file as it grows.

### PAL API v0 (M0 scope)

| fn | class | notes |
| --- | --- | --- |
| `pal.argv`, `pal.platform` | dev | argv after binary name; "linux"/"windows" |
| `pal.log(s)` | dev | timestamped stderr + ring buffer for console |
| `pal.time_ns()` | render-only | monotonic; **never** in sim logic |
| `pal.sleep_ms(n)` | dev | paces interactive headless sessions |
| `pal.quit()` | — | request loop exit |
| `pal.gfx_init{w,h,scale,title,headless,vsync}` | — | once at boot |
| `pal.begin_frame(r,g,b,a)` | render | clear internal target, reset batch |
| `pal.quad(x,y,w,h, r,g,b,a [,tex,u0,v0,u1,v1])` | render | pixels, top-left origin |
| `pal.clip(x,y,w,h)` / `pal.clip()` | render | scissor on internal target |
| `pal.camera(x,y)` | render | subtracted from subsequent quads |
| `pal.present()` | render | upload, render, scale-blit, (headless: render only) |
| `pal.read_pixels()` | dev/test | internal target → string (RGBA8), post-render |
| `pal.png_write(path, str, w, h)` | dev | screenshot/golden output |
| `pal.tex_create(w,h, pixels_str)` / `pal.tex_free(id)` | render | RGBA8; id 0 = builtin white |
| `pal.buf(name_or_nil, size)` | sim | named = persistent + snapshot; view userdata |
| `pal.buf_list()` | sim | iterate named buffers (snapshot/inspector) |
| buf views: `:u8/:u16/:i32/:u32/:f32/:f64(off [,v])`, `:fill`, `:copy`, `:hash`, `:size`, `:str(off,len)`, `:setstr(off,s)` | sim | bounds-checked, error on OOB |
| `pal.read_file(p)` / `pal.write_file(p,s)` / `pal.list_dir(p)` / `pal.mtime(p)` / `pal.mkdir(p)` | dev/io | engine enforces project-relative paths |
| `pal.poll_events()` | input | array of event tables, drained each tick |
| `pal.watch_add(path)` | dev | crash-parachute reload list |

Everything else (bulk draw, snapshot save/load helpers, audio, kernels) lands
in M1+ and gets documented here when it does.
