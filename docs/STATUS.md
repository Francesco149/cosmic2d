# status — living handoff

> Updated at session and milestone boundaries. Detailed July 2026 session
> history is archived verbatim in `history/STATUS-2026-07.md`.

## Current handoff — A1 session metadata durable (2026-07-15)

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

**Exact next packet:** migrate editor journals to atomic checkpoint creation
and add last-known-good journal recovery without changing the existing append
stream or branching semantics. Cover interrupted/corrupt checkpoint recovery
and visible failures. Do not mix in multi-output sprite migration yet.

There is no known blocker or human-only verification required.
