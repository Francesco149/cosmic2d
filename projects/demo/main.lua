-- cosmic demo — the out-of-the-box game. Our M7 platformer moveset (the
-- shared player.lua) across TWO rooms joined by a portal, a handful of
-- sound effects, and music that SWAPS when you change rooms (cozy town
-- <-> adventurous overworld). Extract the engine, pick this, press play.
--
-- Controls: arrows move (down+jump drops through one-ways) · space jump /
-- flash-jump / up-jump · e hop (hold = flutter) · q grapple · r teleport ·
-- d slice. Walk into a portal door to travel; grab coins; the spikes bounce
-- you back to the start.
--
-- Determinism: sim state in named buffers (demo.*) + the doc tree; audio
-- is cm.snd (recorded). The moveset + collision are the engine's.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local gfx = cm.require("cm.gfx")
local level = cm.require("level")
local player = cm.require("player")
local fx = cm.require("fx")
local audio = cm.require("audio")

local W, H = pal.gfx_size()
local game = {}
game.level = level -- console/editor reach: game.level.reset("overworld")

-- the feel-approved M7 moveset defaults (verbatim from smoke's kit).
local KNOBS = {
  move = {
    cw = 12, ch = 18,
    walk_speed = 42, walk_accel = 640, ground_fric = 900,
    air_accel = 110, air_fric = 36,
    jump_h = 20, jump_apex_t = 21.3, fall_mul = 1.3, fall_max = 360,
    coyote = 6, buffer = 5, mantle = 4,
    fj_vx = 186, fj_vy = -52,
    upjump_h = 56,
    hop_vx = 120, hop_h = 18,
    flutter_interval = 30, flutter_boosts = 4, flutter_h = 11, flutter_vx = 30,
    hop_cd = 600,
    grapple_range_max = 244, grapple_range_min_pref = 120,
    grapple_extend = 270, grapple_accel = 720, grapple_vmax = 220,
    grapple_stop_ch = 2.0, grapple_min_t = 6, grapple_cd = 180,
    tp_dist = 60, tp_min_interval = 30,
    attack_interval = 6, attack_reach = 22,
  },
  cam = { lerp = 0.10, lerp_y = 0.08, look = 26, look_lerp = 0.05, dead = 26 },
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
  d.coins = d.coins or {}

  level.reset(d.room or "town")
  fx.init()
  player.init()
  audio.init()
  audio.bgm(level.current)

  cam = pal.buf("demo.cam", 32)
  if cam:f32(0) == 0 and cam:f32(4) == 0 then
    local px, py = player.center()
    cam:f32(0, m.clamp(px - W / 2, 0, level.pw - W))
    cam:f32(4, m.clamp(py - H / 2, 0, level.ph - H))
  end

  input.map({
    { "left", input.key.left }, { "right", input.key.right },
    { "up", input.key.up }, { "down", input.key.down },
    { "jump", input.key.space }, { "hop", input.key.e },
    { "grapple", input.key.q }, { "teleport", input.key.r },
    { "attack", input.key.d },
  })
end

local function build_ctl()
  return {
    left = input.down("left"), right = input.down("right"),
    up = input.down("up"), down = input.down("down"),
    jump_pressed = input.pressed("jump"), jump_held = input.down("jump"),
    hop_pressed = input.pressed("hop"), hop_held = input.down("hop"),
    grapple_pressed = input.pressed("grapple"),
    teleport_held = input.down("teleport"),
    attack_held = input.down("attack"),
  }
end

local function overlap(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end

local function enter_room(room)
  state.doc.room = room
  level.reset(room)
  player.warp(level.spawn.x, level.spawn.y)
  audio.bgm(room)
  -- snap the camera to the arrival so the swap doesn't whip-pan
  local px, py = player.center()
  cam:f32(0, m.clamp(px - W / 2, 0, level.pw - W))
  cam:f32(4, m.clamp(py - H / 2, 0, level.ph - H))
end

local function room_logic()
  local px, py = player.pos()
  local pw, ph = player.size()
  for _, p in ipairs(level.portals) do
    if p.to and overlap(px, py, pw, ph, p.x, p.y, p.w, p.h) then
      enter_room(p.to); return
    end
  end
  local got = level.collected()
  for _, c in ipairs(level.coins) do
    if not got[c.id] and overlap(px, py, pw, ph, c.x, c.y, c.w, c.h) then
      got[c.id] = true
      audio.sfx("coin")
    end
  end
  for _, h in ipairs(level.hazards) do
    if overlap(px, py, pw, ph, h.x, h.y, h.w, h.h) then
      audio.sfx("hit")
      player.warp(level.spawn.x, level.spawn.y)
      return
    end
  end
end

local function cam_step()
  local kc = state.doc.knobs.cam
  local px, py = player.center()
  local look = cam:f32(8)
  look = look + (player.facing() * kc.look - look) * kc.look_lerp
  local cx, cy = cam:f32(0), cam:f32(4)
  cx = cx + (px + look - W / 2 - cx) * kc.lerp
  local err = py - (cy + H / 2)
  if err > kc.dead then cy = cy + (err - kc.dead) * kc.lerp_y
  elseif err < -kc.dead then cy = cy + (err + kc.dead) * kc.lerp_y end
  cam:f32(0, m.clamp(cx, 0, level.pw - W))
  cam:f32(4, m.clamp(cy, 0, level.ph - H))
  cam:f32(8, look)
end

function game.step()
  local ctl = build_ctl()
  local was_grounded = player.grounded()
  local was_vy = player.vy()
  player.step(ctl)
  fx.step()
  -- sfx off the moveset
  if ctl.jump_pressed and was_grounded then audio.sfx("jump", 96) end
  if player.grounded() and not was_grounded and was_vy > 60 then
    audio.sfx("land", math.min(127, 64 + math.floor(was_vy / 6)))
  end
  room_logic()
  cam_step()
end

function game.draw()
  pal.begin_frame(0.07, 0.08, 0.12, 1)
  level.grade() -- per-room mood grade over the whole composite (render-only)
  local camx, camy = cam:f32(0), cam:f32(4)
  gfx.camera(camx, camy)          -- set the camera before the parallax bg
  level.draw_bg(camx, camy)

  gfx.layer(1)
  level.draw(camx, camy)
  player.draw()
  fx.draw()

  gfx.layer(0)
  -- HUD legibility bars (the sky can be light) then the text
  pal.quad(0, 0, W, 13, 0.05, 0.04, 0.08, 0.4)
  pal.quad(0, H - 12, W, 12, 0.05, 0.04, 0.08, 0.45)
  local title = level.current == "town" and "COZY TOWN" or "OVERWORLD"
  text.draw((W - text.measure(title)) // 2, 3, title,
            { r = 1, g = 0.92, b = 0.7, a = 0.97 })
  local n = 0
  for _ in pairs(level.collected()) do n = n + 1 end
  text.draw(4, 3, ("coins %d"):format(n), { r = 1, g = 0.9, b = 0.4, a = 0.97 })
  text.draw(4, H - 10,
            "arrows  space:jump  e:hop  q:grapple  r:teleport  ->  walk into a door",
            { r = 0.92, g = 0.9, b = 0.82, a = 0.95 })
end

return game
