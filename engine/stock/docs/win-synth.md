# The synth (instrument designer)

Design an instrument (`.ins`): a 4-operator FM voice (with pulse and Game Boy
noise waveforms) or a sampler. Drop it on a music track, or play it from code.

## Workflow

1. Pick an **algorithm** (how the 4 operators stack) and set feedback.
2. Shape each operator: waveform, level, and its **ADSR** envelope (drag the
   graph handles; the time axis is logarithmic so short attacks are precise).
3. Add voice **filter** + **pitch sweep** for drums and zaps.
4. Audition with the piano / tracker keys; **ctrl+s** saves.

## Keys

- **the tracker-key rows** play notes (like a chip tracker keyboard)
- **, / .** octave down / up
- **esc** silences held notes · **ctrl+z / ctrl+y** undo / redo · **ctrl+s** save

## Presets

The preset strip carries the stock instruments (the Game Boy family + an FM
family). Click one to load it into the synth; **drag** one onto a music track to
bind it there. Stock presets copy into your project's `ins/` so the song stays
self-contained.

Next: [The music tracker](engine/stock/docs/win-music.md)
