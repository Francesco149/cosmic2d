# The sprite editor reference — every tool, dial and button

This is the complete control-surface reference for the sprite editor.
The guided path is [the sprite tutorial](engine/stock/docs/win-sprite.md);
this page is for when you are holding the window and want to know
exactly what the thing under your cursor does.

## The window at a glance

Edit mode, left to right: the **tool rail** (pen through marquee, the
stamp well, your two colors) · the **canvas** (checkerboard = transparent)
· the **layers rail** (the stack plus the selected layer's mix and fill
controls). Under the canvas: the **palette row** (transparent swatch,
document colors, the hex add field), the **frames row**, and the
**brush strip**, plus one extra row per attached `.pal`.

A window with no file bound is the **new sprite** door: a path field (a
unique three-word name is prefilled, the `.spr` extension is forced).
Enter creates a 32x32 sprite there and opens it editable; an existing
path offers open / overwrite / cancel. Dragging any `.spr` in from an
assets window binds it too.

## Header

- **edit / done** — toggles between edit mode and the read-only view.
- **size** — (edit mode) opens the canvas size bar (below).
- **anim** — opens (or focuses) the animation window bound to this
  sprite — clips are cut there, the strip is drawn here.
- The title carries the standard unsaved marks (the amber dot and the
  trailing `*`). **ctrl+s** saves, **ctrl+z / ctrl+y** walk the undo
  journal — one finished gesture (a stroke, a fill, a structure click)
  is exactly one undo step.

## View mode

The composited current frame, aspect-fit over the checker, with an info
line (size · frames · layers) at the bottom. The view never grabs the
wheel — the editor canvas pans and zooms over it — and a right-click
opens the canvas spawn menu as usual. Toggle **edit** to work.

## The view lock (edit mode)

While the window is **focused** in edit mode, the green **EDITING** chip
shows and the window owns the view: **wheel** zooms the pixels (0.25x to
64x), **middle-drag** pans, **shift+1** refits the art to the frame.
Esc (or focusing another window) hands wheel and pan back to the editor
canvas. While the cursor is over the canvas the top-right readout shows
the pixel under it as `x,y` — tutorial positions like "the eye at 15,11"
are read off it.

## The tool rail

