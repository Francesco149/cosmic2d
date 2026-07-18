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

Start every module by ADOPTING the module table the loader passes in,
exactly like the engine's own modules:

    local M = select(2, ...) or {}
    -- ... define fields and functions on M ...
    return M

A fresh `local M = {}` looks equivalent but splits the module's brain on
reload: replays and hot reload re-execute changed sources against the
table other modules already hold, and functions from a fresh table write
fields your callers never see. Avoid top-level simulation changes: put
them in `init` or `step` so reload and replay have an explicit boundary.

## State that rewinds (`cm.state`)

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

## Actions, mouse, and keys (`cm.input`)

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

`input.bindings(name)` returns the active binding list,
`input.rebind(name, list)` overrides it from code (`nil` restores
defaults), and
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

## Movement vectors (`cm.move`)

Every action game re-derives the same movement dance: read the stick,
fall back to the arrow keys, even out diagonal speed, turn a vector into
an 8-way facing. `cm.move` is exactly that dance, reading the recorded
input state — deterministic in the sim by construction:

    local move = cm.require("cm.move")

    -- in your step: one merged unit-scale vector; you supply the speed
    local mx, my = move.dir(1)
    d.x, d.y = d.x + mx * SPEED, d.y + my * SPEED

    -- twin-stick aim: the right stick wins, else the move direction,
    -- else the last facing sticks (nest the calls for the priority)
    local rx, ry = move.stick(1, "r")
    d.fx, d.fy = move.face8(rx, ry, move.face8(mx, my, d.fx, d.fy))

    -- shots travel the facing at full speed on diagonals too
    local ux, uy = move.unit8(d.fx, d.fy)
    spawn_shot(d, ux * BSPEED, uy * BSPEED)

- `move.dir(pad)` merges pad `pad`'s left stick with the standard
  `left`/`right`/`up`/`down` actions: the stick verbatim while deflected
  (analog magnitude, so a full diagonal exceeds length 1 — the classic
  feel), else the keys with diagonals scaled by `move.DIAG` so 8-way
  keyboard speed is even. Multiply by your own speed.
- `move.stick(pad, side)` is the raw stick as -1..1 floats (`"l"` or
  `"r"`; the recorded quantized axis over 127, nothing re-derived).
  `move.keys(left, right, up, down)` is the digital half as -1/0/1
  integers, with custom action names if yours differ.
- `move.face8(x, y, fx, fy)` takes the per-axis signs of a nonzero
  vector (cardinals keep a zero component), else returns `fx, fy`
  untouched — "keep facing where you last moved".
- `move.unit8(fx, fy)` turns a facing into an 8-way unit vector
  (diagonals scale by `DIAG`, cardinals pass through).

There are no acceleration/friction envelopes or response curves here —
platformer velocity handling like the demo's stays yours. The bundled
arcade demo (swarm) is the worked twin-stick example; the top-down demo
(cellar) feeds `dir` into `box.slide`.

## Drawing, cameras, and text (`cm.gfx`, `cm.text`)

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

## Animation clips and sprites (`cm.anim`, `cm.sprite`)

The sprite editor authors a layered `.spr` document and bakes it into a
horizontal `.png` strip plus two sidecars: `.anim` (the clip table) and
`.meta` (pivot + named slices). Games consume the baked output: the strip is
a normal texture, `cm.anim` picks the frame, `cm.sprite` reads the metadata.

`cm.anim` is a pure evaluator over (clip data, integer elapsed ticks) — no
state of its own, integer math only — so it is equally safe in sim and
render code. Load clips and choose a zero-based frame from sim time:

    local anim = cm.require("cm.anim")
    local clips = anim.load(cm.main.args.project .. "/art/hero.anim")
    local walk = anim.find(clips, "walk")
    local frame = walk and anim.frame_at(walk, state.frame()) or 0

Use that frame to select a source rectangle in `gfx.sprite`. Map placements
with an animation name do this automatically in `cm.map.draw_places`.

- A clip is `{ name, loop, frames = { { frame=, dur= }, ... } }` — `loop`
  is `"loop"`, `"once"`, or `"pingpong"`; `frame` indexes the baked strip
  (zero-based), `dur` is ticks at 60 Hz. `anim.duration(clip)` is one
  forward play-through in ticks; "pingpong" bounces without holding the
  endpoints twice.
- Two timing anchors. **Cosmetic**: `elapsed = state.frame() - t0`
  recomputed each draw, nothing stored, never snapshotted. **Sim-bound**:
  the controller keeps its start frame in its own named buffer and calls
  the same evaluator. The studio's wall-clock preview never reaches sim.
- `anim.load(path)` reads the sidecar (nil on a missing/corrupt file);
  `anim.find(clips, name)` looks a clip up by name. Re-load on
  `cm.asset_epoch` if you want editor saves to show live — the bundled
  smoke project's player does exactly this.

`cm.sprite` at runtime is the metadata door (the authoring surface —
layers, fills, undo — belongs to the sprite window, and a `.spr` itself is
never sim state):

    local sprite = cm.require("cm.sprite")
    local meta = sprite.load_meta(cm.main.args.project .. "/art/hero.meta")
    local px = meta and meta.pivot.x or 0            -- in-game origin
    local hand = meta and sprite.find_slice(meta, "hand")  -- {name,x,y,w,h}

`sprite.load_meta(path)` returns `{ pivot = {x,y}, slices = {...} }` (nil on
any failure, so keep fallbacks); `sprite.find_slice(meta, name)` finds a
named slice rectangle — attachment points, hitboxes, trim rects.

## Loading and drawing a map (`cm.map`)

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

A map layer can carry per-layer PARALLAX factors (the map window's layer
panel, `par` — 1 = world speed, 0.5 = a half-speed backdrop, 0 =
screen-fixed). `draw_places` applies them for you: such layers draw
through their own `gfx.layer` depth, culled against the layer-effective
camera, and the world layer is restored afterwards. Parallax is
presentation only — colliders, markers, and named refs stay world-space,
so keep collider-carrying placements on world-speed layers.

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

## Moving against map collision (`cm.collide`)

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

## Tilemaps (`cm.tmap`)

A `.tm` is a pure-visual tile grid: square cells of `tile` px drawn from a
tileset `.spr` whose baked frames are the tiles — tile id N draws strip
frame N (1-based), cell 0 is empty. A tilemap carries no collision, ever;
collision is collider chains on the map like everything else.

The common path needs no code: place a `.tm` on a map layer in the map
window and `cm.map.draw_places` draws it — culled, batched, riding the
layer's parallax — with everything else. Reach for `cm.tmap` directly to
generate or edit grids from code:

    local tmap = cm.require("cm.tmap")
    local proj = cm.main.args.project

    local td = tmap.blank(60, 8, 16, proj .. "/art/tiles.spr")
    for tx = 0, 59 do
      tmap.set(td, tx, 6, 1)     -- lit ridge row
      tmap.set(td, tx, 7, 2)     -- mass below
    end
    pal.write_file(proj .. "/backdrop.tm", tmap.encode(td))

- The doc is `{ w, h, tile, tileset, cells }` (cells are row-major u16s in
  one string). `tmap.get(doc, tx, ty)` and `tmap.set(doc, tx, ty, id)` read
  and write cells — (0,0) is the top-left cell; out-of-range reads return 0
  and out-of-range writes are ignored.
- `tmap.blank(w, h, tile, tileset)` makes an all-empty doc;
  `tmap.encode(doc)` / `tmap.decode(bytes)` are the `.tm` codec;
  `tmap.save(doc, path)` publishes atomically. `tmap.resize(doc, nw, nh)`
  (anchored top-left: overlap survives, growth is empty) and
  `tmap.fill_rect(doc, tx0, ty0, tx1, ty1, id)` are the grid ops the
  tilemap window drives.
- `tmap.graybox(mapdoc)` rasterizes a map's free collider layer into a
  graybox tile doc over the stock tileset — instant visible geometry for a
  colliders-only room. The bundled demo autotiles its ground layers this
  way at build time.
