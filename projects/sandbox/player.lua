-- player — the character controller (M3 + the air-move set): run with
-- accel/decel, buffered + coyote jumps with release-cut variable height,
-- one-way platforms with down+jump drop-through, grab/throw crates, and
-- the A-Hat-in-Time air kit:
--
--  * DIVE — its own button ("dive", G), mid-air only: a fast forward
--    lunge with a boom pop + trail. No air control, facing locked.
--    Land without canceling -> belly slide, and you stay on your belly
--    until the dive is canceled (slide friction brings you to rest).
--  * CANCEL — pressing ANY action during a dive or slide (the opposite
--    direction included): front-flip pop (slight up momentum), forward
--    momentum slowed, air control returns, but facing stays locked until
--    you touch the ground. The flip-out arc falls under its own gravity
--    multiplier (knobs.dive.cancel_grav) — decoupled from the jump
--    curve's fall_mul/hang shaping, so tuning the jump never changes
--    the flip. No new dive until you touch the ground (the flip-out
--    state IS the lockout) — one dive per airtime, like the dj.
--  * DIVE BOOST — cancel within ~knobs.dive.boost_win frames of the
--    ground (before touchdown or just after sliding) while HOLDING the
--    dive direction: big forward speed + flip + ground-bounce burst. The
--    boost evaporates the moment you touch the ground (gap-crossing
--    tech); while it lasts, steering caps speed at knobs.dive.boost_max
--    instead of move.run — and the dive button is DEAD: no
--    boost->dive->boost chains for infinite fast movement; the
--    touchdown that ends the boost unlocks the dive.
--  * DOUBLE JUMP — jump pressed again in mid-air, one charge per
--    airtime (restored on landing), its own buffer + coyote knobs
--    (knobs.dj): within dj.coyote of walking off a ledge an air press is
--    still the full ground jump (charge kept). A charge-less air press
--    buffers the landing jump as usual. Dives SPEND the charge — no
--    double jump out of a dive or its cancel; landing restores it.
--    Diving OUT of a double jump is still allowed. Release-cut applies
--    to both jumps. The impulse is dj.scale times the jump curve's —
--    a SCALE so the second jump tracks the first under tuning and
--    never silently out-jumps it (stock 255/280, the retired dj.speed
--    over the stock jump impulse, bit-exact).
--
-- Every number is a doc-tree knob (knobs.move/dive/dj/feel) — tune live.
--
-- The jump curve (D029) is authored in feel terms, not raw physics: rise
-- gravity and the takeoff impulse derive from knobs.move.jump_h (apex
-- height, px) and apex_t (time to apex, frames); falling multiplies
-- gravity by fall_mul, and an apex hang window (airborne, |vy| <=
-- hang_speed) multiplies by hang_mul on top — floaty peaks, snappy
-- drops, all five orthogonal. Dives keep their own multiplier (dive.grav)
-- over the same base curve.
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
--   [64] dive state (0 none, 1 air dive, 2 belly slide, 3 flip-out)
--   [68] dive direction (+1/-1) | [72] slide frames | [76] flip anim s
--   [80] boosted (0/1) | [84] air-jump charge (0/1)
--   [88] dj buffer frames | [92] dj coyote frames

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

local function boom(x, y, dir, n, fast)
  fx.spawn(x, y, n, { vx0 = -dir * (fast and 220 or 90), vx1 = -dir * 25,
                      vy0 = -45, vy1 = 35, life0 = 0.16, life1 = 0.34,
                      shade0 = 3.0, shade1 = 4.0 })
end

