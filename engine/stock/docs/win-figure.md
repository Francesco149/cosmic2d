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
