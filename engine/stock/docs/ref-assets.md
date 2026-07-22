# The assets browser reference — every control and route

This is the complete control-surface reference for the project Assets window.
The guided path is [the Assets tutorial](engine/stock/docs/win-assets.md); this
page is for when you are holding the browser and want to know exactly what a
tile, chip, key, or drop destination will do.

## The window at a glance

Top to bottom: the **all / code / image / sound** type chips and tile-size
dial; the **fuzzy search** field; a scrollable preview grid; then a count at
bottom-right. Selection-dependent operations appear in the focused window's
hint strip below the frame. Rename, delete, and cross-project copy each open a
temporary in-window surface over that grid.

Assets is a recursive, flat project view. It does not draw folder rows or
breadcrumbs: every file keeps its project-relative path internally, while the
tile shows its basename. Searching the folder portion is how you gather a
role such as `characters/` or `sound/` across a large project.

## Header

- **assets** is a browser title, not a bound file. The window itself has no
  dirty state, reset action, undo journal, or save command.
- **?** opens [the Assets tutorial](engine/stock/docs/win-assets.md) in a help
  reader.
- The ordinary editor frame still applies: drag the title bar to move, drag
  an edge to resize, and use **ctrl+w** or Alt-right-click to close.

## Type chips

- **all** — every listed project file, including maps, tilemaps, palettes,
  terrain, meshes, figures, and unknown extensions that have no narrower chip.
- **code** — `.lua`, `.md`, `.txt`, `.json`, and `.glsl`.
- **image** — `.spr`, `.png`, and every image format accepted on OS import:
  jpg/jpeg, gif, bmp, tga, hdr, psd, pic, ppm, pgm, and pnm.
- **sound** — playable `.wav`, `.ogg`, `.mp3` plus editable `.song` and `.ins`
  sources. Songs and instruments belong here even though their bytes are not
  decoded audio; they are the project's author-facing sound family.

Left-click a chip to switch. Each chip remembers its own vertical scroll, so
you can leave code and art at different working rows. When a filter, tile size,
window size, or shorter chip makes the old offset impossible, it clamps to real
content instead of showing an apparently empty grid below the last item.

## Fuzzy search

Click the field and type any subsequence of the complete project-relative
path. Case does not matter. Consecutive letters and starts after `/`, `_`, `-`,
or `.` rank higher; shorter paths break close ties. Thus `mnr` can find
`art/characters/moonrunner.spr`, while `characters/` gathers that folder even
though tiles display basenames.

The type chip and text filter combine. A zero-result view says **no matches**;
clear the field or switch back to **all** before assuming a file was deleted.

## Tile-size dial and scrolling

- Drag the header line's circular handle from **48 to 160** logical pixels.
  The value controls previews and the number of grid columns.
- **ctrl+wheel** anywhere over the window steps the same dial by 8 pixels per
  notch.
- Plain **wheel** scrolls the active grid vertically. Scroll is stored in
  canvas/world units, so zooming the editor does not make the first row drift.

The list is capped at 1,000 files. `.ed/` recovery data and `.git/` internals
are excluded. Entries need a dot in their basename; extensionless release
files such as `LICENSE` remain available in the Project window's dedicated
release picker, not this authoring grid.

## Tile previews

- `.png` and other decoded images show the image aspect-fit in the tile.
- `.spr` shows its baked `.png` strip. The `.png`, `.anim`, and `.meta`
  siblings are hidden when the matching `.spr` exists, because the editable
  source is the useful tile.
- `.map` shows a schematic of its bounds, placements, and geometry.
- `.tm` shows its filled-cell pattern.
- Code/text shows a clipped excerpt from the file's first lines.
- Sound-family and unrecognized files use a type glyph plus their extension.

Saving an asset bumps the shared asset epoch, so cached thumbnails refresh on
the next draw. A just-saved sprite or map should never require an editor
restart to update its tile.

## Select, open, and carry

- **Left-click** a tile to select it. The bright outline is the confirmation.
  The same press arms a carry; releasing before moving is only selection.
- **Double-click** the selected tile to open its canonical window: text,
  sprite, image, sound player, map, tilemap, terrain, mesh, figure, palette,
  synth, music, animation, or another registered extension owner.
- **Press-drag** past the shell's small drag threshold to carry the asset. A
  bordered basename ghost follows the pointer until release.

The release destination decides what carry means, in this order:

1. A window-specific **drop** door gets first choice. Maps place art/tilemaps,
   a sprite's `img` well adopts a stamp, palettes stack under a sprite, and a
   music track binds an instrument.