- `tmap.draw(doc, tex, ox, oy, camx, camy [, r,g,b,a])` is the culled
  batched draw placements use; pass the tileset strip's texture id if you
  draw a grid yourself. Ids past the strip skip (a shrunken tileset
  degrades to holes, never errors).

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

## The camera (`cm.camera`)

A scrolling game wants a camera that eases after its target, respects the
room's edges, cuts on room swaps, and shakes on impact. `cm.camera` is that
math over a plain table you keep in `state.doc` — snapshots, traces, and
rewind carry it by construction, and extra fields on the table are yours.

    local camera = cm.require("cm.camera")

    function game.init()
      local d = state.doc
      d.cam = d.cam or camera.new()               -- view-sized, top-left x/y
      camera.bounds(d.cam, 0, 0, level.pw, level.ph)
      camera.center(d.cam, player.center())       -- the cut: no whip-pan
    end

    function game.step()
      local d = state.doc
      camera.tick(d.cam)                          -- ONCE per step: shake decay
      camera.follow(d.cam, px, py, { lerp = 0.1, lerp_y = 0.08, dead_y = 26 })
      if hit_spikes then camera.shake(d.cam, 3, 18) end
    end

    function game.draw()
      pal.begin_frame(...)
      local camx, camy = camera.apply(d.cam)      -- set gfx camera + shake
      gfx.layer(1)                                 -- then draw world layers
      ...
    end

The rules:

- `follow` eases the view **center** toward the point: per-axis
  `lerp`/`lerp_y` (default 1 = snap) over the error beyond the per-axis
  deadzone `dead`/`dead_y` (default 0 — a plain lerp). `ox`/`oy` offset the
  target; for facing lookahead, smooth a field yourself and pass it:
  `d.cam.look = m.lerp(d.cam.look or 0, facing * 26, 0.05)` then
  `{ ox = d.cam.look }` — the bundled demo does exactly this.
- Every motion door ends clamped to `bounds`; a room smaller than the view
  centers instead of jittering. `center` is the cut — use it at init, room
  swaps, and anywhere a follow would whip-pan. Clearing: `camera.bounds(c)`.
- `shake(c, mag, frames)` arms integer counters in the table; `tick` counts
  them down. The wobble itself is render-only math off the counters
  (`offset`/`apply`), fading linearly — sim logic must never read it.
- `to_world`/`to_screen` convert through the **unshaken** camera, so mouse
  aim stays deterministic while the view wobbles.
- Pixel-art projects: `gfx.pixel_snap(true)` still owns the whole-pixel
  rasterization policy; the camera stays sub-pixel smooth underneath.

The bundled platformer demo is the worked example (its whole hand-rolled
camera collapsed into `follow`/`center`/`shake`). Zones/rails, dual-target
framing, zoom, and smooth room pans are deliberately absent for now.

## Juice: hit pause, flashes, and eased effects (`cm.tween`)

Game feel is mostly short decaying counters: freeze the world for two
frames on a hit, wash the screen red for a quarter second on death, shake
on impact, squash on landing. `cm.tween` keeps those as **named effects**
on any plain doc table — an integer frame countdown that remembers its
lifetime — and gives you the eased draw math so you never hand-tune
`alpha = counter / 14 * 0.55` again.

    local tween = cm.require("cm.tween")

    -- arm effects when things happen (in step):
    tween.play(d, "pause", 2)             -- 2-frame hit pause
    tween.play(d, "shake", 6, 2.4)        -- 6 frames, peak 2.4 px
    tween.play(d, "flash", 14, 0.55)      -- 14 frames, peak alpha 0.55

    function game.step()
      local d = state.doc
      tween.tick(d)                       -- ONCE per step, top of step
      if tween.on(d, "pause") then return end   -- world frozen, juice runs
      ...                                 -- the real sim
    end

    function game.draw()
      local d = state.doc
      local sx, sy = tween.wobble(d, "shake")   -- render-only offset pair
      ...draw everything at +sx, +sy...
      local a = tween.val(d, "flash")           -- 0.55 fading to 0
      if a > 0 then pal.quad(0, 0, W, H, 0.9, 0.25, 0.25, a) end
    end

The rules:

- `play(o, name, frames [, mag])` arms (or **replaces**) an effect on
  `o.tw` — plain integers in the doc, so snapshots, traces, and rewind
  carry every running effect by construction. `mag` is the stored strength
  `val`/`wobble` default to. `stop`/`clear` end effects early (put `clear`
  in your reset/room-swap path).
- `tick(o)` once per step at the top. An effect stays present for exactly
  `frames` post-tick steps, so `if tween.on(d, "pause") then return end`
  after `tick` is the whole hit-pause idiom — the tween table keeps
  ticking through its own freeze, and skipping your world's
  `actor.tick(w)` freezes actor timers for free.
- `k(o, name)` is the remaining fraction (1 at the armed frame's draw, 0
  when done); `val(o, name [, curve])` is `mag * curve(k)` with any
  `cm.ease` curve **by name** (`"cubic_out"` — names live happily in doc);
  `mix(o, name, from, to [, curve])` eases between explicit endpoints
  (slide-ins: `mix(d, "slide", -40, 0, "cubic_out")`). All pure math off
  the counters — deterministic anywhere.
- `wobble(o, name)` is the screen-shake offset pair (amplitude `mag * k`,
  the same idiom as `camera.offset` for screens without a camera). Like
  the camera's shake, it is presentation: sim logic must never read it.
- `bob(frame, period, amp)` is the pure looping wobble for item bobs and
  breathing idles: `tween.bob(state.frame(), 90, 2)` in draw.

The bundled arcade demo (swarm) is the worked example — its hit pause /
shake / death flash triple is three `play` calls, one `tick`, and two
draw lines. Sequences/chains, auto-writing field tweens, callbacks, and
springs are deliberately absent for now.

## Depth sorting (`cm.depth`)

Top-down games draw by feet position: things lower on the screen draw
later, in front. `cm.depth` is the stable draw-order sort that pattern
hand-rolls — push an explicit sort key (usually the base/feet y) with
your own item, sort, walk back-to-front:

    local depth = cm.require("cm.depth")

    -- in draw, after the floor/flat layers:
    local dl = depth.list()
    for _, p in ipairs(room.pillars) do
      depth.push(dl, p.y + PILLAR_BASE, p)   -- key = the base line
    end
    depth.push(dl, d.y + PLAYER_H, "player") -- items can be anything
    depth.sort(dl)
    for _, item in depth.each(dl) do
      if item == "player" then draw_player(d) else draw_pillar(item) end
    end

- The sort is **stable and total**: ascending by key, and equal keys keep
  push order (pushed later draws later, on top). Ordering is explicit
  data, never table/hash order, so drawing stays deterministic.
- Items pass through untouched — actor tables, static prop tables, or a
  plain string tag all work. `each` also yields the key as a third value.
- Reuse a list across frames with `depth.clear(dl)` if you prefer (the
  `box.hits` pattern); a fresh `depth.list()` per draw is fine too.
- Already have an array of tables carrying a `y`? `depth.ysort(items)`
  is the one-liner: a stable in-place ascending sort (pass a field name
  to sort by something else, e.g. `depth.ysort(props, "base")`).

This is within-layer ordering. Parallax and screen-fixed layers are
`gfx.layer` (and per-map-layer `par` factors in the map window); the
bundled top-down demo (cellar) is the worked example.

## HUD text and button prompts (`cm.hud`)

Every HUD hand-rolls the same two blocks: margin/centering arithmetic
against `pal.gfx_size()`, and the "name the button on the device the
player is actually holding" dance. `cm.hud` is both, render-only:

    local hud = cm.require("cm.hud")

    -- in draw: nine anchors — "tl" "t" "tr" / "l" "c" "r" / "bl" "b" "br".
    -- dx/dy inset INWARD from the named edges; centering is automatic.
    hud.text("t", 0, 3, title, { r = 1, g = 0.92, b = 0.7 })      -- top center
    hud.text("tl", 4, 3, "coins " .. n, { r = 1, g = 0.9, b = 0.4 })
    hud.text("bl", 4, 2, "walk into a door")                       -- bottom left
    hud.text("c", 0, 0, "GAME OVER\n" .. hud.label("fire") .. " restarts")

