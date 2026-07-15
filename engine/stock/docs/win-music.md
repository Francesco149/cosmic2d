# The music tracker

Compose a song (`.song`): tracks of patterns arranged into clips, over
instruments you designed in the synth.

## Workflow

1. Drag an instrument (`.ins`) onto a track row to bind it.
2. In the piano roll, place notes; arrange patterns as **clips** on the timeline
   (a clip loops its pattern when you stretch it).
3. Set per-track volume; **ctrl+s** saves. The game plays it with
   `cm.snd.music(...)`.

## The roll grammar

- **press empty** adds a note (at the last-used length, grid-snapped)
- **drag** a note moves it · **drag its right edge** resizes · a **motionless
  click** on a note deletes it
- **ctrl** = fine ticks (off the grid) · **ctrl+drag** a note duplicates it

## Keys

- **space** play / stop (from the scrub cursor) · **del** delete the selection
- **1–6** set the placement grid · **esc** stops / clears the selection
- **ctrl+c/x/v** clipboard · **ctrl+z / ctrl+y** undo / redo · **ctrl+s** save
- **wheel** zoom · **middle-drag** pan (while focused)

Next: [The synth](engine/stock/docs/win-synth.md)
