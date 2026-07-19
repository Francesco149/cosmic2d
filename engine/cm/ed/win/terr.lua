-- cm.ed.win.terr — the 3d map window (kind `terr`, EDITOR3D.md §4, D137).
--
-- E0 gave the substrate: an orbit camera (cm.ed.orbit — captured
-- world-unit fields on the window) over a pal.x_rt offscreen viewport;
-- focused middle-drag = orbit, shift+middle = pan, wheel = dolly,
-- shift+1 = home, focus-is-the-one-gate (the map window's contract).
--
-- E2 is the terrain half: the window is a full windowkit asset citizen
-- over `.terr` (kit.asset working CTER bytes, journal cap 512, unsaved-
-- persists, Ctrl+S -> atomic save -> recorded cm.terr3.reload — the
-- running game hot-adopts the ground and rewind scrubs across it), with
-- the sculpting tool set:
--
--   view  — camera only (E3 turns this into select/place)
--   hgt   — raise (left drag) / lower (right drag), radial falloff
--           brush; CTRL quantizes to level steps of tile/2 (the WC3
--           cliff-levels grammar)
--   flt   — flatten toward the height under the press
--   smo   — smooth (neighbor average)
--   pnt   — paint the active material's weight (right = erase); the
--           material strip lives in the inspector
--   shd   — hand-painted shade: darken (left) / lighten (right) — the
--           N64 "painted vertex AO" as a first-class brush
--   wtr   — drag the water level (CTRL = 0.25 steps); press turns
--           water on at the ground height under the cursor
--   wlk   — walkability overrides on the GAT grid: left = force
--           block, right = force walk, CTRL+either = clear the
--           override (back to derived); the overlay shows walk state
--           as translucent ground tint, overridden cells brighter
--           with a center dot (never color-only, D130)
--
-- Brush: ctrl+wheel dials radius, [ ] steps strength (key repeat,
-- D135). One gesture (press..release) = one journal entry; Esc cancels
-- the live gesture by re-adopting the committed bytes.
--
-- Rendering: the viewport draws through cm.terr3's REAL emitters
-- (terrain + water) — what this window shows is exactly what the game
-- renders, by construction. The terrain mesh is cached in a named
-- vertex buffer per path and brush strokes patch only the touched tile
-- rows (fixed 144 B/tile stride), so sculpting stays live on big maps.
--
-- RT lifetime: ephemeral per-window (ed.g.t3), re-created on view-rect
-- resize, pruned when the window dies, registered generationally in
-- ed.t3rt so a VM reboot (D052) frees the previous generation (the
-- rc.p3d.texids pattern; `ed.` prefix so pre-merge trace bundles'
-- sim_buffer rule also excludes it — the smoke-kitcheck lesson).

local ob = cm.require("cm.ed.orbit")
local terr3 = cm.require("cm.terr3")
local terr = cm.require("cm.terr")
local kwalk = cm.require("cm.walk")
local mm = cm.require("cm.math")

local M = { kind = "terr" }
M.menu = "3d map"
M.exts = { "terr" }
M.help = "win-terr"
M.DEF_W, M.DEF_H = 460, 340
M.JCAP = 512
M.wants_keys = true

local COL = {
  btn = 0x262238ff, btn_on = 0x4a4370ff,
  text = 0xd8d2f2ff, dim = 0x8a84b0ff, hot = 0xE8E4FFff,
  danger = 0xf07a7aff, guide = 0xE8E4FFcc,
  spawn = 0xf0d070ff,
}

-- ---- E0: the RT registry (reboot leak guard) ----

local IDCAP = 32 -- ed.t3rt: [0] n, then n texids (one per open viewport)

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

local function tstate(ed)
  local t = ed.g.t3
  if not t then t = { rts = {}, gest = {} }; ed.g.t3 = t end
  return t
end

-- ---- the asset citizen ----

local function decode_into(p, bytes)
  local ok, doc = pcall(terr3.decode, bytes)
  if ok then
    p.doc = doc
    p.err = nil
  else
    p.doc = nil
    p.err = tostring(doc)
  end
  p.gen = (p.gen or 0) + 1 -- full mesh + walk overlay rebuild
  p.g = nil
end

local function fresh_bytes(path)
  local name = path:match("([^/]+)%.terr$") or "map"
  return terr3.encode(terr3.fresh(name, 48, 48, 2.0))
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "t3w", field = "terr", jcap = M.JCAP,
  fresh = function(ed, path) return fresh_bytes(path) end,
  adopt = decode_into,
  encode = terr3.encode,
  write = function(ed, path, a, p)
    return terr3.save(p.doc, ed.root .. "/" .. path, p._save_fail)
  end,
  after_save = function(ed, path)
    local full = ed.root .. "/" .. path
    cm.require("cm.repl").submit(
      ('cm.require("cm.terr3").reload(%q)'):format(full))
    return "[ed] saved " .. path .. " (reload queued)"
  end,
}

