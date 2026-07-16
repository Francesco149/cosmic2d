# Using the editor

Open any project with `--edit` (or from the picker). The editor is an
**infinite canvas** of floating windows — pan and zoom the canvas, drag
windows around, and lay out a workspace that suits the task.

The fixed **← projects** button returns to the project picker. It first closes
pending text edits into their journals, saves the editor session, and flushes
rewind history; an active build/export must finish or be cancelled before the
switch can proceed.

## Spawning windows

**Right-click the canvas** for the spawn menu. The window kinds:

- **project settings** — edit name/author/version/description, internal
  resolution, initial window defaults, and the icon/controls/credits/licenses
  needed by player builds. Project-file validation is live; Ctrl+S merges into
  the shared `project.lua` working copy and saves it atomically. **build/export**
  makes the matching Linux/Windows player archive with progress and cancellation.
- **code editor** — a project file in a syntax-lit editor. `.md` docs (like
  this one) get headings, links, and code spans; Ctrl+click a link to follow
  it. Ctrl+S saves; Ctrl+Z / Ctrl+Y undo and redo. Journals normally preserve
  undo across restarts, but are still cache data rather than a durability
  guarantee.
- **sprite editor** (+ **animation**) — paint frames, define clips.
- **map editor** — collider chains, one-ways, and markers (spawns, portals,
  props). **tilemap** — a grid of tiles placed as one object.
- **sound player**, **synth** (FM + Game Boy voices with filter and pitch
  sweep), and a **music** tracker.
- **palette** — design a palette; generate ramps with a hue shift.
- **assets** — browse the project's files; double-click one to open it.
- **console**, **perf**, and this **help** window.

## The launcher (Ctrl+Space)

Press **Ctrl+Space** anywhere for a fuzzy command palette — one field over
**everything**: open any asset or doc, spawn any window kind by name, or **pan
to** any open window (it centers the window at your current zoom, fitting down
only if it overflows). The highlighted result shows a live **preview** — an
image thumbnail, a map schematic, or a code/doc excerpt. **↑↓** move · **enter**
opens · **esc** closes.

## Text and UI size

Click the **Aa** pill beside the canvas zoom percentage. **Canvas windows**
scales editor windows and their text without changing the saved logical zoom;
**fixed chrome** separately scales the HUD, menus, launcher, and rewind tray.
The default **auto** mode stays at 100% on a normal 1080p display and chooses a
larger size from display DPI or 4K pixel density. `−` or `+` selects a manual
size for this machine; click **auto** to follow the display again.

## Rewind playback

Open rewind from its top-right pill or with **F4**. Play starts at **1×** real
time. Click the speed chip to cycle **1× / 2× / 4× / 8×**; slow rendering may
drop intermediate displayed frames so the transport remains on time. A/B
selection stays inclusive and loops until Esc clears it; Esc again returns to
the live present.

## Keys that matter

- **Ctrl+Space** — the launcher (find/open anything, pan to a window).
- **F4** — open/close rewind (an active A/B clip requires Esc first).
- **Right-click** — spawn menu. **Middle-drag** / **wheel** — pan and zoom.
- **Ctrl+S** — save the focused window's file.
- **Ctrl+Z / Ctrl+Y** — undo / redo (per asset; journals normally survive a
  restart, but source saves remain the durable boundary).
- **Esc** — release the current tool / view lock.
- Each window shows its own hotkeys in a hint strip while it's focused, and a
  **?** button in its title bar opens that window's help (hotkeys + workflow).

## Per-window guides

- [Project settings](engine/stock/docs/win-project.md) ·
  [the map editor](engine/stock/docs/win-map.md) ·
  [sprite editor](engine/stock/docs/win-sprite.md) ·
  [tilemap](engine/stock/docs/win-tmap.md)
- [synth](engine/stock/docs/win-synth.md) ·
  [music tracker](engine/stock/docs/win-music.md) ·
  [sound player](engine/stock/docs/win-sound.md)
- [palette](engine/stock/docs/win-palette.md) ·
  [assets browser](engine/stock/docs/win-assets.md)

New assets and projects auto-name themselves with three random words, so
nothing blocks on inventing a filename — just press Enter to create.

Next: [Writing a game](engine/stock/docs/scripting.md).
