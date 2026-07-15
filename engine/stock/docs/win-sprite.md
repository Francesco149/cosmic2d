# The sprite editor

Paint a pixel sprite; define animation clips in the paired **animation** window.

## Workflow

1. Toggle **edit** (header) to paint; the view lock lights up so wheel/pan act
   on the sprite, not the canvas.
2. Pick a tool, pick a color (or eyedrop one from anywhere on screen), paint.
3. **ctrl+s** saves and bakes the `.png` the game draws.
4. Open **anim** (header button) to cut the strip into clips (frame:duration).

## Tools (edit mode)

- **p** pen · **e** eraser · **f** fill · **k** pick (eyedropper)

The pick tool is a **global eyedropper** — click anywhere (other windows, the
live game) to sample that color.

## Keys

- **shift+1** fit the view · **wheel / middle-drag** zoom / pan (while focused)
- **ctrl+z / ctrl+y** undo / redo · **ctrl+s** save
- **esc** drops the tool / releases the view lock

## Colors

New assets auto-name with three random words, so nothing blocks on a filename —
press **enter** to create. Design a palette in the **palette** window and
eyedrop from its swatches.

Next: [Using the editor](engine/stock/docs/editor.md)
