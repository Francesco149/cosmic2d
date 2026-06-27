# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-28
**Phase**: **M7 — movement overhaul (the heart; D035 / GAME.md §4).** M0–M6
complete. The full MapleStory moveset is built as pure cartridge controller
policy (no PAL/engine change), the attract demo is re-choreographed, and
determinism is proven. **The human did a first live feel pass (win11): "feels
approximately right"** — feedback now applied (flash once/airtime, teleport
alternates fwd/back, flutter cooldown fixed, 1.5× airtime, a cooldown HUD).
**Final knob tuning + the golden re-cut wait for the real ART** (the human's
call — feel tweaks land with real sprites); the mechanics are otherwise done.
**Next: more feel passes as art arrives; the fancy slice VFX is deferred to the
editor/particle work; re-cut goldens once knobs lock.**

## This session (2026-06-27) — M7 moveset

The whole MapleStory moveset (GAME.md §4) now lives in the hub cartridge as
pure controller policy. Commits: `2a810a4` (controller + wiring), `69569c4`
(attract demo).

- **`projects/sandbox/player.lua`** rewritten: the old A-Hat-in-Time kit
  (variable-height jump, dive/boost/double-jump, crate grab) is gone; in its
  place — walk, jump (fixed ~1 CH, hold to auto-repeat), **flash jump** (repeat-
  able dash + sonic-boom ring), **up jump** (fixed vertical, once/airtime, locks
  out flash jump), **hop + flutter** (hop once/airtime; hold E hovers up to 10 s
  then arms a 10 s hop cd — a *1-frame TAP* never arms it), **grapple**
  (deterministic column scan for a standable top above, prefers past ½ screen,
  slow reel, once/airtime, 3 s cd, jump cancels), **teleport** (~5 CW blink,
  momentum dump, max 2/s, persistent A↔B phase mode that tints the sprite), and
  **hold-D slice** (slash stub; enemies at M12). New 128-byte buffer layout
  (pcall self-heals the old 96-byte one on reload). New 11-frame placeholder
  sprite + grapple beam + phase tint.
- **`main.lua`**: action map (hop=E, **grapple=q** — the spec's `` ` `` is the
  dev console, so q is the proxy), new ctl edges, retired dive/dj/throw knobs.
  **`level.lua`**: spawn lifted clear of the ground for any cw/ch.
- **`demo.lua`** re-choreographed: TOUR showreel + KITCHECK rule oracle, both
  byte-exact on `--verify`.
- **Determinism proven**: `selftest 22312 PASS`; record→verify byte-exact —
  TOUR 820 frames, KITCHECK 470 frames. No PAL/engine change (binary untouched).
- **Calibration**: every value is a live knob under `doc.knobs.move` (D028);
  `cw`/`ch` are the character box AND the CW/CH unit. Defaults are placeholders
  sized to the current 16 px-tile map at 1:1 — the absolute *6 CW ≈ ⅓ screen*
  anchor (CW≈26) needs M8 zoom + real art (a cw/ch/zoom knob change).
- **Montage** pushed to llm-feed ("M7 moveset — final demo tour").

### Feedback round 1 (2026-06-28, human win11 pass — "feels approximately right")

Applied (GAME.md §4 + D035 updated; selftest 22312 + record→verify both
timelines still byte-exact; montage "M7 moveset v2" on llm-feed):

- **Flash jump → once per airtime** (was infinite/repeatable): re-arms on
  landing. Verified via the fj flag (fires once, 2nd airborne press blocked,
  resets on land).
- **Teleport → alternates forward/back** (was forward only), tied to the A↔B
  phase flip: mode A fwd/solid, B back/phase.
- **Flutter "permanent cooldown" fixed**: it was the (correct) 10 s hop_cd being
  *invisible* + a real bug where a teleport re-armed it while a stale
  `flutter_t` lingered (now reset on flutter end). Mid-air hop works when off cd.
