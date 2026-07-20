# The figure editor

A `.fig` is a rigid-part character: little shapes hung on a joint
tree, posed by named clips of keyframes. No bones-and-skinning, no
weights, no IK — parts rotate and slide at joints, keys blend, and
that is enough for the whole era style (the engine mascot is exactly
this). The engine ships the mascot as a starting point: copy
`engine/stock/fig/mascot.fig` into your project and riff.

Open one from the spawn menu ("figure") or double-click a `.fig`. An
empty window offers a path field — enter creates a three-part starter.
Ctrl+S saves; 3d maps with placed figures refresh the same frame. The
viewport orbits like every 3D window: middle-drag orbits, wheel zooms,
**shift+1** frames the figure.

## parts (`1`) — build the body

The left panel is the part tree — click selects, **+ part** adds a
child of the selection, **del** removes one (children move up to its
parent). Drag the selected part's **joint dot** in the viewport to
move it (**ctrl** snaps to the grid step, **ctrl+wheel** dials it,
**x / y / z** lock an axis).

The bottom strip edits the selected part's shapes: the **shape** chip
cycles through them, swatches recolor, the size dial drag-adjusts, and
the **+box +ball +prism +lathe** chips add primitives.
**Drop a `.msh`** from the assets window onto the figure to add it as
a mesh shape on the selected part — a hat, a sword, any prop you modeled in
the mesh editor; its chip opens that mesh beside the figure. Name
parts `arm_l` style and the **mirror L>R** chip (or **m**) builds the
right side from the left, x-flipped.

## pose (`2`) — bring it to life

Clips live in the panel's lower half (**+ clip** adds one; the strip's
chips set **rate**, **loop**, **dup clip**). The key rail along the
bottom holds the clip's keys: click a diamond to select, **+** inserts
a copy after it, **del** removes it. **Space** plays the clip exactly
as the game will play it — what you scrub is what ships.

With a key selected, drag a part in the viewport to **rotate** it
about the axis facing the camera (**x / y / z** lock one, **ctrl**
snaps to 15° steps). **Shift+drag slides** the part — that is how
floating hands and feet move. Edits write only the selected key, and
only the parts you touched; **clear** forgets the selected part in
this key so it blends through again. The faint ghosts are the
neighboring keys.

## bake (`3`) — the sprite sheet

The bake tab turns the figure into a classic 8-direction sprite sheet
(a `.spx`). Rows in the panel pick a clip and a moment (`t`) each; the
preview IS the real bake, rendered by the same rasterizer.
**bake .spx** writes `spr/<name>.spx` next to your project's sprites — place
it in a 3d map or draw it as billboards, and your one model covers 3D
and sprite games alike.

## Walkthrough: a critter with a walk, from the mascot

Copying and bending a working figure teaches the tool faster than a
blank tree. Copy `engine/stock/fig/mascot.fig` into your project (the
assets window's **r** can rename it to `fig/critter.fig`), open it, and:

1. **Resculpt the silhouette** (parts tab): select the body, cycle its
   **shape** chip, drag the size dial chunkier, recolor with the
   swatches. Move the head's joint dot lower for a hunched read —
   silhouette changes do more than any detail.
2. **One prop**: model a 20-triangle hat in the mesh editor, then drop
   the `.msh` onto the figure with the head selected. It rides every
   pose from now on.
3. **A left arm the right gets free**: name it `arm_l`, place it, then
   **mirror L>R** — the right side appears x-flipped and stays a twin.
4. **The walk** (pose tab): the mascot's clips are already there —
   select the walk, **space**, and watch what keys it actually takes
   (four: contact, up, contact, up). Now make it yours: on each
   contact key, rotate the body a touch further forward; **shift+drag**
   the hands lower. Play again. A walk reads through exactly two
   things — body lean and hand height.
5. **An attack clip**: **+ clip**, two keys: a windup (body twisted
   back, ctrl-snapped 15°) and the swing (twisted forward, hat tilted).
   Short **rate**, loop off.
6. **ctrl+s**, drag it into a 3d map, and (bake tab) **bake .spx** the
   same critter into an 8-direction sheet for the 2D games.
