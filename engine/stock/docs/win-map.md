# The map editor

A map is collision + placed things. You build a level by **drawing colliders**
(the terrain the game collides against) and **placing sprites/assets** on named
**layers**, plus **markers** (spawns, portals, triggers) the game reads by name.

Direct manipulation is **teidraw-style**: click anything to select and move it;
click again to drill to whatever is beneath.

## Modes (header chips + keys)

- **move** — the default: unified direct manipulation (below). Nothing to
  enter; **esc** always returns here.
- **sel** (`v`) — **box-select**: drag a marquee; it selects and immediately
  returns to *move* so you can manipulate what you caught.
- **col** (`c`) — draw colliders. Places ONLY; it never grabs existing things
  (that's *move*'s job).
- **mkr** (`m`) — drag out a labelled rectangle (spawn / portal / trigger).

## Move mode — select & move anything

- **click** a collider vertex → drag moves that point.
- **click** a collider line → drag moves the whole collider (both ends together).
- **click** a sprite or marker → drag moves it.
- **click again** on the same spot → selects the next thing *underneath* (e.g.
  the collider line, then the sprite it overlaps). This is drill-down.
- **shift+click** adds/removes a sprite or marker from the selection.
- **click empty** deselects. (For a rubber-band selection, use **v** box-select.)
- a single selected marker shows corner knobs — drag one to resize it.

## Drawing colliders (collider tool, line type)

- **drag** from the first click → lays a **2-point line** in one motion.
- **click, then click** → also lays a 2-point line (a rubber-band shows between).
- **shift+click** after → **appends** another point to that last line — extend
  terrain point by point.
- **esc** cancels a placement in progress (and stays in col mode); **esc**
  again returns to move mode.
- **quad / circle** types drag out. **ctrl** while drawing snaps to vertices,
  edges, 45°, and the grid (a guide shows the lock).
- select a chain (in **move** mode) and toggle its **one-way / closed** chips in
  the inspector (closed + solid = fillable ground).

## Layers (right panel)

Rows are front-at-top. Each has two toggles:

- **e** — editor-visible. Off = hidden while you work (declutter); the game is
  unaffected.
- **g** — game-on. Off = the layer's placements act as if they don't exist
  in-game (no draw, no colliders, no name); shown dimmed in the editor.

Name a layer and your code can reach its placements by name via
`cm.map.ref("name")`. Clicking a placement makes its layer active; **lock**
confines picking and new drops to the active layer.

The **par** row edits the active layer's parallax factors (x, then y):
1 = world speed, 0.5 = a half-speed backdrop, 0 = screen-fixed. The game
applies them in `draw_places`; the editor canvas always shows authored
positions. Parallax is visual only — colliders and markers stay
world-space.

## Grouping

- **ctrl+g** groups the selection — they move together; a faint hull shows the
  bounds. Click a member selects the whole group.
- **click again** on a grouped member drills *into* the group to move just that
  item.
- **ctrl+shift+g** ungroups.

## Keys

- **c** col · **v** box-select · **m** markers · **esc** back to move
- **arrows** nudge 1px (**shift** ×8) · **del** removes the selection
- **[ / ]** send a placement back / forward in its layer
- **ctrl+a** all · **ctrl+c/x/v** copy/cut/paste · **ctrl+d** duplicate
- **ctrl+g** group · **ctrl+shift+g** ungroup
- **shift+1** fit the map · **shift+2** fit the selection
- **ctrl+wheel** dials the grid step · **wheel / middle-drag** zoom / pan
- **ctrl+s** save (the running game hot-reloads the map)

## Placing assets

Drag a `.spr` / `.png` / `.tm` from the assets window (or drop a file) onto the
map to place it. Any other asset (a `.song`, `.ins`, …) places as a
**named ref** — a code handle at a position. A missing asset draws a magenta
checkerboard so a broken reference is loud, not silent.

## Walkthrough: a layered lakeside with water

A small side-view scene that exercises the map editor's strongest
pieces — named layers, parallax, fillable ground, markers — plus a
couple of sprite-editor layers feeding it.

1. **Tiles first** (sprite editor, see its *Fill recipes*): a 32x32
   grass block (a *fbm* solid fill in two greens, then hand-draw a
   lighter 2px lip on top on a second layer), a water tile (*noise*,
   deep blue → cyan, a little dither), and a wide soft hill silhouette
   (64x32, one flat mid-green — it will live in the far background).
2. **Layers**: in the right panel make four named layers, front-at-top:
   `fg`, `main`, `water`, `bg`. Activate `bg` and set its **par** row to
   `0.5 0.9` — the hills now scroll at half speed and the scene gets
   depth for free.
3. **Backdrop**: drag the hill sprite in from the assets window a few
   times along the horizon; overlap them at slightly different heights.
   **lock** keeps stray clicks on the active layer while you arrange.
4. **Ground**: activate `main` and lay a row of grass blocks
   (**ctrl+d** duplicates the selection; **ctrl** while dragging snaps).
   Leave a gap for the lake. Then **c** and trace the walkable surface:
   drag the first line along the ground top, **shift+click** to extend
   it point by point up the banks. For a solid platform, select the
   chain and toggle **closed** in the inspector (closed + solid =
   fillable ground).
5. **Water**: activate `water` and tile the water sprite across the
   gap, one or two rows deep. Because it sits on its own named layer,
   code can find it (`cm.map.ref("water")`) — a two-line `game.step`
   bobbing the layer's placements a pixel, or a drowning check against
   the marker below, turns the picture into water that behaves.
6. **Markers**: **m**, drag a `spawn` rect on the near bank and a
   `goal` on the far one; a `water` trigger rect over the lake gives
   code its bounds without caring how many tiles you placed.
7. **Foreground**: a couple of grass tufts on `fg`, nudged over the
   ground line, so the player walks *behind* something.
8. **ctrl+s** — the running game hot-reloads the map in place. Walk it,
   feel the gap width, come back, nudge, save again.

Next: [Using the editor](engine/stock/docs/editor.md) ·
[Writing a game](engine/stock/docs/scripting.md)
