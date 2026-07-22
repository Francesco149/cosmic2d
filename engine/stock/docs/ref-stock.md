# The Stock browser reference — every control and adoption door

This is the complete control-surface reference for the read-only Stock window.
The guided path is [the Stock tutorial](engine/stock/docs/win-stock.md); this
page explains exactly what the library contains and what click, copy, open, or
drag will add to the current project.

## The window at a glance

Top to bottom: the **all / ins / songs / art / fig / pal** family chips and a
standing read-only caption; the **fuzzy search** field; then a scrollable grid
of immutable engine assets. A family tag rides every tile. The focused hint
strip exposes **c — copy to project** after a tile is selected.

There is no folder tree, rename bar, delete confirmation, dirty state, or save
button in Stock. Editing always begins through a copy under the active project.

## Header

- **stock assets** is the library title. The browser itself never binds a
  project file and cannot become dirty.
- **?** opens [the Stock tutorial](engine/stock/docs/win-stock.md).
- Ordinary shell frame gestures still move, resize, focus, or close the window.

## Families and destinations

The five source families are engine-relative and ship with every editor/game
distribution:

- **ins** — `engine/stock/ins/*.ins`; direct copies land in `ins/`.
- **songs** — `engine/stock/songs/*.song`; direct copies land in `sound/`.
- **art** — editable sprites from `engine/stock/spr/`; copies land in `art/`.
- **fig** — figures from `engine/stock/fig/`; copies land in `art/`.
- **pal** — palettes from `engine/stock/pal/`; copies land in `pal/`.
- **all** — the same families in the order above.

Click a chip to switch. Each family remembers its own vertical scroll. A
filter, changed tile size, resized window, or shorter family clamps that scroll
to actual content instead of leaving the grid blank below its last row.

## What ships

The instrument shelf spans FM, Game Boy, orchestral, jazz/latin/funk,
electronic, ambient, percussion, and game-SFX families. For how every patch was
built, see [the synth preset recipes](engine/stock/docs/ref-synth.md).

The song shelf contains desert, water, courtly, soft-prelude, battle, boss,
drum-and-bass, breakbeat, bossa, funk, noir, horror, and ambient starters. They
are editable demonstrations, not opaque recordings: open one and its clips,
patterns, notes, mix, and instrument paths are all ordinary `.song` data.

Art currently includes the stock tiles sprite, Fig the mascot, and Pal the
shipped small and general-purpose palettes. A `.spr` tile hides its generated
`.png` and `.meta` siblings so the editable source appears once.

## Search, size, and scroll

- Click **fuzzy search** and type a case-insensitive subsequence of the stock
  **name**. Consecutive and word-start matches rank above scattered ones.
- **ctrl+wheel** over the Stock window steps tile size from 48 to 160 logical
  pixels. Unlike Assets, Stock has no separate visible size dial.
- Plain **wheel** scrolls the grid. The active family retains the position in
  world units across editor zoom changes.

Stock has no arrow-key tile cursor. Select with the pointer after filtering;
**enter** is an adoption action on an already selected tile, not navigation.

## Tile previews and selection

- Stock sprites show their baked strip; palettes show up to 16 ordered color
  swatches.
- Instruments and songs use sound glyphs, while every tile also prints its
  family and filename.
- **Left-click** selects and outlines a tile. The same press arms drag; a
  release without movement is only selection.
- A second click within the double-click interval opens an unsaved copy.

Stock preview bytes are immutable during a session, so their cache needs no
asset-epoch refresh. Engine upgrades replace the library between sessions.

## Door 1: double-click opens an unsaved copy

Double-click a tile to seed its exact bytes into the matching project editor:
synth, music, sprite, figure, or palette. The destination follows the family
folder and stock basename. If disk or another unsaved working copy already
uses that name, suffixes count upward as `-2`, `-3`, and so on.

The receiving title gets an amber dot and trailing `*`. No project source file
exists until **ctrl+s** in that editor. Undo starts at the stock bytes, so you
can experiment and return to the imported baseline. Closing the receiving
window still creates no source file, although normal editor recovery retains
its working state until you deliberately save or replace it.

Use this door when you want to listen, inspect construction, or make changes
before deciding whether the project should keep anything. A song auditions
with **space** in Music; an instrument auditions from the Synth piano or
tracker-key rows. Stock itself has no play button.

## Door 2: c or enter copies immediately

After selecting a tile, press **c** — hint **copy to project** — or **enter**.
The exact selected file atomically publishes under the family destination and
Assets flashes the new path. A collision never overwrites: another numbered
name is chosen.

This is a single-file copy. It does not infer dependencies. In particular:

- A copied song retains its `engine/stock/ins/...` track references. They are
  valid and portable because the engine library ships; replace a track with a
  project-local `.ins` when you want to edit that voice.
- A directly copied stock `.spr` copies the editable source only. Open it in
  Sprite and save once to generate the project's `.png`, `.anim`, and `.meta`
  family.
- A figure or palette copies only its own source bytes.

Use direct copy when the original is already the desired starting point and a
saved project asset should exist immediately.

## Door 3: drag lets the receiver adopt

Press-drag a selected tile. The shell carries its engine-relative source path;
the release target decides how to make it project-safe.

- Drop a stock `.ins` on a Music track. Music copies it into `ins/` if needed,
  reuses an existing same-name project copy, and binds the project-relative
  path into that track as one song undo step. The row outlines before release.
- Drop stock art on the Sprite `img` well to use it as a stamp. Drop a stock
  palette on a Sprite window to stack its swatches.
- Other compatible wells in Figure, Terrain, or Mesh consume the formats they
  advertise. Release on a precise well when that is the intended role.
- Bare canvas follows the shell's generic opener. For predictable ownership,
  prefer double-click for a whole editable stock source and drag for a
  receiving well or track.

Dragging is not the same as **c**: the receiver may copy, bind, place, stack,
or rebind according to its own reference contract.

## Read-only and rewind guarantees

Stock has no code path that renames, deletes, saves, or overwrites
`engine/stock/`. Every editable destination is project-relative. Direct copies
are walled while parked in rewind history; unsaved experiments may exist only
in the parked document and evaporate when history is dismissed.

Copy/open failures log the exact source or destination. Atomic publication
means a failed direct copy does not expose a partial project asset.

## Pointer and keyboard summary

- Left-click select · double-click open an unsaved copy · press-drag carry.
- Family chips filter · text fuzzy-finds · **ctrl+wheel** resizes tiles ·
  wheel scrolls.
- **c** or **enter** copies the selected file directly into the project.
- There is no Stock rename, delete, save, arrow-key tile walk, or direct audio
  transport. Those actions belong to the copied asset's editor.

Back to [the Stock tutorial](engine/stock/docs/win-stock.md), compare
[the project Assets browser](engine/stock/docs/ref-assets.md), or continue with
[the synth](engine/stock/docs/ref-synth.md) and
[music](engine/stock/docs/win-music.md) guides.
