# status — living handoff

> Updated at session and milestone boundaries. Detailed July 2026 session
> history is archived verbatim in `history/STATUS-2026-07.md`.

## Current handoff — A1 durability complete (2026-07-16)

The active release program is `ALPHA.md`; the original M-series in `PLAN.md`
and the R-series in `REVAMP.md` are historical context. The runtime, editor,
audio stack, two-room platformer demo, Linux build, and cross-built Windows
bundle are working, with the deterministic suite green at the last baseline.
The project remains an alpha candidate: durability, clean portable releases,
project/export UX, gamepad/player settings, broader genre proofs, and release
validation are still explicit gates.

**A0 is complete.** The former 3,112-line STATUS diary is archived verbatim;
the live handoff and docs index are compact; active and historical roadmaps are
unambiguous; all local documentation/help links resolve; obsolete graybox help
is gone; and distribution plus persistent-undo claims match their current
pre-alpha guarantees. The shipped scripting page is now a task/API guide for
project lifecycle, deterministic state, input, rendering, maps/collision,
animation, and audio, with unsupported gamepad/query/export paths named.

**Proof:** implementation-signature and local-link checks pass. `nix run
.#test` is ALL GREEN: 23,106 self-checks, every trace verify, and all pixel
goldens.

**A1 packet 1 is complete.** PAL API v9 adds `pal.write_file_atomic`: a unique
same-directory temp is fully written, flushed, OS-synced, closed, and only then
atomically replaces the destination. It returns `true` or `nil,error`. Injected
failures at open, partial write, flush, sync, close, and rename each preserve a
known-good destination byte-for-byte and clean the temp; success and empty-file
replacement plus a natural missing-directory failure are also covered. Linux
and Windows builds compile; `nix run .#test` is ALL GREEN with 23,129
self-checks, every trace verify, and all pixel goldens.

**A1 packet 2 is complete.** Editor `session.dat` and engine-root
`.recent.dat` now use atomic replacement. Every successful editor save also
atomically maintains `session.dat.good`; corrupt live metadata restores that
copy, while double corruption starts fresh with an explicit recovery notice.
Session/recent write failures are logged and open the console rather than
silently continuing. Focused tests inject failures into the recovery and live
replacement steps, prove the previous files survive, cover single/double
corruption, and pin recents ordering. `nix run .#test` is ALL GREEN: 23,139
self-checks, every trace verify, and all pixel goldens.

**A1 packet 3 is complete.** Journal full rewrites now atomically publish both
`<asset>.jrn.good` and the live append stream; ordinary edits retain the cheap
single-chunk append path. A corrupt or missing live journal restores and
repairs the latest checkpoint. The session's newer working bytes then pass
through the existing adoption path, so current unsaved work survives even if
post-checkpoint undo steps do not. Checkpoint, live-publish, and recovery-write
failures are visible in the console. Injected-failure tests prove no partial
file becomes authoritative, corrupt/missing live recovery, valid-checkpoint
adoption after a failed repair, and safe fresh fallback after double
corruption. The A1 last-known-good session/journal roadmap item is proven
complete. `nix run .#test` is ALL GREEN: 23,145 self-checks, every trace
verify, and all pixel goldens.

**A1 packet 4 is complete.** Sprite saves now encode the full `.spr` plus
`.png`/`.anim`/`.meta` generation before publication, durably record it in an
atomic `.spr.txn` recovery manifest, atomically publish runtime outputs then
source, and only then clear the manifest and claim success. Load and the next
save finish interrupted generations idempotently. PAL API v10 adds in-memory
`png_encode`; empty clip tables now replace stale `.anim` files. Named errors
flow through the editor save console while dirty bytes remain. Injected tests
cover manifest creation, all four output boundaries, manifest cleanup, and
matching recovery. `nix run .#test` is ALL GREEN: 23,176 self-checks, every
trace verify, and all pixel goldens. Linux and cross-built Windows packages
both compile.

**A1 packet 5 is complete.** `.ed/owner.dat` (`CEDO` schema 1) now records
that the directory is engine-owned but not wholly disposable: session and
journal files are working recovery that may contain the only copy of unsaved
work, while rewind history is derived cache. Missing markers adopt the legacy
layout. Corrupt markers rebuild only history and report recovery; foreign or
newer markers preserve everything and refuse the older editor. The explicit
`cm.ed.clear_cache()` operation opts into a derived-history rebuild without
ever deleting session/journals. Ownership is checked before boot reads rewind
history. Focused tests cover legacy, corrupt, newer, explicit-clear, and
marker-publication failure paths. `nix run .#test` is ALL GREEN: 23,185
self-checks, every trace verify, and all pixel goldens.

The export contract is now explicit in `ALPHA.md`: shipped games include the
engine, editor/tooling, source project, and assets for curious players. The
normal named launcher remains locked directly to play mode via D052; “play
only” describes that default entrance, not a stripped artifact.

**A1 packet 6 is complete.** `.map` source saves now use the PAL atomic-write
primitive through a map-specific save API and the real map-window write hook.
An injected replacement failure preserves the previous valid map byte-for-byte,
keeps the newer working document dirty, reports the named failure, and summons
the editor console; a retry publishes a complete decodable generation. `nix
run .#test` is ALL GREEN: 23,191 self-checks, every trace verify, and all pixel
goldens.

