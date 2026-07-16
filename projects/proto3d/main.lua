-- proto3d main.lua — the PAL 3D pipeline's first cartridge: draws the
-- prototype's graybox scene (demo-1 look target) at 60fps through
-- pal.x_view3d/x_tris and orbits the camera around it.
--
-- The scene is proto/out/graybox.c3dd — the same world-space pre-lit
-- triangle dump proto/gpu_proto.c renders; reproducing its look here IS
-- the verification that the PAL pipeline matches the look reference
-- (proto/README.md). Geometry stays a baked asset on purpose: the Lua
-- primitive vocabulary (prisms/lathes/terrain) arrives with demo 1's
-- movement slice, where it grows gameplay colliders too.
--
-- Controls: left/right orbit · up/down zoom · space toggles auto-orbit.
--
-- Determinism: sim state (orbit angle/zoom/auto) lives in the named buffer
-- p3d.cam; the draw path only reads it. Camera matrices are render-class
-- (D036 corollary: the sim never reads pixels or view).

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m4 = cm.require("m4")

local W, H = pal.gfx_size()
local game = {}

-- scene constants, verbatim from proto/main.c scene_graybox
local AT = { 18, 4, 10 }             -- camera look-at
local EYE0 = { -2.0, 7.0, 26.0 }     -- reference eye (frame-0 == money shot)
local FOVY, ZN, ZF = 52, 0.3, 120

local scene -- { segs = {{tex,flags,count,off}...}, fog = {on,s,e,r,g,b} }
local vbuf, skybuf, cam

-- p3d.cam layout: f32 angle (rad), f32 dist scale, u8 auto
local CAM_SIZE = 9

local function unpack_rgb(c)
  return (c & 0xff) / 255, ((c >> 8) & 0xff) / 255, ((c >> 16) & 0xff) / 255
end

