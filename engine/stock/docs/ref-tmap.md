# The tilemap editor reference — every tool, field and gesture

This is the complete control-surface reference for the Tilemap window. The
guided path is [the Tilemap tutorial](engine/stock/docs/win-tmap.md); this page
is for when you are holding the window and want the exact behavior under the
pointer.

## The window at a glance

In edit mode, the narrow left rail is **P / E / F / K** plus the current tile.
The center is the cell grid. The first bottom row is the tileset palette; the
last row is **w**, **h**, **tile**, and **tileset**. View mode replaces those
controls with a clean aspect-fit preview and one metadata line.

A tilemap is a pure-visual rectangular grid. Cell `0` is transparent; cell id
`N` draws frame `N` from one horizontal tileset strip. Collision, markers,
placement names, layers, tint, and parallax all belong to the Map window.

## Create, open and rebind

- Spawn **tilemap** from the empty-canvas menu to get an unbound window. Its
  path field starts under `maps/` with a unique three-word `.tm` name. Edit the
  project-relative path and press Enter; `.tm` is appended when omitted.
- A path that does not exist creates unsaved working bytes for an empty
  16x16-cell grid at 16px per cell with no tileset. The new window enters edit
  mode. No source file exists until Ctrl+S.
- If the typed path already exists on disk or in recovered working state, the
  window offers **open**, **overwrite**, and **cancel**. Open adopts it;
  overwrite deliberately starts a fresh grid; cancel returns to the field.
- Double-click a `.tm` in Assets, use Ctrl+Space to find it, drag it onto empty
  canvas, or double-click one of its Map placements to open another Tilemap
  window. Dragging a different `.tm` from Assets onto an existing Tilemap
  window rebinds that window to the dropped asset.
- Multiple windows bound to one path share the same working document and undo
  journal, while their tool, selected tile, pan, zoom, and edit/view modes are
  window-local.

## Title bar and header

- The title is the source basename. View mode adds `· view`; unsaved working
  bytes add a trailing `*` and an amber dot.
- **edit / done** toggles the editing surface and the read-only preview. It does
  not save and does not discard a live journal.
- **reset** appears beside the dirty mark. It replaces working bytes with the
  last saved source as a normal, undoable edit. Ctrl+Z can therefore undo a
  reset.
- **?** opens the Tilemap tutorial. The remaining title-bar move, resize,
  selection, focus, and close gestures are shared editor chrome.

## View mode

The whole grid is aspect-fit over a checkerboard; empty cells show through.
The bottom line reads `W×H cells · tile px · tileset path`, or `no tileset`.
There are no painting gestures, palette, grid fields, or window view lock in
this mode. Wheel and middle-drag fall through to the infinite editor canvas,
and right-click may open the canvas spawn menu.

## The focused view lock

New Tilemap windows begin focused. Later, click the title, a palette swatch,
or a field to refocus without changing cells. A grid press also focuses, but
immediately applies the armed tool. The green **EDITING** border and banner
mean this window owns the view:

- **wheel** — zoom from 0.05x through 32x, anchored under the pointer while it
  is over the grid and at the view center otherwise;
- **middle-drag** — pan the tile grid, even when the press begins over another
  part of this focused window;
- **shift+1** — **fit** the full grid back into the view;
- **Esc** — first cancels a live paint/fill gesture, then releases the view
  lock through the editor's normal Esc ladder.

An editable but unfocused Tilemap window is inert to wheel and middle-drag, so
the surrounding editor canvas receives them. The grid draws internal lines
only while one cell is at least five screen pixels wide.

## Address and hover feedback

The top-right bay shows `cell x,y · tile N · zoom` while the pointer is inside
the authored grid. Cell coordinates are zero-based, with `(0,0)` at top-left;
the tile number is the value already stored under the pointer, so empty reads
as tile 0. Over checkerboard outside the grid, the bay shows zoom alone. A thin
outline marks the hovered cell unless middle-pan is active.

## The tool rail

The four square chips and their exact key bindings are:

- **P — pen** (`p`, hint **pen**). Left-click or left-drag stores the selected
  tile id in every visited cell. Each continuous press is one undo entry.
  Right-click or right-drag erases visited cells without changing tools.
- **E — eraser** (`e`, hint **eraser**). Left or right button stores tile 0.
  It has the pen's continuous-stroke shape and journal boundary.
- **F — fill** (`f`, hint **fill**). This is a rectangular fill, not a flood
  bucket: press one corner, drag to the other, and release. The live outline
  includes both endpoint cells. Left fills with the selected id; right fills
  with tile 0. A click is a one-cell rectangle. Either corner order works and
  the result clamps to the grid.
- **K — pick** (`k`, hint **pick**). Left-click a nonempty cell to select its
  stored tile id. Empty cells are ignored. Pick stays armed until another tool
  is chosen; right-button still performs a one-cell/stroke erase.

The square at the rail's bottom previews the selected tile. It is feedback,
not a button. A missing or out-of-range tile leaves the well blank.

## Canvas mouse grammar

- Left press applies the active tool as described above.
- Right press is always owned by an editable Tilemap window and erases using
  the active tool's shape. It never opens the spawn menu here; use the title
  band, another window, or empty canvas for that menu.
- A pen or eraser stroke visits cells as pointer events arrive. Move at a pace
  that crosses the cells you intend to paint; use Fill for guaranteed solid
  rectangles.
- A live Pen/Eraser stroke mutates the decoded view before release. Esc restores
  the last committed working bytes and cancels that entire stroke. A live Fill
  is preview-only until release, so Esc simply drops its rectangle.
- Pressing a tool key or clicking its rail chip changes tools without changing
  the selected tile.

