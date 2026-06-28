# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-28
**Phase**: **M8 — viewport & editor UX (D036): FEATURE-COMPLETE** (pending the
golden re-cut, which is deferred — see below). The whole D036 model ships:
variable-FOV two-target composite (editor chrome at its own scale **around** the
game viewport), the resize ladder, alt+enter borderless fullscreen (**human-
approved**), and the **options menu** (Esc) to set resolution/scale/fullscreen
directly, **now persisted across launches** (video.dat). Layout approved ("it
looks correct yes"); three feel passes applied (round 3: **Esc opens the options
menu instead of quitting**, + a menu quit button + persistence). M8 is covered
by **selftest 22312→22351** (+39: viewport/composite/ladder/mouse-split/capture);
determinism byte-exact; both linux + windows builds clean. M7
movement remains FEEL-APPROVED; its deferred items (CW≈26 scale, slice VFX) wait
on real assets.
**Done this session (M8.1–M8.6 + capture, all on `main`, selftest 22312→22351,
determinism byte-exact, uigallery golden byte-identical, goldens else unaffected):**
- **M8.1** `ea7dc9a` — PAL **api 4→5**: `pal.x_fov(w,h)` (the variable game FOV =
  resizable internal target), `pal.x_window_size()`, `x_set_window_size`/
  `x_set_fullscreen` (options menu). Additive `x_*` (experimental ns).
- **M8.2** `f11ab36` — PAL **two-target composite**: `pal.x_ui_target` (a second
  editor/UI canvas), `pal.x_target("game"|"ui")` routing, `pal.x_compose{…}`
  (game→sub-rect at integer scale, ui→whole window at its own scale, alpha-over).
  Mouse events carry BOTH game-space `x,y` (sim, unchanged) + ui-canvas `ui_x,
  ui_y` (editor chrome). present() factored into scene_pass + blit_layer.
- **M8.3** `758dd40` — `cm.view`: the D036 resize **ladder** (scale =
  max(2,min(⌊W/480⌋,⌊H/270⌋)); FOV = min(480,⌊W/scale⌋)×min(270,⌊H/scale⌋)),
  live only (headless/verify keep the fixed FOV). Game fills the window at a
  variable FOV in play mode.
- **M8.4** `6c07b6a` — editor + dev UI on the **ui canvas** at its own scale
  (`cfg.ui_scale`, default **2×** — see knob note); the game becomes an **inset
  viewport** (window minus the toolbar/inspector) at its own integer scale. The
  mouse splits: `inp.gx/gy` game-space (world placement), `inp.mx/my` ui-canvas
  (panel hit-test). console/scrub/perf re-homed via `view.surface_size()`.
- **Capture** `11cbc23` — `pal.x_capture(w,h)` / `x_capture_read()` + engine
  `--win WxH`: composite into an offscreen target so a headless `--shot` shows
  the editor-around-game layout (only the swapchain has it otherwise). This is
  how the layout was self-verified + pushed to llm-feed. **Also fixes** the
  "graphics pipeline not bound" SIGILL the human saw: `pipe_blit` was only built
  for a window; now built unconditionally (UNORM format headless). Live path
  unchanged. `t_capture` guards the composite layering + the headless blit pipe.
  Capture a view: `bin/cosmic projects/sandbox --win 1920x1080 --frames 30 \
  --shot /tmp/e.png --eval "cm.editor.toggle(true)"`.
- **Docs**: **D039** (the two-target composite realizing D036) + the
  **ARCHITECTURE api v5 table**.

