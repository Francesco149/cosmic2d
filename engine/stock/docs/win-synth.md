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

## Walkthrough: a jump blip and the bass to go with it

Two instruments, ten minutes, both starting from stock presets — the
fastest path is always *load the nearest preset, bend it, save as
yours*.

1. **The blip**: click the `sfx-jump` preset. Play a key — hear the
   upward chirp. Now bend it: steepen the **pitch sweep** for more
   cartoon, or shorten the top operator's **decay** on the ADSR graph
   for a drier tick. Drag handles while re-triggering a note; the graph
   is live. Save as `ins/jump.ins` — upload it once in `game.init` and
   trigger it with `snd.on` (the scripting guide's sound section is the
   copyable pattern) and it's *your* jump now.
2. **The bass**: click `gb-pulse-50` (the square wave), drop an octave
   (**,**), and hold a low note. Make it rounder: lower the **filter**
   cutoff until the buzz sits back, then give the volume envelope a
   short attack and medium release so notes overlap smoothly. For growl,
   switch to an algorithm where one operator **modulates** another and
   raise the modulator's level a little — that's FM doing what filters
   can't. Save as `ins/bass.ins`.
3. **Hear them in context**: drag each straight from the preset strip
   or the assets window onto a music-tracker track row. Solo one note
   against the drums before writing a line — a bass that sounds dull
   alone often sits perfectly.

Full reference: [The music tracker](engine/stock/docs/win-music.md) and
[sound in game code](engine/stock/docs/scripting.md#sound-effects-and-music-cmsnd-cmins).