-- ctl: left/right/up/down (held), jump_pressed/jump_held/jump_released,
-- grab_pressed, any_pressed (any action's press edge — the dive cancel
-- trigger) — main.lua builds this from live input or the demo script
function M.step(ctl)
  local k = state.doc.knobs.move
  local kd = state.doc.knobs.dive
  local kj = state.doc.knobs.dj
  local feel = state.doc.knobs.feel
  local kf = state.doc.knobs.fx
  local tm = level.tm

  -- the derived jump curve (D029): integer-ratio math, so the stock
  -- 56 px / 24 f reproduces the retired jump=280/gravity=700 pair
  -- bit-exactly (2*56*3600/24^2 = 700, 2*56*60/24 = 280)
  local apex_t = m.max(k.apex_t, 0.001) -- a zero apex must not make NaNs
  local g_rise = 2.0 * k.jump_h * 3600.0 / (apex_t * apex_t)
  local v0 = 2.0 * k.jump_h * 60.0 / apex_t

  local x, y = buf:f32(0), buf:f32(4)
  local vx, vy = buf:f32(8), buf:f32(12)
  local facing = buf:f32(16)
  local coyote, jbuf = buf:f32(20), buf:f32(24)
  local drop = buf:f32(28)
  local squash_t, stretch_t = buf:f32(32), buf:f32(36)
  local grounded = buf:f32(44) == 1.0
  local on_oneway = buf:f32(60) == 1.0
  local carry = math.floor(buf:f32(48))
  local dstate = buf:f32(64)
  local ddir = buf:f32(68)
  local slide_t, flip_t = buf:f32(72), buf:f32(76)
  local boosted = buf:f32(80) == 1.0
  local charge = buf:f32(84)
  local dj_buf, dj_coy = buf:f32(88), buf:f32(92)

  local press = ctl.jump_pressed
  local canceled = false

  -- dive cancel: any pressed action flips out of a dive or belly slide
  if (dstate == 1 or dstate == 2) and ctl.any_pressed then
    canceled = true
    local near_ground
    if dstate == 2 then
      near_ground = slide_t <= kd.boost_win
    else -- would the dive touch down within the window?
      local probe = m.max(vy, 80.0) * kd.boost_win * DT
      local _, _, ph = tm:move(x, y, M.W, M.H, 0, probe)
      near_ground = ph.down or false
    end
    local holding = (ddir > 0 and ctl.right) or (ddir < 0 and ctl.left)
    if near_ground and holding then -- DIVE BOOST
      vx = ddir * kd.boost
      boosted = true
      boom(x + M.W * 0.5, y + M.H, ddir, 10, true)
      fx.spawn(x + M.W * 0.5, y + M.H, 12, -- ground-bounce ring
               { vx0 = -130, vx1 = 130, vy0 = -40, vy1 = -6,
                 shade0 = 0.3, shade1 = 1.0 })
    else
      vx = vx * kd.cancel_slow
      boom(x + M.W * 0.5, y + M.H * 0.5, ddir, 4, false)
    end
    vy = -kd.cancel_vy
    dstate = 3 -- flip-out: air control back, facing locked until ground
    flip_t = kd.flip_t
    slide_t = 0
    press = false -- the press canceled; it is not also a jump
  end

  -- run: full authority on the ground, k.air of it in the air; dives and
  -- slides have no steering at all
  local ax = (ctl.right and 1 or 0) - (ctl.left and 1 or 0)
  if dstate == 1 then
    -- committed: vx stays as the dive set it
  elseif dstate == 2 then
    vx = vx * m.max(0.0, 1.0 - kd.slide_fric * DT) -- belly friction
  elseif ax ~= 0 then
    if dstate == 0 then facing = ax end -- 3 = flip-out: facing stays locked
    vx = vx + ax * k.accel * (grounded and 1.0 or k.air) * DT
    vx = boosted and m.clamp(vx, -kd.boost_max, kd.boost_max)
         or m.clamp(vx, -k.run, k.run)
  else
    local d = k.decel * (grounded and 1.0 or k.air) * DT
    if vx > 0 then vx = m.max(0.0, vx - d) else vx = m.min(0.0, vx + d) end
  end

  -- jump intent routing: ground/coyote presses buffer as before; an air
  -- press is the double jump when a charge is there, else it buffers the
  -- landing jump
  if press then
    if grounded or coyote > 0 then
      jbuf = k.buffer
    elseif dj_coy > 0 then -- dj's own ledge grace: still the full jump
      vy = -v0
      stretch_t = feel.stretch_t
      coyote, dj_coy = 0, 0
      fx.spawn(x + M.W * 0.5, y + M.H, 3,
               { vx0 = -25, vx1 = 25, vy0 = -35, vy1 = -5,
                 shade0 = 0.3, shade1 = 1.0 })
    elseif charge > 0 and dstate ~= 1 and dstate ~= 2 then
      dj_buf = kj.buffer -- fires just below
    else
      jbuf = k.buffer
    end
  end

  -- the dive: its own button, mid-air only, from clean air ONLY
  -- (dstate 0): mid-dive and mid-slide can't re-dive, and the cancel
  -- flip-out (dstate 3, which persists until touchdown) is the
  -- one-dive-per-airtime lockout — no dive after a cancel, no
  -- boost->dive->boost chains (`not boosted` kept as belt and
  -- suspenders), until the ground resets the kit. Locked while
  -- carrying; the press that canceled a dive never starts the next one
  if ctl.dive_pressed and not canceled and not grounded and carry == 0
     and not boosted and dstate == 0 then
    dstate = 1
    ddir = facing
    vx = facing * kd.speed
    vy = m.max(vy, 0.0) + kd.vy
    flip_t = 0
    -- a dive spends the air moves: the jump buffers AND the dj charge —
    -- no double jump out of a dive or its cancel (landing restores it)
    jbuf, dj_buf, charge = 0, 0, 0
    boom(x + M.W * 0.5 - facing * 4, y + M.H * 0.5, facing, 9, true)
  end

  -- double jump: buffered intent fires as soon as it is legal; the
  -- impulse rides the jump curve (v0 * scale: tuning the jump retunes
  -- the dj with it, and scale <= 1 keeps it the weaker jump)
  if dj_buf > 0 and not grounded and charge > 0
     and dstate ~= 1 and dstate ~= 2 then
    vy = -v0 * kj.scale
    charge = 0
    dj_buf = 0
    coyote, dj_coy = 0, 0
    flip_t = 0 -- a dj out of the flip shows the jump pose again
    stretch_t = feel.stretch_t
    fx.spawn(x + M.W * 0.5, y + M.H, 5,
             { vx0 = -45, vx1 = 45, vy0 = -20, vy1 = 25,
               shade0 = 3.0, shade1 = 3.8 })
  else
    dj_buf = m.max(0.0, dj_buf - 1)
  end

  -- buffered ground jump (+ down+jump drop-through on one-ways)
  if jbuf > 0 and (grounded or coyote > 0) then
    if ctl.down and grounded and on_oneway then
      drop = 8 -- MapleStory down+jump: fall through the plank
    else
      vy = -v0
      stretch_t = feel.stretch_t
      coyote, dj_coy = 0, 0
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

  -- gravity phases: rising = the curve as-is; falling = fall_mul times
  -- it; the apex hang window multiplies hang_mul on top. Dives keep
  -- their own multiplier and the cancel flip-out has its own too
  -- (cancel_grav — jump tuning never reshapes the flip); on the ground
  -- it's just the contact probe
  local grav_mul
  if dstate == 1 then
    grav_mul = kd.grav
  elseif grounded then
    grav_mul = 1.0
  elseif dstate == 3 then
    grav_mul = kd.cancel_grav
  else
    grav_mul = vy > 0 and k.fall_mul or 1.0
    if m.abs(vy) <= k.hang_speed then grav_mul = grav_mul * k.hang_mul end
  end
  vy = m.min(vy + g_rise * grav_mul * DT, k.fall_max)

  local was_grounded = grounded
  local nx, ny, hit = tm:move(x, y, M.W, M.H, vx * DT, vy * DT,
                              { drop = drop > 0 })
  drop = m.max(0.0, drop - 1)
  if hit.left or hit.right then vx = 0 end
  if hit.up then vy = m.max(vy, 0.0) end
  if hit.down then
    if not was_grounded then
      if dstate == 1 then -- dive touchdown: onto the belly
        dstate = 2
        slide_t = 0
        squash_t = feel.squash_t * 0.7
        buf:f32(52, vy)
        fx.spawn(nx + M.W * 0.5 + ddir * 5, ny + M.H, 6,
                 { vx0 = ddir * 20, vx1 = ddir * 90, vy0 = -40, vy1 = -8,
                   shade0 = 0.2, shade1 = 1.0 })
      elseif vy > 60 then -- regular landing: squash + dust
        buf:f32(52, vy)
        squash_t = feel.squash_t
        local burst = m.floor(m.clamp(vy / 60.0, 2, 9))
        fx.spawn(nx + M.W * 0.5, ny + M.H, burst,
                 { vx0 = -55, vx1 = 55, vy0 = -45, vy1 = -8,
                   shade0 = 0.2, shade1 = 1.0 })
      end
    end
    vy = 0
    grounded = true
    on_oneway = hit.oneway or false
    coyote = k.coyote
    dj_coy = kj.coyote
    charge = 1
    if dstate == 3 then -- flip-out ends: facing unlocks
      dstate = 0
      flip_t = 0
    end
    if boosted then -- the boost evaporates on touchdown
      vx = m.clamp(vx, -k.run, k.run)
      boosted = false
    end
  else
    grounded = false
    on_oneway = false
    coyote = m.max(0.0, coyote - 1)
    dj_coy = m.max(0.0, dj_coy - 1)
    if dstate == 2 then dstate = 1 end -- slid off a ledge: airborne dive
  end
  if dstate == 2 then slide_t = slide_t + 1 end

  -- trails: dive boom stream, belly-slide scrape, footfall dust
  local frame = state.frame()
  if dstate == 1 and frame % 2 == 0 then
    boom(nx + M.W * 0.5 - ddir * 6, ny + M.H * 0.5, ddir, 1, false)
  elseif boosted and not grounded then
    boom(nx + M.W * 0.5 - ddir * 7, ny + M.H * 0.5, ddir, 1, false)
  elseif dstate == 2 and m.abs(vx) > 50 and frame % 3 == 0 then
    fx.spawn(nx + M.W * 0.5 + ddir * 5, ny + M.H, 1,
             { vx0 = -ddir * 40, vx1 = -ddir * 10, vy0 = -30, vy1 = -8,
               shade0 = 0.3, shade1 = 0.9 })
  end
  local dust = buf:f32(56)
  if grounded and dstate == 0 and m.abs(vx) > k.run * 0.5 then
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

  -- grab / throw (one button: holding nothing grabs, holding throws);
  -- a press that canceled a dive is spent
  if ctl.grab_pressed and not canceled then
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
  buf:f32(64, dstate)
  buf:f32(68, ddir)
  buf:f32(72, slide_t)
  buf:f32(76, m.max(0.0, flip_t - DT))
  buf:f32(80, boosted and 1.0 or 0.0)
  buf:f32(84, charge)
  buf:f32(88, dj_buf)
  buf:f32(92, dj_coy)