local plumb, working, open_asset, commit =
  A.plumb, A.working, A.open_asset, A.commit

M.open_win = A.open_win
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

function M.defaults()
  local d = ob.defaults(60, 48, 0, 48)
  d.tool = "view"
  return d
end

function M.title(win)
  if (win.path or "") == "" then return "3d map" end
  return win.path:match("([^/]+)%.terr$") or win.path
end

function M.accepts(win, path) return path:sub(-5) == ".terr" end

function M.rebind(win, ed, path)
  win.path = path
  A.open_asset(ed, path)
  local p = plumb(ed, path)
  if p.doc then -- home the orbit on the new map
    ob.fit(win, p.doc.w * p.doc.tile * 0.5, 0, p.doc.h * p.doc.tile * 0.5,
           math.max(p.doc.w, p.doc.h) * p.doc.tile * 0.55)
  end
end

-- Esc: cancel the live gesture (re-adopt committed bytes), else drop
-- back to the view tool; the shell's cascade unfocuses after that
function M.escape(win, ed)
  local p = win.path ~= "" and ed.g.t3w and ed.g.t3w[win.path]
  if p and p.g then
    if p.g.mutates then decode_into(p, working(ed, win.path).terr) end
    p.g = nil
    ed.touch()
    return true
  end
  if (win.tool or "view") ~= "view" then
    win.tool = "view"
    ed.touch()
    return true
  end
  return false
end

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

-- ctrl+wheel: the brush radius dial (focused, brush tools)
local BRUSH_TOOLS = { hgt = true, flt = true, smo = true, pnt = true,
                      shd = true, wlk = true }

function M.ctrl_wheel(win, ed, notches)
  if ed.doc.focus ~= win.id then return false end
  if not BRUSH_TOOLS[win.tool or "view"] then return false end
  local r = (win.brush_r or 3) * (notches > 0 and 1.25 or 0.8)
  win.brush_r = mm.clamp(r, 0.5, 24)
  ed.touch()
  return true
end

-- a kind claims right presses over content for its secondary actions
function M.takes_right(win, ed)
  if win.path == "" or ed.doc.focus ~= win.id then return false end
  local tool = win.tool or "view"
  return tool == "hgt" or tool == "pnt" or tool == "shd" or tool == "wlk"
end

-- ---- tools ----

local TOOLS = {
  { "view", "view" }, { "hgt", "hgt" }, { "flt", "flt" }, { "smo", "smo" },
  { "pnt", "pnt" }, { "shd", "shd" }, { "wtr", "wtr" }, { "wlk", "wlk" },
}

local function set_tool(win, ed, tool)
  win.tool = tool
  local p = win.path ~= "" and ed.g.t3w and ed.g.t3w[win.path]
  if p and p.g then
    if p.g.mutates then decode_into(p, working(ed, win.path).terr) end
    p.g = nil
  end
  ed.touch()
end

