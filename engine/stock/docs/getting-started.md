# Getting started

Welcome to **cosmic2d** — a tiny 2D pixel-art engine and fantasy console.
One folder holds the engine, its editor, and your games. Make a game with
the built-in editor, share it by zipping a folder.

This is a rendered doc reader. Click a link to follow it in place
(ctrl+click opens it in a new reader); the header arrows — or the mouse
back/forward buttons — walk your history. `src` opens the raw markdown.

## Run something

- `bin/cosmic` opens the **project picker** — the front door. Click a tile
  to open that project in the editor; the ▶ zone plays it.
- The bundled **demo** is a two-room platformer with music that swaps
  between rooms. Open it, walk into a door, grab the coins.
- **+ New project** scaffolds a fresh, runnable project (auto-named with
  three random words) and opens it in the editor.

From a shell you can also run a project straight:

    bin/cosmic projects/demo          # play
    bin/cosmic projects/demo --edit   # edit on the infinite canvas

## Where to go next

- [Using the editor](engine/stock/docs/editor.md) — the infinite canvas,
  the window kinds, and the keys that matter.
- [Writing a game](engine/stock/docs/scripting.md) — the `init/step/draw`
  shape, drawing, input, and hot reload.

## The idea

The game is hot-reloadable Lua: edit `main.lua` while it runs and the change
takes effect on the next frame — no restart. The sim runs at a fixed 60 Hz
and is deterministic to the bit, so you can snapshot and rewind any frame.

Read `projects/demo/` for a complete, commented example.
