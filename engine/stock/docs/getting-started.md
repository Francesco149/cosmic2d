# Getting started

Welcome to **cosmic2d** — a tiny 2D pixel-art engine and fantasy console.
Everything here — create a project, edit its code, art, maps, and audio, play
and rewind it, and build a Linux or Windows player — happens in the built-in
editor, using only the shipped UI. The second half of this page is a guided
walkthrough that does exactly that, start to finish.

This is a rendered doc reader. The **docs** button is a search field over every
shipped guide — type a module (`cm.actor`) or a task and jump straight to the
right section. Click a link to follow it in place (ctrl+click opens it in a new
reader); the header arrows — or the mouse back/forward buttons — walk your
history. `src` opens the raw markdown.

## Run something

- `bin/cosmic` opens the **project picker** — the front door. Click a tile
  to open that project in the editor; the ▶ zone plays it. The grid is fully
  keyboard-driven too: arrows move, **Enter** opens, **Shift+Enter** plays.
- **open folder** registers an existing cosmic2d project in place and opens
  it. The picker remembers it across restarts. **refresh** rescans immediately;
  a missing recent folder offers **repair** (choose its new location) and
  **remove** (forget the shortcut, without deleting project files).
- A ready recent tile's **...** menu can **reveal** its folder, **rename** the
  folder, or **move** it beneath a chosen parent on the same filesystem.
- The bundled **demo** is a two-room platformer with music that swaps
  between rooms. Open it, walk into a door, grab the coins.

From a shell you can also run a project straight:

    bin/cosmic projects/demo          # play
    bin/cosmic projects/demo --edit   # edit on the infinite canvas

## Your first game

The rest of this page builds a small platformer from nothing: create it,
play it, rewind it, then give it your own code, art, a map, a sound, and
finally a portable player build. Every step uses only what ships in the box.

### 1. Create a project

Click **+ New project** on the picker (it is always the last tile). The
chooser offers an editable three-word folder name — keep it or type your
own — and four starters: **blank**, **platformer**, **top-down**, and
**arcade**. Pick **platformer** and press **create**. The editor opens on
your fresh project: a **game window** already running the starter, and a
welcome note with the canvas keys.

### 2. Play it

Click into the game window. Focused means **playing** — the chip in its
corner says so, and your keys drive the game: arrows run, Space jumps,
R resets. Click the canvas (or press Esc) to stop playing and get the
editor keys back. While playing, **Esc** opens the player menu — volume,
controls, and rebinding live there.

### 3. Rewind what just happened

The engine records everything, always. Press **F4** (or click the top-right
pill): the timeline shows activity lanes and a time ruler. Click anywhere on
the ruler to **park** in the past — the game window shows that exact frame,
and **resume here** rewrites history from that point if you want a do-over.
**Esc** clears a selection, **Esc** again returns to the live present.
Nothing you do while parked can damage the recording.

### 4. Change the code

Press **Ctrl+Space** — the launcher finds anything — type `main` and press
Enter. `main.lua` opens in a code editor: the whole game is this one file,
and the constants live at the top. Find the line

    local MAXVX, GRAV, JUMP = 2.6, 0.28, -5.6

