# swarm

A one-screen twin-stick arena shooter in one file: waves of chasers pour
in from the edges, you kite and shoot eight ways until they get you, then
restart instantly and chase the high score. It exists to be read — open
it in the editor and poke around.

## Controls

See `CONTROLS.md`. Arrows/WASD or the left stick move; Space or the right
shoulder fires along your facing; on a pad the right stick aims and
aiming fires by itself. R (or Fire after death) restarts instantly.
Everything is rebindable from the Esc menu.

## What it teaches

- **An actor world** (`cm.actor`): enemies and shots live in one world in
  `state.doc` with stable ids, string tags, spawn-order iteration,
  mark-and-sweep despawn, and integer frame timers (the fire cooldown and
  the wave breather). Rewind and traces carry it by construction.
- **Overlap queries**: `actor.hit` answers "which enemy does this shot
  touch" and "did anything reach the player" with strict-edge AABBs.
- **Juice** (`cm.tween`): the hit pause, screen shake, and death flash
  are named decaying effects on doc; all the draw math is pure functions
  of the remaining fraction, and the shake wobble never touches the PRNG.
- **Aim and 8-way fire** (`cm.move`): `dir` merges stick and keys,
  `face8` chains right-stick aim over move direction over last facing,
  and `unit8` keeps diagonal shots the same speed as straight ones.
- **Deterministic randomness** (`cm.rand`): spawn edges come from the
  engine PRNG, which is sim state — runs replay bit-for-bit.
- **Player saves** (`cm.save`): the high score is read once at boot
  (absent-fill only) and written back as a pure output on death, so
  replays never depend on this machine's save file.

## File tour

- `main.lua` — the whole game: input map, the wave spawner, movement and
  aim, shooting, chaser homing, overlap resolution, juice, the game-over
  path with the save write, and drawing. Comments mark which engine
  module carries each formerly hand-rolled block.
- `project.lua` — name, resolution, `save_id` (the save namespace), and
  the player-packaging metadata.

## Things to try

- Make waves harder: raise the per-wave count or enemy speed ramp.
- Add a second enemy tag that moves diagonally, and spawn a few per wave.
- Give shots piercing: don't despawn the shot on its first hit.
- Shorten `COOLDOWN`, or make the pause/shake bigger for chunkier hits.
- Track and save your best wave beside the high score.

## Starter template

The picker's **arcade** starter template is this game's naive minimal
cousin — same genre shape, deliberately hand-rolled instead of using the
engine modules above, so you can see exactly what they save you.
