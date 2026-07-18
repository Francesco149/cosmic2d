-- rovale main.lua — demo 3's RO-style vale (COSMIC3D.md §11): the baked
-- blended terrain, chibi billboards baked live from cm.fig figures, the
-- authentic camera (15 deg FOV, steep pitch, free yaw, stepped zoom), and
-- CLICK-TO-MOVE on the walk grid.
--
-- Controls: left click = walk there · right drag / arrows = camera ·
-- wheel = stepped zoom · c recenter · ` console. game.demo(1) = the vale
-- tour (synthetic clicks through the REAL pick+path pipeline — the golden
-- trace exercises the whole kernel); game.demo(2) = walk to the plaza
-- greeter and stand for the exchange.
--
-- Determinism: sim state in named buffers (ro.player/ro.cam/ro.npc*) +
-- doc tree; cm.math trig; the mouse is in the input record, so a click IS
-- sim input. The terrain bake runs in draw under a budget knob
-- (render-class; _G.RO_BUDGET override must never change a trace).

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local world = cm.require("world")
local spr = cm.require("cm.spr")
local walk = cm.require("cm.walk")
local player = cm.require("player")
local npc = cm.require("npc")
local audio = cm.require("audio")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 15, 1.0, 260

local game = select(2, ...) or {}
game.world = world -- console reach
game.player = player

local KNOBS = {
  move = { -- the RO walk: pathing, no physics
    speed = 4.6,      -- u/s along the path chain
    turn = 0.30,      -- facing ease toward the travel direction
    stride = 1.5,     -- u per 4-frame walk cycle on the sheet
    marker_ttl = 42,  -- click-ring frames
    repeat_f = 9,     -- held-button re-command cadence
  },
  cam = { -- the authentic RO rig (proto ro2 closeup values)
    dist = 66, min_dist = 36, max_dist = 96, wheel_step = 6,
    pitch = 0.70, pitch_min = 0.45, pitch_max = 1.25,
    yaw0 = 0.45,
    orbit = 0.030, key_pitch = 0.015,
    mouse_yaw = 0.010, mouse_pitch = 0.008,
    pos_lerp = 0.12, look_h = 1.0,
  },
  spr = {
    h = 3.4, -- billboard cell height in world units (chibi vs 2u tiles)
  },
  npc = {
    greet_r = 3.2, exit_r = 4.6, turn = 0.12,
    speed = 2.0, arrive = 0.30,
    wave_f = 44, type_f = 2,
  },
  bake = {
    budget = 8, -- terrain tiles baked per draw frame (render-class)
  },
  -- RO preset: sharp present (human 2026-07-17 — crisp sprites suit the
  -- style; the soft VI blit stays for the N64-preset demos)
  look = { quant = 5, soft = 0 },
}

local cam, dyn, skybuf, uibuf

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

-- console: re-rasterize every sprite sheet and rewrite the committed
-- .spx assets (after editing the mascot/variants/bake camera; bump
-- SPR_STAMP in cm/spr.lua for changes that must invalidate other checkouts)
function game.rebake_sprites()
  player.init(true)
  npc.init(true)
end

local function build_sky()
  skybuf = pal.buf("rc.ro.sky", 6 * 24)
  local function sv(x, y, c)
    return string.pack("<fffffBBBB", x, y, 0.9999, 0, 0,
                       (c[1] * 255) // 1, (c[2] * 255) // 1,
                       (c[3] * 255) // 1, 255)
  end
  local t, b = world.sky_top, world.sky_bot
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
  if d.demo_wp == nil then d.demo_wp = 1 end
  if d.demo_cd == nil then d.demo_cd = 0 end

  world.build()
  audio.init()
  player.init()
  npc.init()
  build_sky()

  -- dyn: per-frame decals + billboards (render-class scratch)
  local ok, db = pcall(pal.buf, "rc.ro.dyn", 64 * 72)
  if not ok then
    pal.buf_free("rc.ro.dyn")
    db = pal.buf("rc.ro.dyn", 64 * 72)
  end
  dyn = db
  uibuf = pal.buf("rc.ro.ui", 12 * 24) -- loading bar quads (NDC)

  -- ro.cam: [0]yaw [4]pitch [8]dist [12/16/20]focus [24/28]prev cursor
  local ok2, cb = pcall(pal.buf, "ro.cam", 32)
  if not ok2 then
    pal.buf_free("ro.cam")
    cb = pal.buf("ro.cam", 32)
  end
  cam = cb
  if cam:f32(8) == 0 then -- virgin
    local kc = state.doc.knobs.cam
    local px, pz = player.pos()
    cam:f32(0, kc.yaw0)
    cam:f32(4, kc.pitch)
    cam:f32(8, kc.dist)
    cam:f32(12, px); cam:f32(16, world.ground(px, pz)); cam:f32(20, pz)
  end

  input.map({
    { "cam_l", input.key.left }, { "cam_r", input.key.right },
    { "cam_u", input.key.up }, { "cam_d", input.key.down },
    { "recenter", input.key.c },
  })
end

-- camera eye + basis from the sim rig (shared by draw, the pick ray, and
-- the demo's screen-space projection — all sim-legal, cm.math only)
local function cam_basis()
  local kc = state.doc.knobs.cam
  local yaw, pitch, dist = cam:f32(0), cam:f32(4), cam:f32(8)
  local fx, fy, fz = cam:f32(12), cam:f32(16) + kc.look_h, cam:f32(20)
  local hr = m.cos(pitch) * dist
  local ex = fx + m.sin(yaw) * hr
  local ey = fy + m.sin(pitch) * dist
  local ez = fz + m.cos(yaw) * hr
  -- forward/right/up (the lookat basis)
  local dx, dy, dz = fx - ex, fy - ey, fz - ez
  local dl = m.sqrt(dx * dx + dy * dy + dz * dz)
  dx, dy, dz = dx / dl, dy / dl, dz / dl
  local rx, ry, rz = -dz, 0, dx -- f x up, up=(0,1,0), then normalized
  local rl = m.sqrt(rx * rx + rz * rz)
  rx, rz = rx / rl, rz / rl
  local ux = ry * dz - rz * dy
  local uy = rz * dx - rx * dz
  local uz = rx * dy - ry * dx
  return ex, ey, ez, dx, dy, dz, rx, ry, rz, ux, uy, uz
end

local TANF = nil -- tan(FOVY/2), computed once (render-safe constant)
local function tanf()
  if not TANF then TANF = m.tan(FOVY * (m.pi / 180) * 0.5) end
  return TANF
end

-- screen pixel -> ground point (the click ray): this rig's NDC ray +
-- cm.walk.raycast's march/bisect against the sim ground
local function pick(mx, my)
  local ex, ey, ez, dx, dy, dz, rx, ry, rz, ux, uy, uz = cam_basis()
  local ndx = (mx + 0.5) / W * 2 - 1
  local ndy = 1 - (my + 0.5) / H * 2
  local tf = tanf()
  local kx = dx + rx * (ndx * tf * W / H) + ux * (ndy * tf)
  local ky = dy + ry * (ndx * tf * W / H) + uy * (ndy * tf)
  local kz = dz + rz * (ndx * tf * W / H) + uz * (ndy * tf)
  local kl = m.sqrt(kx * kx + ky * ky + kz * kz)
  kx, ky, kz = kx / kl, ky / kl, kz / kl
  return walk.raycast(world.ground, ex, ey, ez, kx, ky, kz)
end

-- world point -> screen pixel (nil if behind/off-screen): the demo's
-- synthetic clicks go through pick() at this position
local function project(wx, wy, wz)
  local ex, ey, ez, dx, dy, dz, rx, ry, rz, ux, uy, uz = cam_basis()
  local px, py, pz = wx - ex, wy - ey, wz - ez
  local cz = px * dx + py * dy + pz * dz -- view depth
  if cz < ZN then return nil end
  local cx = px * rx + py * ry + pz * rz
  local cy = px * ux + py * uy + pz * uz
  local tf = tanf()
  local ndx = cx / (cz * tf * W / H)
  local ndy = cy / (cz * tf)
  if m.abs(ndx) > 0.92 or m.abs(ndy) > 0.88 then return nil end
  return ((ndx + 1) * 0.5 * W) // 1, ((1 - ndy) * 0.5 * H) // 1
end

-- console: game.demo(1) = the vale tour — path south stretch, up the
-- winding path, onto the plaza decks, back around the pond bank, forever.
-- game.demo(2) = walk to the plaza greeter's loop and STAND (the exchange
-- is the show). Any real press/click takes back control.
function game.demo(on)
  local d = state.doc
  if on and on ~= 0 then
    d.demo = on
    d.demo_wp = 1
    d.demo_cd = 0
  else
    d.demo = 0
  end
end

local ROUTE = { -- every leg <= ~7u so the next target projects on-screen
  { 27.8, 46.0 }, { 25.5, 42.0 }, { 25.4, 38.0 }, { 26.7, 34.0 },
  { 30.0, 30.0 }, { 34.2, 26.0 }, { 38.0, 23.6 }, { 40.5, 21.5 },
  { 37.0, 26.5 }, { 33.0, 30.5 }, { 30.5, 36.0 }, { 28.5, 42.0 },
  { 29.5, 46.5 }, { 30.5, 50.0 }, { 31.5, 50.0 },
}
local ROUTE_GREET = {
  { 30.0, 30.0 }, { 33.5, 27.5 }, { 36.2, 27.2 },
}
local HOLD_LAST = { [2] = true }

-- demo control: when the player idles, project the next waypoint into the
-- screen and CLICK it (the full pick+path pipeline); if it isn't on
-- screen, orbit the camera toward its bearing first
local function demo_step()
  local d = state.doc
  local route = d.demo == 2 and ROUTE_GREET or ROUTE
  if d.demo_cd > 0 then
    d.demo_cd = d.demo_cd - 1
    return
  end
  if player.moving() then return end
  local wp = route[d.demo_wp]
  local px, pz = player.pos()
  local dx, dz = wp[1] - px, wp[2] - pz
  if dx * dx + dz * dz < 1.44 then -- arrived
    if HOLD_LAST[d.demo] and d.demo_wp == #route then return end -- stand
    d.demo_wp = d.demo_wp % #route + 1
    wp = route[d.demo_wp]
  end
  local sx, sy = project(wp[1], world.ground(wp[1], wp[2]), wp[2])
  if sx then
    if player.command(wp[1], wp[2]) then audio.sfx("click", 70) end
    d.demo_cd = 20
  else -- orbit toward the waypoint's bearing until it enters the frame
    local kc = d.knobs.cam
    local want = m.atan2(wp[1] - px, wp[2] - pz) + m.pi
    local yaw = cam:f32(0)
    local da = m.atan2(m.sin(want - yaw), m.cos(want - yaw))
    local turn = m.max(-kc.orbit, m.min(kc.orbit, da))
    cam:f32(0, m.fmod(yaw + turn, m.tau))
    d.demo_cd = 1
  end
end

local function cam_step()
  local kc = state.doc.knobs.cam
  local yaw, pitch, dist = cam:f32(0), cam:f32(4), cam:f32(8)

  local w = input.wheel()
  if w ~= 0 then -- stepped zoom, the RO read
    dist = m.clamp(dist - w * kc.wheel_step, kc.min_dist, kc.max_dist)
  end

  local mx, my = input.mouse()
  if input.button_down(3) then -- right drag rotates (the RO grip)
    local dx, dy = mx - cam:f32(24), my - cam:f32(28)
    yaw = yaw - dx * kc.mouse_yaw
    pitch = m.clamp(pitch + dy * kc.mouse_pitch, kc.pitch_min, kc.pitch_max)
  end
  cam:f32(24, mx); cam:f32(28, my)

  yaw = yaw + (input.down("cam_l") and kc.orbit or 0)
            + (input.down("cam_r") and -kc.orbit or 0)
  pitch = m.clamp(pitch + (input.down("cam_u") and -kc.key_pitch or 0)
                        + (input.down("cam_d") and kc.key_pitch or 0),
                  kc.pitch_min, kc.pitch_max)
  if input.pressed("recenter") then
    yaw, pitch, dist = kc.yaw0, kc.pitch, kc.dist
  end

  local px, pz = player.pos()
  local py = world.ground(px, pz)
  cam:f32(12, cam:f32(12) + (px - cam:f32(12)) * kc.pos_lerp)
  cam:f32(16, cam:f32(16) + (py - cam:f32(16)) * kc.pos_lerp)
  cam:f32(20, cam:f32(20) + (pz - cam:f32(20)) * kc.pos_lerp)
  cam:f32(0, m.fmod(yaw, m.tau)); cam:f32(4, pitch); cam:f32(8, dist)
end

function game.step()
  local d = state.doc
  if d.demo ~= 0 then
    if input.button_pressed(1) or input.pressed("recenter") then
      game.demo(0)
    else
      demo_step()
    end
  end
  if d.demo == 0 then
    -- click to walk: on press, and re-command while held (the RO drag).
    -- Only the press EDGE ticks the click sfx (held-repeat is silent —
    -- human playtest 2026-07-17)
    local mx, my = input.mouse()
    local edge = input.button_pressed(1)
    local held = not edge and input.button_down(1)
                 and state.frame() % d.knobs.move.repeat_f == 0
    if edge or held then
      local wx, wz = pick(mx, my)
      if wx and player.command(wx, wz) and edge then
        audio.sfx("click", 70)
      end
    end
  end
  player.step()
  npc.step()
  cam_step()
  if DBG and state.frame() % (tonumber(DBG) or 10) == 0 then
    local px, pz = player.pos()
    print(("DBG f=%d p=%.2f,%.2f g=%.2f face=%.2f moving=%s yaw=%.2f")
      :format(state.frame(), px, pz, world.ground(px, pz), player.face(),
              tostring(player.moving()), cam:f32(0)))
    for _, n in ipairs(npc.list) do
      local x, z = n.buf:f32(0), n.buf:f32(4)
      print(("  npc %s p=%.2f,%.2f g=%.2f wp=%d greet=%d"):format(
        n.def.name, x, z, world.ground(x, z), n.buf:u32(12), n.buf:u32(16)))
    end
  end
end

local function draw_loading(frac)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)
  -- the bar: dark back + gold fill, NDC quads
  local function bv(x, y, r, g, b)
    return string.pack("<fffffBBBB", x, y, 0.5, 0, 0, r, g, b, 255)
  end
  local x0, x1, y0, y1 = -0.4, 0.4, -0.06, -0.11
  local fx = x0 + (x1 - x0) * frac
  local q = {}
  local function quad2(ax, ay, bx, by, r, g, b)
    q[#q + 1] = bv(ax, ay, r, g, b) .. bv(bx, ay, r, g, b) .. bv(bx, by, r, g, b)
             .. bv(ax, ay, r, g, b) .. bv(bx, by, r, g, b) .. bv(ax, by, r, g, b)
  end
  quad2(x0 - 0.01, y0 + 0.02, x1 + 0.01, y1 - 0.02, 30, 34, 44)
  quad2(x0, y0, fx, y1, 244, 208, 96)
  local bytes = table.concat(q)
  uibuf:setstr(0, bytes)
  pal.x_tris(0, uibuf, #bytes // 72, 0, 0)
  local msg = ("baking the vale  %d%%"):format((frac * 100) // 1)
  text.draw((W - text.measure(msg)) // 2, H // 2 - 24, msg,
            { r = 1, g = 0.92, b = 0.6, a = 1 })
end

function game.draw()
  pal.begin_frame(0, 0, 0, 1)
  gb.sun, gb.ambient = world.sun, world.ambient

  local kl = state.doc.knobs.look
  if kl.quant > 0 then pal.x_grade{ quant = kl.quant } end
  if kl.soft > 0 then pal.x_soft(1) end

  -- the budgeted render-class bake; the honesty override must never
  -- change a trace (draw-only by construction)
  local frac = world.bake(RO_BUDGET or state.doc.knobs.bake.budget)
  if frac < 1 then
    draw_loading(frac)
    return
  end

  -- sky (NDC passthrough, fog off)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)

  local yaw = cam:f32(0)
  local ex, ey, ez = cam_basis()
  local kc = state.doc.knobs.cam
  local view = m4.lookat(ex, ey, ez, cam:f32(12), cam:f32(16) + kc.look_h,
                         cam:f32(20), 0, 1, 0)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  local fog = world.fog
  pal.x_view3d{
    mvp = m4.mul(proj, view),
    fog_start = fog.s, fog_end = fog.e, fog = fog.col, fog_on = fog.on,
  }

  -- static: baked terrain atlas, deck pave, roof shingle, untextured props
  for _, s in ipairs(world.segs) do
    pal.x_tris(s.tex, world.vbuf, s.count, s.off, s.flags)
  end

  -- dynamic, the authentic order: click marker -> blob shadows -> sprites
  -- -> water LAST (recipe: water renders after sprites)
  local out = {}
  local pitch = cam:f32(4)
  local nmk = player.emit_marker(out)
  local nsh = player.emit_shadow(out) + npc.emit_shadow(out)
  local npl = player.emit(out, yaw, pitch)
  local nnp = {}
  for i, n in ipairs(npc.list) do
    nnp[i] = npc.emit_one(n, out, yaw, pitch)
  end
  dyn:setstr(0, table.concat(out))
  local off = 0
  pal.x_tris(world.ring_tex, dyn, nmk, off, 4); off = off + nmk * 72
  pal.x_tris(world.tex.shadow, dyn, nsh, off, 4); off = off + nsh * 72
  pal.x_tris(player.sheet.tex, dyn, npl, off, 3); off = off + npl * 72
  for i, n in ipairs(npc.list) do
    pal.x_tris(n.sheet.tex, dyn, nnp[i], off, 3)
    off = off + nnp[i] * 72
  end
  pal.x_tris(0, world.vbuf, world.water.count, world.water.off, 4)

  -- HUD
  local st = pal.frame_stats()
  text.draw(3, 3, ("rovale  %d tris  frame %d"):format(st.tris or 0,
                                                       state.frame()))
  local line, nch = npc.dialog()
  if line then
    text.draw((W - text.measure(line)) // 2, H - 30, line:sub(1, nch),
              { r = 1, g = 0.95, b = 0.72, a = 0.95 })
  end
  if state.doc.demo ~= 0 then
    local msg = "AUTOPLAY * click to take over"
    text.draw((W - text.measure(msg)) // 2, 14, msg,
              { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  end
  text.draw(3, H - 11,
    "left click walk . right drag / arrows camera . wheel zoom . c recenter")
end

return game
