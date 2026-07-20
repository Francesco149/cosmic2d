# The tilemap editor

A tilemap (`.tm`) is a grid of tiles drawn from a tileset (a `.spr` whose frames
are the tiles). Place a tilemap on a map layer as one object.

## Workflow

1. Bind a tileset (drag a `.spr` in, or the inspector field).
2. Pick a tile from the palette strip, paint cells.
3. Resize the grid with the grow/crop fields. **ctrl+s** saves.

## Keys (edit mode)

- **p** pen (stamp the picked tile) · **e** eraser · **f** rect-fill
- **right-click** erases with the current tool's shape (no need to switch to e)
- **k** pick (eyedrop a cell's tile)
- **shift+1** fit the view · **wheel / middle-drag** zoom / pan (while focused)
- **ctrl+z / ctrl+y** undo / redo · **ctrl+s** save

## Walkthrough: a ruin wall worth reusing

Tilemaps earn their keep as *reusable chunks* placed on maps — build
one good ruin and stamp it everywhere:

1. In the sprite editor give a tileset `.spr` four frames: full brick,
   cracked brick, a broken top edge, and a mossy variant (paint the
   moss on a second layer over a copy of frame 1 — see the sprite
   editor's fill recipes for instant moss).
2. Bind it here, grid ~12x6. Pen (`p`) the wall silhouette in full
   brick, ragged at the top with the broken-edge tile.
3. **f** rect-fills the solid interior fast; then scatter cracked and
   mossy variants by hand — variety carries the read, so no more than
   one in four tiles should repeat its neighbor.
4. **k** eyedrops whatever tile is under the cursor when switching
   between variants beats the palette strip round trip.
5. **ctrl+s**, then drag the `.tm` onto a **map** layer — it places as
   one object; **ctrl+d** duplicates copies along the level. Colliders
   stay the map's job (trace the wall top with a chain there).

Next: [The map editor](engine/stock/docs/win-map.md)
