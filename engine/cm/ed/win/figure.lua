-- cm.ed.win.figure — the figure window (kind `figure`, EDITOR3D.md §6,
-- E5, D137): the rigid-part character editor over `.fig` — a part tree
-- with gb shapes (gbox/ball/prism/lathe/mesh), named clips of sparse
-- pose keys, and the sheet bake. NO skinning, NO weights, NO IK — ever
-- (the cm.fig refusal set).
--
-- Three tabs (header chips) over one orbit viewport + a left panel:
--   parts (`1`) — the tree (click selects, `+part` adds a child, del
--        removes and reparents children, `m`/the mirror chip copies a
--        `_l` part to its `_r` twin x-negated). Drag the selected
--        part's JOINT dot in the viewport to move it on the camera
--        plane (CTRL snaps to the grid step; ctrl+wheel dials it).
--        The panel's lower half lists the selected part's shapes:
--        click selects, swatches recolor, param chips drag-dial,
--        `+shape` adds, a mesh shape's path edits inline.
--   pose (`2`) — the clip editor: clips in the panel's lower half
--        (`+clip` adds, chips rename-cycle rate / loop / dup / del),
--        the KEY RAIL along the bottom (diamonds; click selects, `+`
--        inserts a copy after, del removes, drag reorders), space
--        plays at the clip's rate through fig.cycle — what you scrub
--        is what ships. Drag a part in the viewport to ROTATE it
--        about the axis facing the camera (`x`/`y`/`z` lock, CTRL =
--        15° steps); shift+drag TRANSLATES on the camera plane (the
--        mascot's floating mitts are translated parts). Edits write
--        the SELECTED key's sparse pose; `clear` re-sparses the part.
--        Prev/next keys ghost at low alpha (onion skins).
--   bake (`3`) — the .spx sheet: rows (clip @ t) in the panel, the
--        preview rendered by cm.spr's REAL rasterizer, and the bake
--        button writing `spr/<name>.spx` (editable path) through the
--        atomic door. The model-once-use-anywhere loop closes here.
--
-- Save (Ctrl+S) bumps cm.asset_epoch so 3d maps with placed figures
-- refresh; a mesh shape re-resolves when its .msh saves (same epoch).

local ob = cm.require("cm.ed.orbit")
local fig = cm.require("cm.fig")
local mm = cm.require("cm.math")
local m4 = cm.require("cm.m4")

local M = { kind = "figure" }
M.menu = "figure"
M.exts = { "fig" }
M.help = "win-figure"
M.DEF_W, M.DEF_H = 760, 560
M.JCAP = 512
M.wants_keys = true

local COL = {
  btn = 0x262238ff, btn_on = 0x4a4370ff, panel = 0x1a1730ff,
  row = 0x232038ff, row_on = 0x3a3560ff,
  text = 0xd8d2f2ff, dim = 0x8a84b0ff, hot = 0xE8E4FFff,
  danger = 0xf07a7aff, joint = 0xffb46eff, jsel = 0xE8E4FFff,
  rail = 0x141220ff, key = 0x8a84b0ff, ksel = 0x7fd8a8ff,
}

local SWATCH = {
  { 0.28, 0.60, 0.62 }, { 0.94, 0.90, 0.78 }, { 0.95, 0.52, 0.38 },
  { 0.10, 0.09, 0.13 }, { 0.97, 0.97, 0.95 }, { 1.00, 0.85, 0.35 },
  { 0.62, 0.60, 0.66 }, { 0.36, 0.55, 0.28 }, { 0.55, 0.42, 0.28 },
  { 0.45, 0.55, 0.60 }, { 0.80, 0.30, 0.25 }, { 0.30, 0.50, 0.70 },
}

-- ---- the asset citizen ----

local function decode_into(p, bytes)
  local ok, doc = pcall(fig.decode, bytes)
  if ok then
    p.doc = doc
    p.err = nil
  else
    p.doc = nil
    p.err = tostring(doc)
  end
  p.gen = (p.gen or 0) + 1
  p.g = nil
  p.play = nil
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "fgw", field = "fig", jcap = M.JCAP,
  fresh = function(ed, path)
    local name = path:match("([^/]+)%.fig$") or "figure"
    return fig.encode(fig.fresh(name))
  end,
  adopt = decode_into,
  encode = fig.encode,
  write = function(ed, path, a, p)
    return fig.save(p.doc, ed.root .. "/" .. path, p._save_fail)
  end,
  after_save = function(ed, path)
    cm.asset_epoch = (cm.asset_epoch or 0) + 1 -- placed figures re-read
    return "[ed] saved " .. path .. " (instances refresh)"
  end,
}

local plumb, working, open_asset, commit =
  A.plumb, A.working, A.open_asset, A.commit

M.open_win = A.open_win
M.seed = A.seed -- the stock window's open-a-copy door (D147)
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

function M.defaults()
  local d = ob.defaults(6, 0, 1.0, 0)
  d.oyaw = -2.45 -- face the figure's FRONT (+z) three-quarter — the
  -- floating hands/feet sit ahead of the body and hide from behind
  d.tab = "parts"
  d.part = 1
  d.clip = 1
  d.key = 1
  return d
end

function M.title(win)
  if (win.path or "") == "" then return "figure" end
  return win.path:match("([^/]+)%.fig$") or win.path
end

function M.accepts(win, path) return path:sub(-4) == ".fig" end

