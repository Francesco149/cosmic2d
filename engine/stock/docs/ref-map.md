# The map window reference — every control and gesture

This is the complete control-surface reference for the Map window. The guided
path is [the Map tutorial](engine/stock/docs/win-map.md); this page is for when
you are holding the window and want to know exactly what the thing under your
cursor does.

## The window at a glance

The header holds four modes — **move / sel / col / mkr** — plus **lyr**,
**giz**, and **mk** visibility chips. The center is an independently zoomable
map view. A **LAYERS** panel sits at right when enabled. The bottom inspector
changes with the selected map item; with nothing selected it edits the map
itself.

A window with no file bound is the new-map door. Type a project-relative path
and press Enter; `.map` is forced when absent. A new map starts at the
project's design resolution with grid 8. If the path exists, choose **open**,
**overwrite**, or **cancel** — creation never silently replaces it. Dragging a
`.map` onto a Map window rebinds the window instead of placing that map inside
it. Multiple paths can be open in separate windows.

## Header and document state

- **move** — unified direct manipulation, and the default mode. Click or drag
  existing colliders, placements, groups, and markers. Esc returns here from
  every placement mode.
- **sel** — one-shot box selection. Drag a marquee; on release the window
  returns to **move** with the caught placements and markers selected.
- **col** — place free colliders. Its bottom strip selects **line**, **quad**,
  or **circle** and the new-line one-way flag. This mode places only; switch to
  **move** to manipulate something already present.
- **mkr** — drag out new marker rectangles. This mode also places only;
  existing markers move and resize in **move**.
- **lyr** — show or hide the right-side layer panel. A window too narrow to
  keep at least 60px of view hides the panel automatically.
- **giz** — show free and attached collider gizmos. They are on by default and
  forced visible in **col** mode.
- **mk** — show marker rectangles and labels. It is on by default and forced
  visible in **mkr** mode.
- **?** — opens [the Map tutorial](engine/stock/docs/win-map.md).
- The amber dot and title `*` mean the working CMAP bytes differ from disk.
  **ctrl+s** saves; **reset** restores disk as an undoable edit.
  **ctrl+z / ctrl+y** walk the journal.

The map window has no edit/done split: a bound, focused map is always an
authoring surface. Header visibility chips and mode, layer focus/lock, camera,
and the temporary grid override are window layout state, not map data.

## View lock, camera, and readout

Focusing a bound Map window gives it the green
**EDITING — wheel/mmb here · esc out** chip and accent border. Focus is the
single view gate:

- **wheel** zooms at the pointer when it is over the view; from elsewhere it
  zooms around the view center. Range is 0.05x to 32x.
- **middle-drag** pans the map. While focused, the map owns middle-drag and
  wheel even if the pointer has wandered outside the window.
- **shift+1** fits the complete map bounds.
- **shift+2** fits the selected placements/markers, or the selected free
  collider. It does nothing without a fitting target.
- Esc first cancels an in-flight gesture, then returns a placement mode to
  **move**, clears a collider/attached selection, clears an item selection,
  and finally releases focus to the editor canvas.

At the view's top-right, `x,y · zoom% · grid N` names the rounded authored map
pixel under the pointer, the view zoom, and the snap step. Off the view it
shows only zoom and grid. Coordinates are top-left-origin: x grows right and y
grows down.

## Move mode — direct manipulation and drill-down

The item under the pointer highlights before you press. One left-button
gesture means the same thing across kinds:

- Drag a free collider's square vertex handle to move that point. Drag its
  edge or a circle's interior to move the whole collider.
- Drag a placement or marker to move it. A selected marker gains four corner
  knobs; re-grab one to resize from the opposite corner.
- Drag an attached collider handle while its owning placement is selected to
  edit the collider in world view while retaining placement-relative data.
- Click empty space to clear the selection.

When objects overlap, click again at nearly the same screen point to drill
front-to-back. The stack is collider vertices, collider edges, markers, then
placements in visual order. A grouped item inserts its group as a level: first
click selects/moves the group, the next reaches the individual member, and
later clicks reach whatever lies underneath. Moving the pointer more than the
small re-click tolerance starts a fresh drill.

**Shift+click** toggles a placement or marker in a multi-selection. Free
colliders are selected singly. The selection outline is green; group hulls are
faint violet and brighten when selected.

## Box selection and grouping

