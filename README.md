# cosmic2d

A tiny 2D pixel-art engine / fantasy console. The intended distribution is one
folder containing the engine, editor, tools, and game projects. Today the
source checkout is built with Nix; clean-machine, extract-and-run artifacts
and in-editor export are still alpha release gates.

**Status: alpha candidate.** The engine, infinite-canvas editor, audio stack,
and an out-of-the-box demo game are here. The deterministic suite is green,
but portable distribution, storage hardening, gamepad support, project/export
UX, and broader genre demos are still release gates; see `docs/ALPHA.md`.

## Try it

Linux/WSL2 with [Nix](https://nixos.org):

```sh
nix develop -c make -C pal     # build bin/cosmic
bin/cosmic                     # the project picker — the front door
```

The picker lists your projects. Open the bundled **demo** (a two-room
platformer with music that swaps between rooms), or press **+ New project**
to scaffold your own. A tile opens a project in the editor; the ▶ zone plays
it.

```sh
bin/cosmic projects/demo            # play the demo directly
bin/cosmic projects/demo --edit     # open it in the editor
```

The editor release bundles (`nix build .#cosmic` / `.#cosmic-windows`) contain
only the intentional demo and picker; `.#cosmic-dev` and
`.#cosmic-windows-dev` additionally carry internal tests and fixtures. Editor
bundles drop two launchers in their **root**:

- **`cosmic2d-editor`** (`.exe`) — the project picker / editor front door.
- **`demo`** (`.exe`) — the bundled demo, straight to play.

## Make a game

Everything is authored in the editor (`--edit`, or via the picker): an
infinite canvas of floating windows. Spawn windows from the right-click
menu — a **code editor**, a **sprite editor** (+ animation), a **map editor**
(collider chains, one-ways, markers) and **tilemaps**, a **sound player**, a
**synth** (FM + Game Boy voices with filter/pitch-sweep), a **music** tracker,
and a **palette** designer. New assets and projects auto-name themselves with
three random words, so nothing blocks on a filename.

The game itself is hot-reloadable Lua: edit `main.lua` while it runs. See
`projects/demo/` for a complete, commented example — the moveset, two rooms,
sound effects, and two 30-second BGMs.

## Ship a game

The developer packager can make the bundled demo into a play-only artifact:

```sh
nix run .#package -- demo          # -> demo-windows.zip
nix run .#package -- demo linux    # -> demo-linux.tar.gz
```

The bundle contains the selected editable project, engine/editor tooling,
README, and LICENSE. Its named launcher boots the game locked to play mode;
`bin/cosmic2d-editor` remains available for a deliberate authoring entrance.
This is not yet the promised general export flow or a clean-machine-certified
release; those are gates A2 and A3 in `docs/ALPHA.md`.

## Shape of the thing

- **Two layers**: a small per-platform C binary ("PAL": SDL3 + Vulkan via
  SDL_GPU, embedded Lua 5.4, typed memory buffers, a frame-locked FM/sampler
  audio synth) under a fully hot-reloadable Lua engine — game code, physics,
  the editor, and all tools are Lua you can edit while the game runs.
- **Deterministic to the bit**: fixed 60 Hz sim, snapshot/rewind any frame
  (emulator-style), input-trace regression tests against state + pixel + PCM
  goldens on a pinned software Vulkan driver.
- **Batteries included**: a platformer moveset, sprite/animation + map +
  tilemap editors, an FM/Game-Boy synth and a music tracker with stock
  instruments and sound effects, a palette designer with stock palettes, and
  a demo game to start from.

Deep dives live in `docs/` — `PLAN.md` (vision), `ARCHITECTURE.md` (the
two-layer design + determinism rules), `EDITOR.md`, `AUDIO.md`, `MAPS.md`.

## Platforms

Development builds run on Linux and Windows desktop; the Windows binary is a
cross-build. Portable clean-machine artifacts are still being validated.
macOS is not supported for this alpha.

## License

MIT — see [LICENSE](LICENSE). Vendored third-party code keeps its own
(compatible) licenses, noted in `pal/vendor/`.
