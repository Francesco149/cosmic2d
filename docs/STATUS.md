# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-27
**Phase**: **engine pivot — now building the flagship game, `cosmic`.** M0–M5
(engine) are complete. This session renamed the project to **cosmic2d**,
digested the human's full game vision into a design bible, re-sequenced the
roadmap, and **shipped M6 — the windows port** (cross-build + byte-exact
cross-platform determinism parity, agent-verified on the win11 host). No game
code changed yet — the stock cartridge is still the old M3/M4 platformer
sandbox.
**Next: M7 — movement overhaul** (D035, GAME.md §4): the MapleStory moveset.
**Pending human check**: run cosmic.exe *windowed* on the win11 desktop (a
visible window + feel) — the one M6 thing headless WSL interop can't verify.

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
  protagonist = **antagonist mecha girl**; **Windows-first** sequencing; all six
  GAME.md §11 design questions (→ D037).
- **M6 windows port shipped** (commit `6b39cf6`, D038): mingw cross-build +
  byte-exact cross-platform determinism parity, agent-verified on the win11
  host. Details in the M6 section below.

## What works right now (the engine, M0–M6)

**Runs on Windows** (M6): `nix build .#cosmic-windows` → `cosmic.exe`, byte-exact
state parity with linux.


Boot + live sessions + hot reload + crash parachute; the PAL draw/state/input/
trace stack; the determinism kit (fixed 60 Hz, engine PRNG, cm.math, named
buffers + canonical doc tree); snapshot/restore with code bundles (D012);
cm.ui/console/repl/perf; error containment (game errors pause, never kill);
cm.tilemap with one-way platforms; the platformer sandbox; the editor +
inspector + prop palette (everything edits via recorded EVALs); the M5 **time
machine** (always-on segment ring D032, F4 scrubber, rewind, `.ctrace` export,
replay playback); the suite under `nix flake check`. Detail: ARCHITECTURE.md +
DECISIONS D001–D032 + git history.

## M6 — windows port: DONE (agent-verified 2026-06-27, commit `6b39cf6`)

Cross-build via the flake's `packages.cosmic-windows` (`pkgsCross.mingwW64` +
nixpkgs cross SDL3 3.4.8 — pure Nix, no impure downloads; **D038**). The PAL is
pure SDL3, so the only C changes were `<SDL3/SDL_main.h>` (Windows entry) and
`fixup_cwd()` (self-locate via `SDL_GetBasePath` — **closes the cwd=repo-root
debt on both platforms**). Ships self-contained: `cosmic.exe` + `SDL3.dll` +
`libmcfgthread`. Verified on the win11 host via WSL interop:

- **selftest 22308 checks PASS** on `pal windows`;
- **cross-platform determinism parity is byte-exact** — linux records → windows
  `--verify` PASS, windows records → linux `--verify` PASS, and the two
  independently-recorded sandbox traces are **byte-identical**;
- the full Vulkan pipeline **renders headless on windows** (screenshot pushed
  to llm-feed).

Build it: `nix build .#cosmic-windows`; the `result/` tree is runnable on win11
(`cosmic.exe` beside `SDL3.dll` + `engine/`/`projects/`). **Pending the human**:
run it *windowed* on the desktop (visible window + feel).

## Next step (M7 — movement overhaul, D035 / GAME.md §4)

1. Read GAME.md §4 (the full spec) + D035 + D030 (the assists-as-cartridge-
   policy pattern it follows). It's **pure cartridge controller policy** —
   rewrite `projects/sandbox/player.lua`, no engine/PAL change.
2. Rip out the old controller (variable-height jump + air-dive). Build: walk,
   jump (fixed ~1 CH, auto-repeat), flash-jump (repeatable upright dash +
   sonic-boom ring), up-jump (vertical, locks out flash-jump), hop + flutter
   (once/airtime; hold E → 10 s hover → 10 s cooldown), grapple (pull to a
   platform above, prefers > ½ screen, 3 s cd, once/airtime), teleport (blink
   ~5 CW, kills momentum, persistent A↔B **phase-shift** mode, max 2/s),
   hold-to-slice continuous attack.
3. Every value a live knob under `doc.knobs.move` (D028). Calibrate CW/CH so
   6 CW ≈ ⅓ screen (CW ≈ 26 px — pick sprite size + zoom).
4. Re-choreograph the attract demo (D025) and **re-cut the golden suite** (new
   CTRC magic + new movement) — where the stale goldens finally get replaced.
5. Human feel sign-off, native on win11.

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
