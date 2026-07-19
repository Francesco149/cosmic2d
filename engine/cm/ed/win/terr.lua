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
-- the live gesture by re-adopting the committed bytes. The inspector's
-- brush-shape WELL shows the live brush (radial dot or stamp image)
-- and is the stamp drop target: drag an image onto it and it becomes
-- the brush shape (alpha x luminance mask, aspect-fit to the brush
-- square — terr3.stamp_at); the stamp chip clears back to radial.
-- With pnt active, an image dropped on the VIEWPORT adds a new
-- material of that image, and one dropped on a SWATCH retextures that
-- material — textures render LIVE (the budgeted atlas bake below) and
-- Ctrl+S publishes <map>-atlas.png beside the map (save = bake).
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

-- ---- the asset citizen ----

local TS = 16 -- atlas texels per tile (the §4.5 bake density)

-- any material carrying a texture?
local function textured(doc)
  for _, mt in ipairs(doc.mats) do
    if (mt.tex or "") ~= "" then return true end
  end
  return false
end

-- drop the live atlas (CPU buf + GPU texture) — any edit that changes
-- material colors/textures, and every byte re-adopt, goes through here
local function lat_free(p)
  if p.lat then
    if p.lat.tex then pal.tex_free(p.lat.tex) end
    p.lat = nil
  end
end

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
  lat_free(p) -- materials may have moved: the live atlas re-bakes
end

local function fresh_bytes(path)
  local name = path:match("([^/]+)%.terr$") or "map"
  return terr3.encode(terr3.fresh(name, 48, 48, 2.0))
end

-- declared above its uses in the asset spec; defined with the other
-- atlas plumbing below (it needs mat_samplers)
local lat_complete

local A = cm.require("cm.ed.kit").asset {
  gkey = "t3w", field = "terr", jcap = M.JCAP,
  fresh = function(ed, path) return fresh_bytes(path) end,
  adopt = decode_into,
  encode = function(doc)
    -- the stamp rides EVERY encode: with textured materials the bytes
    -- always carry the current paint hash (save = bake, below — there
    -- is no stale-atlas state for the user to manage any more);
    -- untextured maps encode 0 and the game stays in vertex mode
    doc.stamp = textured(doc) and terr3.mat_hash(doc) or 0
    return terr3.encode(doc)
  end,
  write = function(ed, path, a, p)
    local ok, err = terr3.save(p.doc, ed.root .. "/" .. path, p._save_fail)
    if not ok then return ok, err end
    -- save = bake: the atlas png publishes beside the map whenever a
    -- material is textured (finishing the budgeted live bake
    -- synchronously if it is mid-flight), so the game's freshness
    -- contract (HEAD stamp == mat_hash => draw the atlas) holds by
    -- construction after every save
    if p.doc and textured(p.doc) then
      local lat = lat_complete(ed, p, path)
      local okw, werr = pal.write_file_atomic(
        ed.root .. "/" .. terr3.atlas_path(path),
        pal.png_encode(lat.buf:str(0, lat.w * lat.h * 4), lat.w, lat.h))
      if not okw then
        pal.log("[ed] atlas png write FAILED (the saved map will fall "
                .. "back to flat colors): " .. tostring(werr))
      end
    end
    return ok
  end,
  after_save = function(ed, path, a, p)
    local full = ed.root .. "/" .. path
    cm.require("cm.repl").submit(
      ('cm.require("cm.terr3").reload(%q)'):format(full))
    if p and p.lat then
      -- consumers re-read the published atlas png; the live buffer was
      -- just baked from current sources, so it adopts the new epoch
      -- instead of re-baking
      cm.asset_epoch = (cm.asset_epoch or 0) + 1
      p.lat.epoch = cm.asset_epoch
    end
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
  d.tool = "sel"
  return d
end

-- The shell drops per-asset plumbing on every rewind seek; the live
-- atlas's raw texture id must be released first (the sprite window's
-- pattern — pal.tex_free is deferred and safe mid-frame).
function M.drop_ephemeral(ed)
  for _, p in pairs(ed.g.t3w or {}) do lat_free(p) end
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

-- Esc: cancel the live gesture (re-adopt committed bytes), else clear
-- the selection, else drop back to the select tool; the shell's cascade
-- unfocuses after that
function M.escape(win, ed)
  local p = win.path ~= "" and ed.g.t3w and ed.g.t3w[win.path]
  if p and p.g then
    if p.g.mutates then decode_into(p, working(ed, win.path).terr) end
    p.g = nil
    ed.touch()
    return true
  end
  if p and p.sel then
    p.sel = nil
    ed.touch()
    return true
  end
  if (win.tool or "sel") ~= "sel" then
    win.tool = "sel"
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
  { "sel", "sel" }, { "hgt", "hgt" }, { "flt", "flt" }, { "smo", "smo" },
  { "pnt", "pnt" }, { "shd", "shd" }, { "wtr", "wtr" }, { "wlk", "wlk" },
  { "mkr", "mkr" },
}

local MKINDS = { "spawn", "poi", "npc", "portal", "route" }

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

local function selection(win, ed)
  local p = win.path ~= "" and ed.g.t3w and ed.g.t3w[win.path]
  return p, p and p.sel
end

local function has_sel(win, ed)
  local _, sel = selection(win, ed)
  return bound_focused(win, ed) and sel ~= nil
end

-- a selection edit closure: fn(doc, item) mutates; commits one entry
local function sel_edit(fn)
  return function(win, ed)
    local p, sel = selection(win, ed)
    if not (p and sel and p.doc) then return end
    local it = sel.t == "prop" and p.doc.props[sel.i]
               or p.doc.markers[sel.i]
    if not it then return end
    fn(p.doc, it, sel, p)
    commit(ed, win.path)
    ed.touch()
  end
end

