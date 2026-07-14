# Using the editor

Open any project with `--edit` (or from the picker). The editor is an
**infinite canvas** of floating windows — pan and zoom the canvas, drag
windows around, and lay out a workspace that suits the task.

## Spawning windows

**Right-click the canvas** for the spawn menu. The window kinds:

- **code editor** — a project file in a syntax-lit editor. `.md` docs (like
  this one) get headings, links, and code spans; Ctrl+click a link to follow
  it. Ctrl+S saves; Ctrl+Z / Ctrl+Y undo and redo (across restarts).
- **sprite editor** (+ **animation**) — paint frames, define clips.
- **map editor** — collider chains, one-ways, and markers (spawns, portals,
  props). **tilemap** — a grid of tiles placed as one object.
- **sound player**, **synth** (FM + Game Boy voices with filter and pitch
  sweep), and a **music** tracker.
- **palette** — design a palette; generate ramps with a hue shift.
- **assets** — browse the project's files; double-click one to open it.
- **console**, **perf**, and this **help** window.

## Keys that matter

- **Right-click** — spawn menu. **Middle-drag** / **wheel** — pan and zoom.
- **Ctrl+S** — save the focused window's file.
- **Ctrl+Z / Ctrl+Y** — undo / redo (per asset, kept across restarts).
- **Esc** — release the current tool / view lock.
- Each window shows its own hotkeys in a hint strip while it's focused.

New assets and projects auto-name themselves with three random words, so
nothing blocks on inventing a filename — just press Enter to create.

Next: [Writing a game](engine/stock/docs/scripting.md).
