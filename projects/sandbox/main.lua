-- sandbox main.lua — M3: the live-editable platformer sandbox (the stock
-- cartridge). A MapleStory-vocabulary character in a tile world with a
-- crate pit: run, jump (variable height), hop one-way planks, down+jump
-- through them, grab and throw crates, all under a knobbed follow camera
-- with parallax hills behind. Everything tunes live:
--
--   arrows           move (down+jump drops through planks)
--   space            jump (hold for height); again in mid-air: double jump
--   g                mid-air dive; any key cancels it (see player.lua)
--   e                grab nearest crate / throw it
--   `                console — poke doc.knobs.* live, game.demo(1)
--   f1               editor mode — paint the map, collider overlay (M4)
--   escape           quit
--
-- Module split: level (tiles + map + backdrop), player (controller),
-- props (crates), fx (particles), demo (attract script), pix (art helper).
-- Determinism: sim state in named buffers + doc tree only; randomness from
-- pt.rand; trig from pt.math; fixed dt (ARCHITECTURE "Determinism").

local m = pt.require("pt.math")
local state = pt.require("pt.state")
local input = pt.require("pt.input")
local text = pt.require("pt.text")
local gfx = pt.require("pt.gfx")
local level = pt.require("level")
local player = pt.require("player")
local props = pt.require("props")
local fx = pt.require("fx")
local demo = pt.require("demo")

local W, H = pal.gfx_size()

local game = {}
game.level = level -- console/editor evals reach the map: game.level.reset()

-- feel knobs, all live (doc tree -> snapshots, traces, console, M4 panels).
-- Merged key-by-key so docs from older sessions grow new knobs in place.
local KNOBS = {
  move = { accel = 1500, decel = 1800, air = 0.55, run = 130,
           gravity = 700, jump = 280, cut = 0.45, fall_max = 340,
           coyote = 6, buffer = 5 },
  dive = { speed = 270, vy = 50, grav = 0.55, cancel_vy = 150,
           cancel_slow = 0.45, boost = 400, boost_win = 9,
           slide_fric = 4.0, flip_t = 0.35 },
  dj = { speed = 255, buffer = 5, coyote = 6 },
  cam = { lerp = 0.10, lerp_y = 0.08, look = 26, look_lerp = 0.05,
          dead = 26 },
  throw = { vx = 260, vy = 200, inherit = 0.6, radius = 28 },
  prop = { rest = 0.3, wall_rest = 0.45, fric = 7.0 },
  fx = { gravity = 420, drag = 2.2, run_dist = 22 },
  feel = { squash = 0.55, squash_t = 0.16, stretch = 0.4, stretch_t = 0.12 },
}

local cam

function game.init()
  local d = state.doc
  d.knobs = d.knobs or {}
  for group, defaults in pairs(KNOBS) do
    d.knobs[group] = d.knobs[group] or {}
    for key, v in pairs(defaults) do
      if d.knobs[group][key] == nil then d.knobs[group][key] = v end
    end
  end
  if d.demo == nil then d.demo = 0 end
  if d.demo_t0 == nil then d.demo_t0 = 0 end

  fx.init()
  props.init()
  player.init()

  cam = pal.buf("sandbox.cam", 32)
  if cam:f32(0) == 0 and cam:f32(4) == 0 then -- virgin: snap to the player
    local px, py = player.center()
    cam:f32(0, m.clamp(px - W / 2, 0, level.tm.pw - W))
    cam:f32(4, m.clamp(py - H / 2, 0, level.tm.ph - H))
  end

  input.map({
    { "left", input.key.left },
    { "right", input.key.right },
    { "up", input.key.up },
    { "down", input.key.down },
    { "jump", input.key.space },
    { "grab", input.key.e },
    { "dive", input.key.g },
    { "quit", input.key.escape },
  })

  -- the M4 editor: what to paint, where the camera is, which boxes to
  -- outline. The getter runs once per editor frame and only reads.
  pt.editor.attach(function()
    return {
      tm = level.tm,
      atlas = level.tex,
      camx = cam:f32(0),
      camy = cam:f32(4),
      colliders = function()
        local px, py = player.pos()
        local list = { { x = px, y = py, w = player.W, h = player.H,
                         kind = "player" } }
        for i = 1, props.count() do
          local x, y, w, h = props.get(i)
          list[#list + 1] = { x = x, y = y, w = w, h = h,
                              kind = props.held(i) and "held" or "prop" }
        end
        return list
      end,
      save = level.save,
      reset_eval = "game.level.reset()",
    }
  end)
end

-- attract mode: game.demo(1) in the console (or --eval) hands the controls
-- to the demo script; any real action press takes them back
function game.demo(on)
  local d = state.doc
  if on == 1 or on == true then
    d.demo = 1
    d.demo_t0 = state.frame()
  else
    d.demo = 0
  end
end

local ACTIONS = { "left", "right", "up", "down", "jump", "grab", "dive" }

local function build_ctl()
  local d = state.doc
  if d.demo == 1 then
    for _, a in ipairs(ACTIONS) do
      if input.pressed(a) then
        game.demo(0)
        break
      end
    end
  end
  if d.demo == 1 then
    local rel = state.frame() - d.demo_t0
    local function dn(a) return demo.down(rel, a) end
    local function was(a) return demo.down(rel - 1, a) end
    local any = false
    for _, a in ipairs(ACTIONS) do
      if dn(a) and not was(a) then
        any = true
        break
      end
    end
    return {
      left = dn("left"), right = dn("right"),
      up = dn("up"), down = dn("down"),
      jump_pressed = dn("jump") and not was("jump"),
      jump_released = was("jump") and not dn("jump"),
      grab_pressed = dn("grab") and not was("grab"),
      dive_pressed = dn("dive") and not was("dive"),
      any_pressed = any,
    }
  end
  local any = false
  for _, a in ipairs(ACTIONS) do
    if input.pressed(a) then
      any = true
      break
    end
  end
  return {
    left = input.down("left"), right = input.down("right"),
    up = input.down("up"), down = input.down("down"),
    jump_pressed = input.pressed("jump"),
    jump_released = input.released("jump"),
    grab_pressed = input.pressed("grab"),
    dive_pressed = input.pressed("dive"),
    any_pressed = any,
  }
end

local function cam_step()
  local kc = state.doc.knobs.cam
  local px, py = player.center()
  local look = cam:f32(8)
  look = look + (player.facing() * kc.look - look) * kc.look_lerp
  local cx, cy = cam:f32(0), cam:f32(4)
  cx = cx + (px + look - W / 2 - cx) * kc.lerp
  local err = py - (cy + H / 2)
  if err > kc.dead then
    cy = cy + (err - kc.dead) * kc.lerp_y
  elseif err < -kc.dead then
    cy = cy + (err + kc.dead) * kc.lerp_y
  end
  cam:f32(0, m.clamp(cx, 0, level.tm.pw - W))
  cam:f32(4, m.clamp(cy, 0, level.tm.ph - H))
  cam:f32(8, look)
end

function game.step()
  if input.down("quit") then pal.quit() end
  local ctl = build_ctl()
  player.step(ctl)
  props.step()
  fx.step()
  cam_step()
end

function game.draw()
  pal.begin_frame(0.42, 0.58, 0.80, 1)
  local frame = state.frame()
  local camx, camy = cam:f32(0), cam:f32(4)
  gfx.camera(camx, camy)

  level.draw_bg(frame)

  gfx.layer(1)
  level.tm:draw(level.tex, camx, camy)
  props.draw()
  player.draw()
  fx.draw()

  gfx.layer(0)
  local rec = pt.trace and pt.trace.recording and pt.trace.recording()
  text.draw(3, 3, ("frame %d%s"):format(frame, rec and "  REC" or ""),
            { g = 0.95, b = 0.8, a = 0.9 })
  if state.doc.demo == 1 then
    local msg = "DEMO * press any key to play"
    local tw = text.measure(msg)
    text.draw((W - tw) // 2, 24, msg, { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  end
  text.draw(3, H - 11,
            "arrows * space jump x2 * g air dive (any key cancels) * e grab/throw",
            { r = 0.90, g = 0.88, b = 0.78, a = 0.9 })
end

return game
