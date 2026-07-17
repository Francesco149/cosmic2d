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
resolution, initial window fields, icon, controls, credits, and licenses above.
It shares the code editor's working `project.lua` bytes and journal, preserves
unedited declarative keys, validates referenced project files through the same
contract as packaging, and atomically publishes canonical inspectable Lua on
Ctrl+S. Its **build/export** tab packages the saved project from any opened
folder with the matching carried Linux or Windows runtime, shows progress and
actionable failures, and publishes the archive plus integrity hashes without a
shell toolchain. Unsaved editor assets must be saved first.

Paths passed to `pal.read_file` are relative to the engine working directory.
For project assets, prefix them with `cm.main.args.project .. "/"`.

The file executes in an empty environment and must return only plain data
(strings, finite numbers, booleans, and tables). The first four player-facing
fields (`name`, `version`, `author`, and `description`) are plain strings. A
player bundle additionally requires the four project-local references above.
`icon` is a square 32–1024 px PNG and is also used for the live OS window.
`controls` and `credits` are non-empty Markdown files; `licenses` is a
non-empty array of text license/notice files. An entirely absent release packet
is a valid draft, but once any reference is set the settings window requires
the complete packet and valid saved bytes before it will publish `project.lua`.
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
Each action lists ALL of its bindings — keyboard scancodes and pad
descriptors feed the same action:

    local input = cm.require("cm.input")

    input.map({
      { "left", input.key.left, input.key.a, "pad:dpleft", "pad:lx-" },
      { "right", input.key.right, input.key.d, "pad:dpright", "pad:lx+" },
      { "jump", input.key.space, "pad:south" },
    })

    if input.down("left") then ... end       -- held
    if input.pressed("jump") then ... end    -- up -> down edge
    if input.released("jump") then ... end   -- down -> up edge

A binding is a scancode number (`input.key` names common ones) or a string:
`"pad:south"` is a pad-1 button, `"pad:lx-"`/`"pad:lx+"` is a stick or
trigger direction past a threshold (`input.axis_threshold`, default 40 of
127), and `"pad2:..."` pins a binding to another pad. What you declare are
the DEFAULTS: players can rebind every action from the Esc menu's controls
page, and their overrides persist per machine in the project's `input.dat`
(never exported with the project). Show bindings honestly in your HUD with
`input.label`:

    input.label("jump")           -- every binding: "Space/south"
    input.label("jump", "key")    -- first keyboard binding: "Space"
    input.label("jump", "pad")    -- first pad binding: "south"

`input.bindings(name)` returns the active binding list, `input.rebind(name,
list)` overrides it from code (`nil` restores defaults), and
`input.conflicts()` reports inputs bound to several actions — legal, but
the controls page marks them.

Mouse input uses internal game pixels and is recorded too:

    local mx, my = input.mouse()
    if input.button_pressed(1) then ... end
    if input.button_down(2) then ... end
    local steps = input.wheel()

The current input format supports keyboard, mouse position/buttons, wheel,
and up to four gamepads, with at most 32 actions. Actions and rebinding
cover the common case; read the pad directly (below) for analog movement,
per-pad multiplayer, or anything the action bits cannot express.

## Gamepads

Controllers can connect and disconnect at any time. The first connected
controller becomes pad 1, the next pad 2 (up to pad 4), and a disconnected
slot frees up for the next controller. Pad state is part of the recorded
input, so traces, rewind, and replay carry gamepad play exactly.

    if input.pad_connected(1) then ... end
    if input.pad_down(1, "south") then ... end     -- bottom face button held
    if input.pad_pressed(1, "start") then ... end  -- edges, like actions
    if input.pad_released(1, "south") then ... end
    local lx = input.pad_axis(1, "lx")             -- sticks: -127..127
    local rt = input.pad_axis(1, "rt")             -- triggers: 0..127

Buttons and axes use SDL's standard gamepad layout (`input.pad_btn`,
`input.pad_ax` name them): the face buttons are positional
`south/east/west/north` (south = Xbox A / Nintendo B), plus
`back/guide/start`, `lstick/rstick`, `lshoulder/rshoulder`, and
`dpup/dpdown/dpleft/dpright`; the axes are `lx/ly/rx/ry/lt/rt`. Axis values
arrive already deadzoned and quantized to whole numbers, so using them
directly in the sim stays deterministic — divide by 127 when you want a
-1..1 float. Players tune the deadzone and the axis press threshold on the
Esc menu's controls page; recordings store the post-deadzone values, so
retuning never invalidates a trace.

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
bounds.