M.hotkeys = {
  { key = "v", hint = "select", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "sel") end },
  { key = "n", hint = "marker", when = bound_focused,
    fn = function(win, ed) set_tool(win, ed, "mkr") end },
  { key = "del", hint = "delete", when = has_sel,
    fn = function(win, ed)
      local p, sel = selection(win, ed)
      if sel.t == "prop" then table.remove(p.doc.props, sel.i)
      else table.remove(p.doc.markers, sel.i) end
      p.sel = nil
      commit(ed, win.path)
      ed.touch()
    end },
  { key = "ctrl+d", hint = "duplicate", when = has_sel,
    fn = function(win, ed)
      local p, sel = selection(win, ed)
      local list = sel.t == "prop" and p.doc.props or p.doc.markers
      local src = list[sel.i]
      if not src then return end
      local copy = cm.require("cm.state").value_copy
                   and cm.require("cm.state").value_copy(src) or nil
      if not copy then -- plain deep copy (props/markers are plain data)
        local function dc(t)
          if type(t) ~= "table" then return t end
          local o = {}
          for k, v in pairs(t) do o[k] = dc(v) end
          return o
        end
        copy = dc(src)
      end
      copy.name = nil -- names address uniquely (the map paste rule)
      copy.x = copy.x + (p.doc.tile or 2) * 0.5
      list[#list + 1] = copy
      p.sel = { t = sel.t, i = #list }
      commit(ed, win.path)
      ed.touch()
    end },
  { key = "left", rep = true, when = has_sel,
    fn = sel_edit(function(doc, it) it.x = it.x - doc.tile / 8 end) },
  { key = "right", rep = true, when = has_sel,
    fn = sel_edit(function(doc, it) it.x = it.x + doc.tile / 8 end) },
  { key = "up", rep = true, when = has_sel,
    fn = sel_edit(function(doc, it) it.z = it.z - doc.tile / 8 end) },
  { key = "down", rep = true, when = has_sel,
    fn = sel_edit(function(doc, it) it.z = it.z + doc.tile / 8 end) },
  { key = ",", hint = "yaw-", rep = true, when = has_sel,
    fn = sel_edit(function(doc, it)
      if it.yaw ~= nil then it.yaw = it.yaw - mm.pi / 12 end
    end) },
  { key = ".", hint = "yaw+", rep = true, when = has_sel,
    fn = sel_edit(function(doc, it)
      if it.yaw ~= nil then it.yaw = it.yaw + mm.pi / 12 end
    end) },
  { key = "minus", hint = "smaller", rep = true, when = has_sel,
    fn = sel_edit(function(doc, it, sel)
      if sel.t == "prop" then
        it.scale = math.max(0.25, (it.scale or 1) * 0.9)
      else
        it.r = math.max(0.25, (it.r or 0.5) * 0.9)
      end
    end) },
  { key = "equals", hint = "bigger", rep = true, when = has_sel,
    fn = sel_edit(function(doc, it, sel)
      if sel.t == "prop" then
        it.scale = math.min(40, (it.scale or 1) / 0.9)
      else
        it.r = math.min(40, (it.r or 0.5) / 0.9)
      end
    end) },
  { key = "enter", hint = "end route",
    when = function(win, ed)
      local p = selection(win, ed)
      return bound_focused(win, ed) and p and p.g and p.g.route ~= nil
    end,
    fn = function(win, ed)
      local p = selection(win, ed)
      M.finish_route(win, ed, p)
    end },
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

-- atexid: the fresh atlas texture id (from atlas_tex below) or nil for
-- vertex mode — the vb re-emits whenever the MODE flips, and
-- patch_mesh patches in the same mode (p.meshatlas)
local function mesh_for(ed, p, path, atexid)
  local doc = p.doc
  local want = doc.w * doc.h * 144
  local name = vb_name(path)
  local mode = atexid ~= nil
  if p.meshsize == nil then -- a VM reboot dropped the plumb: re-discover
    for _, b in ipairs(pal.buf_list()) do
      if b.name == name then p.meshsize = b.size break end
    end
  end
  if p.meshgen ~= p.gen or p.meshsize ~= want or p.meshatlas ~= mode then
    if p.meshsize and p.meshsize ~= want then pal.buf_free(name) end
    local out = {}
    terr3.emit_terrain(out, doc, { atlas = mode })
    local bytes = table.concat(out)
    local vb = pal.buf(name, #bytes)
    vb:setstr(0, bytes)
    p.meshgen, p.meshsize, p.meshatlas = p.gen, want, mode
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
    terr3.emit_terrain(out, doc, { x0 = x0, x1 = x1, z0 = zz, z1 = zz,
                                   atlas = p.meshatlas })
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

-- image pixel + stamp caches (render/dev, module-local; keyed on
-- cm.asset_epoch so a re-saved sprite refreshes immediately; failures
-- remembered so a broken image costs one read, not one per frame)
local TEXPIX, STAMPS, PIX_EPOCH = {}, {}, -1
local function texpix_for(ed, path)
  local epoch = cm.asset_epoch or 0
  if PIX_EPOCH ~= epoch then TEXPIX, STAMPS, PIX_EPOCH = {}, {}, epoch end
  local l = path:lower()
  local target = l:find("%.png$") and path
                 or (l:find("%.spr$") and path:gsub("%.spr$", ".png"))
  if not target then return nil end
  local rp = cm.require("cm.ed.win.map").res_path(ed, target)
  if not rp then return nil end
  local got = TEXPIX[rp]
  if got == nil then
    got = false
    local bytes = pal.read_file(rp)
    if bytes then
      local pix, w, h = pal.png_read(bytes)
      if pix then got = { pix = pix, w = w, h = h } end
    end
    TEXPIX[rp] = got
  end
  return got or nil
end

-- resolve an image path (a png, or a .spr's baked png sibling) to the
-- editor's cached texture record {id,w,h} — cm.gfx.texture is epoch-
-- keyed, so a re-saved sprite refreshes every holder (billboards, the
-- brush well thumb, the selection bracket)
local function image_tex(ed, path)
  local l = path:lower()
  local target = l:find("%.png$") and path
                 or (l:find("%.spr$") and path:gsub("%.spr$", ".png"))
  if not target then return nil end
  local rp = cm.require("cm.ed.win.map").res_path(ed, target)
  if not rp then return nil end
  local ok, t = pcall(cm.require("cm.gfx").texture, rp)
  if ok then return t end
end

-- a dropped image becomes the brush shape (terr3.stamp_mask)
local function stamp_for(ed, win)
  local path = win.stamp
  if not path then return nil end
  local rec = texpix_for(ed, path)
  if not rec then return nil end
  local got = STAMPS[path]
  if not got then
    got = terr3.stamp_mask(rec.pix, rec.w, rec.h)
    STAMPS[path] = got
  end
  return got
end

-- samplers for the atlas bake: mi -> tile-repeat nearest sampler for
-- every textured material (draw the texture in the sprite editor)
local function mat_samplers(ed, doc)
  local out = {}
  for mi, mt in ipairs(doc.mats) do
    if mt.tex and mt.tex ~= "" then
      local rec = texpix_for(ed, mt.tex)
      if rec then
        local pix, w, h = rec.pix, rec.w, rec.h
        out[mi] = function(u, v)
          local x = math.floor(u * w) % w
          local y = math.floor(v * h) % h
          local o = (y * w + x) * 4
          local r, g, b = pix:byte(o + 1, o + 3)
          return r / 255, g / 255, b / 255
        end
      end
    end
  end
  return out
end

-- ---- the LIVE atlas (§4.5 v2: textures take effect as you paint) ----
--
-- With any textured material the window maintains a CPU atlas in an
-- anon buf, baked a few ROWS PER FRAME (the budgeted loop — a 48x48
-- map is ~0.4s of pure-Lua bake, far too much for one frame), then
-- serves it as a texture; paint/shade strokes re-bake only the touched
-- texel rect (stroke_patch below). While the initial bake runs the
-- mesh stays in vertex mode (p.at_note carries the progress for the
-- inspector). A fresh saved atlas png seeds the buffer whole, so
-- reopening a saved map pays nothing.

-- make (or resume) the live atlas buffer for a doc; nil if untextured
local function lat_for(ed, p, path)
  local doc = p.doc
  if not textured(doc) then
    lat_free(p)
    return nil
  end
  local W, H = doc.w * TS, doc.h * TS
  local epoch = cm.asset_epoch or 0
  local lat = p.lat
  if lat and (lat.w ~= W or lat.h ~= H or lat.epoch ~= epoch) then
    lat_free(p) -- resized map or re-saved source image: full re-bake
    lat = nil
  end
  if not lat then
    lat = { w = W, h = H, buf = pal.buf(nil, W * H * 4), row = 0,
            epoch = epoch }
    p.lat = lat
    if (doc.stamp or 0) ~= 0 and doc.stamp == terr3.mat_hash(doc) then
      local rp = cm.require("cm.ed.win.map").res_path(
        ed, terr3.atlas_path(path))
      local bytes = rp and pal.read_file(rp)
      if bytes then
        local pix, pw, ph = pal.png_read(bytes)
        if pix and pw == W and ph == H then
          lat.buf:setstr(0, pix)
          lat.row = H -- the disk bake is fresh: skip the loop
        end
      end
    end
  end
  return lat
end

-- finish any remaining rows NOW (the save door) and return the lat
lat_complete = function(ed, p, path)
  local lat = lat_for(ed, p, path)
  if lat and lat.row < lat.h then
    terr3.bake_into(p.doc, mat_samplers(ed, p.doc), TS, lat.buf,
                    0, lat.row, lat.w - 1, lat.h - 1)
    lat.row = lat.h
    lat.dirty = true
  end
  return lat
end

-- one frame of the live atlas: advance the budget, serve the texture
-- when complete (nil = draw vertex colors this frame)
local function live_atlas(ed, p, path)
  local lat = lat_for(ed, p, path)
  if not lat then
    p.at_note = nil
    return nil
  end
  if lat.row < lat.h then
    -- ~6k texels a frame ≈ 3-4ms of bake; clamped so huge maps still
    -- make visible progress and small maps finish in one go
    local rows = mm.clamp(6144 // lat.w, 1, 64)
    local r1 = math.min(lat.h, lat.row + rows)
    terr3.bake_into(p.doc, mat_samplers(ed, p.doc), TS, lat.buf,
                    0, lat.row, lat.w - 1, r1 - 1)
    lat.row = r1
    lat.dirty = true
    ed.touch() -- keep the loop ticking
    if lat.row < lat.h then
      p.at_note = ("tex bake %d%%"):format(lat.row * 100 // lat.h)
      return nil
    end
  end
  p.at_note = nil
  if not lat.tex then
    lat.tex = pal.tex_create(lat.w, lat.h, lat.buf:str(0, lat.w * lat.h * 4))
    lat.dirty = nil
  elseif lat.dirty then
    pal.tex_update(lat.tex, lat.buf, lat.w, lat.h)
    lat.dirty = nil
  end
  return lat.tex
end

-- a paint/shade stroke touched the vertex rect: re-bake just those
-- texels so the texture follows the brush live
local function stroke_patch(ed, p, vx0, vz0, vx1, vz1)
  local lat = p.lat
  if not lat then return end
  local doc = p.doc
  local x0 = mm.clamp(vx0 - 1, 0, doc.w - 1)
  local x1 = mm.clamp(vx1, 0, doc.w - 1)
  local z0 = mm.clamp(vz0 - 1, 0, doc.h - 1)
  local z1 = mm.clamp(vz1, 0, doc.h - 1)
  -- rows the loop has not reached yet get baked when it arrives
  local py1 = math.min((z1 + 1) * TS - 1, lat.row - 1)
  local py0 = z0 * TS
  if py1 < py0 then return end
  terr3.bake_into(doc, mat_samplers(ed, doc), TS, lat.buf,
                  x0 * TS, py0, (x1 + 1) * TS - 1, py1)
  lat.dirty = true
end

-- one frame of a brush gesture at ground hit (hx, hz). Returns the
-- touched vertex rect (or nil). `mask` (a terr3 stamp) replaces the
-- radial falloff with the dropped image's shape.
local function apply_brush(win, p, tool, hx, hz, btn, ctrl, mask)
  local doc = p.doc
  local r = win.brush_r or 3
  local str = win.brush_s or 0.5
  local s = doc.tile
  local vx0, vz0, vx1, vz1 = verts_in_radius(doc, hx, hz, r)
  local lvl = s * 0.5 -- the CTRL level step (EDITOR3D.md §4.2)
  for vz = vz0, vz1 do
    for vx = vx0, vx1 do
      local dx, dz = vx * s - hx, vz * s - hz
      local f = mask and terr3.stamp_at(mask, dx, dz, r)
                or falloff(mm.sqrt(dx * dx + dz * dz), r)
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

-- finish a route polyline gesture into a route marker (Enter / the
-- double-click twin); a route needs at least 2 points
function M.finish_route(win, ed, p)
  local g = p and p.g
  if not (g and g.route) then return end
  if #g.route >= 4 then
    p.doc.markers[#p.doc.markers + 1] = {
      kind = "route", x = g.route[1], z = g.route[2],
      points = g.route,
    }
    p.sel = { t = "marker", i = #p.doc.markers }
    p.g = nil
    commit(ed, win.path)
  else
    p.g = nil
  end
  ed.touch()
end

-- the pnt-mode viewport drop: a NEW material made OF the dropped image
-- — named after the file, flat color = the image's (alpha-weighted)
-- average so the vertex-mode fallback and distant blends read like the
-- sprite. The swatch strip stays the re-texture door for existing ones.
local function add_material(win, ed, p, path)
  local doc = p.doc
  if #doc.mats >= terr3.MAX_MATS then
    pal.log(("[ed] materials full (%d) — drop onto a swatch to "
             .. "retexture one"):format(terr3.MAX_MATS))
    return true
  end
  local cr, cg, cb = 0.6, 0.6, 0.6
  local rec = texpix_for(ed, path)
  if rec then
    local step = math.max(1, math.floor(mm.sqrt(rec.w * rec.h / 4096)))
    local sr, sg, sb, sa = 0, 0, 0, 0
    for y = 0, rec.h - 1, step do
      for x = 0, rec.w - 1, step do
        local o = (y * rec.w + x) * 4
        local r8, g8, b8, a8 = rec.pix:byte(o + 1, o + 4)
        local wa = a8 / 255
        sr, sg, sb, sa = sr + r8 * wa, sg + g8 * wa, sb + b8 * wa, sa + wa
      end
    end
    if sa > 0 then
      cr, cg, cb = sr / sa / 255, sg / sa / 255, sb / sa / 255
    end
  end
  doc.mats[#doc.mats + 1] = {
    name = path:match("([^/]+)%.%w+$") or path,
    col = { cr, cg, cb }, tex = path,
  }
  win.mat = #doc.mats
  lat_free(p)
  p.gen = p.gen + 1
  commit(ed, win.path)
  ed.touch()
  return true
end

-- the drag-in door (kind.drop): any non-.terr asset dropped over the
-- viewport PLACES at the ground under the cursor — 2D images default to
-- billboards (EDITOR3D.md §4.4), meshes/figures to themselves with an
-- auto collider, anything else to a named ref position. Image drops
-- have two more targets, both visible rects: a material SWATCH assigns
-- the texture, the brush-shape WELL adopts it as the stamp, and with
-- the pnt tool a viewport drop ADDS a material of that image (the
-- "paint with this sprite" gesture, one drag).
function M.drop(win, ed, path, sx, sy)
  -- sx/sy are SCREEN px (the shell passes i.wx/i.wy — the map window's
  -- convention; treating them as world coords sent every live drop off
  -- the viewport test and the whole door silently no-oped)
  if win.path == "" or path:sub(-5) == ".terr" then return false end
  local p = plumb(ed, win.path)
  if not p.doc then return false end
  local u = cm.require("cm.ed.kit").winui(p, win)
  local r = u.vrect
  if not r then return false end
  if terr3.is_image(path) then
    -- the brush-shape well (inspector strip): dropping an image ON it
    -- overrides the brush shape — the stamp door (the chip's x resets)
    local r3 = u.stamprect
    if r3 and sx >= r3.x and sx < r3.x + r3.w
       and sy >= r3.y and sy < r3.y + r3.h then
      win.stamp = path
      ed.touch()
      return true
    end
    -- a drop on a MATERIAL SWATCH (the pnt strip — BELOW the viewport,
    -- so this must precede the vrect test) assigns the image as that
    -- material's texture — the ground samples it once per tile
    for _, r2 in ipairs(u.matrects or {}) do
      if sx >= r2.x and sx < r2.x + r2.w
         and sy >= r2.y and sy < r2.y + r2.h then
        p.doc.mats[r2.mi].tex = path
        win.mat = r2.mi
        lat_free(p)
        p.gen = p.gen + 1
        commit(ed, win.path)
        ed.touch()
        return true
      end
    end
  end
  if sx < r.vx or sx >= r.vx + r.vw or sy < r.vy or sy >= r.vy + r.vh then
    return false
  end
  if terr3.is_image(path) and (win.tool or "view") == "pnt" then
    return add_material(win, ed, p, path)
  end
  local ray = ob.ray(win, r.vw, r.vh, sx - r.vx, sy - r.vy)
  local doc = p.doc
  local hx, hz = kwalk.raycast(function(xx, zz)
    return terr.sample(doc, xx, zz)
  end, ray.ox, ray.oy, ray.oz, ray.dx, ray.dy, ray.dz, 0.35, 500, 14)
  if not hx then return false end
  local wxs, wzs = terr.size(doc)
  hx = mm.clamp(hx, 0, wxs)
  hz = mm.clamp(hz, 0, wzs)
  local isimg = terr3.is_image(path)
  local ismsh = path:lower():find("%.msh$") ~= nil
  local isfig = path:lower():find("%.fig$") ~= nil
  doc.props[#doc.props + 1] = {
    path = path, x = hx, z = hz, y = 0, yaw = 0,
    scale = isimg and 2.0 or 1.0,
    col = (ismsh or isfig) and { mode = "auto" } or nil,
  }
  p.sel = { t = "prop", i = #doc.props }
  win.tool = "sel"
  commit(ed, win.path)
  return true
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
  ob.rt_prune(ed)
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
  local over_view = i.wx >= vx and i.wx < vx + vw
                and i.wy >= vy and i.wy < vy + vh
  ob.gestures(win, ed, ctx, i, vh)

  -- ---- the viewport render ----
  local r = ob.rt_for(ed, win, vw, vh)
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

  local hitx, hitz, ray
  if bound then
    local u = cm.require("cm.ed.kit").winui(p, win)
    u.vrect = { vx = vx, vy = vy, vw = vw, vh = vh }
    local atexid = live_atlas(ed, p, win.path)
    local vb, ntris = mesh_for(ed, p, win.path, atexid)
    pal.x_tris(atexid or 0, vb, ntris, 0, atexid and 2 or 0)

    -- image resolvers for placed billboards (the map window's rule:
    -- .spr draws its baked .png sibling)
    local mapwin = cm.require("cm.ed.win.map")
    local function texfn(path)
      local t = image_tex(ed, path)
      return t and t.id
    end
    local function dimsfn(path)
      local t = image_tex(ed, path)
      if t then return t.w, t.h end
    end
    -- .msh resolver: decoded disk doc + baked groups, cached by
    -- cm.asset_epoch (the tm_doc pattern — a mesh-window save shows on
    -- the next frame)
    local cmmesh = cm.require("cm.mesh")
    local function mshfn(path)
      p.msh = p.msh or {}
      local ep = cm.asset_epoch or 0
      if p.msh_ep ~= ep then p.msh, p.msh_ep = {}, ep end
      local rec = p.msh[path]
      if rec == nil then
        rec = false
        local rp = mapwin.res_path(ed, path)
        local bytes = rp and pal.read_file(rp)
        if bytes then
          local ok, md = pcall(cmmesh.decode, bytes)
          if ok then rec = { doc = md, groups = cmmesh.bake_groups(md) } end
        end
        p.msh[path] = rec
      end
      return rec or nil
    end

    -- placements through the real emitter (billboards Y-face the orbit)
    local segs = terr3.emit_props(doc, {
      cam_yaw = win.oyaw, tex = texfn, dims = dimsfn, mesh = mshfn })
    for si, s in ipairs(segs) do
      pal.x_tris(s.tex, scratch(fx_name(win.id) .. ":p" .. si, s.bytes),
                 s.ntris, 0, s.flags)
    end

    -- ground hit under the cursor (for brushes, picking + the ring)
    if over_view then
      ray = ob.ray(win, vw, vh, i.wx - vx, i.wy - vy)
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

    -- markers pick in screen space (their tags overlay everything)
    local vpm_pick = ob.vp(win, vw / vh)
    local function pick_marker()
      local best, bestd
      for mi, mk in ipairs(doc.markers) do
        local sx, sy = ob.project(vpm_pick, vw, vh, mk.x,
                                  terr.sample(doc, mk.x, mk.z) + 0.3, mk.z)
        if sx then
          local d = math.abs(vx + sx - i.wx) + math.abs(vy + sy - i.wy)
          if d < 16 * z and (not bestd or d < bestd) then
            best, bestd = mi, d
          end
        end
      end
      return best
    end
    -- a selected route's point handles pick the same way
    local function pick_route_pt()
      local sel = p.sel
      if not (sel and sel.t == "marker") then return nil end
      local mk = doc.markers[sel.i]
      if not (mk and mk.points) then return nil end
      for k = 1, #mk.points, 2 do
        local pxw, pzw = mk.points[k], mk.points[k + 1]
        local sx, sy = ob.project(vpm_pick, vw, vh, pxw,
                                  terr.sample(doc, pxw, pzw) + 0.15, pzw)
        if sx and math.abs(vx + sx - i.wx) + math.abs(vy + sy - i.wy)
           < 12 * z then
          return k
        end
      end
      return nil
    end

    -- ---- tool gestures ----
    local tool = win.tool or "sel"
    if ctx.focused and over_view and not g.alt and not p.g then
      local press = (i.clicked[1] and 1) or (i.clicked[3] and 3)
      if tool == "sel" and press == 1 then
        local rpt = pick_route_pt()
        local mi = not rpt and pick_marker() or nil
        local pi = (not rpt and not mi and hitx and ray)
                   and terr3.pick_prop(doc, ray, dimsfn) or nil
        if rpt then
          p.g = { tool = "sel", btn = 1, mode = "routept", k = rpt,
                  mutates = true }
        elseif mi then
          p.sel = { t = "marker", i = mi }
          local mk = doc.markers[mi]
          p.g = { tool = "sel", btn = 1, mode = "move", mutates = true,
                  gdx = mk.x - (hitx or mk.x), gdz = mk.z - (hitz or mk.z) }
          ed.touch()
        elseif pi then
          p.sel = { t = "prop", i = pi }
          local pr = doc.props[pi]
          p.g = { tool = "sel", btn = 1, mode = "move", mutates = true,
                  gdx = pr.x - (hitx or pr.x), gdz = pr.z - (hitz or pr.z) }
          ed.touch()
        else
          if p.sel then
            p.sel = nil
            ed.touch()
          end
        end
      elseif tool == "mkr" and press == 1 and hitx then
        local kind = win.mkind or "spawn"
        if kind == "route" then
          p.g = { tool = "mkr", route = { hitx, hitz }, mutates = false }
          ed.touch()
        else
          doc.markers[#doc.markers + 1] = { kind = kind, x = hitx, z = hitz,
                                            r = 0.5 }
          p.sel = { t = "marker", i = #doc.markers }
          commit(ed, win.path)
          ed.touch()
        end
      elseif BRUSH_TOOLS[tool] or tool == "wtr" then
        if press and hitx then
          p.g = { tool = tool, btn = press, mutates = true }
          if tool == "flt" then
            p.g.target = terr.sample(doc, hitx, hitz)
          end
          if tool == "wtr" then
            p.g.y0 = doc.water.on and doc.water.y
                     or terr.sample(doc, hitx, hitz)
            p.g.my0 = i.wy
            doc.water.on = true
          end
        end
      end
    elseif ctx.focused and over_view and not g.alt and p.g
           and p.g.route and i.clicked[1] and hitx then
      -- the route line grammar: each click appends a point
      p.g.route[#p.g.route + 1] = hitx
      p.g.route[#p.g.route + 1] = hitz
      ed.touch()
    end
    if p.g and not p.g.route then
      local btn = p.g.btn
      local held = btn == 1 and i.buttons[1] or btn == 3 and i.buttons[3]
      if held then
        local tool = p.g.tool
        if tool == "sel" then
          if p.g.mode == "move" and hitx and p.sel then
            local it = p.sel.t == "prop" and doc.props[p.sel.i]
                       or doc.markers[p.sel.i]
            if it then
              local nx, nz = hitx + p.g.gdx, hitz + p.g.gdz
              if g.ctrl then
                local st = doc.tile * 0.5
                nx = math.floor(nx / st + 0.5) * st
                nz = math.floor(nz / st + 0.5) * st
              end
              it.x, it.z = nx, nz
              ctx.touch()
            end
          elseif p.g.mode == "routept" and hitx and p.sel then
            local mk = doc.markers[p.sel.i]
            if mk and mk.points then
              local nx, nz = hitx, hitz
              if g.ctrl then
                local st = doc.tile * 0.5
                nx = math.floor(nx / st + 0.5) * st
                nz = math.floor(nz / st + 0.5) * st
              end
              mk.points[p.g.k], mk.points[p.g.k + 1] = nx, nz
              if p.g.k == 1 then mk.x, mk.z = nx, nz end
              ctx.touch()
            end
          end
        elseif tool == "wtr" then
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
            apply_brush(win, p, tool, hitx, hitz, btn, g.ctrl,
                        stamp_for(ed, win))
          if vx0 then
            patch_mesh(ed, p, win.path, vx0, vz0, vx1, vz1)
            if tool == "hgt" or tool == "flt" or tool == "smo" then
              p.wkgen = nil -- ground moved: the walk overlay is stale
            elseif tool == "pnt" or tool == "shd" then
              -- the live atlas follows the brush
              stroke_patch(ed, p, vx0, vz0, vx1, vz1)
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
  -- clipped to the viewport: a gizmo projecting past its edge (a route
  -- point near the bottom) must not paint over the inspector strip
  if bound then
    pal.x_ig_clip_push(vx, vy, vw, vh)
    local tool = win.tool or "sel"
    local function diamond(sx, sy, d, col)
      pal.x_ig_line(vx + sx - d, vy + sy, vx + sx, vy + sy - d, col, 1.5)
      pal.x_ig_line(vx + sx, vy + sy - d, vx + sx + d, vy + sy, col, 1.5)
      pal.x_ig_line(vx + sx + d, vy + sy, vx + sx, vy + sy + d, col, 1.5)
      pal.x_ig_line(vx + sx, vy + sy + d, vx + sx - d, vy + sy, col, 1.5)
    end
    -- brush ring
    if BRUSH_TOOLS[tool] and hitx then
      draw_ring(vpm, vw, vh, vx, vy, doc, hitx, hitz,
                tool == "wlk" and doc.tile * 0.25 or (win.brush_r or 3))
    end
    -- marker tags + route polylines (selected = accent)
    for mi, mk in ipairs(doc.markers) do
      local selm = p.sel and p.sel.t == "marker" and p.sel.i == mi
      local col = selm and COL.hot or COL.spawn
      if mk.points then
        local prev
        for k = 1, #mk.points, 2 do
          local pxw, pzw = mk.points[k], mk.points[k + 1]
          local sx, sy = ob.project(vpm, vw, vh, pxw,
                                    terr.sample(doc, pxw, pzw) + 0.15, pzw)
          if sx then
            if prev then
              pal.x_ig_line(vx + prev[1], vy + prev[2],
                            vx + sx, vy + sy, col, selm and 2 or 1.2)
            end
            if selm then diamond(sx, sy, 3 * z, col) end
            prev = { sx, sy }
          else
            prev = nil
          end
        end
      end
      local sx, sy = ob.project(vpm, vw, vh, mk.x,
                                terr.sample(doc, mk.x, mk.z) + 0.3, mk.z)
      if sx then
        diamond(sx, sy, (selm and 5 or 4) * z, col)
        pal.x_ig_text(vx + sx + 6 * z, vy + sy - px * 0.5, px * 0.9, col,
                      mk.kind .. (mk.label and mk.label ~= ""
                                  and (" " .. mk.label) or ""), 0)
      end
    end
    -- the live route rubber band
    if p.g and p.g.route then
      local rt = p.g.route
      local prev
      for k = 1, #rt, 2 do
        local sx, sy = ob.project(vpm, vw, vh, rt[k],
                                  terr.sample(doc, rt[k], rt[k + 1]) + 0.15,
                                  rt[k + 1])
        if sx then
          if prev then
            pal.x_ig_line(vx + prev[1], vy + prev[2], vx + sx, vy + sy,
                          COL.hot, 2)
          end
          diamond(sx, sy, 3 * z, COL.hot)
          prev = { sx, sy }
        end
      end
      if prev and hitx then
        local sx, sy = ob.project(vpm, vw, vh, hitx,
                                  terr.sample(doc, hitx, hitz) + 0.15, hitz)
        if sx then
          pal.x_ig_line(vx + prev[1], vy + prev[2], vx + sx, vy + sy,
                        0xE8E4FF88, 1.2)
        end
      end
    end
    -- selected prop: projected AABB bracket
    if p.sel and p.sel.t == "prop" then
      local pr = doc.props[p.sel.i]
      if pr then
        local dimsfn2 = function(path)
          local t = image_tex(ed, path)
          if t then return t.w, t.h end
        end
        local b = terr3.prop_aabb(doc, pr, dimsfn2)
        local x0s, y0s, x1s, y1s
        for _, c in ipairs({ { b[1], b[2], b[3] }, { b[4], b[2], b[3] },
                             { b[1], b[2], b[6] }, { b[4], b[2], b[6] },
                             { b[1], b[5], b[3] }, { b[4], b[5], b[3] },
                             { b[1], b[5], b[6] }, { b[4], b[5], b[6] } }) do
          local sx, sy = ob.project(vpm, vw, vh, c[1], c[2], c[3])
          if sx then
            x0s = math.min(x0s or sx, sx)
            x1s = math.max(x1s or sx, sx)
            y0s = math.min(y0s or sy, sy)
            y1s = math.max(y1s or sy, sy)
          end
        end
        if x0s then
          pal.x_ig_rect(vx + x0s - 2, vy + y0s - 2,
                        x1s - x0s + 4, y1s - y0s + 4, COL.hot, 1.5, 2)
          local nm = pr.name and pr.name ~= "" and (pr.name .. "  ") or ""
          pal.x_ig_text(vx + x0s, vy + y0s - px - 2, px * 0.9, COL.hot,
                        nm .. pr.path, 0)
        end
      end
    end
    -- the asset-carry ghost (drop preview)
    if g.adrag and g.adrag.moved and hitx then
      local sx, sy = ob.project(vpm, vw, vh, hitx,
                                terr.sample(doc, hitx, hitz) + 0.3, hitz)
      if sx then
        diamond(sx, sy, 5 * z, COL.hot)
        pal.x_ig_text(vx + sx + 6 * z, vy + sy - px * 0.5, px * 0.9,
                      COL.hot, "place " .. g.adrag.path, 0)
      end
    end
    -- spawn gizmo: a small diamond + label
    local sx, sy = ob.project(vpm, vw, vh, doc.spawn.x,
                              terr.sample(doc, doc.spawn.x, doc.spawn.z)
                              + 0.4, doc.spawn.z)
    if sx then
      diamond(sx, sy, 4 * z, COL.spawn)
      pal.x_ig_text(vx + sx + 6 * z, vy + sy - px * 0.5, px * 0.9,
                    COL.spawn, "spawn", 0)
    end
    pal.x_ig_clip_pop()
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
    local u = cm.require("cm.ed.kit").winui(p, win)
    u.stamprect = nil -- stale drop targets must not linger
    if tool ~= "pnt" then u.matrects = nil end
    local function label(txt, col)
      pal.x_ig_text(vx + 6 * z, sy0 + (INSP - px) * 0.45, px,
                    col or COL.dim, txt, 0)
      return vx + 6 * z + pal.x_ig_text_size(txt, px, 0)
    end
    -- the brush-shape well: SHOWS the live brush shape (the radial dot,
    -- or the stamp image) and IS the stamp drop target — drag a sprite
    -- over it to make it the brush; the stamp chip's x resets. Returns
    -- the x after itself.
    local function brush_well(sx)
      local wsz = INSP - 4 * z
      u.stamprect = { x = sx, y = sy0 + 2 * z, w = wsz, h = wsz }
      pal.x_ig_rect_fill(sx, sy0 + 2 * z, wsz, wsz, COL.btn, 2 * z)
      if win.stamp then
        local t = image_tex(ed, win.stamp)
        if t and t.id then
          local s = math.min(wsz / t.w, wsz / t.h)
          local dw, dh = t.w * s, t.h * s
          pal.x_ig_image(t.id, sx + (wsz - dw) * 0.5,
                         sy0 + 2 * z + (wsz - dh) * 0.5, dw, dh)
        end
      else
        pal.x_ig_circle_fill(sx + wsz * 0.5, sy0 + 2 * z + wsz * 0.5,
                             wsz * 0.32, COL.dim)
      end
      pal.x_ig_rect(sx, sy0 + 2 * z, wsz, wsz, COL.btn_on, 1, 2 * z)
      return sx + wsz + 6 * z
    end
    -- the custom-brush chip: names the dropped stamp, click clears it
    local function stamp_chip(sx)
      if not win.stamp then return end
      local txt = "stamp: " .. (win.stamp:match("([^/]+)$") or win.stamp)
                  .. "  x"
      local w = pal.x_ig_text_size(txt, px, 0) + 10 * z
      local hov = i.wx >= sx and i.wx < sx + w
                  and i.wy >= sy0 and i.wy < sy0 + INSP
      pal.x_ig_rect_fill(sx, sy0 + 2 * z, w, INSP - 4 * z,
                         hov and COL.btn_on or COL.btn, 3 * z)
      pal.x_ig_text(sx + 5 * z, sy0 + (INSP - px) * 0.45, px,
                    hov and COL.hot or COL.dim, txt, 0)
      if hov and i.clicked[1] then
        win.stamp = nil
        ed.touch()
      end
    end
    if tool == "pnt" then
      -- the material strip: swatches + add. Each swatch is also a DROP
      -- TARGET: dropping an image on one assigns it as that material's
      -- texture (sampled per tile, live); dropping on the VIEWPORT
      -- adds a new material of the image; the corner notch marks
      -- textured materials (shape, not only color — D130).
      u.matrects = {}
      local sx = brush_well(vx + 6 * z)
      for mi = 1, #doc.mats do
        local sw = 14 * z
        local on = (win.mat or 1) == mi
        pal.x_ig_rect_fill(sx, sy0 + 2 * z, sw, INSP - 4 * z,
          (math.floor(doc.mats[mi].col[1] * 255) << 24)
          | (math.floor(doc.mats[mi].col[2] * 255) << 16)
          | (math.floor(doc.mats[mi].col[3] * 255) << 8) | 0xff, 2 * z)
        if (doc.mats[mi].tex or "") ~= "" then
          pal.x_ig_rect_fill(sx + sw - 5 * z, sy0 + 2 * z, 5 * z, 5 * z,
                             0x141220ee, 0)
        end
        if on then
          pal.x_ig_rect(sx - 1, sy0 + 2 * z - 1, sw + 2, INSP - 4 * z + 2,
                        COL.hot, 1.5, 2 * z)
        end
        u.matrects[#u.matrects + 1] = { x = sx, y = sy0, w = sw,
                                        h = INSP, mi = mi }
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
      -- the active material's texture chip: names it, click clears
      local am = doc.mats[win.mat or 1]
      if am and (am.tex or "") ~= "" then
        local ct = "tex: " .. (am.tex:match("([^/]+)$") or am.tex) .. "  x"
        local cw2 = pal.x_ig_text_size(ct, px, 0) + 10 * z
        local hov = i.wx >= sx and i.wx < sx + cw2
                    and i.wy >= sy0 and i.wy < sy0 + INSP
        pal.x_ig_rect_fill(sx, sy0 + 2 * z, cw2, INSP - 4 * z,
                           hov and COL.btn_on or COL.btn, 3 * z)
        pal.x_ig_text(sx + 5 * z, sy0 + (INSP - px) * 0.45, px,
                      hov and COL.hot or COL.dim, ct, 0)
        if hov and i.clicked[1] then
          am.tex = ""
          lat_free(p)
          commit(ed, win.path)
          p.gen = p.gen + 1
          ed.touch()
        end
        sx = sx + cw2 + 6 * z
      end
      local txt = ("%s  r=%.1f (ctrl+wheel)  s=%.1f ([ ])  right = erase%s")
          :format(doc.mats[win.mat or 1]
                  and doc.mats[win.mat or 1].name or "?",
                  win.brush_r or 3, win.brush_s or 0.5,
                  p.at_note and ("  " .. p.at_note) or "")
      pal.x_ig_text(sx, sy0 + (INSP - px) * 0.45, px, COL.dim, txt, 0)
      stamp_chip(sx + pal.x_ig_text_size(txt, px, 0) + 10 * z)
    elseif tool == "wtr" then
      label(("water %s  y=%.2f  drag up/down (ctrl = 0.25 steps)")
            :format(doc.water.on and "on" or "off", doc.water.y))
    elseif tool == "wlk" then
      label(("walk: L block - R walk - ctrl clears  (derived slope<=%.2f"
             .. " wade<=%.2f)"):format(doc.walk.slope, doc.walk.wade))
    elseif BRUSH_TOOLS[tool] then
      local sx = brush_well(vx + 6 * z)
      local txt = ("r=%.1f (ctrl+wheel)  s=%.1f ([ ])%s")
            :format(win.brush_r or 3, win.brush_s or 0.5,
                    tool == "hgt" and "  ctrl = level steps" or "")
      pal.x_ig_text(sx, sy0 + (INSP - px) * 0.45, px, COL.dim, txt, 0)
      stamp_chip(sx + pal.x_ig_text_size(txt, px, 0) + 10 * z)
    elseif tool == "mkr" then
      local sx = vx + 6 * z
      for _, kn in ipairs(MKINDS) do
        local w = pal.x_ig_text_size(kn, px, 0) + 10 * z
        local on = (win.mkind or "spawn") == kn
        local hov = i.wx >= sx and i.wx < sx + w
                    and i.wy >= sy0 and i.wy < sy0 + INSP
        pal.x_ig_rect_fill(sx, sy0 + 2 * z, w, INSP - 4 * z,
                           on and COL.btn_on or COL.btn, 3 * z)
        pal.x_ig_text(sx + 5 * z, sy0 + (INSP - px) * 0.45, px,
                      (hov or on) and COL.hot or COL.dim, kn, 0)
        if hov and i.clicked[1] then
          win.mkind = kn
          ed.touch()
        end
        sx = sx + w + 3 * z
      end
      pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px, COL.dim,
                    (win.mkind or "spawn") == "route"
                    and "click lays points - enter ends"
                    or "click places", 0)
    elseif tool == "sel" and p.sel then
      local sel = p.sel
      local it = sel.t == "prop" and doc.props[sel.i]
                 or doc.markers[sel.i]
      if it then
        -- name/label field (set-on-selection-change: the D121 lesson)
        local selkey = sel.t .. sel.i
        local setb = p.fldkey ~= selkey
        p.fldkey = selkey
        local cur = sel.t == "prop" and (it.name or "") or (it.label or "")
        local fw = 90 * z
        local text, _, _, st = pal.x_ig_edit {
          id = "t3nm" .. win.id, x = vx + 6 * z, y = sy0 + 2 * z,
          w = fw, h = INSP - 4 * z, text = cur, px = px, font = 1,
          enter = true, multiline = false, set = setb,
        }
        if st and st.submit and text ~= cur then
          local v = text ~= "" and text or nil
          if sel.t == "prop" then it.name = v else it.label = v end
          commit(ed, win.path)
        end
        local sx = vx + 6 * z + fw + 8 * z
        local function chip(labelc, on)
          local w = pal.x_ig_text_size(labelc, px, 0) + 10 * z
          local hov = i.wx >= sx and i.wx < sx + w
                      and i.wy >= sy0 and i.wy < sy0 + INSP
          pal.x_ig_rect_fill(sx, sy0 + 2 * z, w, INSP - 4 * z,
                             on and COL.btn_on or COL.btn, 3 * z)
          pal.x_ig_text(sx + 5 * z, sy0 + (INSP - px) * 0.45, px,
                        (hov or on) and COL.hot or COL.dim, labelc, 0)
          sx = sx + w + 3 * z
          return hov and i.clicked[1]
        end
        if sel.t == "prop" then
          if chip("abs", it.abs) then
            -- keep the resolved height when flipping anchor modes
            local py = terr3.prop_y(doc, it)
            it.abs = not it.abs and true or nil
            it.y = it.abs and py
                   or py - terr.sample(doc, it.x, it.z)
            commit(ed, win.path)
          end
          if chip("caster", it.caster) then
            it.caster = not it.caster and true or nil
            commit(ed, win.path)
          end
          if chip("blocker", it.blocker) then
            it.blocker = not it.blocker and true or nil
            commit(ed, win.path)
          end
          local cmode = it.col and it.col.mode or "none"
          if chip("col:" .. cmode, cmode ~= "none") then
            if cmode == "none" then it.col = { mode = "auto" }
            elseif cmode == "auto" then
              local b = terr3.prop_aabb(doc, it)
              local s = it.scale or 1
              local py = terr3.prop_y(doc, it)
              it.col = { mode = "box",
                         box = { (b[1] - it.x) / s, (b[2] - py) / s,
                                 (b[3] - it.z) / s, (b[4] - it.x) / s,
                                 (b[5] - py) / s, (b[6] - it.z) / s } }
            else it.col = nil end
            commit(ed, win.path)
          end
          pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px, COL.dim,
            ("x=%.1f z=%.1f y%+.2f yaw=%d s=%.2f  arrows nudge . , yaw"
             .. " - = size"):format(it.x, it.z, it.y or 0,
              math.floor(((it.yaw or 0) * 180 / mm.pi) + 0.5),
              it.scale or 1), 0)
        else
          pal.x_ig_text(sx + 4 * z, sy0 + (INSP - px) * 0.45, px, COL.dim,
            ("%s  x=%.1f z=%.1f r=%.1f%s"):format(it.kind, it.x, it.z,
              it.r or 0.5,
              it.points and ("  route pts=" .. (#it.points // 2)) or ""), 0)
        end
      end
    else
      -- (the D138-era manual "bake tex" chip is gone: textures render
      -- live and Ctrl+S publishes the atlas png — save = bake)
      label(("%s  %dx%d tile %.1f  props %d  markers %d%s")
            :format(doc.name ~= "" and doc.name or win.path,
                    doc.w, doc.h, doc.tile, #doc.props, #doc.markers,
                    p.at_note and ("  " .. p.at_note) or ""))
    end
  end
end

return M
