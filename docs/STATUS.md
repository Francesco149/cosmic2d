# status — living handoff

> Updated every session end and at milestone boundaries. A fresh session
> should be able to resume from this file alone (see PROCESS.md).

**Date**: 2026-06-11
**Milestone**: M3 — sandbox platformer v0 + the air kit: **DONE,
human-verified** ("the control scheme feels good now", 2026-06-11, after
the G-dive / bare-space-dj rebind). `nix run .#test` green, 6 goldens;
montage + stills on llm-feed. Deep feel-knob tuning deliberately waits
for the editor (human call). **Next: M4 — editor mode v0.**

## What works right now

Everything from M0–M2 (boot, live sessions, hot reload, parachute, PAL
draw/state/input/trace stack, determinism kit, goldens, pt.ui/console/
repl/perf, error containment), plus M3:

- **pt.tilemap** (D024): tile grids as self-describing named buffers
  (w/h/tile header + u16 cells), tile classes (solid/one-way) in a code
  table, camera-windowed bulk rendering, and an axis-separated swept-AABB
  mover — boundary-scanning (no tunneling), one-ways collide only on row
  entry from above, `drop` opt for down+jump, OOB = side/bottom walls +
  open sky. Selftested (+37 checks, 22179 total).
- **projects/sandbox = the platformer** (the M1 particle playground is
  retired; it lives on inside the old goldens' code bundles). Modules:
  `level` (procedural tileset + map built at chunk top-level → editing
  the level file hot-rebuilds it; parallax mountains/hills/clouds),
  `player` (MapleStory vocabulary: run accel/decel + air control, jump
  buffer + coyote, release-cut variable height, drop-through, grab/throw,
  squash & stretch + land/footfall dust), `props` (crate pit: tilemap
  collision, bounce/friction, stack-settling pairwise separation, thrown
  crates shove the pile), `fx` (256-particle pool, dust/spark palettes),
  `demo` (attract mode, D025), `pix` (procedural placeholder art).
- **The air kit** (human-requested, A Hat in Time vocabulary; controls:
  arrows, space jump, **G dive**, e grab):
  - *Dive*: G in mid-air (its own action; works during coyote too) —
    forward lunge, boom pop + trail, no steering, facing locked.
    Uncanceled it lands as a **belly slide** that persists until
    canceled (slide friction). Mid-air only; disabled while carrying.
  - *Cancel*: ANY action press during dive/slide — front-flip (tuck
    frames), slight up-pop, forward momentum slowed, air control back,
    facing locked until touchdown. Opposite-direction presses cancel too.
  - *Dive boost*: cancel within `knobs.dive.boost_win` (~150 ms) of the
    ground — probed ahead while falling, or within the window after
    touching down — while HOLDING the dive direction: big forward carry
    (boost trail) that evaporates on touchdown. The gap-crossing tech.
  - *Double jump*: space again in mid-air (no up), one charge per
    airtime, own buffer/coyote knobs (`knobs.dj`): an air press within
    `dj.coyote` of a ledge is still the full ground jump (charge kept);
    a space press that cancels a dive arms `dj.buffer`, so cancel→dj
    chains space-space. A charge-less air press buffers the landing
    jump as before. Dives lock the dj out; diving out of a double jump
    (or its flip) is allowed.
  - Interpretation notes for tuning: release-cut applies to the double
    jump and the cancel pop; a space press shortly before landing
    double-jumps when the charge is up (eats the landing buffer —
    standard dj-game behavior; the buffer applies once the charge is
    spent).
- **Feel knobs all live** in
  `doc.knobs.{move,dive,dj,cam,throw,prop,fx,feel}` — tune from the
  console while playing; knob-merge in init grows new keys into old docs.
- **Attract mode / demo** (D025): `game.demo(1)` (console or `--eval`)
  plays a ~28 s scripted tour: left plank tower → balcony → plateau →
  pillar long-jump → pit dive → crate grab → carry out (full jump over
  the 2-tile wall) → throw back in from the stair plank → drop-through →
  return over the pillar → **air-kit finale** (boost dive off the
  plateau, belly slide + flip, double jump → dive → slide closer). Any
  real press takes control back. Pure f(frame): replays byte-exact,
  drives goldens and montages.
- **pt.main --eval CODE** (repeatable): queues console lines for sim
  frame 1 via the D022 path — recorded as EVAL chunks, so headless
  recordings can flip doc switches.
- **Tests**: `nix run .#test` ALL GREEN — selftest (22179) + 6 goldens
  (churn, evalfix, sandbox, sandbox_ease, **platformer** [1400 f,
  pre-dive bundle], **platformer_dive** [1750 f: tour + air-kit finale]).
  Old goldens keep replaying the code they bundled — D012 doing its job
  through two sandbox rewrites now.

## Verified

- Agent-verified: selftest + full golden suite on lavapipe; demo
  choreography probed numerically end to end; prop pile settles to
  rest; montage + stills inspected and pushed to llm-feed.
- Human-verified (2026-06-11): M3 controls/moves windowed — **"the
  control scheme feels good now"**. Knob tuning deferred to the editor
  era by the human; defaults stand until then.

## Next step (M4 — editor mode v0; see PLAN)

1. Editor/play **mode switch** (` and F3 stay engine-reserved; editor
   unlock key TBD) — play mode locks editing for shipped zips.
2. **Map painting**: tile palette + brush over pt.tilemap (the buffer
   header makes the map tool-openable, D024); retires the code-built
   map — level.lua's top-level build becomes a "reset level" action.
3. **Prop spawn palette** (crates first; doc-tree prop defs later).
4. **Entity list + inspector** over the doc tree and named buffers —
   uigallery already dry-ran the widget set (search, virtualized lists,
   collapsing sections, drag numbers); gaps noted in D021 are additive.
5. **Collider debug draw** (tilemap classes + player/prop AABBs).
6. **Knobs persisted per project** (file next to project.lua) — this is
   where the deferred feel-tuning pass happens, knobs through the
   inspector with the human.
7. M2 wishlist rides along: inertial/bouncy scroll for editor chrome.

## Known small items / debts

- Windowed mode requires cwd = repo root (fix at M10 packaging).
- Freed-buffer husks + texture re-create leaks on VM reboot persist by
  design (inspector cleans up in M4).
- Trace recorder buffers in memory; M5 ring-trace replaces it (D019).
- Console line wrap = none; dim-timestamp polish possible (M2 note).
- repl env caveat (D022): pre-recording env assignments don't travel.
- UI feel wishlist (human, 2026-06-11): inertial/bouncy scroll regions —
  scheduled with M4 editor polish.
- Demo choreography is calibrated against default move knobs (D025):
  retuning movement after the human pass means re-walking the timeline
  (probe pattern: temp print in game.step at %30 frames) and recording a
  new golden deliberately (old ones stay, contract rule 6).
- Player/prop interaction is one-way by design v0: crates never block
  the player; thrown crates don't hit the player. Revisit when the prop
  pit gets physics love (post-M10 rotation solver).
- Belly slide keeps the standing 10x14 hitbox (sprite-only flattening) —
  no slide-under-gap tech until the cancel pop gets an overhead check
  (the mover never ejects an embedded box). The map has no low gaps yet.
- Boost flight distance (~350 px held) is tuned to clear the home
  stretch; cancel-pop release-cut and boost both interact with
  move.cut — flag if it feels inconsistent windowed.
- props separation can squeeze a crate into a wall in pathological piles
  (positional pushes are mover-clamped, but two crates + wall can still
  pin); watch for it once map painting lets users build cruel pits.

## Open questions for the human

- Feel pass: are run speed (130), jump (280/cut 0.45), gravity (700),
  camera (lerp 0.10, lookahead 26, deadzone 26), throw (260/200) in the
  right neighborhood? Squash 0.55 too cartoony or not enough?
- Air kit interpretation checks (all knobbed, see notes above): a
  charged air space press double-jumps even right before landing;
  dives disabled while carrying; dj.coyote = air-press ledge grace as a
  full jump. Camera lookahead lags the boost — widen cam.look_lerp or
  leave? (Feel knobs proper wait for the editor, per the human.)
- Art direction check on the procedural placeholders (tiles, kid sprite,
  crates, parallax palette) — placeholder-fine, or worth one more pass
  before M4 screenshots start accumulating?