function M.header(win, ctx)
  if win.path == "" then return 0 end
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local i = cm.require("cm.ui").inp
  local x = ctx.hx
  local used = 0
  for n = #TOOLS, 1, -1 do
    local t = TOOLS[n]
    local w = pal.x_ig_text_size(t[2], px, 0) + 12 * z
    x = x - w - 3 * z
    used = used + w + 3 * z
    local hov = ctx.hot and i.wx >= x and i.wx < x + w
                and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
    local on = (win.tool or "view") == t[1]
    pal.x_ig_rect_fill(x, ctx.hy + 3 * z, w, ctx.hh - 6 * z,
                       on and COL.btn_on or COL.btn, 4 * z)
    pal.x_ig_text(x + 6 * z, ctx.hy + (ctx.hh - px) * 0.45, px,
                  (hov or on) and COL.hot or COL.dim, t[2], 0)
    if hov and i.clicked[1] then set_tool(win, ctx.ed, t[1]) end
  end
  return used
end

local function bound_focused(win, ed)
  return win.path ~= "" and ed.doc.focus == win.id
end

M.hotkeys = {
  { key = "v", hint = "view", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "view") end },
  { key = "h", hint = "sculpt", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "hgt") end },
  { key = "f", hint = "flatten", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "flt") end },
  { key = "m", hint = "smooth", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "smo") end },
  { key = "p", hint = "paint", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "pnt") end },
  { key = "s", hint = "shade", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "shd") end },
  { key = "w", hint = "water", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "wtr") end },
  { key = "k", hint = "walk", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "wlk") end },
  { key = "[", hint = "softer", rep = true, when = bound_focused,
    fn = function(win, ed)
      win.brush_s = mm.clamp((win.brush_s or 0.5) - 0.1, 0.1, 1)
      ed.touch()
    end },
  { key = "]", hint = "harder", rep = true, when = bound_focused,
    fn = function(win, ed)
      win.brush_s = mm.clamp((win.brush_s or 0.5) + 0.1, 0.1, 1)
      ed.touch()
    end },
  { key = "shift+1", hint = "home view",
    fn = function(win, ed)
      local p = win.path ~= "" and ed.g.t3w and ed.g.t3w[win.path]
      if p and p.doc then
        ob.fit(win, p.doc.w * p.doc.tile * 0.5, 0,
               p.doc.h * p.doc.tile * 0.5,
               math.max(p.doc.w, p.doc.h) * p.doc.tile * 0.55)
      else
        local d = M.defaults()
        win.oyaw, win.opitch, win.odist = d.oyaw, d.opitch, d.odist
        win.ofx, win.ofy, win.ofz = d.ofx, d.ofy, d.ofz
      end
      ed.touch()
    end },
}

-- ---- the terrain mesh cache (named vb per path; tile-row patching) ----

local function vb_name(path) return "ed.t3vb:" .. path end
local function fx_name(id) return "ed.t3fx:" .. id end

-- a size-following named scratch buffer: sizes round up to the next
-- power of two and the previous allocation frees on growth (named
-- buffers refuse silent size changes; sizes are tracked module-locally
-- and re-discovered from buf_list after a VM reboot)
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

