-- cm.ed.win.mesh — the mesh window (kind `mesh`, EDITOR3D.md §5, D137):
-- the picoCAD-class low-poly editor over `.msh` — verts + tri/quad
-- faces, flat per-face colors, doublesided/unlit flags. The refusal set
-- is cm.mesh's: no skinning, no modifiers, no subdivision, no UV
-- unwrap — ever.
--
-- Four modes (header chips; selection CARRIES across switches — a
-- selected face becomes its verts in vtx mode, its edges in edge mode):
--   sel (`1`) — universal manipulation, the default: click picks the
--        edge under the cursor, else the front face; clicking the same
--        selected thing again drills ONE level to the thing behind it
--        (the vert under the cursor, the face under an edge, or the
--        second face along the ray — never further; a third click
--        cycles back). Press-drag on anything selected moves the whole
--        selection on the view plane; drag on empty marquee-selects the
--        verts that are VISIBLE (occluded verts stay out — vtx mode's
--        marquee is the x-ray one).
--   vtx (`2`/`v`) — click picks the nearest vertex (shift adds; click
--        empty drags an x-ray marquee); dragging a selected vertex
--        moves the selection — `x`/`y`/`z` toggle an axis lock, CTRL
--        snaps to the model grid (ctrl+wheel dials the step), the
--        mirror chip edits the x<0 twin live. `m` merges; del dissolves.
--   edge (`3`) — click picks an edge, marquee selects every edge with
--        both ends in the box, drag moves selected edges.
--   face (`4`/`f`) — click ray-picks a face (click-again drills to the
--        face behind), marquee selects fully-boxed faces. `e` extrudes
--        along the normal, `r` flips the winding, the swatch strip
--        paints, ds / unlit chips toggle.
-- CTRL+click on any edge selects its EDGE LOOP in every mode (loop
-- verts in vtx, the walked quad strip in face mode).
--
-- The viewport is a 2x2 QUAD VIEW by default (chip toggles single):
-- orbit perspective + top / front / side axis projections sharing the
-- focus point and zoom — every pane picks, marquees, and drags through
-- its own projection (an ortho drag moves in that pane's plane).
-- Middle-drag orbits the perspective pane and pans the ortho panes;
-- wheel dollies all four; shift+1 frames the mesh.
--
-- The add strip drops primitive starters (box / prism / wedge / plane)
-- at the origin. Save (Ctrl+S) bumps cm.asset_epoch so every 3d map
-- window re-reads placed instances the same frame.

local ob = cm.require("cm.ed.orbit")
local mesh = cm.require("cm.mesh")
local gb = cm.require("cm.gb")
local mm = cm.require("cm.math")
local m4 = cm.require("cm.m4")

local M = { kind = "mesh" }
M.menu = "mesh"
M.exts = { "msh" }
M.help = "win-mesh"
M.DEF_W, M.DEF_H = 880, 720
M.JCAP = 512
M.wants_keys = true

local COL = {
  btn = 0x262238ff, btn_on = 0x4a4370ff,
  text = 0xd8d2f2ff, dim = 0x8a84b0ff, hot = 0xE8E4FFff,
  danger = 0xf07a7aff, vert = 0xb8c4e0ff, vsel = 0xE8E4FFff,
  edge = 0x8a84b066, esel = 0x7fd8a8ff,
}

-- the face-paint palette (era-friendly ramps; #rrggbb field for custom)
local SWATCH = {
  { 0.62, 0.60, 0.66 }, { 0.36, 0.55, 0.28 }, { 0.24, 0.38, 0.20 },
  { 0.55, 0.42, 0.28 }, { 0.38, 0.28, 0.20 }, { 0.62, 0.58, 0.48 },
  { 0.50, 0.50, 0.55 }, { 0.32, 0.34, 0.40 }, { 0.80, 0.30, 0.25 },
  { 0.85, 0.65, 0.25 }, { 0.30, 0.50, 0.70 }, { 0.85, 0.85, 0.88 },
  { 0.15, 0.15, 0.18 }, { 0.72, 0.45, 0.60 }, { 0.35, 0.62, 0.60 },
  { 0.95, 0.90, 0.60 },
}

-- ---- the asset citizen ----

local function decode_into(p, bytes)
  local ok, doc = pcall(mesh.decode, bytes)
  if ok then
    p.doc = doc
    p.err = nil
  else
    p.doc = nil
    p.err = tostring(doc)
  end
  p.gen = (p.gen or 0) + 1
  p.g = nil
  p.vsel, p.esel, p.fsel = {}, {}, {}
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "msw", field = "msh", jcap = M.JCAP,
  fresh = function(ed, path)
    local name = path:match("([^/]+)%.msh$") or "mesh"
    return mesh.encode(mesh.fresh(name))
  end,
  adopt = decode_into,
  encode = mesh.encode,
  write = function(ed, path, a, p)
    return mesh.save(p.doc, ed.root .. "/" .. path, p._save_fail)
  end,
  after_save = function(ed, path)
    cm.asset_epoch = (cm.asset_epoch or 0) + 1 -- placed instances re-read
    return "[ed] saved " .. path .. " (instances refresh)"
  end,
}

local plumb, working, open_asset, commit =
  A.plumb, A.working, A.open_asset, A.commit

M.open_win = A.open_win
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

function M.defaults()
  local d = ob.defaults(4, 0, 0.4, 0)
  d.mode = "sel"
  d.quad = true
  return d
end

function M.title(win)
  if (win.path or "") == "" then return "mesh" end
  return win.path:match("([^/]+)%.msh$") or win.path
end

function M.accepts(win, path) return path:sub(-4) == ".msh" end

function M.rebind(win, ed, path)
  win.path = path
  A.open_asset(ed, path)
end

local function any_sel(p)
  return (p.vsel and #p.vsel > 0) or (p.esel and #p.esel > 0)
      or (p.fsel and #p.fsel > 0)
end

function M.escape(win, ed)
  local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
  if p and p.g then
    if p.g.mutates then decode_into(p, working(ed, win.path).msh) end
    p.g = nil
    ed.touch()
    return true
  end
  if p and any_sel(p) then
    p.vsel, p.esel, p.fsel = {}, {}, {}
    ed.touch()
    return true
  end
  if win.axis then
    win.axis = nil
    ed.touch()
    return true
  end
  return false
end

-- ---- view lock trio ----

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

function M.ctrl_wheel(win, ed, notches)
  if ed.doc.focus ~= win.id then return false end
  local s = win.gstep or 0.25
  s = notches > 0 and s * 2 or s / 2
  win.gstep = mm.clamp(s, 0.03125, 2)
  ed.touch()
  return true
end

-- ---- modes + header ----

local function set_mode(win, ed, mode)
  local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
  if p and p.doc and (win.mode or "sel") ~= mode then
    p.vsel, p.esel, p.fsel = mesh.convert_sel(
      p.doc, p.vsel or {}, p.esel or {}, p.fsel or {}, mode)
  end
  win.mode = mode
  ed.touch()
end

local function bound_focused(win, ed)
  return win.path ~= "" and ed.doc.focus == win.id
end

function M.header(win, ctx)
  if win.path == "" then return 0 end
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local i = cm.require("cm.ui").inp
  local x = ctx.hx
  local used = 0
  local function chip(label, on)
    local w = pal.x_ig_text_size(label, px, 0) + 12 * z
    x = x - w - 3 * z
    used = used + w + 3 * z
    local hov = ctx.hot and i.wx >= x and i.wx < x + w
                and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
    pal.x_ig_rect_fill(x, ctx.hy + 3 * z, w, ctx.hh - 6 * z,
                       on and COL.btn_on or COL.btn, 4 * z)
    pal.x_ig_text(x + 6 * z, ctx.hy + (ctx.hh - px) * 0.45, px,
                  (hov or on) and COL.hot or COL.dim, label, 0)
    return hov and i.clicked[1]
  end
  if chip("mirror", win.mirror) then
    win.mirror = not win.mirror
    ctx.ed.touch()
  end
  if chip("quad", win.quad) then
    win.quad = not win.quad
    ctx.ed.touch()
  end
  local mode = win.mode or "sel"
  if chip("face", mode == "face") then set_mode(win, ctx.ed, "face") end
  if chip("edge", mode == "edge") then set_mode(win, ctx.ed, "edge") end
  if chip("vtx", mode == "vtx") then set_mode(win, ctx.ed, "vtx") end
  if chip("sel", mode == "sel") then set_mode(win, ctx.ed, "sel") end
  return used
end

-- ---- selection helpers ----

local function sel_has(sel, i)
  for _, v in ipairs(sel) do if v == i then return true end end
  return false
end

local function sel_toggle(sel, i)
  for k, v in ipairs(sel) do
    if v == i then
      table.remove(sel, k)
      return
    end
  end
  sel[#sel + 1] = i
end

-- a click candidate: { kind = "vert"|"edge"|"face", id }
local function cand_set(p, c)
  return c.kind == "vert" and p.vsel or c.kind == "edge" and p.esel or p.fsel
end

local function cand_selected(p, c)
  return sel_has(cand_set(p, c), c.id)
end

local function cand_only(p, c)
  local s = cand_set(p, c)
  local total = #p.vsel + #p.esel + #p.fsel
  return total == 1 and #s == 1 and s[1] == c.id
end

local function select_only(p, c)
  p.vsel, p.esel, p.fsel = {}, {}, {}
  cand_set(p, c)[1] = c.id
end

local function apply_col(win, ed, col)
  local p = plumb(ed, win.path)
  if not (p.doc and p.fsel and #p.fsel > 0) then return end
  for _, fi in ipairs(p.fsel) do
    local f = p.doc.faces[fi]
    if f then f.col = { col[1], col[2], col[3] } end
  end
  commit(ed, win.path)
  ed.touch()
end

-- ---- hotkeys ----

local function has_fsel(win, ed)
  local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
  return bound_focused(win, ed) and p and p.fsel and #p.fsel > 0
end

M.hotkeys = {
  { key = "1", hint = "sel", when = bound_focused,
    fn = function(win, ed) set_mode(win, ed, "sel") end },
  { key = "2", when = bound_focused,
    fn = function(win, ed) set_mode(win, ed, "vtx") end },
  { key = "3", when = bound_focused,
    fn = function(win, ed) set_mode(win, ed, "edge") end },
  { key = "4", when = bound_focused,
    fn = function(win, ed) set_mode(win, ed, "face") end },
  { key = "v", when = bound_focused,
    fn = function(win, ed) set_mode(win, ed, "vtx") end },
  { key = "f", when = bound_focused,
    fn = function(win, ed) set_mode(win, ed, "face") end },
  { key = "x", hint = "lock x", when = bound_focused,
    fn = function(win, ed)
      win.axis = win.axis ~= "x" and "x" or nil
      ed.touch()
    end },
  { key = "y", when = bound_focused,
    fn = function(win, ed)
      win.axis = win.axis ~= "y" and "y" or nil
      ed.touch()
    end },
  { key = "z", when = bound_focused,
    fn = function(win, ed)
      win.axis = win.axis ~= "z" and "z" or nil
      ed.touch()
    end },
  { key = "e", hint = "extrude", when = has_fsel,
    fn = function(win, ed)
      local p = plumb(ed, win.path)
      for _, fi in ipairs(p.fsel) do
        mesh.extrude(p.doc, fi, win.gstep or 0.25)
      end
      p.gen = p.gen + 1
      commit(ed, win.path)
      ed.touch()
    end },
  { key = "r", hint = "flip", when = has_fsel,
    fn = function(win, ed)
      local p = plumb(ed, win.path)
      for _, fi in ipairs(p.fsel) do mesh.flip(p.doc, fi) end
      p.gen = p.gen + 1
      commit(ed, win.path)
      ed.touch()
    end },
  { key = "m", hint = "merge",
    when = function(win, ed)
      local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
      return bound_focused(win, ed) and p and p.vsel and #p.vsel >= 2
    end,
    fn = function(win, ed)
      local p = plumb(ed, win.path)
      mesh.merge_verts(p.doc, p.vsel)
      p.vsel = {}
      p.gen = p.gen + 1
      commit(ed, win.path)
      ed.touch()
    end },
  { key = "del", hint = "delete",
    when = function(win, ed)
      local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
      return bound_focused(win, ed) and p and any_sel(p)
    end,
    fn = function(win, ed)
      local p = plumb(ed, win.path)
      local set = {}
      if #p.fsel > 0 then
        for _, fi in ipairs(p.fsel) do set[fi] = true end
      elseif #p.esel > 0 then
        -- dissolve: drop every face carrying a selected edge
        local ekeys = {}
        for _, key in ipairs(p.esel) do ekeys[key] = true end
        for fi, f2 in ipairs(p.doc.faces) do
          local n = #f2.v
          for k = 1, n do
            if ekeys[mesh.ekey(f2.v[k], f2.v[k % n + 1])] then
              set[fi] = true
              break
            end
          end
        end
      elseif #p.vsel > 0 then
        -- dissolve: drop every face touching a selected vert
        local vset = {}
        for _, vi in ipairs(p.vsel) do vset[vi] = true end
        for fi, f2 in ipairs(p.doc.faces) do
          for _, vi in ipairs(f2.v) do
            if vset[vi] then set[fi] = true break end
          end
        end
      end
      mesh.remove_faces(p.doc, set)
      p.vsel, p.esel, p.fsel = {}, {}, {}
      p.gen = p.gen + 1
      commit(ed, win.path)
      ed.touch()
    end },
  { key = "shift+1", hint = "frame",
    fn = function(win, ed)
      local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
      if p and p.doc then
        local b = mesh.bounds(p.doc)
        local cx = (b[1] + b[4]) * 0.5
        local cyy = (b[2] + b[5]) * 0.5
        local cz = (b[3] + b[6]) * 0.5
        local r = math.max(b[4] - b[1], b[5] - b[2], b[6] - b[3]) * 0.7
        ob.fit(win, cx, cyy, cz, math.max(r, 0.5))
      end
      ed.touch()
    end },
}

-- ---- scratch buffers (the terr window's size-following pattern) ----

local BUFSZ = {}
local function scratch(name, bytes)
  local want = 256
  while want < #bytes do want = want * 2 end
  if BUFSZ[name] == nil then
    for _, b in ipairs(pal.buf_list()) do
      if b.name == name then BUFSZ[name] = b.size break end
    end
  end
  if BUFSZ[name] and BUFSZ[name] ~= want then pal.buf_free(name) end
  local vb = pal.buf(name, want)
  BUFSZ[name] = want
  vb:setstr(0, bytes)
  return vb
end

-- the faint lattice floor + gnomon (orientation)
local FLOOR
local function floor_scene()
  if FLOOR then return FLOOR end
  local out = {}
  local function vert(x, y, z, r, g, b, a)
    return string.pack("<fffffBBBB", x, y, z, 0, 0, r, g, b, a or 255)
  end
  local function fq(x0, z0, x1, z1, v)
    local a = vert(x0, 0, z0, v, v, v + 6, 120)
    local b = vert(x1, 0, z0, v, v, v + 6, 120)
    local c = vert(x1, 0, z1, v, v, v + 6, 120)
    local d = vert(x0, 0, z1, v, v, v + 6, 120)
    out[#out + 1] = a .. b .. c .. a .. c .. d
  end
  local S, TH = 4, 0.008
  for i = -S, S do
    local v = i == 0 and 110 or (i % 2 == 0 and 78 or 52)
    fq(i * 0.5 - TH, -S * 0.5, i * 0.5 + TH, S * 0.5, v)
    fq(-S * 0.5, i * 0.5 - TH, S * 0.5, i * 0.5 + TH, v)
  end
  local bytes = table.concat(out)
  FLOOR = { bytes = bytes, ntris = #bytes // 72 }
  return FLOOR
end

-- ---- panes (the 2x2 quad view) ----

-- fixed axis projections: f = view direction, u = screen up
local AXVIEW = {
  top   = { f = { 0, -1, 0 }, u = { 0, 0, -1 }, label = "top" },
  front = { f = { 0, 0, -1 }, u = { 0, 1, 0 }, label = "front" },
  side  = { f = { -1, 0, 0 }, u = { 0, 1, 0 }, label = "side" },
}
local ORTHO_D = 250 -- ortho eye offset (clipping only; zf is 600)

local function pane_rects(win, vw, vh)
  if not win.quad or vw < 160 or vh < 120 then
    return { { x = 0, y = 0, w = vw, h = vh, kind = "persp" } }
  end
  local hw = math.floor(vw / 2) - 1
  local hh = math.floor(vh / 2) - 1
  return {
    { x = 0, y = 0, w = hw, h = hh, kind = "persp" },
    { x = hw + 2, y = 0, w = vw - hw - 2, h = hh, kind = "top" },
    { x = 0, y = hh + 2, w = hw, h = vh - hh - 2, kind = "front" },
    { x = hw + 2, y = hh + 2, w = vw - hw - 2, h = vh - hh - 2,
      kind = "side" },
  }
end

-- per-pane camera: vpm (project), drag basis right/up + px->world scale
-- at the focus plane, and what a ray needs. Ortho panes share the
-- perspective zoom (half-height = odist * tan(fov/2): the same world
-- span at the focus in all four panes).
local function pane_cam(win, pr)
  local half = (win.ofov or ob.FOV) * (mm.pi / 180) * 0.5
  if pr.kind == "persp" then
    local vpm = ob.vp(win, pr.w / math.max(1, pr.h))
    local _, _, _, rx, ry, rz, ux, uy, uz = ob.basis(win)
    local ex, ey, ez = ob.eye(win)
    local fx, fy, fz = ob.basis(win)
    return { vpm = vpm, persp = true,
             rx = rx, ry = ry, rz = rz, ux = ux, uy = uy, uz = uz,
             fx = fx, fy = fy, fz = fz, ex = ex, ey = ey, ez = ez,
             s = 2 * win.odist * mm.tan(half) / math.max(1, pr.h) }
  end
  local a = AXVIEW[pr.kind]
  local hh = win.odist * mm.tan(half)
  local hw = hh * pr.w / math.max(1, pr.h)
  local ex = win.ofx - a.f[1] * ORTHO_D
  local ey = win.ofy - a.f[2] * ORTHO_D
  local ez = win.ofz - a.f[3] * ORTHO_D
  local view = m4.lookat(ex, ey, ez, win.ofx, win.ofy, win.ofz,
                         a.u[1], a.u[2], a.u[3])
  -- screen right = f x u (lookat's own s vector)
  local rx = a.f[2] * a.u[3] - a.f[3] * a.u[2]
  local ry = a.f[3] * a.u[1] - a.f[1] * a.u[3]
  local rz = a.f[1] * a.u[2] - a.f[2] * a.u[1]
  return { vpm = m4.mul(m4.ortho(hw, hh, 0.3, 600), view),
           rx = rx, ry = ry, rz = rz,
           ux = a.u[1], uy = a.u[2], uz = a.u[3],
           fx = a.f[1], fy = a.f[2], fz = a.f[3],
           ex = ex, ey = ey, ez = ez, hw = hw, hh = hh,
           s = 2 * hh / math.max(1, pr.h) }
end

-- cursor (pane-local px) -> world ray
local function pane_ray(win, pr, cam, sx, sy)
  if cam.persp then return ob.ray(win, pr.w, pr.h, sx, sy) end
  local nx = (2 * sx / math.max(1, pr.w) - 1) * cam.hw
  local ny = (1 - 2 * sy / math.max(1, pr.h)) * cam.hh
  return { ox = cam.ex + cam.rx * nx + cam.ux * ny,
           oy = cam.ey + cam.ry * nx + cam.uy * ny,
           oz = cam.ez + cam.rz * nx + cam.uz * ny,
           dx = cam.fx, dy = cam.fy, dz = cam.fz }
end

-- the eye a visibility test uses for vert vi in this pane (ortho rays
-- are parallel: each vert gets its own origin back along the view dir)
local function pane_eye_for(doc, cam, vi)
  if cam.persp then return cam.ex, cam.ey, cam.ez end
  local x, y, z = mesh.vert3(doc, vi)
  return x - cam.fx * ORTHO_D, y - cam.fy * ORTHO_D, z - cam.fz * ORTHO_D
end

-- point -> segment distance in px (+ the parameter along the segment)
local function seg_dist(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = 0
  if l2 > 1e-9 then
    t = ((px - ax) * dx + (py - ay) * dy) / l2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
  end
  local qx, qy = ax + dx * t - px, ay + dy * t - py
  return math.sqrt(qx * qx + qy * qy), t
end

-- everything under the cursor in one pane: nearest vert (px), nearest
-- in-threshold edge (frontmost by view depth), first two ray faces.
-- An edge candidate must not sit BEHIND the front face hit — a far
-- silhouette edge projects inside the silhouette and would otherwise
-- steal clicks aimed at the face in front of it.
local function hit_at(doc, edges, proj, nv, px, py, z, ray)
  local bv, bvd
  for vi = 1, nv do
    local pr = proj[vi]
    if pr then
      local d = math.abs(pr[1] - px) + math.abs(pr[2] - py)
      if d < 10 * z and (not bvd or d < bvd) then bv, bvd = vi, d end
    end
  end
  local hits = mesh.pick_hits(doc, ray)
  local t1 = hits[1] and hits[1].t
  local be, bed
  for _, e in ipairs(edges) do
    local pa, pb = proj[e.a], proj[e.b]
    if pa and pb then
      local d, t = seg_dist(px, py, pa[1], pa[2], pb[1], pb[2])
      if d < 7 * z then
        -- ray param of the edge's closest point (screen-space lerp is
        -- exact enough inside the px threshold)
        local x1, y1, z1 = mesh.vert3(doc, e.a)
        local x2, y2, z2 = mesh.vert3(doc, e.b)
        local ex2 = x1 + (x2 - x1) * t
        local ey2 = y1 + (y2 - y1) * t
        local ez2 = z1 + (z2 - z1) * t
        local te = (ex2 - ray.ox) * ray.dx + (ey2 - ray.oy) * ray.dy
                 + (ez2 - ray.oz) * ray.dz
        if not t1 or te <= t1 * 1.05 + 0.05 then
          local depth = pa[3] + (pb[3] - pa[3]) * t
          if not bed or depth < bed then be, bed = e, depth end
        end
      end
    end
  end
  return { vert = bv, edge = be,
           f1 = hits[1] and hits[1].fi, f2 = hits[2] and hits[2].fi }
end

-- the universal/edge/face click ladder: first candidate + the one
-- drill-behind candidate ("not further than that")
local function sel_candidates(mode, hit)
  if mode == "face" then
    return hit.f1 and { kind = "face", id = hit.f1 } or nil,
           hit.f2 and { kind = "face", id = hit.f2 } or nil
  elseif mode == "edge" then
    return hit.edge and { kind = "edge", id = hit.edge.key } or nil, nil
  end
  local c1, c2
  if hit.edge then c1 = { kind = "edge", id = hit.edge.key }
  elseif hit.f1 then c1 = { kind = "face", id = hit.f1 } end
  if hit.vert then c2 = { kind = "vert", id = hit.vert }
  elseif hit.edge and hit.f1 then c2 = { kind = "face", id = hit.f1 }
  elseif hit.f2 then c2 = { kind = "face", id = hit.f2 } end
  return c1, c2
end

-- ---- draw ----

function M.draw(win, ctx)
  local ed = ctx.ed
  ob.rt_prune(ed)
  local i = cm.require("cm.ui").inp
  local g = ed.g
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local vx, vy = ctx.cx, ctx.cy
  local INSP = math.max(12, 22 * z)
  local vw = math.max(1, math.floor(ctx.cw + 0.5))
  local vh = math.max(1, math.floor(ctx.ch - INSP - 2 * z + 0.5))
  if vh < 40 then INSP, vh = 0, math.max(1, math.floor(ctx.ch + 0.5)) end

  local bound = (win.path or "") ~= ""
  local p, doc
  if bound then
    local _, pp = open_asset(ed, win.path)
    p = pp
    if p.err or not p.doc then
      pal.x_ig_text(vx + 8 * z, vy + 8 * z, px, COL.danger,
                    "unreadable .msh: " .. tostring(p.err), 0)
      return
    end
    doc = p.doc
    p.vsel = p.vsel or {}
    p.esel = p.esel or {}
    p.fsel = p.fsel or {}
  end

  local over_view = i.wx >= vx and i.wx < vx + vw
                and i.wy >= vy and i.wy < vy + vh
  -- unbound windows show the single orientation pane
  local panes = pane_rects(bound and win or { quad = false }, vw, vh)

  local function pane_at(wxl, wyl)
    for k, pr in ipairs(panes) do
      if wxl >= pr.x and wxl < pr.x + pr.w
         and wyl >= pr.y and wyl < pr.y + pr.h then
        return k
      end
    end
    return nil
  end

  -- camera gestures: middle-drag orbits the persp pane, pans an ortho
  -- pane; the gesture stays with the pane it started in
  local gest = ob.gest(ed)
  if ctx.focused and i.clicked[2] and over_view then
    local pi = pane_at(i.wx - vx, i.wy - vy)
    if pi then
      gest[win.id] = { pane = pi, mx = i.wx, my = i.wy,
                       pan = g.shift or false }
    end
  end
  local cg = gest[win.id]
  if cg then
    if i.buttons[2] then
      local pr = panes[cg.pane] or panes[1]
      local dxs, dys = i.wx - cg.mx, i.wy - cg.my
      if pr.kind == "persp" then
        if cg.pan then ob.pan(win, dxs, dys, pr.h)
        else ob.orbit(win, dxs, dys) end
      else
        local cam = pane_cam(win, pr)
        win.ofx = win.ofx - cam.rx * dxs * cam.s + cam.ux * dys * cam.s
        win.ofy = win.ofy - cam.ry * dxs * cam.s + cam.uy * dys * cam.s
        win.ofz = win.ofz - cam.rz * dxs * cam.s + cam.uz * dys * cam.s
      end
      cg.mx, cg.my = i.wx, i.wy
      ctx.touch()
    else
      gest[win.id] = nil
    end
  end

  -- per-pane cameras + the 3D scene into each pane's RT
  local cams, rts = {}, {}
  local fl = floor_scene()
  local mode = win.mode or "sel"
  local nv = 0
  if bound then
    nv = #doc.verts // 3
    if p.meshgen ~= p.gen then
      local out = {}
      p.meshtris = mesh.emit(out, m4.ident(), m4.ident(), doc)
      p.meshbytes = table.concat(out)
      p.meshgen = p.gen
      p.edges = mesh.edges(doc)
    end
    p.edges = p.edges or mesh.edges(doc)
  end
  for k, pr in ipairs(panes) do
    cams[k] = pane_cam(win, pr)
    rts[k] = ob.rt_for(ed, win, math.max(1, pr.w), math.max(1, pr.h),
                       k > 1 and ("p" .. k) or nil)
    pal.x_view3d{ mvp = cams[k].vpm, target = rts[k].tex,
                  clear = { 0.09, 0.10, 0.13, 1 } }
    pal.x_tris(0, scratch("ed.mshfloor", fl.bytes), fl.ntris, 0, 4)
    if bound and p.meshtris and p.meshtris > 0 then
      pal.x_tris(0, scratch("ed.mshvb:" .. win.path, p.meshbytes),
                 p.meshtris, 0)
    end
  end

  -- projected verts per pane (pane-local px + view depth)
  local projs = {}
  if bound then
    for k, pr in ipairs(panes) do
      local cam = cams[k]
      local pj = {}
      for vi = 1, nv do
        local x, y, zz = mesh.vert3(doc, vi)
        local sx, sy = ob.project(cam.vpm, pr.w, pr.h, x, y, zz)
        if sx then
          local d = (x - cam.ex) * cam.fx + (y - cam.ey) * cam.fy
                  + (zz - cam.ez) * cam.fz
          pj[vi] = { sx, sy, d }
        else
          pj[vi] = false
        end
      end
      projs[k] = pj
    end
  end

  -- ---- selection gestures (button 1) ----
  if bound and ctx.focused and over_view and not g.alt and not p.g
     and i.clicked[1] then
    local pi = pane_at(i.wx - vx, i.wy - vy)
    if pi then
      local pr, cam = panes[pi], cams[pi]
      local lx, ly = i.wx - vx - pr.x, i.wy - vy - pr.y
      local ray = pane_ray(win, pr, cam, lx, ly)
      local hit = hit_at(doc, p.edges, projs[pi], nv, lx, ly, z, ray)
      if g.ctrl and hit.edge and (mode ~= "vtx" or not hit.vert) then
        -- CTRL+click an edge: the edge loop, expressed in this mode
        -- (the face under the cursor picks the fallback side on a
        -- dead-end edge — a cube edge selects THAT face's ring)
        local keys, lfaces = mesh.edge_loop(doc, hit.edge.a, hit.edge.b,
                                            hit.f1)
        if mode == "vtx" then
          p.vsel, p.esel, p.fsel =
            mesh.sel_verts(doc, {}, keys, {}), {}, {}
        elseif mode == "face" then
          p.fsel = #lfaces > 0 and lfaces or { hit.f1 }
          p.vsel, p.esel = {}, {}
        else
          p.vsel, p.esel, p.fsel = {}, keys, {}
        end
        ed.touch()
      elseif mode == "vtx" then
        if hit.vert then
          if g.shift then
            sel_toggle(p.vsel, hit.vert)
          elseif not sel_has(p.vsel, hit.vert) then
            p.vsel = { hit.vert }
          end
          p.esel, p.fsel = {}, {}
          p.g = { mode = "vmove", btn = 1, mutates = true, pane = pi,
                  mx = i.wx, my = i.wy,
                  mv = mesh.sel_verts(doc, p.vsel, {}, {}) }
          ed.touch()
        else
          p.g = { mode = "marquee", btn = 1, mutates = false, pane = pi,
                  x0 = i.wx, y0 = i.wy, add = g.shift or false }
        end
      else
        local c1, c2 = sel_candidates(mode, hit)
        local on_sel = (c1 and cand_selected(p, c1))
                    or (c2 and cand_selected(p, c2))
                    or (hit.vert and sel_has(p.vsel, hit.vert))
        p.g = { mode = "pend", btn = 1, mutates = false, pane = pi,
                mx = i.wx, my = i.wy, x0 = i.wx, y0 = i.wy,
                c1 = c1, c2 = c2, on_sel = on_sel and true or false,
                add = g.shift or false, vert = hit.vert }
      end
    end
  end

  if bound and p.g then
    local held = i.buttons[1]
    local gg = p.g
    if held and gg.mode == "pend" then
      local moved = math.abs(i.wx - gg.x0) + math.abs(i.wy - gg.y0) > 4 * z
      if moved then
        if gg.on_sel and not gg.add then
          gg.mode = "vmove"
          gg.mutates = true
          gg.mv = mesh.sel_verts(doc, p.vsel, p.esel, p.fsel)
        else
          gg.mode = "marquee"
        end
      end
    end
    if held then
      if gg.mode == "vmove" then
        local dxs, dys = i.wx - gg.mx, i.wy - gg.my
        gg.mx, gg.my = i.wx, i.wy
        local cam = cams[gg.pane] or cams[1]
        local s = cam.s
        local dx = (cam.rx * dxs - cam.ux * dys) * s
        local dy = (cam.ry * dxs - cam.uy * dys) * s
        local dz = (cam.rz * dxs - cam.uz * dys) * s
        local ax = win.axis
        if ax == "x" then dy, dz = 0, 0 end
        if ax == "y" then dx, dz = 0, 0 end
        if ax == "z" then dx, dy = 0, 0 end
        local mv = gg.mv or mesh.sel_verts(doc, p.vsel, p.esel, p.fsel)
        local mvset = {}
        for _, vi in ipairs(mv) do mvset[vi] = true end
        for _, vi in ipairs(mv) do
          local base = (vi - 1) * 3
          doc.verts[base + 1] = doc.verts[base + 1] + dx
          doc.verts[base + 2] = doc.verts[base + 2] + dy
          doc.verts[base + 3] = doc.verts[base + 3] + dz
          if win.mirror then
            local pr2 = mesh.mirror_pair(doc, vi, 0.02)
            if pr2 and not mvset[pr2] then
              local b2 = (pr2 - 1) * 3
              doc.verts[b2 + 1] = doc.verts[b2 + 1] - dx
              doc.verts[b2 + 2] = doc.verts[b2 + 2] + dy
              doc.verts[b2 + 3] = doc.verts[b2 + 3] + dz
            end
          end
          if g.ctrl then
            local st = win.gstep or 0.25
            doc.verts[base + 1] =
              math.floor(doc.verts[base + 1] / st + 0.5) * st
            doc.verts[base + 2] =
              math.floor(doc.verts[base + 2] / st + 0.5) * st
            doc.verts[base + 3] =
              math.floor(doc.verts[base + 3] / st + 0.5) * st
          end
        end
        p.gen = p.gen + 1
        ctx.touch()
      end
    else
      if gg.mode == "marquee" then
        local pr = panes[gg.pane] or panes[1]
        local cam = cams[gg.pane] or cams[1]
        local pj = projs[gg.pane] or projs[1]
        local ox, oy = vx + pr.x, vy + pr.y
        local x0 = math.min(gg.x0, i.wx) - ox
        local x1 = math.max(gg.x0, i.wx) - ox
        local y0 = math.min(gg.y0, i.wy) - oy
        local y1 = math.max(gg.y0, i.wy) - oy
        local function inrect(vi)
          local pv = pj[vi]
          return pv and pv[1] >= x0 and pv[1] <= x1
                 and pv[2] >= y0 and pv[2] <= y1
        end
        if mode == "vtx" or mode == "sel" then
          if not gg.add then p.vsel = {} end
          if mode == "sel" and not gg.add then p.esel, p.fsel = {}, {} end
          for vi = 1, nv do
            if inrect(vi) and not sel_has(p.vsel, vi) then
              -- universal marquee takes only VISIBLE verts; vtx mode
              -- boxes through (the x-ray marquee)
              if mode == "vtx" then
                p.vsel[#p.vsel + 1] = vi
              else
                local ex2, ey2, ez2 = pane_eye_for(doc, cam, vi)
                if mesh.vert_visible(doc, ex2, ey2, ez2, vi) then
                  p.vsel[#p.vsel + 1] = vi
                end
              end
            end
          end
        elseif mode == "edge" then
          if not gg.add then p.esel = {} end
          for _, e in ipairs(p.edges) do
            if inrect(e.a) and inrect(e.b)
               and not sel_has(p.esel, e.key) then
              p.esel[#p.esel + 1] = e.key
            end
          end
        elseif mode == "face" then
          if not gg.add then p.fsel = {} end
          for fi, f in ipairs(doc.faces) do
            local all = true
            for _, vi in ipairs(f.v) do
              if not inrect(vi) then all = false break end
            end
            if all and not sel_has(p.fsel, fi) then
              p.fsel[#p.fsel + 1] = fi
            end
          end
        end
      elseif gg.mode == "vmove" then
        commit(ed, win.path)
      elseif gg.mode == "pend" then
        -- a clean click: select, or drill one level behind
        local c1, c2 = gg.c1, gg.c2
        if gg.add and c1 then
          sel_toggle(cand_set(p, c1), c1.id)
        elseif c1 then
          if cand_only(p, c1) and c2 then
            select_only(p, c2)
          else
            select_only(p, c1)
          end
        else
          p.vsel, p.esel, p.fsel = {}, {}, {}
        end
      end
      p.g = nil
      ctx.touch()
    end
  end

  -- ---- blit + overlays per pane ----
  for k, pr in ipairs(panes) do
    local ox, oy = vx + pr.x, vy + pr.y
    pal.x_ig_image(rts[k].tex, ox, oy, pr.w, pr.h)
    if pr.kind ~= "persp" then
      pal.x_ig_text(ox + 4 * z, oy + 3 * z, math.max(4, 9 * z), COL.dim,
                    AXVIEW[pr.kind].label, 0)
    end
    if bound then
      pal.x_ig_clip_push(ox, oy, pr.w, pr.h)
      local pj = projs[k]
      local fselset, eselset = {}, {}
      for _, fi in ipairs(p.fsel) do fselset[fi] = true end
      for _, key in ipairs(p.esel) do eselset[key] = true end
      for fi, f in ipairs(doc.faces) do
        local n = #f.v
        local fs = fselset[fi]
        for kk = 1, n do
          local a = pj[f.v[kk]]
          local b = pj[f.v[kk % n + 1]]
          if a and b then
            local es = eselset[mesh.ekey(f.v[kk], f.v[kk % n + 1])]
            local col = (fs or es) and COL.esel or COL.edge
            local wdt = (fs or es) and 2 or 1
            pal.x_ig_line(ox + a[1], oy + a[2], ox + b[1], oy + b[2],
                          col, wdt)
          end
        end
      end
      if mode == "vtx" then
        for vi = 1, nv do
          local pv = pj[vi]
          if pv then
            local selv = sel_has(p.vsel, vi)
            pal.x_ig_circle_fill(ox + pv[1], oy + pv[2],
                                 (selv and 3.5 or 2) * z,
                                 selv and COL.vsel or COL.vert)
          end
        end
      else
        for _, vi in ipairs(p.vsel) do
          local pv = pj[vi]
          if pv then
            pal.x_ig_circle_fill(ox + pv[1], oy + pv[2], 3.5 * z, COL.vsel)
          end
        end
      end
      pal.x_ig_clip_pop()
    end
  end
  if #panes > 1 then -- pane separators
    local hw = panes[1].w
    local hh = panes[1].h
    pal.x_ig_rect_fill(vx + hw, vy, 2, vh, 0x14122066, 0)
    pal.x_ig_rect_fill(vx, vy + hh, vw, 2, 0x14122066, 0)
  end

  -- live marquee rect (over the blits)
  if bound and p.g and p.g.mode == "marquee" then
    pal.x_ig_rect(math.min(p.g.x0, i.wx), math.min(p.g.y0, i.wy),
                  math.abs(i.wx - p.g.x0), math.abs(i.wy - p.g.y0),
                  COL.hot, 1, 0)
  end

  if not bound then
    A.pathfield(win, ed, ctx, {
      ext = "msh", default = "art/",
      label = "no mesh bound — drag a .msh here, or type a path:",
    })
    return
  end

  -- ---- the inspector strip ----
  if INSP > 0 then
    local sy0 = vy + vh + 2 * z
    local sx = vx + 6 * z
    local function chip(label, on)
      local w = pal.x_ig_text_size(label, px, 0) + 10 * z
      local hov = i.wx >= sx and i.wx < sx + w
                  and i.wy >= sy0 and i.wy < sy0 + INSP
      pal.x_ig_rect_fill(sx, sy0 + 2 * z, w, INSP - 4 * z,
                         on and COL.btn_on or COL.btn, 3 * z)
      pal.x_ig_text(sx + 5 * z, sy0 + (INSP - px) * 0.45, px,
                    (hov or on) and COL.hot or COL.dim, label, 0)
      sx = sx + w + 3 * z
      return hov and i.clicked[1]
    end
    -- add strip
    for _, kind in ipairs({ "box", "prism", "wedge", "plane" }) do
      if chip("+" .. kind, false) then
        mesh.add_prim(doc, kind, { n = 6 })
        p.gen = p.gen + 1
        commit(ed, win.path)
        ed.touch()
      end
    end
    if #p.fsel > 0 then
      -- swatches apply to the face selection (face mode or a universal
      -- pick — wherever faces are selected)
      for si, c in ipairs(SWATCH) do
        local sw = 10 * z
        local hov = i.wx >= sx and i.wx < sx + sw
                    and i.wy >= sy0 and i.wy < sy0 + INSP
        pal.x_ig_rect_fill(sx, sy0 + 3 * z, sw, INSP - 6 * z,
          (math.floor(c[1] * 255) << 24) | (math.floor(c[2] * 255) << 16)
          | (math.floor(c[3] * 255) << 8) | 0xff, 2 * z)
        if hov and i.clicked[1] then apply_col(win, ed, c) end
        sx = sx + sw + 2 * z
        local _ = si
      end
      sx = sx + 4 * z
      local dsn, unl = false, false
      for _, fi in ipairs(p.fsel) do
        local f = doc.faces[fi]
        if f then
          dsn = dsn or f.ds
          unl = unl or f.unlit
        end
      end
      if chip("ds", dsn) then
        for _, fi in ipairs(p.fsel) do
          local f = doc.faces[fi]
          if f then f.ds = not dsn and true or nil end
        end
        p.gen = p.gen + 1
        commit(ed, win.path)
        ed.touch()
      end
      if chip("unlit", unl) then
        for _, fi in ipairs(p.fsel) do
          local f = doc.faces[fi]
          if f then f.unlit = not unl and true or nil end
        end
        p.gen = p.gen + 1
        commit(ed, win.path)
        ed.touch()
      end
    end
    local ntris = 0
    for _, f in ipairs(doc.faces) do
      ntris = ntris + (#f.v - 2) * (f.ds and 2 or 1)
    end
    pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px, COL.dim,
      ("%s  v=%d t=%d  sel v:%d e:%d f:%d  grid %.3g%s%s"):format(
        mode, nv, ntris, #p.vsel, #p.esel, #p.fsel,
        win.gstep or 0.25,
        win.axis and ("  axis:" .. win.axis) or "",
        win.mirror and "  mirror" or ""), 0)
  end
end

return M
