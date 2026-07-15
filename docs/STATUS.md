# status — living handoff

> Updated at session and milestone boundaries. Detailed July 2026 session
> history is archived verbatim in `history/STATUS-2026-07.md`.

## Current handoff — A0 complete; begin A1 durability (2026-07-15)

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

**Exact next packet:** A1 atomic-write primitive plus failure KATs. Define the
same-directory temporary-file, flush/close, and rename contract at the PAL/Lua
persistence seam; prove that injected interruption/failure never replaces a
valid destination with partial bytes. Do not yet migrate every caller in the
same packet.

There is no known blocker or human-only verification required before A1.
