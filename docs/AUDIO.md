# AUDIO.md — sound + music (R9, D058)

> The R9 design: the audio engine (the M9 debt, finally paid), the sound
> and music windows, and the windowkit generalization they ride on.
> Written design-first per REVAMP §3.1; ADR D058 records the binding
> choices. The wstudio survey (zexk/wstudio, a minimal no-plugins DAW
> guided by a producer) informed the music-editor scope — its lessons are
> cited inline as [W].

The asks (human, 2026-07-13, verbatim intent):

- A basic **sound design tool**; drag-and-drop mp3/wav/other audio opens
  a **generic sound player**; FM-synth'd sounds open in **the synth**.
- A basic **music editor** composing designed instruments + samples;
  a few reasonable **stock presets, including gameboy-voice mimics**.
- Same UX philosophy: **mouse-driven**.
- **Per-window hotkeys**, and the common window patterns **generalized**
  rather than reimplemented per window (no more footguns when a UX
  change should reflect everywhere).

## 1. Scope + shape

Five phases (§12): **R9a** the windowkit (hotkeys + shared window
patterns — the foundation the new windows are built on, and the existing
ones migrate to), **R9b** the PAL audio core, **R9c** the sound player +
instrument windows + stock presets, **R9d** the music window + song
playback, **R9e** the game hookup (sfx + a first track, in
../cosmic2d-game — the original M9 sfx list).

Deliberately out of v1 (each has a §13 revisit trigger): effects
(reverb/delay/filter racks), automation lanes, tempo changes mid-song,
non-/4 meters, sample slicing, MIDI in/out, audio input. wstudio's
roadmap rule applies: sort by what most blocks an artist *finishing* a
loop [W].

## 2. The audio engine — PAL core (R9b)

The ARCHITECTURE.md sketch, made concrete. PAL owns the audio device and
the voice inner loop (C, deterministic); Lua owns patches, sequencing,
and mixing decisions.

### 2.1 Clock + formats — the frame lock

- **Sample rate 48000 Hz, stereo, i16 output.** At 60 sim fps that is
  **exactly 800 samples per sim frame** — the whole timing model is that
  one integer.
