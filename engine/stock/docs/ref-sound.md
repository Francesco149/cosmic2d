# The sound player reference — every knob and button

The complete control-surface reference for the sound player. The
guided path is [the sound player tutorial](engine/stock/docs/win-sound.md).

## What it is

A read-only player for `.wav`, `.mp3`, and `.ogg` files: drop one
anywhere in the editor and it opens here. The file on disk is the
truth — there is no journal, no save, nothing to dirty. Its one
creative act is the **→ins** door, which turns the recording into a
sampler instrument.

Playback rides the editor audition bank: it is never recorded, never
appears in replays, and headless sessions decode and play nothing.

## Header chips

- **→ins** — mono-mixes the entire decoded recording into an embedded
  sampler instrument at `ins/<name>.ins` (root note C4, a tight
  2 ms attack / 30 ms release envelope) and opens a synth window on it
  beside this one. The project no longer depends on the source file —
  the audio bytes live inside the `.ins`. Adjust root, gain, and the
  envelope in the synth ([reference](engine/stock/docs/ref-synth.md)).
- **loop** — toggles looping over the whole file (the waveform well
  tints while loop is on). Also the **l** key.
- **stop** — stops playback and rewinds to the start.
- **play / pause** — starts from the resting position, or pauses and
  remembers it. Also **space**.

## The waveform well

- The mirrored green columns are the peak profile of the whole file.
- The bright vertical line is the **playhead** — live while playing;
  the resting position otherwise. A voice that runs off the end flips
  the transport back to stopped at the start.
- **click anywhere in the waveform to seek** — while playing, playback
  jumps there immediately; while stopped, the next play starts there.
- Under the well: the position and total time (`m:ss.s`), and the
  transport state (`playing` / `stopped`).

## Keys

- **space** — play/pause
- **home** — start: jump to the beginning (keeps playing if playing)
- **l** — loop on / off

## Notes

- Two player windows on the same file stay independent — each has its
  own position, loop flag, and voice.
- Stereo files play in stereo; mono files are duplicated to both
  channels. The →ins door always mono-mixes (samplers are mono; pan
  lives on the instrument and the song track).

Back to [the sound player tutorial](engine/stock/docs/win-sound.md).
