# rewind — R6 mechanics and the A7 product timeline (D053/D065)

> Sections 1–9 describe the **built R6 mechanics**: a disk-streamed ~1 GB
> state history of the WHOLE engine — sim *and* editor — browsable frame by
> frame, interactive but ephemeral (D046 §7b), with resume-from-frame and
> asset bring-back. Sections 10–16 specify the **A7 product surface**: the full
> timeline, A/B loops, standalone replay clips, and crash handoff requested on
> 2026-07-16. The editor tray and live-history interaction foundation are now
> built; the status note in §10 names the remaining packets. Binding ADRs:
> **D053** and **D065**.

## 1. What exists (and is kept verbatim)

- **The segment ring** (cm.trace, D032): every live session records
  itself — segments = a code-less keyframe + delta FRAMs (per-buffer
  `buf_delta1` + doc canon-on-change) + EVAL/EPOC, eagerly closed every
  `ring.kf` frames. `ring_state_at(f)` = read-only reconstruction (no
  re-sim); `rewind(f)` = write-back + truncate + the restore contract.
- **The park-and-render model** (cm.scrub): while parked the sim is
  frozen and the decoded state is written into the live buffers/doc —
  the game's own draw renders the past, because draw is pure over state
  (the iron rules). No special "replay renderer" exists or is needed.
- **One engine-state lifecycle** (cm.state, D066): modules with ergonomic Lua
  handles flush them into ordinary buffers/doc before every snapshot/ring/
  verify observation and rebuild derived wrappers after every table restore.
  Scrub and trace never call module-specific repair functions. Map slots use
  this for active identity, canonical placements/markers, and collision, so a
  room transition cannot leave past movement under present map art.
- **The captured editor domain** (D050): everything a rewound frame must
  show lives in `cm.ed.doc`, canon-clean; `ed.*` buffers reserved;
  mid-gesture state is ephemeral by contract.

R6 is those three ideas, finished: the ring learns the editor domain and
a disk budget; the park model learns to park the editor too; a pill UI
replaces F4 in editor sessions.

## 2. The editor stream (capture)

- **`EDOC v1`** — a new per-frame chunk in ring segments alongside FRAM:
  `u8 kind` (0 = unchanged, 1 = changed + `s4 canon bytes` of
  `cm.ed.doc`). Written by the recorder right after the frame's FRAM.
  cm.chunk readers are skip-tolerant by design, so **CTRC stays v1**:
  old traces load, exported traces carry EDOC harmlessly, and the
  verifier ignores it (editor state is not sim truth — goldens never
  see it, byte-identical by construction).
- **Cost gate**: `cm.ed.touch()` bumps a monotone `cm.ed.doc_rev`; the
  recorder canon-encodes the ed doc **only when the rev moved** since
  the last frame (idle editor = 1 byte/frame). Keyframes store the full
  ed canon next to `kf_bufs`/`kf_doct` so any segment reconstructs
  standalone.
- Sessions without the shell (`--edit` off, headless, verify) write
  kind 0 always — the stream degenerates to nothing.

## 3. Disk streaming + the budget

- Closed segments **spill to disk**: `<project>/.ed/history/seg_%06d`
  (one file per segment: keyframe + chunk bytes, the in-RAM shape
  serialized). RAM keeps the open segment plus a small decode LRU;
  `ring_state_at` transparently loads a spilled segment.
- **The budget replaces the seconds window**: `ring.budget_mb`
  (default 1024, console-tunable) — whole oldest segments (files) are
  evicted once total retained bytes exceed it. The 30 s RAM window
  survives as the *RAM* residency knob, not the history bound.
