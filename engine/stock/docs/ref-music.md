# The Music reference — every track, clip, note and control

This is the complete control-surface reference for the Music window. The
guided path is [the Music tutorial](engine/stock/docs/win-music.md); this page
is for when the tracker is open and you want the exact behavior under the
pointer.

## The window at a glance

The left **track rail** binds instruments and mixes tracks. The top-right
**transport row** controls preview, tempo, and placement grid. Beneath it, the
**arrangement** places patterns as clips on track lanes. The **scrub ruler**,
**piano keys**, and central **roll** edit the selected clip's pattern. The
bottom **velocity lane** edits note strength.

The editor has three levels:

- a **note** has pattern-relative tick, duration, MIDI pitch, and velocity;
- a **pattern** owns notes and a grow-only whole-bar length;
- a **clip** places one pattern on one track at a song tick and loops it to
  fill the clip length.

A track chooses the instrument, mute, volume, and pan. Plain clip creation
makes a fresh pattern, so nothing shares by accident. Ctrl-creation is the
explicit linked-reuse door: several clips may deliberately point at one
pattern and every edit then appears in all of them.

## Create, open and rebind

- Spawn **music** from the empty-canvas menu for an unbound window. Its path
  field starts under `sound/` with a unique three-word name. Enter a
  project-relative path and press Enter; `.song` is appended when omitted.
- A new path creates unsaved working bytes at 120 BPM: one track, one
  four-bar pattern, and one four-bar clip at song tick 0. The source does not
  exist on disk until Ctrl+S.
- If that path already exists on disk or in recovered working state, the
  prompt offers **open**, **overwrite**, and **cancel**. Open adopts it;
  overwrite deliberately starts fresh bytes; cancel returns to the field.
- Double-click a `.song` in Assets, find it with Ctrl+Space, drag it onto
  empty canvas, or drag it onto an existing Music window. The last form
  rebinds that window to the dropped song.
- Double-clicking a Stock song opens an unsaved project copy under `sound/`.
  Save it to adopt the copy; the engine's stock source remains unchanged.
- Multiple windows bound to one project path share one working document and
  undo journal. Their selected track/pattern, grid, cursor, arrangement
  height, pan, and zoom are window-local captured view state.
- An unreadable source shows `bad .song` and the decoder error. It is not
  partially adopted.

## Title bar and standard header

- The title is the source basename. Dirty working bytes add a trailing `*`
  and an amber dot.
- **reset** appears while dirty. It replaces working bytes with the saved
  source as a normal journal entry, so Ctrl+Z can undo the reset.
- **?** opens the Music tutorial. Music has no extra title-bar chips; play,
  tempo, and grid live in the content's transport row.
- The remaining title move, edge/corner resize, focus, close, and canvas
  selection gestures are shared editor chrome.

## Timing, grids, pitch and the address bay

Song time is integer ticks at **PPQ 96**: 96 ticks per beat. In the usual
four-beat bar, a bar is 384 ticks. Tempo is one global integer BPM. Notes use
MIDI pitch 0–127; the visible names follow `C4 = 60` and spell accidentals
with sharps.

The grid is placement snap, not note length:

    key 1   1/1    384 ticks    four beats
    key 2   1/2    192 ticks    two beats
    key 3   1/4     96 ticks    one beat
    key 4   1/8     48 ticks    half a beat
    key 5   1/16    24 ticks    quarter beat
    key 6   1/32    12 ticks    eighth beat

Changing grid affects where the next add, move, paste, and scrub cursor land.
It never rewrites existing notes and never changes the last-used placement
length. The current UI grid is captured in the editor session, not written
back to the CSNG HEAD grid byte.

While the pointer is over empty roll space, the transport's right bay reports
the destination ADD would use:

    bar 2 beat 1+48 · G4 · tick 432

The part after `+` is the within-beat tick remainder. Over a stored note, the
bay uses that note's real start and adds `dur` and `vel`. During a piano-key
press it reads `audition C5`. Very narrow windows hide this bay before letting
it overlap the transport chips.

## The track rail

Each row shows the saved track name and the bound instrument basename. A new
row is called `track N`; v1 has no track-name editing field, so imported names
remain whatever the CSNG contains.

- **click a row** — selects the track and drills the roll into its first clip.
  If the track has no clips, the click creates one fresh one-bar pattern and
  one bar-1 clip as a single undo entry. The roll therefore never edits an old
  track while auditioning the newly selected instrument.