**A1 packet 7 is complete.** `.tm` source saves now use the PAL atomic-write
primitive through a tilemap-specific save API and the real tilemap-window write
hook. An injected replacement failure preserves the previous valid tilemap
byte-for-byte, keeps the newer working document dirty, reports the named
failure, and summons the editor console; retry publishes a complete decodable
generation and clears dirty state. `nix run .#test` is ALL GREEN: 23,198
self-checks, every trace verify, and all pixel goldens.

**A1 packet 8 is complete.** `.pal` source saves now use the PAL atomic-write
primitive through a palette-specific save API and the real palette-window write
hook. An injected replacement failure preserves the previous valid palette
byte-for-byte, keeps the newer working document dirty, emits the named palette
failure, and summons the editor console; retry publishes a complete decodable
generation and clears dirty state. `nix run .#test` is ALL GREEN: 23,205
self-checks, every trace verify, and all pixel goldens.

**A1 packet 9 is complete.** `.ins` source saves now use the PAL atomic-write
primitive through an instrument-specific save API and the real synth-window
write hook. An injected replacement failure preserves the previous valid CINS
source byte-for-byte, including its embedded-PCM contract, keeps the newer
working instrument dirty, emits the named instrument failure, and summons the
editor console; retry publishes a complete decodable generation and clears
dirty state. `nix run .#test` is ALL GREEN: 23,212 self-checks, every trace
verify, and all pixel goldens.

**A1 packet 10 is complete.** `.song` source saves now use the PAL atomic-write
primitive through a song-specific save API and the real music-window write
hook. An injected replacement failure preserves the previous valid CSNG
arrangement byte-for-byte, keeps the newer working song dirty, emits the named
song failure, and summons the editor console; retry publishes a complete
decodable generation and clears dirty state. `nix run .#test` is ALL GREEN:
23,219 self-checks, every trace verify, and all pixel goldens.

**A1 packet 11 is complete.** Code/text-window source saves (`.lua`, `.md`,
`.txt`, `.json`, `.glsl`) now use atomic replacement. Injected rename failures
for every routed extension preserve the previous file byte-for-byte, keep the
newer working text dirty, emit the named path and failure, and summon the
console; retry publishes the complete source and clears dirty state. `nix run
.#test` is ALL GREEN: 23,239 self-checks, every trace verify, and all pixel
goldens.

**A1 packet 12 is complete.** Editor-created and imported assets now publish
with atomic replacement: raw and converted OS drops, map graybox `.tm`
generation, stock-instrument copies bound into songs, and sound-to-sampler
`.ins` creation. Image conversion encodes to memory before publication.
Failures name the target and cause, summon the console, publish no partial new
asset, preserve any previous valid generation, and leave map state unchanged
when its generated tilemap cannot be committed. Focused injected rename
failures cover all four paths. `nix run .#test` is ALL GREEN: 23,247
self-checks, every trace verify, and all pixel goldens.

**A1 packet 13 is complete.** `.ctrace` exports, rewind-history segment
containers, append-equivalent history index updates, and adoption-time index
compaction now use atomic replacement. A segment becomes authoritative only
after both its container and index entry are durable; an index failure removes
the unreachable orphan, retains the RAM generation, and disables further
spilling for the session. Errors include paths and causes. Injected failures
prove an interrupted trace export preserves its previous valid file, segment
failure publishes nothing, and index failure preserves the prior manifest;
corrupt indexed tails are rejected and removed. `nix run .#test` is ALL GREEN:
23,251 self-checks, every trace verify, and all pixel goldens.

**A1 packet 14 is complete.** Machine-local viewport/options `video.dat` and
explicit runtime snapshot saves now use atomic replacement and return named
errors. Video-setting failures are logged with their path and cause; snapshot
callers receive a `write snapshot failed` error suitable for their UI. Injected
rename failures prove both paths preserve the previous valid generation and a
retry publishes complete canonical settings/snapshot bytes. The persistence
audit found only intentional journal appends, explicit screenshot output,
compatibility sidecar helpers, and the current picker's project-creation paths
outside the atomic primitive. `nix run .#test` is ALL GREEN: 23,255
self-checks, every trace verify, and all pixel goldens.

**A1 packet 15 is complete, closing A1.** Standalone `.anim` and `.meta`
compatibility sidecar helpers now replace atomically and return errors naming
their target. Picker recents pruning uses the shared atomic recents API.
Project scaffolding moved to `cm.project`: it atomically publishes `main.lua`
first and the discoverability/authority file `project.lua` last, rolling back
all earlier output on either failure and never launching a partial project.
Injected rename failures prove prior sidecars and recents survive byte-for-byte,
both scaffold boundaries leave no partial project, and retries publish complete
decodable/discoverable results. The final write-site audit leaves only designed
journal appends, explicit user-requested screenshots, test/bootstrap fixture
writes, and player storage reserved for A4. `nix run .#test` is ALL GREEN:
23,264 self-checks, every trace verify, and all pixel goldens.

**Exact next packet:** begin A2 with a dev/test, editor-release, and
default-play manifest split plus a clean picker fixture. Prove release manifests
exclude `selftest`, `smoke`, `igcanvas`, and `uigallery` while retaining the
intentional bundled demos and editable engine/tooling contract.

There is no known blocker or human-only verification required.
