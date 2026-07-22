# The palette window reference — every control

This is the complete control-surface reference for the palette window. The
guided path is [the palette tutorial](engine/stock/docs/win-palette.md); this
page is for when you are holding the window and want to know exactly what the
thing under your cursor does.

## The window at a glance

Top to bottom: the **saved swatch grid**; the framed **working color** with
the **sv / hsv / rgb** mode chips, selection counter and hex field; the active
picker; six **swatch-operation buttons**; then **ramp from working** with its
shade count, hue shift, and append/replace buttons.

A new unbound window shows a path field with a unique three-word `.pal` name.
Edit it and press Enter to create the working asset; the extension is forced.
If the path already exists, choose **open**, **overwrite**, or **cancel** — it
never silently replaces a file. Dragging a `.pal` from assets onto a palette
window rebinds that window to the dropped file.

## Header and document state

- **paste** — reads a Lospec-style hex list from the clipboard and replaces
  every saved swatch in one undo step. Six- and eight-digit hex tokens are
  accepted; six-digit colors become opaque. At most the format's first 256
  colors are adopted.
- **copy** — writes the saved palette as lowercase `RRGGBB`, one color per
  line, ready for Lospec and ordinary hex-list tools. The clipboard form is
  RGB-only; `.pal` itself can retain alpha.
- **?** — opens [the palette tutorial](engine/stock/docs/win-palette.md) in a
  help reader.
- The amber dot and title `*` mean the working document differs from disk.
  **ctrl+s** saves. While dirty, **reset** restores the last saved bytes as an
  undoable edit — **ctrl+z** can bring the discarded working version back.

Two windows bound to the same path share one palette document and one undo
journal. Selection, picker mode, and working color belong to each window, so
one window can audition a new mix without moving the other window's scratch.

## Saved swatch grid

- **Left-click a swatch** — select it. The bright outline and `swatch N/M`
  counter confirm the index. Selection alone never changes a color.
- **Double-click the selected swatch** — adopt its exact RGBA bytes into the
  working color. A second click within 320 ms is the double-click. **enter**
  is the keyboard form of the same **pick** action.
- The grid is ordered left to right, then top to bottom. Swatches shrink when
  needed so large palettes remain visible instead of falling out of the top
  region. A `.pal` holds at most 256 colors and at least one in the editor.
- **left / right** — **prev / next** selection; both repeat while held and
  stop at the first or last swatch.

The swatches are also real screen colors. Arm a sprite window's **k** pick
tool, then click a palette-window swatch anywhere on the canvas to sample it
as the sprite's primary color.

## The working color

The large framed square is a persistent mixing scratch, separate from the
saved grid. Picker drags and hex typing change only this square. It enters the
document only through **+add**, **set**, or a ramp operation; generating a
ramp never selects or mutates a saved swatch behind your back.

The `swatch N/M` counter names the saved selection, not the working color.
The field below the mode chips shows the scratch as six hexadecimal RGB
digits. Type `RRGGBB`, `#RRGGBB`, or an eight-digit RGBA token; valid input
updates the square immediately. Picker changes produce opaque colors. An
adopted translucent swatch keeps its alpha until an RGB/HSV/hex change makes
a new mix.

## Picker modes

All slider tracks display the exact value they will commit; drag anywhere on
a track to jump and continue dragging to tune.

### sv — choose by eye

- **H** — hue, 0° to 359°. This colors the two-dimensional field below.
- **SV square** — saturation runs 0% to 100% from left to right; value runs
  100% to 0% from top to bottom. Click or drag. The crosshair flips between
  dark and light so it stays legible over the color.

This is the fastest mode for "a muted blue around this brightness." The hex
field remains the exact channel readout.

### hsv — tune a color relationship

- **H** — hue, 0° to 359°.
- **S** — saturation, 0% gray to 100% fully saturated.
- **V** — value, 0% black to 100% maximum channel brightness.

HSV is useful when related materials need equal value or saturation, and for
adopting a generated shade to understand why it reads differently.

### rgb — match a known source

- **R / G / B** — red, green, and blue channels, each 0 to 255.

Use RGB for a sampled paint-over, brand specification, or any reference that
already gives channel values. HSV and the working hex update with it; the
three modes are views of one scratch color, not three independent colors.

## Swatch-operation row

All six buttons act on the current selection. Structure changes are one undo
step each.

- **+add** — insert the working color immediately after the selected swatch,
  then select the new one. The **a** key is the same **add** action.
- **set** — overwrite the selected saved swatch with the working color.
- **dup** — duplicate the selected saved swatch immediately after itself and
  select the copy. The **d** key is the same **dup** action.
- **del** — remove the selected swatch and select its predecessor. A palette
  keeps at least one color. The **del** key is the same **del** action.
- **left-arrow button** — swap the selected swatch one place earlier and move
  the selection with it.
- **right-arrow button** — swap the selected swatch one place later and move
  the selection with it.