- **instrument line** — `(drag an .ins here)` means unbound and silent.
  Otherwise it shows the final component of the project-relative source path.
- **mute dot** — toggles the track's authored mute flag. Muted tracks stay in
  the arrangement but editor and game sequencers skip their notes.
- **del** — available when more than one track exists. It removes that track
  and all clips on it, then reindexes the higher lanes. It cannot delete the
  last track. Patterns made unreachable by the deletion remain harmless
  source bytes in v1.
- **+ track** — appends a blank, centered, unity-gain track and selects it.
  No clip is created until the row is clicked or the arrangement is stamped.
  The UI limit is 16 tracks.

The rail itself does not scroll in v1. A tall window is needed to reach all
rows in a large song; the arrangement lanes have their own vertical scroll.

## Binding an instrument

Drag an `.ins` from Assets, Stock, or a Synth preset rail onto a track. While
the shell carry is live, the exact destination row gains an accent outline.
Release there to bind it as one journal entry.

- A path already under the project binds as-is.
- A Stock, engine-relative, or absolute source is copied atomically to
  `ins/<basename>.ins` first, then that project-relative path is stored. An
  existing local copy is reused. This keeps the song portable with its
  project.
- A release outside the track rail falls back to the selected track. Dropping
  on an arrangement lane does not target that lane separately.
- An unreadable source refuses the bind. A failed import preserves any
  previous copy, logs the error, and summons Console.
- Preview resolves the project path first and can also read an engine-relative
  source. Runtime resolves a direct path first, then relative to the project
  containing the song. Missing instruments leave their tracks silent.

## The selected track's mix panel

The selected row expands two controls. Each has a slider and an exact type-in
field; submit a typed value with Enter.

- **vol** — 0–255. `0` is exact silence, `128` preserves the instrument's
  authored gain, and `255` reaches the loudest encoded gain even for a quiet
  preset. The shared piecewise law travels 0 → preset → 255 without making a
  loud preset saturate halfway through the fader.
- **pan** — −64 hard left through `0` center to +64 hard right. This is an
  offset added to the instrument patch's own pan and clamped to the same
  range. The slider marks center and snaps values within two units to zero.

One slider press/release is one undo entry; one typed submit is one entry.
While preview or an audition is sounding, either control re-uploads the
affected track patch immediately. Editor preview and game playback use the
same gain/pan composition functions.

## The transport row

- **play / stop** — starts editor preview at the scrub cursor or releases the
  preview. It loops at `cm.song.length`, which is the farthest clip end with
  the saved loop end as a minimum.
- **bpm N** — each click adds 10 BPM; 200 wraps to 60. There is no typed BPM
  field in v1. A tempo edit is journaled and invalidates the flattened
  preview.
- **1/1 … 1/32** — each click advances through the six placement grids. Keys
  1–6 select them directly. Grid choice is view state, so it does not dirty
  the song.
- **pN · loop N bars** — permanently names the active pattern and its exact
  repeat period. Editor-authored patterns have a one-bar floor and whole-bar
  growth. This label is information, not a button.
- The free right side carries the roll address or held-key audition described
  above.

Space and the play/stop chip are the same **play/stop** action. Editor preview
uses the render-only editor sound bank; it never enters simulation history.
Edits rebuild the note flatten as needed, and mute/mix changes apply while it
plays. Closing the window or leaving the live editor releases every preview
and audition voice it owns.

## The arrangement strip

The strip is song time horizontally and one fixed-height lane per track
vertically. Clips are labelled `pN` with their pattern id. The active track
lane is tinted; the selected clip is bright; other clips sharing its pattern
glow together.

### Select and drill

Left-click a clip to select it, select its track, clear the previous note
selection, reset the scrub cursor to 0, and show that clip's pattern in the
roll. The press also arms move or edge-resize, so a motionless click only
drills while a drag edits.

If no roll notes are selected, **Del** removes the selected clip. It does not
delete the pattern bytes, because another linked clip may still use them.
Right-click has no arrangement action.

### Create clips

- **left-click empty lane space** — bar-snaps the destination, makes a fresh
  one-bar pattern, places a one-bar clip, selects it, and drills into it.
- **Ctrl+left-click empty space** — places the currently active pattern as a
  linked clip. Its fill length is that pattern's length rounded up to complete
  bars, with a one-bar minimum.

Plain creation is independent; Ctrl-creation is deliberate reuse.