- `hud.text(anchor, dx, dy, str, opts)` draws through `cm.text` (same
  `font`/`r`/`g`/`b`/`a` opts). On a centered axis `dx`/`dy` are plain
  signed shifts. Multi-line strings place as one measured block with each
  line aligned to the anchor's side; the call returns the block's
  resolved top-left for badges drawn relative to it.
- `hud.label(action)` is the live binding label flavored for the device
  in hand — pad names while pad 1 is connected, else key names. Rebinds
  show through automatically (it is `input.label(action, kind)` with the
  kind chosen for you).
- `hud.place(anchor, dx, dy, tw, th, w, h)` is the bare anchor math over
  any box when you need to place quads, bars, or icons the same way.

Everything is draw-time presentation: nothing touches `state.doc`, so
use it freely in `draw` without determinism concerns. There is no
menu/dialogue kit yet — a pause screen is a `d.paused` flag, an early
`return` in `tick`, and a `hud.text("c", ...)` overlay.

## Palettes and color grading (`cm.palette`, `cm.grade`)

`cm.palette` reads `.pal` palettes — the color window authors them, stock
ones ship in `engine/stock/pal/` — and `cm.grade` is the render-only mood
pass: brightness/contrast/saturation/tint over the finished game composite,
so each room gets a distinct look without touching the art. The bundled
demo's per-room sky + warm/cool rooms are the pattern:

    local palette = cm.require("cm.palette")
    local paint = cm.require("cm.paint")
    local grade = cm.require("cm.grade")

    local sky = palette.load("engine/stock/pal/ember-8.pal")

    function game.draw()
      local r, g, b = paint.unpack(sky.colors[6])
      gfx.layer(0)
      pal.quad(0, 0, 480, 270, r / 255, g / 255, b / 255, 1)
      grade.preset("warm")   -- every frame; the grade resets each frame
      -- ... the rest of the scene ...
    end

- `palette.load(path)` returns `{ name, colors }` — colors are
  `cm.paint`-packed rgba, so `paint.unpack` yields 0..255 channels — cached
  against the asset epoch (an editor save shows live), nil if unreadable.
  `palette.color(path, i, fallback)` fetches one color with a fallback.
  The canvas eyedropper samples palette-window swatches directly, so a
  palette is also a live picking surface while you paint.
- `grade.set{ brightness=, contrast=, saturation=, tint={r,g,b} }` applies
  this frame's grade (all fields optional, identity defaults);
  `grade.preset(name)` picks a named mood — `warm`, `cool`, `dusk`,
  `night`, `noir`, `dream`; `"none"`/unknown = off — and `grade.off()`
  clears. The grade is presentation only, never sim: the sim cannot read
  it, `--verify` ignores it, and like the camera it resets every frame —
  set it each frame you want it.

## Sound effects and music (`cm.snd`, `cm.ins`)

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

## The options menu (`cm.options`)

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

## Player saves (`cm.save`)

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

## Recipe: a puzzle or board game

Puzzles need no module the engine does not already ship — a board game is
a plain doc table, pressed edges, and pure functions. The whole shape:

    local state = cm.require("cm.state")
    local input = cm.require("cm.input")
    local hud   = cm.require("cm.hud")
    local rand  = cm.require("cm.rand")

    local COLS, ROWS, CELL = 8, 8, 18

    local function idx(x, y) return (y - 1) * COLS + x end

    function game.init()
      input.map({ { "left", input.key.left, "pad:dpleft" },
                  { "right", input.key.right, "pad:dpright" },
                  { "up", input.key.up, "pad:dpup" },
                  { "down", input.key.down, "pad:dpdown" },
                  { "act", input.key.space, "pad:south" } })
      local d = state.doc
      if d.grid == nil then
        d.grid = {}
        for i = 1, COLS * ROWS do d.grid[i] = rand.range(1, 4) end
        d.cx, d.cy = 1, 1
        d.moves = 0
      end
    end

- **The board is one flat doc array** of numbers or short strings
  (`d.grid[idx(x, y)]`), so every rule is a pure read over it and
  snapshots, traces, and rewind carry the whole game by construction.
  One array, not nested tables — cheaper for the recorder, and `ipairs`
  order is your iteration contract.
- **A turn is a pressed edge.** In `step`, `input.pressed("left")` moves
  the cursor; `input.pressed("act")` applies ONE board mutation, then a
  pure scan decides matches/wins. Between presses nothing in doc changes,
  and unchanged frames cost the recorder nothing — turn-based games sit
  about as far inside the performance envelope as it is possible to sit.
- **Undo is a doc list.** Push the reverse of each move (or a small copy
  of what changed) onto `d.undo` and pop it on the undo action — it
  rewinds with everything else. While developing you also get the
  editor's whole-timeline scrub for free.
- **Place the board with `hud.place`.** With `W, H = pal.gfx_size()`,
  `hud.place("c", 0, 0, COLS * CELL, ROWS * CELL, W, H)` returns the
  centered top-left; cell to pixel is `ox + (x - 1) * CELL`. Mouse
  picking is the same line inverted over `input.mouse()` — floor-divide,
  then bounds-check.
- **Deals and shuffles use `cm.rand`**, so a shuffled board replays
  bit-for-bit. Slide/pop/land flourishes are `cm.tween` effects — the
  authoritative grid snaps instantly in doc; only the drawing eases.
- **Progress goes through `cm.save`** (best times, solved levels), with
  the same boot-load shape as any other game.

There is no dedicated grid/match module, and deliberately so: every
puzzle's rules differ, and the shared parts — state, edges, anchoring,
undo, randomness — are already the modules above. The one genre this
recipe does not cover is real-time board juice like falling-block chains;
`cm.tween` plus an actor world covers what the bundled demos needed.

## Deterministic randomness, math, and easing (`cm.rand`, `cm.math`, `cm.ease`)

`math.random` and the libm trig functions are banned in sim code — they
differ across platforms and break bit-exact replay. These three modules are
the sim-safe replacements.

    local rand = cm.require("cm.rand")
    local m = cm.require("cm.math")
    local ease = cm.require("cm.ease")

    function game.init()
      rand.ensure_seeded(7)               -- seeds only a virgin state
    end

    local roll = rand.range(1, 6)          -- uniform integer, inclusive
    local bob = m.sin(t * m.tau * 0.25)    -- bit-stable trig
    local x = ease.mix(x0, x1, t, "cubic_out")

- `cm.rand` is the engine PRNG (xoshiro256++). Its state lives in the
  `cm.sim` named buffer, so the stream position snapshots, rewinds, and
  replays with everything else. `rand.seed(n)` seeds unconditionally;
  `rand.ensure_seeded(n)` seeds only an untouched state (a restored
  snapshot keeps its position — usually what `init` wants). Draws:
  `rand.float()` uniform in [0, 1), `rand.range(m, n)` uniform inclusive
  integer (unbiased; `range(n)` means [1, n]), `rand.pick(t)` a uniform
  element of a non-empty array, `rand.u64()` the raw 64-bit draw.
- `cm.math` is deterministic transcendentals — `m.sin`/`m.cos`/`m.tan`/
  `m.asin`/`m.acos`/`m.atan`/`m.atan2`/`m.exp2` built from exact IEEE
  arithmetic (fdlibm kernels), identical on every platform — plus
  `m.clamp(x, lo, hi)`, `m.round`, `m.lerp(a, b, t)`, the constants
  `m.pi`/`m.tau`, and exact stock re-exports (`sqrt`, `floor`, `ceil`,
  `abs`, `min`, `max`, `fmod` — these are already sim-safe from `math`).
  Trig arguments must stay within about a million radians: keep
  accumulated angles wrapped, or the call errors loudly rather than
  silently losing accuracy.
