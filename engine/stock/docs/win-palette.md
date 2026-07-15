# The palette editor

Design a palette (`.pal`): a list of colors your game and sprites draw from.
Generate value **ramps** with a pixel-art hue shift (warm highlights, cool
shadows).

## Workflow

1. Add colors; tune the selected one with the H/S/V sliders (or type a hex).
2. Pick a shade count + hue shift, then **append ramp** / **replace all** to
   generate a ramp from the selected color.
3. **ctrl+s** saves. Game code reads it with `cm.palette.load(...)`.

## Keys

- **left / right** select the previous / next swatch
- **a** add a swatch · **d** duplicate the selected · **del** delete it
- **ctrl+z / ctrl+y** undo / redo · **ctrl+s** save

Swatches are eyedropper-pickable from the canvas: arm the sprite editor's pick
tool and click a swatch to sample it.

Next: [The sprite editor](engine/stock/docs/win-sprite.md)