function M.rebind(win, ed, path)
  win.path = path
  A.open_asset(ed, path)
end

-- the drag-in door: a .msh dropped on a bound figure becomes a MESH
-- SHAPE on the selected part (the "add a hat from a .msh" flow — no
-- path typing; the shape chip cross-opens the mesh window)
function M.drop(win, ed, path, wx, wy)
  if win.path == "" or path:sub(-4) ~= ".msh" then return false end
  local p = win.path ~= "" and ed.g.fgw and ed.g.fgw[win.path]
  if not (p and p.doc) then return false end
  local part = p.doc.parts[win.part or 1]
  if not part then return false end
  part.shapes[#part.shapes + 1] = { kind = "mesh", col = { 1, 1, 1 },
                                    path = path }
  win.shape = #part.shapes
  win.tab = "parts"
  p.gen = p.gen + 1
  commit(ed, win.path)
  ed.touch()
  return true
end

function M.escape(win, ed)
  local p = win.path ~= "" and ed.g.fgw and ed.g.fgw[win.path]
  if p and p.g then
    if p.g.mutates then decode_into(p, working(ed, win.path).fig) end
    p.g = nil
    ed.touch()
    return true
  end
  if p and p.play then
    p.play = nil
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
  local s = win.gstep or 0.1
  s = notches > 0 and s * 2 or s / 2
  win.gstep = mm.clamp(s, 0.0125, 1)
  ed.touch()
  return true
end

-- ---- doc helpers ----

local function cur(win, ed)
  local p = win.path ~= "" and ed.g.fgw and ed.g.fgw[win.path]
  if not (p and p.doc) then return nil end
  return p, p.doc
end