local function mesh_for(ed, p, path)
  local doc = p.doc
  local want = doc.w * doc.h * 144
  local name = vb_name(path)
  if p.meshsize == nil then -- a VM reboot dropped the plumb: re-discover
    for _, b in ipairs(pal.buf_list()) do
      if b.name == name then p.meshsize = b.size break end
    end
  end
  if p.meshgen ~= p.gen or p.meshsize ~= want then
    if p.meshsize and p.meshsize ~= want then pal.buf_free(name) end
    local out = {}
    terr3.emit_terrain(out, doc)
    local bytes = table.concat(out)
    local vb = pal.buf(name, #bytes)
    vb:setstr(0, bytes)
    p.meshgen, p.meshsize = p.gen, want
  end
  return pal.buf(name, want), doc.w * doc.h * 2
end

-- re-emit the tiles covering a touched VERTEX rect and patch the vb rows
local function patch_mesh(ed, p, path, vx0, vz0, vx1, vz1)
  local doc = p.doc
  if p.meshgen ~= p.gen then return end -- full rebuild queued anyway
  local x0 = mm.clamp(vx0 - 1, 0, doc.w - 1)
  local x1 = mm.clamp(vx1, 0, doc.w - 1)
  local z0 = mm.clamp(vz0 - 1, 0, doc.h - 1)
  local z1 = mm.clamp(vz1, 0, doc.h - 1)
  local vb = pal.buf(vb_name(path), doc.w * doc.h * 144)
  for zz = z0, z1 do
    local out = {}
    terr3.emit_terrain(out, doc, { x0 = x0, x1 = x1, z0 = zz, z1 = zz })
    vb:setstr((zz * doc.w + x0) * 144, table.concat(out))
  end
end

-- the walk overlay mesh (blend segment): rebuilt when the doc moves
local function walk_overlay(ed, p, path)
  local doc = p.doc
  if p.wkgen == p.gen and p.wkbytes then return p.wkbytes, p.wktris end
  local grid, gw, gh = terr3.walk_grid(doc)
  local ovr = {}
  for _, o in ipairs(doc.wovr) do ovr[o.cz * gw + o.cx] = true end
  local cell = doc.tile * 0.5
  local out = {}
  local ntris = 0
  local pk = string.pack
  for cz = 0, gh - 1 do
    for cx = 0, gw - 1 do
      local okc = grid:byte(cz * gw + cx + 1) == 1
      local forced = ovr[cz * gw + cx]
      local r, g, b = okc and 60 or 220, okc and 220 or 70, 70
      local a = forced and 150 or 70
      local x0, z0 = cx * cell, cz * cell
      local function V(x, zc)
        return pk("<fffffBBBB", x, terr.sample(doc, x, zc) + 0.06, zc,
                  0, 0, r, g, b, a)
      end
      local A0 = V(x0, z0)
      local B0 = V(x0 + cell, z0)
      local C0 = V(x0 + cell, z0 + cell)
      local D0 = V(x0, z0 + cell)
      out[#out + 1] = A0 .. B0 .. C0 .. A0 .. C0 .. D0
      ntris = ntris + 2
      if forced then -- center dot: state never reads by color alone
        local mx, mz = x0 + cell * 0.5, z0 + cell * 0.5
        local dd = cell * 0.18
        local function W(x, zc)
          return pk("<fffffBBBB", x, terr.sample(doc, x, zc) + 0.09, zc,
                    0, 0, 245, 245, 245, 220)
        end
        out[#out + 1] = W(mx - dd, mz - dd) .. W(mx + dd, mz - dd)
                     .. W(mx + dd, mz + dd)
        out[#out + 1] = W(mx - dd, mz - dd) .. W(mx + dd, mz + dd)
                     .. W(mx - dd, mz + dd)
        ntris = ntris + 2
      end
    end
  end
  p.wkbytes = table.concat(out)
  p.wktris = ntris
  p.wkgen = p.gen
  return p.wkbytes, p.wktris
end

-- ---- brush application ----

local STEP_FRAC = 0.14 -- per-frame brush rate at strength 1

local function verts_in_radius(doc, hx, hz, r)
  local s = doc.tile
  local vx0 = math.max(0, math.floor((hx - r) / s))
  local vx1 = math.min(doc.w, math.ceil((hx + r) / s))
  local vz0 = math.max(0, math.floor((hz - r) / s))
  local vz1 = math.min(doc.h, math.ceil((hz + r) / s))
  return vx0, vz0, vx1, vz1
end

local function falloff(d, r)
  if d >= r then return 0 end
  local t = 1 - d / r
  return t * t * (3 - 2 * t) -- smoothstep
end

-- one frame of a brush gesture at ground hit (hx, hz). Returns the
-- touched vertex rect (or nil).
local function apply_brush(win, p, tool, hx, hz, btn, ctrl)
  local doc = p.doc
  local r = win.brush_r or 3
  local str = win.brush_s or 0.5
  local s = doc.tile
  local vx0, vz0, vx1, vz1 = verts_in_radius(doc, hx, hz, r)
  local lvl = s * 0.5 -- the CTRL level step (EDITOR3D.md §4.2)
  for vz = vz0, vz1 do
    for vx = vx0, vx1 do
      local dx, dz = vx * s - hx, vz * s - hz
      local f = falloff(mm.sqrt(dx * dx + dz * dz), r)
      if f > 0 then
        local vi = vz * (doc.w + 1) + vx + 1
        if tool == "hgt" then
          local dir = btn == 3 and -1 or 1
          local hh = doc.hts[vi] + dir * str * STEP_FRAC * f
          if ctrl then hh = math.floor(hh / lvl + 0.5) * lvl end
          doc.hts[vi] = hh
        elseif tool == "flt" then
          local hh = doc.hts[vi]
          doc.hts[vi] = hh + (p.g.target - hh) * str * 0.22 * f
        elseif tool == "smo" then
          local hh = doc.hts[vi]
          local avg = (terr.hget(doc, vx - 1, vz) + terr.hget(doc, vx + 1, vz)
                     + terr.hget(doc, vx, vz - 1) + terr.hget(doc, vx, vz + 1))
                     * 0.25
          doc.hts[vi] = hh + (avg - hh) * str * 0.35 * f
        elseif tool == "pnt" then
          local mi = win.mat or 1
          if mi >= 1 and mi <= #doc.mats then
            doc.wts[mi] = doc.wts[mi] or {}
            local pl = doc.wts[mi]
            if #pl == 0 then
              for i = 1, terr3.plane_size(doc) do pl[i] = 0 end
            end
            local dir = btn == 3 and -1 or 1
            pl[vi] = mm.clamp((pl[vi] or 0)
                              + dir * math.ceil(30 * str * f), 0, 255)
          end
        elseif tool == "shd" then
          if not doc.shade then
            doc.shade = {}
            for i = 1, terr3.plane_size(doc) do doc.shade[i] = 255 end
          end
          local dir = btn == 3 and 1 or -1
          doc.shade[vi] = mm.clamp(doc.shade[vi]
                                   + dir * math.ceil(14 * str * f), 40, 255)
        end
      end
    end
  end
  return vx0, vz0, vx1, vz1
end

-- walk-override painting: one cell per hit (small cells; dragging
-- covers a path). CTRL clears the override.
local function apply_walk(p, hx, hz, btn, ctrl)
  local doc = p.doc
  local cell = doc.tile * 0.5
  local gw, gh = terr3.walk_dims(doc)
  local cx = math.floor(hx / cell)
  local cz = math.floor(hz / cell)
  if cx < 0 or cz < 0 or cx >= gw or cz >= gh then return end
  for i = #doc.wovr, 1, -1 do
    if doc.wovr[i].cx == cx and doc.wovr[i].cz == cz then
      table.remove(doc.wovr, i)
    end
  end
  if not ctrl then
    doc.wovr[#doc.wovr + 1] = { cx = cx, cz = cz, v = btn == 3 and 1 or 0 }
  end
  -- canonical order: the codec writes list order; sorted = stable bytes
  table.sort(doc.wovr, function(a, b)
    if a.cz ~= b.cz then return a.cz < b.cz end
    return a.cx < b.cx
  end)
end

-- ---- RT lifecycle (E0) ----

local function rt_for(ed, win, w, h)
  local t = tstate(ed)
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
  local t = tstate(ed)
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

-- ---- the E0 empty scene (unbound windows) ----

local function vert(x, y, z, r, g, b)
  return string.pack("<fffffBBBB", x, y, z, 0, 0, r, g, b, 255)
end

local function flatquad(out, x0, z0, x1, z1, y, r, g, b)
  local a = vert(x0, y, z0, r, g, b)
  local bq = vert(x1, y, z0, r, g, b)
  local c = vert(x1, y, z1, r, g, b)
  local d = vert(x0, y, z1, r, g, b)
  out[#out + 1] = a .. bq .. c .. a .. c .. d
end

local SCENE
local function empty_scene()
  if SCENE then return SCENE end
  local out = {}
  local S, TH = 16, 0.02
  for i = -S, S do
    local v = i % 4 == 0 and 96 or 56
    if i == 0 then v = 120 end
    flatquad(out, i - TH, -S, i + TH, S, 0, v, v, v + 8)
    flatquad(out, -S, i - TH, S, i + TH, 0, v, v, v + 8)
  end
  local bytes = table.concat(out)
  SCENE = { bytes = bytes, ntris = #bytes // 72 }
  return SCENE
end

-- ---- draw ----

local function draw_ring(vpm, vw, vh, vx, vy, doc, hx, hz, r)
  local prev
  for k = 0, 24 do
    local a = k / 24 * 2 * mm.pi
    local x = hx + mm.cos(a) * r
    local zc = hz + mm.sin(a) * r
    local y = terr.sample(doc, x, zc) + 0.05
    local sx, sy = ob.project(vpm, vw, vh, x, y, zc)
    if sx and prev then
      pal.x_ig_line(vx + prev[1], vy + prev[2], vx + sx, vy + sy,
                    COL.guide, 1.5)
    end
    prev = sx and { sx, sy } or nil
  end
end

function M.draw(win, ctx)
  local ed = ctx.ed
  prune(ed)
  local i = cm.require("cm.ui").inp
  local g = ed.g
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local vx, vy = ctx.cx, ctx.cy

  -- inspector strip (bottom band)
  local INSP = math.max(12, 22 * z)
  local vw = math.max(1, math.floor(ctx.cw + 0.5))
  local vh = math.max(1, math.floor(ctx.ch - INSP - 2 * z + 0.5))
  if vh < 40 then INSP, vh = 0, math.max(1, math.floor(ctx.ch + 0.5)) end

  local bound = (win.path or "") ~= ""
  local a, p, doc
  if bound then
    a, p = open_asset(ed, win.path)
    if p.err or not p.doc then
      pal.x_ig_text(vx + 8 * z, vy + 8 * z, px, COL.danger,
                    "unreadable .terr: " .. tostring(p.err), 0)
      return
    end
    doc = p.doc
  end

  -- ---- camera gestures (focused only; the one gate) ----
  local t = tstate(ed)
  local over_view = i.wx >= vx and i.wx < vx + vw
                and i.wy >= vy and i.wy < vy + vh
  if ctx.focused and i.clicked[2] then
    t.gest[win.id] = { mx = i.wx, my = i.wy, pan = g.shift or false }
  end
  local ge = t.gest[win.id]
  if ge then
    if i.buttons[2] then
      local dx, dy = i.wx - ge.mx, i.wy - ge.my
      if ge.pan then ob.pan(win, dx, dy, vh)
      else ob.orbit(win, dx, dy) end
      ge.mx, ge.my = i.wx, i.wy
      ctx.touch()
    else
      t.gest[win.id] = nil
    end
  end

  -- ---- the viewport render ----
  local r = rt_for(ed, win, vw, vh)
  local vpm = ob.vp(win, vw / vh)
  local clear = { 0.10, 0.11, 0.14, 1 }
  local fogopts = nil
  if bound and doc.fog.on then
    local fc = doc.fog.col
    clear = { fc[1], fc[2], fc[3], 1 }
    fogopts = doc.fog
  end
  pal.x_view3d{
    mvp = vpm, target = r.tex, clear = clear,
    fog_on = fogopts ~= nil, fog_start = fogopts and fogopts.s or 0,
    fog_end = fogopts and fogopts.e or 1,
    fog = fogopts and fogopts.col or nil,
  }

  local hitx, hitz
  if bound then
    local vb, ntris = mesh_for(ed, p, win.path)
    pal.x_tris(0, vb, ntris, 0)

    -- ground hit under the cursor (for brushes + the ring)
    if over_view then
      local ray = ob.ray(win, vw, vh, i.wx - vx, i.wy - vy)
      hitx, hitz = kwalk.raycast(function(xx, zz)
        return terr.sample(doc, xx, zz)
      end, ray.ox, ray.oy, ray.oz, ray.dx, ray.dy, ray.dz, 0.35, 500, 14)
      -- clamp into the map so brushes at the horizon don't run away
      if hitx then
        local wxs, wzs = terr.size(doc)
        hitx = mm.clamp(hitx, 0, wxs)
        hitz = mm.clamp(hitz, 0, wzs)
      end
    end

    -- ---- tool gestures ----
    local tool = win.tool or "view"
    if ctx.focused and tool ~= "view" and over_view and not g.alt then
      local press = (i.clicked[1] and 1) or (i.clicked[3] and 3)
      if press and hitx and not p.g then
        p.g = { tool = tool, btn = press, mutates = true }
        if tool == "flt" then p.g.target = terr.sample(doc, hitx, hitz) end
        if tool == "wtr" then
          p.g.y0 = doc.water.on and doc.water.y
                   or terr.sample(doc, hitx, hitz)
          p.g.my0 = i.wy
          doc.water.on = true
        end
      end
    end
    if p.g then
      local btn = p.g.btn
      local held = btn == 1 and i.buttons[1] or btn == 3 and i.buttons[3]
      if held then
        local tool = p.g.tool
        if tool == "wtr" then
          local ny = p.g.y0 + (p.g.my0 - i.wy) * 0.04
          if g.ctrl then ny = math.floor(ny / 0.25 + 0.5) * 0.25 end
          doc.water.y = ny
          ctx.touch()
        elseif tool == "wlk" then
          if hitx then
            apply_walk(p, hitx, hitz, btn, g.ctrl)
            -- the overlay rebuild (a full walk_grid derivation — 20ms+
            -- on big maps) waits for gesture END; mid-drag it shows the
            -- pre-stroke state
            ctx.touch()
          end
        elseif hitx then
          local vx0, vz0, vx1, vz1 =
            apply_brush(win, p, tool, hitx, hitz, btn, g.ctrl)
          if vx0 then
            patch_mesh(ed, p, win.path, vx0, vz0, vx1, vz1)
            if tool == "hgt" or tool == "flt" or tool == "smo" then
              p.wkgen = nil -- ground moved: the walk overlay is stale
            end
            ctx.touch()
          end
        end
      else
        -- gesture end: ONE journal entry (unless nothing changed)
        if p.g.tool == "wlk" then p.wkgen = nil end -- overlay rebuild now
        commit(ed, win.path)
        p.g = nil
        ctx.touch()
      end
    end

    -- water through the real emitter (blend segment after opaque)
    if doc.water.on then
      local wout = {}
      local wtris = terr3.emit_water(wout, doc)
      if wtris > 0 then
        pal.x_tris(0, scratch(fx_name(win.id), table.concat(wout)),
                   wtris, 0, 4)
      end
    end

    -- the walk overlay (walk tool only; blend)
    if (win.tool or "view") == "wlk" then
      local bytes, wktris = walk_overlay(ed, p, win.path)
      if wktris > 0 then
        pal.x_tris(0, scratch(fx_name(win.id) .. ":wk", bytes), wktris, 0, 4)
      end
    end
  else
    local sc = empty_scene()
    local vb = pal.buf("ed.t3vb", #sc.bytes)
    vb:setstr(0, sc.bytes)
    pal.x_tris(0, vb, sc.ntris, 0)
  end

  pal.x_ig_image(r.tex, vx, vy, vw, vh)

  -- ---- 2D overlays (projected gizmos) ----
  if bound then
    -- brush ring
    local tool = win.tool or "view"
    if BRUSH_TOOLS[tool] and hitx then
      draw_ring(vpm, vw, vh, vx, vy, doc, hitx, hitz,
                tool == "wlk" and doc.tile * 0.25 or (win.brush_r or 3))
    end
    -- spawn gizmo: a small diamond + label
    local sx, sy = ob.project(vpm, vw, vh, doc.spawn.x,
                              terr.sample(doc, doc.spawn.x, doc.spawn.z)
                              + 0.4, doc.spawn.z)
    if sx then
      local d = 4 * z
      pal.x_ig_line(vx + sx - d, vy + sy, vx + sx, vy + sy - d, COL.spawn, 1.5)
      pal.x_ig_line(vx + sx, vy + sy - d, vx + sx + d, vy + sy, COL.spawn, 1.5)
      pal.x_ig_line(vx + sx + d, vy + sy, vx + sx, vy + sy + d, COL.spawn, 1.5)
      pal.x_ig_line(vx + sx, vy + sy + d, vx + sx - d, vy + sy, COL.spawn, 1.5)
      pal.x_ig_text(vx + sx + 6 * z, vy + sy - px * 0.5, px * 0.9,
                    COL.spawn, "spawn", 0)
    end
  end

  -- unbound: the kit's new-file door over the empty scene
  if not bound then
    A.pathfield(win, ed, ctx, {
      ext = "terr", default = "maps/",
      label = "no 3d map bound — drag a .terr here, or type a path:",
    })
    return
  end

  -- ---- the inspector strip ----
  if INSP > 0 then
    local sy0 = vy + vh + 2 * z
    local tool = win.tool or "view"
    local function label(txt, col)
      pal.x_ig_text(vx + 6 * z, sy0 + (INSP - px) * 0.45, px,
                    col or COL.dim, txt, 0)
    end
    if tool == "pnt" then
      -- the material strip: swatches + add
      local sx = vx + 6 * z
      for mi = 1, #doc.mats do
        local sw = 14 * z
        local on = (win.mat or 1) == mi
        pal.x_ig_rect_fill(sx, sy0 + 2 * z, sw, INSP - 4 * z,
          (math.floor(doc.mats[mi].col[1] * 255) << 24)
          | (math.floor(doc.mats[mi].col[2] * 255) << 16)
          | (math.floor(doc.mats[mi].col[3] * 255) << 8) | 0xff, 2 * z)
        if on then
          pal.x_ig_rect(sx - 1, sy0 + 2 * z - 1, sw + 2, INSP - 4 * z + 2,
                        COL.hot, 1.5, 2 * z)
        end
        local hov = i.wx >= sx and i.wx < sx + sw
                    and i.wy >= sy0 and i.wy < sy0 + INSP
        if hov and i.clicked[1] then
          win.mat = mi
          ed.touch()
        end
        sx = sx + sw + 3 * z
      end
      if #doc.mats < terr3.MAX_MATS then
        local bw = pal.x_ig_text_size("+", px, 0) + 8 * z
        local hov = i.wx >= sx and i.wx < sx + bw
                    and i.wy >= sy0 and i.wy < sy0 + INSP
        pal.x_ig_rect_fill(sx, sy0 + 2 * z, bw, INSP - 4 * z,
                           hov and COL.btn_on or COL.btn, 2 * z)
        pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px,
                      hov and COL.hot or COL.dim, "+", 0)
        if hov and i.clicked[1] then
          local n = #doc.mats + 1
          local hsh = terr.hash(77, n, 3)
          doc.mats[n] = { name = "mat" .. n,
                          col = { 0.3 + 0.5 * terr.hash(77, n, 1),
                                  0.3 + 0.5 * terr.hash(77, n, 2),
                                  0.3 + 0.5 * hsh }, tex = "" }
          win.mat = n
          commit(ed, win.path)
          p.gen = p.gen + 1 -- colors may shift (weights renormalize)
          ed.touch()
        end
        sx = sx + bw + 6 * z
      end
      pal.x_ig_text(sx, sy0 + (INSP - px) * 0.45, px, COL.dim,
        ("%s  r=%.1f (ctrl+wheel)  s=%.1f ([ ])  right = erase")
          :format(doc.mats[win.mat or 1]
                  and doc.mats[win.mat or 1].name or "?",
                  win.brush_r or 3, win.brush_s or 0.5), 0)
    elseif tool == "wtr" then
      label(("water %s  y=%.2f  drag up/down (ctrl = 0.25 steps)")
            :format(doc.water.on and "on" or "off", doc.water.y))
    elseif tool == "wlk" then
      label(("walk: L block - R walk - ctrl clears  (derived slope<=%.2f"
             .. " wade<=%.2f)"):format(doc.walk.slope, doc.walk.wade))
    elseif BRUSH_TOOLS[tool] then
      label(("r=%.1f (ctrl+wheel)  s=%.1f ([ ])%s")
            :format(win.brush_r or 3, win.brush_s or 0.5,
                    tool == "hgt" and "  ctrl = level steps" or ""))
    else
      label(("%s  %dx%d tile %.1f  props %d  markers %d")
            :format(doc.name ~= "" and doc.name or win.path,
                    doc.w, doc.h, doc.tile, #doc.props, #doc.markers))
    end
  end
end

return M
