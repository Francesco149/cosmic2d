# The 3d map editor

A 3d map is a heightmap terrain plus placed things: sculpt the ground,
paint its materials, set the water level, and place props, characters,
sprites, and markers on it. The window shows the map through a real 3D
viewport rendered exactly the way the game renders it — a `.terr` asset
games load with `cm.terr3`.

Open one from the spawn menu ("3d map"), or double-click a `.terr` in
the assets window. An empty window offers a path field — press enter on
the suggested name (or type your own) to create a fresh flat map.
Ctrl+S saves; a running game using the map hot-reloads it, and undo
(ctrl+z) walks whole gestures back — one brush stroke is one step.

## The viewport

- **middle-drag** — orbit the camera around its focus point.
- **shift + middle-drag** — pan the focus across the ground.
- **wheel** — stepped zoom toward/away from the focus.
- **shift+1** — frame the whole map.

The view responds while the window is **focused** (click it first) —
the same one-gate rule as the map editor. The gold diamond marks the
spawn point.

## Tools (header chips + keys)

- **view** (`v`) — camera only; the inspector shows the map's facts.
- **hgt** (`h`) — sculpt: **left-drag raises**, **right-drag lowers**,
  with a smooth radial falloff. Hold ctrl to **snap to level steps**
  (half a tile) — terraces and cliffs the WC3 way.
- **flt** (`f`) — flatten toward the height under the press.
- **smo** (`m`) — smooth toward the neighbor average.
- **pnt** (`p`) — paint the active material's weight; **right erases**.
  The material swatches live in the bottom strip — click to choose,
  `+` adds one (up to 8). Ground colors blend where weights mix.
- **shd** (`s`) — hand-painted shade: **left darkens, right lightens**.
  Painted shadows are most of the era look — use them.
- **wtr** (`w`) — press and drag up/down to set the water level (ctrl
  snaps to 0.25 steps). Pressing on a dry map turns water on at the
  ground height under the cursor. Shorelines are wherever ground dips
  below the level.
- **wlk** (`k`) — walkability: the overlay tints walkable cells green
  and blocked cells red (steep slopes, deep water, and blocking props
  are derived automatically). **Left forces blocked**,
  **right forces walkable**, **ctrl+click clears** the override —
  overridden cells show brighter with a center dot.

## The brush

**ctrl+wheel** dials the radius; **[** and **]** step the strength.
The ring under the cursor is the live brush footprint.

## What the game reads

`cm.terr3.use{ path = "maps/vale.terr", name = "world" }` loads the
map; `terr3.ground(x, z)` is the exact rendered height, walkability
comes from the derived grid + your overrides, and markers/props are
readable by name and kind. See the scripting guide's 3D sections.

Placements (props, billboards, characters) and markers arrive in this
window's next slice; today they author through code or a generator
script writing the same `.terr`.
