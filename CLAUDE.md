# cosmic2d — agent orientation

Tiny 2D pixel-art engine / fantasy console: small C platform binary ("PAL") +
hot-reloadable Lua engine/editor/games, deterministic to the bit, batteries
included. You (the agent) are the primary developer.

**This repo is engine-only since revamp R0 (D045/D046)**: the flagship game
(**cosmic**) lives in **`../cosmic2d-game`** and experiments/demos in
**`../cosmic2d-demos`** — each with its own CLAUDE.md. Pre-split history:
branch `pre-revamp` (keep forever). The active roadmap is
**docs/REVAMP.md**.

## Session start — do this first

1. Read `docs/STATUS.md` (current state + exact next step).
2. `git log --oneline -10`.
3. llm-feed health: `curl -sf http://localhost:8777/healthz` → `ok`;
   if down: `cd /opt/src/llm-feed && nix run nixpkgs#python3 -- /opt/src/llm-feed/feed.py serve` (background, leave running).
4. Open PLAN/ARCHITECTURE/DECISIONS/PROCESS in `docs/` only as needed.

## Diagrams (teidraw)

When the human says "look at the/my diagram", it's a **teidraw board** in the
default windows-side save dir. Resolve it like this:

1. Boards home = `boardsDir` in
   `/mnt/c/Users/headpats/AppData/Roaming/teidraw/settings.json`
   (currently `F:\Documents\teidraw` → **`/mnt/f/Documents/teidraw/`**);
   each board is a folder (`board.json` + `assets/`). The board for this
   project is `cosmic2d` unless told otherwise; `recent` in that settings
   file shows what the human last worked on.
2. Export with the Linux CLI at `/opt/src/teidraw/build/teidraw`:
   ```sh
   teidraw <boardDir> --export-txt out.txt   # reading-order text — the bulk of the information
   teidraw <boardDir> --export out.png       # rendered board — for the drawn/spatial parts
   ```
   Read the text export first (positions + full text + arrows), then look at
   the PNG for anything drawn. Exports go in the scratchpad, not the repo.

## The docs (all in `docs/`)

- **STATUS.md** — living handoff; update at session/milestone end.
- **PLAN.md** — vision, pillars, milestone roadmap with exit criteria.
- **REVAMP.md** — **the active roadmap (D045)**: the teidraw-style
  infinite-canvas editor UX reboot, repo split, script-engine gate, rewind.
  Distilled from the human's `cosmic2d` teidraw board (the source of truth —
  re-export it when direction is unclear).
- **ARCHITECTURE.md** — two-layer design, state model, determinism iron
  rules, PAL API contract.
- **IMGUI.md** — the R2 design (D049): imgui hosted in the PAL, the
  drawlist+widgets script surface, window model, C/C++ layer rules.
- **EDITOR.md** — the R3+R4 design (D050/D051): the infinite-canvas editor
  shell — ALT grammar, the captured editor state domain (R6-ready),
  unsaved-persists + undo-forever journals, and §12 the windows (code ed /
  playable game / console / assets / sprite ed). The STUDIO.md successor.
- *(moved at R0)* GAME.md / STORY.md / maps → `../cosmic2d-game/docs/`;
  PROCART.md → `../cosmic2d-demos/docs/`.
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
bin/cosmic projects/smoke                                    # the minimal test room (M7 moveset)
bin/cosmic projects/smoke --headless --frames 120 --shot /tmp/s.png
bin/cosmic projects/igcanvas                                 # the imgui canvas (R2); headless: --win 1280x800 --frames 40 --shot
bin/cosmic projects/smoke --edit                             # the editor shell (R3/R4): canvas + windows (code/sprite/assets/console)
bin/cosmic ../cosmic2d-game/cosmic                           # the game (sibling repo; path is engine-root-relative)
nix run .#test                                               # goldens (selftest + traces + pixels)
```
