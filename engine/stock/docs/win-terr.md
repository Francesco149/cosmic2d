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

**Custom brush stamps**: drop a sprite or image onto the map while a
brush tool is active and it becomes the brush shape — its alpha and
brightness are the paint weight, fit to the brush circle. Draw a stamp
in the sprite editor (white shape on transparency = a full-strength
brush), then sculpt hills, paint paths, or shade with it. The
`stamp: name  x` chip in the bottom strip clears it back to the round
brush. Dropping an image with the **select** tool still places a
billboard as usual.

## Texturing the ground

Materials can carry a **texture**: with the paint tool active, drop a
sprite or image onto a material's swatch in the bottom strip and that
material now samples the image, repeating once per tile (the corner
notch marks textured swatches; the `tex: name  x` chip clears the
active one). Draw ground tiles in the sprite editor — grass, dirt,
cobbles — and paint with them like any material.

Textures show through the **bake**: with the select tool and nothing
selected, the bottom strip offers **bake tex** — it renders the whole
painted ground (textures, blends, painted shade) into an atlas image
saved beside the map, and the viewport and the game draw it. Painting
again marks the bake **stale** and the ground falls back to live flat
colors until you bake again; the **x** chip turns the atlas off for
good. Ctrl+S saves the map's bake state with everything else.

## Placing things

**Drag any asset in from the assets window** and release over the
ground: a 2D image (`.png`/`.spr`) becomes an upright **billboard**
standing on the terrain; a mesh or figure places as itself (with an
automatic collider); anything else becomes a named reference the game
can look up. Unbuilt asset kinds show as a tinted stand-in box.

With the **sel** tool (`v`):

- **click** a prop or marker to select it; **drag** moves it along the
  ground (**ctrl snaps** to the half-tile lattice); click empty ground
  to deselect.
- **arrows** nudge; **,** and **.** rotate in 15-degree steps;
  **-** and **=** resize; **del** deletes; **ctrl+d** duplicates.
- the bottom strip edits the selection: a **name** field (games address
  named props from code), **abs** (anchor to absolute height instead of
  the ground), **caster** (casts a baked shadow), **blocker** (stamps
  the walk grid), and the collider chip (none / auto box / editable
  box).

The **mkr** tool (`n`) places markers — pick a kind in the strip
(spawn / poi / npc / portal / route) and click. The **route** kind lays
a patrol polyline: each click adds a point, **enter** finishes. Games
read routes for NPC paths; select a route to drag its points.

## What the game reads

`cm.terr3.use{ path = "maps/vale.terr", name = "world" }` loads the
map; `terr3.ground(x, z)` is the exact rendered height, walkability
comes from the derived grid + your overrides, colliders come from prop
collider boxes, and markers/props are readable by name and kind. See
the scripting guide's 3D sections.