-- parse the .c3dd dump (format: proto/main.c finish()); creates PAL
-- textures + fills the p3d.verts named buffer, returns the scene table
local function load_scene(path)
  local data = assert(pal.read_file(path), "missing " .. path)
  local p = 1
  local magic, ver
  magic, ver, p = string.unpack("<I4I4", data, p)
  assert(magic == 0x44443343 and ver == 1, "bad c3dd header")
  p = p + 16 -- w,h,scale,quant: presentation hints, ours come from project.lua
  p = p + 64 + 64 -- view/proj: recomputed live in Lua (m4.lua)
  local fog = {}
  for i = 1, 6 do fog[i], p = string.unpack("<f", data, p) end
  local sky_top, sky_bot
  sky_top, sky_bot, p = string.unpack("<I4I4", data, p)

  -- textures: free the previous generation first (hot-reload/reboot safe:
  -- ids persist in p3d.texids, PAL textures survive VM reboots)
  local idbuf = pal.buf("p3d.texids", 4 * 33)
  local nold = idbuf:u32(0)
  for i = 1, nold do pal.tex_free(idbuf:u32(4 * i)) end
  local ntex
  ntex, p = string.unpack("<I4", data, p)
  local texid = {}
  for i = 1, ntex do
    local tw, th
    tw, th, p = string.unpack("<i4i4", data, p)
    local px = data:sub(p, p + tw * th * 4 - 1)
    p = p + tw * th * 4
    texid[i] = pal.tex_create(tw, th, px)
    idbuf:u32(4 * i, texid[i])
  end
  idbuf:u32(0, ntex)

  -- triangles: 80B records (tex i32, flags u32, 3x 24B verts). Vertex bytes
  -- are already the PAL x_tris layout — copy runs of equal (tex,flags)
  -- verbatim into the vertex buffer and remember them as segments.
  local ntri
  ntri, p = string.unpack("<I4", data, p)
  vbuf = pal.buf("p3d.verts", ntri * 72)
  local segs, chunks = {}, {}
  local off, cur = 0, nil
  for i = 1, ntri do
    local tex, flags
    tex, flags = string.unpack("<i4I4", data, p)
    chunks[#chunks + 1] = data:sub(p + 8, p + 79)
    p = p + 80
    local pal_tex = tex >= 0 and texid[tex + 1] or 0
    if not cur or cur.tex ~= pal_tex or cur.flags ~= flags then
      cur = { tex = pal_tex, flags = flags, count = 0, off = off }
      segs[#segs + 1] = cur
    end
    cur.count = cur.count + 1
    off = off + 72
  end
  vbuf:setstr(0, table.concat(chunks))

  -- sky: full-screen NDC quad at far depth, gradient via vertex colors,
  -- drawn first under an identity view with fog off (proto sky pass)
  skybuf = pal.buf("p3d.sky", 6 * 24)
  local tr, tg, tb = unpack_rgb(sky_top)
  local br, bg, bb = unpack_rgb(sky_bot)
  local function sv(x, y, r, g, b)
    return string.pack("<fffffBBBB", x, y, 0.9999, 0, 0,
                       m.floor(r * 255 + 0.5), m.floor(g * 255 + 0.5),
                       m.floor(b * 255 + 0.5), 255)
  end
  local v0 = sv(-1, 1, tr, tg, tb)
  local v1 = sv(1, 1, tr, tg, tb)
  local v2 = sv(1, -1, br, bg, bb)
  local v3 = sv(-1, -1, br, bg, bb)
  skybuf:setstr(0, v0 .. v1 .. v2 .. v0 .. v2 .. v3)

  return { segs = segs, fog = fog, ntri = ntri }
end

function game.init()
  input.map({
    { "left", input.key.left }, { "right", input.key.right },
    { "up", input.key.up }, { "down", input.key.down },
    { "auto", input.key.space },
  })
  cam = pal.buf("p3d.cam", CAM_SIZE)
  if state.frame() == 0 then
    cam:f32(0, 0) -- orbit angle relative to the reference eye
    cam:f32(4, 1) -- distance scale
    cam:u8(8, 1)  -- auto-orbit on
  end
  scene = load_scene(cm.main.args.project .. "/graybox.c3dd")
end

function game.step()
  local auto = cam:u8(8)
  if input.pressed("auto") then
    auto = auto == 1 and 0 or 1
    cam:u8(8, auto)
  end
  local a = cam:f32(0)
  if auto == 1 then a = a + 0.004 end
  if input.down("left") then a = a - 0.02 end
  if input.down("right") then a = a + 0.02 end
  local d = cam:f32(4)
  if input.down("up") then d = m.max(0.35, d - 0.01) end
  if input.down("down") then d = m.min(2.5, d + 0.01) end
  cam:f32(0, m.fmod(a, m.tau))
  cam:f32(4, d)
end

function game.draw()
  pal.begin_frame(0, 0, 0, 1)

  -- sky pass: NDC passthrough (identity view, fog off)
  pal.x_view3d()
  pal.x_tris(0, skybuf, 2, 0, 0)

  -- scene pass: orbit the reference eye around the look-at point
  local a, d = cam:f32(0), cam:f32(4)
  local rx, rz = EYE0[1] - AT[1], EYE0[3] - AT[3]
  local r = m.sqrt(rx * rx + rz * rz) * d
  local a0 = m.atan2(rz, rx)
  local ex = AT[1] + r * m.cos(a0 + a)
  local ez = AT[3] + r * m.sin(a0 + a)
  local ey = AT[2] + (EYE0[2] - AT[2]) * d
  local view = m4.lookat(ex, ey, ez, AT[1], AT[2], AT[3], 0, 1, 0)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  local fog = scene.fog
  pal.x_view3d{
    mvp = m4.mul(proj, view),
    fog_start = fog[2], fog_end = fog[3],
    fog = { fog[4], fog[5], fog[6] }, fog_on = fog[1] > 0.5,
  }
  for _, s in ipairs(scene.segs) do
    pal.x_tris(s.tex, vbuf, s.count, s.off, s.flags)
  end

  -- HUD on top: 2D quads composite over the 3D pass by design
  local st = pal.frame_stats() -- last present's counters, fine for a HUD
  text.draw(3, 3, ("proto3d  %d tris  %d segs3d  frame %d")
            :format(st.tris or 0, st.segs3d or 0, state.frame()))
  text.draw(3, H - 11, "arrows orbit/zoom . space auto-orbit")
end

return game
