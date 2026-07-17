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

Advanced format and determinism contracts live in `docs/ARCHITECTURE.md`,
`docs/MAPS.md`, and `docs/AUDIO.md`. For copyable game code, read
`projects/demo/main.lua`, `level.lua`, `player.lua`, and `audio.lua`.

Back to [Getting started](engine/stock/docs/getting-started.md) ·
[Using the editor](engine/stock/docs/editor.md)