- `cm.ease` is the easing-curve registry: `linear` plus the `quad`,
  `cubic`, `quart`, `quint`, `sine`, `expo`, `circ`, `back`, `elastic`,
  and `bounce` families, each as `_in`/`_out`/`_inout`. Curves are
  addressed **by name** — names live happily in doc, and `ease.get(name)`
  resolves at use time — and every curve is endpoint-pinned (f(0)=0,
  f(1)=1 exactly), so eased values land precisely on their targets.
  `ease.mix(a, b, t, curve)` is eased interpolation with t clamped;
  `ease.register(name, fn)` adds a game-defined curve (the registering
  code travels in snapshots, so named curves replay exactly);
  `ease.names()` lists them sorted. Use out-curves for things that react
  to the player: snappy start, soft landing.

## Making a 3D game (the retro pipeline)

Everything above is the 2D path. cosmic2d also ships a fixed
**retro-3D pipeline** — an N64/PS1/Ragnarok-Online-flavored triangle renderer with a
handful of Lua modules on top. If you are making a 2D game you can skip to
[the performance envelope](#the-performance-envelope); nothing below is
needed. If you want 3D, this is the whole supported surface, and it mirrors
the 2D engine exactly:

- **The sim never sees pixels or geometry.** Simulation state (player,
  entities, camera angles) lives in `state.doc` and named buffers as
  always; `draw` derives triangles from it every frame and hands them to
  the PAL. Determinism, rewind, traces, and goldens work identically — 3D
  is just a different `draw`.
- **Geometry is CPU-built and re-submitted every frame.** There is no
  retained GPU scene: you fill a vertex buffer (24 bytes/vert) and call
  `pal.x_tris`, the 3D sibling of `pal.quad`. Static worlds bake their
  vertices into a buffer once; characters rebuild theirs per frame.
- **Lighting and matrices are Lua policy.** Vertex colors arrive at the PAL
  already lit (`col * (ambient + sun term)`); the PAL is a dumb triangle
  consumer. `cm.m4` builds the camera matrix; `cm.gb`/`cm.terr`/`cm.fig`
  build and light the vertices.
- **Two presets, chosen by presentation knobs, not engine forks.** The
  **N64 preset** (soft VI upscale + 5-bit dither) and the **RO preset**
  (sharp, steep camera, billboard sprites) are the same renderer with
  different `pal.x_grade`/`pal.x_soft` settings and camera policy.

Bytes are lazy: a project that never calls `pal.x_view3d` produces a frame
byte-identical to a pure-2D build. The pipeline needs a PAL that provides
the 3D primitives (**API >= 20**; relative-mouse look needs 21, the
baked-figure fast path 22); engine code checks and refuses loudly on an
older PAL.

The bundled 3D demos are the worked examples — read them the way you would
`projects/demo`: `projects/bounce` (an N64 platformer, the cube
protagonist), `projects/openworld` and `projects/bigworld` (open-world +
streaming), `projects/rovale` (the RO-style vale), and `projects/figure`
(the character showcase). They live in the engine dev tree, not the shipped
starter templates — references, not scaffolds. The 3D modules run on
procedural graybox art; the CC0 asset packs a few experiments reference are
gitignored (see `assets/README.md` for the re-fetch table — never assume
those files are present).

## 3D drawing primitives (`pal.x_*`)

Three PAL calls draw a 3D frame: set a camera, submit triangles, pick a
preset.

    local m4 = cm.require("cm.m4")

    function game.draw()
      pal.begin_frame(0.5, 0.7, 0.9, 1)            -- sky color

      -- one camera + fog setup for the triangles that follow
      local view = m4.lookat(ex, ey, ez, tx, ty, tz, 0, 1, 0)
      local proj = m4.persp(60, W / H, 0.1, 200)
      pal.x_view3d{
        mvp = m4.mul(proj, view),                  -- column-major proj*view
        fog_start = 40, fog_end = 110, fog = { 0.5, 0.7, 0.9 }, fog_on = true,
      }
      pal.x_tris(world.tex, world.vbuf, world.count, 0, 0)  -- a prebuilt world

      pal.x_grade{ quant = 5 }                      -- N64 preset: 5-bit dither
      pal.x_soft(1)                                 -- + VI bilinear/smear
    end

- `pal.x_view3d{ mvp=, fog_start=, fog_end=, fog={r,g,b}, fog_on= }` sets
  the camera and fog for every `pal.x_tris` that follows it. `mvp` is a flat
  16-number column-major `proj*view*model` (usually just `proj*view` — bake
  the model into your vertices). Call it again to change camera or fog
  mid-frame, up to 64 times (a sky pass, then the scene, then a HUD-space
  pass). **`pal.x_view3d()` with no argument** is identity + fog off: an NDC
  passthrough for a full-screen sky/gradient quad.
- `pal.x_tris(tex, buf, count [, off [, flags]])` draws `count` triangles
  from a named buffer — `3 × count` packed vertices of **24 bytes** each,
  `<fffffBBBB` = position `xyz` (f32), texcoord `uv` (f32), color `rgba`
  (u8×4). `tex` is a `gfx`/`gb` texture id; `off` is a byte offset (draw
  sub-ranges of one big buffer); `flags` bit 1 = alpha-test cutout, 2 =
  nearest filtering (default is three-point), 4 = alpha blend with no depth
  write (decals/shadows, drawn last). Colors are **pre-lit** — the PAL does
  no lighting.
- `pal.x_grade{ quant = bits }` and `pal.x_soft(on)` are the retro
  presentation knobs (both render-only, both reset every `begin_frame`, so
  set them each frame you want them). `quant` posterizes to N bits/channel
  with a Bayer dither (`quant = 5` is the classic 5551 framebuffer);
  `x_soft` is the N64 preset's bilinear-upscale-plus-horizontal-smear. The
  RO preset runs `quant = 5` with `soft` off (sharp pixels suit pixel-art
  sprites). `x_grade` bakes into the internal target, so screenshots and
  pixel goldens include it; `x_soft` is a present-blit effect only.

**Filling the buffer.** The `cm.gb`/`cm.terr`/`cm.fig` emitters below append
packed vertex strings to a plain Lua array; concatenate it into a named
buffer once and submit:

    local out = {}
    local n = gb.gbox(out, root, { 1, 1, 1 }, { 0, 0, 0 }, { 0.8, 0.4, 0.3 })
    dyn:setstr(0, table.concat(out))     -- dyn = pal.buf("rc.mygame.dyn", cap)
    pal.x_tris(0, dyn, n, 0, 0)

A per-frame vertex buffer is **render-class** — nothing the sim reads — so
name it with the **`rc.`** prefix (`rc.mygame.dyn`). Buffers named `rc.*`
are excluded from snapshots and traces exactly like the editor's `ed.*`
buffers, which is what keeps a huge streaming world or a rebuilt-every-frame
character out of your recordings. Never read an `rc.*` buffer from `step`.

**Relative-mouse look.** For mouselook, declare the capture wish (once, in
`game.init`) and read the recorded delta:

    local input = cm.require("cm.input")
    input.capture_mouse(true)              -- the WISH: this game wants the cursor
    local dx, dy = input.mouse_rel()       -- recorded game-px delta, sim-legal

`capture_mouse(true)` never grabs the cursor by itself — it declares that
your game wants it, and the engine grants the actual OS capture only while
play owns the screen: in the player, whenever the Esc menu is closed; in
the editor, only while your game window is focused (Esc releases, and the
PLAYING chip says so). Opening the Esc menu, a crash, or time travel
releases it automatically, and the standing wish re-captures by itself
afterward — you never manage the OS state.

`input.mouse_rel()` is part of the input recording (the MREL extension), so
using it in `step` stays deterministic and replays exactly. The capture
*state* (`pal.x_mouse_capture`) is live-side chrome — headless runs stay
uncaptured, and sim logic must branch on `mouse_rel()`, never on whether the
cursor is captured.

**The live target size.** The editor's game window (and the player's resize
ladder) can change the FOV while the game runs. Read the size through the
recording, never the live target:

    local W, H = input.game_size()   -- recorded, sim-legal (FSIZ)

