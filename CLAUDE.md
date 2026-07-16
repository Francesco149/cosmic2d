# cosmic3d — agent orientation

The **3D sibling of cosmic2d**: same two-layer architecture (small C PAL +
hot-reloadable deterministic Lua engine/editor), same batteries-included
philosophy, specialized for two aesthetics — **N64-era retro 3D** and
**Ragnarok-Online-style 2.5D** (3D terrain + billboard sprites). You (the
agent) are the primary developer.

**This repo is a git fork of `/opt/src/cosmic2d`** (remote `upstream`,
push-disabled — NEVER push to it; another agent works that repo). The fork
plan: diverge now, re-merge ergonomics after cosmic2d 1.0. Keep changes to
shared engine files surgical and additive where possible; new 3D docs/modules
go in NEW files so future merges stay clean.

## Session start — do this first

1. Read `docs/STATUS.md` (current state + exact next step).
2. `git log --oneline -10`.
3. llm-feed health: `curl -sf http://localhost:8777/healthz` → `ok`;
   if down: `nix run nixpkgs#python3 -- /opt/src/llm-feed/feed.py serve` (background, leave running).
4. Read `docs/COSMIC3D.md` (the 3D design doc) as needed; inherited cosmic2d
   docs (ARCHITECTURE/EDITOR/MAPS/AUDIO/DECISIONS/PROCESS) describe the shared
   engine and still bind.

## The 3D docs (new in this fork)

- **docs/COSMIC3D.md** — the design/scoping doc: renderer verdict (GPU retro
  pipeline), the two aesthetic presets, map model (splat-paint + bake), the
  rigid-part figure character model, mascot, demo roadmap, all human
  decisions with dates. **Read before proposing 3D designs.**
- **docs/DECISIONS3D.md** — append-only ADR log for fork-specific choices
  (shared docs/DECISIONS.md stays untouched for merge cleanliness).
- **docs/research-3d/** — the research reports: cosmic2d transplant map, N64
  aesthetic, RO 2.5D formats + editor UX, **ro-render-recipe.md** (exact
  lightmap/water/sprite math from roBrowser/BrowEdit3/Rebuild — the
  authoritative RO reference), CC0 assets, anime sprite licensing,
  Body Harvest/slopstudio techniques. Do not redo this research.
- **proto/** — the aesthetic prototype: deterministic software rasterizer +
  SDL_GPU retro-pipeline twin rendering identical scenes; 12 scenes cover
  every target look (see proto/README.md; money shots committed in
  proto/out/). This is the LOOK REFERENCE — the engine's 3D pipeline must
  reproduce it. `retro.vert/frag` are the working shader drafts.
- **assets/** — 230MB license-verified CC0/CC-BY packs (gitignored;
  assets/README.md documents contents + re-fetch; per-pack LICENSE-NOTE.txt
  inside). Kushnariova pack is CC-BY: attribution required if bundled.

## Iron rules (inherited from cosmic2d, all still bind)

- All project knowledge lives in the repo, never in private auto-memory.
- Commit in logical units as you go, direct to `main`. End each commit with a
  `Co-Authored-By` trailer naming **your own model slug** (e.g. an Anthropic
  agent uses its actual Claude model slug with `<noreply@anthropic.com>`).
- Determinism discipline in all sim code (docs/ARCHITECTURE.md): fixed
  timestep, engine PRNG only, no libm trig in sim paths, state only in named
  buffers / doc tree. **3D corollary: the sim never reads pixels; camera/
  presentation are render-class; terrain/entity state lives in named buffers.**
- Goldens run on pinned lavapipe only; a broken golden is a bug found.
- Visual changes: headless screenshot → look at it yourself → push to
  llm-feed with title+note. Human is the taste check, not the smoke test.
- Sessions are autonomous until human verification truly blocks; suggest
  `/clear` after a milestone is committed and STATUS is current.

## Quick commands

```sh
nix develop -c make -C pal                    # build bin/cosmic (2D engine, still green)
bin/cosmic projects/smoke                     # inherited smoke cartridge
nix run .#test                                # inherited goldens (keep green!)
# the look-reference prototype:
cd proto && nix shell nixpkgs#gcc -c gcc -O2 -std=gnu11 -w -o proto r3d.c main.c -lm
./proto ro2 out/ro2.png --soft                # see proto/README.md for all scenes
```

## Diagrams (teidraw)

Same protocol as cosmic2d (see upstream CLAUDE.md §Diagrams); the board for
this project is `cosmic3d` unless told otherwise.
