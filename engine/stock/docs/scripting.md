# Writing a game

This guide covers the supported scripting path for a small project: lifecycle,
deterministic state, input, drawing, maps, collision, animation, and audio.
The bundled `projects/demo/` is the complete working example.

## Project shape

A project needs `project.lua` and an entry file (normally `main.lua`):

    -- project.lua
    return {
      name = "my game",
      author = "me",
      version = "0.1",
      description = "a small adventure",
      icon = "icon.png",
      controls = "CONTROLS.md",
      credits = "CREDITS.md",
      licenses = { "LICENSE.md" },
      internal_w = 480,
      internal_h = 270,
      window_scale = 2,
      entry = "main.lua",
    }

The editor's **project settings** window edits the identity, internal
resolution, and initial window fields above. It shares the code editor's
working `project.lua` bytes and journal, preserves unedited declarative keys,
and atomically publishes canonical inspectable Lua on Ctrl+S. Icon/legal file
pickers and export configuration remain follow-up A3 work; those keys are still
editable directly in the code window today.

Paths passed to `pal.read_file` are relative to the engine working directory.
For project assets, prefix them with `cm.main.args.project .. "/"`.

The file executes in an empty environment and must return only plain data
(strings, finite numbers, booleans, and tables). The first four player-facing
fields (`name`, `version`, `author`, and `description`) are plain strings. A
player bundle additionally requires the four project-local references above.
`icon` is a square 32–1024 px PNG and is
also used for the live OS window. `controls` and `credits` are non-empty
Markdown files; `licenses` is a non-empty array of text license/notice files.
Use forward slashes and no `.`/`..` segments, absolute paths, drive prefixes,
or backslashes. The packager evaluates `project.lua` as declarative data in an
empty environment, validates every reference, and fails closed rather than
publishing an incomplete player README. Project authors remain responsible for
the licensing of their project-local code and assets; engine/runtime notices
are carried separately in every archive.

## Lifecycle

The entry file returns a table with three callbacks:

    local game = {}

    function game.init()
      -- boot, restart, and hot-reload setup
    end

    function game.step()
      -- deterministic simulation, fixed at 60 steps/second
    end

    function game.draw()
      -- render the current state; do not change simulation here
    end

    return game

`init` may run more than once while buffers and the document survive. Make it
idempotent: use `value = value or default`, and rebuild disposable wrappers
around persistent data instead of assuming a fresh process.

Load engine and project modules through the reload-aware loader:

    local state = cm.require("cm.state") -- engine/cm/state.lua
    local player = cm.require("player")  -- <project>/player.lua

Project modules return ordinary Lua tables. Avoid top-level simulation changes:
put them in `init` or `step` so reload and replay have an explicit boundary.

## State that rewinds

Simulation truth belongs in `cm.state.doc` or a named `pal.buf`. Ordinary Lua
locals and module tables are not snapshotted.

    local state = cm.require("cm.state")

    function game.init()
      local d = state.doc
      d.player = d.player or { x = 100, y = 80, hp = 3 }
    end

    function game.step()
      state.doc.player.x = state.doc.player.x + 1
    end

Use `state.frame()` as the deterministic clock. A frame is 1/60 second.
For dense numeric state, allocate a stable named buffer and access typed slots:

    local body = pal.buf("mygame.player", 16)
    body:f32(0, body:f32(0) + 1.5) -- x at byte offset 0
    body:f32(4, -3.0)              -- velocity at byte offset 4

Calling `pal.buf` again with the same name adopts the existing buffer. Do not
change a buffer's size without an explicit migration.

## Actions, mouse, and keys

Define actions in a fixed array during `init`. Their first-definition order is
part of recorded input, so append new actions rather than reordering old ones.

    local input = cm.require("cm.input")

    input.map({
      { "left", input.key.left, input.key.a },
      { "right", input.key.right, input.key.d },
      { "jump", input.key.space },
    })

    if input.down("left") then ... end       -- held
    if input.pressed("jump") then ... end    -- up -> down edge
    if input.released("jump") then ... end   -- down -> up edge

