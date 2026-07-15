# cosmic2d documentation map

Start with `STATUS.md` for the exact handoff and `ALPHA.md` for the active
release program. Documents are labeled here so an old milestone cannot be
mistaken for current work.

## Active

- `STATUS.md` — current state, proof, exact next session packet, blockers.
- `ALPHA.md` — release scope, genre/demo matrix, gates, order, session hygiene.
- `PROCESS.md` — build/test/visual verification and repository workflow.

## Contracts and current subsystem designs

- `ARCHITECTURE.md` — two-layer runtime, determinism, state, PAL contract.
- `EDITOR.md` — infinite-canvas shell, persisted editor domain, window model.
- `IMGUI.md` — hosted imgui/drawlist boundary and canvas primitives.
- `MAPS.md` — map/tilemap formats, collision model, map authoring UX.
- `AUDIO.md` — deterministic audio kernel, instruments, songs, editor windows.
- `REWIND.md` — disk-backed history mechanics and browsing semantics. The
  product UI/export work still to do is gate A7 in `ALPHA.md`.
- `DECISIONS.md` — append-only binding decisions and revisit triggers.

## Historical design context

- `history/STATUS-2026-07.md` — verbatim detailed session handoffs through the
  alpha-roadmap reset; use current `STATUS.md` for what to do next.
- `PLAN.md` — original vision and M-series build roadmap; pillars still matter.
- `REVAMP.md` — D045 UX reboot/R-series plan that produced the current editor.
- `STUDIO.md` — superseded full-window sprite-studio design; retained to explain
  existing asset-format/tool decisions. `EDITOR.md` is authoritative for UI.

## Shipped in-engine help

Player/author-facing documentation lives under `engine/stock/docs/`. It must
describe only shipped behavior and use links that the in-engine reader can
resolve. A0's scripting guide covers the supported small-project path and its
current limits; gate A8 expands this into the complete create-to-export guide
and exhaustive public API/task reference.