- History is **one continuous stream across sessions** (R6.5/D055 —
  the human asked; supersedes R6's per-session wipe): at boot, a live
  session **seeds the sim frame counter one past the retained history**
  (`hist_peek`, cm.main — before game.init, live windowed only) and
  `ring_start` **adopts** the on-disk chain as skeleton segments.
  Segments were standalone by construction (keyframes carry full
  buffers + doc + ed canon), so browsing/parking adopted frames is
  exact — including the editor doc, so **bring-back reaches previous
  sessions**. The session boundary shows as an honest state jump (a
  reboot happened).
  - **The manifest** (`history/index`, one appended line per spill:
    id/first/frames/bytes) makes adoption O(files) without reading the
    blobs; stale lines drop on an existence check, a re-spilled id
    dedupes last-wins, and the newest file — the only one a crash can
    half-write — is fully parsed (corrupt → deleted, scan retries).
  - **The stream marker** (`history/stream`, `CHST` / `STRM v1`) gives the
    retained generation an opaque `hs1-…` identity. Normal adoption preserves
    it; clearing history or forking away from its contiguous tail rotates it.
    `ring_locator()` and `hist_locator(project)` expose exact
    project/stream/committed-frame tuples for crash resolution. The marker is
    derived cache and clears with the segments it identifies.
  - **Contiguity is the adoption rule**: the chain must end exactly at
    the present frame (guaranteed at boot by the seed). A mid-session
    `ring_reset` (out-of-band restore) usually fits nothing — a forked
    timeline can't rejoin — and wipes, the old behavior.
  - **Resume into an adopted frame keeps the current code**: segment
    bundles were RAM-only references and are not spilled; browsing
    never needed them, and `rewind` logs the fallback. (`ring_export`
    likewise starts after adopted segments — a CTRC needs a bundle.)
  - **The quit path spills the open segment** (`ring_flush`, cm.main)
    so the session tail joins the stream, then drains the native writer before
    claiming an exact durable crash/history locator.
- Spill is an **observer of an observer**. Segment close (every `ring.kf`
  frames) only marks the decoded segment ready. The render/dev phase serializes
  it and queues one PAL API 13 transaction that atomically publishes the
  segment followed by its cumulative manifest on a bounded FIFO worker. The
  worker performs flush + OS sync; neither serialization nor file I/O runs in
  the measured sim interval. Pending segments remain authoritative in RAM and
  cannot be demoted/evicted until completion. Quit/crash, rewind truncation,
  replay replacement, explicit cache clear, and project/VM handoff are the
  deliberate wait barriers.

## 4. Browsing (interactive but ephemeral, D046 §7b)

Parking on frame f:

1. Freeze the sim (the scrub gate, unchanged) and **stash the present**:
   the live ed doc (`cm.ed.doc`) is set aside in a module-local; the
   ring goes dormant (already does under scrub).
2. Restore sim state (`state.restore_tables`, unchanged) **and the ed
   doc**: decode frame f's EDOC canon → `cm.ed.doc`. The shell keeps
   running its normal frame loop against it — so the parked editor is
   fully interactive: move windows, open/close, scroll, even type into
   working buffers. **All of it mutates the restored copy.**
3. **Suspension discipline while parked** (the §7b "ephemeral" half —
   the traps that would leak the past into the present):
   - the session autosave is OFF (`touch()` still bumps doc_rev for
     redraws but `save_due` never arms) — session.dat must keep the
     *present*;
   - journals never push (undo/redo walk in-memory only; `jpos` writes
     land in the restored copy and evaporate);
   - `Ctrl+S`/file writes are rejected with a log line (the one
     deliberate wall: writing files from the past IS bring-back, use
     the door);
   - the recorder ignores frames while parked (dormant ring, as today).
4. Scrub to another frame: re-run 2 — the poked copy is dropped on the
   floor. Close without resuming: the stashed present comes back,
   session autosave re-arms, play continues (scrub's existing contract).

**Resume from frame f** (door one): `trace.rewind(f)` truncates the sim
future (unchanged), and the **currently shown ed doc — pokes included —
becomes the present** (it's what you're looking at; adopting it is the
least surprising rule). Session autosave re-arms and immediately
persists it. `.ed/history` truncates with the ring.

**Game/editor switch while rewinding**: nothing to build — the game IS
a canvas window (R4); a parked frame shows it through the normal draw.
Scrub-play (the existing play-through-the-past) becomes "watch gameplay
back" with the editor chrome moving in sync, free.

## 5. Asset bring-back (door two)

The working state of every open asset is **inside** `cm.ed.doc.assets`
(D050/D051 — text and CSPR bytes alike), so a parked frame already
holds every open asset *as it was*. Bring-back, on the focused asset
window while parked: copy the parked working bytes into the **present**
doc's `assets[path]` (stash-side), journal-push it there (flagged, so
it's one undoable step in the present timeline), and mark the present
window dirty. Overwrites if the asset still exists, re-adds if it was
closed since — non-problems by construction, exactly as D046 predicted.
File-level epochs (assets never opened in any window) are out of scope:
the journals already cover every asset the editor ever touched.

## 6. The built R6 UI (the pill)

- The reserved top-right corner (D050 §3) gets the **rewind pill**:
  the retained span ("42 min") + a dot while recording. Hover (or `F4`
  in an editor session) expands the **top bar**: full-width timeline
  (segment ticks, the eviction edge), park/step/play controls, and two
  buttons that exist only while parked — **resume here** and **bring
  back** (enabled when an asset window is focused). Timeout-collapse
  like teidraw's video pill.
- Drawn on `x_ig_overlay`, shell-side (ephemeral state only; the pill
  is not editor *state*, it's chrome — a rewound frame does not show a
  rewound pill).
- Play-mode sessions (no shell) keep the legacy F4 scrubber unchanged;
  it still owns the non-editor story until it re-hosts someday.

This compact hover bar proved the park/reconstruct mechanics. A7 has now
replaced it in editor sessions with the persistent timeline tray in §10 while
retaining the pill as its collapsed entrance. Play-mode sessions still use the
legacy scrubber described above.

## 7. Determinism / goldens stance

Everything here is an observer: capture reads state after the fact,
EDOC is invisible to `--verify`, goldens pass explicit projects and
never open the shell, and parking never records. The one sim-visible
action is resume (`trace.rewind`), which already exists and already
carries the restore contract. No golden regenerates for R6 — pinned by
running the suite unchanged.

## 8. R6 module plan + build order (built)

- **R6a — the editor stream**: EDOC in ring segments + keyframes,
  doc_rev gating, ring_state_at returns `edoc`; KATs (rev gate, ring
  round-trip with ed changes, keyframe standalone-ness, verify ignores
  EDOC).
- **R6b — disk spill + budget**: segment files, decode LRU, budget
  eviction, boot wipe; KATs headless (spill/reload byte-parity, budget
  eviction order); a soak run (10+ min session, budget crossed).
- **R6c — park + ephemeral discipline**: cm.scrub grows the ed stash/
  restore + the suspension flags in cm.ed (autosave gate, journal gate,
  save wall); resume adopts the shown doc. Scripted proofs like R3/R4's
  (park → poke → scrub → poke gone; resume → poke kept).
- **R6d — the pill/bar UI** on the shell overlay; scrub-play with the
  editor in sync (the human's feel pass rides here).
- **R6e — bring-back** + the exit proof: scrub an hour-long session,
  watch gameplay back, pull an older sprite state into the present,
  poke a rewound frame and watch it evaporate.

## 9. Traps / watch list

- **The autosave leak** — one missed suspension and session.dat holds
  the past. The gate lives in ONE place (`touch()`/`save_now` honor a
  `parked` flag owned by cm.scrub) and R6c's proof includes a
  park-quit-relaunch (the present must come back).
- **Ephemeral plumbing vs restored docs** — g-side caches key by asset
  path (journals, decoded sprites, textures); a restored older doc can
  disagree with a cache (e.g. decoded sprite ≠ parked bytes). Rule: on
  park/scrub, drop `g.sw`/`g.tw` wholesale (they rebuild lazily from
  the restored doc — they were built for exactly this).
- **Segment memory doubling** — spill must actually FREE the RAM copy
  (the Lua strings go, the GC follows); watch ring_stats during the
  soak.
- **EDOC size** — a huge sprite in doc.assets canon-encodes per touch.
  The rev gate bounds frequency, not size; if soaks show pain, the
  escape hatch is delta-ing the ed canon like buffers (kind 2 = delta,
  format has room).
- **Replay files (current limitation)** — exported `.ctrace` with EDOC can
  replay the editor, but `ring_load` replaces the live ring and exiting adopts
  the replay. A7 must not build its viewer on that destructive path; §13 gives
  live history and foreign replay files separate immutable sources.
- **Project assets are the remaining file-epoch boundary** — D066 captures the
  loaded logical map runtime; textures, tilemaps, sounds, and other project-file
  versions still need A7's manifest/blob epochs (§14) for a standalone exact
  historical render. Do not mistake that planned asset layer for permission to
  leave mutable engine runtime on the Lua heap.

## 10. A7 surface: one real timeline tray

The rewind pill remains in the top-right corner, but clicking it (or `F4`)
opens a proper full-width timeline tray rather than a 58 px hover slider. It
stays open while the session is parked; it never disappears on a hover timeout
while the user is seeking, selecting, viewing a replay, or investigating a
crash.

The tray has four aligned lanes over one time axis:

1. **Preview filmstrip.** Capture a small thumbnail of the presented frame
   approximately every 60 seconds. The default ten-minute viewport therefore
   shows about ten useful landmarks. At wider zooms the renderer decimates
   samples to avoid overlap; it never manufactures a preview by re-running the
   sim. A thumbnail is navigation media, not state truth.
2. **Activity envelope.** Per-frame state activity is indexed when recording
   and drawn log-scaled. Each screen column uses the maximum in its frame bin,
   not the average, so a one-frame spike remains visible when zoomed out.
   Sim-state, editor-state, and project-file/asset changes use separate stacked
   colors; a tooltip gives exact changed-byte counts. This visualizes actual
   logical delta magnitude rather than total snapshot size.
3. **Event lane.** Code epochs, asset saves/imports, input transitions,
   restarts/session boundaries, contained errors, and crash boundaries get
   named markers. Large unexplained activity remains visible even without a
   marker — the activity lane is the honest fallback.
4. **Ruler and transport.** The playhead, live edge, retained/evicted edge,
   A/B handles, frame/time readout, play/step controls, storage use, and clip
   export live here. Panning away from the present exposes a clear “back to
   live” affordance rather than silently snapping the view.

Timeline navigation follows the editor grammar: **wheel zooms at the cursor**,
**middle-drag pans**, and the initial camera ends at live while showing roughly
ten minutes (or all retained history when shorter). Zoom reaches frame-level
inspection at the near end and the full retained stream at the far end.
Seeking remains bounded by the existing one-second segment keyframes and decode
LRU; preview/activity queries use indexes and must not decode frame state.

**Implementation status (2026-07-16).** The editor tray, camera, transport,
live-ring click seeking, inclusive A/B playback, and layered Esc/F4 persistence
are built. Until the segment indexes in §12 land, the activity/event lanes use
a read-only summary of already-resident FRAM/EDOC streams; they never reconstruct
state or load a demoted disk skeleton just to paint chrome, and uncovered older
history is labelled as missing. The preview lane explicitly reports that no
presented-frame samples exist. Persistent multi-resolution summaries, `THMB`
records, project-file epochs, full event coverage, immutable foreign/crash
sources, standalone packaging, and export remain later A7 packets.

## 11. Exact pointer grammar and persistence

- **Left click → seek.** A press/release that stays inside the normal drag
  threshold parks on that frame. Seeking never changes the timeline.
- **Left drag → select A/B.** Crossing the drag threshold creates an ordered,
  inclusive range regardless of drag direction. On release it immediately
  plays A→B and wraps to A until dismissed. Handles can refine either edge;
  dragging an empty point starts a new range.
- **Esc is deliberately layered.** With an A/B range active, the first Esc
  stops the loop and clears the range but leaves rewind open at the current
  frame. A second Esc closes rewind immediately and restores the stashed live
  present. F4, outside clicks, and pill collapse cannot bypass the first step.
- **A loaded replay is persistent.** Dropping a replay onto any editor view
  opens it, fits its exported interval, and activates its A/B loop. The first
  Esc clears that loop; the next exits the replay source, restores the untouched
  live source/present, and resumes recording. It never adopts the replay as the
  user's live future merely because the viewer closed.

“Clip mode” means an A/B selection is active. Playback, export controls, and
the timeline remain available, but the tray cannot be dismissed until Esc has
explicitly cleared the selection. Export progress likewise has an explicit
cancel/complete state; closing the tray cannot orphan a half-published file.

## 12. Activity and preview records

The recorder already sees every FRAM/EDOC delta. A7 adds observer-only summary
data to each segment:

- per frame: changed bytes for named sim buffers, sim doc, editor doc, and
  project files, plus event bits;
- multi-resolution max buckets in the segment index for cheap zoomed-out
  rendering;
- a `THMB` sample near each minute boundary, encoded after the compositor has
  produced the frame the user actually saw;
- optional frame-aligned audio blocks for replay/showcase playback. Legacy
  traces without them remain viewable and are labelled silent.

These records never enter named buffers or the sim doc and verification ignores
them. The disk budget counts segments, thumbnails, audio, and uniquely retained
project blobs. Evicting old segments reference-counts/garbage-collects blobs
that no retained frame can reach. Preview capture may skip a sample under load;
it may never stall or alter a sim step to hit an exact timestamp.

## 13. Timeline sources, not destructive ring replacement

The product UI reads an immutable **timeline source** interface: range,
`state_at`, activity buckets, events, previews, and `files_at`. There are three
source kinds:

- the live disk-backed history (recording is dormant only while parked);
- a foreign replay artifact;
- a crash focus, which resolves to either of the above plus a crash marker.

Opening a foreign source stashes the live present and live source object. It
does not call today's destructive `ring_load`, truncate history, or replace the
recorder's segment array. Closing restores exactly what was stashed. “Resume
here” remains available only for the live history source; foreign replay state
cannot accidentally become project state. Replay code has the same trust
boundary as opening a project and the UI must say so before executing an
untrusted bundle.

## 14. One logical history/replay format, self-contained clips

History remains a directory store and a replay remains one `.ctrace` file, but
they use the same logical records and segment decoder:

- FRAM/EDOC/EPOC/keyframes remain the state timeline and old golden traces stay
  readable;
- a content-addressed blob store holds project files without copying unchanged
  sprites/sounds/code into every segment;
- each standalone segment keyframe references a complete project manifest;
  file epochs update that manifest on editor saves/imports and observed external
  changes;
- a packed clip carries the complete manifest at A and every file version
  needed to materialize the complete project through B, plus the selected state
  segments, editor state, events, thumbnails, metadata, and any captured audio.
  In other words, it carries **all project source and assets**, not only
  currently open editor assets or the files draw happened to touch.

Physical packaging stays additive under the existing skip-tolerant CTRC chunk
container, so legacy `.ctrace` goldens remain dependency-bound but valid. New
UI exports are standalone. On load, their project tree is materialized/mounted
as an isolated replay workspace: the normal editor and asset browser can poke
around it, while the existing parked write wall keeps those experiments
ephemeral. Compatibility checks name the missing PAL/engine/schema capability
instead of failing as a generic bad trace.

The live history store uses the same manifests/blobs so **any retained range,
including an adopted previous-session range, is exportable**. This supersedes
R6.5's “adopted history has no bundle; keep current code / cannot export”
limitation. History recorded before the A7 manifest store is visibly marked
legacy and may be browsed, but cannot claim to produce a standalone exact clip.

An A/B export snapshots the exact state and project manifest at A, includes the
frames through inclusive B, and records the intended loop bounds as metadata.
Loading that artifact therefore opens on the same range and starts the same
loop without changing its contents.

## 15. Export UX

The **Export replay** button exists when A/B is selected. Its zero-config
destination is `replays/` beside the engine's `engine/` directory, created on
first use; the default filename includes project, wall-clock export time, and
clip duration. Publication is atomic. Only after success does the engine reveal
and select the file in Explorer/the platform file manager (falling back to
opening the folder). A read-only engine root produces an actionable choose-a-
writable-folder path rather than silently writing somewhere surprising.

The trace artifact is the recording/showcase master. Direct image sequence,
video, or separate audio exports come only after this artifact is stable; they
are consumers of the same A/B source, not a second editing timeline.

## 16. Crash reports as timeline entry points

A crash/error report has a small structured envelope in addition to readable
logs: project identity, history-stream identity, last fully committed frame,
the attempted next-frame input/evals when available, code epoch, error kind,
and traceback/log path. A contained Lua error flushes/pins a one-minute tail;
for a PAL/native failure, the next launch resolves the newest durable segment
(the open segment may be missing and the UI says exactly how much tail was
recovered). Reports may embed that tail or reference the local history; the
viewer prefers embedded data, then an exact local stream/frame match.

Dropping a crash report onto any editor view opens the resolved timeline, fits
up to 60 seconds ending at the last committed frame, marks the failed next-frame
boundary immediately after it, and starts the safe pre-roll as an A/B loop. The
normal Esc layering applies: first dismiss the loop, second dismiss the crash/
replay view. If the referenced history was evicted or belongs to another machine
and no tail is embedded, the UI reports that fact and the identities it tried —
it never guesses by timestamp.

The crash boundary is honest. A game step that throws may have partially
mutated live state, so history ends at the last committed frame and records the
failed attempt as an event; it does not bless partial state as a rewind frame.
From there the user can inspect, export the pre-roll, or explicitly resume the
last safe frame and retry.

**A2 foundation now built (D067).** PAL API v11 exposes one fixed SDL
per-user application-data root. Interactive processes keep a flushed
`process-<UTC>-<pid>.log` under its `diagnostics/` child, including Windows GUI
launches and read-only engine installs; capped/verify runs create no persistent
logs. A
contained error or Lua parachute atomically adds a `CCRP` `.ccrash` container.
Its `HEAD v1` is frozen as report ID, project path + display name, history
stream ID, last committed frame, attempted frame, code epoch, error kind, and
log path. Additive `TIME`, `META`, `ERRO`, `INPT`, `EVAL`, and `LOGS` chunks
carry display time, runtime versions, traceback, attempted input/evals, and a
portable recent-log copy. Empty stream / frame `-1` means unavailable rather
than guessed. Project path/name are discovery hints; the stream+frame pair is
the exact local match.

The contained-error path flushes the open segment before publishing and never
records the partially mutated throwing step. The later A7 packets still own
the one-minute pin/embed policy, native-failure next-launch synthesis, crash
timeline source, drop/view/loop UI, and graceful missing-tail explanation.
