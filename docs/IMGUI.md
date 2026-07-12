# imgui in the binary — the R2 design (D049)

> The REVAMP §3.1 design doc for **R2 — platform layer revamp**: how Dear
> ImGui is hosted by the PAL, exactly what surface the scripting side gets,
> the new window model, and the C/C++ helper-layer convention. Binding ADR:
> **D049**. Prior art: `../teidraw` (imgui 1.92.4, the dynamic font atlas,
> the crisp-text-at-any-zoom trick) — cribbed deliberately throughout.

## 1. Why imgui, and why in the PAL

The R3+ editor is a teidraw-style infinite canvas with floating windows,
written in Lua. Two ingredients of that are miserable to hand-roll and add
zero creative value: **scalable text** (rasterization, kerning, wrapping,
clipping, atlas management — at arbitrary zoom) and **text editing**
(caret/selection/undo/IME across platforms). Dear ImGui ≥ 1.92 solves both
(the dynamic font atlas rasterizes any glyph at any pixel size on demand),
teidraw proves the exact feel we want is buildable on it, and its SDL3 +
SDL_GPU backends drop into the renderer we already have.

The engine's own cm.ui (the chunky pixel-art immediate-mode chrome) stays
what it is: the in-game/dev overlay at integer scale. imgui is a different
tool for a different job — native-resolution editor content.

## 2. The split — one UI philosophy (the §8 risk, addressed first)

The iron rule: **imgui is machinery inside the PAL, not a UI philosophy in
the engine.** The scripting side never sees "an imgui"; it sees a
native-resolution drawlist plus a small set of hard widgets. Concretely:

**Exposed** (the whole surface, §5):

- a **screen-space drawlist** — shapes, text at any pixel size, images,
  clip rects. The editor canvas renders *through* this, exactly like
  teidraw renders its canvas through ImDrawList.
- **hard widgets** placed at explicit rects: multiline text editing (the
  code-ed foundation). That's it for v1.
- **frame gate + capture flags** (`want mouse/kb/text`) + queries (text
  measurement, DPI scale, clipboard).

**Not exposed, ever**: `ImGui::Begin/End` windows, docking, menus, popups,
tables, the layout/cursor system, imgui styling, imgui IDs for anything but
widget instances, `.ini` persistence (host sets `io.IniFilename = NULL` —
layout persistence is the engine's job, R3's unsaved-persists model).
Floating windows, title-bar-less chrome, the ALT interaction grammar,
bring-to-front, edge resize — all of that is Lua drawing rects and text on
the drawlist and hit-testing events, same as cm.ui does today, same as
teidraw does with its own shapes.

The review test for every future addition (REVAMP §8): *could teidraw's
feel be built on this surface without the addition leaking imgui policy?*
teidraw itself is drawlist + one text-editor overlay + capture flags — so
the answer stays yes while the surface stays that shape.

Widgets take explicit rects (the host wraps them in one invisible
fullscreen host window and `SetCursorScreenPos`), matching cm.ui's
`opts.rect` idiom — no flow layout crosses the boundary.

## 3. Hosting architecture

### The pieces

- **Vendored imgui 1.92.4** in `pal/vendor/imgui/` (same pin as teidraw):
  core (`imgui.cpp/_draw/_tables/_widgets`, headers, `imstb_*`),
  `backends/imgui_impl_sdl3.*`, `backends/imgui_impl_sdlgpu3.*`,
  `misc/cpp/imgui_stdlib.*`, `LICENSE.txt`. No `imgui_demo.cpp`
  (`IMGUI_DISABLE_DEMO_WINDOWS`).
- **One C++ TU**: `pal/src/ig.cpp` (C++17) — hosts the context + both
  backends behind an `extern "C"` interface (`pal_ig_*`, declared in
  pal.h). imgui types never cross into C or Lua. Everything else in the
  PAL stays C11 (§7).
- **Fonts** in `pal/vendor/fonts/`: `InterVariable.ttf` (UI/sans) +
  `JetBrainsMono-Regular.ttf` (code) + their OFL licenses — teidraw's
  taste-approved picks. Loaded at ig init with size 0 (deferred
  rasterization; the dynamic atlas owns sizing). Spleen remains the
  in-game bitmap font; these are editor-content fonts.

### Lifecycle (live windowed session)