Refresh it at the top of `step` and `draw` and use it for the projection
aspect and any screen-to-world unprojection (pick rays) — the bundled 3D
demos do exactly this, so a widened window widens their view instead of
squashing it. It rides the input record like `mouse_rel`: a replay sees the
recorded sizes, an older recording reads the project's design resolution,
and `pal.gfx_size()` in `step` remains the determinism trap it always was.

## Matrices (`cm.m4`)

`cm.m4` is column-major 4×4 matrix math for building the camera `mvp` and
transforming vertices on the CPU. It uses `cm.math` trig, so it is
bit-stable (though matrices usually live in `draw`). Every function returns
a fresh flat 16-number array (or, for `apply`, three numbers).

    local m4 = cm.require("cm.m4")

    local view = m4.lookat(ex, ey, ez, tx, ty, tz, 0, 1, 0)  -- eye, target, up
    local proj = m4.persp(60, W / H, 0.1, 200)               -- fovy in DEGREES
    local mvp  = m4.mul(proj, view)

    local root = m4.mul(m4.translate(x, y, z), m4.roty(yaw)) -- a model transform
    local wx, wy, wz = m4.apply(root, lx, ly, lz)            -- transform a point

- Builders: `m4.ident()`, `m4.translate(x,y,z)`, `m4.scale(x,y,z)`,
  `m4.rotx(a)`/`m4.roty(a)`/`m4.rotz(a)` (radians),
  `m4.lookat(ex,ey,ez, ax,ay,az, ux,uy,uz)`, and
  `m4.persp(fovy_deg, aspect, znear, zfar)` (fovy
  is in **degrees**). `m4.mul(a, b)` composes (a·b).
- `m4.apply(t, x,y,z)` transforms a **point** (with translation) → `x,y,z`;
  `m4.applydir(t, x,y,z)` transforms a **direction** (no translation, for
  normals under rigid transforms). The convention matches the reference
  software rasterizer, GL-style clip z.

## Graybox meshes, textures, and baked figures (`cm.gb`)

`cm.gb` is the "graybox" mesh library: procedural material-checker textures
plus pre-lit triangle emitters for boxes, prisms, lathes, and balls — a
shape vocabulary that escapes axis-aligned boxes without a modeling tool. It
lights every vertex as `col * (ambient + max(0, -N·sun))` using its
`gb.sun`/`gb.ambient` fields (overwrite them to relight a scene).

    local gb = cm.require("cm.gb")

    function game.init()
      -- six 64x64 material checkers (grass/stone/wood/dirt/metal/accent) + a
      -- shadow blob; ids kept in an rc. buffer across hot reloads
      tex = gb.load_textures("rc.mygame.texids")
    end

    -- in draw: append geometry, then submit
    local out, n = {}, 0
    n = n + gb.gbox(out, root, { 1, 2, 0.5 }, { 0, 1, 0 }, { 0.7, 0.5, 0.3 })
    n = n + gb.prism(out, m4.translate(4, 0, 0), 6, 0.5, 0.34, 1.0,
                     { 0.6, 0.6, 0.7 }, 3)         -- hexagonal post, both caps
    dyn:setstr(0, table.concat(out))
    pal.x_tris(tex.stone, dyn, n, 0, 0)

- Textures: `gb.load_textures(idbuf_name)` (re)creates the six 64x64 material
  checkers + a shadow blob, returning a name → texture id table
  (`grass/stone/wood/dirt/metal/accent/shadow`). It frees the previous generation's ids
  (kept in the `rc.` buffer you name) first, so it is hot-reload safe.
- Low-level: `gb.vert(x,y,z, u,v, col, nx,ny,nz [,alpha])` packs one lit
  24-byte vertex; `gb.quad(out, a,b,c,d, col, nx,ny,nz [,alpha])` and
  `gb.tri(out, a,b,c, col, nx,ny,nz [,alpha])` append a quad/tri from
  `{x,y,z,u,v}` corner tables with one shared normal.
- Shape emitters append packed strings to `out` and return the triangle
  count: `gb.gbox(out, xf, size, center, col [, uvs [, rot]])`,
  `gb.prism(out, xf, n, r0, r1, h, col [, caps [, nrmxf]])` (an extruded
  n-gon; `caps` bit 0 = top, bit 1 = bottom),
  `gb.lathe(out, xf, prof, n, col [, alpha [, nrmxf]])`
  (revolves a flat `{r,y, r,y, …}` profile around
  Y), and `gb.ball(out, xf, R, n, col [, alpha [, nrmxf]])`. `xf` is an `m4`
  (or `nil` for identity); `uvs` scales texel density.

**Baked figures** are the fast path for geometry you re-emit every frame
(characters). Record a shape's local vertex stream once, then transform +
light + pack it per frame — in C when the PAL supports it:

    local bk = gb.bake_prism(6, 0.5, 0.34, 1.0, 3)  -- once: record local space
    n = n + gb.emit_baked(out, xf, nxf, bk, { 0.6, 0.6, 0.7 })  -- per frame

`gb.bake_gbox(size, center [, uvs])`, `gb.bake_prism(n, r0, r1, h [, caps])`,
`gb.bake_lathe(prof, n)`, and `gb.bake_ball(R, n)` return a bake
record (local vertices, in emit order).
`gb.emit_baked(out, xf, nxf, bk, col [, alpha])`
is the per-frame emitter: it uses `pal.x_figverts` (PAL 22) to
run the transform/light/pack loop in C — ~10× cheaper than the immediate
emitters and **byte-identical** to them — and falls back to Lua on an older
PAL. `cm.fig` drives this for you; reach for it directly only for your own
re-posed props. (`xf` carries position and any squash/scale; `nxf` is the
rigid transform for normals, so lighting ignores the squash.)

## Heightfield terrain (`cm.terr`)

`cm.terr` is the world surface: a grid of per-vertex heights that emits a
lit triangle mesh AND answers exact height queries, so
**one height grid is both what you see and what you walk on**.
The sim reads heights via
`terr.sample`; `draw` emits the mesh via `terr.emit`.

    local terr = cm.require("cm.terr")

    function game.init()
      local t = terr.build{ w = 64, h = 64, tile = 2.0 }    -- 64×64 tiles
      for vz = 0, 64 do for vx = 0, 64 do
        local nz = terr.vnoise(31, vx * 3, vz * 3, 64)       -- value noise
        terr.hset(t, vx, vz, nz * nz * 20 - 1)
      end end
      W.terr = t
    end

    function W.ground(x, z) return terr.sample(W.terr, x, z) end  -- sim query

    -- in draw:
    local n = terr.emit(out, W.terr, {
      bands = { { 2, { 0.3, 0.5, 0.2 } }, { 8, { 0.5, 0.45, 0.3 } } },
      sun = gb.sun, amb = gb.ambient,
    })

- `terr.build{ w=, h=, tile= }` allocates a `(w+1)×(h+1)` vertex grid (tile
  size default 2.0), heights zeroed; `terr.hget/hset(t, vx, vz [, v])` read
  and write vertex heights; `terr.size(t)` is the world extent.
- `terr.sample(t, wx, wz)` is the **triangle-exact** height at a world point
  — it matches the exact diagonal `terr.emit` triangulates, so an entity
  never floats or sinks against the visible ground. This is the sim query;
  feed it a walk grid or use it directly for ground glue.
- `terr.emit(out, t, opts)` appends the lit mesh and returns the tri count;
  `opts.bands` is a required ordered `{ upper_height, {r,g,b} }` color ramp,
  plus optional `jitter`, `seed`, `sun`, `amb`, `flat_y`, and `ox`/`oz`
  (lattice offset, for chunked worlds).
  `terr.emit_water(out, t, y, col, alpha [, step [, ox, oz]])` adds a
  flat water plane; `terr.load_detail(idbuf_name)` makes a neutral
  detail texture (id in an `rc.` buffer).
- `terr.vnoise(seed, x, y, cell)` and `terr.hash(seed, ix, iy)` are the
  deterministic noise primitives for procedural heights. For a **streaming**
  world with no stored grid, `terr.sample_fn(hfn, tile, wx, wz)` samples the
  same triangle-exact surface from a pure `hfn(vx, vz)` height function — the
  sim stands anywhere in an unbounded world with zero resident terrain state
  (the `bigworld` demo).

