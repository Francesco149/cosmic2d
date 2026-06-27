# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-27
**Phase**: **engine pivot — now building the flagship game, `cosmic`.** M0–M5
(the engine: determinism kit, PAL stack, UI/console/inspector/editor, the
platformer sandbox, the M5 time machine) are complete. This session renamed the
project to **cosmic2d**, digested the human's full game vision into a design
bible, and re-sequenced the roadmap. No game code changed yet — the stock
cartridge is still the old M3/M4 platformer sandbox.
**Next: M6 — windows port** (the human's call: native feel-testing on the win11
host before the movement overhaul).

## This session (2026-06-27)

- **Total rename pettan2d → cosmic2d** (D033), committed `c9fbe72`: `cm.*` Lua
  namespace (`engine/cm/`, `cm` global, `cm_tick`), container magic
  **CTRC/CSNP**, trace ext **`.ctrace`**, `bin/cosmic`, env `COSMIC_LVP_ICD`.
  Verified: build clean, **selftest 22308 checks PASS**, record → verify
  round-trips on the new magic (exit 0), sandbox smoke shot renders.
- **Game design digested into the repo**:
  - **`docs/GAME.md`** (new) — the design bible: identity, fiction spine
    (proposal), the gameplay loop, the full movement spec (§4), combat/
    spectacle, hub, sandbox, exploration, areas/story, art direction + GPT
    ref-prompts, and the open questions.
  - **PLAN.md** — "What this is" reframed around the game; **roadmap
    re-sequenced** M6→M15 (windows → movement → viewport/editor-UX → audio →
    art tools → physics → combat → world → sandbox → shipping+content); new
    risks.
  - **DECISIONS** — D033 (rename), D034 (game identity: mecha-girl spin-off),
    D035 (movement = cartridge controller policy, supersedes D029 specifics),
    D036 (viewport: variable FOV + resize ladder + editor-only UI scale), D037
    (death/respawn + optional economy + navigation + verifiable stats).
  - **CLAUDE.md** — intro + docs list updated for the game and GAME.md.
- **Human decisions ratified**: total rename (incl. magic; goldens waived);
  protagonist = **antagonist mecha girl**; **Windows-first** sequencing.

## What works right now (the engine, M0–M5)

Boot + live sessions + hot reload + crash parachute; the PAL draw/state/input/
trace stack; the determinism kit (fixed 60 Hz, engine PRNG, cm.math, named
buffers + canonical doc tree); snapshot/restore with code bundles (D012);
cm.ui/console/repl/perf; error containment (game errors pause, never kill);
cm.tilemap with one-way platforms; the platformer sandbox; the editor +
inspector + prop palette (everything edits via recorded EVALs); the M5 **time
machine** (always-on segment ring D032, F4 scrubber, rewind, `.ctrace` export,
replay playback); the suite under `nix flake check`. Detail: ARCHITECTURE.md +
DECISIONS D001–D032 + git history.

## Next step (M6 — windows port)

1. Read PLAN M6, ARCHITECTURE ("two layers", PAL API table, Rendering), and the
   flake. The dev box is NixOS on WSL2 and can run both Linux and Windows
   binaries (D004).
2. mingw cross toolchain in `flake.nix`; cross-build the PAL against SDL3 for
   Windows; package `SDL3.dll`; run `cosmic.exe projects/sandbox` on the win11
   host via WSL interop. SDL_GPU/Vulkan backend (native dzn/RTX or lavapipe).
3. Fix the **"windowed needs cwd=repo-root"** debt as part of packaging
   (long-deferred to packaging).
4. **Parity proof, cheaply**: record a fresh `.ctrace` on Linux, `--verify` it
   on Windows (and vice versa) — state is pure CPU so it must be byte-exact.
   Do **not** re-bless the committed golden suite here; that re-cut belongs to
   M7 (new movement + real assets), so M6's throwaway parity traces aren't
   redone.

After M6: **M7 — movement overhaul** (D035, GAME.md §4) — rip out the old
controller, build the MapleStory moveset as live knobs, calibrate CW/CH, re-cut
the attract demo + goldens, human feel sign-off (native on win11).

## Known small items / debts

- **Golden suite is intentionally stale** (D033): committed `.ptrace` files
  carry the old PTRC magic *and* old-movement choreography; `nix run .#test`
  trace/pixel goldens are red until re-cut at M7. **selftest** (22308 checks,
  driver-independent) is the live net meanwhile.
- `projects/sandbox/map.dat` is **untracked local state** that shadows the
  procedural map at boot (PROCESS warns about it for goldens); left as-is.
- Confirm the rename *choices* `cm` (prefix) and `.ctrace` (ext) are
  acceptable — one sed to change now, frozen after 1.0 (D033).
- Carry-over M5/M4 debts still stand: console-eval rewind caveat, scrub previews
  with current draw code, bundle-mode-after-restore pauses disk reload, pinned
  recordings grow memory, inspector strings read-only / no add-delete, props can
  squeeze into a wall in pathological piles. (Full list was in the M5 STATUS in
  git history if one bites.)

## Design questions — RESOLVED 2026-06-27 (GAME.md §11, D037)

The human answered all six: fiction spine **ratified**; **earth + a cosmic
finale**, two hubs; **~3–5 hand-crafted bosses**; **full moveset from the
start**; teleport **phase-shift** modes (A solid / B phases); and a
**hub-respawn + optional-economy** model (currency/farmable drops, dual-sourced
abilities incl. radar + flutter-range, cheese consumables, world map + quest
arrow, no-rollback death, verifiable challenge stats). Captured in GAME.md §8/§11
and **D037**. Remaining opens are milestone-local (ability roster, boss roster,
HP/regen tuning) and don't block M6/M7.

(Always-open: art is human-authored; the agent designs map layouts + scenery
from primitives and writes story/quests once we reach M-content.)
