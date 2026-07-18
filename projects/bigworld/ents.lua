-- ents — entities EVERYWHERE (COSMIC3D.md §10): ~4000 mascot-variant
-- wanderers scattered across the whole streaming world, in ONE named sim
-- buffer. The scheduling directive ("efficiently update — or don't —
-- entities far from the player") lands as a structural answer, not a
-- budget loop:
--
--   * A FAR entity is (route, phase): its route is a circle around a home
--     point and its position is a CLOSED FORM of the frame counter —
--     advancing it any number of frames is O(1) and exact, so far
--     entities cost literally nothing per frame, and trajectories cannot
--     depend on scheduling (no hash order, no update-rate drift — the
--     §8e sim-legality question answered by construction).
--   * A NEAR entity (deterministic distance test + hysteresis against
--     the player) is PROMOTED into a small near-list and runs the
--     interactive kernel: greet-and-wave (the D3D-020 beat, chime pitched
--     by species), route freeze while greeting (phase_off absorbs the
--     pause, so demotion needs no re-anchoring at all), the D3D-024
--     won't-plow-the-player wait, and solidity via M.boxes().
--   * Spatial access is by HOME CHUNK: buckets are rebuilt at init from
--     the same pure placement streams (memoizing a pure function), so the
--     sim scans only the 3x3-ish window around the player and the
--     renderer only the draw window — never the full population.
--
-- Slot layout (48B, f32): +0 home_x +4 home_z +8 rad +12 w (rad/frame,
-- signed) +16 base_ang +20 phase_off +24 kind +28 mode (0 far, 1 near
-- armed, 2 near greeted) +32 greet-start frame+1 +36 yaw +40/+44 spare.
-- Position = home + (cos,sin)(base_ang + w*frame + phase_off) * rad.
-- Buffer header (16B): +0 placed flag, +4 count. "bw.near" holds the
-- promoted slot indices (u32 count + indices) — sim state, so traces
-- replay the exact promote/demote history.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local fig = cm.require("cm.fig")
local mascot = cm.require("cm.mascot")
local world = cm.require("world")
local player = cm.require("player")
local audio = cm.require("audio")

local M = select(2, ...) or {}

local HDR = 16
local SLOT = 48
local CAP = 4000
local NEAR_CAP = 24

-- the four species (color variants; the chime rises with kind)
local KINDS = {
  { body = { 0.93, 0.55, 0.42 }, belly = { 0.97, 0.92, 0.80 },
    mitt = { 0.30, 0.58, 0.60 } }, -- coral/teal (the watcher's cousin)
  { body = { 0.70, 0.58, 0.86 }, belly = { 0.96, 0.93, 0.84 },
    mitt = { 0.44, 0.62, 0.36 } }, -- lavender/moss (the wanderer's)
  { body = { 0.52, 0.68, 0.88 }, belly = { 0.92, 0.95, 0.98 },
    mitt = { 0.90, 0.72, 0.34 } }, -- sky/gold
  { body = { 0.88, 0.80, 0.46 }, belly = { 0.98, 0.95, 0.86 },
    mitt = { 0.50, 0.40, 0.62 } }, -- wheat/plum
}
local VFIG = {}
for i, k in ipairs(KINDS) do VFIG[i] = mascot.build(k) end
local TOTEM = {} -- far-LOD colors: body tint per kind
for i, k in ipairs(KINDS) do TOTEM[i] = k.body end

local buf, nearbuf
M.by_chunk = {} -- home-chunk id -> { slot indices }, rebuilt every init

local function xs32(st)
  local s = st[1]
  s = (s ~ (s << 13)) & 0xffffffff
  s = s ~ (s >> 17)
  s = (s ~ (s << 5)) & 0xffffffff
  st[1] = s
  return s
end

-- closed-form position (and route angle) of slot i at frame f
local function pos_of(i, f)
  local o = HDR + i * SLOT
  local ang = buf:f32(o + 16) + buf:f32(o + 12) * f + buf:f32(o + 20)
  local rad = buf:f32(o + 8)
  return buf:f32(o) + m.cos(ang) * rad,
         buf:f32(o + 4) + m.sin(ang) * rad, ang
end

-- placement: per-chunk streams (draws before accepts, D3D-022), identical
-- every run. Returns the slot list so init can (re)build the buckets
-- without touching an already-placed buffer.
local function place()
  local slots = {}
  local WCH, CH_T, TILE = world.WCH, world.CH_T, world.TILE
  local cs = CH_T * TILE
  for cz = 0, WCH - 1 do
    for cx = 0, WCH - 1 do
      local seed = ((cx * 668265263) ~ (cz * 374761393) ~ 0x51e57e11)
                   & 0xffffffff
      local st = { seed ~= 0 and seed or 1 }
      local n = xs32(st) % 3 -- 0..2 per chunk, ~1 average
      for _ = 1, n do
        local hx = cx * cs + (40 + xs32(st) % (CH_T * 20 - 80)) / 10.0
        local hz = cz * cs + (40 + xs32(st) % (CH_T * 20 - 80)) / 10.0
        local rad = 2.5 + (xs32(st) % 30) / 10.0
        local speed = (100 + xs32(st) % 100) / 6000.0 -- u/frame
        local sgn = xs32(st) % 2 == 0 and 1 or -1
        local base = (xs32(st) % 628) / 100.0
        local kind = xs32(st) % 4
        if #slots < CAP then
          -- the route must stay on land it can amble: home + 3 ring
          -- points on walkable ground, no water, no cliffs-into-snow
          local ok = true
          local h = world.ground(hx, hz)
          if h < 0.35 or h > 7.0 then ok = false end
          if ok then
            for a = 0, 2 do
              local ang = a * (m.tau / 3)
              local rh = world.ground(hx + m.cos(ang) * rad,
                                      hz + m.sin(ang) * rad)
              if rh < 0.35 or rh > 7.0 then
                ok = false
                break
              end
            end
          end
          if ok then
            slots[#slots + 1] = { hx = hx, hz = hz, rad = rad,
              w = sgn * speed / rad, base = base, kind = kind,
              chunk = cz * WCH + cx }
          end
        end
      end
    end
  end
  return slots
end

function M.init()
  local size = HDR + CAP * SLOT
  local ok, b = pcall(pal.buf, "bw.ents", size)
  if not ok then
    pal.buf_free("bw.ents")
    b = pal.buf("bw.ents", size)
  end
  buf = b
  local ok2, nb = pcall(pal.buf, "bw.near", 4 + NEAR_CAP * 4)
  if not ok2 then
    pal.buf_free("bw.near")
    nb = pal.buf("bw.near", 4 + NEAR_CAP * 4)
  end
  nearbuf = nb

  local slots = place() -- pure: recomputed every init for the buckets
  M.by_chunk = {}
  for i, s in ipairs(slots) do
    local bucket = M.by_chunk[s.chunk]
    if not bucket then
      bucket = {}
      M.by_chunk[s.chunk] = bucket
    end
    bucket[#bucket + 1] = i - 1
  end
  if buf:f32(0) ~= 1.0 then -- virgin buffer: write the placement
    for i, s in ipairs(slots) do
      local o = HDR + (i - 1) * SLOT
      buf:f32(o, s.hx); buf:f32(o + 4, s.hz)
      buf:f32(o + 8, s.rad); buf:f32(o + 12, s.w)
      buf:f32(o + 16, s.base); buf:f32(o + 20, 0)
      buf:f32(o + 24, s.kind); buf:f32(o + 28, 0)
      buf:f32(o + 32, 0); buf:f32(o + 36, s.base + m.pi / 2)
    end
    buf:f32(0, 1.0)
    buf:f32(4, #slots)
  end
end

function M.count()
  return nearbuf:u32(0), buf:f32(4) // 1
end

-- the near entities' collider AABBs (D3D-024: solid, boxes inside the
-- round visual) — main passes these into player.step
function M.boxes()
  local k = state.doc.knobs.ents
  local hw = k.cw / 2
  local f = state.frame()
  local out = {}
  for j = 0, nearbuf:u32(0) - 1 do
    local i = nearbuf:u32(4 + j * 4)
    local x, z = pos_of(i, f)
    local y = world.ground(x, z)
    out[#out + 1] = { x - hw, y, z - hw, x + hw, y + k.ch, z + hw }
  end
  return out
end

local function greeting_since(o, f) -- frames since greet start, or nil
  local k = state.doc.knobs.ents
  local s = buf:f32(o + 32)
  if s > 0 and f - (s - 1) < k.hold then return f - (s - 1) end
  return nil
end

function M.step()
  local k = state.doc.knobs.ents
  local f = state.frame()
  local px, _, pz = player.pos()
  local WCH, CH_T, TILE = world.WCH, world.CH_T, world.TILE
  local cs = CH_T * TILE

  -- 1) demote: near slots past demote_r drop back to closed-form far
  -- (swap-remove; phase_off already absorbed every pause, so a demoted
  -- slot needs nothing — its closed form is already correct)
  local nn = nearbuf:u32(0)
  local j = 0
  while j < nn do
    local i = nearbuf:u32(4 + j * 4)
    local x, z = pos_of(i, f)
    local dx, dz = x - px, z - pz
    if dx * dx + dz * dz > k.demote_r * k.demote_r then
      local o = HDR + i * SLOT
      buf:f32(o + 28, 0)
      nn = nn - 1
      nearbuf:u32(4 + j * 4, nearbuf:u32(4 + nn * 4))
    else
      j = j + 1
    end
  end
  nearbuf:u32(0, nn)

  -- 2) promote: scan the chunk window around the player (fixed cz/cx and
  -- bucket order — deterministic), far slots inside promote_r join
  local pcx = m.clamp((px / cs) // 1, 0, WCH - 1)
  local pcz = m.clamp((pz / cs) // 1, 0, WCH - 1)
  local sr = (k.promote_r / cs) // 1 + 1
  for cz = m.max(0, pcz - sr), m.min(WCH - 1, pcz + sr) do
    for cx = m.max(0, pcx - sr), m.min(WCH - 1, pcx + sr) do
      local bucket = M.by_chunk[cz * WCH + cx]
      if bucket then
        for _, i in ipairs(bucket) do
          local o = HDR + i * SLOT
          if buf:f32(o + 28) == 0 and nn < NEAR_CAP then
            local x, z = pos_of(i, f)
            local dx, dz = x - px, z - pz
            if dx * dx + dz * dz < k.promote_r * k.promote_r then
              buf:f32(o + 28, 1) -- armed
              nearbuf:u32(4 + nn * 4, i)
              nn = nn + 1
            end
          end
        end
      end
    end
  end
  nearbuf:u32(0, nn)

  -- 3) the near kernel: greet + hold + queue + facing
  for j2 = 0, nn - 1 do
    local i = nearbuf:u32(4 + j2 * 4)
    local o = HDR + i * SLOT
    local x, z, ang = pos_of(i, f)
    local dx, dz = px - x, pz - z
    local d2 = dx * dx + dz * dz
    local mode = buf:f32(o + 28)
    local w = buf:f32(o + 12)
    local held = greeting_since(o, f)

    local target
    if held then
      -- greeting: freeze on the route (phase_off absorbs the pause) and
      -- face the player
      buf:f32(o + 20, buf:f32(o + 20) - w)
      target = m.atan2(dx, dz)
    else
      if mode == 2 and d2 > k.exit_r * k.exit_r then
        buf:f32(o + 28, 1) -- re-arm past exit_r (hysteresis)
        mode = 1
      end
      if mode == 1 and d2 < k.greet_r * k.greet_r then
        buf:f32(o + 32, f + 1)
        buf:f32(o + 28, 2)
        audio.sfx("greet", 100, 76 + (buf:f32(o + 24) // 1) * 2)
        buf:f32(o + 20, buf:f32(o + 20) - w)
        target = m.atan2(dx, dz)
      else
        -- the D3D-024 wait: if next frame's route point closes inside
        -- stop_r on the player, hold this frame (direction-aware)
        local nx2, nz2 = pos_of(i, f + 1)
        local pd2 = (nx2 - px) ^ 2 + (nz2 - pz) ^ 2
        if pd2 < k.stop_r * k.stop_r and pd2 < d2 then
          buf:f32(o + 20, buf:f32(o + 20) - w)
          target = m.atan2(dx, dz) -- stopped: look at the obstacle
        else
          -- face along travel: d(pos)/d(ang) = (-sin, cos)*sign(w)
          local s = w >= 0 and 1 or -1
          target = m.atan2(-m.sin(ang) * s, m.cos(ang) * s)
        end
      end
    end
    local yaw = buf:f32(o + 36)
    local d = m.atan2(m.sin(target - yaw), m.cos(target - yaw))
    buf:f32(o + 36, m.fmod(yaw + d * k.turn, m.tau))
  end
end

-- ---- render-class from here down ----------------------------------------

-- near slots emit the full variant figure (walk/wave off the greet edges,
-- the npc.lua read); far slots within the draw window emit an 18-tri
-- totem LOD. Returns opaque tris.
function M.emit(out, fx, fz, draw_d)
  local k = state.doc.knobs.ents
  local feel = state.doc.knobs.feel
  local km = state.doc.knobs.move
  local f = state.frame()
  local WCH, CH_T, TILE = world.WCH, world.CH_T, world.TILE
  local cs = CH_T * TILE
  local fcx = m.clamp((fx / cs) // 1, 0, WCH - 1)
  local fcz = m.clamp((fz / cs) // 1, 0, WCH - 1)
  local r = (draw_d / cs) // 1 + 1
  local d2max = draw_d * draw_d
  local nt = 0
  for cz = m.max(0, fcz - r), m.min(WCH - 1, fcz + r) do
    for cx = m.max(0, fcx - r), m.min(WCH - 1, fcx + r) do
      local bucket = M.by_chunk[cz * WCH + cx]
      if bucket then
        for _, i in ipairs(bucket) do
          local o = HDR + i * SLOT
          local x, z, ang = pos_of(i, f)
          local dx, dz = x - fx, z - fz
          local d2 = dx * dx + dz * dz
          if d2 <= d2max then
            local kind = buf:f32(o + 24) // 1
            if buf:f32(o + 28) > 0 then
              -- full figure: idle+walk, wave blending off the greet edges
              local pose = fig.cycle(mascot.idle, f / feel.idle_f)
              local held = greeting_since(o, f)
              local s = buf:f32(o + 32)
              local wb, vb, wavephase = 1, 0, 0
              if held then
                wb = m.max(0, 1 - held / k.blend_f)
                vb = m.min(1, held / k.blend_f)
                wavephase = held / k.wave_f
              elseif s > 0 then
                local since_end = f - (s - 1) - k.hold
                wb = m.min(1, since_end / k.blend_f)
                vb = m.max(0, 1 - since_end / k.blend_f)
                wavephase = k.hold / k.wave_f
              end
              if wb > 0 then
                local phase = (ang * buf:f32(o + 8) / km.stride) % 1
                pose = fig.mix(pose, fig.cycle(mascot.walk, phase), wb)
              end
              if vb > 0 then
                pose = fig.mix(pose, fig.cycle(mascot.wave, wavephase), vb)
              end
              local root = m4.mul(m4.translate(x, world.ground(x, z), z),
                                  m4.roty(buf:f32(o + 36)))
              nt = nt + fig.emit(out, VFIG[kind + 1], root, pose)
            else
              -- totem LOD: a squat body prism + a head cone, kind-tinted;
              -- it bobs nothing, costs nothing, reads as "someone's there"
              local y = world.ground(x, z)
              local root = m4.mul(m4.translate(x, y, z),
                                  m4.roty(buf:f32(o + 36)))
              nt = nt + gb.prism(out, root, 5, 0.5, 0.34, 1.05,
                                 TOTEM[kind + 1], 0)
              nt = nt + gb.prism(out, m4.mul(root, m4.translate(0, 0.95, 0)),
                                 4, 0.3, 0.08, 0.55, TOTEM[kind + 1], 0)
            end
          end
        end
      end
    end
  end
  return nt
end

-- blob shadows for the NEAR entities only (far totems live in fog)
function M.emit_shadow(out)
  local f = state.frame()
  local nt = 0
  for j = 0, nearbuf:u32(0) - 1 do
    local i = nearbuf:u32(4 + j * 4)
    local x, z = pos_of(i, f)
    local e, rr = 0.6, 1.0
    local gy = world.ground(x, z)
    local dhx = (world.ground(x + e, z) - world.ground(x - e, z)) / (2 * e)
    local dhz = (world.ground(x, z + e) - world.ground(x, z - e)) / (2 * e)
    local white = { 1, 1, 1 }
    local lift = 0.06
    local function p(ddx, ddz)
      return { x + ddx, gy + lift + ddx * dhx + ddz * dhz, z + ddz }
    end
    local A, B, C, D = p(-rr, -rr), p(rr, -rr), p(rr, rr), p(-rr, rr)
    gb.quad(out, { A[1], A[2], A[3], 0, 0 }, { B[1], B[2], B[3], 1, 0 },
            { C[1], C[2], C[3], 1, 1 }, { D[1], D[2], D[3], 0, 1 },
            white, 0, 0, 0, 127)
    nt = nt + 2
  end
  return nt
end

return M
