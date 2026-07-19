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
- **code editor** — a project file in a syntax-lit editor. An unbound
  window is both the file picker and the **new file** door: type a path and
  Enter creates it (typed text extensions are kept; a bare name becomes
  `.lua`). `.md` docs (like this one) get headings, links, and code spans;
  Ctrl+click a link to follow it. Ctrl+S saves; Ctrl+Z / Ctrl+Y undo and
  redo. Journals normally preserve undo across restarts, but are still cache
  data rather than a durability guarantee.
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
**everything**: open any asset or doc, spawn any window kind by name, or
**pan to** any open window (it centers the window at your current zoom,
fitting down only if it overflows). The highlighted result shows a live **preview** — an
image thumbnail, a map schematic, or a code/doc excerpt. **↑↓** move · **enter**
opens · **esc** closes.

The query also **content-searches the shipped docs**: a term like `cm.actor`
or "deadzone" lists the doc **sections** covering it (tagged `sect`, below the
name matches), previewing the section source at the matching line. Enter opens
the documentation reader scrolled to that section — the fast path to a doc
page without leaving the keyboard.

## Reading and searching the docs

This window is a rendered documentation reader. Spawn it from the right-click
menu, or press the **?** on any window's title bar for that window's guide.

Its home — the **docs** button in the header — is a
**search field over every shipped doc**. Type a module (`cm.actor`), a
task ("draw a map"), or any term,
and it lists ranked hits across the whole documentation set, each naming the
**doc**, the **section**, and a one-line snippet. Click a hit to open that doc
scrolled to the section (the landed-on line lights briefly). An empty field
just lists the docs to browse.

Inside a doc, click a link to follow it in place (**ctrl+click** opens a new
reader); a `#section` link jumps to that heading. The header **◀ ▶** — or the
mouse back/forward buttons — walk your history, **docs** returns to search, and
**src** opens the raw markdown in a code editor (which has its own Ctrl+F find).

Any text in a doc can be **selected**: drag across prose, headings, or code —
the selection is glyph-precise and follows the rendered text, spanning
wrapped lines and whole code blocks. Press **Ctrl+C** to copy it (a small
"copied" tag confirms; wrapped lines rejoin, code keeps its exact
indentation). **Esc** clears the selection. Links still follow on a plain
click — a drag that starts on a link selects instead of navigating.

Code blocks are **syntax-highlighted** and **copyable**: hover a block for its
**copy** button (it copies that block's source), or press **copy page** in the
header to put the whole doc on the clipboard as plain text.

Scrolling: the wheel, the **scroll bar** (drag its knob, or click anywhere on
the track to jump), and the keyboard — **PgUp/PgDn** page through the doc,
**Home** (or **Ctrl+PgUp**) jumps to the top, **End** (or **Ctrl+PgDn**) to
the bottom.

## Text and UI size

Click the **Aa** pill beside the canvas zoom percentage. **Canvas windows**
scales editor windows and their text without changing the saved logical zoom;
**fixed chrome** separately scales the HUD, menus, launcher, and rewind tray.
The default **auto** mode stays at 100% on a normal 1080p display and chooses a
larger size from display DPI or 4K pixel density. `−` or `+` selects a manual
size for this machine; click **auto** to follow the display again. A size
change keeps the view centered where it was, and game windows keep their
on-screen size and crisp pixel scale — the surrounding windows and chrome are
what grow or shrink.

## Rewind playback

Open rewind from its top-right pill or with **F4**. Play starts at **1×** real
time. Click the speed chip to cycle **1× / 2× / 4× / 8×**; slow rendering may
drop intermediate displayed frames so the transport remains on time. A/B
selection stays inclusive and loops until Esc clears it; Esc again returns to
the live present.

The tray's disk-use meter shows retained history against your budget. The
notch on the track marks 90% of the budget; when the fill passes it the
used/budget label gains a leading **!** — both read without color, beside
the exact numbers.

## The settings window

The **settings** window (spawn menu, the launcher's "settings / player
options" entry, or the controller's back/select button) is the dev view
over the knobs your players reach in the player menu (F1): the options your game
declared with `cm.options.add` (against their defaults), the volume
knobs, stick deadzone and press threshold, and the user-wide
accessibility toggles (reduce screen shake / reduce flashes) — so you can
watch a reduced death flash or a volume change live against the running
game window. It's an ordinary window: nothing pauses, nothing is blocked
while it's open. Rebinding and the player menu itself are player-facing —
test those by running the game in player mode.

## Playing and mouse capture

Clicking into a game window focuses it — focused means playing, and your
keys drive the game. A mouse-look game (one that called
`input.capture_mouse(true)`) also captures the cursor while its window is
focused: the pointer hides and turns into look input. The window's chip
reads **PLAYING · ESC RELEASES MOUSE** while that's on — press **Esc** and
the cursor comes back exactly where it was. The capture never survives
leaving play: the launcher, an edit field, time travel, or the player menu
all release it, and it re-engages when you click back in.

## Keys that matter

- **Ctrl+Space** — the launcher (find/open anything, pan to a window). Its
  **settings / player options** entry summons the settings window (the pad
  back/select button does too).
- **F4** — open/close rewind (an active A/B clip requires Esc first).
- **Right-click** — spawn menu (over an editing sprite/tilemap canvas the
  right button paints/erases instead — spawn from elsewhere or the launcher).
  **Middle-drag** / **wheel** — pan and zoom.
- **Ctrl+S** — save the focused window's file. A window with unsaved work
  marks its title bar with a dot **and** a trailing `*` on the title (the
  state never rides color alone); **reset** beside them reverts to the
  saved file.
- **Ctrl+Z / Ctrl+Y** — undo / redo (per asset; journals normally survive a
  restart, but source saves remain the durable boundary).
- **Ctrl+Tab / Ctrl+Shift+Tab** — cycle window focus in reading order
  (top-to-bottom, then left-to-right). An off-screen window pans into view;
  the focus ring shows where you landed. Works mid-typing — cycling out of
  a code editor releases its keyboard — and while a game window is playing.
- **Ctrl+W** — close the focused window (with nothing focused, the
  selection). Closing never loses work: asset state lives with the project,
  not the window.
- **Arrow keys** — nudge the selected windows by 1 (Shift = 10);
  **Alt+arrows** resize them from the bottom-right corner instead (same
  Shift step, same size rules as a pointer drag).
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
