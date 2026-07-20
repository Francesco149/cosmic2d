# The assets browser

Browse the project's files. Double-click one to open it in the right editor;
drag one onto the canvas (or a map) to place or bind it.

## Keys

- **arrows** move the selection · **enter** open the selected asset
- **r** rename/move (a bar opens with the full path — edit the name, or the
  folder part to move; **enter** commits, **esc** cancels). A `.spr` takes its
  baked files along; open windows, unsaved edits, and undo history follow.
  Code that referenced the old name falls to the engine's invalid-asset
  fallbacks until you update it — renaming never corrupts a running game.
- **del** delete (arms a red confirm; **del** again to execute, **esc** cancels)
- **ctrl+wheel** dials the preview tile size · type in the filter to fuzzy-find

Dropping an OS file anywhere imports it (images convert to `.png`) and opens the
right window at the drop point.

Next: [Using the editor](engine/stock/docs/editor.md)
