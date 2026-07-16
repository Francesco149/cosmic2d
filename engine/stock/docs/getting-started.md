# Getting started

Welcome to **cosmic2d** — a tiny 2D pixel-art engine and fantasy console.
Make and export a game with the built-in editor in this engine folder. The
remaining alpha work broadens project lifecycle, input/settings, starter
genres, rewind product UI, and release validation.

This is a rendered doc reader. Click a link to follow it in place
(ctrl+click opens it in a new reader); the header arrows — or the mouse
back/forward buttons — walk your history. `src` opens the raw markdown.

## Run something

- `bin/cosmic` opens the **project picker** — the front door. Click a tile
  to open that project in the editor; the ▶ zone plays it.
- **open folder** registers an existing cosmic2d project in place and opens
  it. The picker remembers it across restarts. **refresh** rescans immediately;
  a missing recent folder offers **repair** (choose its new location) and
  **remove** (forget the shortcut, without deleting project files).
- A ready recent tile's **...** menu can **reveal** its folder, **rename** the
  folder, or **move** it beneath a chosen parent on the same filesystem. The
  project name itself stays in project settings. Existing destinations are
  never replaced; a failed recents update leaves the old tile available for
  **repair**.
- The bundled **demo** is a two-room platformer with music that swaps
  between rooms. Open it, walk into a door, grab the coins.
- **+ New project** scaffolds a fresh, runnable project (auto-named with
  three random words) and opens it in the editor.
- In an editor, **← projects** returns to the picker after flushing pending
  text edits, the editor session, and rewind history. Finish or cancel an
  active player export first.
- In the editor, open **project settings** from the right-click menu or
  **Ctrl+Space**. Give the project its real name, author/version/description,
  internal resolution, and initial window defaults. On **player files**, choose
  a project icon, controls, credits, and at least one license/notice. Drop files
  into the editor to import them first; every reference validates live and
  Ctrl+S saves the complete settings atomically. Then open **build/export**,
  choose this download's matching Linux or Windows target and an output folder,
  and press **build export**. Progress, cancellation, archive integrity, and
  retryable errors stay in that window.

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
