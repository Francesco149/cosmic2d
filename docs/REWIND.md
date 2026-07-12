# rewind — the R6 design (D053)

> The REVAMP §3.3/§6 design doc for **R6 — rewind**, the flagship engine
> feature: a disk-streamed ~1 GB state history of the WHOLE engine —
> sim *and* editor — browsable frame by frame, interactive but ephemeral
> (D046 §7b), with resume-from-frame and asset bring-back. Extends the
> M5/D032 machinery (cm.trace's segment ring + cm.scrub's park-and-render
> model); the R3/R4 editor state model (D050/D051) was built so this doc
> could be written. Binding ADR: **D053**.

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
- History is **per-session**: `.ed/history/` is wiped at boot (a crashed
  session's leftovers too — the ring can't adopt foreign keyframes
  safely, and cross-session rewind is journals'/git's job, not R6's).
- Spill is an **observer of an observer**: writes happen at segment
  close (every `ring.kf` frames), off the sim path, plain `pal.write_file`
  — a stall shows in perf as render time, never in sim state.

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

## 6. The UI (the pill)

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

## 7. Determinism / goldens stance

Everything here is an observer: capture reads state after the fact,
EDOC is invisible to `--verify`, goldens pass explicit projects and
never open the shell, and parking never records. The one sim-visible
action is resume (`trace.rewind`), which already exists and already
carries the restore contract. No golden regenerates for R6 — pinned by
running the suite unchanged.

## 8. Module plan + build order

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
- **Replay files** — exported .ctrace with EDOC replays the editor too
  (nice); but ring_load of a foreign trace into a live editor session
  must stash exactly like parking does. R6c covers it or ring_load
  refuses under the shell (decide in build).