end

-- ---- sprite (procedural placeholder: 7 frames of 12x16) ----
-- 0 idle, 1-2 run, 3 jump, 4 dive/belly, 5-6 front-flip tuck

local function build_sprite()
  local img = pix.img(84, 16)
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

  -- frame 4: dive/belly — horizontal, head forward (atlas faces right)
  local o = 4 * 12
  img.rect(o + 0, 10, 3, 2, 0.20, 0.17, 0.15) -- trailing legs
  img.rect(o + 2, 8, 7, 5, 0.24, 0.55, 0.62) -- body flat
  img.rect(o + 8, 6, 4, 2, 0.32, 0.22, 0.16) -- hair swept back
  img.rect(o + 8, 8, 4, 4, 0.96, 0.82, 0.66) -- face forward
  img.px(o + 10, 9, 0.13, 0.11, 0.11) -- eye
  img.rect(o + 4, 13, 4, 1, 0.96, 0.82, 0.66) -- arms tucked under

  -- frames 5/6: front-flip tuck, upright and inverted
  local function tuck(f, inverted)
    local o2 = f * 12
    img.rect(o2 + 3, 4, 7, 8, 0.24, 0.55, 0.62) -- ball
    local hy = inverted and 10 or 3
    local fy = inverted and 6 or 7
    img.rect(o2 + 4, hy, 5, 2, 0.32, 0.22, 0.16) -- hair
    img.rect(o2 + 5, fy, 4, 2, 0.96, 0.82, 0.66) -- face sliver
    img.px(o2 + 6, fy, 0.13, 0.11, 0.11)
    img.rect(o2 + 3, inverted and 3 or 12, 4, 1, 0.20, 0.17, 0.15) -- legs
  end
  tuck(5, false)
  tuck(6, true)
  return img.tex()