## The terrain texture atlas (`cm.atlas`)

The RO look bakes a **unique texture per terrain tile** (organic blended
borders, baked shadow) into one big atlas so the whole map draws in one
call. `cm.atlas` owns that atlas: its layout, a budgeted bake loop, and the
gutter trick that stops filtering from seaming at tile edges. It is entirely
render-class — pixels and progress live in `rc.` buffers, the sim never
touches it.

    local atlas = cm.require("cm.atlas")

    W.atlas = atlas.build{
      pixels = "rc.mygame.atlas", state = "rc.mygame.bake",
      n = 32, tile = 2.0, stamp = 1,               -- 32×32 tiles
    }

    -- in draw: bake a few tiles per frame until done
    local frac = atlas.bake(W.atlas, 24, function(wx, wz)
      return material_rgb(wx, wz)          -- your policy: 0..255 per channel
    end)
    local u0, v0, u1, v1 = atlas.uv(W.atlas, tx, tz)  -- tile UVs for the mesh

- `atlas.build(o)` creates the atlas texture and returns a handle (`o`:
  `pixels`/`state` rc. buffer names, `n` tiles per side or `w`×`h`, `tile`
  world units, `cell` interior texels [32], `gutter` [1], `fill`, `stamp`).
  You own `handle.tex` — register it for freeing.
- `atlas.bake(a, budget, texel)` bakes up to `budget` tiles this frame and
  returns the done fraction 0..1; `texel(wx, wz) -> r, g, b` (0..255) is your
  per-texel material policy. It uploads to the GPU once on completion. Call
  it from `draw`. `atlas.done(a)` tests completion, `atlas.rebake(a)`
  restarts, `atlas.uv(a, tx, tz)` gives the interior UV rect the terrain mesh
  must share.

Because the whole bake is a budgeted render-class pass, a golden trace
replays byte-identically whatever `budget` you pass — the sim reads only
`terr.sample` and the walk grid, never the atlas.

## Figures — rigid-part characters (`cm.fig`)

A **figure** is a character built the SM64 way: a tree of rigid parts (no
skinning), each a `cm.gb` primitive, posed by per-joint euler rotations and
lerped keyframes. `cm.fig` compiles a figure definition and emits its posed
geometry.

    local fig = cm.require("cm.fig")

    local guy = fig.build{ parts = {
      { name = "pelvis", joint = { 0, 0.95, 0 }, shapes = {
        { kind = "gbox", size = { 0.44, 0.28, 0.30 }, col = { 0.3, 0.3, 0.4 } } } },
      { name = "torso", parent = "pelvis", joint = { 0, 0.20, 0 }, shapes = {
        { kind = "gbox", size = { 0.52, 0.50, 0.34 }, col = { 0.7, 0.3, 0.3 } } } },
      -- … arms, legs, head parented onward …
    } }

    local walk = { pose_a, pose_b, pose_c, pose_d }   -- a clip = a list of poses

    -- in draw: pick a pose from sim time, emit under a root transform
    local pose = fig.cycle(walk, state.frame() / 40 % 1)
    local root = m4.mul(m4.translate(x, y, z), m4.roty(yaw))
    n = n + fig.emit(out, guy, root, pose)

- `fig.build(def)` compiles `def.parts` (tree order, parents before
  children) into a figure. Each part has a `name`, optional `parent`, a
  `joint` offset `{x,y,z}`, and `shapes` — each shape a `kind` of `"gbox"` /
  `"prism"` / `"lathe"` / `"ball"` with that primitive's params, a `col`,
  and optional `at`/`scale`/`alpha`.
- A **pose** is a sparse `{ [part_name] = {rx,ry,rz, tx,ty,tz, sx,sy,sz} }`
  (rotation Ry·Rx·Rz; translation for floating parts; scale for squash,
  which deforms positions but never lighting). `fig.mix(a, b, t)` lerps two
  poses; `fig.cycle(keys, t)` lerps around a clip (a list of poses) at phase
  `t` wrapped to 0..1.
- `fig.emit(out, fig, root, pose [, alpha])` appends the posed, lit geometry
  to `out` (via `cm.gb`'s baked path) and returns the tri count. It does not
  call `pal.x_tris` — concatenate `out` and submit yourself, so several
  figures can batch into one buffer.

## The stock mascot (`cm.mascot`)

`cm.mascot` is the engine's ready-made character — the cosmic mascot (lathe
teardrop body, floating mitts and boots, antenna star) expressed as `cm.fig`
data, with idle/walk/swim/wave clips. Drop it in for a protagonist or an NPC
without authoring a figure.

    local mascot = cm.require("cm.mascot")

    local npc = mascot.build{ body = { 0.4, 0.7, 0.9 } }   -- a recolored variant

    -- in draw: a walk cycle
    local pose = fig.cycle(mascot.walk, state.frame() / 40 % 1)
    local root = m4.mul(m4.translate(x, y, z), m4.roty(yaw))
    n = n + fig.emit(out, mascot.fig, root, pose)

- `mascot.fig` is the prebuilt default figure; `mascot.build(over)` builds a
  color variant (override keys from `mascot.colors`: `body`, `belly`,
  `mitt`, `dark`, `white`, `star`).
- Clips: `mascot.idle`, `mascot.walk`, `mascot.swim`, `mascot.wave` — pose
  lists for `fig.cycle`.
- `mascot.pose(bob, lean, s, hl, hr, fl, fr, ant)` builds a pose from feel
  parameters (base bob/lean, body squash, per-limb offsets, antenna sway);
  `mascot.sq(s)` turns a squash amount into a volume-preserving scale triple.

## Figure sprite sheets (`cm.spr`)

`cm.spr` bakes any figure into an **8-direction sprite sheet** and draws it
as a camera-facing billboard — the RO path, and the "model once, use as 3D
or as a sprite" loop. The bake is a tiny deterministic rasterizer; the sheet
is cached as a committed `.spx` asset.

    local spr = cm.require("cm.spr")

    function P.init()
      -- 8 directions × these rows, rasterized once (or loaded from .spx)
      P.sheet = spr.bake(0, mascot.fig, {
        { mascot.idle, 0 },
        { mascot.walk, 0 }, { mascot.walk, 0.5 },
        { mascot.wave, 0 },
      }, force_bake)
    end

    -- in draw: pick the column for our facing seen from the camera, billboard it
    local col = spr.oct(facing, cam_yaw)
    n = n + spr.billboard(out, P.sheet, x, y, z, 3.0, col, anim_row, tint,
                          cam_yaw, cam_pitch)
    n = n + spr.decal(out, x, y + 0.03, z, 0.5, 0, 0, 0, 120)   -- blob shadow

- `spr.bake(slot, figure, rows, force)` rasterizes `figure` into a sheet (8
  columns 45° apart, one row per `{ clip, phase }` in `rows`) and returns
  `{ tex, rows, fv }`. It loads a cached `.spx` (`<project>/spr/sheetN.spx`)
  unless `force`. Cells are `spr.CW × spr.CH` (40×52); the sheet is
  `spr.DIRS` (8) columns wide.
- `spr.oct(face_ang, cam_yaw)` picks the sheet column (0..7) for a world
  facing seen from the camera yaw.
  `spr.billboard(out, sheet, x, y, z, h, col, row, tint, cam_yaw, cam_pitch)`
  emits a fully camera-facing quad (feet
  at `x,y,z`, height `h`, `tint` a grayscale ground-shadow factor) — draw
  with `x_tris` flags 3 (alpha-test + nearest).
  `spr.decal(out, x, y, z, r, rr, gg, bb, aa)`
  is a flat ground quad (blob shadow, click marker) — draw
  with flag 4.

## The camera rig (`cm.rig`)