### Move, resize and duplicate clips

- **drag a clip body** — moves it in whole-bar steps, never before tick 0.
- **drag the right edge** — resizes in whole-bar steps, minimum one bar. The
  edge brightens when the pointer is in its six-pixel grab zone.
- **Ctrl+drag a clip** — creates and moves a linked duplicate. Original and
  copy point at the same pattern; the duplicate commits even if released
  without motion.

A clip longer than its pattern loops the pattern. A clip shorter than the
pattern truncates notes at its right edge, including note duration at the
boundary. Overlapping clips on one track are both flattened; there is no
automatic override or monophonic arbitration.

### Arrangement view controls

The arrangement has a view separate from the roll:

- **wheel over the arrangement** — horizontal time zoom from 0.02 to 4
  screen pixels per tick, pinning the tick under the pointer;
- **middle-drag over it** — pans time and, when lanes overflow, scrolls
  vertically;
- **drag the centered bottom-edge handle** — resizes the panel from 24 to 240
  logical pixels tall.

Lane height remains fixed and a thin right scrollbar marks vertical position.
Arrangement zoom, origin, vertical scroll, and height are captured window
state, not song bytes.

## The scrub ruler

The band immediately above the roll shares the roll's horizontal tick view.
Whole-bar lines are numbered from 1. Click or drag to set the accent cursor,
snapped down to the active grid. The marker persists as window state.

Space starts preview at that absolute song tick, then wraps to 0 at the song
end. The moving white line is the live playhead. The ruler is visually
pattern-aligned but does not add the selected clip's arrangement offset; when
editing a clip that begins later, choose the absolute song bar where playback
should enter.

Ctrl+V no longer uses the ruler as a paste anchor. The current paste ghost
follows the pointer directly in pattern space.

## The piano-roll view

The roll shows the active pattern. Time runs left to right; pitch rises upward.
Vertical lines follow the current placement grid, with beat lines heavier.
Horizontal octave lines align with C. The accent line at the pattern end is
the length that clips loop.

A pattern starts at one or four bars depending on how it was created. A note
commit fits its content: if content crosses the end, length grows to the
smallest fitting whole bar. It never auto-shrinks after notes move or delete,
because a stable short pattern is the unit clips loop.

When the selected clip still has exactly the old pattern length, that clip
grows with the pattern so the new bar is immediately visible and audible. A
clip that was deliberately shortened or extended keeps its independent
authored length. Other linked placements also keep their own clip lengths.

The authoring floor is one complete bar. A one-beat phrase in an otherwise
empty four-beat pattern loops once per bar, leaving three beats of space; it
does not repeat on every beat. There is no sub-bar pattern-period control in
v1. Put repeated notes across the bar when that is the wanted rhythm.

### Focused view lock

A bound, focused Music window owns view input:

- **wheel over the arrangement** zooms the arrangement; wheel anywhere else
  in the window zooms roll time from 0.05 to 8 pixels per tick, pinning the
  pointer tick when possible and using the roll center otherwise;
- **middle-drag over the arrangement** pans that view; middle-drag elsewhere
  pans roll time and pitch on both axes;
- an unfocused window is inert, so the infinite editor canvas receives wheel
  and middle drag.

Click the title or a transport chip for a non-note focus door. Clicking empty
roll space focuses and immediately adds; clicking a note focuses and selects
it. Roll time origin, low pitch, and zoom survive restart and rewind as
captured window fields. Pitch rows keep fixed height; there is no vertical
zoom or fit command.

## Piano keys and pitch audition

The narrow left column is a playable keyboard aligned exactly to roll rows.
Black keys use the accidental shape; C rows carry octave labels.

- **left press** — auditions that pitch on the selected track's instrument;
- **hold** — keeps the note gate open until release, like the Synth piano;
- **drag while held** — glissandos row by row, releasing the old pitch through
  its short safety fuse and holding the new one;
- hovering either keys or roll highlights the matching key.

The audible hold follows the instrument envelope: a bass or lead can sustain,
while a deliberately short hat may decay almost immediately even though its
gate remains held. Key audition never creates a note. Missing instruments stay
silent, though the visual gesture still works. Playback itself does not light
keys in v1.

## Add, select and audition notes

### Add on empty space

Left-press empty roll space to add at the grid-snapped tick and pointer pitch.
The note gets velocity 100 and the last-used duration; before any resize, that
duration is one active-grid cell.

