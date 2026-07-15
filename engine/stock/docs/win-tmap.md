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

Tip: in the map editor, the **graybox** chip autotiles your colliders into a
`.tm` you can then hand-edit here.

Next: [The map editor](engine/stock/docs/win-map.md)
