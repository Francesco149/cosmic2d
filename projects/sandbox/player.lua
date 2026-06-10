-- player — the MapleStory-vocabulary character controller (M3): run with
-- accel/decel, jump with buffering + coyote time + variable height (release
-- cuts the rise), one-way platforms with down+jump drop-through, grab/throw
-- crates, squash & stretch hooks. Every feel number is a doc-tree knob —
-- tune live from the console (doc.knobs.move.jump = 320).
--
-- sandbox.player layout (f32 fields):
--   [0] x | [4] y          AABB top-left (10x14 px body)
--   [8] vx | [12] vy
--   [16] facing (+1/-1)
--   [20] coyote frames | [24] jump-buffer frames | [28] drop-through frames
--   [32] squash timer s | [36] stretch timer s | [40] anim phase
--   [44] grounded (0/1) | [48] carried prop (0 = none)
--   [52] landing impact (px/s) | [56] run-dust accumulator
--   [60] standing on one-way (0/1)

local m = pt.require("pt.math")
local state = pt.require("pt.state")
local ease = pt.require("pt.ease")
local pix = pt.require("pix")
local level = pt.require("level")
local props = pt.require("props")
local fx = pt.require("fx")

local M = {}

local DT = 1.0 / 60.0
M.W, M.H = 10, 14

local buf

function M.init()
  buf = pal.buf("sandbox.player", 96)
  if buf:f32(0) == 0 and buf:f32(4) == 0 and buf:f32(8) == 0
     and buf:f32(12) == 0 then -- virgin: spawn
    buf:f32(0, level.spawn.x)
    buf:f32(4, level.spawn.y)
    buf:f32(16, 1)
  end
end

function M.pos()
  return buf:f32(0), buf:f32(4)
end

function M.center()
  return buf:f32(0) + M.W * 0.5, buf:f32(4) + M.H * 0.5
end

function M.facing()
  return buf:f32(16)
end

-- ctl: left/right/down (held), jump_pressed/jump_held/jump_released,
-- grab_pressed — main.lua builds this from live input or the demo script
function M.step(ctl)
  local k = state.doc.knobs.move
  local feel = state.doc.knobs.feel
  local kf = state.doc.knobs.fx
  local tm = level.tm

  local x, y = buf:f32(0), buf:f32(4)
  local vx, vy = buf:f32(8), buf:f32(12)
  local facing = buf:f32(16)
  local coyote, jbuf = buf:f32(20), buf:f32(24)
  local drop = buf:f32(28)
  local squash_t, stretch_t = buf:f32(32), buf:f32(36)
  local grounded = buf:f32(44) == 1.0
  local on_oneway = buf:f32(60) == 1.0
  local carry = math.floor(buf:f32(48))

  -- run: full authority on the ground, k.air of it in the air
  local ax = (ctl.right and 1 or 0) - (ctl.left and 1 or 0)
  if ax ~= 0 then
    facing = ax
    vx = vx + ax * k.accel * (grounded and 1.0 or k.air) * DT
    vx = m.clamp(vx, -k.run, k.run)
  else
    local d = k.decel * (grounded and 1.0 or k.air) * DT
    if vx > 0 then vx = m.max(0.0, vx - d) else vx = m.min(0.0, vx + d) end
  end

  -- jump intent: buffered a few frames so early presses still land
  if ctl.jump_pressed then jbuf = k.buffer end
  if jbuf > 0 and (grounded or coyote > 0) then
    if ctl.down and grounded and on_oneway then
      drop = 8 -- MapleStory down+jump: fall through the plank
    else
      vy = -k.jump
      stretch_t = feel.stretch_t
      coyote = 0
      fx.spawn(x + M.W * 0.5, y + M.H, 3,
               { vx0 = -25, vx1 = 25, vy0 = -35, vy1 = -5,
                 shade0 = 0.3, shade1 = 1.0 })
    end
    jbuf = 0
  else
    jbuf = m.max(0.0, jbuf - 1)
  end
  -- variable height: releasing the key while rising cuts the jump
  if ctl.jump_released and vy < 0 then vy = vy * k.cut end

  vy = m.min(vy + k.gravity * DT, k.fall_max)

  local was_grounded = grounded
  local nx, ny, hit = tm:move(x, y, M.W, M.H, vx * DT, vy * DT,
                              { drop = drop > 0 })
  drop = m.max(0.0, drop - 1)
  if hit.left or hit.right then vx = 0 end
  if hit.up then vy = m.max(vy, 0.0) end
  if hit.down then
    if not was_grounded and vy > 60 then -- landed: squash + dust
      buf:f32(52, vy)
      squash_t = feel.squash_t
      local burst = m.floor(m.clamp(vy / 60.0, 2, 9))
      fx.spawn(nx + M.W * 0.5, ny + M.H, burst,
               { vx0 = -55, vx1 = 55, vy0 = -45, vy1 = -8,
                 shade0 = 0.2, shade1 = 1.0 })
    end
    vy = 0
    grounded = true
    on_oneway = hit.oneway or false
    coyote = k.coyote
  else
    grounded = false
    on_oneway = false
    coyote = m.max(0.0, coyote - 1)
  end

  -- footfall dust while running
  local dust = buf:f32(56)
  if grounded and m.abs(vx) > k.run * 0.5 then
    dust = dust + m.abs(vx) * DT
    if dust >= kf.run_dist then
      dust = dust - kf.run_dist
      fx.spawn(nx + M.W * 0.5 - facing * 3, ny + M.H, 1,
               { vx0 = -facing * 30, vx1 = -facing * 8, vy0 = -28, vy1 = -8,
                 shade0 = 0.3, shade1 = 0.9 })
    end
  else
    dust = 0
  end

  -- grab / throw (one button: holding nothing grabs, holding throws)
  if ctl.grab_pressed then
    local kt = state.doc.knobs.throw
    if carry > 0 then
      props.throw(carry, facing * kt.vx + vx * kt.inherit, -kt.vy)
      carry = 0
      stretch_t = m.max(stretch_t, feel.stretch_t * 0.6)
    else
      local i = props.nearest_free(nx + M.W * 0.5, ny + M.H * 0.5, kt.radius)
      if i then
        props.grab(i)
        carry = i
      end
    end
  end
  if carry > 0 then
    local pw, ph = select(3, props.get(carry))
    props.pin(carry, nx + M.W * 0.5 - pw * 0.5, ny - ph - 1)
  end

  buf:f32(0, nx)
  buf:f32(4, ny)
  buf:f32(8, vx)
  buf:f32(12, vy)
  buf:f32(16, facing)
  buf:f32(20, coyote)
  buf:f32(24, jbuf)
  buf:f32(28, drop)
  buf:f32(32, m.max(0.0, squash_t - DT))
  buf:f32(36, m.max(0.0, stretch_t - DT))
  buf:f32(40, buf:f32(40) + m.abs(vx) * DT * 0.075)
  buf:f32(44, grounded and 1.0 or 0.0)
  buf:f32(48, carry)
  buf:f32(56, dust)
  buf:f32(60, on_oneway and 1.0 or 0.0)