Press **v** or click **sel**, then drag a marquee. Intersecting visible
placements and shown markers are selected; a still click clears them. Release
returns to **move**, ready to drag the result.

- **ctrl+g** groups at least two selected placements/markers under one saved
  group id. Group members move together and may span layers.
- **ctrl+shift+g** removes every group touched by the selection.
- Free colliders do not join groups.
- Copying and pasting a group assigns a fresh id, so the pasted set remains a
  group without joining the original.

## Collider types and game meaning

Free colliders live in the map's collision list. Attached colliders live under
a placement and move with it, but the running collision world treats both as
static geometry.

- **line, solid** — an open chain whose segments block from both sides. A
  shallow segment is floor/ceiling; steeper than 45 degrees is a wall.
- **line, one-way** — dashed support from above. Actors may rise through it;
  the mover's `drop=true` option ignores it for that step. Shallow slopes work;
  steep one-ways are not support and are omitted from the collision world.
- **closed solid line** — a polygon. Its edges block and its interior answers
  `world:solid_at`; it is the normal terrain-mass shape.
- **quad** — rectangle sugar, stored as x/y/w/h and swept as a closed loop.
- **circle** — an overlap/query zone for hazards and hit areas. The AABB mover
  does not sweep circles; use `world:circles(x,y,w,h)`.

Coordinates are integer map pixels. A chain needs at least two points open or
three closed. Deleting the selected vertex removes the whole collider if
another deletion would cross that minimum.

## Drawing free colliders — col

The bottom strip chooses what the next empty press creates:

- **line** — drag from A to B for a two-point chain, or click A and click B.
  A rubber band previews the second form. Afterward, **Shift+click** appends a
  point to the most recently created line. Each initial line or appended point
  is one undo step.
- **quad** — drag between opposite corners. Cross-over is normalized; width
  and height stay at least 1.
- **circle** — press at the center and drag the radius. The exact selected
  **x / y / r** fields clamp radius to at least 1.
- **one-way** — affects newly drawn lines. When a selected chain is showing,
  the same-position chip edits that chain instead.
- **closed** — appears for a selected chain and toggles its closing segment.
  Closed plus solid creates filled terrain. There is no keyboard close command;
  the chip is the authoritative door.

**col** never picks existing geometry from an empty press, which makes drawing
from a busy edge predictable. Return to **move** to edit. The selected chain's
bottom hint distinguishes moving a vertex from moving the whole collider.

## CTRL snapping

Plain placement and dragging are free pixel movement. Hold Ctrl before or
during a gesture for the precise variant. A guide dot, line, segment, or ray
shows what won. Targets are chosen in this order:

1. Collider vertices and placement corners.
2. Collider/placement edges, plus placement centers for object movement.
3. Tile edges inside a placed `.tm`.
4. For collider points with a previous point, horizontal, vertical, or true
   45-degree lock.
5. The current grid step.

The threshold is about six screen pixels, so zooming changes map-space reach
without changing how sticky snapping feels to the hand. A dragged item does
not snap to its own starting geometry.

With **line + col + Ctrl**, hovering an exposed solid edge in a placed tilemap
can propose the complete contiguous **edge-run**. Its bright endpoint dots and
full line preview are the confirmation; one click lays that whole collider
segment. Interior tile edges and empty-cell boundaries do not propose a run.

**ctrl+wheel** steps the active window's snap grid through 1, 2, 4, 8, 16, 32,
and 64. This is a window override shown in the readout. To change the map's
saved default for every new window, clear the selection and edit **grid** in
the map inspector (1 through 256).

## Markers — mkr

In **mkr**, drag a rectangle at least 2x2px. Ctrl snaps both corners. A new
marker starts with kind `marker` and becomes selected immediately. Its bottom
inspector provides:

- **x / y** — exact top-left map coordinates.
- **kind** — the gameplay category, such as `spawn`, `goal`, `portal`,
  `trigger`, `npc`, or any project-defined word. Empty submissions are
  refused.
- **label** — a short author-facing or display name.
- **note** — free authoring context stored with the asset.
- **k=v** — whitespace-separated extra fields such as
  `to=south-trail facing=left`. Tokens without `=` are ignored; values cannot
  contain spaces in this compact editor form.

Markers never collide or draw in the shipped game by themselves. Read them in
file order from `room.doc.markers`; `cm.map.extras(marker)` turns extras into a
keyed table.

