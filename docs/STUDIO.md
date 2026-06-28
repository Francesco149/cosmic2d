# the studio — in-engine sprite & animation editor (M10)

The art-authoring tool that lives inside the console. This is M10's keystone:
GAME.md §10 requires it ("the in-engine sprite editor must comfortably author
character sprites and portraits with gradients"), and it is pulled ahead of M9
(audio) because **nothing in the world gets built until the human can author
assets in-engine**. The M10 exit criterion is concrete: *the human authors a
character sprite + a portrait in the studio*. So the bar is real authoring, not
a tech demo.

This doc is the studio design bible (what GAME.md is to the game). ARCHITECTURE
describes the engine it sits on; DECISIONS D040 is the binding ADR; PLAN M10 is
the roadmap slot.

> Terminology: **the studio** (`cm.studio`) is the *asset* editor — sprites,
> portraits, animations. It is NOT **the editor** (`cm.editor`, the F1 world/map
> editor). Two different tools; keep the names apart.

## 1. The one idea that makes this simple: assets are not sim state

The world editor (`cm.editor`) is hard because a tilemap *is* sim state: every
painted cell must route through `cm.repl` as a recorded EVAL so a trace replays
byte-exact (D022/D026). **The studio has none of that tax.**

A sprite's pixels are a **render-only asset**, exactly like a PNG or a baked
font: the game loads them at boot, and "file bytes are not sim input" (the same
rule that governs `map.dat`, `knobs.dat`, every `cm.gfx.texture`). Editing an
asset and the game consuming it are decoupled across the boot boundary, just
like editing source code. Therefore:

- The studio is **dev/render class** (the D021 family — like `cm.ui`,
  `cm.console`, `cm.inspect`). It owns **no** sim state, never touches named
  sim buffers / the doc tree / `cm.rand`, is **never recorded** into a trace,
  and never runs in `--verify` / capped-golden runs.
- It may use float math, `math.random` (dither scatter, noise), libm — none of
  it reaches the sim. (Editor convenience code is explicitly allowed
  non-determinism; the ban is on `sim_step`.)
- No EVAL plumbing, no determinism proofs, no golden churn. The studio is a
  **free creative app** bolted onto the console.

What *is* disciplined: the pure pixel rasterizers (`cm.paint`) are
deterministic functions (a line is a line), so selftest can pin them with KATs
— cheap insurance against a flood-fill or Bresenham regression, even though
nothing forces it.

## 2. Data flow: document → bake → game

```
   .spr  (editable source, studio only)          art/girl.spr
     │  layers · palette · frames · clips · gradient fills
     │
     ├── bake (flatten visible layers per frame → horizontal strip)
     │        └────────────────────────►  art/girl.png   (RGBA8 strip atlas)
     │                                     the game loads THIS (cm.gfx.texture)
     └── clips (frame sequences + timing) ─►  art/girl.anim  (canonical bytes)
                                              cm.sprite loads THIS
```

- **`.spr`** is the lossless editable truth. Only the studio reads/writes it.
- **`art/<name>.png`** is the baked horizontal strip — `frames` cells of `w×h`
  laid left-to-right, the **exact convention the game already draws** (see
  `player.lua` `build_sprite`, today a procedural strip). The game loads it
  through the unchanged `cm.gfx.texture` path. Zero engine change to consume.
- **`art/<name>.anim`** is the clip table (sequences + per-frame durations +
  loop modes) as canonical doc bytes (`cm.state.canon`, like `knobs.dat`). The
  runtime `cm.sprite` loader reads it; the deterministic `cm.anim` evaluator
  plays it (§7).

Per-project: assets live in `<project>/art/`. The sandbox gets
`projects/sandbox/art/`. Both `.spr` source and baked `.png`/`.anim` sit there;
the source travels in the repo, the baked outputs are the build product (and
can be regenerated from source by a headless `--bake` later).

## 3. The document model

The in-memory editing model (and the on-disk `.spr` mirror it):

```
Document
  name            string
  w, h            int     -- one frame's pixel size (the cell)
  frames          int     -- ≥1; columns in the baked strip
  palette         { rgba… }            -- working swatches (truecolor)
  layers[]        bottom→top draw order
      name        string
      opacity     0..255
      hidden      bool
      locked      bool
      blend       "normal"             -- v1; "add"/"multiply" later
      cells[f]    -- per frame: w*h RGBA8 pixels  (the actual art)
  clips[]         animation clips (§7)
      name, frames=[{frame, dur}], loop="loop"|"once|"pingpong"
  fills[]         non-destructive gradient fills (§6), each bound to a layer
  pivot           {x,y} per-doc anchor (later: per-frame)  -- in-game origin
```

**Pixel storage.** A cell is `w*h*4` bytes RGBA8. A 32×32 sprite × 11 frames ×
4 layers ≈ 180 KB; a 128×128 portrait × 4 layers ≈ 256 KB — all trivially small.
Cells live in a **dev-side (anonymous) `pal.buf`** so paint ops are in-place and
fast (no per-pixel Lua GC churn). Colors are **raw bytes, no sRGB** (D009) — the
picker and gradients operate on raw values, matching the engine's UNORM chain.

**Truecolor, with a palette as curated swatches** (D040): pixels are full RGBA,
not palette indices. The palette is a working set of swatches + named save
slots, not a hard index constraint — because gradients (the signature
technique, §6) need many colors and an indexed mode would fight them. (An
optional indexed/palette-swap mode can come later for those who want it; it is
not the default.)

**Undo/redo** reuses the PAL's frozen sparse-XOR codec: each stroke records a
`pal.buf_delta1(before, after)` of the touched cell; undo is `buf_apply_delta1`
(self-inverse). Structural ops (add/remove/reorder layer, resize, paste-commit)
push a coarse snapshot step instead. One stroke = one undo step (press→release),
not per-pixel. The stack is dev memory, capped at N steps.

## 4. The on-disk `.spr` format

Rides the existing tagged-container infra (`cm.chunk`: `<magic 4cc>` then
`<tag 4cc, u32 version, u32 len, payload>`, unknown chunks skippable — so the
format evolves forward-compatibly). Magic `CSPR`:

| chunk | holds |
| --- | --- |
| `HEAD` | w, h, frames, layer count, flags, pivot |
| `PALT` | the document palette (count + RGBA entries) |
| `LAYR` | one per layer: name, opacity, flags, then `frames` cells of pixels |
| `CLIP` | animation clips (names, sequences, durations, loop modes) |
| `FILL` | non-destructive gradient fill defs (§6) |
| `TAIL` | integrity check (layer/frame counts) |

v1 stores cells **raw RGBA8**. Pixel art is mostly transparent, so PNG-encoding
each cell (`pal.png_write`/`png_read` already exist) is a large, easy win — a
documented v2 upgrade behind a `LAYR` version bump, readers staying
back-compatible. This is engine/asset-class bytes (not a PAL primitive), so it
has more freedom than the trace format, but reusing `cm.chunk` keeps it
consistent and skip-tolerant.

## 5. The studio UX — a dedicated full-window mode

The studio is a **top-level dev mode** (D040): `F2` toggles it, it takes the
**whole window**, the sim **pauses** behind it (like the scrubber), and it
**captures all mouse + keyboard**. Real authoring wants maximum canvas and a
real panel layout; floating-over-the-game was rejected for that reason. It
draws on the **ui canvas** at `cfg.ui_scale` (the same surface the editor chrome
uses — D036/D039), reusing every `cm.ui` widget + the style table, so it fits
the existing chrome and honors the play-mode lockdown (`editor=false` ships
without it).

```
┌─ studio ───────────────────────────────  file▾ edit▾  girl.spr   browser ─┐
│T│                                                              │ LAYERS    │
│o│                                                              │ ◉ hair  ▣ │
│o│        ▓▓░░░░░░░░  the canvas  ░░░░░░░░▓▓                     │ ◉ suit  ▣ │
│l│        ░░  checkerboard transparency  ░░                     │ ◉ skin  ▣ │
│s│        ░░  composited layers @ integer zoom ░░               │ ◉ line  ▣ │
│ │        ░░  1px pixel-grid past 8×       ░░                    ├───────────┤
│✐│        ░░  hovered-cell highlight       ░░                   │ PALETTE   │
│⌫│        ░░                               ░░                    │ ▢▢▢▢▢▢▢▢  │
│▨│        ░░  pan: space-drag / MMB        ░░                    │ ▢▢▢▢▢▢▢▢  │
│╱│        ░░  zoom: wheel (cursor-anchored)░░                    │ slots:1234│
│▭│        ▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▓▓                     ├───────────┤
│◯│                                                              │ COLOR     │
│⬗│                                                              │ ┌───┐ hue │
│⊹│  ┌──┐ primary/secondary  (LMB / RMB)                        │ │HSV│ ▌   │
│✥│  │▓▓│  X swaps                                               │ └───┘ #hex │
├─┴──┴────────────────────────────────────────────────────────┴───────────┤
│ TIMELINE  ◧0 ◧1 ◧2 …  +frame  clips▾  ▶play  onion▢  fps12   px 14,7  6× │
└──────────────────────────────────────────────────────────────────────────┘
```

- **Left tool rail** — vertical icon buttons: pencil, eraser, bucket, line,
  rect, ellipse, gradient, eyedropper, select(marquee), move. Active tool lit.
  Below it: the **primary/secondary** color chips (MS-Paint model: LMB paints
  primary, RMB secondary; `X` swaps; eraser writes transparent).
- **Center canvas** — the dominant space. Checkerboard shows true transparency;
  visible layers composite to one texture (§8) drawn as a single scaled quad;
  a 1px grid fades in past a zoom threshold; the hovered pixel is outlined;
  a status corner shows pixel coords + zoom %.
- **Right dock** — stacked panels: **Layers** (visibility / opacity / lock,
  reorder, add / dup / delete, active layer lit), **Palette** (swatch grid +
  named save slots + "add current"), **Color** (HSV square + hue strip +
  hex/RGBA fields).
- **Bottom timeline** — the frame strip (per-frame thumbnails, select / add /
  dup / delete / reorder), clip selector, play / stop, onion-skin toggle, fps.
  (Animation is Phase 4; the strip is reserved from the start so the layout
  doesn't lurch when it lands.)
- **Top menubar** — file (new / open / save / save-as / export-png / bake),
  edit (undo / redo / cut / copy / paste / flip / rotate / scale), the asset
  name, the **browser** toggle.

**The asset browser** — an overlay grid of baked thumbnails scanned from
`<project>/art/`, with new / open / duplicate / delete. Click opens a doc.
Part of the MVP (you cannot author a second asset without it).

## 5.1 Usability traps we are deciding NOT to fall into

The user asked specifically to surface the things one overlooks. These are
load-bearing, not polish:

- **Cursor-anchored zoom.** The pixel under the cursor stays put as you wheel.
  Get this wrong and the tool feels broken; it is the single most-botched thing
  in homemade pixel editors.
- **Exact-match flood fill** (tolerance 0, 4-connected). Smooth/tolerant fills
  ruin pixel art — there is no "close enough" color.
- **No anti-aliasing, anywhere.** Every rasterizer is integer/nearest:
  Bresenham lines, midpoint ellipses, pixel-perfect curves. Matches the
  engine's nearest sampling and the explicit ask. "Curves" = clean stair-step
  pixel lines, never a smooth blend.
- **Transparent-aware everything.** Eraser = alpha 0. Brush stamps mask their
  transparent texels. Gradient-fill recolors only a layer's *visible* pixels
  (masked by existing alpha). The checkerboard never lies about transparency.
- **Temporary eyedropper on a held modifier** (alt) — pick a color without
  leaving the brush, then keep painting. A massive ergonomics win; cheap.
- **Shift constrains** — line to 45°, rect to square, ellipse to circle.
- **Live shape preview** — line/rect/ellipse/gradient preview while dragging,
  commit on release, show dimensions; nothing touches pixels until release.
- **Single-key tools + numbers pick swatches** — Aseprite-grade muscle memory
  (B pencil, E eraser, G fill, L line, …; `[`/`]` size; `X` swap). Shown in a
  hint line (the editor already has the idiom).
- **No accidental edits** — paint only when the cursor is over the canvas and a
  tool is armed; every panel captures its own mouse; press must *start* on the
  canvas to begin a stroke.
- **Don't lose work** — confirm before discarding an unsaved doc (new / open /
  close / quit). Autosave-recovery is a later nicety.
- **Selection restricts editing.** With a marquee active, pencil / eraser /
  bucket / shapes only touch the selected area (a write-clip in `cm.paint` honored
  by set / over / flood — composite / bake are never clipped). The marquee stays
  visible across tool switches so it reads as an active mask. `^D` clears it.
- **Paste never overwrites silently.** Paste lands on its **own new layer** (you
  position the float, it commits as a "paste" layer) — merge-down from the layers
  panel to flatten onto the layer below when you mean to.
- **Big-canvas perf** — never submit thousands of quads. Composite to one
  texture, re-upload only the dirty cell, draw one scaled quad (§8).

## 6. Gradients — the signature feature

GAME.md §10: "the most sophisticated technique is gradients (some lines and
fills are gradients)." This is the differentiator, so it is designed properly,
not as an afterthought.

