-- waterwall — the animated-texture demo (D155's strip frames as
-- FLOWING WATER): a rock wall of UV-mapped stone blocks (art/wall.msh
-- over art/rock.spr — the center channel maps the sheet's WET tiles),
-- and on top of it an overlay mesh a hair proud of the surface
-- (art/water.msh: fall sheet, side trickle, foam pool) textured from
-- an 8-frame water strip (art/water.spr) where each frame is the same
-- y-periodic streak pattern scrolled 8px — swapping strip frames
-- through the sprite animation slots IS the flow. The overlay draws
-- with NEAREST|BLEND (translucent decal: depth test on, depth write
-- off) over the opaque wall, unlit under a full-white ambient bracket
-- so the texel alpha/color carry the water.
--
-- space toggles the overlay (see exactly what the animated texture
-- adds), left/right steps the flow rate. Determinism: sim state is
-- state.doc only ({water, spd}); frame choice, camera sway, and all
-- lighting derive from state.frame() in draw (render-class). Textures
-- resolve through the epoch-keyed cm.gfx.texture door, so live edits
-- to rock.spr/water.spr hot-reload the running scene.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local hud = cm.require("cm.hud")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local mesh = cm.require("cm.mesh")
local gfx = cm.require("cm.gfx")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 40, 0.3, 60
local root = cm.main.args.project

local game = select(2, ...) or {}

local NFR = 8                  -- water strip frames
local SPD = { 12, 8, 5, 3 }    -- ticks per strip frame, slow..fast

-- ---- render-class asset memos (epoch-keyed: live edits follow) ----
local A
local function assets()
  local ep = cm.asset_epoch or 0
  if not A or A.ep ~= ep then
    A = {
      wall = mesh.decode(pal.read_file(root .. "/art/wall.msh")),
      water = mesh.decode(pal.read_file(root .. "/art/water.msh")),
      wg = {}, ag = {}, ep = ep,
    }
  end
  return A
end
local function texture(name)
  local ok, t = pcall(gfx.texture, root .. "/art/" .. name)
  return ok and t or nil
end
local function groups_for(cache, doc, t, fr)
  local key = fr .. ":" .. (t and t.w or 0)
  if not cache[key] then
    cache[key] = mesh.bake_groups(doc, {
      tex = t and { w = t.w, h = t.h }, frame = fr })
  end
  return cache[key]
end

-- console door: regenerate the committed assets (gen.lua — the garage
-- precedent; the files remain the source of record)
function game.gen()
  cm.require("gen").run()
end

local dyn
function game.init()
  local d = state.doc
  if d.water == nil then d.water = true end
  if d.spd == nil then d.spd = 3 end
  input.map({
    { "slower", input.key.left }, { "faster", input.key.right },
    { "toggle", input.key.space },
    { "toggle2", input.key["return"] },
  })
  local ok, db = pcall(pal.buf, "rc.waterwall.dyn", 32768)
  if not ok then
    pal.buf_free("rc.waterwall.dyn")
    db = pal.buf("rc.waterwall.dyn", 32768)
  end
  dyn = db
end

function game.step()
  local d = state.doc
  if input.pressed("slower") then d.spd = m.max(1, d.spd - 1) end
  if input.pressed("faster") then d.spd = m.min(#SPD, d.spd + 1) end
  if input.pressed("toggle") or input.pressed("toggle2") then
    d.water = not d.water
  end
end

-- floor quads (pre-lit flat verts, packed per draw)
local vpack = string.pack
local function flatquad(out, x0, z0, x1, z1, y, r, g, b)
  local A1 = vpack("<fffffBBBB", x0, y, z0, 0, 0, r, g, b, 255)
  local B1 = vpack("<fffffBBBB", x1, y, z0, 1, 0, r, g, b, 255)
  local C1 = vpack("<fffffBBBB", x1, y, z1, 1, 1, r, g, b, 255)
  local D1 = vpack("<fffffBBBB", x0, y, z1, 0, 1, r, g, b, 255)
  out[#out + 1] = A1 .. B1 .. C1 .. A1 .. C1 .. D1
  return 2
end

local function submit(segs, off, xflags)
  for _, s in ipairs(segs) do
    if s.ntris > 0 then
      dyn:setstr(off, s.bytes)
      local fl = s.flags
      if xflags then fl = (fl & ~1) | xflags end
      pal.x_tris(s.tex, dyn, s.ntris, off, fl)
      off = off + #s.bytes
    end
  end
  return off
end

function game.draw()
  pal.begin_frame(0.04, 0.045, 0.075, 1)
  local d = state.doc
  local a = assets()
  local rockt = texture("rock.png")
  local watert = texture("water.png")
  local now = state.frame()

  -- gentle camera sway, render-derived
  local ang = 0.28 + 0.16 * m.sin(now * 0.006)
  local ex, ez = 3.9 * m.sin(ang), 3.9 * m.cos(ang)
  local view = m4.lookat(ex, 1.55, ez, 0, 0.92, 0, 0, 1, 0)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  pal.x_view3d{ mvp = m4.mul(proj, view) }

  local oamb = gb.ambient
  gb.ambient = { 0.40, 0.42, 0.50 }

  -- floor + the damp apron at the base of the fall
  local out = {}
  local nt = flatquad(out, -6, -6, 6, 6, 0, 16, 16, 22)
  nt = nt + flatquad(out, -1.2, 0, 1.2, 1.5, 0.005, 21, 25, 34)
  local off = 0
  local bytes = table.concat(out)
  dyn:setstr(off, bytes)
  pal.x_tris(0, dyn, nt, off, 0)
  off = off + #bytes

  -- the wall (opaque; the sprite rule ALPHATEST|NEAREST)
  local I = m4.ident()
  off = submit(mesh.emit_segments(a.wall, I, I, {
    groups = groups_for(A.wg, a.wall, rockt, 0),
    tex_id = rockt and rockt.id }), off)

  -- the water overlay: strip frame = the flow (drawn last — BLEND is
  -- a decal: depth test on, depth write off); full-white ambient so
  -- the unlit faces carry the texel color exactly
  if d.water then
    local fr = (now // SPD[d.spd]) % NFR
    gb.ambient = { 1, 1, 1 }
    off = submit(mesh.emit_segments(a.water, I, I, {
      groups = groups_for(A.ag, a.water, watert, fr),
      tex_id = watert and watert.id }), off, 4 | 2)
  end
  gb.ambient = oamb

  -- the demo chrome
  text.draw((W - 9 * 6) // 2, 10, "WATERWALL",
            { r = 0.8, g = 0.9, b = 0.95 })
  local line = ("< flow %d/%d >  water %s"):format(
    d.spd, #SPD, d.water and "on" or "off")
  text.draw((W - #line * 6) // 2, H - 34, line,
            { r = 0.85, g = 0.9, b = 0.95 })
  hud.text("b", 0, 10, "left/right flow speed . space water on/off",
           { r = 0.6, g = 0.65, b = 0.75, a = 0.9 })
end

return game