## Placing and opening assets

Drag any asset with an extension from Assets and release it over the map view.
The ghost is centered under the pointer; Ctrl snapping updates while carrying.
It becomes a placement on the active layer:

- `.spr`, `.png`, and `.tm` are visual. Sprites draw their baked strip or one
  chosen animation clip; tilemaps draw their tileset grid.
- Any other extension becomes a labelled named-ref tag. Give it a unique
  placement name and resolve it from code with `cm.map.ref(name)`.
- An unreadable visual path shows a loud magenta checkerboard. Missing refs do
  not silently disappear.
- An OS file dropped over the map is first imported into the project, then
  placed through the same door.

Double-click a placement in **move** to open its natural editor beside the
map. A sprite opens Sprite, a tilemap opens Tilemap, and a PNG opens Image.
Double-clicking a marker only selects its inspector; it has no separate asset.

## The placement inspector

Exactly one selected placement exposes:

- **x / y** — integer top-left coordinates.
- **name** — optional unique code address. Clearing it makes the placement
  anonymous. Pasted placements deliberately drop names so code addresses do
  not duplicate.
- **L** — 1-based layer index, clamped to the current layer count.
- **vis** — for visual assets, show the image. Off turns it into a named-ref
  tag while preserving path and code address.
- **flip** — horizontal image flip, available only while a visual is shown.
- **anim:name** — for a shown `.spr` with clips, click to cycle no clip, then
  each clip. A selected clip auto-plays in editor time and sim time.
- **+col** — opens an attached-collider picker: **one-way** fits a line across
  the asset's top, **line** fits the same solid line, **quad** fits its bounds,
  and **circle** fits the largest inscribed circle. The new collider selects
  for immediate handle editing.
- The remaining dim text names the resolved layer and source path.

Attached coordinates are stored relative to the placement. Moving the art
moves its collision. Handles appear only while that placement is the single
selection; Delete with an attached collider selected removes it.

## Layers panel

Rows are drawn **front at top**, while layer indices count back-to-front. The
highlight is the active layer; clicking a placement also activates its layer.

- **e** — editor-visible. Off hides that layer's placements from the window
  and picking, but does not change the game.
- **g** — game-on. Off makes the layer's placements, attached colliders, and
  names act as if absent in-game. They remain dimly visible in the editor so
  the layer can be restored.
- **lock** — picking, marquee selection, and new drops stay on the active
  layer. Free colliders and markers remain global.
- **par** x/y fields — presentation parallax. `1` follows the world camera,
  `0.5` moves at half speed, and `0` is screen-fixed. The editor always shows
  authored coordinates. Colliders, markers, and named refs remain world-space,
  so keep collision-carrying placements on `1 1`.
- **+** — add a front layer named `layer N` and activate it.
- **x** — delete the active layer when more than one exists. Its placements
  move to the layer immediately behind; art is never silently deleted.
- **^ / v** — move the active layer one step forward/back. Placements follow
  their layer.
- **footer name field** — rename the active layer on Enter.

Within a layer, later placements draw in front. `[` and `]` move selected
placements backward/forward while retaining the selection's internal order.
Markers and free colliders do not have visual z-order.

## The map inspector — nothing selected

Clear selection in **move** to edit the asset itself:

- **w / h** — map bounds in pixels, each at least 16. The collision world also
  treats the outside side/bottom bounds as solid.
- **grid** — the saved snap default, clamped from 1 to 256.
- **bg** — three non-negative floating values `r g b`. This is the editor map
  well tint and stored map background metadata; your game decides how to use
  it.
- **name** — the map's authoring name.
- **fill** — when on, `map.draw_fill` can render closed solids, open lines, and
  one-ways as temporary graybox geometry. It does not change editor gizmos.
- **graybox** — immediately writes or regenerates `<map>_gb.tm` from free
  colliders, inserts it at `(0,0)` on layer 1 as placement name `graybox` when
  absent, and turns **fill** off. Attached colliders and circles are not baked.

Graybox publication is a real filesystem write and is walled while parked in
the past. Undo can remove the map placement/change, but the generated `.tm`
remains as an ordinary recoverable project asset.

## Clipboard, order, nudge, and deletion

- **ctrl+a** selects every placement and marker. It does not select free
  colliders.