end

-- ---- sprite (procedural placeholder: 4 frames of 12x16) ----

local function build_sprite()
  local img = pix.img(48, 16)
  local function frame(f, legs, body_y)
    local o = f * 12
    img.rect(o + 3, body_y, 6, 2, 0.32, 0.22, 0.16) -- hair
    img.px(o + 2, body_y + 1, 0.32, 0.22, 0.16)
    img.px(o + 9, body_y + 1, 0.32, 0.22, 0.16)
    img.rect(o + 3, body_y + 2, 6, 4, 0.96, 0.82, 0.66) -- face
    img.px(o + 4, body_y + 3, 0.13, 0.11, 0.11) -- eyes
    img.px(o + 7, body_y + 3, 0.13, 0.11, 0.11)
    img.rect(o + 2, body_y + 6, 8, 5, 0.24, 0.55, 0.62) -- overalls
    img.rect(o + 2, body_y + 6, 1, 3, 0.96, 0.82, 0.66) -- arms
    img.rect(o + 9, body_y + 6, 1, 3, 0.96, 0.82, 0.66)
    for _, l in ipairs(legs) do
      img.rect(o + l[1], l[2], 2, l[3], 0.20, 0.17, 0.15)
    end
  end
  frame(0, { { 3, 13, 3 }, { 7, 13, 3 } }, 2) -- idle
  frame(1, { { 2, 13, 3 }, { 8, 13, 2 } }, 1) -- run A
  frame(2, { { 5, 13, 3 }, { 6, 14, 2 } }, 1) -- run B
  frame(3, { { 3, 12, 2 }, { 7, 12, 2 } }, 2) -- jump (legs tucked)
  return img.tex()
end

local sprite = build_sprite()

function M.draw()
  local feel = state.doc.knobs.feel
  local x, y = buf:f32(0), buf:f32(4)
  local vx, vy = buf:f32(8), buf:f32(12)
  local facing = buf:f32(16)
  local grounded = buf:f32(44) == 1.0

  local f
  if not grounded then
    f = 3
  elseif m.abs(vx) > 8 then
    f = math.floor(buf:f32(40)) % 2 == 0 and 1 or 2
  else
    f = 0
  end

  -- squash & stretch around the feet center
  local sq = ease.cubic_in(m.clamp(buf:f32(32) / feel.squash_t, 0, 1))
            * feel.squash * m.clamp(buf:f32(52) / 360.0, 0.3, 1.0)
  local st = ease.cubic_in(m.clamp(buf:f32(36) / feel.stretch_t, 0, 1))
            * feel.stretch
  if not grounded then
    st = st + m.clamp(m.abs(vy) / 900.0, 0, 0.22)
  end
  local sx = (1.0 + sq * 0.9 - st * 0.5)
  local sy = (1.0 - sq * 0.6 + st * 0.6)

  local dw, dh = 12 * sx, 16 * sy
  local dx = x + M.W * 0.5 - dw * 0.5
  local dy = y + M.H - dh -- feet-anchored: squash sinks, stretch rises
  local u0 = (f * 12) / 48
  local u1 = (f * 12 + 12) / 48
  if facing < 0 then u0, u1 = u1, u0 end
  pal.quad(dx, dy, dw, dh, 1, 1, 1, 1, sprite.id, u0, 0, u1, 1)
end

return M
