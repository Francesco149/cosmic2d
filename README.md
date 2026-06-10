# pettan2d

A tiny 2D pixel-art engine / fantasy console. One self-contained folder holds
the engine, its editor and tools, and your game projects — share a game by
zipping the folder; the recipient can play it, edit it live, and build their
own game with the same binary.

**Status: pre-alpha, milestone M0 (boot).** Nothing to see yet unless you
enjoy watching quads.

## Shape of the thing

- **Two layers**: a deliberately small per-platform C binary (SDL3 + Vulkan
  via SDL_GPU, embedded Lua 5.4, typed memory buffers, audio) under a fully
  hot-reloadable Lua engine — game code, physics, editor and all tools are
  Lua you can edit while the game runs, no recompiling.
- **Deterministic to the bit**: fixed 60 Hz sim, snapshot/rewind any frame
  (emulator-style), input-trace regression tests against state goldens.
- **Batteries included** (roadmap): live-editable platformer sandbox with
  rigid-body props, sprite/animation editor, procedural sprite generator,
  FM synth for sfx + music, LUT color grading, timeline scrubber/debugger.

See `docs/PLAN.md` for the full vision and roadmap, `docs/ARCHITECTURE.md`
for the design.

## Build (dev)

Linux/WSL2 with Nix:

```sh
nix develop -c make -C pal
bin/pettan projects/sandbox
```

Windows native builds land at milestone M7.

## License

MIT — see [LICENSE](LICENSE). Vendored third-party code keeps its own
(compatible) licenses, noted in `pal/vendor/`.
