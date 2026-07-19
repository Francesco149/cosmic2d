-- cm.ed.win.terr — the 3d map window (kind `terr`, EDITOR3D.md §4,
-- D137). E0 slice: the offscreen 3D viewport substrate — an orbit
-- camera (cm.ed.orbit; captured world-unit fields on the window) over a
-- pal.x_rt render target sized to the content rect, drawing the lattice
-- floor + axis gnomon through pal.x_view3d{target=}/x_tris. Grammar:
-- focused middle-drag = orbit, shift+middle = pan the focus on the
-- ground, wheel = stepped dolly, shift+1 = home the view — the map
-- window's focus-is-the-one-gate contract exactly. The .terr asset
-- binding, sculpt/paint tools, placements, and the inspector arrive
-- with E1/E2/E3.
--
-- RT lifetime: ephemeral per-window (ed.g.t3), re-created on view-rect
-- resize, pruned when the window dies, and registered generationally in
-- ed.t3rt so a VM reboot (D052) frees the previous generation's
-- textures instead of leaking them (the rc.p3d.texids pattern).

local ob = cm.require("cm.ed.orbit")

local M = { kind = "terr" }
M.menu = "3d map"
M.exts = { "terr" }
M.help = "win-terr"
M.DEF_W, M.DEF_H = 460, 340

local IDCAP = 32 -- ed.t3rt: [0] n, then n texids (one per open viewport)

-- reboot leak guard: free the previous VM generation's RTs on module load
do
  local b = pal.buf("ed.t3rt", 4 * (IDCAP + 1))
  local n = b:u32(0)
  for i = 1, math.min(n, IDCAP) do pal.tex_free(b:u32(4 * i)) end
  b:u32(0, 0)
end

local function reg_write(rts)
  local b = pal.buf("ed.t3rt", 4 * (IDCAP + 1))
  local n = 0
  for _, r in pairs(rts) do
    if n < IDCAP then n = n + 1; b:u32(4 * n, r.tex) end
  end
  b:u32(0, n)
end

local function state(ed)
  local t = ed.g.t3
  if not t then t = { rts = {}, gest = {} }; ed.g.t3 = t end
  return t
end

function M.defaults()
  return ob.defaults(26, 0, 0, 0)
end

function M.title(win)
  if (win.path or "") == "" then return "3d map" end
  return win.path:match("([^/]+)%.terr$") or win.path
end

function M.accepts(win, path) return path:sub(-5) == ".terr" end
function M.rebind(win, ed, path) win.path = path end

