-- cm.ed.win.mesh — the mesh window (kind `mesh`, EDITOR3D.md §5, D137):
-- the picoCAD-class low-poly editor over `.msh` — verts + tri/quad
-- faces, flat per-face colors, doublesided/unlit flags. The refusal set
-- is cm.mesh's: no skinning, no modifiers, no subdivision, no UV
-- unwrap — ever.
--
-- Two modes (header chips):
--   vtx (`v`) — click picks the nearest vertex (shift adds; click empty
--        drags a marquee); dragging a selected vertex moves the whole
--        selection on the camera plane — `x`/`y`/`z` toggle an axis
--        lock, CTRL snaps to the model grid (ctrl+wheel dials the
--        step), the mirror chip edits the x<0 twin live. `m` merges the
--        selection at its mean; del dissolves (faces touching die).
--   face (`f`) — click ray-picks a face (shift adds). `e` extrudes
--        along the normal by one grid step (THE power op), `r` flips
--        the winding, del removes. The inspector's swatch strip applies
--        its color to the selection on click; `#rrggbb` types a custom
--        color; ds / unlit chips toggle.
-- The add strip drops primitive starters (box / prism / wedge / plane)
-- at the origin. Save (Ctrl+S) bumps cm.asset_epoch so every 3d map
-- window re-reads placed instances the same frame.
--
-- The viewport is the shared cm.ed.orbit pool: middle-drag orbits,
-- shift+middle pans, wheel dollies, shift+1 frames the mesh; a faint
-- lattice floor + gnomon keep orientation (the terr window's scene).

local ob = cm.require("cm.ed.orbit")
local mesh = cm.require("cm.mesh")
local gb = cm.require("cm.gb")
local mm = cm.require("cm.math")
local m4 = cm.require("cm.m4")

local M = { kind = "mesh" }
M.menu = "mesh"
M.exts = { "msh" }
M.help = "win-mesh"
M.DEF_W, M.DEF_H = 440, 360
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
  p.vsel, p.fsel = {}, {}
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
  d.mode = "vtx"
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

function M.escape(win, ed)
  local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
  if p and p.g then
    if p.g.mutates then decode_into(p, working(ed, win.path).msh) end
    p.g = nil
    ed.touch()
    return true
  end
  if p and ((p.vsel and #p.vsel > 0) or (p.fsel and #p.fsel > 0)) then
    p.vsel, p.fsel = {}, {}
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

-- ---- header: mode chips + mirror ----

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
  if chip("face", (win.mode or "vtx") == "face") then
    win.mode = "face"
    ctx.ed.touch()
  end
  if chip("vtx", (win.mode or "vtx") == "vtx") then
    win.mode = "vtx"
    ctx.ed.touch()
  end
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

M.hotkeys = {
  { key = "v", hint = "verts", when = bound_focused,
    fn = function(win, ed) win.mode = "vtx"; ed.touch() end },
  { key = "f", hint = "faces", when = bound_focused,
    fn = function(win, ed) win.mode = "face"; ed.touch() end },
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
  { key = "e", hint = "extrude",
    when = function(win, ed)
      local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
      return bound_focused(win, ed) and (win.mode or "vtx") == "face"
             and p and p.fsel and #p.fsel > 0
    end,
    fn = function(win, ed)
      local p = plumb(ed, win.path)
      for _, fi in ipairs(p.fsel) do
        mesh.extrude(p.doc, fi, win.gstep or 0.25)
      end
      p.gen = p.gen + 1
      commit(ed, win.path)
      ed.touch()
    end },
  { key = "r", hint = "flip",
    when = function(win, ed)
      local p = win.path ~= "" and ed.g.msw and ed.g.msw[win.path]
      return bound_focused(win, ed) and (win.mode or "vtx") == "face"
             and p and p.fsel and #p.fsel > 0
    end,
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
      return bound_focused(win, ed) and (win.mode or "vtx") == "vtx"
             and p and p.vsel and #p.vsel >= 2
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
      return bound_focused(win, ed) and p
             and ((p.vsel and #p.vsel > 0) or (p.fsel and #p.fsel > 0))
    end,
    fn = function(win, ed)
      local p = plumb(ed, win.path)
      if (win.mode or "vtx") == "face" and #p.fsel > 0 then
        local set = {}
        for _, fi in ipairs(p.fsel) do set[fi] = true end
        mesh.remove_faces(p.doc, set)
        p.fsel = {}
      elseif #p.vsel > 0 then
        -- dissolve: drop every face touching a selected vert
        local set = {}
        local vset = {}
        for _, vi in ipairs(p.vsel) do vset[vi] = true end
        for fi, f2 in ipairs(p.doc.faces) do
          for _, vi in ipairs(f2.v) do
            if vset[vi] then set[fi] = true break end
          end
        end
        mesh.remove_faces(p.doc, set)
        p.vsel = {}
      end
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
    p.fsel = p.fsel or {}
  end

  local over_view = i.wx >= vx and i.wx < vx + vw
                and i.wy >= vy and i.wy < vy + vh
  ob.gestures(win, ed, ctx, i, vh)

  local r = ob.rt_for(ed, win, vw, vh)
  local vpm, _, _, ex, ey, ez = ob.vp(win, vw / vh)
  pal.x_view3d{ mvp = vpm, target = r.tex, clear = { 0.09, 0.10, 0.13, 1 } }
  local fl = floor_scene()
  pal.x_tris(0, scratch("ed.mshfloor", fl.bytes), fl.ntris, 0, 4)

  local mode = win.mode or "vtx"
  local nv = 0
  if bound then
    nv = #doc.verts // 3
    -- the mesh itself (identity transforms; gb default light)
    if p.meshgen ~= p.gen then
      local out = {}
      p.meshtris = mesh.emit(out, m4.ident(), m4.ident(), doc)
      p.meshbytes = table.concat(out)
      p.meshgen = p.gen
    end
    if p.meshtris and p.meshtris > 0 then
      pal.x_tris(0, scratch("ed.mshvb:" .. win.path, p.meshbytes),
                 p.meshtris, 0)
    end

    -- projected verts (screen px, viewport-relative), cached per frame
    local proj = {}
    for vi = 1, nv do
      local x, y, zz = mesh.vert3(doc, vi)
      local sx, sy = ob.project(vpm, vw, vh, x, y, zz)
      proj[vi] = sx and { sx, sy } or false
    end

    -- ---- gestures ----
    if ctx.focused and over_view and not g.alt and not p.g
       and i.clicked[1] then
      if mode == "vtx" then
        local best, bestd
        for vi = 1, nv do
          local pr = proj[vi]
          if pr then
            local d = math.abs(vx + pr[1] - i.wx) + math.abs(vy + pr[2] - i.wy)
            if d < 12 * z and (not bestd or d < bestd) then
              best, bestd = vi, d
            end
          end
        end
        if best then
          if g.shift then
            sel_toggle(p.vsel, best)
          elseif not sel_has(p.vsel, best) then
            p.vsel = { best }
          end
          p.g = { mode = "vmove", btn = 1, mutates = true,
                  mx = i.wx, my = i.wy }
          ed.touch()
        else
          p.g = { mode = "marquee", btn = 1, mutates = false,
                  x0 = i.wx, y0 = i.wy, add = g.shift or false }
        end
      else -- face mode: ray pick
        local ray = ob.ray(win, vw, vh, i.wx - vx, i.wy - vy)
        local fi = mesh.pick_face(doc, ray)
        if fi then
          if g.shift then sel_toggle(p.fsel, fi)
          else p.fsel = { fi } end
        elseif not g.shift then
          p.fsel = {}
        end
        ed.touch()
      end
    end

    if p.g then
      local held = i.buttons[1]
      if held then
        if p.g.mode == "vmove" and #p.vsel > 0 then
          local dxs, dys = i.wx - p.g.mx, i.wy - p.g.my
          p.g.mx, p.g.my = i.wx, i.wy
          local fx, fy, fz, rx, ry, rz, ux, uy, uz = ob.basis(win)
          local half = (win.ofov or ob.FOV) * (mm.pi / 180) * 0.5
          local s = 2 * win.odist * mm.tan(half) / vh
          local dx = (rx * dxs - ux * dys) * s
          local dy = (ry * dxs - uy * dys) * s
          local dz = (rz * dxs - uz * dys) * s
          local ax = win.axis
          if ax == "x" then dy, dz = 0, 0 end
          if ax == "y" then dx, dz = 0, 0 end
          if ax == "z" then dx, dy = 0, 0 end
          p.g.acc = p.g.acc or {}
          for _, vi in ipairs(p.vsel) do
            local base = (vi - 1) * 3
            doc.verts[base + 1] = doc.verts[base + 1] + dx
            doc.verts[base + 2] = doc.verts[base + 2] + dy
            doc.verts[base + 3] = doc.verts[base + 3] + dz
            if win.mirror then
              local pr = mesh.mirror_pair(doc, vi, 0.02)
              if pr and not sel_has(p.vsel, pr) then
                local b2 = (pr - 1) * 3
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
        if p.g.mode == "marquee" then
          local x0 = math.min(p.g.x0, i.wx)
          local x1 = math.max(p.g.x0, i.wx)
          local y0 = math.min(p.g.y0, i.wy)
          local y1 = math.max(p.g.y0, i.wy)
          if not p.g.add then p.vsel = {} end
          for vi = 1, nv do
            local pr = proj[vi]
            if pr then
              local sx, sy = vx + pr[1], vy + pr[2]
              if sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1
                 and not sel_has(p.vsel, vi) then
                p.vsel[#p.vsel + 1] = vi
              end
            end
          end
        elseif p.g.mode == "vmove" then
          commit(ed, win.path)
        end
        p.g = nil
        ctx.touch()
      end
    end

    pal.x_ig_image(r.tex, vx, vy, vw, vh)

    -- live marquee rect (over the blit)
    if p.g and p.g.mode == "marquee" then
      pal.x_ig_rect(math.min(p.g.x0, i.wx), math.min(p.g.y0, i.wy),
                    math.abs(i.wx - p.g.x0), math.abs(i.wy - p.g.y0),
                    COL.hot, 1, 0)
    end

    -- wireframe edges (faint; selected faces accent)
    local fselset = {}
    for _, fi in ipairs(p.fsel) do fselset[fi] = true end
    for fi, f in ipairs(doc.faces) do
      local n = #f.v
      local col = fselset[fi] and COL.esel or COL.edge
      local wdt = fselset[fi] and 2 or 1
      for k = 1, n do
        local a = proj[f.v[k]]
        local b = proj[f.v[k % n + 1]]
        if a and b then
          pal.x_ig_line(vx + a[1], vy + a[2], vx + b[1], vy + b[2], col, wdt)
        end
      end
    end
    -- verts on top (vtx mode)
    if mode == "vtx" then
      for vi = 1, nv do
        local pr = proj[vi]
        if pr then
          local selv = sel_has(p.vsel, vi)
          pal.x_ig_circle_fill(vx + pr[1], vy + pr[2],
                               (selv and 3.5 or 2) * z,
                               selv and COL.vsel or COL.vert)
        end
      end
    end
  else
    pal.x_ig_image(r.tex, vx, vy, vw, vh)
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
    if mode == "face" then
      -- swatches apply to the selection
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
      if #p.fsel > 0 then
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
    end
    local ntris = 0
    for _, f in ipairs(doc.faces) do
      ntris = ntris + (#f.v - 2) * (f.ds and 2 or 1)
    end
    pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px, COL.dim,
      ("%s  v=%d t=%d  sel %s  grid %.3g%s%s"):format(
        mode, nv, ntris,
        mode == "vtx" and ("v:" .. #p.vsel) or ("f:" .. #p.fsel),
        win.gstep or 0.25,
        win.axis and ("  axis:" .. win.axis) or "",
        win.mirror and "  mirror" or ""), 0)
  end
end

return M
