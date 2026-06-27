# cosmic2d — agent orientation

Tiny 2D pixel-art engine / fantasy console: small C platform binary ("PAL") +
hot-reloadable Lua engine/editor/games, deterministic to the bit, batteries
included. You (the agent) are the primary developer.

The engine now has a flagship game it is built around: **cosmic** — a cute /
cozy, occasionally cosmic-dread action-exploration game starring the
antagonist mecha girl of the `cosmic` universe (a spin-off / prequel).
MapleStory-style movement and self-contained maps + portals, power-fantasy
slice-through-hordes spectacle, and a Garry's-Mod-flavored physics sandbox.
The art targets a Wadanohara-like pixel style. See `docs/GAME.md`.

## Session start — do this first

1. Read `docs/STATUS.md` (current state + exact next step).
2. `git log --oneline -10`.
3. llm-feed health: `curl -sf http://localhost:8777/healthz` → `ok`;
   if down: `cd /opt/src/llm-feed && nix run nixpkgs#python3 -- /opt/src/llm-feed/feed.py serve` (background, leave running).
4. Open PLAN/ARCHITECTURE/DECISIONS/PROCESS in `docs/` only as needed.

## The docs (all in `docs/`)

- **STATUS.md** — living handoff; update at session/milestone end.
- **PLAN.md** — vision, pillars, milestone roadmap with exit criteria.
- **GAME.md** — the cosmic game design bible: identity, gameplay loop,
  movement spec, combat/spectacle, sandbox, art direction, story.
- **ARCHITECTURE.md** — two-layer design, state model, determinism iron
  rules, PAL API contract.
- **DECISIONS.md** — append-only ADR log; binding choices + revisit triggers.
- **PROCESS.md** — session protocol, commits, build/test/verify commands,
  llm-feed recipes, when to ask the human.

## Iron rules

- All project knowledge lives in the repo, never in private auto-memory.
- Commit in logical units as you go; trailer
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; direct to `main`.
- Determinism discipline in all sim code (ARCHITECTURE.md): fixed timestep,
  engine PRNG only, no libm trig, no hash-order dependence, state only in
  named buffers / doc tree.
- Goldens run on pinned lavapipe only; an unexpectedly broken golden is a bug
  found, not a golden to regenerate.
- Visual changes: headless screenshot → look at it yourself → push to
  llm-feed with title+note. Human is the taste check, not the smoke test.
- Sessions are autonomous until human verification truly blocks; suggest
  `/clear` after a milestone is committed and STATUS is current.

## Quick commands

```sh
nix develop -c make -C pal                                   # build bin/cosmic
bin/cosmic projects/sandbox                                  # run windowed
bin/cosmic projects/sandbox --headless --frames 120 --shot /tmp/s.png
nix run .#test                                               # goldens (M1+)
```