```
pump_events (C)      SDL events → PAL queue, AND → ImGui_ImplSDL3_ProcessEvent
                     (only while ig is active — one-frame latency on the very
                     first frame, same class as cm.ui's capture latency)
cm_tick (Lua)        pal.x_ig_frame()  → lazy init, NewFrame, returns
                     {mouse=,kb=,text=,dpi=} capture flags — Lua policy
                     decides what the game/cm.ui still see
                     … pal.quad game/chrome draws + pal.x_ig_* content …
pal.present (C)      ImGui::Render → PrepareDrawData(cmd) → scene passes →
                     composite pass (game blit + ui blit) →
                     RenderDrawData into the SAME pass, last — imgui is
                     always the top layer, at native window resolution
```

- **Lazy + optional**: nothing initializes until the first
  `pal.x_ig_frame()`. A session that never calls it pays nothing.
- If a frame was begun but present never ran (error mid-tick), the next
  `x_ig_frame` discards the orphan (`EndFrame`) before starting — no
  assert spiral; the parachute stays clean.
- The SDL3 platform backend owns imgui's DeltaTime/DisplaySize/IME from
  the real window. It also starts/stops SDL text input from
  `io.WantTextInput`; a legacy `pal.text_input` user (console) active in
  the same frame as an ig edit widget is a documented conflict to avoid
  in engine code (they live in different modes anyway).

### Headless capture (the agent's visual loop)

Goldens never see imgui (§8), but the R3+ editor work needs headless
screenshots. The existing `--win WxH` composite capture extends to ig:
in capture mode the host runs **without** the SDL3 platform backend
(no window) — `io.DisplaySize` is set from the capture size,
`io.DeltaTime` fixed at 1/60, no input — and renders into the capture
target (UNORM pipeline). So `bin/cosmic projects/igcanvas --win 1280x800
--frames 30 --shot x.png` shows the real canvas. Plain `--headless`
(no `--win`) keeps `x_ig_frame` returning nil.

The sdlgpu3 pipeline is built once for the format ig first rendered to
(swapchain when windowed, UNORM in capture). If a later present targets a
different format (live session toggling `x_capture`), ig skips that frame
with one log line rather than binding a mismatched pipeline.

## 4. Crisp text at any zoom (the teidraw trick, as mechanism)

imgui ≥ 1.92 rasterizes glyphs at any requested size into a dynamically
grown atlas (`RendererHasTextures`; the sdlgpu3 backend honors texture
update requests during render). Unbounded zoom would grow it without
limit, so the host applies teidraw's trick inside `x_ig_text`: raster size
is capped (`min(px, 320)`); above the cap, glyphs are drawn at 320 and the
emitted vertices are scaled up around the anchor. Lua just asks for any
pixel size — `world_px * zoom` — and never knows. Below the cap text is
pixel-perfect; above it (rare: zoomed way in) it magnifies smoothly.

## 5. The Lua surface — PAL API v7 (`x_` namespace, all render/dev)

Determinism class for the whole table: **render/dev, live + `--win`
capture only** — never sim-readable, never recorded, never in
`--verify`/plain-headless (there `x_ig_frame` returns nil and every other
`x_ig_*` is a safe no-op). Coordinates are **window pixels** (native
resolution, top-left origin), colors are `0xRRGGBBAA` u32 like `pal.quad`'s
byte convention. Calls outside an open ig frame are no-ops.