### M8 feedback round 1 (2026-06-28, win11) — `bf58389`
Layout approved. Applied: **fill-the-window ladder** — a maximized window was
letterboxing the game in black bars (the old min-of-floors + 480×270 cap); now
the scale is chosen to keep the FOV near the reference and the FOV fills the
window at that scale (1920×1040 → 480×260@4×; the editor inset sits snug, no
margins). **alt+enter** toggles borderless fullscreen (`pal.x_set_fullscreen`).
selftest 22349; verified by `--win` capture (maximized play fills edge-to-edge;
editor inset fills the central rect) on llm-feed. **Still open**: confirm
`cfg.ui_scale` (2× readable vs D036's literal 1×) on win11; test the alt+enter
toggle natively (headless can't).

### M8 feedback round 2 (2026-06-28, win11) — `02d55c4`, `2ea0973`
Fullscreen **approved**. Fixed "parallax bleeds through the bottom in fullscreen
editor mode": a FOV taller/wider than the 480×270 design renders past the sim
camera's clamp (the sim can't read the live FOV — determinism), revealing
undesigned world. Also latent in play mode (1280×720→640×360 bled). Fix —
**unified ladder** (supersedes round-1's fill): `scale = max(base, ⌊W/ref_w⌋,
⌊H/ref_h⌋)` (max-of-fits, so maximize still FILLS) **+ FOV hard-capped at the
reference** (so the render never exceeds the design → never bleeds). Net: fills
on whole-multiple windows (incl. maximized 16:9 → 480×260), thin letterbox /
editor margins otherwise; no bleed in play or editor. **M8.6 options menu**
(`cm.options`, Esc): fullscreen toggle, windowed presets (960×540…1920×1080),
ui-scale 1×/2×/3× — sets res directly when you can't drag-resize. **M8.5**:
api5 table extended (x_capture); nested-subdir module load + deep hot-reload
verified (the loader watch_adds every required file, dotted names → nested
paths).

### M8 feedback round 3 (2026-06-28) — `ff1e234`, `929d0e6`
The human couldn't reach the options menu: Esc still **quit** the game. The
sandbox bound Esc→`pal.quit()` in `game.step()`, firing alongside `cm.options`'
own Esc toggle and killing the game before the menu opened. **Fixed** — Esc is
now engine-reserved for the options menu (like ` for the console); the sandbox
no longer binds or acts on it. That removed the only keyboard quit, and
borderless fullscreen has no window-close button, so the options menu gained a
red **"quit game"** button; it and the window-close (X) now share one
`cm.main.request_quit()` (a game's `on_quit` hook fires from either). The menu
also captures the keyboard while open (mirroring the mouse capture) so the
player doesn't run around behind it. **Options persistence** (the deferred
follow-up) also landed: resolution / ui-scale / fullscreen save to
`<project>/video.dat` (`cm.view.save_video`/`load_video`, canonical bytes like
knobs.dat) and apply before the first frame — interactive sessions only, so
headless/`--frames`/`--verify`/`--win` keep the fixed FOV (goldens + determinism
byte-stable; gitignored). selftest 22351; sandbox record→verify byte-exact
(300f); save/load round-trip + menu render verified headless. The **interactive
behaviors** (Esc opens not quits; settings persist across a real relaunch) are
the human's native pass — headless has no window events. (The human's own
test-session video.dat — ui_scale=1, fullscreen — was observed on disk, which
*proves* persistence works end-to-end; I reset it during testing, so the next
launch starts from defaults.)

### M8/M7 feedback round 4 (2026-06-28) — `3894779`, `429530d`, `f890256`
Three asks from the human's first real play:
- **Window presets now FILL the window** (options menu): 720×540, 960×540,
  1440×1080, 1920×1080 (a 4:3 + a 16:9 at two heights) — each a whole multiple of
  a FOV ≤ the 480×270 reference, so the ladder fills with no letterbox (was the
  old 16:9-only set that letterboxed at e.g. 1280×720). See cm.view.ladder.
- **ui_scale applies in PLAY mode too** (D039 revision): the dev chrome (options
  menu / console / perf / scrub) now ALWAYS rides a ui canvas at `cfg.ui_scale` —
  cm.view.update allocates it in play as well as the editor (game composed under
  it, centered full-window in play), and cm.main routes the panels there after
  `editor.frame` regardless of editor state. So changing ui_scale with the editor
  closed rescales the menu live (it didn't before — it drew at the game scale).
  Render-only / live-only; goldens untouched.
- **Flutter is a rhythmic hold, not a glide** (M7 feel pass 4 + 4b, GAME.md §4 +
  D035): hold E after a hop and KEEP holding once you START FALLING → a small
  UPWARD height-based mini-hop every `flutter_interval`(30f≈2/s), `flutter_boosts`
  (4) times, sized (`flutter_h`=11) to roughly HOLD altitude with a gentle ~11px
  bob. Carried momentum is CANCELLED at hover-start (a flash-jump doesn't launch
  you far) and each boost is a slight up-FORWARD diagonal (`flutter_vx`=30 « the
  ~84 vertical → ~20°, <45°) so you drift forward a little; air drag keeps it
  gentle, hold a dir to steer. Replaces the `flutter_grace`/`_max`/`_fall`/`_decel`
  glide knobs; the "must be falling" gate is the tap guard. **4b** tuned the boosts
  ¼ smaller + 2/s; **4c** kept momentum (too far); **4d** cancel + slight diagonal
  (the keeper). Verified on TOUR: x drifts gently ~20–34px/s, vy flips every 30f at
  ~−84, y holds; selftest 22351; KITCHECK + TOUR record→verify byte-exact;
  montage on llm-feed. **KITCHECK's flutter sub-test no longer triggers** (hop hold
  lands in a merged airtime under the new trajectories — choreography drift, not a
  bug; re-choreograph once the knobs settle). Magnitudes are the human's feel call.