Mouse input uses internal game pixels and is recorded too:

    local mx, my = input.mouse()
    if input.button_pressed(1) then ... end
    if input.button_down(2) then ... end
    local steps = input.wheel()

The current input format supports keyboard, mouse position/buttons, and wheel,
with at most 32 actions. Gamepad input, axes, and player rebinding are planned
for alpha gate A4 and must not be advertised by a project yet.

## Drawing, cameras, and text

Begin every draw with a clear, then draw back-to-front:

    local gfx = cm.require("cm.gfx")
    local text = cm.require("cm.text")

    function game.draw()
      pal.begin_frame(0.08, 0.09, 0.14, 1)

      gfx.camera(state.doc.camera_x, state.doc.camera_y)
      gfx.layer(0.5) -- parallax: half camera motion
      pal.quad(0, 0, 480, 270, 0.2, 0.3, 0.5, 1)

      gfx.layer(1)   -- world space
      pal.quad(state.doc.player.x, state.doc.player.y,
               16, 24, 1, 0.8, 0.5, 1)

      gfx.layer(0)   -- screen-fixed HUD
      text.draw(4, 4, "hp 3", { r=1, g=1, b=1, a=1 })
    end

`gfx.layer(x [, y])` applies the camera multiplier to later drawing. Call
`gfx.pixel_snap(true)` once if pixel-art tiles crawl or show seams under a
fractional camera. It rounds the render translation, not simulation positions.

Load and draw a baked PNG or sprite strip:

    local tex = gfx.texture(cm.main.args.project .. "/art/hero.png")
    gfx.sprite(tex, 100, 80) -- whole image at native size
    gfx.sprite(tex, 100, 80, { sx=16, sy=0, sw=16, sh=24, dw=32, dh=48 })

`text.draw` uses the `5x8` font by default; pass `font="8x16"` for the larger
font. `text.measure(str [, font])` returns width and height.

## Animation

The sprite editor bakes a `.spr` source into a horizontal `.png` strip and an
`.anim` sidecar. Load clips and choose a zero-based frame from sim time:

    local anim = cm.require("cm.anim")
    local clips = anim.load(cm.main.args.project .. "/art/hero.anim")
    local walk = anim.find(clips, "walk")
    local frame = walk and anim.frame_at(walk, state.frame()) or 0

Use that frame to select a source rectangle in `gfx.sprite`. Map placements
with an animation name do this automatically in `cm.map.draw_places`.

## Loading and drawing a map

A `.map` contains bounds, collider chains/circles, markers, and placed assets.
Load it during `init` with a stable collision-buffer name:

    local map = cm.require("cm.map")
    local room

    function game.init()
      local path = cm.main.args.project .. "/room.map"
      room = map.use({ path=path, name="mygame.room_collision" })
    end

That name is a persistent map *slot*, not just a collision allocation. The
engine captures its active path, canonical placements/markers, collision, and
direct `map.get(...)` mutations, then rebuilds the same `room`/`room.world`
wrapper identities after snapshot load, timeline parking, and rewind. Calling
`map.use` again with the same slot/path adopts the captured generation; pass
`fresh=true` only when you explicitly want to discard it and reload disk.

Draw its visuals with the world layer active:

    gfx.layer(1)
    map.draw_places(room, camera_x, camera_y)

Markers are in `room.doc.markers` in file order. Custom marker fields authored
in the inspector are returned as a table by `map.extras(marker)`:

    for _, marker in ipairs(room.doc.markers) do
      local fields = map.extras(marker)
      if marker.kind == "portal" and fields.to then ... end
    end

If a level module copies markers, bounds, tint, or titles into convenience
fields, treat those as a revision-keyed derived cache: call `map.sync(room)`
and rebuild when `room.rev` changes before drawing. The bundled multi-room demo
shows this pattern. Never keep an independent current-map truth on the Lua heap.