Top to bottom (each tool's key is the letter shown in its hint):

- **P — pen** (`p`). Paints the primary color with the brush-strip
  footprint; right-button paints the secondary. Opacity applies once
  per stroke — a slow drag never darkens twice.
- **E — eraser** (`e`). The same footprint, painting transparency; a
  low-opacity eraser fades pixels instead of deleting them.
- **F — fill** (`f`). The flood bucket: fills the contiguous same-color
  region under the click (left = primary, right = secondary). With the
  transparent swatch selected it is the transparency eraser for a whole
  region.
- **K — pick** (`k`). The **global eyedropper**: while armed the chip
  reads PICKING and a click anywhere on screen — this canvas, another
  window, the live game — samples that color (left sets the primary,
  right the secondary). On this canvas it samples the composite, so a
  color under a blend layer picks what you actually see. Esc returns
  to the pen.
- **~ — curve** (`c`). The classic 2-point curve: click the start,
  click the end, move the mouse to bow the preview, click to lay it.
  Right-click cancels at any stage.
- **M — marquee** (`m`). Rectangle selection — see the clipboard
  section below.
- **The stamp well** — the square slot under the tools. Drop any
  `.spr` or `.png` on it and it becomes the **stamp** brush (`t`): a
  ghost of the image rides the cursor and each click prints its opaque
  pixels as one undo step. A dropped `.spr` stamps its first frame,
  composited. Click the well (or press `t`) to re-arm the tool;
  right-click the well — or the brush strip's `x` chip — clears it.
- **The two color swatches** — the big square is the **primary** (left
  button paints it), the smaller overlapped square the **secondary**
  (right button paints it). The `x` key — hint: **swap colors** — or a
  right-click on the swatch pair swaps them.

## Canvas gestures

- **left-drag** — paint with the active tool (primary color).
- **right-drag** — paint the secondary (edit mode owns the right
  button; the spawn menu is a view-mode / canvas affair).
- **shift+click** (pen / eraser) — a straight line from the last pixel
  you painted, previewed before you commit.
- **wheel / middle-drag** — zoom / pan, focused windows only (the view
  lock above).
- The cursor outline previews the true brush footprint at the current
  size; the `x,y` readout top-right names the pixel under it.

## Marquee, copy, cut and paste

The **m** marquee drags a rectangle selection on the canvas; a plain
click deselects, right-click cancels a drag in progress, Esc clears.
The selection reads from the **active layer**:

- **ctrl+c** — hint **copy** — copies the selected pixels (with no
  selection: the whole layer cell), transparency included.
- **ctrl+x** — hint **cut** — copies and clears the region, one undo
  step (needs a selection on an unlocked layer).
- **ctrl+v** — hint **paste** — arms the paste tool: the clip ghosts
  on the cursor and each click prints its opaque pixels, one undo step
  per click (the stamp rule). Esc returns to the pen.

The clip is shared across every sprite window in the session — copy in
one sprite, ctrl+v in a window on a **different** `.spr`, and it pastes
there too.

## The size bar (header **size**)

Type `WxH` (1 to 1024 each) and press Enter or **apply**. The default
**canvas** mode keeps pixels where they are — growing adds transparent
room, shrinking crops; the **scale** mode resamples the art to fill the
new size. Either way it is one undo step. The **x** chip closes the bar.
Mesh texture sheets usually want 64x64 or more.

## The layers rail

The list is the stack, top-down — the top row draws last (in front).

- **click a row** — selects that layer (paint lands here).
- **the eye dot** (row's left edge) — hides / shows the layer.
- **right-click a row** — locks it: a locked layer refuses paint and
  cut, and carries a small red dot.
- **+ −** — add a layer (on top, selected) / delete the selected one
  (a document always keeps at least one).
- **^ v** — move the selected layer up / down the stack.

### The mix controls (the selected layer)

- **op** — layer opacity, dragged in 5% steps.
- **mix** — the blend mode chip: **normal, mul, add, screen, overlay**
  (click cycles forward, right-click back). *mul* darkens (shadows,
  grime), *add* glows, *screen* lightens softly, *overlay* adds
  contrast. Over empty pixels every mode just paints — a blend layer
  never blackens transparent canvas, and stray marks outside your art
  stay visible until erased.

### The fill chip (the selected layer)

A live, non-destructive fill — saved in the `.spr`, re-rendered on
every composite, adjustable until you **bake** it. Click cycles the
type forward (right-click back): four gradients — **linear**,
**radial**, **angular**, **mirror** — and six procedural fields —
**noise** (soft value
noise), **fbm** (cloudy fractal), **ridged** (creased strata — rock
veins), **cells** (organic cells/scales), **shards** (cracks between
cells — cobblestone), **facets** (flat random tone per cell — crystal
planes).

By default a fill **recolors the layer's painted pixels** (the shape is
yours, the colors are the ramp's). Toggle **solid** to cover the whole
canvas instead. The ramp is created from your **secondary → primary**
color the moment the fill is born — pick the colors first. A fresh
fill's axis runs top to bottom: the secondary color at the sprite's top
edge, the primary at the bottom. **cols** re-grabs the ramp from the
current colors whenever you change your mind.

The dials underneath tune it live; releasing a drag commits one undo
step:

- **sd** — the random seed (drag to reroll a procedural field).
- **px** — feature size in pixels, 2 to 64 (procedural types).
- **oct** — detail octaves, 1 to 8 (fbm / ridged only).
- **lv** — color bands, 2 to 16; **di** — dither strength between
  bands, 0 to 100%. Every output pixel is an exact ramp color —
  dithered bands, never a blur, so baking stays palette-clean.
- **bake** — stamps the fill into the layer's pixels and removes it.

### Fill recipes

![Procedural water, crystal, sand, moss, stone, and gem fills](media/sprite-fills.png)

Every recipe is: pick secondary (dark) + primary (light), set the fill,
tune dials. All results stay live — reroll **sd** until it looks right.

- **Water tile** — deep blue secondary, pale cyan primary; *noise*,
  **solid**, px ~8, lv 4, a little **di**. The dither bands read as
  ripples; a second layer of *noise* at **mix mul** + low **op**
  roughens the surface.
- **Sand / dunes** — dark red-brown secondary, cream primary; *fbm*,
  **solid**, px 10–14, oct 3. The cloudy octaves make dune shadows.
- **Moss / foliage** — near-black green secondary, yellow-green primary;
  *cells*, **solid**, px 6–10. Reads as leaf clumps; larger px = bushes,
  smaller = lichen.
- **Cobblestone** — near-black blue secondary, light blue-gray primary;
  *shards*, **solid**, px 10–16. The cracks between cells are the
  mortar lines; raise **lv** for flatter stones.
- **Crystal wall** — deep violet secondary, pale lavender primary;
  *facets*, **solid**, px 10–16, di 0. Flat tone per cell = mineral
  planes.
- **A shaded boulder** — draw the silhouette with the pen first (any
  color), keep the fill **masked** (solid off), pick dark slate → warm
  gray, *ridged*, px 8, oct 2–3, lv 4. The strata shade your shape;
  the silhouette stays yours.
- **A cut gem** — draw a diamond silhouette; *facets* masked, deep blue →
  ice blue, px large (few big cells). **bake**, then hand-touch: a
  1px darker outline and a 2px white sparkle at the top facet.
- **Speckle / stars overlay** — transparent secondary, white primary;
  *noise* on an empty **solid** layer, high lv, then **mix screen** over
  the scene below.

Blend-mode staples on top of any base: a *mul* + *fbm* layer at ~40%
**op** is instant grime/shadow; an *add* + *noise* layer at low op is
sparkle/heat; *overlay* + *ridged* deepens rock contrast without
touching the palette.

## The palette row

- **The transparent swatch** (the little checker, far left) — select it
  to paint or flood-fill with transparency; right-click makes the
  secondary transparent (speckle overlays are born that way).
- **The document swatches** — the `.spr`'s own palette (new sprites
  ship a 17-color starter). Left-click sets the primary, right-click
  the secondary. The row truncates on narrow windows — widen the
  window if your palette outgrows it.
- **The hex field** (bottom-right, placeholder `#hex adds color`) —
  type `#RRGGBB` or `#RRGGBBAA` and press Enter to append that color to
  the palette and select it as the primary. The little swatch to its
  left previews the parse (a dim + until the text is a valid hex).

### Attached palettes

**Drag a `.pal` in** to stack it as an extra swatch row at the bottom —
as many as you like; each row shows the palette's name and a **×** to
remove it. Left / right-click its swatches to set the primary /
secondary. Rows re-read their file when it changes, so palette-window
edits arrive live.

## The frames row

Frames are the columns of the baked strip — the animation window cuts
them into named clips.

- **the numbered chips** — select the frame you are painting.
- **+** — insert a blank frame after the current one.
- **⧉** — duplicate the current frame (pixels copied, all layers).
- **−** — delete the current frame (a document keeps at least one;
  clips referencing it lose those entries).

## The brush strip (pen / eraser)

- **size** — 1 to 32 px; the `[` and `]` keys — hints **smaller** /
  **bigger** — step it too, and repeat while held.
- **op** — stroke opacity, 5% steps; applied once per stroke however
  the drag re-crosses a pixel. The eraser honors it (partial erase).
- **the shape chip** — toggles **circle / square**.

With the stamp tool armed the strip shows the stamp's filename instead —
click it to clear the stamp, or drop a new image on the rail well to
swap.

## Hotkeys

Edit mode, dispatched to the focused window (the hint strip under the
window carries the same words):

- `p` pen · `e` eraser · `f` fill · `k` pick · `c` curve · `t` stamp
  (once an image is in the well) · `m` marquee
- `[` / `]` — smaller / bigger brush
- `x` — swap colors (primary ↔ secondary)
- **ctrl+c** copy · **ctrl+x** cut · **ctrl+v** paste
- **shift+1** — fit the view to the frame
- **esc** — the ladder: cancel the in-flight curve or marquee drag,
  then disarm pick / stamp / paste back to the pen, then clear the
  selection, then unfocus.
- **ctrl+s** save · **ctrl+z / ctrl+y** undo / redo (the journal keeps
  the last 512 gestures).

## Files and code

A sprite saves as a `.spr` (the CSPR container: layers, frames, fills,
palette, clips, pivot) and **ctrl+s also bakes the sibling `.png`** —
the flattened frame strip games actually draw. Tilemaps, maps, meshes
and running games re-read the baked strip on the next frame after a
save (live hot-reload). Clips defined in the animation window travel in
the same `.spr`; game code plays them through `cm.anim` + `cm.sprite` —
the copyable pattern is in
[sprites in game code](engine/stock/docs/scripting.md#animation-clips-and-sprites-cmanim-cmsprite).

Back to [the sprite tutorial](engine/stock/docs/win-sprite.md).