## Rectangles, triggers, and the lightweight slide (`cm.box`)

For game-object rectangles that are not map terrain — pickups, triggers,
doorways, hand-built rooms — `cm.box` is a set of pure AABB helpers. Rects
are plain keyed tables `{ x=, y=, w=, h= }` (your actor tables pass through
untouched), overlap is strict (rects sharing only an edge do NOT overlap),
and everything is exact math on the inputs, so determinism is trivial.

    local box = cm.require("cm.box")

    -- did we grab the coin? (a centered square of side 8 at coin.x/y)
    if box.touch(d.x, d.y, PW, PH, coin, 8) then ... end

    -- are we inside the doorway rect?
    if box.overlap_rect(d.x, d.y, PW, PH, room.door) then ... end

    -- interaction reach: grow our rect, then test
    local ex, ey, ew, eh = box.expand(d.x, d.y, PW, PH, 6)
    if box.overlap_rect(ex, ey, ew, eh, room.door) then ... end

    -- first solid we would hit, in array order
    local i, r = box.hit(solids, x, y, w, h)

    -- walk with the classic wall-slide feel (axis-at-a-time)
    d.x, d.y = box.slide(d.x, d.y, PW, PH, dx, dy, solids)

`box.slide` moves one whole step per axis and cancels an axis entirely when
it would overlap — the feel every top-down game hand-rolls. It is NOT swept:
a step larger than a wall's thickness tunnels, so fast movers against real
terrain belong to `room.world:move` above. The bundled `cellar` project is
the worked example; layers/masks, circles, raycasts, and richer trigger
ergonomics remain later A5 work.

## Actors, tags, and timers (`cm.actor`)

When a game grows populations — enemies, shots, pickups — the bookkeeping
(stable identity, spawn/despawn, iteration, cooldowns) is the same
everywhere. `cm.actor` is that bookkeeping over ONE plain table you keep in
`state.doc`, so snapshots, traces, and rewind carry your world by
construction. It is a small composable module, not an entity system: your
actors are your own plain tables, and everything else in this guide still
applies to them.

    local actor = cm.require("cm.actor")

    function game.init()
      local d = state.doc
      d.world = d.world or actor.world()
    end

    -- spawn: your table gains a stable ascending id
    local e = actor.spawn(state.doc.world, { tag = "enemy", x = 40, y = 8,
                                             w = 9, h = 9, hp = 2 })

    function game.step()
      local d = state.doc
      actor.tick(d.world)           -- ONCE per step: sweep + timers
      for a in actor.each(d.world, "enemy") do a.x = a.x + 0.5 end
      local hitme = actor.hit(d.world, "enemy", d.x, d.y, 10, 10)
      if hitme then actor.despawn(d.world, hitme) end
    end

The rules that make it deterministic and safe:

- Iteration (`each`, `count`, `first`, `hit`) is always spawn order —
  ascending id. `hit` is the first strict-edge overlap (`cm.box` semantics;
  give actors `x`/`y`/`w`/`h` and they are box rects).
- `despawn` only marks: every query skips the actor immediately, and the
  next `tick` removes it — so despawning inside your own `each` loop is
  safe. Ids are never reused; `actor.get(w, id)` finds a live actor by id.
- `tick(w)` runs once per step (top of `step` is the canonical spot). Skip
  it and the world freezes — that is hit-pause for free.
- Timers are integer frame countdowns on any actor or the world itself:
  `actor.timer(w, "wave", 90)` arms, `running` is true while counting,
  `expired` is true exactly on the frame it reaches zero, and the next
  tick forgets it. `actor.timer(e, "cool", 9)` is a cooldown; check
  `not actor.running(e, "cool")` to act again.

The bundled `swarm` project is the worked example: enemies and shots are
tags in one world, the fire cooldown and the wave breather are world
timers, and the shots-vs-enemies loop is `actor.hit`. Components/systems,
multi-tags, parent/child links, and spatial indexes are deliberately
absent — later A5 slices earn ergonomics from real demo pain first.

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

## The options menu

Every game gets the Esc menu for free: fullscreen, window sizes that fit the
player's display, UI scale, master/music/SFX volume, the controls page
(rebinding plus stick deadzone and press-threshold knobs), and quit. All of it
is per-player, per-machine policy — volumes change what the speakers hear,
never the simulated mix, so recordings and replays are untouched; every choice
persists in the project's `video.dat`/`input.dat` (never exported).