A named placement can act as an asset reference:

    local path, kind, ok = map.ref("battle music")

`ok` is false when a loud built-in fallback is used. Missing visual placements
draw a magenta checkerboard rather than silently disappearing.

## Moving against map collision

`room.world` is a `cm.collide` world. Sweep an AABB by a proposed delta:

    local nx, ny, hit = room.world:move(x, y, w, h, dx, dy, {
      ground = was_grounded, -- keeps downhill slope contact
      drop = drop_pressed,   -- ignore one-way support this step
    })
    x, y = nx, ny
    if hit.down then vy = 0 end
    if hit.left or hit.right then vx = 0 end

Useful queries are:

- `world:grounded(x, y, w, h [, opts])` — standing on support.
- `world:stand_ray(x, y0, y1)` — first supporting surface along a ray.
- `world:stand_span(x, w, y0, y1)` — support under a horizontal span.
- `world:solid_at(x, y)` — inside closed solid terrain or outside side/bottom
  bounds.
- `world:circles(x, y, w, h)` — collider circles overlapping an AABB, in file
  order.

The mover handles solid and one-way chains, slopes up to 45 degrees, and map
bounds. General AABB/circle layers, raycasts, and trigger-query ergonomics are
still alpha A5 work; projects currently scan markers or use small overlap
helpers as the demo does.

## Sound effects and music

Instruments must be uploaded into the simulation bank before use. The demo's
`audio.lua` is the concise pattern to copy:

    local ins = cm.require("cm.ins")
    local snd = cm.require("cm.snd")
    local path = cm.main.args.project .. "/ins/jump.ins"
    local doc = ins.decode(assert(pal.read_file(path)))
    ins.upload(doc, 0, "sim", "jump")
    snd.on(0, 64, 110) -- slot, MIDI note, velocity 0..127

`snd.on` returns a voice handle; `snd.off(handle)` releases it. Slots 0–31 are
for game SFX. Play a tracker song with:

    snd.music(cm.main.args.project .. "/sound/theme.song", { loop=true })
    snd.music_stop()

Sequencing and audio stepping are handled by the engine. Sound is deterministic
simulation: trigger it in `step`, not `draw`.

## Determinism checklist

- Change simulation only in `init`/`step`; keep `draw` side-effect free.
- Put all lasting simulation data in `state.doc` or named buffers.
- Use `state.frame()` for time and `cm.rand` for random numbers.
- Use `cm.math` for simulation trig; do not use wall clocks or `math.random`.
- Iterate gameplay arrays with `ipairs`. Do not let hash-table `pairs` order
  decide collisions, spawns, random draws, or any other visible outcome.
- Treat file reads as loading/setup. Do not make per-frame gameplay depend on
  files, directory order, editor state, or the operating system.
- Keep action order and named-buffer layouts compatible with old recordings.

## Small module reference

- `cm.state` — `doc`, `frame()`, snapshots, named-buffer helpers.
- `cm.input` — action map, keyboard/mouse state and edges.
- `cm.gfx` — camera/layers, PNG textures, sprite rectangles, pixel snap.
- `cm.text` — bitmap text drawing and measurement.
- `cm.map` / `cm.collide` — map assets, placements, markers, swept AABBs.
- `cm.tmap` — decode/draw/edit tilemap grids.
- `cm.anim` / `cm.sprite` — animation sidecars and sprite source documents.
- `cm.snd` / `cm.ins` — deterministic music, voices, and instruments.
- `cm.palette` / `cm.grade` — palette data and render-only color grading.
- `cm.rand` / `cm.math` / `cm.ease` — deterministic helpers.

Advanced format and determinism contracts live in `docs/ARCHITECTURE.md`,
`docs/MAPS.md`, and `docs/AUDIO.md`. For copyable game code, read
`projects/demo/main.lua`, `level.lua`, `player.lua`, and `audio.lua`.

Back to [Getting started](engine/stock/docs/getting-started.md) ·
[Using the editor](engine/stock/docs/editor.md)
