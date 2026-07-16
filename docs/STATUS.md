# status — living handoff

> Updated at session and milestone boundaries. Detailed July 2026 session
> history is archived verbatim in `history/STATUS-2026-07.md`.

## Current handoff — A2 application identity + A7 rewind foundation (2026-07-16)

The active release program is `ALPHA.md`; the original M-series in `PLAN.md`
and the R-series in `REVAMP.md` are historical context. The runtime, editor,
audio stack, two-room platformer demo, Linux build, and cross-built Windows
bundle are working, with the deterministic suite green at the last baseline.
The project remains an alpha candidate: durability, clean portable releases,
project/export UX, gamepad/player settings, broader genre proofs, and release
validation are still explicit gates.

**A7 rewind tray packet 1 is complete (D065).** Editor sessions now use a
persistent full-width four-lane tray instead of the R6 hover bar. Its live
camera follows up to ten minutes ending at live, reaches one-frame inspection
and full retained history, wheel-zooms at the cursor, middle-pans, and offers a
clear return to live. The ruler exposes current/live/retention markers,
storage/budget/segment facts, transport, resume-here, and bring-back. Click
seeks; a thresholded left drag creates an ordered inclusive A/B loop; and the
two-step Esc contract clears the clip before restoring the present. F4 cannot
bypass an active clip. The tray derives honest sim/editor activity and basic
input/code/eval/session markers read-only from resident FRAM/EDOC data; it
labels unavailable presented-frame previews instead of inventing thumbnails.

**The map/rewind split-state defect is closed (D066).** Every snapshot and
trace observation now crosses one generic engine-state lifecycle: registered
runtime facades flush authoritative data into ordinary captured buffers/docs,
and every restore rebuilds those facades afterward. `cm.map` uses that
contract to capture each stable map slot's path, canonical CMAP document,
collision bytes, and the active-slot selector. Restoring across a map switch
therefore restores the matching visuals, placements, markers, and collision
world together while preserving held map/world table identities. Bundled
multi-map level caches are revision-derived views of that captured state. A
focused A→B→mutated-B rewind regression proves both historical maps and direct
map-table edits restore coherently, including reconstruction without
`game.init`; the mechanism is reusable rather than a scrubber-specific map
exception.

**A2 packet 4 is complete.** A canonical 256 px cosmic2d mark now has a
documented multi-resolution Windows ICO (256 through 16 px). Both GUI and
console executables embed it plus Explorer `VERSIONINFO`; every copied editor
and named-game launcher inherits the same identity. Repository `VERSION` is
the single public package/resource string (`0.1-alpha`). Cross-package fixup
rejects a missing icon group, version resource/string, or wrong subsystem on
all four dev/editor entrances. Dev, public-editor, and renamed play artifacts
all pass; the play archive proves GUI editor/game plus CUI diagnostics retain
the resources. The Linux portable derivation still builds. `nix run .#test`
is ALL GREEN: 23,287 self-checks, every trace verify, and all pixel goldens.

**Exact next packet:** stay in A2 and define the platform-correct crash-log/
report location plus the stable project/history-stream/frame envelope D065's
crash-focused timeline will consume. After that, carry release notices and
checksums into artifacts with an explicit unsigned-alpha policy. A7's queued
implementation packet remains persisted multi-resolution activity/event
indexes and minute `THMB` samples, followed by project-file epochs; legacy
coverage must remain honestly labelled.

**A0 is complete.** The former 3,112-line STATUS diary is archived verbatim;
the live handoff and docs index are compact; active and historical roadmaps are
unambiguous; all local documentation/help links resolve; obsolete graybox help
is gone; and distribution plus persistent-undo claims match their current
pre-alpha guarantees. The shipped scripting page is now a task/API guide for
project lifecycle, deterministic state, input, rendering, maps/collision,
animation, and audio, with unsupported gamepad/query/export paths named.

**Proof:** implementation-signature and local-link checks pass. `nix run
.#test` is ALL GREEN: 23,287 self-checks, every trace verify, and all pixel
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

**A2 packet 1 is complete.** Dev/test, editor-release, and default-play trees
are now staged from explicit allowlist manifests. The public editor contains
only the picker and intentional `demo`; play exports contain the picker and
selected editable project. Both retain the engine/editor tooling, while the
named game launcher remains locked to play and a deliberate editor launcher is
available. A clean staging fixture proves `selftest`, `smoke`, `igcanvas`, and
`uigallery` cannot leak into either release shape and remain present in dev.
Linux and Windows dev/editor packages all build; `nix run .#test` is ALL GREEN:
23,264 self-checks, every trace verify, and all pixel goldens.

**A2 packet 2 is complete.** Linux editor and play trees now carry SDL3's
non-glibc runtime closure plus the Vulkan loader in `lib/`; every ELF resolves
through an `$ORIGIN`-relative RPATH and uses the standard x86_64 glibc loader,
with a build-time rejection for Nix-store RPATH/interpreter metadata. The
portable target builds its own SDL3 variant, restoring upstream Vulkan and X11
soname lookups instead of nixpkgs' absolute Nix-store `dlopen` substitutions.
The Linux packager consumes that portable tree and emits a 13 MiB demo tarball.
`tests/linux-portable-smoke.sh` extracts the archive as the only host input in
a stock Debian 13 container, verifies `ldd` resolves nothing from `/nix/store`,
makes the install tree read-only, and boots one headless frame under software
Vulkan/Xvfb with writable state confined to `/tmp`. Debian 13's Lavapipe
manifest is `lvp_icd.json`; using that clean-machine path completes the launch
with SDL's Vulkan GPU backend. The archive build, dependency checks, read-only
install check, and clean-container boot all pass.

**A2 packet 3 is complete.** The Windows object tree now links into two explicit
entrances: normal `cosmic.exe`, editor, and named-game launchers use the Windows
GUI subsystem and therefore do not create a terminal on double-click;
`bin/cosmic-console.exe` retains the console subsystem for diagnostics,
stdout/stderr, headless runs, and CI. Both dev and public-editor distributions
contain the pair, and Windows play packaging retains the console executable
while deriving its game/editor launchers from the GUI executable. Build-time PE
header checks reject either subsystem being wrong. The dev and editor cross
packages build, and a fresh demo Windows archive contains all three intended
entrances. `nix run .#test` is ALL GREEN: 23,264 self-checks, every trace
verify, and all pixel goldens.

**A2 packet 4 is complete.** The repository now carries one canonical cosmic2d
application mark as a 256 px PNG and a documented Windows ICO with 256, 128,
64, 48, 32, 24, and 16 px entries. `windres` binds the icon and English
`VERSIONINFO` into both GUI and console executables; copied editor/demo and
renamed play launchers retain it. A root `VERSION` supplies the shared
`0.1-alpha` derivation/resource string. Cross-build fixup rejects missing icon
group/version resources, incorrect strings, or subsystem regressions on every
staged entrance. Windows dev/editor builds, a fresh play archive inspection,
the Linux portable build, and `nix run .#test` all pass; the suite is ALL GREEN
at 23,287 self-checks with every trace and pixel golden matching.

**Exact next packet:** define and expose the crash-log/report location plus a
stable project/history-stream/frame envelope for D065; then carry release
notices and checksums into artifacts with an explicit unsigned-alpha policy.

There is no known blocker or human-only verification required.