-- ---- the view lock trio (kit.viewlock's contract, orbit math) ----

function M.own_view(win) return true end

function M.wheel(win, ed, dy)
  if ed.doc.focus ~= win.id then return false end
  ob.dolly(win, dy)
  ed.touch()
  return true
end

function M.takes_middle(win, ed)
  return ed ~= nil and ed.doc.focus == win.id
end

-- ---- static scene: lattice floor + axis gnomon (E0 proving scene) ----

local function vert(x, y, z, r, g, b)
  return string.pack("<fffffBBBB", x, y, z, 0, 0, r, g, b, 255)
end

-- a flat ground-plane quad (two tris, both windings irrelevant: the 3D
-- pipe culls nothing)
local function flatquad(out, x0, z0, x1, z1, y, r, g, b)
  local a = vert(x0, y, z0, r, g, b)
  local bq = vert(x1, y, z0, r, g, b)
  local c = vert(x1, y, z1, r, g, b)
  local d = vert(x0, y, z1, r, g, b)
  out[#out + 1] = a .. bq .. c .. a .. c .. d
end

local SCENE -- { bytes, ntris } built once
local function scene()
  if SCENE then return SCENE end
  local out = {}
  local S, TH = 16, 0.02 -- half-extent, line half-thickness
  for i = -S, S do
    local major = i % 4 == 0
    local v = major and 96 or 56
    if i == 0 then v = 120 end
    flatquad(out, i - TH, -S, i + TH, S, 0, v, v, v + 8)
    flatquad(out, -S, i - TH, S, i + TH, 0, v, v, v + 8)
  end
  -- gnomon: +x red, +y green(up), +z blue — thin raised bars at origin
  local B = 0.09
  local function bar(x0, y0, z0, x1, y1, z1, r, g, b)
    -- an axis bar as two crossed flat quads (reads from any orbit angle)
    local a1 = vert(x0, y0 - B, z0, r, g, b) .. vert(x1, y1 - B, z1, r, g, b)
             .. vert(x1, y1 + B, z1, r, g, b)
    local a2 = vert(x0, y0 - B, z0, r, g, b) .. vert(x1, y1 + B, z1, r, g, b)
             .. vert(x0, y0 + B, z0, r, g, b)
    local b1 = vert(x0 - B, y0, z0, r, g, b) .. vert(x1 - B, y1, z1, r, g, b)
             .. vert(x1 + B, y1, z1, r, g, b)
    local b2 = vert(x0 - B, y0, z0, r, g, b) .. vert(x1 + B, y1, z1, r, g, b)
             .. vert(x0 + B, y0, z0, r, g, b)
    out[#out + 1] = a1 .. a2 .. b1 .. b2
  end
  bar(0, 0.02, 0, 3, 0.02, 0, 235, 90, 80)
  bar(0, 0.02, 0, 0, 3.02, 0, 90, 220, 110)
  bar(0, 0.02, 0, 0, 0.02, 3, 90, 140, 240)
  local bytes = table.concat(out)
  SCENE = { bytes = bytes, ntris = #bytes // 72 }
  return SCENE
end

-- ---- RT lifecycle ----

local function rt_for(ed, win, w, h)
  local t = state(ed)
  local r = t.rts[win.id]
  if r and (r.w ~= w or r.h ~= h) then
    pal.tex_free(r.tex)
    t.rts[win.id] = nil
    r = nil
  end
  if not r then
    r = { tex = pal.x_rt(w, h), w = w, h = h }
    t.rts[win.id] = r
    reg_write(t.rts)
  end
  return r
end

local function prune(ed)
  local t = state(ed)
  local wm = cm.require("cm.ed.wm")
  local gone
  for id, r in pairs(t.rts) do
    if not wm.get(ed.doc, id) then
      pal.tex_free(r.tex)
      t.rts[id] = nil
      t.gest[id] = nil
      gone = true
    end
  end
  if gone then reg_write(t.rts) end
end

-- ---- draw ----

function M.draw(win, ctx)
  local ed = ctx.ed
  prune(ed)
  local i = cm.require("cm.ui").inp
  local g = ed.g
  local vx, vy = ctx.cx, ctx.cy
  local vw = math.max(1, math.floor(ctx.cw + 0.5))
  local vh = math.max(1, math.floor(ctx.ch + 0.5))

  -- gestures (focused only — focus is the one gate; the shell's
  -- takes_middle routing already made this window's claim)
  local t = state(ed)
  if ctx.focused and i.clicked[2] then
    t.gest[win.id] = { mx = i.wx, my = i.wy, pan = g.shift or false }
  end
  local ge = t.gest[win.id]
  if ge then
    if i.buttons[2] then
      local dx, dy = i.wx - ge.mx, i.wy - ge.my
      if ge.pan then
        ob.pan(win, dx, dy, vh)
      else
        ob.orbit(win, dx, dy)
      end
      ge.mx, ge.my = i.wx, i.wy
      ctx.touch()
    else
      t.gest[win.id] = nil
    end
  end

  -- render the scene into this window's RT and blit it
  local r = rt_for(ed, win, vw, vh)
  local sc = scene()
  local vb = pal.buf("ed.t3vb", #sc.bytes)
  vb:setstr(0, sc.bytes)
  local vpm = ob.vp(win, vw / vh)
  pal.x_view3d{ mvp = vpm, target = r.tex,
                clear = { 0.10, 0.11, 0.14, 1 } }
  pal.x_tris(0, vb, sc.ntris, 0)
  pal.x_ig_image(r.tex, vx, vy, vw, vh)

  -- unbound hint (E1 grows the pathfield/create door here)
  if (win.path or "") == "" then
    local tpx = math.max(8, 11 * ctx.z)
    pal.x_ig_text(vx + 8 * ctx.z, vy + 6 * ctx.z, tpx, 0x9aa4b2ff,
                  "empty 3d map viewport - drop a .terr (E1)", 0)
  end
end

-- shift+1 = home the view (the fit key, EDITOR.md grammar)
M.hotkeys = {
  { key = "shift+1", hint = "home view",
    fn = function(win, ed)
      local d = M.defaults()
      for k, v in pairs(d) do win[k] = v end
      ed.touch()
    end },
}

return M
