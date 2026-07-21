-- garage — the vehicle-select mock (D155's smoke demo): one UV-mapped
-- truck mesh (art/truck.msh, textured picoCAD-style in the mesh
-- window's uv tab) over a 2-frame .spr strip (art/truck.spr) — the
-- LIVERIES. Left/right swaps the livery by picking a different strip
-- frame with the SAME uv map (texture swapping through the sprite
-- animation slots); enter/space strobes the "flash" clip from the
-- .spr's own .anim sidecar through cm.anim.frame_at (texture
-- ANIMATION through the same slots). The truck rotates on a pedestal
-- and the pick flashes the scene light.
--
-- Determinism: sim state is state.doc only (sel + flash anchor
-- frames); rotation/lighting/frame choice derive from state.frame()
-- in draw (render-class). Textures resolve through the epoch-keyed
-- cm.gfx.texture door, so editing truck.spr live hot-reloads the
-- running screen.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local hud = cm.require("cm.hud")
local m4 = cm.require("cm.m4")
local gb = cm.require("cm.gb")
local mesh = cm.require("cm.mesh")
local anim = cm.require("cm.anim")
local gfx = cm.require("cm.gfx")

local W, H = pal.gfx_size()
local FOVY, ZN, ZF = 40, 0.3, 60
local root = cm.main.args.project

local game = select(2, ...) or {}

local NLIV = 2 -- liveries = strip frames

-- ---- render-class asset memos (epoch-keyed: live edits follow) ----
local truck, clips, tgroups
local function assets()
  local ep = cm.asset_epoch or 0
  if not truck or truck.ep ~= ep then
    local doc = mesh.decode(pal.read_file(root .. "/art/truck.msh"))
    truck = { doc = doc, ep = ep }
    clips = anim.load(root .. "/art/truck.anim") or {}
    tgroups = {}
  end
  return truck
end
local function strip()
  local ok, t = pcall(gfx.texture, root .. "/art/truck.png")
  return ok and t or nil
end
local function groups_for(doc, t, fr)
  local key = fr .. ":" .. (t and t.w or 0)
  if not tgroups[key] then
    tgroups[key] = mesh.bake_groups(doc, {
      tex = t and { w = t.w, h = t.h }, frame = fr })
  end
  return tgroups[key]
end

local dyn
function game.init()
  local d = state.doc
  if d.sel == nil then d.sel = 0 end      -- 0-based livery / strip frame
  if d.flash0 == nil then d.flash0 = -999 end -- confirm anchor frame
  if d.swap0 == nil then d.swap0 = -999 end   -- swap anchor frame
  input.map({
    { "prev", input.key.left }, { "next", input.key.right },
    { "confirm", input.key.space },
    { "confirm2", input.key["return"] },
  })
  local ok, db = pcall(pal.buf, "rc.garage.dyn", 16384)
  if not ok then
    pal.buf_free("rc.garage.dyn")
    db = pal.buf("rc.garage.dyn", 16384)
  end
  dyn = db
end

function game.step()
  local d = state.doc
  if input.pressed("prev") then
    d.sel = (d.sel - 1) % NLIV
    d.swap0 = state.frame()
  end
  if input.pressed("next") then
    d.sel = (d.sel + 1) % NLIV
    d.swap0 = state.frame()
  end
  if input.pressed("confirm") or input.pressed("confirm2") then
    d.flash0 = state.frame()
  end
end

-- floor + pedestal quads (pre-lit flat verts, packed once per draw)
local vpack = string.pack
local function flatquad(out, x0, z0, x1, z1, y, r, g, b)
  local A = vpack("<fffffBBBB", x0, y, z0, 0, 0, r, g, b, 255)
  local B = vpack("<fffffBBBB", x1, y, z0, 1, 0, r, g, b, 255)
  local C = vpack("<fffffBBBB", x1, y, z1, 1, 1, r, g, b, 255)
  local D = vpack("<fffffBBBB", x0, y, z1, 0, 1, r, g, b, 255)
  out[#out + 1] = A .. B .. C .. A .. C .. D
  return 2
end

function game.draw()
  pal.begin_frame(0.05, 0.05, 0.09, 1)
  local d = state.doc
  local a = assets()
  local t = strip()
  local now = state.frame()

  -- livery frame: the confirm strobe rides the .spr's own "flash" clip
  -- (texture animation through the sprite animation slots)
  local fr = d.sel
  local fl = anim.find(clips, "flash")
  local fel = now - d.flash0
  if fl and fel >= 0 and fel < 36 then fr = anim.frame_at(fl, fel) end

  -- the flash: a decaying light pulse on confirm, a soft pop on swap
  local pulse = 1
  if fel >= 0 and fel < 30 then pulse = 1 + 0.9 * (1 - fel / 30) end
  local sel2 = now - d.swap0
  if sel2 >= 0 and sel2 < 12 then
    pulse = m.max(pulse, 1 + 0.45 * (1 - sel2 / 12))
  end

  local view = m4.lookat(2.7, 1.7, 3.6, 0, 0.55, 0, 0, 1, 0)
  local proj = m4.persp(FOVY, W / H, ZN, ZF)
  pal.x_view3d{ mvp = m4.mul(proj, view) }

  local osun, oamb = gb.sun, gb.ambient
  gb.ambient = { 0.50 * pulse, 0.50 * pulse, 0.58 * pulse }

  -- stage: dark floor + the pedestal disc
  local out = {}
  local nt = flatquad(out, -6, -6, 6, 6, 0, 18, 17, 26)
  nt = nt + flatquad(out, -1.6, -1.6, 1.6, 1.6, 0.02,
                     (46 * pulse) // 1, (44 * pulse) // 1,
                     (66 * pulse) // 1)
  local off = 0
  local bytes = table.concat(out)
  dyn:setstr(off, bytes)
  pal.x_tris(0, dyn, nt, off, 0)
  off = off + #bytes

  -- the rotating truck
  local yaw = now * 0.014
  local xf = m4.mul(m4.translate(0, 0.06, 0), m4.roty(yaw))
  local segs = mesh.emit_segments(a.doc, xf, m4.roty(yaw), {
    groups = groups_for(a.doc, t, fr), tex_id = t and t.id })
  for _, s in ipairs(segs) do
    if s.ntris > 0 then
      dyn:setstr(off, s.bytes)
      pal.x_tris(s.tex, dyn, s.ntris, off, s.flags)
      off = off + #s.bytes
    end
  end
  gb.sun, gb.ambient = osun, oamb

  -- the mock select UI
  text.draw((W - 6 * 6) // 2, 10, "GARAGE",
            { r = 0.95, g = 0.92, b = 0.8 })
  local name = d.sel == 0 and "SUNSET RED" or "COAST BLUE"
  local line = "< " .. name .. "  " .. (d.sel + 1) .. "/" .. NLIV .. " >"
  text.draw((W - #line * 6) // 2, H - 34, line,
            { r = 0.9, g = 0.9, b = 0.95 })
  hud.text("b", 0, 10, "left/right change color . enter select",
           { r = 0.62, g = 0.6, b = 0.72, a = 0.9 })
end

return game
