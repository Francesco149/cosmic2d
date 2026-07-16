-- bounce main.lua — demo 1's movement slice: the bouncy cube running and
-- jumping around an axis-aligned graybox playground, pull-string follow
-- camera, every feel value a live knob (the smoke KNOBS pattern, D028).
--
-- Controls: arrows move (camera-relative: up = away from camera) · space
-- jump · z/x orbit the camera · ` console (game.demo(1) = autoplay loop).
--
-- Determinism: sim state in named buffers (bounce.player/bounce.cam) + doc
-- tree; cm.math trig; fixed dt. The follow camera is GAMEPLAY state (input
-- is camera-relative, so the sim must know it — the smoke cam precedent),
-- stepped in game.step; view/proj matrices stay render-class in draw.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m4 = cm.require("cm.m4")
local gb = cm.require("gb")
local level = cm.require("level")
local player = cm.require("player")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 52, 0.3, 120

local game = {}
game.level = level -- console reach

-- feel knobs, all live (doc tree -> console, snapshots). Units: world units
-- (the cube is 1u tall), seconds, frames where named _t/frames.
local KNOBS = {
  move = {
    cw = 0.9, ch = 1.0, -- collider box (visual cube is 1x1x1)
    speed = 6.5, accel = 40, fric = 30, air_accel = 20, air_fric = 4,
    jump_h = 1.9, jump_apex_t = 22, fall_mul = 1.5, fall_max = 22,
    coyote = 6, buffer = 5, turn = 0.25,
  },
  cam = {
    dist = 7.5, height = 3.2, look_h = 1.0,
    lerp = 0.10, lerp_y = 0.06, orbit = 0.045,
  },
  feel = {
    stretch = 0.32, squash = 0.42, vref = 12,
    squash_frames = 10, lean = 0.15,
  },
}

local cam, dyn, skybuf

local function knob_file() return cm.main.args.project .. "/knobs.dat" end

local function load_knobs()
  local bytes = pal.read_file(knob_file())
  if not bytes then return nil end
  local ok, t = pcall(state.parse, bytes)
  if ok and type(t) == "table" then return t end
  pal.log("[knobs] knobs.dat unreadable; using defaults")
  return nil
end

function game.save_knobs()
  return pal.write_file(knob_file(), state.canon(state.doc.knobs))
end

local function build_sky()
  skybuf = pal.buf("bounce.sky", 6 * 24)
  local function sv(x, y, c)
    return string.pack("<fffffBBBB", x, y, 0.9999, 0, 0,
                       (c[1] * 255) // 1, (c[2] * 255) // 1, (c[3] * 255) // 1, 255)
  end
  local t, b = level.sky_top, level.sky_bot
  local v0, v1 = sv(-1, 1, t), sv(1, 1, t)
  local v2, v3 = sv(1, -1, b), sv(-1, -1, b)
  skybuf:setstr(0, v0 .. v1 .. v2 .. v0 .. v2 .. v3)
end

function game.init()
  local d = state.doc
  d.knobs = d.knobs or load_knobs() or {}
  for group, defaults in pairs(KNOBS) do
    d.knobs[group] = d.knobs[group] or {}
    for key, v in pairs(defaults) do
      if d.knobs[group][key] == nil then d.knobs[group][key] = v end
    end
    for key in pairs(d.knobs[group]) do
      if defaults[key] == nil then d.knobs[group][key] = nil end
    end
  end
  if d.demo == nil then d.demo = 0 end
  if d.demo_t0 == nil then d.demo_t0 = 0 end

  level.build()
  player.init()
  build_sky()

  -- dyn: per-frame cube + shadow verts (render-class scratch, rebuilt in
  -- draw; lives in a named buffer only so the PAL can read it)
  dyn = pal.buf("bounce.dyn", 74 * 72)

  cam = pal.buf("bounce.cam", 12) -- f32 x,y,z
  if cam:f32(0) == 0 and cam:f32(4) == 0 and cam:f32(8) == 0 then
    local px, py, pz = player.pos()
    cam:f32(0, px - state.doc.knobs.cam.dist) -- behind the +x-facing spawn
    cam:f32(4, py + state.doc.knobs.cam.height)
    cam:f32(8, pz)
  end

  input.map({
    { "left", input.key.left }, { "right", input.key.right },
    { "up", input.key.up }, { "down", input.key.down },
    { "jump", input.key.space },
    { "orbit_l", input.key.z }, { "orbit_r", input.key.x },
  })
end

-- console: game.demo(1) hands controls to the autoplay loop (run the stair
-- course, hop on a beat, arc left); any real press takes back
function game.demo(on)
  local d = state.doc
  if on and on ~= 0 then
    d.demo = on
    d.demo_t0 = state.frame()
  else
    d.demo = 0
  end
end

local ACTIONS = { "left", "right", "up", "down", "jump" }

-- camera-relative wish vector from held dirs: forward = cam->player on xz
local function build_ctl()
  local d = state.doc
  if d.demo ~= 0 then
    for _, a in ipairs(ACTIONS) do
      if input.pressed(a) then
        game.demo(0)
        break
      end
    end
  end
  local fwd, side, jump_pressed
  if d.demo ~= 0 then
    local rel = state.frame() - d.demo_t0
    fwd = 1
    side = (rel % 270 >= 90 and rel % 270 < 180) and -1 or 0
    jump_pressed = rel % 45 == 5
  else
    fwd = (input.down("up") and 1 or 0) + (input.down("down") and -1 or 0)
    side = (input.down("right") and 1 or 0) + (input.down("left") and -1 or 0)
    jump_pressed = input.pressed("jump")
  end
  local wishx, wishz = 0, 0
  if fwd ~= 0 or side ~= 0 then
    local px, _, pz = player.pos()
    local dx, dz = px - cam:f32(0), pz - cam:f32(8)
    local l = m.sqrt(dx * dx + dz * dz)
    if l < 1e-4 then dx, dz, l = 0, 1, 1 end
    local fx, fz = dx / l, dz / l -- forward; right = (-fz, fx)... see below
    -- screen right = cross(forward, up) on xz = (-fz, fx)? cross gives
    -- (-fz, 0, fx) with f=(fx,0,fz): checked f=(0,0,-1) -> (1,0,0). yes.
    wishx = fx * fwd + (-fz) * side
    wishz = fz * fwd + fx * side
    local wl = m.sqrt(wishx * wishx + wishz * wishz)
    if wl > 1e-4 then wishx, wishz = wishx / wl, wishz / wl
    else wishx, wishz = 0, 0 end
  end
  return { wishx = wishx, wishz = wishz, jump_pressed = jump_pressed }
end

-- pull-string camera: manual orbit rotates the offset, then the camera is
-- dragged toward sitting cam.dist behind the player (Mario-cam lazy follow)
local function cam_step()
  local kc = state.doc.knobs.cam
  local px, py, pz = player.pos()
  local cx, cy, cz = cam:f32(0), cam:f32(4), cam:f32(8)
  local ox, oz = cx - px, cz - pz
  local orbit = (input.down("orbit_l") and -kc.orbit or 0)
              + (input.down("orbit_r") and kc.orbit or 0)
  if orbit ~= 0 then
    local c, s = m.cos(orbit), m.sin(orbit)
    ox, oz = ox * c - oz * s, ox * s + oz * c
  end
  local l = m.sqrt(ox * ox + oz * oz)
  if l < 1e-4 then ox, oz, l = -1, 0, 1 end
  local tx = px + ox / l * kc.dist
  local tz = pz + oz / l * kc.dist
  cx = px + ox -- orbit applies instantly, the pull eases
  cz = pz + oz
  cx = cx + (tx - cx) * kc.lerp
  cz = cz + (tz - cz) * kc.lerp
  cy = cy + (py + kc.height - cy) * kc.lerp_y
  cam:f32(0, cx); cam:f32(4, cy); cam:f32(8, cz)
end

function game.step()
  player.step(build_ctl())
  cam_step()
end

function game.draw()
  pal.begin_frame(0, 0, 0, 1)

  -- sky: NDC passthrough gradient (fog off)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)

  local px, py, pz = player.pos()
  local view = m4.lookat(cam:f32(0), cam:f32(4), cam:f32(8),
                         px, py + state.doc.knobs.cam.look_h, pz, 0, 1, 0)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  local fog = level.fog
  pal.x_view3d{
    mvp = m4.mul(proj, view),
    fog_start = fog.s, fog_end = fog.e, fog = fog.col, fog_on = fog.on,
  }

  for _, s in ipairs(level.segs) do
    pal.x_tris(s.tex, level.vbuf, s.count, s.off, 0)
  end

  -- the cube (opaque), then its blob shadow (blend, no depth write)
  local out = {}
  local ncube = player.emit(out)
  local nsh = player.emit_shadow(out)
  dyn:setstr(0, table.concat(out))
  pal.x_tris(0, dyn, ncube, 0, 0)
  pal.x_tris(level.tex.shadow, dyn, nsh, ncube * 72, 4)

  local st = pal.frame_stats()
  text.draw(3, 3, ("bounce  %d tris  frame %d")
            :format(st.tris or 0, state.frame()))
  if state.doc.demo ~= 0 then
    local msg = "AUTOPLAY * press any key"
    text.draw((W - text.measure(msg)) // 2, 14, msg,
              { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  end
  text.draw(3, H - 11, "arrows move . space jump . z/x orbit cam")
end

return game