- **1.5× airtime, same heights**: `jump_apex_t` ×1.5; `upjump_v`/`hop_vy`/`fj_vy`
  ×2/3 (height ∝ v²/g).
- **Temporary cooldown HUD** (main.lua `draw_cd_hud`, live-play only): hop/
  grapple/tp bars + spent air-moves + phase mode — the requested cd viz.

Deferred per the human: the **fancy slice VFX** (orbiting energy blades + trail
particles) waits for the editor/particle-emitter work so it can be authored
live; final knob tuning waits for the real art.

### Feedback round 2 (2026-06-28)

GAME.md §4 + D035 updated; selftest 22312 + record→verify both timelines still
byte-exact; montage "M7 moveset v3" on llm-feed:

- **Flutter cd only on a real flutter** (was: any tap armed the 10 s cd). A
  `flutter_grace` (10 airborne frames) must pass before the hover — and thus the
  cd — engages; a normal tap is a clean hop. (Verified: `flutter_t` starts only
  after `hop_active`>grace, cd arms on land.) Also reconfirmed the teleport-
  re-arm bug fix.
- **Grapple extends → reels** (was: instant reel, short-range slingshot). The
  hook climbs to the target at `grapple_extend` (~1 screenful/s) under gravity;
  it reels only on connect, from your current velocity — so a jump-into-grapple
  has fallen to downward velocity (verified +70 px/s at connect) that the reel
  reverses first, damping the launch. Key fix: landing no longer cancels a
  grapple (the extend phase is grounded for a grapple-from-standing).

### Feedback round 3 (2026-06-28)

GAME.md §4 + D035 updated; selftest 22312 + record→verify both timelines:

- **Jump airtime ≈ ⅔ s** (apex_t 22.5→21.3; measured 0.65 s for a clean jump),
  height unchanged.
- **Up-jump & hop are height-based now** (`upjump_h`/`hop_h`): velocity derived
  from live gravity, so gravity retunes auto-preserve heights (no more ×k impulse
  recomputes).
- **Grapple launch dampened**: reel stops ~2 CH short of the platform
  (`grapple_stop_ch`) so the residual coasts under gravity; `grapple_min_t` keeps
  very-short grapples a small launch. The launch is really capped by
  `grapple_vmax` (coast ≈ vmax²/2g) — lowered 300→220, cutting a medium grapple's
  overshoot ~5.6 CH → **~2.5 CH** (accel 720 unchanged). **Grapple start zeroes
  horizontal momentum.**

## What works right now (the engine, M0–M6 + the M7 moveset)

**Runs on Windows** (M6): `nix build .#cosmic-windows` → `cosmic.exe`, byte-exact
state parity with linux.


Boot + live sessions + hot reload + crash parachute; the PAL draw/state/input/
trace stack; the determinism kit (fixed 60 Hz, engine PRNG, cm.math, named
buffers + canonical doc tree); snapshot/restore with code bundles (D012);
cm.ui/console/repl/perf; error containment (game errors pause, never kill);
cm.tilemap with one-way platforms; the editor + inspector + prop palette
(everything edits via recorded EVALs); the M5 **time machine** (always-on
segment ring D032, F4 scrubber, rewind, `.ctrace` export, replay playback); the
suite under `nix flake check`. Detail: ARCHITECTURE.md + DECISIONS D001–D032 +
git history.

**The M7 moveset** (this session): walk / jump / flash-jump / up-jump /
hop+flutter / grapple / teleport / hold-slice, all deterministic, every value a
live knob — pending the human's feel tuning. See the session note above.

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
(`cosmic.exe` beside `SDL3.dll` + `engine/`/`projects/`).

**Post-M6 windowed bug, FIXED** (commit `6209bbc`): the human's windowed run hit
a **key-stick** — `cm.input` was sampled only inside `sim_step`, so on a >60 Hz
monitor (vsync) the render loop's zero-sim-step ticks dropped their polled
events (a key-up landing there never cleared → stuck). Now `feed()` ingests
events **every tick**, `sample()` builds the record **per sim step**; headless
lockstep + trace determinism are byte-identical (selftest 22308→**22312** with
new regression cases; parity re-verified).