Holding the press keeps the audition gate open until release but does not grow
the stored note; audible sustain still follows the bound instrument's envelope.
Drag horizontally past the three-pixel threshold to set duration instead. The
right end uses ceiling snap, so it covers the cursor and has at least one grid
cell. A changed add length becomes the next placement default. The completed
add is one undo entry and becomes the only selection.

### Select and move

Left-press a note to select it. An unselected note replaces the old selection;
pressing one already selected keeps the set. A motionless hold auditions the
grabbed note for its whole duration under the hand and changes no bytes.

Drag from the same press to move the selection. Time moves by grid-sized
**deltas**, so an off-grid note keeps its offset instead of snapping to an
absolute line. Pitch moves in semitones and the held voice follows it. The
whole set uses one clamped delta, preserving intervals and preventing any
pitch from leaving 0–127.

Selected notes hit-test before overlapping unselected notes and draw last,
translucent with an outline. This makes an overlap visible and lets a drag
keep hold of the intended note.

### Resize

Hover a note's right four-pixel edge to reveal the bright handle, then drag.
For one selected note, duration snaps to the nearest grid multiple with a
one-cell minimum.

If several notes are selected, dragging a selected edge offsets every stored
duration by the grabbed note's delta, preserving their differences and
clamping at one tick. Hold Ctrl during the drag to set every selected note to
the same duration instead.

### Selection, duplicate and delete

- **Shift+click note** — toggles that note in the selection.
- **Shift+drag empty space** — marquee-adds every note rectangle the marquee
  touches.
- **Ctrl+drag note** — duplicates that note, or the whole selection when the
  grabbed note belongs to it, then moves the copies. Originals stay put and
  the grabbed duplicate auditions while held.
- **right-click note** — deletes only the note under the pointer.
- **Del** — deletes the note selection first; with no selected notes, deletes
  the selected arrangement clip.
- **Ctrl+Up / Ctrl+Down** — **octave**-steps the whole selection ±12
  semitones. If any note would cross 0 or 127, the entire step refuses.
- **Esc** — clears a note selection after first cancelling a paste.

Right-click is claimed by every bound Music window so it cannot open the
canvas menu. Away from a note, and outside an armed paste, it has no action.

## Clipboard and the paste ghost

**Ctrl+C** copies selected notes relative to the earliest selected tick.
Durations, pitch, and velocity survive. **Ctrl+X** copies, removes the notes,
and commits the cut as one edit.

The clipboard lives in the current editor session, so it crosses tracks,
patterns, assets, and separate song windows. It does not survive an editor
restart.

**Ctrl+V** arms, rather than immediately placing:

- the ghost's earliest note follows the pointer's grid-snapped tick;
- its anchor pitch follows the pointer row and the whole chord transposes by
  one clamped delta, so intervals never squash at MIDI limits;
- wheel and middle-pan remain live while armed;
- left-click in the roll places once, selects the pasted notes, commits one
  journal entry, and disarms;
- right-click or Esc cancels without changing bytes.

Paste is single-shot; it does not stay armed for repeated stamping. There is
no clip clipboard or arrangement paste in v1.

## The velocity lane

Each note has a narrow bar aligned to its start tick. Height is velocity
1–127; newly added notes use 100.

- **left-drag near a bar** — changes that note to the value under the pointer;
- **double-click a bar** — resets it to 100;
- with a note selection, dragging a selected bar offsets the entire selection
  by the grabbed note's delta, preserving relative dynamics and clamping;
- hold Ctrl during that group drag to set every selected note to one value.

The nearest start within eight screen pixels wins. A motionless first click
arms the 350 ms double-click clock; a drag never masquerades as that first
click. One finished velocity drag is one undo entry.

## Keys in one place

- `space` — **play/stop**
- `del` — **delete** selected notes, otherwise the selected clip
- `1`–`6` — choose 1/1 through 1/32 placement grid
- `ctrl+up / ctrl+down` — move the note selection one **octave**
- `ctrl+c / ctrl+x` — copy / cut selected notes
- `ctrl+v` — arm the one-shot paste ghost
- `ctrl+s` — save · `ctrl+z` — undo · `ctrl+y` or
  `ctrl+shift+z` — redo
- `Esc` — cancel paste, then clear selection, then stop preview, then continue
  through the editor's ordinary focus/canvas ladder
- `Ctrl+W` — close the window and release its preview voices

