# The stock assets window

Everything the engine ships in the box — instruments, demo songs, sprites,
figures, palettes — in one read-only browser. Nothing here can be edited or
deleted in place; every door pulls a copy INTO your project.

## The doors

- **double-click** opens an *unsaved copy*: the stock bytes open in the right
  editor window under a fresh auto-generated project name, already marked
  unsaved. Play with it freely — **ctrl+s** keeps it in your project; closing
  the window without saving leaves your project untouched.
- **c** (or **enter**) copies the selected asset into your project directly
  (instruments land in `ins/`, songs in `sound/`, art in `art/`, palettes in
  `pal/`). The assets browser flashes the new file.
- **drag** an asset onto a window that accepts it — a music track binds a
  dragged instrument (copying it in on the way), the sprite editor's stamp
  well takes a dragged image.

## What ships

- **ins** — the FM/gameboy/sfx instrument presets (the synth window's preset
  rail lists these too). Families cover the common vibes: orchestral
  (strings, choir, harp, flute, reed, timpani, orchestra hit, harpsichord,
  music box), jazz/latin/funk (nylon, upright, vibes, muted trumpet, clav,
  slap, cowbell), electronic (sub, reese, ride, shaker, rim, conga), and
  ambient/spooky (drone, glass).
- **songs** — demo tracks smoke-testing those presets: desert, water,
  a minuet, a soft prelude, battle, final boss, drum-n-bass, breakbeat,
  two bossa novas, funk, a detective swing, horror, and slow ambient.
  Open one unsaved and drill into its patterns to see how it's built —
  they make good starting points.
- **art / fig / pal** — the stock tileset, the mascot figure, and the
  shipped palettes.

## Keys

- **c** copy the selection into the project · **enter** same
- **ctrl+wheel** dials the preview tile size · type in the filter to
  fuzzy-find · the chips filter by family

Next: [The assets browser](engine/stock/docs/win-assets.md)