**Still open / deferred**:
- **`cfg.ui_scale`** default (2× now; D036 says 1×) — the human's taste call,
  live-tunable + in the options menu (and now persisted). Not blocking.
- **Golden suite re-cut** — DEFERRED (D033 + STATUS): the pixel goldens
  (sandbox_idle/tour) are M5-era and would just re-cut again when real art lands
  (M10); the `.ptrace`→`.ctrace` trace re-cut waits on confirming the rename
  (D033, human's call). selftest (22351) is the live net meanwhile.

**Next:** native pass on the round-3/4 interactive feel (Esc opens the menu;
fill presets; ui_scale rescales the menu in play; **the flutter** — does it hold
height well, is the bob / forward drift right, is `flutter_h`/`flutter_vx` to
taste) + the ui_scale default taste on win11; the deferred golden re-cut; then M9
(audio) or M7's asset-gated items (CW≈26 scale via FOV/scale + `move.cw/ch`;
slice VFX once the editor's particle work lands).

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
  horizontal momentum; arrows + teleport are locked out for the whole grapple**
  (committed vertical move; jump still cancels).

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

## Next step — finish M8 (M8.4 → M8.6 → M8.5), then close M7's deferred items

**M8.1–M8.3 are done** (see the Phase block up top: PAL api5 viewport surface +
two-target composite + the resize ladder). Remaining M8 sub-steps:

1. **M8.4 — editor + dev UI onto the ui canvas**: route `editor`/`ui`/`console`/
   `scrub`/`perf` draws through `pal.x_target("ui")`; lay them out against the
   ui-canvas size (not `gfx_size`, which is now the FOV); panels hit-test in
   ui-space (`ui_x/ui_y`), the world overlay + prop placement stay game-space
   (`x/y`); the game becomes a central viewport rect via `pal.x_compose`. This
   is the big Lua refactor and the visible payoff (editor at 1× around game at
   2×). **Default layout is a taste call — checkpoint with the human first.**
2. **M8.6 — options menu**: set resolution/scale/fullscreen directly (a
   borderless/fullscreen window can't be drag-resized). PAL hooks exist
   (`x_set_window_size`/`x_set_fullscreen`); needs the menu UI + persistence.
3. **M8.5 — docs + goldens + multi-file**: ADR for the two-target model, the
   ARCHITECTURE api5 table, multi-file/subdir hot-reload at scale, golden re-cut.
   The **zoom** delivers the GAME.md §4 anchor (6 CW ≈ ⅓ screen, CW≈26 at the
   480-wide FOV) — set the FOV/scale + `move.cw/ch` together here. Plus the
   editor's live particle-emitter work for the deferred M7 **slice VFX**.
2. **Then close M7's deferred items** (once scale + assets settle): final knob
   tuning with the real sprite; the slice VFX; and **re-cut the golden suite** —
   committed traces are still dormant `.ptrace` (suite globs `.ctrace`). Plan:
   **delete** the obsolete-mechanic traces (boostcap/boostlock/divecancel/djscale/
   jumpfeel/platformer*/sandbox_ease/old kitcheck/sandbox); **re-cut as `.ctrace`**
   the engine-feature goldens (editpaint, inspectpoke, propspawn, mantle) +
   churn/evalfix; **add** a fresh `kitcheck.ctrace`; **re-shoot** the pixel
   goldens (sandbox_idle, sandbox_tour). selftest 22312 is the live net until then.

Controls (dev): arrows · space=jump (hold=auto-repeat; airborne=flash, Up=up-jump)
· e=hop (hold=flutter) · **q=grapple** · r=teleport · d=slice. F1=editor ·
**Esc=options menu** · **alt+enter=borderless fullscreen** · `=console · F3=perf ·
F4=time machine. `game.save_knobs()` persists tuning. The temporary cooldown HUD
shows hop/grapple/tp timers.

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
