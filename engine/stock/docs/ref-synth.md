# The synth reference — every knob and button

This is the complete control-surface reference for the instrument
designer. The guided path is [the synth tutorial](engine/stock/docs/win-synth.md);
this page is for when you are holding the window and want to know
exactly what the thing under your cursor does.

## The window at a glance

From top to bottom: the **header** (the presets chip and the standard
save/dirty chrome) · the **voice strip** (algorithm, feedback, gain,
pan, filter, sweep — everything shaping the whole voice) · the
**four operator panels** (the sound itself) · the **audition piano**.
Toggling **presets** adds a scrolling rail down the left edge.

A window with no file bound is the **new instrument** door: a path
field (a unique name is prefilled, the `.ins` extension is forced).
Enter creates the file; an existing path offers open / overwrite /
cancel. The fresh patch is a sounding two-operator pair — op1 quietly
modulating, op2 carrying — so the piano makes a tone immediately.

## Thirty seconds of FM

Each of the four **operators** is a little oscillator: a waveform
running at (usually) a multiple of the note you play, shaped by its own
ADSR envelope. The **algorithm** decides each operator's job: a
**carrier** is mixed into what you hear; a **modulator** bends the
phase of the operator it feeds, which adds harmonics to *that*
operator's sound. A sine carrier alone is a pure tone; push a modulator
into it and it grows brightness — gently for electric pianos, hard for
growls and metal. That one idea, plus envelopes per operator, is the
whole instrument. Voice-wide gain/pan, a one-pole filter, and a pitch
sweep finish the sound.

Everything renders in the deterministic integer kernel (no drift, no
platform differences); edits re-send the patch live, so tweak while a
note rings.

## Header

- **presets** — toggles the preset rail (below).
- The title carries the standard unsaved marks (the amber dot and the
  trailing `*`). **ctrl+s** saves, **ctrl+z / ctrl+y** walk the undo
  journal — every finished gesture (a slider release, a chip click, a
  preset load) is exactly one undo step.

## The presets rail

Lists every stock instrument (`engine/stock/ins/`, 53 of them) and
every `.ins` in your project's `ins/` folder, labeled `stock` or
`project` on the right.

- **click** a row — loads that patch into the working bytes (one
  journaled, undoable step). The instrument keeps *your* file's name;
  only the sound changes. The loaded row stays highlighted so you never
  lose your place while preset-hopping.
- **drag** a row out of the window — carries the instrument to a music
  window track (a stock preset copies into your project's `ins/` on
  drop, so songs stay self-contained).
- **wheel** over the rail scrolls it; the thin bar on the right edge is
  the position cue.

## The algorithm chips (1–8)

The wiring diagram for the four operators. `a>b` means "a modulates b";
what is listed after the arrows are the carriers you hear.

    chip 1   1>2>3>4            hear: 4      the deepest stack — each op
                                              bends the next; wild, hissy
    chip 2   (1+2)>3>4          hear: 4      two modulators into a chain
    chip 3   (1 + 2>3)>4        hear: 4      a chain and a direct mod
    chip 4   (1>2 + 3)>4        hear: 4      likewise, other order
    chip 5   1>2   3>4          hear: 2+4    TWO independent pairs — the
                                              melodic workhorse (bells,
                                              keys, plucks: a main pair +
                                              a sparkle pair)
    chip 6   1>2  1>3  1>4      hear: 2+3+4  one modulator brightens
                                              three carriers (choir)
    chip 7   1>2   3   4        hear: 2+3+4  one modulated voice + two
                                              plain ones (brass)
    chip 8   1  2  3  4         hear: all    no modulation — pure
                                              additive. Organs, detuned
                                              ensembles, drums, and every
                                              Game Boy channel

Rule of thumb: start at chip **5** for pitched instruments (one pair =
the tone, the other pair = attack color), chip **8** for chip-tunes,
drums, and layered/detuned sounds.

## The feedback chips (fb0–fb7)

Operator 1 modulating **itself**. fb0 is off; each step roughly doubles
the bite: fb1–2 thicken a sine toward a saw, fb4–5 rasp (brass), fb6–7
snarl and hiss (hard leads, distortion). Feedback only does anything
when op1 is audible in the algorithm's wiring — on chip 8 it turns op1
alone into a saw-ish voice for free.

## gain and pan

- **gain** 0–255 — the voice's own volume; 128 is unity. Stock drums
  run hot (140–190), pads a touch under.
- **pan** −64 (left) … +64 (right). A song track's own pan is applied
  *on top* of this, so an instrument authored off-center stays
  off-center in the mix.

## The filter (flt · cut)

A one-pole voice filter, applied after the operators mix:

- **flt** — `off` (true bypass), `lp` (low-pass: darkens, tames buzz —
  pads, choirs, upright bass), `hp` (high-pass: thins the body away —
  hats, rims, the Game Boy noise "sizzle").