2. Otherwise a compatible asset window **rebinds** to the path. Dropping a
   `.spr` on a sprite window or `.map` on a map window retargets it.
3. Bare canvas opens the file's canonical window at the release point.
4. An incompatible occupied window declines the drop. Nothing is copied or
   converted merely because the pointer crossed it.

Tile choice itself is pointer-based. There is currently no arrow-key cursor or
plain-Enter open action in this grid; **up / down / enter** belong only to the
cross-project chooser described below. The fuzzy field is the fast narrowing
door for a large project.

## Rename or move — r

Select a tile and press **r**. The green bottom bar contains the complete
project-relative path.

- Edit only the basename to rename in place; edit the folder portion to move.
  Missing destination folders are created.
- If the new basename has no extension, the old extension is retained.
- **enter** commits. **esc** cancels. An empty path, a trailing `/`, an
  unreadable source, or any disk/working-state collision leaves the old asset
  intact and prints a visible error.
- A `.spr` carries its baked `.png`, `.anim`, and `.meta` siblings. Other
  formats move only the selected file.
- Open windows rebind, unsaved working bytes keep the same dirty state, both
  journal files follow, and undo history survives under the new name.
- Runtime caches invalidate. Code, map references, song references, and other
  user-authored path strings are deliberately **not** rewritten; update those
  call sites explicitly.

The move publishes the destination atomically before removing the source. It
is not a filesystem-wide dependency refactor, and it is not a copy.

## Delete — del twice

Select a tile and press **del** once. A red bottom bar names the exact file;
press **del** again to execute or **esc** to cancel. Selecting something else
also disarms the confirmation.

Deletion is immediate rather than a move to trash. A `.spr` also deletes its
baked `.png`, `.anim`, and `.meta`; other formats delete only the selected
path. Open working state is not a substitute for a deleted disk asset, so use
the two-press confirmation as a real destructive boundary.

## Copy to another project — c

Select a **saved** asset and press **c** — hint **copy to another project**.
A modal chooser lists other valid projects known from Recents plus bundled
projects; the current project, duplicates, stale entries, and malformed project
roots are absent.

- **up / down** — **choose target**; the cursor move repeats while held.
- **enter** or the **copy** button commits. **esc** or **cancel** closes the
  chooser.
- Open an out-of-tree target once in the Project picker so it joins Recents.
- If the source has unsaved working bytes, save it first. The chooser refuses
  to copy older disk bytes while a window shows newer work.

The destination keeps the same project-relative path and never overwrites.
Links in either path are refused. Every byte is staged and re-read before
publication; a reported failure rolls back the files it published.

A `.spr` carries existing `.png`, `.anim`, and `.meta` companions. A `.terr`
carries its published `-atlas.png`. Referenced dependencies do not recurse:
copy a song's project-local instruments or a map's placed art explicitly, so a
single action never pulls an unbounded graph into another game.

## OS file drops

An operating-system file dropped anywhere in the editor is imported under a
collision-free name; repeated basenames gain `_2`, `_3`, and so on.

- Decodable images land in `art/` and normalize to `.png` in memory before an
  atomic publish. `.spr` stays `.spr`.
- `.wav`, `.ogg`, `.mp3`, and `.song` land in `sound/`; `.ins` lands in `ins/`.
- Other files land at the project root.
- Over Assets, import ends with a flashing tile. Over a map or another
  accepting window, it imports and then places/binds. Elsewhere it imports and
  opens the canonical window when one exists.

An unreadable, undecodable, encode-failed, or publish-failed file is logged by
name. A failed publish leaves no partial authoritative asset and summons the
console where appropriate.

## Rewind and durability

While parked in the past, rename, delete, import, and cross-project copy are
walled: historical browsing must not mutate the live filesystem. Bringing the
frame back to the present is the write door.

The browser list and previews are derived caches. Asset source files, their
windowkit working bytes, and journals hold authority; closing Assets loses no
work in another window.

## Pointer and keyboard summary

- Left-click select · double-click open · press-drag carry.
- Header chips filter · search field fuzzy-finds · size dial or
  **ctrl+wheel** resizes tiles · wheel scrolls.
- **r** rename/move · **del**, then **del** confirm delete · **c** copy to
  another project.
- In the copy chooser: **up / down** choose target · **enter** copy · **esc**
  cancel.
- The standard shell still owns **ctrl+w**, focus cycling, window movement,
  resize, canvas pan/zoom, and the header **?**.

Back to [the Assets tutorial](engine/stock/docs/win-assets.md), continue to
[the Stock browser](engine/stock/docs/ref-stock.md), or review
[editor shell gestures](engine/stock/docs/editor.md).
