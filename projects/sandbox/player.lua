-- player — the cosmic mecha-girl controller (M7, D035 / GAME.md §4): the
-- MapleStory-derived moveset that replaces the old A-Hat-in-Time air kit.
-- Pure cartridge policy: it rides the frozen tilemap mover + one-way
-- platforms (D024) and reads the map through primitives for grapple
-- targeting (the D030 pattern — feel/assists/queries are controller-side,
-- the mover stays a mechanism). No engine/PAL change. Determinism class is
-- unchanged: integer-frame timers, pure-IEEE scans, engine PRNG (fx) only,
-- cm.math trig, no libm, no wall clock.
--
-- The moveset (every value a live knob under doc.knobs.move, D028):
--   1 WALK      hold ←/→ grounded — slow ground move (~3 CW/s; you fly,
--               you don't run).
--   2 JUMP      Jump, grounded — FIXED apex ≈1 CH (not variable height);
--               hold Jump auto-repeats on landing (bounce). down+Jump on a
--               one-way drops through.
--   3 FLASH JUMP Jump again airborne — upright forward dash (~6 CW from
--               apex), repeatable, the staple. Sonic-boom ring. Minimal air
--               control (air_accel only trims the arc). Locked while up-jumped.
--   4 UP JUMP   Up + Jump airborne — fixed vertical impulse (jump→up-jump
--               chain ≈5 CH). Once per airtime; LOCKS OUT flash jump until
--               landing. Time it late for less height.
--   5 HOP       E — diagonal up-forward boost, the trajectory fine-tuner.
--               Chains anywhere. Once per airtime (and never on flutter cd).
--   6 FLUTTER   hold E after a hop AND keep holding once you START FALLING —
--               small up-forward mini-hops (a slight diagonal, <45° from up:
--               flutter_vx forward « the vertical kick) every flutter_interval
--               frames, flutter_boosts times, each ~holding height with a gentle
--               bob + nudging you forward a little. Carried momentum is CANCELLED
--               at hover-start (a flash-jump doesn't launch you far); hold a dir
--               to steer. On release/timeout/land hop goes on hop_cd (a plain TAP
--               hop — released before you fall — never arms it). Cd persists.
--   7 GRAPPLE   q (the spec's ` is the dev console — see main.lua) — reel up
--               to a standable top above, preferring targets past ½ a
--               screenful. Slow accel. Once per airtime, 3 s cooldown. Jump
--               CANCELS (no auto-FJ; press Jump again for that).
--   8 TELEPORT  R (hold to spam) — blink ~5 CW forward, lose all momentum,
--               max 2/s. Persistent A↔B PHASE-SHIFT mode, flips each blink,
--               resets on map change: appearance reflects the mode (mode B's
--               phase-through-hazards/enemies lands with combat, M12). Blink
--               clamps at solid walls, passes one-ways.
--   9 ATTACK    hold D — continuous slice (slash particle stub; enemies at
--               M12). Jump/FJ/up-jump allowed; HOP is disabled while held.
--
-- Per-airtime flags (hop_used, up-jumped→FJ-lock, grapple_used) reset on
-- landing; the teleport MODE bit, hop cooldown and grapple cooldown persist
-- (mode resets on map change). All state is named-buffer sim state below;
-- nothing lives on the Lua heap.
--
-- Units: cw/ch knobs are the character box AND the calibration unit (CW/CH,
-- GAME.md §4). Distances default to the spec's CW/CH relationships sized to
-- fit the current 16 px-tile map at 1:1. The absolute "6 CW ≈ ⅓ screen"
-- anchor (CW ≈ 26 px) needs the zoom/real-sprite pass (M8 / M-art); it's a
-- cw/ch/zoom knob change away.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local ease = cm.require("cm.ease")
local pix = cm.require("pix")
local level = cm.require("level")
local fx = cm.require("fx")
local gfx = cm.require("cm.gfx")
local anim = cm.require("cm.anim")

local M = {}

local DT = 1.0 / 60.0
local TAU = 6.28318530717958623200

-- named-buffer layout (f32 fields). Offsets are the single source of truth
-- shared by step() (writes) and draw() (reads).
local O = {
  x = 0, y = 4, vx = 8, vy = 12, facing = 16,
  grounded = 20, on_oneway = 24, coyote = 28, jbuf = 32, drop = 36,
  hop_used = 40, upjumped = 44, grapple_used = 48,
  hop_active = 52, fluttering = 56, flutter_t = 60, hop_cd = 64,
  grappling = 68, gx = 72, gy = 76, grapple_cd = 80,
  tp_mode = 84, tp_cd = 88, attack_t = 92,
  squash_t = 96, stretch_t = 100, anim = 104, land = 108, dust = 112,
  tp_flash = 116, fj_used = 120, htipy = 124, reel_t = 128,
}
local SIZE = 132

M.W, M.H = 12, 18 -- body box; refreshed from cw/ch knobs each init/step

local buf

function M.init()
  -- the layout changed from the old controller's 96 bytes; a hot reload over
  -- the stale buffer would size-mismatch (pal.buf errors), so discard it and
  -- re-seed. Cold boots / verify runs just allocate fresh.
  local ok, b = pcall(pal.buf, "sandbox.player", SIZE)
  if not ok then
    pal.buf_free("sandbox.player")
    b = pal.buf("sandbox.player", SIZE)
  end
  buf = b
  if buf:f32(O.x) == 0 and buf:f32(O.y) == 0
     and buf:f32(O.vx) == 0 and buf:f32(O.vy) == 0 then -- virgin: spawn
    buf:f32(O.x, level.spawn.x)
    buf:f32(O.y, level.spawn.y)
    buf:f32(O.facing, 1)
  end
end

function M.pos() return buf:f32(O.x), buf:f32(O.y) end
function M.center() return buf:f32(O.x) + M.W * 0.5, buf:f32(O.y) + M.H * 0.5 end
function M.facing() return buf:f32(O.facing) end

-- live cooldown/flag state for the temporary testing HUD (main.draw). Pure
-- read; cooldowns are remaining frames, flags are 0/1.
function M.dbg()
  return {
    hop_cd = buf:f32(O.hop_cd), grapple_cd = buf:f32(O.grapple_cd),
    tp_cd = buf:f32(O.tp_cd), flutter_t = buf:f32(O.flutter_t),
    hop_used = buf:f32(O.hop_used), fj_used = buf:f32(O.fj_used),
    upjumped = buf:f32(O.upjumped), grapple_used = buf:f32(O.grapple_used),
    fluttering = buf:f32(O.fluttering), tp_mode = buf:f32(O.tp_mode),
  }
end

-- ---- helpers ----

local function approach(v, target, step)
  if v < target then return m.min(v + step, target) end
  return m.max(v - step, target)
end

-- a radial particle ring (sonic boom, teleport pop): exact angles via
-- cm.math trig (deterministic, no libm). fx.spawn collapses equal min/max.
local function ring(x, y, n, speed, sh0, sh1, l0, l1)
  for i = 0, n - 1 do
    local a = TAU * i / n
    local c, s = m.cos(a), m.sin(a)
    fx.spawn(x, y, 1, { vx0 = c * speed, vx1 = c * speed,
                        vy0 = s * speed, vy1 = s * speed,
                        life0 = l0, life1 = l1, shade0 = sh0, shade1 = sh1 })
  end
end

local function puff(x, y, n, sh)
  fx.spawn(x, y, n, { vx0 = -34, vx1 = 34, vy0 = -38, vy1 = -6,
                      shade0 = sh or 0.3, shade1 = (sh or 0.3) + 0.7 })
end

-- the grapple targeting scan (deterministic, cartridge-side, D030): find
-- standable tops above the player in its column span within range_max; pick
-- the LOWEST that is at least range_min_pref above (reach past close ones);
-- if none qualify, fall back to the HIGHEST in range. Returns the surface y
-- (the tile top the feet would land on) or nil.
local function grapple_scan(tm, x, y, W, H, range_max, min_pref)
  local t = tm.tile
  local feet = y + H
  local c0 = m.floor(x / t)
  local c1 = m.ceil((x + W) / t) - 1
  local r_lo = m.floor((feet - range_max) / t)
  local r_hi = m.ceil(feet / t) - 1 -- rows strictly above the feet
  local best_q, gap_q -- smallest gap among gap >= min_pref
  local best_a, gap_a -- largest gap overall
  for r = r_lo, r_hi do
    local standable = false
    for c = c0, c1 do
      local d = tm.tiles[tm:get(c, r)]
      if d and (d.solid or d.oneway) then standable = true break end
    end
    if standable then
      local clear = true -- room to stand: the row above must be solid-free
      for c = c0, c1 do
        local a = tm.tiles[tm:get(c, r - 1)]
        if a and a.solid then clear = false break end
      end
      if clear then
        local surface = r * t
        local gap = feet - surface
        if gap > 0 and gap <= range_max then
          if gap >= min_pref and (not gap_q or gap < gap_q) then
            best_q, gap_q = surface, gap
          end
          if not gap_a or gap > gap_a then best_a, gap_a = surface, gap end
        end
      end
    end
  end
  return best_q or best_a
end

-- mantle leniency (D030): a descending near-miss at a standable lip within
-- `mantle` px below the feet (column span extended toward a side bonk) hoists
-- the player onto it. Returns the surface y and whether support is one-way.
local function mantle_top(tm, x, y, W, H, mantle, ext_l, ext_r)
  local t = tm.tile
  local feet = y + H
  local r = m.ceil((feet - mantle) / t)
  if r * t >= feet then return nil end
  local c0 = m.floor(x / t) - (ext_l and 1 or 0)
  local c1 = m.ceil((x + W) / t) - 1 + (ext_r and 1 or 0)
  for c = c0, c1 do
    local a = tm.tiles[tm:get(c, r - 1)]
    if a and a.solid then return nil end
  end
  local found, solid = false, false
  for c = c0, c1 do
    local d = tm.tiles[tm:get(c, r)]
    if d and (d.solid or d.oneway) then
      found = true
      solid = solid or (d.solid or false)
    end
  end
  if not found then return nil end
  return r * t, not solid
end

-- ctl (built in main.lua from live input or the demo script):
--   left/right/up/down       held
--   jump_pressed/jump_held    space (press edge / held — held = auto-repeat)
--   hop_pressed/hop_held      e     (press edge / held — held = flutter)
--   grapple_pressed           q     (press edge)
--   teleport_held             r     (held — hold to spam, rate-limited)
--   attack_held               d     (held)
function M.step(ctl)
  local k = state.doc.knobs.move
  local feel = state.doc.knobs.feel
  local kf = state.doc.knobs.fx
  local tm = level.tm

  local W = m.max(4, m.floor(k.cw))
  local H = m.max(4, m.floor(k.ch))
  M.W, M.H = W, H

  -- the fixed-height jump curve (D029 math, but no release-cut): apex height
  -- jump_h px reached in apex_t frames sets the rise gravity + takeoff impulse.
  local apex_t = m.max(k.jump_apex_t, 1.0)
  local g_rise = 2.0 * k.jump_h * 3600.0 / (apex_t * apex_t)
  local v0 = 2.0 * k.jump_h * 60.0 / apex_t

  local x, y = buf:f32(O.x), buf:f32(O.y)
  local vx, vy = buf:f32(O.vx), buf:f32(O.vy)
  local facing = buf:f32(O.facing)
  local grounded = buf:f32(O.grounded) == 1.0
  local on_oneway = buf:f32(O.on_oneway) == 1.0
  local coyote, jbuf, drop = buf:f32(O.coyote), buf:f32(O.jbuf), buf:f32(O.drop)
  local hop_used = buf:f32(O.hop_used)
  local upjumped = buf:f32(O.upjumped)
  local grapple_used = buf:f32(O.grapple_used)
  local fj_used = buf:f32(O.fj_used)
  local hop_active = buf:f32(O.hop_active)
  local fluttering = buf:f32(O.fluttering)
  local flutter_t = buf:f32(O.flutter_t)
  local hop_cd = buf:f32(O.hop_cd)
  local grappling = buf:f32(O.grappling) -- 0 idle, 1 extending, 2 reeling
  local gx, gy = buf:f32(O.gx), buf:f32(O.gy)
  local htipy = buf:f32(O.htipy) -- the climbing hook tip's y (extend phase)
  local reel_t = buf:f32(O.reel_t) -- frames spent reeling (min-duration guard)
  local grapple_cd = buf:f32(O.grapple_cd)
  local tp_mode, tp_cd = buf:f32(O.tp_mode), buf:f32(O.tp_cd)
  local attack_t = buf:f32(O.attack_t)
  local squash_t, stretch_t = buf:f32(O.squash_t), buf:f32(O.stretch_t)

  local was_grounded = grounded
  local dir = (ctl.right and 1 or 0) - (ctl.left and 1 or 0)
  local press = ctl.jump_pressed

  -- ===== TELEPORT (R, hold to spam) — blink, lose all momentum. Direction
  -- ALTERNATES forward/back, tied to the A<->B phase flip that happens each
  -- blink: mode A blinks forward (solid), mode B blinks back (phases through
  -- hazards/enemies — at M12). Max 2/s. =====
  if ctl.teleport_held and tp_cd <= 0 and grappling == 0 then -- locked while
    local tdir = tp_mode == 0 and facing or -facing -- grappling. A fwd / B back
    local bx = tm:move(x, y, W, H, tdir * k.tp_dist, 0) -- clamps at solids
    if flutter_t > 0 then hop_cd = m.max(hop_cd, k.hop_cd) end
    fluttering, hop_active, flutter_t = 0, 0, 0
    ring(x + W * 0.5, y + H * 0.5, 12, 150, 2.0, 3.2, 0.14, 0.30) -- depart
    x, vx, vy = bx, 0, 0
    tp_mode = 1 - tp_mode
    tp_cd = k.tp_min_interval
    buf:f32(O.tp_flash, 1.0)
    ring(x + W * 0.5, y + H * 0.5, 10, 70, 3.0, 4.0, 0.12, 0.26) -- arrive
  end

  -- ===== GRAPPLE (q) — the hook EXTENDS to a target above (~1 screenful/s)
  -- while you stay under normal gravity; once it CONNECTS it reels you in from
  -- your CURRENT velocity. So a jump INTO a grapple has fallen back to downward
  -- velocity by connect-time, which damps the reel — no short-range slingshot.
  -- Jump cancels either phase. =====
  if ctl.grapple_pressed and grappling == 0 and grapple_cd <= 0
     and grapple_used == 0 then
    local ty = grapple_scan(tm, x, y, W, H, k.grapple_range_max,
                            k.grapple_range_min_pref)
    if ty then
      grappling, gy, gx = 1, ty, x + W * 0.5 -- 1 = extending
      htipy, grapple_used, reel_t = y, 1, 0 -- tip starts at the player, climbs
      vx = 0 -- starting a grapple cancels all horizontal momentum
      ring(x + W * 0.5, y, 8, 60, 3.0, 4.0, 0.10, 0.22)
    end
  end
  if grappling ~= 0 then
    if press then -- jump cancels (consumed; no auto flash-jump)
      grappling, grapple_cd, press = 0, k.grapple_cd, false
      puff(x + W * 0.5, y + H * 0.5, 4, 2.2)
    elseif grappling == 1 then -- EXTENDING: the hook climbs; you keep falling
      htipy = htipy - k.grapple_extend * DT
      if htipy <= gy then grappling, htipy = 2, gy end -- connect -> reel
    else -- grappling == 2: REELING from the velocity you connected with. Stop
      reel_t = reel_t + 1 -- a couple of CH SHORT of the platform so the residual
      vy = m.max(vy - k.grapple_accel * DT, -k.grapple_vmax) -- coasts up under
      vx = approach(vx, 0, k.grapple_accel * DT) -- gravity (damps the launch);
      if (y + H) <= gy + k.grapple_stop_ch * H -- a min duration keeps very
         and reel_t >= k.grapple_min_t then    -- short grapples a real launch
        grappling, grapple_cd = 0, k.grapple_cd
      end
    end
  end

  -- ===== WALK / AIR CONTROL (locked out for the WHOLE grapple — extend and
  -- reel — until it's cancelled; the grapple is a committed vertical move) =====
  if grappling == 0 then
    if dir ~= 0 then facing = dir end
    if grounded then
      if dir ~= 0 then
        vx = approach(vx, dir * k.walk_speed, k.walk_accel * DT)
      else
        vx = approach(vx, 0, k.ground_fric * DT)
      end
    else -- airborne: holding a dir trims the arc / steers the flutter hover
      if dir ~= 0 then
        vx = m.clamp(vx + dir * k.air_accel * DT, -k.fj_vx, k.fj_vx)
      else -- air drag also applies mid-flutter, so the slight per-beat forward
        vx = approach(vx, 0, k.air_fric * DT) -- diagonal stays a gentle drift
      end
    end
  end

  -- ===== JUMP INTENT: ground/coyote buffers; airborne = up-jump or FJ =====
  if press then
    if grounded or coyote > 0 then
      jbuf = k.buffer
    elseif ctl.up and upjumped == 0 then -- UP JUMP — rise upjump_h above here
      vy = -m.sqrt(2.0 * g_rise * k.upjump_h) -- (height-based: survives gravity
      upjumped, coyote = 1, 0                 -- tweaks; time it late for less)
      ring(x + W * 0.5, y + H, 9, 80, 3.0, 4.0, 0.12, 0.26)
    elseif upjumped == 0 and fj_used == 0 then -- FLASH JUMP (once per airtime;
      vx = facing * k.fj_vx                    -- also locked out by an up-jump)
      vy = k.fj_vy
      fj_used = 1
      ring(x + W * 0.5 - facing * 4, y + H * 0.5, 14, 130, 3.0, 4.2, 0.14, 0.32)
    end
  end

  -- ===== buffered GROUND JUMP (+ down+jump drop-through) =====
  if jbuf > 0 and (grounded or coyote > 0) then
    if ctl.down and grounded and on_oneway then
      drop = 8 -- fall through the plank
    else
      vy = -v0
      coyote = 0
      puff(x + W * 0.5, y + H, 3)
    end
    jbuf = 0
  else
    jbuf = m.max(0, jbuf - 1)
  end

  -- ===== HOP (E) — once/airtime; never while attacking or on flutter cd ====
  local can_hop = hop_used == 0 and hop_cd <= 0 and not ctl.attack_held
                  and grappling == 0
  if ctl.hop_pressed and can_hop then
    vx = vx + facing * k.hop_vx
    vy = -m.sqrt(2.0 * g_rise * k.hop_h) -- height-based (survives gravity tweaks)
    hop_used, hop_active = 1, 1
    puff(x + W * 0.5, y + H, 4, 0.8)
  end

  -- ===== FLUTTER (hold E after a hop) — once you've started FALLING (past the
  -- hop's apex) and you're STILL holding, HOVER by rhythm: a small UPWARD boost
  -- (a mini hop, height-based; + an optional forward nudge flutter_vx) every
  -- flutter_interval frames, flutter_boosts times, each sized (flutter_h) to
  -- roughly hold your altitude over the beat — NOT a continuous glide. flutter_t
  -- counts frames
  -- since the hover began; the cooldown (hop_cd) arms when it ends (release /
  -- timeout / land, below), so a plain TAP — E let go before you fall — is a
  -- clean hop with no cd (the "must be falling" gate IS the tap guard). =====
  local flutter_total = k.flutter_interval * m.max(1, k.flutter_boosts)
  if hop_active > 0 then
    local hold = ctl.hop_held and grappling == 0 and not ctl.attack_held
    if fluttering == 1 then
      if not hold or grounded or flutter_t >= flutter_total then
        hop_cd = k.hop_cd -- a real flutter happened -> cooldown
        fluttering, hop_active, flutter_t = 0, 0, 0 -- reset ft so a later
        -- teleport (which re-arms hop_cd while ft>0) can't refresh the cd
      else
        if flutter_t % k.flutter_interval == 0 then -- the beat: a mini UP-hop
          vy = -m.sqrt(2.0 * g_rise * k.flutter_h)  -- up (~holds height/beat)
          if k.flutter_vx ~= 0 then -- slight up-FORWARD diagonal (< vy, so <45°
            vx = m.clamp(vx + facing * k.flutter_vx, -k.fj_vx, k.fj_vx) -- from up)
          end
          puff(x + W * 0.5, y + H, 2, 2.4)
        end
        flutter_t = flutter_t + 1
      end
    elseif not hold or grounded then
      hop_active = 0 -- released / landed before falling: a clean hop, no cd
    elseif vy > 0 then -- started falling while holding: the hover begins
      fluttering, flutter_t = 1, 0 -- cancel carried momentum (so a flash-jump
      vx = 0                       -- doesn't launch you far); the boosts then
    end                            -- nudge you forward a little (flutter_vx)
  end

  -- ===== GRAVITY (normal during the extend phase; the reel drives vy itself.
  -- Flutter no longer eases gravity — it rhythm-boosts vy above, so normal
  -- gravity acts between the beats) ===
  if grappling ~= 2 then
    local g = (vy < 0) and g_rise or (g_rise * k.fall_mul)
    vy = m.min(vy + g * DT, k.fall_max)
  end

  -- ===== MOVE + COLLIDE (the frozen exact mover) =====
  local nx, ny, hit = tm:move(x, y, W, H, vx * DT, vy * DT, { drop = drop > 0 })
  if k.mantle > 0 and not hit.down and vy >= 0 and drop <= 0
     and grappling ~= 2 then
    local top, ow = mantle_top(tm, nx, ny, W, H, k.mantle, hit.left, hit.right)
    if top then
      ny = top - H
      hit.left, hit.right = false, false
      hit.down, hit.oneway = true, ow
    end
  end
  drop = m.max(0, drop - 1)
  if hit.left or hit.right then vx = 0 end
  if hit.up then
    vy = m.max(vy, 0.0)
    if grappling == 2 then grappling, grapple_cd = 0, k.grapple_cd end -- reel
  end                                                                  -- bonked

  if hit.down then
    if not was_grounded and vy > 60 then -- landing squash + dust
      buf:f32(O.land, vy)
      squash_t = feel.squash_t
      local burst = m.floor(m.clamp(vy / 60.0, 2, 9))
      fx.spawn(nx + W * 0.5, ny + H, burst,
               { vx0 = -55, vx1 = 55, vy0 = -45, vy1 = -8,
                 shade0 = 0.2, shade1 = 1.0 })
    end
    vy = 0
    grounded, on_oneway = true, hit.oneway or false
    coyote = k.coyote
    hop_used, upjumped, grapple_used, fj_used = 0, 0, 0, 0 -- per-airtime reset
    if hop_active > 0 and flutter_t > 0 then hop_cd = k.hop_cd end
    fluttering, hop_active, flutter_t = 0, 0, 0
    -- NB: landing does NOT cancel a grapple — the hook extends while you stand
    -- (grounded grapple), then the reel lifts you off; the extend phase always
    -- connects, so there is no "stuck on the ground" case to cancel
    if ctl.jump_held then jbuf = k.buffer end -- auto-repeat: hold to bounce
  else
    grounded, on_oneway = false, false
    coyote = m.max(0, coyote - 1)
  end

  -- ===== ATTACK (hold D) — continuous slice stub (enemies at M12) =====
  if ctl.attack_held then
    attack_t = attack_t - 1
    if attack_t <= 0 then
      attack_t = k.attack_interval
      local sx = nx + W * 0.5 + facing * (W * 0.5 + k.attack_reach * 0.4)
      fx.spawn(sx, ny + H * 0.45, 5,
               { vx0 = facing * 60, vx1 = facing * 210,
                 vy0 = -36, vy1 = 36, life0 = 0.07, life1 = 0.16,
                 shade0 = 2.0, shade1 = 3.6 })
    end
  else
    attack_t = 0
  end

  -- ===== cooldown timers (integer-frame) =====
  hop_cd = m.max(0, hop_cd - 1)
  grapple_cd = m.max(0, grapple_cd - 1)
  tp_cd = m.max(0, tp_cd - 1)

  -- ===== cosmetic trails =====
  local frame = state.frame()
  if fluttering == 1 and frame % 4 == 0 then -- hover shimmer
    fx.spawn(nx + W * 0.5, ny + H * 0.6, 1,
             { vx0 = -16, vx1 = 16, vy0 = -22, vy1 = -6,
               life0 = 0.22, life1 = 0.40, shade0 = 2.6, shade1 = 3.4 })
  end
  if grappling == 2 and frame % 2 == 0 then -- motes streaming up while reeling
    fx.spawn(nx + W * 0.5, ny, 1,
             { vx0 = -8, vx1 = 8, vy0 = -180, vy1 = -90,
               life0 = 0.10, life1 = 0.20, shade0 = 3.0, shade1 = 4.0 })
  end
  local dust = buf:f32(O.dust)
  if grounded and dir ~= 0 and m.abs(vx) > k.walk_speed * 0.5 then
    dust = dust + m.abs(vx) * DT
    if dust >= kf.run_dist then
      dust = dust - kf.run_dist
      fx.spawn(nx + W * 0.5 - facing * 3, ny + H, 1,
               { vx0 = -facing * 28, vx1 = -facing * 8, vy0 = -26, vy1 = -8,
                 shade0 = 0.3, shade1 = 0.9 })
    end
  else
    dust = 0
  end

  -- ===== write back =====
  buf:f32(O.x, nx); buf:f32(O.y, ny)
  buf:f32(O.vx, vx); buf:f32(O.vy, vy)
  buf:f32(O.facing, facing)
  buf:f32(O.grounded, grounded and 1.0 or 0.0)
  buf:f32(O.on_oneway, on_oneway and 1.0 or 0.0)
  buf:f32(O.coyote, coyote); buf:f32(O.jbuf, jbuf); buf:f32(O.drop, drop)
  buf:f32(O.hop_used, hop_used); buf:f32(O.upjumped, upjumped)
  buf:f32(O.grapple_used, grapple_used); buf:f32(O.fj_used, fj_used)
  buf:f32(O.hop_active, hop_active); buf:f32(O.fluttering, fluttering)
  buf:f32(O.flutter_t, flutter_t); buf:f32(O.hop_cd, hop_cd)
  buf:f32(O.grappling, grappling); buf:f32(O.gx, gx); buf:f32(O.gy, gy)
  buf:f32(O.htipy, htipy); buf:f32(O.reel_t, reel_t)
  buf:f32(O.grapple_cd, grapple_cd)
  buf:f32(O.tp_mode, tp_mode); buf:f32(O.tp_cd, tp_cd)
  buf:f32(O.attack_t, attack_t)
  buf:f32(O.squash_t, m.max(0, squash_t - DT))
  buf:f32(O.stretch_t, m.max(0, stretch_t - DT))
  buf:f32(O.anim, buf:f32(O.anim) + m.abs(vx) * DT * 0.09)
  buf:f32(O.dust, dust)
  buf:f32(O.tp_flash, m.max(0, buf:f32(O.tp_flash) - 0.12))
end

-- ---- sprite ----
-- The sprite is a RENDER-ONLY asset (STUDIO.md §1, D040): the game loads the
-- studio-baked strip art/girl.png + clips art/girl.anim at boot — file bytes are
-- NOT sim input (D026), exactly like a texture or map.dat — so authoring it in
-- the F2 studio cannot perturb a trace (the M10 Phase 4 payoff). The strip is
-- 16x24 cells laid L→R: poses 0..10 are the moveset frames, selected from sim
-- state below (the state-driven mode, STUDIO.md §7); frame 11 is the idle-breath
-- the timed "idle" CLIP cycles via cm.anim. NF is derived from the loaded width.
--
-- build_sprite below is the PROCEDURAL FALLBACK, used only if the asset is
-- missing (a fresh tree / a project with no art) — same 0..10 pose set, 11 frames.
-- Regenerate the asset: --eval "cm.require('genart').girl()" (see genart.lua).

local FW, FH = 16, 24

local function build_sprite()
  local img = pix.img(NF * FW, FH)
  local HAIR = { 0.30, 0.26, 0.42 }
  local SKIN = { 0.97, 0.86, 0.74 }
  local SUIT = { 0.93, 0.94, 0.98 }
  local SHAD = { 0.66, 0.70, 0.84 }
  local CYAN = { 0.42, 0.86, 0.98 }
  local DARK = { 0.15, 0.14, 0.20 }
  local function R(o, x, y, w, h, c) img.rect(o + x, y, w, h, c[1], c[2], c[3]) end
  local function P(o, x, y, c) img.px(o + x, y, c[1], c[2], c[3]) end

  -- head at cell-local (hx, hy), 6 wide. eye_dx shifts the eye for a look dir.
  local function head(o, hx, hy, eye_dx)
    R(o, hx, hy, 6, 3, HAIR)
    P(o, hx - 1, hy + 1, HAIR); P(o, hx + 6, hy + 1, HAIR)
    R(o, hx, hy + 3, 6, 4, SKIN)
    P(o, hx + 2 + (eye_dx or 0), hy + 4, DARK)
    P(o, hx + 4 + (eye_dx or 0), hy + 4, DARK)
    R(o, hx, hy + 7, 6, 1, HAIR) -- fringe shadow
  end

  -- torso top-left (tx, ty), w x h, with a cyan accent seam down the middle
  local function torso(o, tx, ty, tw, th)
    R(o, tx, ty, tw, th, SUIT)
    R(o, tx, ty + th - 1, tw, 1, SHAD)
    R(o, tx + tw // 2, ty + 1, 1, th - 1, CYAN)
  end

  -- frame 0: idle
  do local o = 0 * FW
    head(o, 5, 2, 0)
    torso(o, 4, 10, 8, 6)
    R(o, 3, 10, 1, 4, SUIT); R(o, 12, 10, 1, 4, SUIT) -- arms down
    R(o, 5, 16, 2, 5, SHAD); R(o, 9, 16, 2, 5, SHAD) -- legs
    P(o, 5, 21, CYAN); P(o, 10, 21, CYAN) -- boot glow
  end
  -- frames 1-2: walk (legs + arm swing alternate)
  do local o = 1 * FW
    head(o, 5, 2, 1)
    torso(o, 4, 10, 8, 6)
    R(o, 2, 11, 2, 3, SUIT); R(o, 12, 11, 2, 2, SUIT) -- arms swing
    R(o, 4, 16, 2, 5, SHAD); R(o, 10, 16, 2, 4, SHAD) -- stride
  end
  do local o = 2 * FW
    head(o, 5, 2, 1)
    torso(o, 4, 10, 8, 6)
    R(o, 3, 11, 2, 2, SUIT); R(o, 12, 11, 2, 3, SUIT)
    R(o, 6, 16, 2, 4, SHAD); R(o, 9, 16, 2, 5, SHAD)
  end
  -- frame 3: rise (legs tucked, arms up)
  do local o = 3 * FW
    head(o, 5, 3, 0)
    torso(o, 4, 11, 8, 6)
    R(o, 3, 8, 2, 3, SUIT); R(o, 11, 8, 2, 3, SUIT) -- arms up
    R(o, 5, 17, 2, 3, SHAD); R(o, 9, 17, 2, 3, SHAD) -- knees up
  end
  -- frame 4: fall (arms out)
  do local o = 4 * FW
    head(o, 5, 3, 0)
    torso(o, 4, 11, 8, 6)
    R(o, 1, 11, 3, 2, SUIT); R(o, 12, 11, 3, 2, SUIT) -- arms wide
    R(o, 5, 17, 2, 5, SHAD); R(o, 9, 17, 2, 5, SHAD)
  end
  -- frame 5: dash / flash jump (leaning forward, trailing limbs; faces right)
  do local o = 5 * FW
    head(o, 7, 3, 1)
    R(o, 3, 11, 9, 5, SUIT) -- torso swept back
    R(o, 5, 15, 7, 1, SHAD)
    R(o, 6, 11, 1, 4, CYAN) -- accent streak
    R(o, 1, 12, 3, 2, SUIT) -- trailing arm
    R(o, 2, 16, 4, 2, SHAD); R(o, 5, 18, 3, 2, SHAD) -- trailing legs
  end
  -- frame 6: up jump (stretched vertical, arms straight up)
  do local o = 6 * FW
    head(o, 5, 4, 0)
    torso(o, 4, 12, 8, 7)
    R(o, 4, 7, 2, 5, SUIT); R(o, 10, 7, 2, 5, SUIT) -- arms straight up
    P(o, 4, 7, CYAN); P(o, 11, 7, CYAN)
    R(o, 6, 19, 2, 4, SHAD); R(o, 8, 19, 2, 4, SHAD) -- legs together
  end
  -- frame 7: hop (compact crouch-leap)
  do local o = 7 * FW
    head(o, 5, 5, 0)
    torso(o, 4, 12, 8, 5)
    R(o, 2, 13, 2, 2, SUIT); R(o, 12, 13, 2, 2, SUIT)
    R(o, 4, 17, 3, 3, SHAD); R(o, 9, 17, 3, 3, SHAD) -- knees drawn up
  end
  -- frame 8: hover / flutter (arms out wide, floaty)
  do local o = 8 * FW
    head(o, 5, 3, 0)
    torso(o, 4, 10, 8, 6)
    R(o, 0, 10, 4, 2, SUIT); R(o, 12, 10, 4, 2, SUIT) -- wide arms
    P(o, 0, 10, CYAN); P(o, 15, 10, CYAN)
    R(o, 5, 16, 2, 4, SHAD); R(o, 9, 16, 2, 4, SHAD)
    P(o, 5, 20, CYAN); P(o, 10, 20, CYAN)
  end
  -- frame 9: grapple (one arm reaching up, body stretched)
  do local o = 9 * FW
    head(o, 5, 5, 0)
    torso(o, 4, 12, 8, 6)
    R(o, 9, 4, 2, 9, SUIT) -- reaching arm
    P(o, 9, 4, CYAN); P(o, 10, 4, CYAN)
    R(o, 4, 13, 2, 3, SUIT) -- other arm
    R(o, 5, 18, 2, 4, SHAD); R(o, 9, 18, 2, 4, SHAD)
  end
  -- frame 10: attack (arm thrust forward; faces right)
  do local o = 10 * FW
    head(o, 4, 3, 1)
    torso(o, 3, 11, 8, 6)
    R(o, 10, 12, 5, 2, SUIT) -- extended arm
    P(o, 14, 12, CYAN); P(o, 14, 13, CYAN) -- blade root glow
    R(o, 4, 17, 2, 5, SHAD); R(o, 8, 17, 2, 5, SHAD)
  end
  return img.tex()
end

-- load the baked strip + clips (render-only; pcall so a missing asset cleanly
-- falls back to the procedural build_sprite at 11 frames with no clips).
local function load_sprite()
  local proj = cm.main and cm.main.args and cm.main.args.project
  if proj then
    local ok, tex = pcall(gfx.texture, proj .. "/art/girl.png")
    if ok and tex then
      return tex, m.max(1, tex.w // FW), anim.load(proj .. "/art/girl.anim")
    end
  end
  return build_sprite(), 11, nil
end

local sprite, NF, clips = load_sprite()
local idle_clip = clips and anim.find(clips, "idle")

function M.draw()
  local k = state.doc.knobs.move
  local feel = state.doc.knobs.feel
  local x, y = buf:f32(O.x), buf:f32(O.y)
  local vx, vy = buf:f32(O.vx), buf:f32(O.vy)
  local facing = buf:f32(O.facing)
  local W, H = M.W, M.H
  local grounded = buf:f32(O.grounded) == 1.0
  local fluttering = buf:f32(O.fluttering) == 1.0
  local grappling = buf:f32(O.grappling) > 0.5 -- 1 extending or 2 reeling
  local upjumped = buf:f32(O.upjumped) == 1.0
  local attacking = buf:f32(O.attack_t) > 0
  local mode = buf:f32(O.tp_mode)

  -- grapple beam first (under the body): a cyan line up to the climbing hook
  -- tip (htipy reaches the anchor gy when it connects, then the reel shrinks it)
  if grappling then
    local cxp = x + W * 0.5
    local tipy = buf:f32(O.htipy)
    pal.quad(cxp - 0.5, tipy, 1, m.max(0, y - tipy), 0.42, 0.86, 0.98, 0.7)
    pal.quad(cxp - 2, tipy - 1, 4, 2, 0.7, 0.95, 1.0, 0.9) -- the hook tip
  end

  local f
  if grappling then f = 9
  elseif fluttering then f = 8
  elseif attacking and grounded and m.abs(vx) < 6 then f = 10
  elseif not grounded then
    if m.abs(vx) > k.fj_vx * 0.55 then f = 5
    elseif vy < -40 then f = upjumped and 6 or 3
    else f = 4 end
  elseif m.abs(vx) > 6 then
    f = m.floor(buf:f32(O.anim)) % 2 == 0 and 1 or 2
  else -- idle: play the timed BREATH clip if the asset shipped one — a COSMETIC
    f = idle_clip and anim.frame_at(idle_clip, state.frame()) or 0 -- clip off the
  end                                  -- integer frame counter (D030: zero stored
  f = m.min(f, NF - 1)                 -- state, pure, render-only — can't perturb
                                       -- the trace). Clamp guards a short fallback.

  -- squash & stretch around the feet
  local sx, sy = 1.0, 1.0
  local sq = ease.cubic_in(m.clamp(buf:f32(O.squash_t) / feel.squash_t, 0, 1))
             * feel.squash * m.clamp(buf:f32(O.land) / 360.0, 0.3, 1.0)
  local st = ease.cubic_in(m.clamp(buf:f32(O.stretch_t) / feel.stretch_t, 0, 1))
             * feel.stretch
  if not grounded then st = st + m.clamp(m.abs(vy) / 900.0, 0, 0.22) end
  sx = 1.0 + sq * 0.9 - st * 0.5
  sy = 1.0 - sq * 0.6 + st * 0.6

  -- phase-shift mode tint: mode A solid/white, mode B cyan + translucent.
  -- a teleport flash brightens both for a frame or two.
  local tr, tg, tb, ta = 1, 1, 1, 1
  if mode == 1 then tr, tg, tb, ta = 0.55, 0.93, 1.0, 0.82 end
  local flash = buf:f32(O.tp_flash)
  if flash > 0 then
    tr = tr + (1 - tr) * flash
    tg = tg + (1 - tg) * flash
    tb = tb + (1 - tb) * flash
    ta = ta + (1 - ta) * flash
  end

  local dw, dh = W * sx, H * sy
  local dx = x + W * 0.5 - dw * 0.5
  local dy = y + H - dh -- feet-anchored
  local u0 = (f * FW) / sprite.w
  local u1 = (f * FW + FW) / sprite.w
  if facing < 0 then u0, u1 = u1, u0 end
  pal.quad(dx, dy, dw, dh, tr, tg, tb, ta, sprite.id, u0, 0, u1, 1)
end

return M