local function cur_clip(win, doc)
  local ci = mm.clamp(win.clip or 1, 1, math.max(1, #doc.clips))
  return doc.clips[ci], ci
end

local function cur_key(win, cl)
  if not cl then return nil, 1 end
  local ki = mm.clamp(win.key or 1, 1, math.max(1, #cl.keys))
  return cl.keys[ki], ki
end

-- the figure cache: rebuilt when the doc changes OR any asset saves
-- (a mesh part edits live through cm.asset_epoch)
local function figure_of(ed, p)
  local epoch = cm.asset_epoch or 0
  if p.fg and p.fggen == p.gen and p.fgepoch == epoch then return p.fg end
  local ok, fg = pcall(fig.build_doc, p.doc, function(path)
    return pal.read_file(ed.root .. "/" .. path)
  end)
  p.fg = ok and fg or nil
  p.fgerr = not ok and tostring(fg) or nil
  p.fggen, p.fgepoch = p.gen, epoch
  return p.fg
end

-- the pose previewed this frame. The parts tab shows the FIRST clip's
-- first key rather than the bind pose: floating parts (the mascot's
-- mitts and boots) are POSITIONED by pose translations — at bind they
-- all sit at the origin inside the body, invisible.
local function preview_pose(win, p, doc)
  local cl = cur_clip(win, doc)
  if not cl or #cl.keys == 0 then return {} end
  if win.tab == "pose" or win.tab == "bake" then
    if p.play then return fig.cycle(cl.keys, p.play.t) end
    local key = cur_key(win, cl)
    return key or {}
  end
  return doc.clips[1] and doc.clips[1].keys[1] or {}
end

-- part depth for tree indent
local function depths(doc)
  local d, byname = {}, {}
  for i, p in ipairs(doc.parts) do
    d[i] = p.parent and ((d[byname[p.parent] or 0] or 0) + 1) or 0
    byname[p.name] = i
  end
  return d
end

-- ---- hotkeys ----

local function bound_focused(win, ed)
  return win.path ~= "" and ed.doc.focus == win.id
end

local function set_tab(win, ed, tab)
  win.tab = tab
  ed.touch()
end

M.hotkeys = {
  { key = "1", hint = "parts", when = bound_focused,
    fn = function(win, ed) set_tab(win, ed, "parts") end },
  { key = "2", hint = "pose", when = bound_focused,
    fn = function(win, ed) set_tab(win, ed, "pose") end },
  { key = "3", hint = "bake", when = bound_focused,
    fn = function(win, ed) set_tab(win, ed, "bake") end },
  { key = "space", hint = "play",
    when = function(win, ed)
      return bound_focused(win, ed) and win.tab == "pose"
    end,
    fn = function(win, ed)
      local p, doc = cur(win, ed)
      if not p then return end
      if p.play then p.play = nil
      else p.play = { t = 0 } end
      ed.touch()
    end },
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
  { key = "m", hint = "mirror",
    when = function(win, ed)
      local p, doc = cur(win, ed)
      return bound_focused(win, ed) and win.tab == "parts" and doc
             and doc.parts[win.part or 1]
             and doc.parts[win.part or 1].name:find("_l$") ~= nil
    end,
    fn = function(win, ed)
      local p, doc = cur(win, ed)
      if not p then return end
      local ti = fig.mirror_lr(doc, win.part or 1)
      if ti then
        p.gen = p.gen + 1
        commit(ed, win.path)
      end
      ed.touch()
    end },
  { key = "del", hint = "delete",
    when = function(win, ed)
      local p, doc = cur(win, ed)
      if not (bound_focused(win, ed) and doc) then return false end
      if win.tab == "parts" then return #doc.parts > 1 end
      if win.tab == "pose" then
        local cl = doc.clips[win.clip or 1]
        return cl and #cl.keys > 1
      end
      return false
    end,
    fn = function(win, ed)
      local p, doc = cur(win, ed)
      if not p then return end
      if win.tab == "parts" then
        if fig.remove_part(doc, win.part or 1) then
          win.part = mm.clamp((win.part or 1) - 1, 1, #doc.parts)
          p.gen = p.gen + 1
          commit(ed, win.path)
        end
      else
        local cl = cur_clip(win, doc)
        local _, ki = cur_key(win, cl)
        if cl and #cl.keys > 1 then
          table.remove(cl.keys, ki)
          win.key = mm.clamp(ki, 1, #cl.keys)
          p.gen = p.gen + 1
          commit(ed, win.path)
        end
      end
      ed.touch()
    end },
  { key = "shift+1", hint = "frame",
    fn = function(win, ed)
      local p, doc = cur(win, ed)
      if p then
        local fg = figure_of(ed, p)
        if fg then
          local js = fig.joints(fg, {})
          local lo, hi = 1e9, -1e9
          for _, j in ipairs(js) do
            lo, hi = math.min(lo, j[2]), math.max(hi, j[2])
          end
          ob.fit(win, 0, (lo + hi) * 0.5, 0,
                 math.max(1.2, (hi - lo) * 1.1))
        end
      end
      ed.touch()
    end },
}

-- ---- scratch buffers + floor (the mesh window's pattern) ----

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

-- ---- sheet preview textures (freed generationally across reboots) ----

local TEXCAP = 16
do
  local b = pal.buf("ed.figtex", 4 * (TEXCAP + 1))
  local n = b:u32(0)
  for i = 1, math.min(n, TEXCAP) do pal.tex_free(b:u32(4 * i)) end
  b:u32(0, 0)
end
local SHEETS = {} -- win.id -> { tex, w, h, sig, fv }
local function sheets_reg()
  local b = pal.buf("ed.figtex", 4 * (TEXCAP + 1))
  local n = 0
  for _, r in pairs(SHEETS) do
    if n < TEXCAP then n = n + 1; b:u32(4 * n, r.tex) end
  end
  b:u32(0, n)
end

-- resolve win.rows ({clip=,t=} list) against the doc -> cm.spr row specs
local function bake_rows(win, doc)
  local rows = win.rows
  if not rows or #rows == 0 then
    rows = {}
    for _, c in ipairs(doc.clips) do rows[#rows + 1] = { clip = c.name, t = 0 } end
    win.rows = rows
  end
  local specs, names = {}, {}
  for _, r in ipairs(rows) do
    for _, c in ipairs(doc.clips) do
      if c.name == r.clip and #c.keys > 0 then
        specs[#specs + 1] = { c.keys, r.t or 0 }
        names[#names + 1] = r
        break
      end
    end
  end
  return specs, names
end

local function rows_sig(win, p)
  local parts = { tostring(p.gen), tostring(p.fgepoch) }
  for _, r in ipairs(win.rows or {}) do
    parts[#parts + 1] = r.clip .. "@" .. tostring(r.t or 0)
  end
  return table.concat(parts, "|")
end

local function sheet_preview(ed, win, p, fg, doc)
  local sig = rows_sig(win, p)
  local got = SHEETS[win.id]
  if got and got.sig == sig then return got end
  local specs = bake_rows(win, doc)
  if #specs == 0 then return nil end
  local spr = cm.require("cm.spr")
  local px, fv = spr.rasterize_sheet(fg, specs)
  local w, h = spr.DIRS * spr.CW, #specs * spr.CH
  if got then pal.tex_free(got.tex) end
  got = { tex = pal.tex_create(w, h, px), w = w, h = h, sig = sig,
          fv = fv, px = px }
  SHEETS[win.id] = got
  sheets_reg()
  return got
end

-- ---- pose editing ----

-- write one channel of the selected key's sparse pose
local function pose_set(key, part, chan, v)
  local e = key[part]
  if not e then
    e = {}
    key[part] = e
  end
  e[chan] = v
end

local function pose_get(key, part, chan, dflt)
  local e = key[part]
  local v = e and e[chan]
  if v == nil then return dflt end
  return v
end

-- the world axis facing the camera most directly (the dominant-axis
-- rotation grammar); win.axis overrides
local function drag_axis(win)
  if win.axis then return win.axis end
  local fx, fy, fz = ob.basis(win)
  local ax, ay, az = math.abs(fx), math.abs(fy), math.abs(fz)
  if ay >= ax and ay >= az then return "y" end
  if ax >= az then return "x" end
  return "z"
end

local CHAN = { x = 1, y = 2, z = 3 }

-- ---- header: tab chips ----

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
  local tab = win.tab or "parts"
  if chip("bake", tab == "bake") then set_tab(win, ctx.ed, "bake") end
  if chip("pose", tab == "pose") then set_tab(win, ctx.ed, "pose") end
  if chip("parts", tab == "parts") then set_tab(win, ctx.ed, "parts") end
  return used
end

-- ---- draw ----

function M.draw(win, ctx)
  local ed = ctx.ed
  ob.rt_prune(ed)
  for id in pairs(SHEETS) do -- prune sheet textures with their windows
    if not cm.require("cm.ed.wm").get(ed.doc, id) then
      pal.tex_free(SHEETS[id].tex)
      SHEETS[id] = nil
      sheets_reg()
    end
  end
  local i = cm.require("cm.ui").inp
  local g = ed.g
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local INSP = math.max(12, 22 * z)
  local tab = win.tab or "parts"
  local RAIL = tab == "pose" and math.max(12, 20 * z) or 0
  local PW = math.max(60, 128 * z) -- the left panel
  local vx = ctx.cx + PW + 2 * z
  local vy = ctx.cy
  local vw = math.max(1, math.floor(ctx.cw - PW - 2 * z + 0.5))
  local vh = math.max(1, math.floor(ctx.ch - INSP - RAIL - 2 * z + 0.5))

  local bound = (win.path or "") ~= ""
  local p, doc
  if bound then
    local _, pp = open_asset(ed, win.path)
    p = pp
    if p.err or not p.doc then
      pal.x_ig_text(ctx.cx + 8 * z, vy + 8 * z, px, COL.danger,
                    "unreadable .fig: " .. tostring(p.err), 0)
      return
    end
    doc = p.doc
    win.part = mm.clamp(win.part or 1, 1, math.max(1, #doc.parts))
  end

  if not bound then
    -- the unbound door: pathfield over the empty scene
    local r = ob.rt_for(ed, win, math.max(1, math.floor(ctx.cw + 0.5)),
                        math.max(1, math.floor(ctx.ch + 0.5)))
    local vpm = ob.vp(win, ctx.cw / math.max(1, ctx.ch))
    pal.x_view3d{ mvp = vpm, target = r.tex,
                  clear = { 0.09, 0.10, 0.13, 1 } }
    local fl = floor_scene()
    pal.x_tris(0, scratch("ed.figfloor", fl.bytes), fl.ntris, 0, 4)
    pal.x_ig_image(r.tex, ctx.cx, ctx.cy, ctx.cw, ctx.ch)
    A.pathfield(win, ed, ctx, {
      ext = "fig", default = "art/",
      label = "no figure bound — drag a .fig here, or type a path:",
    })
    return
  end

  local fg = figure_of(ed, p)
  local cl, ci = cur_clip(win, doc)
  win.clip = ci
  local key, ki = cur_key(win, cl)
  win.key = ki

  -- advance play (wall-follow: one tick per drawn frame at the editor's
  -- cadence; preview-only state, never recorded)
  if p.play and cl then
    p.play.t = (p.play.t + (cl.rate or 1) / 60) % 1
    ctx.touch()
  end

  local over_view = i.wx >= vx and i.wx < vx + vw
                and i.wy >= vy and i.wy < vy + vh
  ob.gestures(win, ed, ctx, i, vh)

  -- ---- the 3D scene ----
  local r = ob.rt_for(ed, win, vw, vh)
  local vpm = ob.vp(win, vw / math.max(1, vh))
  pal.x_view3d{ mvp = vpm, target = r.tex, clear = { 0.09, 0.10, 0.13, 1 } }
  local fl = floor_scene()
  pal.x_tris(0, scratch("ed.figfloor", fl.bytes), fl.ntris, 0, 4)

  local pose = preview_pose(win, p, doc)
  local joints
  if fg then
    local out = {}
    local ntris = fig.emit(out, fg, m4.ident(), pose)
    if ntris > 0 then
      pal.x_tris(0, scratch("ed.figvb:" .. win.path, table.concat(out)),
                 ntris, 0)
    end
    -- onion skins: the neighbor keys at low alpha (pose tab, paused)
    if tab == "pose" and not p.play and cl and #cl.keys > 1 then
      local oout = {}
      local prev = cl.keys[(ki - 2) % #cl.keys + 1]
      local nxt = cl.keys[ki % #cl.keys + 1]
      local on = fig.emit(oout, fg, m4.ident(), prev, 46)
      on = on + fig.emit(oout, fg, m4.ident(), nxt, 46)
      if on > 0 then
        pal.x_tris(0, scratch("ed.figon:" .. win.path,
                              table.concat(oout)), on, 0, 4)
      end
    end
    joints = fig.joints(fg, pose)
  end

  -- ---- viewport gestures (button 1) ----
  local proj = {}
  if joints then
    for pi2, j in ipairs(joints) do
      local sx, sy = ob.project(vpm, vw, vh, j[1], j[2], j[3])
      proj[pi2] = sx and { sx, sy } or false
    end
  end

  if ctx.focused and over_view and not g.alt and not p.g and i.clicked[1]
     and tab ~= "bake" and joints then
    local best, bestd
    for pi2, pr in ipairs(proj) do
      if pr then
        local d = math.abs(vx + pr[1] - i.wx) + math.abs(vy + pr[2] - i.wy)
        if d < 14 * z and (not bestd or d < bestd) then
          best, bestd = pi2, d
        end
      end
    end
    if tab == "parts" then
      if best then
        win.part = best
        p.g = { mode = "joint", mutates = true, mx = i.wx, my = i.wy }
        ed.touch()
      end
    else -- pose tab: any press over the figure poses the SELECTED part
      if best then win.part = best end
      if key then
        p.g = { mode = g.shift and "ptrans" or "prot", mutates = true,
                mx = i.wx, my = i.wy,
                base = pose_get(key, doc.parts[win.part].name,
                                CHAN[drag_axis(win)] or 1, 0) }
        p.g.acc = 0
        ed.touch()
      end
    end
  end

  if p.g and (p.g.mode == "joint" or p.g.mode == "prot"
              or p.g.mode == "ptrans") then
    local held = i.buttons[1]
    if held then
      local dxs, dys = i.wx - p.g.mx, i.wy - p.g.my
      p.g.mx, p.g.my = i.wx, i.wy
      local _, _, _, rx, ry, rz, ux, uy, uz = ob.basis(win)
      local half = (win.ofov or ob.FOV) * (mm.pi / 180) * 0.5
      local s = 2 * win.odist * mm.tan(half) / math.max(1, vh)
      local part = doc.parts[win.part]
      if p.g.mode == "joint" and part then
        local dx = (rx * dxs - ux * dys) * s
        local dy = (ry * dxs - uy * dys) * s
        local dz = (rz * dxs - uz * dys) * s
        local ax = win.axis
        if ax == "x" then dy, dz = 0, 0 end
        if ax == "y" then dx, dz = 0, 0 end
        if ax == "z" then dx, dy = 0, 0 end
        local j = part.joint
        j[1], j[2], j[3] = j[1] + dx, j[2] + dy, j[3] + dz
        if g.ctrl then
          local st = win.gstep or 0.1
          j[1] = math.floor(j[1] / st + 0.5) * st
          j[2] = math.floor(j[2] / st + 0.5) * st
          j[3] = math.floor(j[3] / st + 0.5) * st
        end
        p.gen = p.gen + 1
        ctx.touch()
      elseif p.g.mode == "prot" and part and key then
        local ax = drag_axis(win)
        p.g.acc = (p.g.acc or 0) + dxs * 0.01
        local v = p.g.base + p.g.acc
        if g.ctrl then
          local st = mm.pi / 12 -- 15 deg
          v = math.floor(v / st + 0.5) * st
        end
        pose_set(key, part.name, CHAN[ax], v ~= 0 and v or nil)
        p.gen = p.gen + 1
        ctx.touch()
      elseif p.g.mode == "ptrans" and part and key then
        local dx = (rx * dxs - ux * dys) * s
        local dy = (ry * dxs - uy * dys) * s
        local dz = (rz * dxs - uz * dys) * s
        local ax = win.axis
        if ax == "x" then dy, dz = 0, 0 end
        if ax == "y" then dx, dz = 0, 0 end
        if ax == "z" then dx, dy = 0, 0 end
        for c = 1, 3 do
          local d = ({ dx, dy, dz })[c]
          if d ~= 0 then
            pose_set(key, part.name, 3 + c,
                     pose_get(key, part.name, 3 + c, 0) + d)
          end
        end
        p.gen = p.gen + 1
        ctx.touch()
      end
    else
      commit(ed, win.path)
      p.g = nil
      ctx.touch()
    end
  end

  -- ---- blit + overlays ----
  if tab == "bake" then
    -- the sheet preview fills the viewport (rendered by the REAL baker)
    pal.x_ig_rect_fill(vx, vy, vw, vh, 0x0d0b18ff, 0)
    if fg then
      local ok, sh = pcall(sheet_preview, ed, win, p, fg, doc)
      if ok and sh then
        local fit = math.min(vw / sh.w, vh / sh.h, 4 * z)
        local dw, dh = sh.w * fit, sh.h * fit
        pal.x_ig_image(sh.tex, vx + (vw - dw) * 0.5, vy + (vh - dh) * 0.5,
                       dw, dh)
      else
        pal.x_ig_text(vx + 8 * z, vy + 8 * z, px, COL.danger,
                      "sheet: " .. tostring(sh), 0)
      end
    end
  else
    pal.x_ig_image(r.tex, vx, vy, vw, vh)
    -- joint dots (clipped: an off-edge projection must not paint over
    -- the rail/inspector — the terr gizmo rule)
    if joints and tab ~= "bake" then
      pal.x_ig_clip_push(vx, vy, vw, vh)
      for pi2, pr in ipairs(proj) do
        if pr then
          local selp = pi2 == win.part
          pal.x_ig_circle_fill(vx + pr[1], vy + pr[2],
                               (selp and 4 or 2.5) * z,
                               selp and COL.jsel or COL.joint)
        end
      end
      pal.x_ig_clip_pop()
    end
  end

  -- ---- the left panel: part tree (+ clips / rows below) ----
  local px0, py0 = ctx.cx, ctx.cy
  local ph = math.floor(ctx.ch + 0.5)
  pal.x_ig_rect_fill(px0, py0, PW, ph, COL.panel, 0)
  local rowh = math.max(8, 15 * z)
  local half = tab == "parts" and ph or math.floor(ph * 0.55)
  local y = py0 + 3 * z
  local dep = depths(doc)
  pal.x_ig_clip_push(px0, py0, PW, half)
  for pi2, part in ipairs(doc.parts) do
    if y + rowh <= py0 + half then
      local on = pi2 == win.part
      local hov = i.wx >= px0 and i.wx < px0 + PW
                  and i.wy >= y and i.wy < y + rowh
      if on or hov then
        pal.x_ig_rect_fill(px0 + 1, y, PW - 2, rowh,
                           on and COL.row_on or COL.row, 2 * z)
      end
      pal.x_ig_text(px0 + (4 + dep[pi2] * 8) * z,
                    y + (rowh - px) * 0.45, px,
                    on and COL.hot or COL.text, part.name, 0)
      if hov and i.clicked[1] then
        win.part = pi2
        win.shape = 1
        ed.touch()
      end
      y = y + rowh
    end
  end
  -- +part row
  if y + rowh <= py0 + half and tab == "parts" then
    local hov = i.wx >= px0 and i.wx < px0 + PW
                and i.wy >= y and i.wy < y + rowh
    pal.x_ig_text(px0 + 4 * z, y + (rowh - px) * 0.45, px,
                  hov and COL.hot or COL.dim, "+ part", 0)
    if hov and i.clicked[1] then
      local sel = doc.parts[win.part or 1]
      local n = #doc.parts + 1
      doc.parts[#doc.parts + 1] = {
        name = "part" .. n, parent = sel and sel.name or nil,
        joint = { 0, 0.3, 0 },
        shapes = { { kind = "gbox", col = { 0.6, 0.58, 0.62 },
                     size = { 0.25, 0.25, 0.25 } } },
      }
      win.part = #doc.parts
      p.gen = p.gen + 1
      commit(ed, win.path)
      ed.touch()
    end
  end
  pal.x_ig_clip_pop()

  if tab == "pose" then
    -- clips list in the lower half
    local cy0 = py0 + half
    pal.x_ig_rect_fill(px0, cy0, PW, 1, 0x35305aff, 0)
    local yy = cy0 + 3 * z
    pal.x_ig_clip_push(px0, cy0, PW, ph - half)
    for ci2, c in ipairs(doc.clips) do
      local on = ci2 == ci
      local hov = i.wx >= px0 and i.wx < px0 + PW
                  and i.wy >= yy and i.wy < yy + rowh
      if on or hov then
        pal.x_ig_rect_fill(px0 + 1, yy, PW - 2, rowh,
                           on and COL.row_on or COL.row, 2 * z)
      end
      pal.x_ig_text(px0 + 4 * z, yy + (rowh - px) * 0.45, px,
                    on and COL.hot or COL.text,
                    c.name .. "  (" .. #c.keys .. ")", 0)
      if hov and i.clicked[1] then
        win.clip = ci2
        win.key = 1
        p.play = nil
        ed.touch()
      end
      yy = yy + rowh
    end
    local hov = i.wx >= px0 and i.wx < px0 + PW
                and i.wy >= yy and i.wy < yy + rowh
    pal.x_ig_text(px0 + 4 * z, yy + (rowh - px) * 0.45, px,
                  hov and COL.hot or COL.dim, "+ clip", 0)
    if hov and i.clicked[1] then
      doc.clips[#doc.clips + 1] = {
        name = "clip" .. (#doc.clips + 1), rate = 1, loop = true,
        keys = { {}, {} },
      }
      win.clip = #doc.clips
      win.key = 1
      p.gen = p.gen + 1
      commit(ed, win.path)
      ed.touch()
    end
    pal.x_ig_clip_pop()
  elseif tab == "bake" then
    -- bake rows in the lower half
    local cy0 = py0 + half
    pal.x_ig_rect_fill(px0, cy0, PW, 1, 0x35305aff, 0)
    local yy = cy0 + 3 * z
    bake_rows(win, doc)
    pal.x_ig_clip_push(px0, cy0, PW, ph - half)
    for ri, rr in ipairs(win.rows) do
      local hov = i.wx >= px0 and i.wx < px0 + PW
                  and i.wy >= yy and i.wy < yy + rowh
      local on = (win.brow or 1) == ri
      if on or hov then
        pal.x_ig_rect_fill(px0 + 1, yy, PW - 2, rowh,
                           on and COL.row_on or COL.row, 2 * z)
      end
      pal.x_ig_text(px0 + 4 * z, yy + (rowh - px) * 0.45, px,
                    on and COL.hot or COL.text,
                    ("%s @ %.2f"):format(rr.clip, rr.t or 0), 0)
      if hov and i.clicked[1] then
        win.brow = ri
        ed.touch()
      end
      yy = yy + rowh
    end
    local hov = i.wx >= px0 and i.wx < px0 + PW
                and i.wy >= yy and i.wy < yy + rowh
    pal.x_ig_text(px0 + 4 * z, yy + (rowh - px) * 0.45, px,
                  hov and COL.hot or COL.dim, "+ row", 0)
    if hov and i.clicked[1] then
      local c = cl or doc.clips[1]
      if c then
        win.rows[#win.rows + 1] = { clip = c.name, t = 0 }
        win.brow = #win.rows
        ed.touch()
      end
    end
    pal.x_ig_clip_pop()
  end
  -- (parts tab: the tree gets the full panel; shape editing lives in
  -- the inspector strip below)

  -- ---- the key rail (pose tab) ----
  if RAIL > 0 and cl then
    local ry0 = vy + vh + 2 * z
    pal.x_ig_rect_fill(vx, ry0, vw, RAIL - 2 * z, COL.rail, 3 * z)
    local n = #cl.keys
    local step = math.min(26 * z, vw / math.max(1, n + 2))
    local kx = vx + 12 * z
    local kyc = ry0 + (RAIL - 2 * z) * 0.5
    for k = 1, n do
      local sel = k == ki
      local rad = (sel and 5 or 3.5) * z
      local hov = math.abs(i.wx - kx) < 8 * z
                  and i.wy >= ry0 and i.wy < ry0 + RAIL
      -- diamond = rotated square: cheap as a circle + ring here
      pal.x_ig_circle_fill(kx, kyc, rad, sel and COL.ksel
                           or (hov and COL.hot or COL.key))
      if hov and i.clicked[1] then
        win.key = k
        p.play = nil
        ed.touch()
      end
      kx = kx + step
    end
    -- + adds a copy of the selected key after it
    local hov = math.abs(i.wx - kx) < 8 * z
                and i.wy >= ry0 and i.wy < ry0 + RAIL
    pal.x_ig_text(kx - 3 * z, ry0 + (RAIL - px) * 0.4, px,
                  hov and COL.hot or COL.dim, "+", 0)
    if hov and i.clicked[1] and key then
      local copy = {}
      for name, e in pairs(key) do
        local ce = {}
        for k2, v in pairs(e) do ce[k2] = v end
        copy[name] = ce
      end
      table.insert(cl.keys, ki + 1, copy)
      win.key = ki + 1
      p.gen = p.gen + 1
      commit(ed, win.path)
      ed.touch()
    end
    -- play state readout at the right
    pal.x_ig_text(vx + vw - 90 * z, ry0 + (RAIL - px) * 0.4, px, COL.dim,
                  p.play and ("playing %.2f"):format(p.play.t)
                  or "space plays", 0)
  end

  -- ---- the inspector strip ----
  if INSP > 0 then
    local sy0 = vy + vh + RAIL + 2 * z
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
    -- a horizontal drag-dial: click-drag adjusts, returns the delta px.
    -- `id` must be STABLE — the label carries the live value, and a
    -- value-derived id would orphan the gesture after one step
    local function dial(id, label)
      local w = pal.x_ig_text_size(label, px, 0) + 10 * z
      local hov = i.wx >= sx and i.wx < sx + w
                  and i.wy >= sy0 and i.wy < sy0 + INSP
      pal.x_ig_rect_fill(sx, sy0 + 2 * z, w, INSP - 4 * z, COL.btn, 3 * z)
      pal.x_ig_text(sx + 5 * z, sy0 + (INSP - px) * 0.45, px,
                    hov and COL.hot or COL.dim, label, 0)
      sx = sx + w + 3 * z
      if hov and i.clicked[1] and not p.g then
        p.g = { mode = "dial", id = id, mutates = true, mx = i.wx }
        return 0
      end
      if p.g and p.g.mode == "dial" and p.g.id == id then
        if i.buttons[1] then
          local d = i.wx - p.g.mx
          p.g.mx = i.wx
          if d ~= 0 then return d end
        else
          commit(ed, win.path)
          p.g = nil
          ctx.touch()
        end
      end
      return nil
    end
    local part = doc.parts[win.part]

    if tab == "parts" and part then
      -- selected part identity + shape editing
      local d = dial("joint", ("joint %.2f %.2f %.2f"):format(
        part.joint[1], part.joint[2], part.joint[3]))
      -- (the joint edits by viewport drag; the dial nudges y)
      if d and d ~= 0 then
        part.joint[2] = part.joint[2] + d * 0.01
        p.gen = p.gen + 1
        ctx.touch()
      end
      local ns = #part.shapes
      win.shape = mm.clamp(win.shape or 1, 1, math.max(1, ns))
      local sh = part.shapes[win.shape]
      if sh then
        if chip(("shape %d/%d: %s"):format(win.shape, ns, sh.kind),
                false) then
          win.shape = win.shape % ns + 1
          ed.touch()
        end
        -- color swatches recolor the selected shape
        for _, c in ipairs(SWATCH) do
          local sw = 9 * z
          local hov = i.wx >= sx and i.wx < sx + sw
                      and i.wy >= sy0 and i.wy < sy0 + INSP
          pal.x_ig_rect_fill(sx, sy0 + 3 * z, sw, INSP - 6 * z,
            (math.floor(c[1] * 255) << 24)
            | (math.floor(c[2] * 255) << 16)
            | (math.floor(c[3] * 255) << 8) | 0xff, 2 * z)
          if hov and i.clicked[1] then
            sh.col = { c[1], c[2], c[3] }
            p.gen = p.gen + 1
            commit(ed, win.path)
            ed.touch()
          end
          sx = sx + sw + 2 * z
        end
        sx = sx + 4 * z
        -- per-kind size dial
        local d2
        if sh.kind == "gbox" then
          d2 = dial("size", ("size %.2f %.2f %.2f"):format(
            sh.size[1], sh.size[2], sh.size[3]))
          if d2 and d2 ~= 0 then
            local f = 1 + d2 * 0.01
            sh.size[1] = math.max(0.02, sh.size[1] * f)
            sh.size[2] = math.max(0.02, sh.size[2] * f)
            sh.size[3] = math.max(0.02, sh.size[3] * f)
            p.gen = p.gen + 1
            ctx.touch()
          end
        elseif sh.kind == "ball" then
          d2 = dial("ballr", ("r %.2f"):format(sh.r))
          if d2 and d2 ~= 0 then
            sh.r = math.max(0.02, sh.r * (1 + d2 * 0.01))
            p.gen = p.gen + 1
            ctx.touch()
          end
        elseif sh.kind == "prism" then
          d2 = dial("prism", ("r0 %.2f h %.2f"):format(sh.r0, sh.h))
          if d2 and d2 ~= 0 then
            local f = 1 + d2 * 0.01
            sh.r0, sh.r1 = math.max(0.01, sh.r0 * f),
                           math.max(0.01, sh.r1 * f)
            sh.h = math.max(0.02, sh.h * f)
            p.gen = p.gen + 1
            ctx.touch()
          end
        elseif sh.kind == "mesh" then
          if chip("mesh: " .. (sh.path ~= "" and sh.path or "unset"),
                  false) then
            -- cross-open the mesh beside (double-click convention's
            -- single-click cousin — one chip, one action)
            if sh.path ~= "" then
              ed.open_asset_window(sh.path, win.x + win.w + 16, win.y)
            end
          end
        end
      end
      local ADD = {
        box = { kind = "gbox", size = { 0.3, 0.3, 0.3 } },
        ball = { kind = "ball", r = 0.2, n = 8 },
        prism = { kind = "prism", n = 6, r0 = 0.15, r1 = 0.12, h = 0.4 },
        lathe = { kind = "lathe", n = 10,
                  prof = { 0, -0.3, 0.2, 0, 0, 0.3 } },
      }
      for _, kn in ipairs({ "box", "ball", "prism", "lathe" }) do
        if chip("+" .. kn, false) then
          local proto = ADD[kn]
          local s = { col = { 0.6, 0.58, 0.62 } }
          for k2, v in pairs(proto) do
            if type(v) == "table" then
              local cv = {}
              for kk, vv in pairs(v) do cv[kk] = vv end
              s[k2] = cv
            else
              s[k2] = v
            end
          end
          part.shapes[#part.shapes + 1] = s
          win.shape = #part.shapes
          p.gen = p.gen + 1
          commit(ed, win.path)
          ed.touch()
        end
      end
      if part.name:find("_l$") and chip("mirror L>R", false) then
        if fig.mirror_lr(doc, win.part) then
          p.gen = p.gen + 1
          commit(ed, win.path)
          ed.touch()
        end
      end
      pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px, COL.dim,
        ("%s  grid %.3g%s%s"):format(part.name, win.gstep or 0.1,
          win.axis and ("  axis:" .. win.axis) or "",
          p.fgerr and ("  ERR " .. p.fgerr) or ""), 0)
    elseif tab == "pose" and cl then
      local d = dial("rate", ("rate %.2f"):format(cl.rate or 1))
      if d and d ~= 0 then
        cl.rate = mm.clamp((cl.rate or 1) + d * 0.02, 0.05, 8)
        p.gen = p.gen + 1
        ctx.touch()
      end
      if chip(cl.loop and "loop" or "once", cl.loop) then
        cl.loop = not cl.loop
        p.gen = p.gen + 1
        commit(ed, win.path)
        ed.touch()
      end
      if part and key and key[part.name] and chip("clear " .. part.name,
                                                  false) then
        key[part.name] = nil
        p.gen = p.gen + 1
        commit(ed, win.path)
        ed.touch()
      end
      if chip("dup clip", false) then
        local copy = { name = cl.name .. "2", rate = cl.rate,
                       loop = cl.loop, keys = {} }
        for _, k2 in ipairs(cl.keys) do
          local ck = {}
          for name, e in pairs(k2) do
            local ce = {}
            for kk, v in pairs(e) do ce[kk] = v end
            ck[name] = ce
          end
          copy.keys[#copy.keys + 1] = ck
        end
        doc.clips[#doc.clips + 1] = copy
        win.clip = #doc.clips
        p.gen = p.gen + 1
        commit(ed, win.path)
        ed.touch()
      end
      pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px, COL.dim,
        ("%s  key %d/%d  part %s  drag rotates (%s)  shift moves  "
         .. "ctrl 15deg"):format(cl.name, ki, #cl.keys,
          part and part.name or "?", drag_axis(win)), 0)
    elseif tab == "bake" then
      local rr = win.rows and win.rows[win.brow or 1]
      if rr then
        local d = dial("rowt", ("t %.2f"):format(rr.t or 0))
        if d and d ~= 0 then
          rr.t = mm.clamp((rr.t or 0) + d * 0.01, 0, 0.99)
          ctx.touch()
        end
        if chip("clip: " .. rr.clip, false) then
          -- cycle the row's clip
          local idx = 1
          for k2, c in ipairs(doc.clips) do
            if c.name == rr.clip then idx = k2 break end
          end
          rr.clip = doc.clips[idx % #doc.clips + 1].name
          ed.touch()
        end
        if #win.rows > 1 and chip("-row", false) then
          table.remove(win.rows, win.brow or 1)
          win.brow = mm.clamp(win.brow or 1, 1, #win.rows)
          ed.touch()
        end
      end
      if chip("bake .spx", false) and fg then
        local spr = cm.require("cm.spr")
        local specs = bake_rows(win, doc)
        if #specs > 0 then
          local pxs, fv = spr.rasterize_sheet(fg, specs)
          local w, h = spr.DIRS * spr.CW, #specs * spr.CH
          local target = win.spx or ("spr/" .. (M.title(win)) .. ".spx")
          local full = ed.root .. "/" .. target
          pal.mkdir(full:match("^(.*)/[^/]+$"))
          local okw, err = pal.write_file_atomic(
            full, spr.spx_encode(pxs, w, h, #specs, fv))
          p.bakemsg = okw and ("baked " .. target)
                      or ("bake FAILED: " .. tostring(err))
          if okw then
            cm.asset_epoch = (cm.asset_epoch or 0) + 1
            pal.log("[ed] " .. p.bakemsg)
          end
          ed.touch()
        end
      end
      pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px, COL.dim,
        (p.bakemsg or ("-> spr/" .. M.title(win) .. ".spx"))
        .. "  rows x 8 dirs", 0)
    end
  end
end

return M