| fn | notes |
| --- | --- |
| `pal.x_ig_frame()` → nil \| `{mouse,kb,text,dpi,w,h}` | begin the imgui frame (lazy init). nil = unavailable (headless without `--win`). `mouse/kb/text` = imgui wants that input this frame (Lua filters what the game sees); `dpi` = display scale; `w,h` = the surface px the drawlist targets |
| `pal.x_ig_line(x0,y0,x1,y1,rgba[,thick])` | drawlist polyline segment |
| `pal.x_ig_rect(x,y,w,h,rgba[,thick,round])` / `x_ig_rect_fill(x,y,w,h,rgba[,round])` | stroked / filled rect, optional corner rounding |
| `pal.x_ig_circle(cx,cy,r,rgba[,thick])` / `x_ig_circle_fill(cx,cy,r,rgba)` | stroked / filled circle |
| `pal.x_ig_poly(pts,rgba[,thick,closed])` / `x_ig_poly_fill(pts,rgba)` | flat array `{x1,y1,x2,y2,…}`; stroked polyline (ink strokes, arrows) / filled convex poly |
| `pal.x_ig_text(x,y,px,rgba,text[,font,wrap_w])` | text at any pixel size (the §4 cap+scale trick). `font`: 0 = sans (default), 1 = mono |
| `pal.x_ig_text_size(text,px[,font,wrap_w])` → w,h | measurement (valid any time after init) |
| `pal.x_ig_image(tex,x,y,w,h[,u0,v0,u1,v1,rgba])` | draw a PAL texture on the drawlist; `tex == -1` = **the game internal target** (the live-game-window preview). **Samples NEAREST** (the pixel-art contract, R8d: sprites/tiles/the game target never blur — no seams between atlas tiles, exact 2x game pixels); fonts + AA shape fringes keep the backend's linear sampler via lazy per-drawlist switch callbacks |
| `pal.x_ig_clip_push(x,y,w,h)` / `pal.x_ig_clip_pop()` | drawlist clip stack (window content clipping) |
| `pal.x_ig_edit{id,x,y,w,h,text,px[,font,readonly,multiline]}` → text,changed,active | the hard widget: imgui text editing (caret/selection/undo/IME) at an explicit rect. The host keeps a per-`id` buffer; `text` re-syncs it whenever the widget is not active (external reload wins); returns the buffer + a changed flag + focus state. Chrome-less styling — frame/scrollbar drawing stays ours |
| `pal.x_clipboard([s])` → s | OS clipboard get/set (plain SDL, no imgui needed; the code-ed/canvas paste path) |
| `pal.x_ig_mouse(on)` | gate mouse input to imgui (default on). The R3 shell turns it off while ALT is held: widgets render unchanged but hover/click/wheel never reach them — the §11 "filter in C behind Lua-set flags" fix, realized. Off-transition parks the pointer + releases buttons |
| `pal.x_ig_event(e)` → bool | feed one pal-shaped event table (motion/button/wheel/text/key) into the imgui io — **capture mode only** (windowed no-ops: the SDL3 backend already forwards real events). The R8e proof-tape hook: a scripted driver that injects a synthetic tape into `pal.poll_events` mirrors the same events here, so `x_ig_edit` fields (inspector text, path fields) are tape-drivable in `--win` captures like everything else. Mouse events honor the `x_ig_mouse` gate; keys map a small scancode set (letters, digits, enter/backspace/tab/home/end/del/arrows, mods) |

Additive non-ig v7 entries riding the same bump:

| fn | notes |
| --- | --- |
| `pal.gfx_init{…, maximized=bool}` | create the window maximized (the editor session shape). Policy — who boots maximized — lives in Lua (project.lua / the R5 launcher) |
| event `wx,wy` (motion/button) | raw window-px mouse alongside game `x,y` + ui-canvas `ui_x,ui_y` — what Lua hit-tests ig-canvas content with |
| `pal.x_compose{scale=0,…}` | `scale=0` now means *don't blit the game layer* (previously invalid). The R3 editor draws the game target itself via `x_ig_image(-1,…)`; the blit would double it |

Everything is born `x_` (contract rule 3). Promotion to `pal.ig_*` is the
freeze event, expected around the time the R3/R4 editor stabilizes the
surface.

## 6. The window model (what R2 changes, what survives)

- **Game / launcher sessions — unchanged and now blessed**: default window
  = `internal 480×270 × window_scale 2` = **960×540** (the board's
  half-1080p), resizable; **fullscreen = upscale** via the existing
  borderless toggle + cm.view ladder (M8/D036 survives intact as the
  play-mode + shipped-game model: max-of-fits integer scale, FOV capped at
  the 480×270 reference, sim never reads any of it).
- **Editor sessions — new**: a maximized resizable window
  (`gfx_init{maximized}`), imgui content at native resolution on top.
  Until R3 lands, the only maximized citizen is the igcanvas demo
  (its project.lua opts in); dev sessions on game projects keep today's
  shape (960×540 + F1 chrome).
- **The two-target composite survives** for the legacy dev chrome
  (console/perf/editor-v0/studio on the ui canvas). imgui is a third,
  topmost layer, native-res, not a target — it renders straight into the
  swapchain pass. During R3/R4 the legacy chrome migrates or dies
  (the F2 studio dies at R4, D046); cm.view's editor-inset branch goes
  with it. Nothing is removed in R2.