`cm.rig` is the orbit-follow camera every 3D demo shares: it eases behind a
moving target, follows its facing, and takes mouse/key look. Because look is
camera-relative *input*, the rig is **sim state** — it owns the layout of a
caller-named f32 buffer but never allocates it, so you keep the buffer and
snapshots, traces, and rewind carry the camera by construction.

    local rig = cm.require("cm.rig")

    function game.init()
      cam = pal.buf("mygame.cam", rig.SIZE)                 -- 40 bytes
      d.knobs = d.knobs or rig.defaults()                  -- tunables in doc
      rig.reset(cam, d.knobs, px, py, pz, player_yaw)
    end

    function game.step()
      local wx, wz = rig.wish(cam, fwd_input, side_input)  -- camera-relative wish
      -- … player.step consumes wx,wz … then advance the rig behind the player:
      rig.step(cam, d.knobs, px, py, pz, vx, vz, player_yaw)
    end

    function game.draw()
      local view = rig.view(cam, d.knobs)                  -- the view matrix
      pal.x_view3d{ mvp = m4.mul(proj, view), fog_on = false }
    end

The `mygame.cam` buffer layout `cm.rig` owns (f32):

    [0]yaw [4]pitch [8]dist [12/16/20]focus xyz
    [24]manual-hold frames [28/32]prev cursor [36]recentering flag

- `rig.SIZE` (40) is the buffer size; `rig.defaults()` returns the knob
  table (orbit distance/height, follow lerps, mouse/key look rates, pitch
  clamps, recenter — keep it in `state.doc` so tuning rewinds).
  `rig.reset(cam, knobs, px, py, pz, target_yaw)` seeds it (init, respawn,
  room cut).
- `rig.step(cam, knobs, px, py, pz, vx, vz, target_yaw)` advances the orbit
  once per step **after** the target moves (fed its post-step position,
  horizontal velocity, and facing). `rig.wish(cam, fwd, side)` turns
  forward/side input into a camera-relative world vector for the player.
  `rig.view(cam, knobs)` derives the view matrix in `draw` (the camera
  *position* exists only here — render-class). `rig.angdiff(a, b)` is the
  shortest signed-arc helper.

## The player kernel (`cm.kin`)

`cm.kin` is the shared 3D character-movement core — ground collision, jump
with coyote/buffer, gravity, box-top landing and mantling, run
accel/friction, squash and lean. It is deliberately **value-based**: every
function takes values and returns values, allocating nothing. You own the
player buffer and its layout (they differ per game — platformer vs
open-world vs streaming — so no single owned layout fits, and a pure module
can never accidentally resize a persistent buffer mid-session).

    local kin = cm.require("cm.kin")

    -- in your player step, reading/writing your OWN player buffer:
    local vy, jbuf, coyote, grounded, evt =
      kin.jump(jbuf, coyote, grounded, jump_pressed, k.buffer, k.coyote, v0)
    vy = kin.gravity(vy, g_rise, k.fall_mul)
    -- swept clamp against a list of AABB boxes, one axis at a time:
    nx, vx, y = kin.slide(boxes, true,  nx, y, z, x, vx, hw, hh, mantle)
    nz, vz, y = kin.slide(boxes, false, x, y, nz, z, vz, hw, hh, mantle)

- Movement: `kin.run(vx, vz, yaw, wx, wz, speed, accel, fric, turn)`,
  `kin.gravity(vy, g_rise, fall_mul)`, `kin.jump(...)` (returns the new `vy`
  plus updated jump-buffer/coyote/grounded and a `"jump"`/`"paddle"` event),
  `kin.jump_curve(jump_h, apex_t) -> g_rise, v0`,
  `kin.approach(v, target, step)`, and
  `kin.lean(lean, hspeed, amount, speed)`.
- Collision (against a plain list of `{x0,y0,z0,x1,y1,z1}` boxes you build):
  `kin.overlaps(box, x, y, z, hw, hh)`,
  `kin.slide(list, xaxis, cx, cy, cz, p0, v, hw, hh [, mantle])`
  (one swept axis; returns the clamped axis
  position, the new velocity, and the new y), `kin.mantle_top(...)`,
  `kin.ground_top(list, g, x, y, z, hw)` (raise the ground to a box top —
  heightfield landing), and `kin.land_squash(vy, squash, vref, frames)`.
- `kin.EPS` (1e-3) is the shared epsilon. Because nothing here is stateful,
  the bundled `bounce`/`openworld`/`bigworld` players each keep their own
  buffer layout and call the same core — the module is pure math on your
  values.

## Pick rays and walk-grid pathing (`cm.walk`)

`cm.walk` is the click-to-move kernel: cast a screen ray onto the ground,
snap to a walk grid, A* a path, and follow the cell chain. (The name
`cm.pick` is taken by the project picker, so the 3D pick ray lives here as
`walk.raycast`.) The walker is a caller-named buffer whose layout `cm.walk`
owns.

    local walk = cm.require("cm.walk")

    -- pick: march a camera ray onto the terrain (ground(x,z)->height)
    local hx, hz = walk.raycast(world.ground, ex, ey, ez, kx, ky, kz)

    -- command: snap + A* + store the path into the walker buffer
    if hx and walk.command(buf, PATH_MAX, world.GW, world.walkable,
                           hx, hz, 4, marker_ttl) then … end

    -- follow: advance along the cell-center chain each step
    walk.step(buf, world.GW, k.speed, k.turn)

The walker buffer layout `cm.walk` owns (f32/u32, size `40 + path_max*4`):

    [0]x [4]z [8]facing [12]dist_phase  [16]u32 len [20]u32 idx
    [24/28]marker x/z [32]marker ttl   [40..] u32 path cell indices

- `walk.raycast(ground, ex, ey, ez, kx, ky, kz [, step, maxs, iters])`
  marches ray origin `(ex,ey,ez)` + direction `(kx,ky,kz)` against the
  caller's `ground(x, z) -> height`, returning the hit `x, z` (or nil). Build
  the ray from the sim camera so clicks replay deterministically.
- The grid is the caller's `(gw, walkable)` pair — `gw` cells per side and a
  `walkable(cx, cz) -> bool` predicate you derive once from slope/water/
  blockers. `walk.cell(gw, wx, wz)` maps world→cell,
  `walk.snap(gw, ok, cx, cz, r)` finds the nearest walkable cell, and
  `walk.astar(gw, ok, sx, sz, gx, gz)` is heap A* (8-way, no corner
  cutting) returning a cell-index list.
- `walk.command(buf, path_max, gw, walkable, wx, wz, snap_r, marker_ttl)`
  does snap+A* and writes the chain into the walker (returns whether a path
  exists); `walk.step(buf, gw, speed, turn)` follows it (eases facing, decays
  the destination marker); `walk.moving(buf)` is the done test.

## The performance envelope

The engine records everything, always: the rewind ring re-canonizes your
whole `state.doc` on every frame in which anything in it changed. That is
what makes rewind, traces, and crash replay free at the game-code level —
and it is the cost that sets the honest actor budget. Your own logic is
almost never the limit: `cm.actor` steps 8,000 chasers with overlap
queries in under 3 ms, but recording a doc that holds 8,000 moving tables
costs ~70 ms more. The measured envelope, from a swarm-shaped world
(every actor moving every frame, worst case) on the 2026 reference
desktop (Ryzen 9 5900X), Linux and native Windows within noise of each
other:

    moving doc actors   typical frame   spikes (p95/worst)   verdict
                  250         ~2.5 ms          4 /  6 ms     lots of headroom
                  500           ~5 ms          8 / 10 ms     comfortable
                1,000          ~10 ms         15 / 27 ms     the edge - occasional drops
                2,000          ~20 ms         27 / 37 ms     over the 16.7 ms budget