and make `JUMP` stronger: change `-5.6` to `-7.2` (Ctrl+F opens
find/replace if you'd rather search). Press **Ctrl+S**. The running game
reloads on the next frame — jump and feel the difference. No restart,
and the rewind history is still there.

Windows overlap on the canvas: an overlapped window draws its text but its
fields are inert until it's on top — drag windows by their title bars to lay
out your workspace, or **alt+right-click** a window to close it (closing
never loses work).

### 5. Draw your hero

Right-click the canvas and spawn a **sprite editor** (or launcher: `sprite`).
An unbound sprite window is the new-sprite door: a unique name is prefilled —
type `art/hero` instead and press Enter. A 32×32 sprite opens in edit mode.

Paint something: **p** pen, **e** eraser, **f** fill, **k** eyedropper.
**Left-click paints the primary color, right-click the secondary** — the two
swatches sit at the bottom of the tool rail. Press **Ctrl+S**: the sprite
saves and bakes `art/hero.png`, the file the game draws.

Now use it. In `main.lua`, add `cm.gfx` beside the other requires:

    local gfx = cm.require("cm.gfx")

and in `game.draw`, replace the player quad
(`pal.quad(d.x, d.y, PW, PH, ...)`) with your sprite:

    gfx.sprite(gfx.texture(cm.main.args.project .. "/art/hero.png"),
               d.x - 10, d.y - 16)

Ctrl+S — your hero is in the game. Every save re-bakes the png, so later
paint edits show up live.

### 6. Lay out a room

Spawn a **map editor** the same way (launcher: `map`), and type
`maps/room` at its new-file field. A map is collision + placed things +
**markers** — labelled rectangles the game reads by name. Press **m**,
drag out a small marker where you'd like the goal flag to stand, then type
`goal` into the **label** field in the inspector strip below and press
Enter. **Ctrl+S** saves (a running game hot-reloads the map).

Read it from code. Add `cm.map` to the requires:

    local map = cm.require("cm.map")

and at the end of `game.init`:

    local room = map.use({ path = cm.main.args.project .. "/maps/room.map",
                           name = "hopper.room" })
    for _, mk in ipairs(room.doc.markers) do
      if mk.label == "goal" then GOAL[1], GOAL[2] = mk.x, mk.y end
    end

Ctrl+S, then press R in the game: the flag stands where you dragged the
marker. Move the marker in the map window, save, reset — level layout
without touching code again. Colliders, layers, and placing sprites on the
map are the [map editor guide](engine/stock/docs/win-map.md)'s subject.

### 7. Give it a sound

Spawn a **synth** (launcher: `synth`) and type `ins/jump` at its new-file
field. Click **presets** in its header: the stock strip carries FM voices,
the Game Boy family, and ready sound effects. Click **sfx-jump** to load it,
audition it on the tracker keys, and **Ctrl+S** to save your instrument.

Wire it up — requires first:

    local ins = cm.require("cm.ins")
    local snd = cm.require("cm.snd")

upload it once, at the end of `game.init`:

    ins.upload(ins.decode(assert(pal.read_file(
      cm.main.args.project .. "/ins/jump.ins"))), 0, "sim", "jump")

and play it in `game.step`, on the jump line:

    if input.pressed("jump") and d.grounded then
      d.vy = JUMP
      snd.on(0, 64, 110) -- slot, MIDI note, velocity
    end

Sound is deterministic simulation — trigger it in `step`, never in `draw` —
so your jump blip replays perfectly inside the time machine too.

### 8. Name it and build a player

A player build needs identity and a few player-facing files. Create them
in the editor: spawn **open file…** windows (launcher: `open file`), and use
the **new file** field — type `controls.md`, Enter, write a line about the
controls, Ctrl+S. Same for `credits.md` and `license.txt` (any typed text
extension is kept; a bare name becomes `.lua`).

Open **project settings** (right-click menu or the launcher):

- **general** — give the project its real name and a version.
- **player files** — icon: `art/hero.png` (your baked sprite is already a
  valid square PNG); controls and credits: the files you just wrote;
  **add file** your `license.txt`. Every row validates the saved bytes
  live. **Ctrl+S** saves the complete settings.
- **build/export** — choose this download's matching target (a downloaded
  editor carries its own platform's player runtime), pick an output
  folder, and press **build export**. Progress stays visible; a finished
  build publishes `<name>-<version>-<target>.tar.gz` (or `.zip`)
  atomically, shows its SHA-256, and writes a sibling `.sha256`.

That archive is your game: engine, runtime, icon, licenses, and a README —
ready to hand to a player on a clean machine.

## Where to go next

- [Using the editor](engine/stock/docs/editor.md) — the infinite canvas,
  the window kinds, and the keys that matter.
- [Writing a game](engine/stock/docs/scripting.md) — the `init/step/draw`
  shape, the module reference, determinism, and every `cm.*` door this
  walkthrough used.
- Read `projects/demo/` for a complete, commented example.

## The idea

The game is hot-reloadable Lua: edit `main.lua` while it runs and the change
takes effect on the next frame — no restart. The sim runs at a fixed 60 Hz
and is deterministic to the bit, so you can snapshot and rewind any frame.
