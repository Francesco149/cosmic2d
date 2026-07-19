# The 3d map editor

A 3d map is a heightmap terrain plus placed things: sculpt the ground,
paint its materials, set the water level, and place props, characters,
sprites, and markers on it. The window shows the map through a real 3D
viewport rendered exactly the way the game renders it.

This window is landing in slices. What works today:

## The viewport

- **middle-drag** — orbit the camera around its focus point.
- **shift + middle-drag** — pan the focus across the ground.
- **wheel** — stepped zoom (dolly toward/away from the focus).
- **shift+1** — home the view.

The view responds while the window is **focused** (click it first) — the
same one-gate rule as the map editor: an unfocused viewport never steals
your scroll, and any action outside the window releases it.

The colored bars at the origin are the axes: red = x, green = up,
blue = z. Grid lines are 1 unit apart, brighter every 4.

## Coming in the next slices

Terrain sculpting (raise/lower/flatten/smooth, with ctrl snapping to
level steps), material painting, shade painting, the water level,
walkability overrides, placements (drop any asset in — 2d images become
billboards), markers and NPC routes, and the texture bake. See
`EDITOR3D.md` in the repo docs for the full design.
