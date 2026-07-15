# status — living handoff

> Updated at session and milestone boundaries. Detailed July 2026 session
> history is archived verbatim in `history/STATUS-2026-07.md`.

## Current handoff — A0 documentation reset (2026-07-15)

The active release program is `ALPHA.md`; the original M-series in `PLAN.md`
and the R-series in `REVAMP.md` are historical context. The runtime, editor,
audio stack, two-room platformer demo, Linux build, and cross-built Windows
bundle are working, with the deterministic suite green at the last baseline.
The project remains an alpha candidate: durability, clean portable releases,
project/export UX, gamepad/player settings, broader genre proofs, and release
validation are still explicit gates.

**Current packet:** finish A0. This session archived the former 3,112-line
STATUS diary without alteration and reduced this file to the live handoff. A
local-link audit passes; it also removed the retired tilemap graybox help and
made distribution and persistent-undo claims match their current, pre-alpha
guarantees. The exact next packet is rewriting the shipped scripting help as a
real public task/API guide, followed by an A0 exit review.

**Exit proof required:** every local documentation/help link resolves; shipped
help describes only current behavior; `ALPHA.md`'s A0 checklist and the docs
index agree; run `nix run .#test` before beginning A1 atomic persistence.

There is no known code blocker and no human-only verification required for A0.