- **cut** 0–255 — the cutoff index (a tuned table, not literal Hz).
  For `lp`: lower = darker. For `hp`: higher = thinner. With `flt` off
  the slider is inert.

## The pitch sweep (swp · sw ms)

The voice glides from the played note toward note + **swp** semitones
(−48…+48), arriving after **sw ms** milliseconds (0–1000), then holds.
Either at 0 = no sweep. This is the drum-and-SFX workhorse:

- kicks drop: swp −20…−26 over 40–70 ms
- coins and jumps chirp up: +14…+19 over 65–90 ms
- powerups rise long: +24 over 260 ms
- lasers and explosions fall: −20…−30 over 150–450 ms

The sweep moves every operator together (ratios stay intact), affects
FM voices only, and is linear in the frequency multiplier — which is
exactly why swept kicks punch.

## The operator panel (op1–op4)

Four identical panels. An operator with **lvl 0 is off** — the fresh
patch ships op3/op4 silent.

- **wave chips** — `sin` pure · `sq` square · `p25` / `p12` pulse (25% /
  12.5% duty — the NES/GB pulse colors) · `saw` · `tri` · `ns` noise
  (15-bit LFSR) · `ns2` short-mode noise (7-bit — tighter, metallic,
  the Game Boy's second noise color). The noise clock follows the
  operator's frequency: crs (or a fixed Hz) sets how *fast* the noise
  is, i.e. its color.
- **lvl** 0–255 — on a carrier: loudness. On a modulator: **brightness**
  of the operator it feeds — this is the single most expressive FM
  knob. Drag a modulator's lvl while holding a note and listen.
- **crs** 0–15 — the frequency ratio: the operator runs at N× the note
  (0 = ×0.5, one octave down — the sub knob). Carrier at 1, modulator
  at 1 = warm; modulator at 2–4 = brighter, hollow; big odd ratios
  (7, 11, 14) = bells and metal.
- **fin** −63…+63 — fine ratio trim, up to about ±6%. Small values
  against another op = chorus shimmer; larger = clangy inharmonics
  (the cowbell is two squares at 5:7 pushed ±20 fin apart).
- **dtn** −63…+63 — micro-detune, about ±0.4% at the extremes. Too
  small to hear as pitch, exactly right for **width**: two saws at
  dtn −34/+34 are the classic reese; strings sit at ±14. Use fin for
  color, dtn for ensemble.
- **fix** — `note` (default): the operator tracks the key. Dragged up,
  the operator locks to a **fixed frequency** (20 Hz–12 kHz, log
  scale) no matter what note plays. Drum bodies (kick thump ≈ 120 Hz),
  noise colors (hat hiss ≈ 9 kHz, snare rattle ≈ 5 kHz), and breath
  live here — play the kick up and down the keyboard and it stays the
  same kick.
- **the ADSR graph** — the operator's envelope in three regions:
  **attack** (left third: 0–2000 ms to full), **decay + sustain**
  (middle: 0–2000 ms down to the sustain level 0–255 — drag
  horizontally for decay, vertically for sustain), **release** (right
  third: 0–4000 ms to silence after the key lifts). Grab a handle and
  drag; a live readout shows the value. The time axis is
  **logarithmic** — equal pixels are equal ratios, so a 2 ms pluck, a
  30 ms tap, and a 300 ms swell are all easy to hit. Sustain 0 with a
  short decay = percussive; sustain high with decay 0 = organ-flat.
  A carrier's envelope shapes loudness; a modulator's envelope shapes
  brightness *over time* (bright attack fading to mellow = every
  plucked string in the stock set).

## The audition piano and the tracker keys

- The strip along the bottom is two octaves of piano from the window's
  base octave: **click** to hear, **hold** to sustain, release to stop.
- The tracker keyboard plays without the mouse: **z x c v b n m** are
  the lower octave's white keys (sharps on **s d g h j** above them),
  and **q w e r t y u i** the octave above (sharps on the number row).
- **,** / **.** — oct− / oct+: shift the base octave down / up
  (oct 1–7, shown above the piano; both repeat while held).
- **esc** silences everything ringing.

Auditions play on the editor bank: they are never recorded, never in
replays, and never disturb a running game's mix.

## Sample instruments

An `.ins` can be a **sampler** instead of an FM voice — made by
pressing **→ins** in the sound player (see
[the sound player reference](engine/stock/docs/ref-sound.md)), which
embeds the recording into the file. The synth window then shows:
**root** (0–127 — the MIDI note at which the sample plays back
unchanged), **gain**, and one voice-wide ADSR. Everything else (the
piano, presets, save/undo) works the same; other notes resample from
the root.

## How the stock presets are built

Every stock instrument was authored with exactly the knobs above.
Recipes by family — load one, open this list, and check the claims
against the sliders:

**The Game Boy family** — chip 8, one operator, that's the whole
console: `gb-pulse-50/25/12` are one square/p25/p12 carrier (the three
duty colors), `gb-wave-bass` one tri at crs 0 (the wave channel an
octave down), `gb-arp` a square with a fast 90 ms decay for arpeggio
stabs. The drums are the noise channel: `gb-noise-hat` = ns fixed at
9 kHz through a hp filter; `gb-noise-snare` = ns at 5 kHz + ns2 at
8.2 kHz; `gb-noise-kick` = a sine fixed at 150 Hz swept −26 semitones
in 40 ms with a dab of 2 kHz noise.

**Bells and mallets** — chip 5, pairs at wide ratios, every envelope
decaying to sustain 0: `fm-bell` modulates 2 with 7 (7:2 = the classic
bell clang); `fm-musicbox` a 5:2 pair plus an 11:4 "sparkle" pair;
`fm-vibes` 4:1 with a 1.6 s decay; `fm-xylo` 3:1 plus a fast 10:3
click; `fm-glass` slow 200–350 ms attacks on 7:2 and 11:3 pairs with
fin offsets. The recipe: modulator crs much bigger than carrier crs;
the second pair is a quieter, faster echo of the first.

**Keys and plucks** — chip 5, instant attack, the modulator's decay
shorter than the carrier's (the bite fades first): `fm-epiano` 1:1
pair + a 14:1 click pair, lp 218; `fm-pluck` a bare 3:1 over 1:1;
`fm-harp` and `fm-nylon` the same idea with longer carrier tails;
`fm-harpsi` adds fb2; `fm-clav` runs saw/pulse waves through hp 55
for the funk snap; `fm-upright` drops the carrier to crs 0 under
lp 140.

**Winds, voices, sustains** — slow-ish attacks, high sustains:
`fm-brass` chip 7 with fb5 (the rasp) and 35–60 ms attacks; `fm-flute`
chip 8 sines at 1/1/2 plus a 6.2 kHz fixed noise breath op; `fm-reed`
a p25 carrier; `fm-choir` chip 6 — one sine brightening three carriers
detuned −10/+12/+8 under lp 150; `fm-organ` chip 8 with sines at crs
1/2/3/4 (drawbar harmonics), decay 0, sustain full.

**Ensemble width** — the dtn knob's home: `fm-strings` two saws at
dtn ∓14 with a 2× saw shimmer, lp 180, slow envelopes; `fm-reese`
two saws at dtn ∓34 plus a crs-0 square under lp 112 (drum'n'bass
bass); `fm-drone` stacked saws/tri at dtn −20…+24 with 600–900 ms
attacks, fb4.

**Drums** — chip 8, fixed-frequency ops, negative sweeps, sustain 0
everywhere: `fm-kick` = sine carrier swept −20/70 ms + a sine fixed
at 120 Hz (the body) + noise fixed at 3.2 kHz for 30 ms (the beater);
`fm-snare` = a sine thump + ns at crs 6; `fm-tom` / `fm-timpani` =
crs-0 sines with a noise dab (timpani sweeps −5 over 180 ms);
`fm-conga` a 175 ms sine with 2.5 kHz noise, swept −3; `fm-hat` one
ns2 at crs 15 decaying in 40 ms; `fm-shaker` ns fixed 11 kHz through
hp 160; `fm-ride` ns fixed 9.5 kHz decaying over a full second + a
9× sine ping; `fm-rim` an 8×+30fin square tick + ns2 at 4 kHz;
`fm-cowbell` two squares at 5 and 7 with fin +22/−15 (the clang is
the beat between them); `fm-orchhit` three saws at 1/2/3 + noise,
all decaying together.

**SFX** — chip 8, usually ONE operator, the sweep *is* the effect:
`sfx-coin` sine at crs 4, +19 semis in 65 ms; `sfx-jump` p25 at crs
2, +14 in 90 ms; `sfx-powerup` the same pulse riding +24 over a long
260 ms; `sfx-laser` ns2 fixed 9 kHz falling −20; `sfx-hit` ns2 4 kHz
+ a square, −10 in 60 ms; `sfx-land` a 190 Hz sine thud, −12;
`sfx-dash` a 10.5 kHz noise whoosh, −5 over 200 ms; `sfx-explosion`
5.2 kHz noise + a 92 Hz square rumble, −30 over 450 ms under lp 160.

The meta-recipe: pitched sound → **chip 5**, tune the pair's ratio,
shape both envelopes. Chip sound, drum, or sfx → **chip 8**, one to
three ops, fix what shouldn't track the key, and let the sweep do the
talking.

## Files and code

An instrument saves as a `.ins` (the CINS container: name + the packed
patch + embedded sample PCM if any). Songs reference instruments per
track; games upload one with `cm.ins` and trigger it through `cm.snd`
— the copyable pattern is in
[sound in game code](engine/stock/docs/scripting.md#sound-effects-and-music-cmsnd-cmins).

Back to [the synth tutorial](engine/stock/docs/win-synth.md).
