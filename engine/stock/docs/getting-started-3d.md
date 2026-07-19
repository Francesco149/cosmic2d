# Your first 3D game

This is the 3D twin of the [Getting started](engine/stock/docs/getting-started.md)
walkthrough: make a little world, a character, and a wandering friend —
almost entirely inside the editors. Budget half an hour.

## 1. Create the project

From the project picker click **+ New project**, keep (or edit) the
folder name, pick the **3D vale** starter, and press **create**. The
editor opens with the game running: green hills, a pond in the dip, a
teal creature you can walk with **arrows / wasd**, and a friend
wandering a loop nearby.

The first boot wrote two files next to `main.lua`:

- `world.terr` — the 3D map (terrain, water, props, markers)
- `art/mascot.fig` — the character both creatures use

Everything you see is read from those files. From here on you mostly
edit assets, not code.

## 2. Reshape the world

Open the spawn menu (right-click the canvas) and pick **3d map**, then
type `world.terr` — or double-click it in the **assets** window. You
get a 3D viewport: middle-drag orbits, wheel zooms.

- Pick the **hgt** tool and drag on the ground: left raises, right
  lowers. Sculpt a hill somewhere you'll recognize.
- Pick **pnt**, add a second material with the **+** swatch, and paint
  a path.
- Press **Ctrl+S** — the game window reloads the world the same frame.
  Walk your new hill.

The full tool set (flatten, smooth, shade, water, walk overrides,
markers) is in [the 3d map editor](engine/stock/docs/win-terr.md).

## 3. Model a prop

Spawn a **mesh** window and type a path like `art/tree.msh` — you get
a unit box in a four-view layout. Select the top face (just click it),
press **e** to extrude, drag faces and points until it reads as a
tree; paint faces with the swatch strip. Save.

Now drag `art/tree.msh` from the assets window into the 3d map and
drop it on the ground: it stands there, with a collider. Save the map
and walk into it — it blocks you. Sprinkle a few.

Modeling moves (edge loops, mirror building, the box-select modes) are
in [the mesh editor](engine/stock/docs/win-mesh.md).

## 4. Make the character yours

Double-click `art/mascot.fig` — the **figure** window opens with the
part tree. On the **parts** tab, click a part and recolor its shapes
with the swatches, or drop your `art/tree.msh` on it to give the poor
creature a hat. On the **pose** tab pick the `walk` clip, press
**space**, and drag the rate dial until the waddle feels right. Save —
both creatures in the game update, because both read this file.

Baking the figure into an 8-direction sprite sheet (for 2D-style
games) is the bake tab; see
[the figure editor](engine/stock/docs/win-figure.md).

## 5. Send the friend somewhere

Back in the 3d map window, pick the **mkr** tool: the friend follows
the `route` marker's polyline. Drag its points to re-route the patrol,
or click new points to lay a longer loop (Enter finishes). Save — the
friend adopts the new route live.

Markers are plain data your code reads: the template's `game.step`
calls `terr3.markers(world.doc, "route")` and just walks the points.
Add your own kinds (`poi`, `portal`, anything) and read them the same
way.

## 6. Where the code comes in

Open `main.lua` (Ctrl+Space, type `main`). It is ~260 lines and every
system is a handful of calls:

- the world loads with `terr3.use`; the ground query is
  `terr3.ground`, walkability is `terr3.walkable` — see
  [3D maps from the editor](engine/stock/docs/scripting.md#3d-maps-from-the-editor-cmterr3).
- the character is `fig.decode` + `fig.build_doc`, posed by its own
  clips with `fig.cycle`, drawn with `fig.emit` — see
  [Figures](engine/stock/docs/scripting.md#figures-rigid-part-characters-cmfig)
  and [the .fig asset](engine/stock/docs/win-figure.md).
- the camera is one `m4.lookat` + `m4.persp`; the whole 3D pipeline is
  [Making a 3D game](engine/stock/docs/scripting.md#making-a-3d-game-the-retro-pipeline).

Change `SPEED`, save, and keep playing — the reload watcher applies
code edits without restarting, position preserved.

## 7. Keep going

- The player menu (**F1**) gives your game rebinding, volumes, and
  accessibility for free.
- **F4** opens the time machine — scrub back through everything you
  just did; it all replays exactly.
- When it feels like a game: project settings (right-click menu) name
  it, pick an icon, and **build** ships a portable player — the same
  export path as any 2D project ([Getting started](engine/stock/docs/getting-started.md)
  walks it).
