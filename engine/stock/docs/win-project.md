# Project settings

Open **project settings** from the right-click spawn menu or **Ctrl+Space**.
This first A3 settings surface edits the player-facing identity, internal game
resolution, and initial window policy stored in `project.lua`.

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

Press **Ctrl+S** or **save settings**. Identity and export validation appears
inside the window before anything reaches disk. Resolution and window changes
take effect on the next launch; saving never rebuilds a running render target
under the game.

## Source and recovery

The form and a code window opened on `project.lua` share one working copy and
one undo journal. A form save merges these fields into the latest declarative
table, preserves unedited keys such as `entry`, `seed`, icon/legal references,
and project-specific extensions, then rewrites canonical inspectable Lua with
atomic replacement. A failed write leaves the previous file intact and the
complete newer working copy dirty for retry.

Use the header's **reset** action to return to the saved file. **reload form**
instead discards only temporary form typing and re-reads the shared working
copy, which is useful when a code window changed `project.lua` at the same
time.

The export-check line uses the same metadata schema as player packaging. Icon,
controls, credits, license pickers, and export configuration are the next A3
settings packets; until then those fields remain directly editable in
`project.lua`.

Back to [Using the editor](engine/stock/docs/editor.md), or read the complete
[project scripting contract](engine/stock/docs/scripting.md).