Add, duplicate, paste, and ramp append stop at the 256-color format limit;
saving never hides extra working swatches by silently truncating them.

## Ramp from working

A ramp is generated from the working color, dark to light. The generator
spreads value, rotates hue once per adjacent shade, and lowers saturation at
both ends to keep the middle colorful without blowing the highlight to white
or dirtying the shadow to gray.

- **shades field** — type 2 through 32. Larger or smaller input clamps to the
  range. This and the **n** track below are two controls for the same value.
- **n** — drag the shade count from 2 to 32; the exact count is shown at the
  right of the track and copied into the shades field.
- **hue** — signed hue rotation per adjacent shade, −30° through +30°. At
  `+14°`, a five-shade ramp spans working hue −28° at the dark end through
  working hue +28° at the light end. Zero keeps one hue; a negative value
  reverses the rotation. "Warmer" depends on the starting hue, so judge the
  resulting ends rather than treating the sign as a universal temperature.
- **append ramp** — add the generated shades at the palette's end, preserving
  the grid and selection already there. The append is one undo step and stops
  at 256 colors.
- **replace all** — replace the entire saved grid with this one ramp and
  select its first, darkest shade. This is one undo step.

The working color does not have to appear verbatim in the result: it supplies
the hue/saturation/value center of the recipe, while the generator spreads
values across the requested range. Double-click a generated middle shade when
you want to continue from the exact emitted color.

## Cohesion recipes

**Three fundamentals.** Give every major material the same shade count, then
append one ramp each. Equal-length ramps make outline/shadow/body/light roles
interchangeable across stone, cloth, skin, foliage, and UI.

**Shared shadow.** Keep one deep violet, blue-black, or warm near-black swatch
and use that one color wherever separate materials meet. Do not overwrite the
darkest slot of every ramp with identical bytes: repeated swatches spend the
budget without adding a role, while the original chromatic darks remain useful
for material-specific outlines. [The tutorial](engine/stock/docs/win-palette.md)
keeps its universal shadow once, at swatch 1.

**Shared accent.** Keep one or two saturated colors outside every ramp for
pickups, damage, focus, or blood. Their rarity creates emphasis; using them as
ordinary body colors spends the effect.

**Wide palette.** Five shades each across many fundamentals reads colorful and
material-rich. Keep the count consistent and stop when every gameplay role has
a color.

**Narrow / film palette.** Invert the ratio: one 9-to-16-shade dominant ramp,
at most one or two 3-to-4-shade support ramps, then stop. A horror scene might
be twelve desaturated teals plus three blood reds; sepia might be one long
warm-brown ramp and a short cold-gray counter-ramp. Use **replace all** for the
dominant, then lower shades and **append ramp** for supports.

## Pointer and keyboard summary

- Left button selects/adopts swatches, clicks buttons, edits fields, and drags
  picker/slider controls. Palette controls bind no right-button action.
- Middle-drag and wheel are not palette gestures; when the shell can receive
  them they retain the editor canvas pan/zoom grammar.
- **left** prev · **right** next · **enter** pick/adopt · **a** add · **d**
  dup · **del** del.
- **ctrl+s** save · **ctrl+z / ctrl+y** undo / redo. A paste, add, set, dup,
  delete, reorder, append, or replace is one journal entry. Selection and
  working-color mixing are layout state, not palette edits.

## Using a palette in other windows

Drag a saved `.pal` from assets onto an editable sprite window. It stacks as a
named swatch row beneath the sprite's own palette; multiple `.pal` rows can be
attached. Left-click an attached swatch for the primary color, right-click for
the secondary, and click its **×** to remove that row. The attachment belongs
to the editor layout; painting writes the chosen RGBA into the sprite. Saving
the `.pal` refreshes attached rows live.

The global sprite eyedropper is the other direction: with **k** armed, click
any visible palette swatch without attaching the file first.

## Files and code

`.pal` is the CPAL container: a name plus an ordered list of up to 256 RGBA
colors. It has no baked sibling; **ctrl+s** atomically replaces the source and
bumps the asset epoch.

Games load the document or ask for one indexed color:

    local palette = cm.require("cm.palette")
    local path = cm.main.args.project .. "/pal/moonlit-vale.pal"
    local doc = palette.load(path)            -- { name, colors }
    local accent = palette.color(path, 16, 0xffffffff)

Colors use `cm.paint` packing. Pass one to `paint.unpack` for 0-to-255 RGBA
channels, or use it directly where an engine helper expects packed color.
`palette.load` caches by path and asset epoch, returns nil for an unreadable
file, and follows editor saves live. `palette.color` is 1-based and returns its
fallback (opaque white by default) when the file or index is missing.

Back to [the palette tutorial](engine/stock/docs/win-palette.md) or continue to
[palettes and grading in game code](engine/stock/docs/scripting.md#palettes-and-color-grading-cmpalette-cmgrade).