Text fields consume ordinary typing while active. Editor-reserved shortcuts
still win at the shell tier; Ctrl+C reaches Music through the kind's copy
door so it is not shadowed by the shell clipboard.

## Journal, save, recovery and rewind

Every instrument bind, mute, track add/delete, BPM click, clip create/move/
resize/duplicate, note add/move/resize/delete/paste, velocity drag, and mix
edit is journaled. One completed gesture is one entry. Track/clip selection,
grid, cursor, panel size, pan, and zoom are view state and do not dirty bytes.

- **ctrl+z / ctrl+y** walk a per-song journal capped at 512 snapshots.
- **ctrl+s** writes the `.song` as one atomic replacement. Failure preserves
  the previous source, keeps working bytes dirty, logs the reason, and opens
  Console.
- Unsaved working bytes and the journal survive ordinary window close and
  editor restart. Close is not discard.
- Saving invalidates the Assets browser so a newly created song appears
  immediately. An already running game keeps a path-keyed derived song cache
  in v1; restart that game session before judging a same-path resave.
- While rewind is parked in the past, edits are ephemeral and saving is
  walled. **bring back** is the explicit route to present, saveable work.

## CSNG v1 file contract

`.song` is the canonical CSNG chunk container:

    HEAD v1  u16 bpm, u8 beats_per_bar, u8 legacy grid,
             u32 loop0, u32 loop1
    TRKS v1  u8 count, then name, instrument path, u8 gain,
             i8 pan, u8 mute per track
    PATN v1  one chunk per pattern: u16 id, u32 length,
             u16 note count, then u32 tick, u32 duration,
             u8 pitch, u8 velocity per note
    ARRG v1  u16 clip count, then u8 track, u32 tick,
             u32 length, u16 pattern id per clip

Names and paths are length-prefixed one-byte strings. Canonical encoding sorts
pattern chunks by id, notes by tick then pitch, and clips by track then tick.
The editor writes complete replacement bytes; playback never mutates them.

Decode normalizes old or damaged structure:

- a round-6 TRKS v2 file with one pattern id per track migrates those ids into
  clips;
- a document with tracks but no clips gains one starter clip;
- a clip pointing at a missing pattern gets a fresh replacement;
- deliberate existing pattern sharing remains linked.

`fit_pattern` grows pattern length to whole bars but never shrinks.
`flatten` expands every clip into absolute song ticks, repeating its pattern
until the clip ends and clipping note tails at that boundary. `length` is at
least one bar and the saved `loop1`, then grows to the farthest clip edge.
The current editor does not expose `beats_per_bar`, `loop0`, `loop1`, or the
HEAD grid byte as controls.

## Runtime and data APIs

Game playback uses the same flattened notes, instrument bindings, mute, gain,
and pan:

    local snd = cm.require("cm.snd")

    snd.music(cm.main.args.project .. "/sound/theme.song")
    snd.music(path, { loop = false })
    snd.music_stop()

The default loops. `loop = false` stops and releases held notes at the song
end. Transport is stored in simulation state, so snapshots, traces, replay,
and rewind carry it. Tracks upload to simulation slots 32–47; the practical
runtime/UI ceiling is therefore 16.

For generated or inspected songs, `cm.song` exposes `fresh`, `normalize`,
`encode`, `decode`, `save`, `fit_pattern`, `flatten`, `length`, and `PPQ`.
Read bytes with `pal.read_file`, decode, edit the plain tables, and save or
atomically encode them. Hand-authored files reopen in this window.

## Deliberate v1 limits

There is one global tempo: no tempo map, swing, time-signature editor, or
automation. There are no effect racks, buses, sends, audio/MIDI recording,
note quantize command, probability, ratchets, chord brush, keyboard-entry
tracker mode, per-note pan, or per-note expression.

Tracks cannot be renamed or scrolled in the rail. Clips have no labels,
colors, unlink/private-copy button, fades, crossfades, slip editing, clipboard,
or right-click menu. Pattern garbage is not collected after every last clip is
deleted. The roll has no vertical zoom, playback-key lighting, or fit command.
Pattern periods cannot be shorter than one bar through the current editor. The
arrangement has no loop-region handles even though CSNG retains loop fields.
These are honest boundaries, not hidden shortcuts.

Full reference: [the hands-on Music tutorial](engine/stock/docs/win-music.md),
[every Synth control](engine/stock/docs/ref-synth.md), and
[sound and song APIs](engine/stock/docs/scripting.md#sound-effects-and-music-cmsnd-cmins).