end

local sprite = build_sprite()
local FRAMES = 7

function M.draw()
  local feel = state.doc.knobs.feel
  local x, y = buf:f32(0), buf:f32(4)
  local vx, vy = buf:f32(8), buf:f32(12)
  local facing = buf:f32(16)
  local grounded = buf:f32(44) == 1.0
  local dstate = buf:f32(64)
  local flip_t = buf:f32(76)

  local f
  if dstate == 1 or dstate == 2 then
    f = 4
  elseif dstate == 3 and flip_t > 0 then
    f = 5 + math.floor(flip_t * 14) % 2 -- tumbling tuck
  elseif not grounded then
    f = 3
  elseif m.abs(vx) > 8 then
    f = math.floor(buf:f32(40)) % 2 == 0 and 1 or 2
  else
    f = 0
  end

  -- squash & stretch around the feet center (flat poses skip it)
  local sx, sy = 1.0, 1.0
  if dstate == 0 then
    local sq = ease.cubic_in(m.clamp(buf:f32(32) / feel.squash_t, 0, 1))
              * feel.squash * m.clamp(buf:f32(52) / 360.0, 0.3, 1.0)
    local st = ease.cubic_in(m.clamp(buf:f32(36) / feel.stretch_t, 0, 1))
              * feel.stretch
    if not grounded then
      st = st + m.clamp(m.abs(vy) / 900.0, 0, 0.22)
    end
    sx = 1.0 + sq * 0.9 - st * 0.5
    sy = 1.0 - sq * 0.6 + st * 0.6
  end

  local dw, dh = 12 * sx, 16 * sy
  local dx = x + M.W * 0.5 - dw * 0.5
  local dy = y + M.H - dh -- feet-anchored: squash sinks, stretch rises
  local u0 = (f * 12) / (FRAMES * 12)
  local u1 = (f * 12 + 12) / (FRAMES * 12)
  if facing < 0 then u0, u1 = u1, u0 end
  pal.quad(dx, dy, dw, dh, 1, 1, 1, 1, sprite.id, u0, 0, u1, 1)
end

return M