- The **sim bank** renders exactly 800 stereo samples per sim step, ON
  the sim thread, in C (32 voices × 4 ops at 48 kHz is trivial). PCM is
  a **pure function of (voice state, this frame's commands)**; voice
  state lives in a named buffer and advances once per sim frame.
- Rendered frames push into an eight-frame-capacity **output FIFO**. The live
  producer and consumer normally stay close rather than intentionally priming
  all eight frames, keeping control-to-sound latency low. The SDL3 audio callback
  only memcpys from the FIFO — it never computes. Underrun (a stalled
  editor frame, an unfocused paused game) plays silence; state is never
  touched from the callback. No locks on the hot path: single-producer
  (sim thread) / single-consumer (callback) ring.
- **Headless renders the same PCM and discards it** (or hashes it —
  §5). No device is ever opened headless. Goldens can't hear by
  construction.

### 2.2 Two banks — sim vs editor

The same split as D036 render-only, applied to sound:

- **The sim bank**: driven only by recorded sim-side commands
  (`cm.snd`, §6). State in named buffers → snapshotted, traced,
  delta-recorded in the ring, **rewound like any sim state**. Replays
  regenerate identical PCM.
- **The editor bank**: the audition path — synth-window piano presses,
  sound-player playback, music-window preview. State is PAL-internal
  (never a named buffer, never recorded, never snapshotted). Driven by
  immediate `pal.x_snd_ed_*` calls through a lock-free command ring, and
  rendered **in the audio callback itself** — press a key, hear it now,
  no 3-frame FIFO latency. Headless/capped runs never init it; goldens
  are untouchable by construction.

Both banks mix into the device stream; master gain + a hard soft-clip
(tanh-shaped i32→i16 fold) on the sum so hot mixes duck instead of
wrapping [W: the always-on limiter default].

### 2.3 The voice — 4-op FM, chip-flavored

PLAN.md M9 pinned "voices × 4-op, envelopes, feedback, a few
algorithms". Kept, with one twist that buys the gameboy ask for free:
**operators have selectable waveforms**, so a single unmodulated op IS a
chip voice.

Per voice:

- **4 operators**, each: waveform (**sine / square / pulse25 / pulse12.5
  / saw / triangle / noise-LFSR**), frequency ratio (coarse 0..15 ×
  fine), optional fixed-frequency mode, output/mod level 0..127, ADSR
  envelope (fixed-point attack/decay/sustain/release rates), detune.
  The LFSR op is the gameboy/NES noise channel (15-bit taps, short-mode
  flag for the metallic variant).
- **8 algorithms** (the classic OPN-style wiring set: 4-serial through
  4-parallel), **feedback 0..7** on op 1.
- Per-voice: note (0..127) + pitch offset, velocity (scales op output
  levels), pan (constant-power from a LUT), gain.
- **Sampler voice type** (for the music editor's "samples"): mono i16
  PCM + root note + optional loop points, fixed-point (16.16) step
  resampling, amp ADSR. One-shot or looped.
- **Voice-wide fx (R9f)** — two patch-level controls the GB-noise
  research (docs) flagged as the gap between a *click* and a *sizzle*:
  a **1-pole filter** (`filter` off/lp/**hp**, `cutoff` 0..255 index →
  ~20 Hz..16 kHz via the `SND_FILT_A` Q16 LUT; hp = the bright noise
  that cuts through — rustle/dash/hat sizzle), and a **pitch sweep**
  (`sweep` semitones + `sweep_ms`: glide every op's increment from ×1
  toward ×2^(sweep/12), reusing the semitone-ratio LUT — kick drops,
  whooshes, lasers, descending metallic snares). Both live in the
  `SndPatch` pad tail and **bypass at 0**, so every pre-R9f patch and
  the PCM golden render byte-identical. Filter state (`flp`) + the sweep
  clock (`nsamp`) are per-voice, reset on note-on — recorded/rewound
  like all voice state. *(Deferred: per-op filters, retrigger/loop-gate
  for machine-gun rustle — the research's third lever.)*

Budget: **32 voices per bank**. Allocation is explicit (the caller gets
a voice id) with deterministic stealing (oldest released-then-quietest;
no wall clock, no pointer order).

### 2.4 The kernel discipline (determinism across platforms)

The iron rules applied to C: **integer/fixed-point only in voice
state and the render loop** — u32 phase accumulators, quarter-wave
sine LUT (s16) + exp/level LUT (the OPN idiom), fixed-point envelope
counters, i32 mix accumulator. **No libm, no floats in state, no
FMA-sensitive math** — bit-exact on every platform by construction,
and it *sounds* like the chips we're mimicking. The whole sim-bank
state (voices + patch slots) is one self-describing named buffer with
a versioned layout (`snd.bank`), like `cm.sim`.

### 2.5 Commands + patches

Sim-side Lua appends commands during the step; the end-of-step render
consumes them in order:

```
pal.snd_patch(slot, bytes)         -- upload a patch (flat struct, §4.1)
pal.snd_pcm(slot, buf_name, root, lp0, lp1)  -- bind sample PCM
pal.snd_on(voice, slot, note, vel) -- voice = -1: allocate, returns id
pal.snd_off(voice)
pal.snd_set(voice, param, value)   -- gain/pan/pitch bend
pal.snd_render()                   -- cm.main calls once per sim step
```

64 patch slots per bank. Sample PCM for sim-bank instruments lives in
named buffers (`snd.pcm/*`) — sim state, so replay/rewind hold; the
keyframe cost is accepted for v1 and watched (§13).

The editor bank mirrors the surface as `pal.x_snd_ed_on/off/set/patch`
plus `pal.x_snd_ed_stream(pcm, pos)` — the sound player's streaming
voice (stereo, no pitch, seekable).

### 2.6 Decoders

Vendored single-header decoders next to stb: **dr_wav, dr_mp3,
stb_vorbis**. `pal.x_snd_decode(path)` → interleaved i16 + rate,
resampled to 48 kHz on decode (editor-side utility — sim never reads
files, D028 rule). The asset browser's sound class (.wav/.ogg/.mp3)
finally routes somewhere (§8).

## 3. Determinism + rewind (the contract)

- Synth state is sim state (ARCHITECTURE.md determinism section,
  already written): commands are frame-locked, PCM is pure, **audio
  goldens hash PCM** (§5).
- The ring records `snd.bank` deltas like any buffer → **scrubbing
  rewinds the mix**; resuming from a parked frame resumes the song
  mid-note. Verify mode catches any voice-state divergence byte-first.
- The editor bank is render-only by the same construction that keeps
  imgui out of goldens: headless never inits it, the recorder never
  sees it.
- The audio callback never touches sim state; the sim thread never
  blocks on the device. The only shared structure is the PCM FIFO
  (SPSC) and the editor-command ring (SPSC the other way) [W: the
  never-block iron rule].

## 4. The assets

Both new formats are cm.chunk containers (the CSPR/CMAP idiom: magic +
versioned tagged chunks, unknown tags skipped, pure codec modules with
KATs, canonical encode).

### 4.1 `.ins` — the instrument (CINS)

One instrument = **one flat struct of defaulted scalars** [W: patch =
param table; presets cost no code]. Chunks:

- `HEAD` v1 — type (0 fm / 1 sample), name.
- `FMPT` v1 — the FM patch: algorithm, feedback, then 4 × op
  {wave, ratio_coarse, ratio_fine, fixed_flag+freq, level, a, d, s, r,
  detune}, master gain, pan. Fixed size, byte-packed, every field
  defaulted — additive growth needs no version bump.
- `SMPL` v1 — sample type: root note, loop points, amp ADSR, gain, pan,
  and the **embedded mono i16 PCM** (self-contained; projects move as a
  unit).

`cm.ins` is the pure codec. Editing = the standard working-bytes +
journal citizen via the windowkit (§7).

### 4.2 `.song` — the song (CSNG)

Time is integer ticks at **PPQ 96**: a quarter note is 96 ticks. Tempo
is BPM u16; samples-per-quarter derives in 32.32 fixed point
(48000·60 / (bpm·96)) — integer math end to end. `beat_unit` turns that
quarter-note clock into the notated beat, and `beats_per_bar` derives bars.
Steps remain a presentation concern [W: frames as the single time truth].

Model (round 7 — the human): an **arrangement of clips**. A clip
places a pattern on a track at a bar with a length; **resizing a clip
longer than its pattern LOOPS the pattern to fill** (the "auto loop").
Patterns are saved, named units. **+ pat** creates a fresh active pattern;
pressing empty arrangement space places that active pattern, and Shift-drag
duplicates clips with the same pattern reference. One note edit therefore
updates every deliberately linked placement.

- `HEAD` v2 — bpm, beats_per_bar, beat_unit (default 4/4), loop region,
  legacy grid. v1 reads as a quarter-note beat unit.
- `TRKS` v1 — tracks: name, instrument path (.ins), gain, pan, mute.
  (v2 carried a per-track `pat` — round 6; read + migrated to clips.)
- `PATN` v2 (×N) — patterns: id, saved name, length (ticks), notes
  {tick_on, tick_len, pitch 0..127, vel 0..127}. A pattern's length
  **grows to fit content but never auto-shrinks** (`fit_pattern`;
  clips loop a short one to fill). v1 receives the stable name `pattern N`.
- `ARRG` v1 — clips {track, tick, len, pattern}.

`cm.song` is the pure codec + `normalize` (round-6 per-track docs
migrate to clips; missing pattern refs heal; deliberate sharing stays
linked) + the **flatten**: clips loop their patterns → one
absolute-tick note list per track. Playback never walks the doc [W];
the sequencer walks the flat list.

### 4.3 Sound files

.wav/.ogg/.mp3 stay what they are — droppable assets, playable in the
player window (§8), importable as sampler instruments (§9). No new
container.

## 5. Testing

- **PCM-hash goldens**: a scripted command sequence (note on/off ladder
  across patch types, the stock presets, a short .song via the
  sequencer) rendered headless for N frames; the golden stores the FNV
  hash of the PCM (and the tail as bytes for diffability). Pinned
  lavapipe irrelevance noted: audio goldens are pure C + Lua, they run
  everywhere the suite runs.
- **KATs**: cm.ins/cm.song round-trip + canonical encode; the flatten
  (clip loop/override cases); samples-per-tick math; envelope stepping;
  LFSR sequence; voice stealing determinism.
- **Tape proofs** for the windows, per the R8 idiom (real events through
  pal.poll_events).
- The **taste check is the human's ears** — llm-feed carries shots
  (window UX, waveform/spectrogram renders where useful) but presets get
  a live listening pass.

## 6. `cm.snd` — the game API (sim-side)

```lua
cm.snd.load(path)            -- .ins → patch slot handle (cached)
cm.snd.play(ins, note, vel, opts) -- one-shot sfx → voice id
cm.snd.stop(voice)
cm.snd.music(path)           -- start the song (flattened, looped)
cm.snd.music_stop()
cm.snd.step()                -- cm.main calls inside the sim step:
                             -- advances the sequencer, emits pal.snd_*
```

The sequencer (`cm.snd.seq`, pure core + thin driver) converts ticks →
frame boundaries in fixed point and emits note commands on the frames
they land in. Music is sim state: it records, replays, and rewinds with
everything else. sfx calls sit in game code exactly where the action
happens (jump/land/slice… — R9e).

## 7. The windowkit (R9a) — hotkeys + the generalized citizen

The survey found the §6 asset contract hand-copied ~150 lines × 4
(sprite/map/tmap/text), hotkeys hardcoded in the shell, and new-kind
registration touching three files. R9a factors this ONCE, migrates the
existing kinds, and the audio windows are built on it — the point is
that the next UX change lands in one place. EDITOR.md grows **§13**
recording the contract when this lands.

### 7.1 `cm.ed.kit.asset(spec)` — the working-bytes factory

```lua
local kit = cm.require("cm.ed.kit")
local A = kit.asset {
  field = "ins",              -- doc.assets[path].<field> = the bytes
  jcap  = 512,                -- journal cap
  fresh = function(path) ... end,   -- unbound path field → new bytes
  decode = cm.ins.decode, encode = cm.ins.encode,
  after_commit = function(ed, path) ... end,  -- epoch bumps etc.
}
-- A provides: open_asset/open_path, commit/commit_path, dirty, save,
-- undo, redo, revert, plus the ed.g.<kind>w plumbing lifecycle
-- (park/unpark reset, bring_back payload registration).
```

sprite/map/tmap/text migrate onto it **behavior-identical** (the
existing selftests + tapes pin that); anim keeps delegating through
sprite's doors, which the factory now provides uniformly. The
open_path/commit_path doors are part of the factory, so any future
window pair (music ↔ synth is one: double-click a track's instrument)
shares bytes + one journal for free.

### 7.2 Per-window hotkeys — declarative tables

```lua
M.hotkeys = {
  { key = "space", when = "bound", hint = "play/stop",
    fn = function(win, ed) ... end },
  { key = "ctrl+d", hint = "duplicate", fn = ... },
  ...
}
```

- The shell dispatches the **focused** window's table after its own
  ctrl-combo pre-gates (Ctrl+S/F stay global) and before shell plain
  keys; a match consumes the key. `wants_keys` kinds keep claiming the
  remainder; the game window's filter_events path is untouched.
- Declarative means the **hint bar renders itself** (the map window's
  hand-rolled key hints migrate) and a future help overlay is free.
- Existing ad-hoc per-kind key handling (map tool keys, sprite keys,
  text's find bar) migrates into tables; Esc stays the shell ladder +
  `kind.escape`.

### 7.3 Self-describing kinds — one-file registration

Kind modules declare `M.exts = {"ins"}`, `M.menu = "synth"`,
`M.DEF_W/H`; ed.lua builds `M.kinds`, the spawn menu, and
`kind_for()` from one roster list. Adding a window kind becomes: write
the module, add one require line.

### 7.4 Shared chrome + view helpers

- `cm.ed.chips` — the header button/chip/field helpers every kind
  hand-rolls today (hover via ctx.hot, on/off fill, width accounting).
- `kit.viewlock(M, opts)` — installs the standard own_view / wheel /
  takes_middle trio over cm.ed.winview (the §12.7 contract), instead of
  each kind re-deriving focus gating.

## 8. The sound player window (kind `sound`)

The generic player — drop any .wav/.ogg/.mp3 anywhere (the existing
drop-anywhere = import + open flow) and it opens here; `kind_for`'s
sound class finally returns a window.

- **View**: the waveform (min/max peak columns from the decoded PCM,
  cached per path+width), playhead line, loop-region shading, duration/
  position readout.
- **Mouse**: click = seek; drag on the waveform = set loop region;
  the usual winview wheel-zoom into long files (world units = samples).
- **Header chips**: play/pause, stop, loop toggle, gain field.
- **Hotkeys** (the §7.2 table): space play/pause, home = start,
  L = loop toggle.
- Read-only, no journal. Playback = the editor bank's stream voice.
  An "→ins" header chip imports the file as a sampler `.ins`
  (mono-mixed, root C4) and opens the synth window on it — the door
  from found-sound to instrument.

## 9. The instrument window (kind `synth`)

Binds `.ins` — the sound design tool. A full windowkit asset citizen
(journal, dirty dot, ctrl+Z/S, unsaved-persists, rewind bring-back).
FM-synth'd sounds open here (double-click an .ins anywhere); the
unbound path field creates a fresh one from the init patch.

Layout (mouse-first, one screen, no tabs):

- **Algorithm picker**: the 8 wirings as clickable thumbnails.
- **Feedback + master**: feedback 0..7 chips, gain/pan fields.
- **4 operator panels**: waveform chip row, ratio coarse/fine fields,
  level slider, and a **draggable ADSR envelope widget** (four
  breakpoints on a small graph — grab and drag, the teidraw feel; one
  gesture = one journal entry, per the R8 gesture rule). The A/D/R times
  live on a **logarithmic axis** (round 8 — the human: a linear/squared
  axis crammed the musically-useful short times into a few pixels, so a
  pluck vs a soft attack were 1–2 px apart; log spreads them by ratio,
  fine at the short end and still reaching seconds). Three fixed thirds
  (A | D·S | R) with boundary guides; the DRAW and the DRAG share the
  mapping (a prior bug drew handles linearly but dragged them squared —
  the handle jumped on grab); the hovered/dragged handle glows and a
  live ms/level readout shows the exact value.
- **Sample type** swaps the op panels for: waveform view, root-note
  field, draggable loop points, amp ADSR.
- **The piano**: two on-screen octaves along the bottom; press =
  audition through the editor bank (release = note off). Per-window
  hotkeys give the tracker keyboard (z s x d c v … = C D E F, q 2 w 3 …
  the octave up; `,`/`.` octave shift) — playable while mousing knobs.
- **Preset strip**: a browser over `engine/stock/ins/*` + the
  project's own instruments; **click** = load into the working bytes
  (journaled, undoable); **drag a row onto a music track** = bind it
  there (round 5 — the shell's g.adrag carry → the music window's
  `drop`; a stock preset copies into the project's `ins/` first, §10).

Every parameter edit re-sends the patch to the editor bank live —
tweak while a note rings.

## 10. The music window (kind `music`)

Binds `.song` as a **whole-song arrangement plus pattern drill-in editor**.
Preview runs on the render-only editor bank; games play the same bytes through
`cm.snd.music`.

- **Track rail.** Drag `.ins` assets onto rows; external/Stock sources copy
  into `ins/` first. Rows own mute, Ctrl+click solo with exact mute restore,
  deletion, gain 0..255, and pan −64..64. Mix edits re-bake live. Preview
  patch ownership is keyed per track assignment (path + gain + pan), checked
  continuously against the shared editor-bank slot owner, and gated by a
  per-track ready bit. Deleting/reindexing a track, undoing, rebinding, adding
  a blank track, or losing a slot claim can therefore never make a lane play a
  stale preset that differs from its displayed assignment.
- **Named patterns and arrangement.** `+ pat` creates an unplaced one-bar
  pattern with a saved editable name. Plain empty-space click places the active
  pattern; right-click erases. Plain drag moves the selection, Shift-drag
  makes linked copies, Ctrl marquee selects, Ctrl+Shift extends, and Alt
  temporarily bypasses one-beat horizontal snap. Marquee time edges follow the
  pointer exactly while vertical edges expand to whole track rows; intersecting
  clips highlight live before release. Vertical movement remains whole tracks.
  Right-edge resize is beat-snapped. Clips loop/truncate their pattern to fill
  and linked references survive save/load.
- **Two explicit transports.** A ruler attached to the arrangement owns the
  independent song cursor and whole-song loop. The roll's ruler and **clip**
  button own the last-clicked clip instance: they loop its exact song span
  while other tracks remain audible. Space follows the last explicit scope
  and falls back to song scope when no clip is selected.
- **Piano roll.** The default placement grid is 1/4 with all divisions through
  1/32. Ctrl marquee/replace and Ctrl+Shift add/toggle selection; Shift-drag
  duplicates without pitch drift. Right-click deletes. The enlarged
  right-edge hitbox resizes the whole selected set, while a separate selection
  handle stretches timing and durations. Ctrl+A/D, semitone, 1/32, beat,
  octave, duplicate, and double-spacing commands cover exact keyboard edits;
  double-spacing overwrites same-pitch colliders. Paste follows pointer time
  but preserves copied pitches. Up/Down smoothly scroll pitch.
- **Readable pitch view.** Rows default to twice the old height and middle-drag
  on the piano keys changes row height. Notes name their pitch when space
  permits; holding a key or note lights the entire row. Piano marquee edges
  follow pointer time and expand only to complete pitch rows, with note
  highlights updating during the drag. Wheel/MMB keep the existing focused
  time zoom/pan contract; vertical MMB pan remains fractional and pixel-smooth
  across pitch boundaries. Arrangement/roll zoom and pan, pitch scroll, and
  row scaling glide by default under the global **smooth pan / zoom** switch
  in the canvas Aa panel; off means immediate motion. Deleted notes and clips
  leave a brief collapsing inner glow attenuated by **reduce flashes**. The
  velocity lane retains relative group editing.
- **Step sequencer.** The `steps / piano` chip opens a one-bar channel-rack
  view across tracks. Left adds, right erases, alternating groups expose beats,
  and each row's **roll** button drills into the same pattern bytes.
- **Typed timing.** BPM accepts 1..999. Time signature accepts numerators
  1..32 and power-of-two denominators 1..128; rulers, beat snap, step cells,
  and grow-to-bar math use `cm.song.beat_ticks/bar_ticks`.

Pattern length still grows to the smallest fitting whole bar and never
auto-shrinks. An exact-fit selected clip follows growth; intentionally shorter
or longer clips do not. Playback state is ephemeral; Ctrl+S atomically writes
the asset and refreshes Assets.

### H8 tutorial audit (2026-07-22)

The shipped Music lesson now builds **Moonlit Relay** as one exact eight-bar
CSNG: four instrument-bound tracks, three backing patterns stretched across
the arrangement, a two-bar lead pattern reused through two linked clips, and
an independent answer pattern. It exercises held-key audition, drag-to-length,
group selection, clipboard ghost placement, octave movement, velocity editing,
clip stretching, linked reuse, scoped playback, stereo gain/pan, atomic save,
canonical decode, and runtime flattening. The matching executable tape passes
43/43 live verdicts, including saved pattern naming, step add/erase/drill,
typed 137 BPM / 7/8 timing with undo, eased and immediate view motion, a live
vertical-only-snapped arrangement marquee, fractional piano MMB pan, live note
marquee highlighting, both deletion afterimages, and canvas MMB pan making
substantial progress before release then settling exactly. It owns five @2x
capture points: roll, arrangement, mix, steps, and live selection.

The updated interaction boundary is explicit in both the tutorial and
`ref-music.md`: `+ pat` creates, ordinary placement reuses the active pattern,
Shift-drag duplicates clips, Ctrl owns selection, and Alt owns temporary snap
bypass. The address bay reports bar/beat/tick and pitch, adding stored
duration/velocity over a note. Saving refreshes Assets, but a running game's
path-keyed song cache does not hot-reload that same path; restart the game
before judging a resaved arrangement.

## 11. Stock presets + demo songs (ship with the engine)

`engine/stock/ins/` — 52 .ins files, all engine-made (parameter
tables, no shipped audio bytes [W]):

- **gameboy family** (single-op chip voices + LFSR): gb-pulse-50 /
  gb-pulse-25 / gb-pulse-12 (the duty leads), gb-wave-bass (the wave
  channel's soft triangle-ish bass), gb-arp (pulse + fast envelope),
  gb-noise-hat / gb-noise-snare / gb-noise-kick (LFSR, short-mode on
  the hat).
- **FM family** (the DX/OPN staples on 4 ops): fm-epiano, fm-bell,
  fm-bass, fm-pluck, fm-brass, fm-organ, fm-pad, fm-lead, and the FM
  drum kit: fm-kick, fm-snare, fm-tom, fm-hat.
- **the D147 vibe expansion**: orchestral/classical (fm-strings,
  fm-choir, fm-harp, fm-flute, fm-reed, fm-timpani, fm-orchhit,
  fm-harpsi, fm-musicbox), jazz/latin/funk (fm-nylon, fm-upright,
  fm-vibes, fm-muted, fm-clav, fm-slap, fm-cowbell), electronic
  (fm-sub, fm-reese, fm-ride, fm-shaker, fm-rim, fm-conga), and
  ambient/spooky (fm-drone, fm-glass).
- **sfx family**: sfx-jump/land/coin/hit/laser/dash/explosion/powerup.

`engine/stock/songs/` — 14 demo .song tracks (D147), one per common
vibe, smoke-testing the roster: desert-dunes, water-caverns,
noble-court (3/4), prelude-soft, battle-charge, boss-gate, dnb-rush,
breaks-alley, bossa-breeze, bossa-fiesta, funk-strut, noir-sleuth,
horror-hollow, ambient-drift. Track ins refs are engine-cwd-relative
so they play from any project; the stock-assets window (win-stock,
D147) opens copies into a project on demand.

The preset pass is a human listening session (the taste check) — the
PCM goldens pin them bit-exact once approved. t_stock_ins /
t_stock_songs pin decode/canonical-bytes/audibility for the whole
roster meanwhile.

## 12. Build order (R9a–R9e) + exits

Order rule: **R9a first** (the windows are built on the kit, not
migrated to it later), R9b before R9c/R9d (windows need ears),
R9c before R9d (the music window binds instruments).

- **R9a — the windowkit**: kit.asset factory + sprite/map/tmap/text
  migration, declarative hotkey tables + the shared hint bar (map's
  hints migrate), self-describing kind registration, cm.ed.chips,
  kit.viewlock. *Exit*: suite ALL GREEN with **zero behavior change**
  (existing tapes + selftests are the pin); a demo dummy kind registers
  from one file; EDITOR.md §13 written.
- **R9b — the PAL audio core**: SDL3 device + FIFO, the sim bank
  (4-op FM + waveforms + LFSR + sampler voices, fixed-point kernel,
  `snd.bank` named buffer), frame-locked command surface, the editor
  bank + immediate API, decoders (dr_wav/dr_mp3/stb_vorbis vendored),
  PCM-hash golden harness + first goldens. *Exit*: the command-ladder
  golden hashes identically across runs + linux/windows; a live smoke
  beep is audible; headless stays silent + goldens byte-identical;
  verify catches a deliberately-poked voice byte.
- **R9c — the sound windows**: cm.ins codec + the synth window (§9,
  audition piano + live patch send + preset strip) + the stock presets
  (§11), the sound player (§8) + kind_for's sound class routes, the
  →ins import door. *Exit*: drop an .mp3 → it plays; design a bell
  from init; the gb presets pass the human's ear; tape-proven
  undo/save/rebind; shots on llm-feed.
- **R9d — the music window + playback**: cm.song codec + flatten +
  cm.snd.seq, the music window (§10) on editor-bank preview, cm.snd
  game API + music-as-sim-state. *Exit*: compose an 8-bar loop from
  stock presets in the editor, ctrl+S, the game plays it; a recorded
  trace replays to the same PCM hash; the rewind pill scrubs across it
  and resumes mid-note; tape-proven roll grammar (add/delete/move/
  resize/velocity), shots on llm-feed.
- **R9e — the game hookup** (../cosmic2d-game): sfx wired at
  jump/land/flash-jump/slice/teleport + stardust/hit moments, a first
  rim_hub track, mix pass. *Exit*: the human plays with sound on and
  signs the feel.

## 13. Open questions (human) + revisit triggers

1. **Effects floor** — v1 ships dry (gain/pan only). A 3-knob
   Freeverb + a stereo delay are the proven minimum [W]; revisit when
   the first real track feels flat. (Both fit the fixed-point rule.)
2. **Swing + humanize** — cheap in the sequencer (tick offsets), out
   of v1; revisit at the first drum groove.
3. **Sample-PCM snapshot weight** — sim-bank sample buffers ride
   keyframes; if a sample-heavy game bloats the ring, add a
   static-buffer flag (content-hash instead of bytes in keyframes).
4. **Tracker-style step view** — the roll covers v1; a drum-grid view
   (paint-drag steps [W]) is a natural later addition to the same
   pattern data.
5. **Piano-roll CTRL inversion** (§10) — confirm the "CTRL = precise"
   reading feels right in the hand.