- **Gradient tool**: drag an axis (start→end). Types: **linear**, **radial**
  (center + radius), **angular/conic**, **mirror**. Maps a **multi-stop ramp**
  (pulled from the palette or the two active colors).
- **Dithered, not smooth.** Pixel-art gradients are *ordered dithering* between
  bands, not a Photoshop blur. A dither **strength** + **Bayer pattern** so the
  result reads as pixel art. This is the technique the art direction actually
  wants. (Plain hard-band and smooth-as-possible are the endpoints of the same
  strength knob.)
- **Non-destructive fill** (the user's "tweak the gradient's type, center,
  phase, etc."). A gradient **fill** is an editable object living on a layer:
  `{ type, p0, p1 | center+radius+angle, stops[], dither, phase, layer }`. It
  re-renders whenever you drag its on-canvas handles or change the panel — type,
  center, endpoints, stops, dither, **phase** (slides the ramp along the axis).
  It is **masked by the layer's existing alpha** — "fill a layer's *visible*
  pixels with a gradient": draw the shape on a layer, gradient-fill it, then
  keep tuning the gradient forever. Bake flattens it; the `.spr` keeps it live.
- Destructive "stamp gradient to pixels" is the same math with no stored object,
  for when you want to paint over it afterward.

## 7. Animation — clips as data, a deterministic player

Two animation modes coexist (the second is new):

1. **State-driven** (today's model, kept): draw code selects a frame index from
   sim state (velocity, grounded). A pure function of sim state — deterministic,
   needs no timer. The moveset uses this; it stays the simplest path.
2. **Timed clips** (new): a named clip plays over time (idle breathing, an
   attack swing). A clip = `{ name, [{frame, dur_ticks}], loop }`.

**The determinism split** (mechanism vs policy, mirroring D030/D035): the engine
provides the **mechanism** — the clip data, the loader, and a **pure evaluator**
`cm.anim.frame_at(clip, elapsed_frames) → frame_index` plus a draw helper. The
*cartridge* owns the **policy** — which clip a state plays, and where the
playhead is anchored:

- **Cosmetic clips** (idle bob): `elapsed = state.frame() - t0`, recomputed each
  draw from the integer frame counter. Deterministic, **zero stored state**, not
  snapshotted. `t0` can even be a constant (`frame % period`).
- **Sim-relevant clips** (an attack frame gates a hitbox): the controller keeps
  `t0_frame` in its **own named buffer** (already sim state, already
  snapshotted) and reads the same pure evaluator. The animation that matters to
  rules rides the sim state that already exists; no new determinism surface.

So `cm.anim` adds **no** sim state of its own — it is a pure evaluator over data
+ an integer elapsed. The studio authors the clips (sequence + per-frame
duration + loop mode) and previews them live in a pane (dev-only wall-clock
preview is fine — it never touches the sim). The proof at Phase 4: wire the
sandbox player to a studio-authored sprite + clips, replacing the procedural
`build_sprite`, and keep `record→verify` byte-exact (the sprite is render-only,
so it cannot perturb the trace — a clean demonstration of §1).

## 8. Rendering the canvas (perf)

The canvas must stay O(1) draw calls regardless of sprite size:

- On edit, composite the **visible** layers (respecting opacity/hidden, plus any
  live gradient fills) into one `w*h` RGBA8 scratch buffer — but only the
  **dirty cell**, gated by a dirty flag (not every frame).
- Upload that to a texture and draw it as **one quad** scaled by the integer
  zoom. The pixel grid, hover outline, selection marquee and gradient handles
  are a handful of overlay quads on top.
- The PAL has `tex_create`/`tex_free` but no in-place update, so a change does
  `tex_free(old)` + `tex_create(new)` — fine at human edit rates (≤ once/frame
  while dragging). If profiling ever demands it, a `pal.x_tex_update(id,…)`
  primitive is the obvious additive PAL upgrade (note, not a blocker).
- Onion-skin = the same composite for neighbor frames at low alpha.

## 9. Module decomposition

- **`cm.paint`** — pure pixel rasterizers on a cell buffer: get/set, line
  (Bresenham), rect, ellipse (midpoint), flood fill (4-connected exact), blit /
  stamp (alpha-masked), flip H/V, rotate90, gradient eval + ordered dither.
  No UI, no state — deterministic functions, **selftest-covered**.
- **`cm.sprite`** — the document model, `.spr` load/save (`cm.chunk`), bake to
  strip PNG + `.anim`, undo stack (`buf_delta1`). Shared by the studio and the
  game runtime (the game uses only the load+bake-consume half).
- **`cm.studio`** — the mode + UI: tools, panels, canvas, browser, interaction.
  A dev surface like `cm.editor`/`cm.options`; `frame()` called from `cm.main`,
  draws on the ui canvas, pauses the sim, captures input. Toggled `F2`.
- **`cm.anim`** — the pure clip evaluator + draw helper (engine mechanism;
  cartridge owns policy).
- **`cm.palette`** — swatch sets + named slots, persisted to a project-level
  palettes file (palettes are shared across assets, not trapped per-doc). May
  fold into `cm.studio` for v1.

`cm.main` gains `M.studio = cm.require("cm.studio")`, a `M.studio.frame()` call
in the tick (on the ui canvas, after the editor), and a pause gate
(`M.studio.on` joins `M.scrub.paused()` in the step guard). `cm.view.update`
learns the studio owns the chrome (like the editor) so the ui canvas is
allocated and the game target is hidden behind the studio's opaque fill. `F2`
is reserved like `F1`/`F3`/`` ` ``; the lockdown disables it with the rest.

## 10. Build plan (phased; "solid paint foundation" first, per the human)

> **Status (2026-06-28): Phases 1–4 DONE** (paint · layers/shapes/selection/
> transforms · gradients · animation), and the **M10 exit proof is hit** — the
> sandbox player draws a studio-authored, clip-animated sprite with
> `record→verify` byte-exact. **Phase 5 is next.** Live tracker: STATUS.md.

**Phase 1 — foundation / MVP (the first deliverable).**
- 1a `cm.paint` rasterizers (pencil/eraser/fill set) + selftest KATs.
- 1b `cm.sprite` doc model, `.spr` save/load, bake-to-PNG, undo.
- 1c `cm.studio` shell: F2 mode, full-window layout, checkerboard canvas,
  composite-to-texture, cursor-anchored pan/zoom, pixel grid, hover.
- 1d tools (pencil/eraser/bucket, primary/secondary, alt-eyedropper), palette
  panel + save slots, HSV+hex color picker, save/load/bake wired to UI, the
  asset browser with baked previews.
- *Exit*: open the studio, paint a sprite across a palette, save it, bake it,
  reopen it from the browser. A human can author a single-layer sprite.

**Phase 2 — layers, shapes, transforms, clipboard.** multi-layer composite +
the layers panel; line/rect/ellipse (no-AA, live preview, shift-constrain);
marquee select / move / cut / copy / paste (floating selection); flip /
rotate90 / scale; custom brush from a selection.

**Phase 3 — gradients.** the gradient tool + non-destructive gradient fill with
live on-canvas handles, ordered dither, and the type/center/phase/stops panel,
masked by layer alpha (§6).

**Phase 4 — animation.** the timeline (multi-frame, onion skin), clips
(sequence + duration + loop), live preview; `cm.anim` evaluator + `cm.sprite`
runtime loader; **wire the sandbox player to a studio-authored sprite + clips**
(replaces `build_sprite`; `record→verify` stays byte-exact). Hits the M10 exit.

**Phase 5 — polish & the rest of M10.** asset hot-reload (game refreshes
textures on save), pivots/origins, frame tags/slices, a brush palette, optional
indexed/palette-swap mode, the **procedural sprite generator**
(noise/shape/gradient/bevel/blend, M10's other half) feeding particles/liquids/
dust, the **LUT post pass** + palette/LUT editor, headless `--bake`.

Each phase commits in logical units; visual progress goes to llm-feed for the
human's taste check (the human is the taste gate, not the smoke test).

## 11. Open questions (decide at their phase, not now)

- **Arbitrary rotation** of pixel art mushes; a RotSprite-style algorithm is the
  good answer but is Phase 2+ — 90° clean ships first, arbitrary with a "nearest,
  expect cleanup" warning until then.
- **Palette-swap / indexed mode** — wanted by some pixel artists, fights
  gradients; offered later as an optional per-doc mode, not the default.
- **In-world live preview** (paint and see it on the character) needs asset
  hot-reload (Phase 5); the studio's own canvas + preview pane cover authoring
  meanwhile.
- **Pivot granularity** (per-doc vs per-frame origins) — per-doc first; per-frame
  when a weapon needs to track a hand.
- **Tile mode** (canvas repeats around itself for seamless tiles) — easy add
  once the canvas exists; slot in Phase 2/3 if tile authoring comes up.
