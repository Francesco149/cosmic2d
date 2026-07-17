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
map to place it. Any other asset (a `.song`, `.ins`, …) places as a **named
ref** — a code handle at a position. A missing asset draws a magenta
checkerboard so a broken reference is loud, not silent.

Next: [Using the editor](engine/stock/docs/editor.md) ·
[Writing a game](engine/stock/docs/scripting.md)
