# Project settings

Open **project settings** from the right-click spawn menu or **Ctrl+Space**.
The two tabs edit player-facing identity, game/window defaults, and the files a
player bundle needs, all stored declaratively in `project.lua`.

## Fields

- **name**, **author**, **version**, and **description** become project and
  player-facing metadata. Name and version are required; author and description
  may remain empty while the project is a draft.
- **internal width / height** define the game's design target. Both must be
  whole numbers from 1 through 4096.
- **initial scale** is the ordinary play window's integer multiple, from 1
  through 16.
- **start maximized** applies to ordinary play launches. Editor launches are
  always maximized independently.

The **player files** tab selects:

- one square **PNG icon**, from 32 through 1024 pixels;
- non-empty **controls** and **credits** Markdown/text files; and
- one or more non-empty project **license/notice** text files.

Type a project-relative path or press **choose** for a fuzzy list of suitable
files already in the project. Drop an OS file anywhere in the editor to import
it first; images become project PNGs. Every row validates the saved bytes live,
and the complete export check appears at the bottom. Unsafe paths, missing or
empty files, binary text, non-PNG icons, and non-square icons stay visible as
specific errors and cannot be saved.

With every player-file field empty, the project remains a normal saveable
draft. Once any one is selected, all four parts are required together. Use
**clear release** to deliberately return to a draft.

Press **Ctrl+S** or **save settings**. Identity and export validation appears
inside the window before anything reaches disk. Resolution and window changes
take effect on the next launch; saving never rebuilds a running render target
under the game.

## Source and recovery

The form and a code window opened on `project.lua` share one working copy and
one undo journal. A form save merges these fields into the latest declarative
table, preserves unedited keys such as `entry`, `seed`, and project-specific
extensions, then rewrites canonical inspectable Lua with atomic replacement. A
failed write leaves the previous file intact and the complete newer working
copy dirty for retry.

Use the header's **reset** action to return to the saved file. **reload form**
instead discards only temporary form typing and re-reads the shared working
copy, which is useful when a code window changed `project.lua` at the same
time.

The editor and player packager call the same release schema and referenced-byte
validator. Build target, output location, and export progress are still the next
A3 packet; metadata completeness here does not claim an export has run.

Back to [Using the editor](engine/stock/docs/editor.md), or read the complete
[project scripting contract](engine/stock/docs/scripting.md).