- **ctrl+c** copies selected placements/markers to the session map clipboard.
- **ctrl+x** copies, then removes them as one edit.
- **ctrl+v** pastes centered under the pointer when it is over the view;
  otherwise it offsets by one grid step. Names drop; groups get fresh ids.
- **ctrl+d** duplicates the selection by one grid step.
- **left / right / up / down** nudge a selected item, free collider, attached
  collider, or selected vertex 1px. Hold Shift for 8px. Nudge and bracket
  actions repeat while held.
- **[ / ]** send selected placements backward/forward.
- **Delete / Backspace** remove the selected placements/markers, collider
  vertex/collider, or attached collider according to the active selection.

Every finished drag, nudge step, append, structure button, field submission,
paste, and delete is a journal entry. Pure selection, mode, camera, layer
focus, lock, and visibility chips in the header are not document edits.

## Keyboard summary

- **c** col · **v** one-shot box select · **m** marker placement · **esc**
  cancel/back to move/clear/unfocus.
- **arrows** nudge 1px · **shift+arrows** nudge 8px · **Delete/Backspace**
  remove.
- **[ / ]** placement z · **ctrl+a/c/x/v/d** select all, copy, cut, paste,
  duplicate.
- **ctrl+g / ctrl+shift+g** group / ungroup.
- **shift+1 / shift+2** fit map / fit selection.
- **wheel / middle-drag** zoom / pan while focused · **ctrl+wheel** change the
  window grid override.
- **ctrl+s** save · **ctrl+z / ctrl+y** undo / redo.

The standard shell still owns **ctrl+w**, Ctrl+Tab focus cycling, window move
and resize, and Alt gestures. Map's plain keys are claimed only while its
window is focused; they never feed the running game.

## Save, hot reload, rewind, and failure boundaries

Working CMAP bytes and their 512-entry journal survive closing the window and
editor restart. Unsaved work is visible in Map but not in the running game.
**ctrl+s** atomically replaces the `.map`, bumps asset caches, and submits a
recorded `cm.map.reload(path)` for the next sim frame. If that map is the live
room, the existing instance and collision-world wrapper rebuild in place;
held game references remain valid. A non-live map save publishes normally and
the reload request logs that it was ignored.

Because reload is a recorded event and logical map runtime lives in captured
buffers, traces and rewind cross map edits with matching collision,
placements, layers, and markers. While parked in past state, asset writes are
walled. Bring the frame back to the present before saving or grayboxing.

An atomic save failure keeps the previous disk file and all dirty working
bytes, summons the console, and leaves Ctrl+S as a safe retry. **reset** is not
a destructive filesystem revert: it places the disk generation into the
journal, so ctrl+z can recover the discarded working version.

## CMAP asset and runtime contract

A `.map` is a versioned, skip-tolerant CMAP container with:

- HEAD: name, width, height, grid, and background tint.
- COLL: free chain, quad, and circle geometry with one-way/closed flags.
- PLCE: project-relative path, layer, visibility/flip, integer position,
  optional name and animation, group id, plus relative attached colliders.
- LAYR: ordered names, editor-visible/game-on flags, and optional parallax.
- MRKR: integer rectangle, kind, label, note, group id, and ordered extras.
- FLGS when collider fill is disabled, plus an integrity tail.

Tilemaps are pure visuals; their collision is still authored here. Named
placements are addressable through `cm.map.get`/`cm.map.ref`. Map layers gate
placements and their attached collision, not free terrain or markers.

The normal runtime shape is:

    local map = cm.require("cm.map")
    local room = map.use {
      path = cm.main.args.project .. "/maps/moonlit-crossing.map",
      name = "mygame.room",
    }

    local nx, ny, hit = room.world:move(x, y, w, h, dx, dy, {
      ground = was_grounded,
      drop = drop_pressed,
    })

    gfx.layer(1)
    map.draw_fill(room, camera_x, camera_y)
    map.draw_places(room, camera_x, camera_y)

Read markers from `room.doc.markers`, extras through `map.extras`, circles
through `room.world:circles`, and named assets through `map.ref`. If you cache
derived marker lookups, call `map.sync(room)` and rebuild them when `room.rev`
changes after save, rewind, or room switch.

Back to [the Map tutorial](engine/stock/docs/win-map.md), continue with
[the tilemap tutorial](engine/stock/docs/win-tmap.md), or open the complete
[map and collision scripting reference](engine/stock/docs/scripting.md#loading-and-drawing-a-map-cmmap).