Add game-specific settings to the same menu with `cm.options`:

    local options = cm.require("cm.options")

    options.add({ id = "shake", label = "screen shake",
                  kind = "toggle", default = true })
    options.add({ id = "zoom", kind = "slider", min = 1, max = 8,
                  default = 2, on_change = function(v) ... end })
    options.add({ id = "filter", kind = "choice",
                  choices = { "clean", "crt" } })

    if options.get("shake") then ... end -- read it in draw, not step

Declare options in `init`; values persist automatically beside the volume
knobs, and stored values survive even if a version skips the declaration.
These are LIVE settings for presentation choices — read them in `draw` or
apply them via `on_change`. A setting that changes gameplay belongs in
`state.doc` (where it is recorded) instead, or it will break replay.
`options.set(id, value)` and `options.set_vol("master"|"music"|"sfx", 0..100)`
are the scripted doors to the same knobs.

## Player saves

`cm.save` stores save data per player, outside the project folder, so exports
and copies of a game never carry anyone's progress. Declare a stable id in
`project.lua` first (new projects scaffold one; the project settings window
edits it):

    save_id = "my-game",   -- lowercase a-z 0-9 - _; renaming the project is
                           -- safe, changing save_id orphans existing saves

Then, in `main.lua`:

    local save = cm.require("cm.save")

    save.write(1, { level = d.level, coins = d.coins }) -- slot 1, atomic
    local data, err = save.read(1)  -- nil, "no save in slot 1" on a first run
    save.erase(1)                   -- explicit reset of one slot
    save.slots()                    -- { 1, 3 }: which slots exist

Saved data must be plain tables/numbers/strings/booleans, like `state.doc`.
Writes are atomic: a failure (named in `err`) can never corrupt the previous
save. `save.profile("name")` switches between per-player namespaces and
`save.wipe()` resets the current one.

**Loading must respect the recording.** Save files live on one machine;
recordings replay on any machine. The two safe shapes:

- **Boot loads** — read in `init`, and only fill `state.doc` fields that are
  absent (the same idempotence hot reload already requires):

      function game.init()
        local d = state.doc
        if d.level == nil then
          local got = save.read(1)
          d.level = got and got.level or 1
        end
      end

- **Mid-session loads** (a "load game" menu entry) — register a handler and
  call `save.load(slot)`; the engine records the loaded bytes and applies
  them at the start of the next frame, so replays reproduce the load without
  needing the file:

      save.on_load(function(data) state.doc.level = data.level end)
      if menu_picked_load then save.load(1) end

Reading a slot directly inside `step` and branching on it is a determinism
bug, exactly like reading any other local file. Writing from `step` is always
fine — a save write feeds nothing back into the simulation.

When your saved shape changes, bump the schema and describe each step once;
old saves migrate on read, and saves from a newer version of your game are
refused with a named error instead of being misread:

    save.schema(2)
    save.migrate(1, function(data) data.gems = 0 return data end)

Headless runs, captures, and replay verifies see a disabled store (`nil` plus
a reason), so test runs and recordings never depend on one machine's saves.
Handle the "no save" answer and your first run already does the right thing.

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
- `cm.box` — pure AABB overlap/queries and the lightweight wall slide.
- `cm.actor` — actor worlds in doc: stable ids, tags, spawn order, timers.
- `cm.tmap` — decode/draw/edit tilemap grids.
- `cm.anim` / `cm.sprite` — animation sidecars and sprite source documents.
- `cm.snd` / `cm.ins` — deterministic music, voices, and instruments.
- `cm.options` — the Esc menu: game-declared settings, volume doors.
- `cm.save` — per-player save slots/profiles outside the project folder.
- `cm.palette` / `cm.grade` — palette data and render-only color grading.
- `cm.rand` / `cm.math` / `cm.ease` — deterministic helpers.

Advanced format and determinism contracts live in `docs/ARCHITECTURE.md`,
`docs/MAPS.md`, and `docs/AUDIO.md`. For copyable game code, read
`projects/demo/main.lua`, `level.lua`, `player.lua`, and `audio.lua`.

Back to [Getting started](engine/stock/docs/getting-started.md) ·
[Using the editor](engine/stock/docs/editor.md)
