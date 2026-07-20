# Changelog

High-level, user-facing history. The detailed, binding record is the ADR
log (`DECISIONS.md`, `DECISIONS3D.md`); session-by-session proofs live in
`STATUS.md` and `history/`.

## 0.1-alpha (release candidate — July 2026)

The first release: everything below is new.

### The console

- A small C platform binary ("PAL") hosting a hot-reloadable Lua engine,
  editor, and games — one folder, batteries included, Linux and Windows.
- Deterministic to the bit: fixed 60 Hz timestep, engine PRNG, no libm
  trig in sim code, recorded input as the only sim input. The golden
  suite (state traces + pixel goldens on pinned lavapipe + a ~25k-check
  engine selftest) verifies byte-exact replay cross-platform.
- Always-on disk-backed rewind: scrub, A/B loop, resume anywhere; a
  timeline tray with activity envelopes, previews, event markers, and a
  disk budget. Standalone replay clips (`.ctrace`) embed the project and
  open by drag-in on any machine, trust-gated; crash reports (`.ccrash`)
  embed their last minute and open the same way.
- Real distributions: portable Linux and Windows archives, clean-machine
  tested; in-editor export builds a player archive of any project.

### The editor

- An infinite canvas of floating windows: code (syntax-lit, undo journals
  that survive restarts), sprite + animation, map, tilemap, 3d map, mesh,
  figure, synth, music tracker, sound player, palette, assets, project
  settings/build, console, perf, settings, and a searchable in-engine
  documentation reader with a guided Getting Started.
- The sprite editor authors layered, animated sprites: brushes with
  size/shape/opacity, stamps, two-color paint, palettes, per-layer
  opacity and blend modes (mul/add/screen/overlay), and live
  non-destructive fills — four gradients plus six procedural fields
  (noise, fbm, ridged, cells, shards, facets) mapped through dithered
  color ramps, reseedable until baked.
- The 3D authoring suite: sculpt/paint `.terr` heightfield maps (with a
  position-keyed noise brush), model low-poly `.msh` meshes, rig `.fig`
  figures with pose clips and sprite-sheet bakes; live material textures
  with a published atlas the running game follows.
- Deterministic audio: FM/sampler synth in the PAL, instruments and a
  clip-arrangement tracker, stock presets including the gameboy family.
- Every asset window shares one contract: atomic transactional saves,
  undo journals, dirty marks, hot reload into the running game.
- The project assets browser copies a saved asset directly into another
  known project with collision refusal and staged rollback; sprite bakes and
  textured-terrain atlases travel with their editable source.

### Playing

- Project picker front door: create from five starter templates, import,
  duplicate, rename, archive, export — entirely through the shipped UI.
- SDL gamepads with hot-plug, full rebinding across keyboard and pads,
  deterministic pad recording; per-player atomic save storage.
- The player menu (F1) in every game: volumes, rebinding, window/
  fullscreen, and user-wide accessibility (reduced flash/shake, UI
  scale); keyboard-only and pad-only navigation throughout.
- Bundled demo matrix: side-view platformer, top-down cellar, arcade
  swarm — plus 3D demos riding the retro pipeline.

Known gaps for this release are listed in `KNOWN-LIMITATIONS.md`.