- **Mouse**: events now carry all three spaces — game FOV `x,y` (sim,
  recorded, unchanged), ui-canvas `ui_x,ui_y` (legacy chrome), window
  `wx,wy` (ig canvas). How the R3 editor synthesizes sim mouse coords for
  the game-as-canvas-window is R3/R4 design, not R2.

## 7. The C/C++ helper layer, formalized

The board's "portable C/C++ helpers • performance heavy lifting" box,
now with rules (ARCHITECTURE.md Conventions gets these):

- The PAL core stays **C11**. C++ (**C++17, `pal/src/*.cpp`**) is allowed
  for vendored C++ libraries and their host TUs; each exposes an
  `extern "C"` interface in a header; no C++ types, exceptions, or RTTI
  cross the boundary. imgui/ig.cpp is the first citizen.
- The numpy model is unchanged by language: perf kernels stay pure
  state-in/state-out over named buffers, versioned names (contract rule
  4), C or C++ alike.
- Link: `$(CC)` gains `-lstdc++` on Linux; the mingw cross build links
  `-static-libgcc -static-libstdc++` (self-contained exe, no new DLLs).

## 8. Determinism / goldens stance

- The entire ig surface is **render/dev**: the sim never reads it, nothing
  it does is recorded or snapshotted, and no golden contains imgui output
  — pixel goldens keep reading the **game internal target** only
  (`--headless --shot`), where ig never renders.
- `--verify` and plain `--headless` never initialize imgui at all.
- Font rasterization, atlas growth, imgui's wall-clock DeltaTime — all
  live only in the layer above the deterministic machine, exactly like
  cm.view/window state (D036 iron rule extends verbatim).
- selftest (headless) asserts the *absence contract*: `x_ig_frame()` nil,
  `x_ig_*` no-ops, `x_clipboard` safe.

## 9. Build integration

- `pal/Makefile`: `CXX` + `CXXFLAGS` (`-std=c++17`, imgui + vendor
  includes), imgui core/backends + `ig.cpp` object rules; link via `$(CC)`
  + `-lstdc++` (LDLIBS). imgui compiles with
  `IMGUI_DISABLE_OBSOLETE_FUNCTIONS`, `IMGUI_DISABLE_DEMO_WINDOWS`.
- `flake.nix`: `cosmic-windows` adds `-static-libstdc++` to LDFLAGS;
  nothing else — imgui + fonts are vendored, `src = self` stays hermetic.
- Binary growth: ~0.5–1 MB — accepted (D049); the PAL is still "small"
  in the ways that matter (surface, not bytes).

## 10. R2 build plan + exit

1. Vendor imgui + fonts; C++ toolchain in Makefile/flake; both builds link.
2. `ig.cpp`: context + backends + present integration + the font pair +
   the cap-and-scale text path; `x_ig_frame` + drawlist + text + images.
3. `x_ig_edit` + clipboard + `wx,wy` + `maximized` + `x_compose{scale=0}`.
4. `projects/igcanvas` — the living reference (like uigallery for cm.ui):
   pan/zoom infinite canvas fully in Lua on the drawlist, crisp text at
   every zoom, a text-edit widget, the live game target drawn as an image.
5. Headless-capture ig path; selftest absence KATs; goldens re-verified
   untouched; captures → llm-feed.

**Exit (REVAMP §6 R2)**: the script-driven hello-canvas runs at display
refresh, windowed + fullscreen both behave on the game window model,
`nix run .#test` green with no golden regenerated, windows cross build
clean.

## 11. Traps / watch list

- **Surface creep** — every proposed `x_ig_*` addition re-runs the §2
  test; widgets that imply imgui layout/styling are rejected on shape.
- **Event capture latency** — ig sees events one pump ahead of Lua's
  filter decision; same one-frame class as cm.ui. If it ever bites, the
  fix is filtering in C behind Lua-set flags, not exposing imgui's IO.
- **Atlas growth** — the 320 px cap bounds it; watch `frame_stats`-style
  counters if long editor sessions balloon (add an ig stats query then).
- **Text-input tug-of-war** — the SDL3 backend vs `pal.text_input` (§3);
  keep legacy text fields and ig edits out of the same frame.
- **WSLg** — the wayland socket flakes (STATUS 2026-07-03); the `--win`
  capture path is the reliable proof medium, the live window the feel
  check.