The supported alpha envelope is
**about 500 live, moving, doc-carried actors** — comfortable 60 Hz with
room left for your own logic and a real GPU frame. A thousand mostly
works but spends the whole budget on a slow machine. The bundled demos
sit far inside it (swarm's biggest waves are a few dozen actors).

What the cost actually tracks — and how to stay fast when you grow:

- **Total doc size, not motion.** If any field changes in a frame, that
  frame re-canonizes everything in doc (~9 µs per small table on the
  reference machine). One moving camera plus 5,000 parked actor tables
  still pays for 5,000 tables every frame. Keep doc holding what must
  rewind, not everything you ever computed.
- **Bulk numeric state belongs in named buffers.** A `pal.buf` records as
  a compact binary delta on the C side — thousands of particles or bullets
  in packed `f32`/`i16` slots cost a tiny fraction of the same data as
  doc tables, and they snapshot and rewind identically. Doc for dozens to
  hundreds of rich actors; buffers for thousands of simple ones. Past ~500
  rich `cm.actor` tables the answer is that shape, not more tables: the 3D
  `bigworld` demo streams ~4,000 entities as fixed-slot records in ONE
  named buffer (each just a route + a phase; far ones advance by closed-form
  catch-up, O(1) and exact, and only the handful near the player promote to
  a full interactive kernel).
- **Render-only flourish stays out of doc.** Sparks, floating numbers,
  and screen-shake offsets that decide nothing can live in module locals
  or derive from `cm.tween` counters — they cost the recorder nothing.
- **Memory scales the same way.** Every changed frame retains one canon
  copy of doc in the in-RAM ring; a huge doc mutating for minutes holds
  hundreds of megabytes of history. The buffer rules above are also the
  memory fix.

To measure your own game, open the F3 performance overlay while it runs
in the editor (it is disabled only in exported player builds): the "sim"
number includes the recorder, so the gap between it and what your own
`step` plausibly does is the recorder tax growing with your doc.

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

## Common failures

Most bugs here are determinism bugs — the simulation did something the recorder
could not reproduce. The symptom, the cause, and the fix:

- **A recording stops verifying, or a replay diverges.** You changed the
  simulation's shape: the order of `cm.input` actions, a named buffer's layout,
  or a project source (a code edit changes the recorded code bundle). Old
  recordings are against the old shape, so the mismatch is an honest divergence,
  not a crash. Keep action order and buffer layouts stable; when a change is
  deliberate, re-record the affected trace.

- **`--verify` crashes instead of reporting a divergence.** A project module
  written `local M = {}` split-brains when the bundle re-executes — the reloaded
  copy writes a table nobody reads. Adopt the loader's table instead:

      local M = select(2, ...) or {}

- **Collisions, spawns, or draws come out differently between runs.** Something
  gameplay-visible depends on hash-table `pairs` order. Iterate gameplay arrays
  with `ipairs`; `cm.actor` already gives actors stable, spawn-ordered ids.

- **Random numbers differ between machines or replays.** You used `math.random`
  or a wall clock. Use `cm.rand` for randomness and `cm.math` for simulation
  trig — both are seeded and deterministic.

- **The frame budget breaks as the world grows.** Per-frame history cost tracks
  total `state.doc` size, not motion — about
  **500 live, moving, doc-carried actors** is the supported alpha
  envelope. Move bulk numeric state into named
  buffers, keep flourish render-only, and watch the F3 gauge. See
  [the performance envelope](#the-performance-envelope).

- **A saved game did not travel with an export or a copy.** That is intended:
  `cm.save` keeps saves outside the project folder, so a shared game never
  carries anyone's progress. See [Player saves](#player-saves-cmsave).

- **A load behaves differently on replay.** Reading a save slot inside `step`
  and branching on it is a determinism bug. Read in `init` (filling only absent
  `state.doc` fields), or use `save.on_load` + `save.load(slot)` for a
  mid-session load — the recorder reproduces that without the file.

- **A background layer does not parallax.** Give the map layer `par_x`/`par_y`
  factors below `1`; parallax is presentation-only and never moves colliders.

## Compatibility policy

The engine is pre-1.0, so formats can still change before the alpha freeze — but
the rules that protect your project are already enforced, not merely promised
(the full stability contract is in `docs/ARCHITECTURE.md`):

- **Recordings replay forever.** Every golden trace committed to `tests/` must
  replay byte-exact on every future build; a change that breaks an old trace is
  by definition a bug. Your half of that contract is the determinism discipline
  above — stable action order and named-buffer layouts. Input capabilities grow
  additively: the relative-mouse deltas (`input.mouse_rel`) ride a new input-
  record extension (MREL) that old recordings replay as (0,0), and the live
  target size (`input.game_size`) rides another (FSIZ) that old recordings
  replay as the design resolution — so extending the input format never
  invalidates an old trace.

- **Formats are versioned, tagged-chunk containers.** Every chunk is
  version-stamped; a reader skips the chunks it does not know and errors loudly
  on truncation — it never guesses. Old files stay readable as a format grows.

- **The engine refuses loudly, never degrades silently.** Engine code checks the
  PAL API version (currently **22**) and function presence, and refuses with a
  clear "needs PAL api >= N" message rather than half-running. A newer engine on
  an older PAL still works whenever it needs no new primitive — the retro-3D
  pipeline needs >= 20, relative-mouse look >= 21, and the baked-figure fast
  path >= 22, each refusing loudly (or falling back) rather than half-running.

- **Saves migrate forward and refuse newer.** Bump `save.schema(n)` and describe
  each `save.migrate` step once: old saves upgrade on read, and a save from a
  newer version of your game is refused with a named error instead of being
  misread.

- **Base semantics are frozen** — little-endian data, IEEE-754 numbers, Lua 5.4,
  `buf:hash()` as fnv1a-64, SDL scancodes. Code and data written against them
  stay valid; new behavior arrives under a new name, never by redefining an old
  one.

## Small module reference

- `cm.state` — `doc`, `frame()`, snapshots, named-buffer helpers.
- `cm.input` — action map, keyboard/mouse state and edges.
- `cm.gfx` — camera/layers, PNG textures, sprite rectangles, pixel snap.
- `cm.text` — bitmap text drawing and measurement.
- `cm.map` / `cm.collide` — map assets, placements, markers, swept AABBs.
- `cm.box` — pure AABB overlap/queries and the lightweight wall slide.
- `cm.actor` — actor worlds in doc: stable ids, tags, spawn order, timers.
- `cm.camera` — follow/deadzone, bounds, room cuts, shake, world<->screen.
- `cm.tween` — named effect counters: hit pause, flashes, shake, eased decay.
- `cm.depth` — stable draw-order sorting: y-sorted draw lists, `ysort`.
- `cm.hud` — anchored HUD text and device-flavored binding labels.
- `cm.move` — stick+key movement vectors, 8-way facings, even diagonals.
- `cm.tmap` — decode/draw/edit tilemap grids.
- `cm.anim` / `cm.sprite` — animation sidecars and sprite source documents.
- `cm.snd` / `cm.ins` — deterministic music, voices, and instruments.
- `cm.options` — the Esc menu: game-declared settings, volume doors.
- `cm.save` — per-player save slots/profiles outside the project folder.
- `cm.palette` / `cm.grade` — palette data and render-only color grading.
- `cm.rand` / `cm.math` / `cm.ease` — deterministic helpers.

The 3D retro pipeline (see [Making a 3D game](#making-a-3d-game-the-retro-pipeline)):

- `cm.m4` — column-major 4×4 matrices for the camera mvp and vertex transforms.
- `cm.gb` — graybox meshes (box/prism/lathe/ball), material textures, baked figures.
- `cm.terr` — heightfield terrain: build, triangle-exact sample, emit, water.
- `cm.atlas` — the budgeted per-tile terrain-texture atlas (the RO bake).
- `cm.fig` — rigid-part figures: build, pose, cycle clips, emit.
- `cm.mascot` — the stock mascot figure and its idle/walk/swim/wave clips.
- `cm.spr` — bake a figure to an 8-way sprite sheet; billboards and decals.
- `cm.rig` — the orbit-follow camera rig (a sim buffer whose layout it owns).
- `cm.kin` — the value-based player kernel: collide, jump, gravity, mantle, squash.
- `cm.walk` — the pick ray + walk-grid A* + cell-chain follow (click-to-move).

Advanced format and determinism contracts live in `docs/ARCHITECTURE.md`,
`docs/MAPS.md`, and `docs/AUDIO.md`. For copyable game code, read
`projects/demo/main.lua`, `level.lua`, `player.lua`, and `audio.lua`.

Back to [Getting started](engine/stock/docs/getting-started.md) ·
[Using the editor](engine/stock/docs/editor.md)
