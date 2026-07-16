# Project settings

Open **project settings** from the right-click spawn menu or **Ctrl+Space**.
The three tabs edit player-facing identity, game/window defaults, the files a
player bundle needs, and the final portable export.

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

## Build / Export

Open **build/export**, choose **Linux .tar.gz** or **Windows .zip**, and enter
the output folder. A downloaded editor carries its own platform's complete
runtime, so Linux builds Linux and Windows builds Windows; choose the matching
editor download for the other target. The optional replacement checkbox is the
explicit door for atomically advancing an artifact with the same name.

Preflight requires complete player metadata and saved project assets. If a code,
sprite, map, tilemap, palette, instrument, song, or settings form has unsaved
working bytes, the window names the first file to save. The build then re-reads
`project.lua` and every referenced file from disk, verifies the output folder,
and walks the carried runtime and current project. Progress remains visible
while you change tabs.

**cancel export** stops at a file boundary, removes the sibling temporary file,
and publishes nothing. Closing the project window, opening rewind with F4, and
Esc cannot accidentally dismiss a running build; cancel it first. A successful
job atomically publishes the archive, then shows its exact SHA-256 and writes a
sibling `.sha256`. The archive also contains `SHA256SUMS` for every extracted
file. Failures stay in the window and open the console with a retryable reason.

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

The editor, streaming exporter, and developer packager call the same release
schema and referenced-byte validator. Export choices and progress are ephemeral
machine state: they never enter `project.lua`, the editor session, or rewind.

Back to [Using the editor](engine/stock/docs/editor.md), or read the complete
[project scripting contract](engine/stock/docs/scripting.md).
