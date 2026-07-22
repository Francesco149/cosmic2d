# The animation window reference — every control

This is the complete control-surface reference for the animation
window. The guided path is
[the animation tutorial](engine/stock/docs/win-anim.md); this page is
for when you are holding the window and want to know exactly what the
thing under your cursor does.

## The window at a glance

Left: the **preview pane** — the current frame composited over a
checkerboard, aspect-fit, with a `frame N/M` readout in its top-left
corner. Right: the **clip rail** — the sprite's named clips plus the
**+** and **-** buttons. Below: the **transport row** (play/pause, the
loop chip, the entry chips) and the **entry row** (**+f**, **-f**, and
the **frame**, **dur**, and **name** fields).

A window with no file bound reads "no sprite bound — drag a .spr
here". Bind one by dragging a `.spr` in from an assets window, or open
the window from the sprite editor's **anim** header button — that
spawns it (or focuses an existing one) already bound to the sprite
being edited.

## One document, two windows

The animation window edits the **same `.spr` document** as the sprite
editor — the clip table travels inside the sprite file. Undo, redo,
revert, the dirty dot, and **ctrl+s** are all shared with a sprite
window on the same path: the two windows walk one journal. A frame you
paint in a sprite window shows in the preview — playing or
paused — as soon as the stroke commits. Saving from either window
bakes the sibling `.png` strip plus the `.anim` and `.meta` sidecars
games read.

## The preview pane

- Shows the composited strip frame the playhead (or your selection)
  lands on, aspect-fit over the checker.
- The `frame N/M` readout names the strip frame showing and the strip
  length — frame numbers here are 1-based, matching the sprite
  editor's frame chips.
- **Playing**: one editor frame is one 1/60 s tick, so the preview
  runs at real game speed. **Paused**: the pane holds the selected
  entry's frame.
- With **no clips defined** the preview just cycles the whole strip at
  8 ticks per frame — a bound sprite always shows something moving.
- The preview is dev-only plumbing: it never touches the document, so
  watching a clip is never an undo step.

## The clip rail

- Each row reads **name · loop mode** (for example `idle · loop`).
  Click a row to select that clip — the playhead restarts from its
  beginning.
- **+** adds a clip. It is born `clipN`, loop mode `loop`, with one
  entry: the frame the preview was showing, 8 ticks long. Rename it in
  the **name** field.
- **-** removes the selected clip. There is no confirm — it is one
  journal entry, so **ctrl+z** brings it back.

## The transport row

- **play / pause** — toggles the preview. The playhead restarts from
  the clip's beginning on each toggle. The **space** key does the
  same.
- **The loop chip** — shows the selected clip's end behavior and
  cycles it: **loop** wraps forever; **once** plays through and then
  holds the final entry's frame; **pingpong** bounces (a 1-2-3 clip
  plays 1-2-3-2-1-2… without holding the endpoints twice; two or
  fewer entries just loop). The **l** key cycles it too.
- **The entry chips** — one per clip entry, reading `frame:dur`
  (strip frame, 1-based, then ticks at 60 Hz — `1:40` shows frame 1
  for 40 ticks, two thirds of a second). Click a chip to select that
  entry and pause the preview on its frame. The chip row truncates on
  narrow windows — widen the window to reach later entries.

## The entry row

- **+f** — appends an entry, copying the last entry's frame and
  duration; the new entry is selected.
- **-f** — removes the selected entry (a clip keeps at least one).
- **frame** — the selected entry's strip frame, typed 1-based and
  clamped to the strip (enter commits).
- **dur** — the selected entry's duration in ticks at 60 Hz, minimum
  1 (enter commits).
- **name** — renames the selected clip (enter commits). Names are how
  game code finds a clip, and how the rail tracks your selection — an
  empty name or one another clip already uses is refused.

## Hotkeys

Dispatched to the focused window; the hint strip under the window
carries the same words:

- **space** — play/pause.
- **l** — loop: cycle the selected clip's end behavior (the loop
  chip).
- **ctrl+s** save · **ctrl+z / ctrl+y** undo / redo — shared with the
  sprite editor's journal, one finished edit per step.

## Timing model

Durations are integer **ticks at 60 Hz** — the sim's fixed timestep —
so a clip plays identically in the preview, in a running game, and
under a recorded trace. A clip is data, not state: the runtime
evaluator (`cm.anim`) is a pure function of the clip and an elapsed
tick count, which is why the same clip can drive sim logic and
cosmetic drawing alike.

Displayed frame numbers are 1-based everywhere in the editor (chips,
fields, the preview readout); the stored clip data and the runtime API
speak 0-based strip indices. The translation happens at the UI edge
only — code that loads `.anim` files sees 0-based frames.

## Files and code

Clips live in the `.spr` and bake to a `.anim` sidecar beside the
`.png` strip on save. Games load the sidecar and evaluate it against
their own clock:

    local anim = cm.require("cm.anim")
    local clips = anim.load(cm.main.args.project .. "/art/hero.anim")
    local walk = anim.find(clips, "walk")
    local frame = walk and anim.frame_at(walk, state.frame()) or 0

`anim.duration(clip)` is one forward play-through in ticks. Running
games re-read the sidecar when you save (watch `cm.asset_epoch`), so
editor tweaks show live. The full pattern — timing anchors, map
placements that animate themselves — is in
[animation in game code](engine/stock/docs/scripting.md#animation-clips-and-sprites-cmanim-cmsprite).

Back to [the animation tutorial](engine/stock/docs/win-anim.md).
