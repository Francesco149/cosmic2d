# The sprite editor

Paint a pixel sprite; define animation clips in the paired **animation** window.

## Workflow

0. A fresh (unbound) sprite window is the **new sprite** door: type a path —
   a unique name is prefilled — and Enter creates a 32x32 sprite there (an
   existing path offers open / overwrite / cancel). Or drag any `.spr` in
   from an assets window.
1. Toggle **edit** (header) to paint; the view lock lights up so wheel/pan act
   on the sprite, not the canvas.
2. Pick a tool, pick a color (or eyedrop one from anywhere on screen), paint.
3. **ctrl+s** saves and bakes the `.png` the game draws.
4. Open **anim** (header button) to cut the strip into clips (frame:duration).

## Tools (edit mode)

- **p** pen · **e** eraser · **f** fill · **k** pick (eyedropper) · **~ c** curve
- **t** stamp (once an image is in the stamp well, below)

The pick tool is a **global eyedropper** — click anywhere (other windows, the
live game) to sample that color.

The **curve** tool is the classic 2-point curve: click the start, click the
end, then move the mouse to bow the line and click to lay it (esc cancels).

## Brush size, shape and opacity

The strip under the canvas dials the pen/eraser brush: **size** (1-32 px,
default 1 — also `[` and `]`), **opacity** (drag; applied once per stroke,
so a slow drag never darkens twice), and the **shape** chip toggles
**circle / square**. The eraser honors all three — a low-opacity eraser
fades pixels instead of deleting them.

## The stamp well

The square slot at the bottom of the tool rail is the **stamp well**:
**drag any sprite or image onto it** and it becomes a stamp — click the
canvas to print its opaque pixels (a ghost preview shows where it lands;
one click = one undo step). Click the well or press **t** to re-arm the
stamp tool; right-click the well (or the strip's `x` chip) to clear it.

## Two colors + lines

- **left-click paints the primary color, right-click the secondary** — the two
  swatches sit at the bottom of the tool rail; **x** swaps them, and a
  right-click on either the rail swatch or a palette swatch sets the secondary.
- **hold shift** and click with the pen/eraser to draw a
  **straight line from the last pixel you painted** (a preview line
  shows first).

## Colors & palettes

New assets auto-name with three random words, so nothing blocks on a filename —
press **enter** to create. The bottom-right **`#hex adds color`** field appends
a typed `#RRGGBB[AA]` to the palette (the swatch left of it previews the parse).

The palette row starts with the **transparent swatch** (the little
checker): select it to paint or **fill with transparency** — the bucket
with transparency erases a whole region in one click.

**Drag a `.pal` in** to stack it as an extra swatch source at the bottom — add
as many as you like; each row has a **×** to remove it. Left/right-click its
swatches to set the primary/secondary color.

Next: [Using the editor](engine/stock/docs/editor.md)
