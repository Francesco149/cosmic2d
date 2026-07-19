# The mesh editor

A `.msh` is one low-poly mesh: points, triangle/quad faces, flat
per-face colors. It is deliberately small — no bones, no modifiers, no
subdivision, no UV unwrapping. Push points, paint faces, extrude. That
is the whole tool, and it is enough for era props and characters.

Open one from the spawn menu ("mesh") or double-click a `.msh`. An
empty window offers a path field — enter creates a fresh unit box.
Ctrl+S saves and every 3d map showing placed copies refreshes the same
frame. Undo walks whole gestures.

## The viewport

Middle-drag orbits, shift+middle pans, wheel zooms, **shift+1** frames
the mesh. The grid square is half a unit.

## vtx mode (`v`) — push points

- **click** picks the nearest point (**shift** adds to the selection);
  click empty space and drag for a box select.
- **drag** a selected point to move the whole selection on the camera
  plane. **x / y / z** toggle an axis lock; **ctrl snaps** to the model
  grid (**ctrl+wheel** dials the step).
- the **mirror** chip edits the matching point on the other side of
  x=0 live — build one half, get both.
- **m** merges the selection into one point; **del** dissolves (faces
  touching the points go too).

## face mode (`f`) — paint and grow

- **click** picks the face under the cursor (**shift** adds).
- click a **swatch** in the bottom strip to paint the selection.
- **e** extrudes the selection outward by one grid step — the power
  move: start from a box and pull every shape out of it.
- **r** flips a face's winding; **ds** makes it doublesided; **unlit**
  exempts it from lighting; **del** removes it.

## Adding shapes

The `+box +prism +wedge +plane` chips drop a primitive at the origin —
select its points and push. Keep an eye on the `t=` count in the strip:
era characters live at 250–800 triangles.

## Using meshes

Drag a `.msh` from the assets window into a **3d map** to place it (it
arrives with an automatic collider), or reference it from a figure as a
part mesh. Meshes render pre-lit through the engine's fast baked path.