## Tileset palette strip

The strip beneath the view shows the tileset's frames from left to right. The
first swatch is tile id 1; cell 0 is empty and has no palette swatch.

- Left-click a swatch to select that id. If Eraser was active, palette choice
  returns to Pen; Fill and Pick remain armed.
- A `.spr` tileset uses its baked sibling `.png`. Each sprite frame must be one
  tile and the bake must be a horizontal strip. A raw `.png` path also works;
  ids are consecutive `tile`-pixel slices across its first row.
- Only swatches that fit the window are shown; this v1 strip does not scroll.
  A wide tileset may therefore be easier to use in a wider Tilemap window.
- The renderer resolves the tileset under the project root first, then accepts
  an engine-root path such as `engine/stock/spr/tiles.spr`. Project-relative
  paths are the portable choice.
- If the path is empty the canvas says `no tileset — set one below`. If the
  source or baked strip cannot load, it names the unreadable path. Existing
  ids remain in the CTLM either way.

## Grid fields

Every field commits on Enter and becomes one undoable edit.

- **w** — cell columns, integer 1 or greater.
- **h** — cell rows, integer 1 or greater.
- **tile** — square size in pixels, integer 1 or greater. Changing it changes
  the grid's visual/map scale and how the strip is sliced; it does not resample
  cells or rewrite ids.
- **tileset** — the `.spr` or `.png` path used for the palette and rendering.
  Changing it retargets existing ids. If the new strip has fewer frames, ids
  beyond its width become transparent holes rather than errors.

Resize is anchored at the top-left. Growing **w** or **h** preserves the old
overlap and adds empty cells on the right or bottom. Shrinking crops the right
columns or bottom rows immediately; Ctrl+Z is the recovery door.

## Save, undo, recovery and refresh

- **ctrl+s** saves the focused `.tm` as one atomic replacement. A failed write
  leaves the previous file intact, keeps the working document dirty, logs the
  reason, and opens the Console.
- **ctrl+z / ctrl+y** undo and redo finished gestures and field changes. A
  stroke, rectangular fill, field submission, or reset is one journal entry.
  The journal keeps at most 512 snapshots for this asset.
- Unsaved working bytes and their journal normally survive window close and an
  editor restart. Closing a Tilemap window is therefore not a discard action;
  Ctrl+S remains the durable source boundary.
- Saving bumps the shared asset epoch. Open Map windows, Assets thumbnails, and
  running games invalidate their tilemap caches and read the new grid on the
  next frame. Unsaved cell edits stay visible only in Tilemap.
- Rewind captures editor working state. While parked in the past, edits are
  ephemeral and Ctrl+S is walled; **bring back** is the explicit route for
  making historical work present and saveable.

## Placing a tilemap on a map

Drag a saved `.tm` from Assets into a Map view. Its placement rectangle is
`w × tile` by `h × tile` map pixels, centered under the carry pointer. Plain
drop is free-pixel placement; Ctrl engages Map's vertex, edge, center, tile
edge, and grid snapping. The active Map layer receives it.

After placement, Map owns the object-level controls: select/move, exact x/y,
name, layer, visibility, z-order, grouping, duplicate, copy/paste, and delete.
Ctrl+D duplicates the placement record; both records still name one `.tm`, so
a Tilemap save updates every copy. Double-click a placement in Map's move mode
opens the shared source here.

Tilemap cells never create collision. In Map's line/collider mode, Ctrl-hover
near an exposed solid-to-empty tile edge proposes an **edge-run** across the
whole contiguous face. One click authors that collider segment in the map.
Those colliders stay independent if the art later changes.

## Keys in one place

- `p` — pen · `e` — eraser · `f` — rectangular fill · `k` — pick
- `shift+1` — fit the full grid
- `ctrl+s` — save · `ctrl+z` — undo · `ctrl+y` or `ctrl+shift+z` — redo
- `Esc` — cancel live gesture, then release the focused view lock
- `Ctrl+W` — close the window without discarding project working state

The tool keys are active only for a bound Tilemap window in edit mode. Fit is
available whenever a file is bound. Editor-reserved shortcuts still win over
tool keys and focused text fields consume ordinary typing until submitted.

## CTLM v1 file contract

`.tm` is the canonical CTLM chunk container:

    HEAD v1  i32 width, i32 height, u32 tile pixels, string tileset path
    GRID v1  width × height little-endian u16 ids, row-major
    TAIL v1  empty terminator chunk

Rows run top to bottom and columns left to right. Id 0 is empty; id N draws
frame N. Decode refuses a missing HEAD, missing TAIL, or a GRID whose byte size
is not exactly `w × h × 2`. Unknown chunks remain forward-compatible through
the shared chunk reader, but this editor writes canonical HEAD/GRID/TAIL bytes.

`cm.tmap.blank`, `get`, `set`, `resize`, `fill_rect`, `encode`, `decode`, and
`save` expose the same model to code. `cm.tmap.draw` performs a culled batched
draw; `cm.map.draw_places` is the normal path for placed grids. Tile ids beyond
the loaded strip are skipped safely.

## Deliberate v1 limits

There are no autotiling rules, multi-cell stamp brushes, animated tile ids,
rotated/flipped cells, per-cell tint, layers inside a `.tm`, palette scrolling,
or collision flags in CTLM v1. Build reusable visual chunks here; use Map
layers and placement controls for composition, and Map colliders for gameplay.

Full reference: [the hands-on Tilemap tutorial](engine/stock/docs/win-tmap.md),
[every Map control](engine/stock/docs/ref-map.md), and
[the `cm.tmap` API](engine/stock/docs/scripting.md#tilemaps-cmtmap).
