# Using the editor

Open any project with `--edit` (or from the picker). The editor is an
**infinite canvas** of floating windows — pan and zoom the canvas, drag
windows around, and lay out a workspace that suits the task.

## Spawning windows

**Right-click the canvas** for the spawn menu. The window kinds:

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

## Keys that matter

- **Ctrl+Space** — the launcher (find/open anything, pan to a window).
- **Right-click** — spawn menu. **Middle-drag** / **wheel** — pan and zoom.
- **Ctrl+S** — save the focused window's file.
- **Ctrl+Z / Ctrl+Y** — undo / redo (per asset; journals normally survive a
  restart, but source saves remain the durable boundary).
- **Esc** — release the current tool / view lock.
- Each window shows its own hotkeys in a hint strip while it's focused, and a
  **?** button in its title bar opens that window's help (hotkeys + workflow).

## Per-window guides

- [The map editor](engine/stock/docs/win-map.md) ·
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
