# The mesh editor

A `.msh` is one low-poly mesh: points, triangle/quad faces, flat
per-face colors. It is deliberately small — no bones, no modifiers, no
subdivision, no UV unwrapping. Push points, paint faces, extrude. That
is the whole tool, and it is enough for era props and characters.

Open one from the spawn menu ("mesh") or double-click a `.msh`. An
empty window offers a path field — enter creates a fresh unit box.
Ctrl+S saves and every 3d map showing placed copies refreshes the same
frame. Undo walks whole gestures.

## The quad view

The window opens as four views: the orbit perspective plus **top**,
**front**, and **side** axis projections. All four share the focus
point and zoom; every view picks, box-selects, and drags through its
own projection — a drag in the front view moves points in that plane.
The **quad** chip collapses to the single perspective view.

Middle-drag orbits the perspective view and pans the axis views;
wheel zooms all four; **shift+1** frames the mesh. The grid square is
half a unit.

## sel mode (`1`) — the universal tool, the default

- **click** picks what is under the cursor: an edge when you are on
  one, otherwise the face in front. Hidden edges never steal a click.
- **click again** on the same selected thing to drill one step to what
  is behind it — the point under the cursor, the face under an edge,
  or the next face along the ray. A third click cycles back.
- **ctrl+click an edge** selects its whole edge loop.
- **press and drag on anything selected** to move the selection on the
  view plane; **x / y / z** toggle an axis lock, **ctrl snaps** to the
  model grid (**ctrl+wheel** dials the step).
- **drag on empty space** box-selects the points you can see —
  occluded points stay out (vtx mode's box is the x-ray one).

Switching modes carries the selection with it: a selected face becomes
its corner points in vtx mode, its boundary edges in edge mode, and a
full set of corners turns back into the face.

## vtx mode (`2`) — push points

- **click** picks the nearest point (**shift** adds to the selection);
  click empty space and drag for a box select — this one selects
  through the mesh (x-ray).
- **drag** a selected point to move the whole selection; the same
  axis-lock and snap keys as sel mode.
- the **mirror** chip edits the matching point on the other side of
  x=0 live — build one half, get both.
- **m** merges the selection into one point; **del** dissolves (faces
  touching the points go too).

## edge mode (`3`) — work the seams

- **click** picks an edge; box select takes every edge with both ends
  in the box; **ctrl+click** selects the edge loop.
- **drag** a selected edge to move it; **del** removes the faces the
  selected edges carry.

## face mode (`4`) — paint and grow

- **click** picks the face under the cursor (**shift** adds; click
  again drills to the face behind). Box select takes fully-boxed
  faces; **ctrl+click an edge** selects the quad strip its loop walks.
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

## Walkthrough: a watchtower from one box

Every era prop is a box plus extrudes. This one exercises the whole
tool in a few minutes:

1. **The shaft**: start from the fresh unit box. Face mode (`4`),
   click the top face, then **e e e** — three extrudes stack the tower.
   In the front view, box-select each ring of points (sel drag on
   empty space) and nudge alternate rings slightly inward for a taper.
2. **The flare**: click the top face and **e** once more, then switch
   to vtx mode (`2`) — the selection arrives as the four corner
   points. In the **top view**, turn on **mirror** and drag each
   corner outward (x-lock, then z-lock): the overhanging platform, and
   mirror halves the work.
3. **The roof**: face mode, top face, **e**, then vtx mode and **m** —
   the four points merge into one and the extrusion becomes a pyramid
   roof.
4. **Paint**: face mode, box-select the shaft faces, click a stone
   swatch; the roof gets a dark red; the underside of the flare a
   deeper shadow tone (painted shading is most of the era look).
5. Check **t=** in the strip (a prop like this should sit well under
   100), **ctrl+s**, and drag the `.msh` into a 3d map — it lands
   standing on the ground with a collider.

Corners read better slightly irregular: pull a few points a half-step
off-grid at the end, exactly the opposite of what a modern modeler's
instincts say.