**Post-M6 perf fix** (commit `cae9024`): running from a WSL terminal showed
rhythmic frame spikes — the 4 Hz hot-reload poll stat'd ~30 module files inline
on the main thread, slow over 9p/drvfs. PAL gained a **background file-watcher
thread** (`pal.watch_mtime`, API 3→4); `cm.reload` reads cached mtimes, no
main-thread FS. Lazy-spawned (never in capped/verify runs → determinism
intact); parachute keeps its inline stat. Verified: selftest 22312, hot reload
still fires (linux), windows binary runs stably with the thread up.

Latest build (both fixes) deployed to `C:\temp\cosmic`. **Human-verified
2026-06-27**: windowed run is perfectly smooth — input releases cleanly, no
frame spikes from a WSL terminal.

## Next step (close M7)

1. **Human feel sign-off, native on win11** (the exit gate). Build the windows
   package (`nix build .#cosmic-windows`) or run the linux binary; play the
   moveset and tune `doc.knobs.move` live (F1 inspector / `` ` `` console). Keys:
   arrows · space=jump (hold=auto-repeat; airborne=flash, Up+space=up-jump) ·
   e=hop (hold=flutter) · **q=grapple** · r=teleport · d=slice. Save tuned
   knobs with `game.save_knobs()`.
2. **Re-cut the golden suite** (deferred until knobs lock — tuning invalidates
   any sandbox golden cut now). The committed traces are still old `.ptrace`
   (dormant; the suite globs `.ctrace`). Plan: **delete** the obsolete-mechanic
   traces (boostcap, boostlock, divecancel, djscale, jumpfeel, platformer_dive,
   platformer, platformer_locked, sandbox_ease, old kitcheck, sandbox); **re-cut
   as `.ctrace`** the engine-feature goldens that ride the sandbox (editpaint,
   inspectpoke, propspawn, mantle) + churn/evalfix (their own cartridges); **add**
   a fresh `kitcheck.ctrace` from `game.demo(2)`; **re-shoot** the pixel goldens
   (sandbox_idle, sandbox_tour). selftest 22312 is the live net meanwhile.
3. Then M7 is closed; suggest `/clear` → M8 (viewport/zoom, D036) which also
   delivers the CW≈26 absolute calibration.

## Known small items / debts

- **M7 feel knobs are placeholders** — `doc.knobs.move` defaults are agent
  guesses for the human to dial in (with the real art). cw/ch=12/18 fit the
  current map at 1:1; absolute screen-scale (CW≈26) is M8.
- **Slice VFX is a stub, deferred** — the fancy version (orbiting energy blades
  + trail particles) waits for the editor/particle-emitter work so it can be
  live-authored (human's call). The attack input + a placeholder slash exist.
- **Cooldown HUD is temporary** (main.lua `draw_cd_hud`, live-play only) — a
  testing aid; remove once the editor can visualize ability/emitter state.
- **Golden suite still stale, now also pre-sign-off** (D033): committed
  `.ptrace` are dormant; the M7 re-cut waits for locked knobs (next-step #2).
  selftest 22312 is the live net.
- **Grapple onto a SOLID platform from directly below bonks** (hit.up) — the
  two map balconies are STONE; grapple works through one-way planks (most of
  the map). The real hub (M-content) follows the one-way rule (GAME.md §4).
- **Grapple is on `q`, not the spec's `` ` ``** (the dev console owns backtick
  unless the project locks the editor). A shipped/locked build can bind grave.
- **Player grab/throw is gone** — E is hop now; the crate pit is inert physics.
  The sandbox grab/float/constrain "tool" returns with M-physics (GAME.md §7).
- `projects/sandbox/map.dat` is **untracked local state** that shadows the
  procedural map at boot (PROCESS warns for goldens); left as-is.
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
