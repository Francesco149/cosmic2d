# The assets browser

Browse the project's files. Double-click one to open it in the right editor;
drag one onto the canvas (or a map) to place or bind it.

## Keys

- **arrows** move the selection · **enter** open the selected asset
- **r** rename/move (a bar opens with the full path — edit the name, or the
  folder part to move; **enter** commits, **esc** cancels). A `.spr` takes its
  baked files along; open windows, unsaved edits, and undo history follow.
  Code that referenced the old name falls to the engine's invalid-asset
  fallbacks until you update it — renaming never corrupts a running game.
- **del** delete (arms a red confirm; **del** again to execute, **esc** cancels)
- **c** copy the selected saved asset to another known project. Choose the
  target with **up/down**, then press **enter** (or click **copy**); **esc**
  cancels. Open an out-of-tree target once from the project picker so it joins
  the known-project list.
- **ctrl+wheel** dials the preview tile size · type in the filter to fuzzy-find

Each type chip remembers its own scroll position. Switching to a shorter list,
changing the filter or tile size, or resizing the window always snaps the view
back inside the content, so an empty-looking tab really has no matches.

Dropping an OS file anywhere imports it (images convert to `.png`) and opens the
right window at the drop point.

## Copy to another project

The copy keeps the same project-relative path and never overwrites a target
file. Save a dirty source first. Sprites carry their baked `.png`, `.anim`, and
`.meta` companions; textured 3D maps carry their `-atlas.png`. The complete
family is staged before it appears in the target, and a reported failure rolls
the family back instead of leaving a partial import.

References inside an asset are not guessed. For example, after copying a song,
copy its project-local instruments explicitly; after copying a map, copy the
art it places. This keeps cross-project reuse deliberate instead of silently
pulling an unbounded dependency tree.

## Walkthrough: import, inspect, and reuse one image

1. Drop a reference PNG from the OS onto empty canvas. It is copied into the
   project, normalized as PNG, and opened in the read-only **image** window.
2. Open **assets**, type part of its name, select it, and use
   **Ctrl+wheel** until the thumbnail scale is useful. Enter reopens the full
   checker-backed image inspector.
3. Drag it from assets onto a sprite's **stamp well**, stamp a few pixels, then
   drag it onto a map (or 3D map) to place it. One source now exercised three
   real asset doors.
4. Press **r** in assets and move it into `art/refs/`. Every open window and
   unsaved edit follows. For a `.spr`, the baked PNG and animation sidecars
   move as one family.
5. Filter for the new path, open it once more, and save the receiving sprite or
   map. If code named the old path, update it explicitly — the browser never
   silently rewrites game logic.
6. Press **c**, choose another project, and copy it. Open that project from
   **← projects**: `art/refs/` contains the saved image at the same path.

Full reference: [Using the editor](engine/stock/docs/editor.md),
[the sprite editor](engine/stock/docs/win-sprite.md), and
[the map editor](engine/stock/docs/win-map.md).
