-- cm.studio — the asset studio: a full-window in-engine sprite editor (M10,
-- D040, STUDIO.md). The F2 mode. Distinct from cm.editor (the F1 world editor).
--
-- Determinism class: dev/render ONLY. It edits render-only assets (cm.sprite
-- documents), never sim state — so it is never recorded, never runs headless/
-- verify, and pauses the sim while open (cm.main gates on M.on). It draws on the
-- ui canvas at cfg.ui_scale (like the editor/options chrome) and captures all
-- mouse + keyboard. Toggled F2; the play-mode lockdown disables it (locked()).
--
-- Phase 1 (this file): the studio shell + canvas (checkerboard, composite→one
-- texture, cursor-anchored pan/zoom, pixel grid, hover), the pencil/eraser/
-- bucket/eyedropper tools, a palette + primary/secondary colors, save. Layers /
-- shapes / gradients / animation / the asset browser land in later phases.

local M = select(2, ...) or {}

local ui = cm.require("cm.ui")
local view = cm.require("cm.view")
local paint = cm.require("cm.paint")
local sprite = cm.require("cm.sprite")

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

-- ---- persistent dev state (survives hot reload, resets on VM reboot) ----
M.on = M.on or false
M.doc = M.doc -- the open document (nil until first open)
M.zoom = M.zoom or 8
M.pan_x = M.pan_x or 0
M.pan_y = M.pan_y or 0
M.tool = M.tool or "pencil" -- pencil | eraser | fill | pick | line | rect | ellipse
M.fill_shapes = M.fill_shapes or false -- rect/ellipse: filled vs outline
M.prim = M.prim or paint.pack(246, 248, 252) -- primary color (LMB)
M.sec = M.sec or paint.pack(32, 28, 44) -- secondary color (RMB)
M.hsv = M.hsv or { h = 0.58, s = 0.03, v = 0.99 } -- the picker's H/S/V state
M.dirty = true -- the canvas composite texture needs a rebuild
M.alt, M.ctrl = false, false
M.dock_scroll = M.dock_scroll or 0 -- the right dock scrolls when content is tall

-- layout metrics (ui-canvas px); regions computed each frame from these
local MENU_H, RAIL_W, DOCK_W, TIME_H = 14, 22, 116, 24
local SWATCH = 12
local LROW = 12 -- a layers-panel row

-- scancodes
local KEY_F2 = 59
local ALT_L, ALT_R, CTRL_L, CTRL_R = 226, 230, 224, 228
local SHIFT_L, SHIFT_R = 225, 229
local SC = { z = 29, y = 28, s = 22, b = 5, e = 8, g = 10, i = 12, x = 27,
             l = 15, r = 21, o = 18, f = 9 }

local TOOLS = {
  { id = "pencil",  key = "B", tip = "pencil" },
  { id = "eraser",  key = "E", tip = "eraser" },
  { id = "fill",    key = "G", tip = "bucket fill" },
  { id = "line",    key = "L", tip = "line (Shift = 45°)" },
  { id = "rect",    key = "R", tip = "rectangle (Shift = square)" },
  { id = "ellipse", key = "O", tip = "ellipse (Shift = circle)" },
  { id = "pick",    key = "I", tip = "eyedropper (or hold Alt)" },
}
local SHAPE = { line = true, rect = true, ellipse = true }

-- ---- helpers ----

local function pin(x, y, rx, ry, rw, rh)
  return x >= rx and x < rx + rw and y >= ry and y < ry + rh
end

local function col(rgba) -- packed u32 -> ui {r,g,b,a} floats
  local r, g, b, a = paint.unpack(rgba)
  return { r / 255, g / 255, b / 255, a / 255 }
end

local function hexstr(rgba)
  local r, g, b, a = paint.unpack(rgba)
  if a == 0 then return "(clear)" end
  return ("#%02X%02X%02X"):format(r, g, b)
end

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

local function parse_hex(s)
  s = (s or ""):gsub("^%s*#?", ""):gsub("%s*$", "")
  if not s:match("^%x%x%x%x%x%x$") then return nil end
  return paint.pack(tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16),
                    tonumber(s:sub(5, 6), 16), 255)
end

function M.locked()
  local proj = cm.main and cm.main.proj
  return (proj ~= nil and proj.editor == false) and true or false
end

function M.cell() return sprite.cell(M.doc) end

function M.new_doc(w, h)
  M.doc = sprite.new(w or 32, h or 32)
  M.dirty, M.need_fit = true, true
end

function M.toggle(on)
  if M.locked() then return end
  if on == nil then M.on = not M.on else M.on = on == true or on == 1 end
  if M.on then
    cm.require("cm.editor").on = false -- the studio is exclusive (full window)
    if not M.doc then M.new_doc(32, 32) end
    M.need_fit = true
  end
end

-- open (optionally adopt a doc) and enter the mode. Usable from the console.
function M.open(doc)
  if doc then M.doc, M.dirty, M.need_fit = doc, true, true end
  if not M.doc then M.new_doc(32, 32) end
  M.toggle(true)
end

-- a recognizable motif for screenshots / smoke tests (not undoable; dev aid)
function M.demo()
  if not M.doc then M.new_doc(32, 32) end
  local c, P = M.cell(), paint.pack
  paint.fill(c, 0)
  paint.ellipse(c, 8, 5, 23, 28, P(236, 232, 245), true)  -- suit body
  paint.ellipse(c, 8, 5, 23, 28, P(150, 156, 196), false) -- shade outline
  paint.rect(c, 12, 10, 8, 5, P(247, 219, 188), true)     -- face
  paint.rect(c, 13, 12, 2, 2, P(32, 28, 44), true)        -- eyes
  paint.rect(c, 17, 12, 2, 2, P(32, 28, 44), true)
  paint.line(c, 14, 20, 17, 20, P(108, 220, 250))         -- cyan accent
  paint.line(c, 15, 6, 15, 1, P(248, 214, 122))           -- gold antenna
  M.dirty = true
end

function M.save()
  if not M.doc then return end
  local proj = cm.main and cm.main.args and cm.main.args.project
  if not proj then pal.log("[studio] no project dir to save into"); return end
  local dir = proj .. "/art"
  pal.mkdir(dir)
  local path = M.doc.path or (dir .. "/" .. (M.doc.name or "untitled") .. ".spr")
  local ok, err = sprite.save(M.doc, path)
  pal.log(ok and ("[studio] saved " .. path)
             or ("[studio] save FAILED: " .. tostring(err)))
end

-- ---- color + palette ----

-- set the primary from outside the picker (palette / eyedropper / hex / swap)
-- and sync the HSV picker to it. The picker writes M.prim + M.hsv directly.
function M.set_prim(rgba)
  M.prim = rgba
  M.hsv.h, M.hsv.s, M.hsv.v = paint.to_hsv(rgba)
end

local function palettes_path()
  local proj = cm.main and cm.main.args and cm.main.args.project
  return proj and (proj .. "/art/palettes.dat") or nil
end

-- named palette preset slots, shared across all assets in a project (render/dev
-- state, like cm.view's video.dat — not sim state). Canonical doc bytes.
function M.load_palettes()
  M.palettes = {}
  local p = palettes_path()
  local bytes = p and pal.read_file(p)
  if not bytes then return end
  local ok, t = pcall(cm.require("cm.state").parse, bytes)
  if ok and type(t) == "table" then
    for i, slot in ipairs(t) do if type(slot) == "table" then M.palettes[i] = slot end end
  end
end

function M.save_palettes()
  local p = palettes_path()
  if not p then return end
  pal.mkdir((p:gsub("/[^/]*$", "")))
  pal.write_file(p, cm.require("cm.state").canon(M.palettes))
end

-- the HSV color-picker textures: the saturation/value square (regenerated when
-- the hue changes) and the static hue strip.
local function rebuild_sv()
  local n = 84
  M.sv = M.sv or paint.image(n, n)
  local h = M.hsv.h
  for y = 0, n - 1 do
    local v = 1 - y / (n - 1)
    for x = 0, n - 1 do M.sv.buf:u32((y * n + x) * 4, paint.hsv(h, x / (n - 1), v)) end
  end
  if M.sv_tex then pal.tex_free(M.sv_tex) end
  M.sv_tex = pal.tex_create(n, n, M.sv.buf:str(0, n * n * 4))
  M.sv_hue = h
end

local function build_hue()
  local n = 84
  local img = paint.image(1, n)
  for y = 0, n - 1 do img.buf:u32(y * 4, paint.hsv(y / (n - 1), 1, 1)) end
  if M.hue_tex then pal.tex_free(M.hue_tex) end
  M.hue_tex = pal.tex_create(1, n, img.buf:str(0, n * 4))
end

-- ---- asset browser ----

-- scan <project>/art for .spr documents, bake a thumbnail texture for each
function M.scan_assets()
  if M.browse_items then
    for _, it in ipairs(M.browse_items) do if it.tex then pal.tex_free(it.tex) end end
  end
  M.browse_items = {}
  local proj = cm.main and cm.main.args and cm.main.args.project
  if not proj then return end
  local dir = proj .. "/art"
  local names = pal.list_dir(dir) or {}
  table.sort(names)
  for _, n in ipairs(names) do
    if n:match("%.spr$") then
      local doc = sprite.load(dir .. "/" .. n)
      if doc then
        local strip = sprite.bake_image(doc)
        M.browse_items[#M.browse_items + 1] = {
          path = dir .. "/" .. n, name = (n:gsub("%.spr$", "")),
          tex = pal.tex_create(strip.w, strip.h, strip.buf:str(0, strip.w * strip.h * 4)),
          w = strip.w, h = strip.h,
        }
      end
    end
  end
end

function M.open_browser() M.browser = true; M.scan_assets() end

-- ---- canvas mapping ----

-- the doc pixel under a ui-canvas point, or nil if outside the image
function M.doc_pixel(mx, my)
  local r = M.canvas
  if not r then return nil end
  local px = floor((mx - r.x - M.pan_x) / M.zoom)
  local py = floor((my - r.y - M.pan_y) / M.zoom)
  if px < 0 or px >= M.doc.w or py < 0 or py >= M.doc.h then return nil end
  return px, py
end

-- the doc pixel under a point WITHOUT the in-bounds clip — a shape's far
-- endpoint may be dragged off the image; the rasterizers clip per-pixel.
function M.doc_pixel_raw(mx, my)
  local r = M.canvas
  return floor((mx - r.x - M.pan_x) / M.zoom), floor((my - r.y - M.pan_y) / M.zoom)
end

function M.fit()
  local r = M.canvas
  if not r then return end
  local zx = (r.w - 24) // M.doc.w
  local zy = (r.h - 24) // M.doc.h
  M.zoom = max(1, min(zx, zy, 32))
  M.pan_x = (r.w - M.doc.w * M.zoom) // 2
  M.pan_y = (r.h - M.doc.h * M.zoom) // 2
end

function M.rebuild_tex()
  local doc = M.doc
  if not M.comp or M.comp.w ~= doc.w or M.comp.h ~= doc.h then
    M.comp = paint.image(doc.w, doc.h)
  end
  sprite.composite_into(doc, doc.cur_frame, M.comp)
  if M.canvas_tex then pal.tex_free(M.canvas_tex) end
  M.canvas_tex = pal.tex_create(doc.w, doc.h, M.comp.buf:str(0, doc.w * doc.h * 4))
  M.dirty = false
end

-- ---- input ----

local function handle_keys()
  local typing = ui.focus ~= nil -- the hex field owns the keyboard; no shortcuts
  for _, k in ipairs(ui.inp.keys) do
    local sc = k.scancode
    if sc == ALT_L or sc == ALT_R then M.alt = k.down end
    if sc == CTRL_L or sc == CTRL_R then M.ctrl = k.down end
    if sc == SHIFT_L or sc == SHIFT_R then M.shift = k.down end
    if k.down and not k.rep and not typing then
      if M.ctrl then
        if sc == SC.z then sprite.undo(M.doc); M.dirty = true
        elseif sc == SC.y then sprite.redo(M.doc); M.dirty = true
        elseif sc == SC.s then M.save() end
      elseif sc == SC.b then M.tool = "pencil"
      elseif sc == SC.e then M.tool = "eraser"
      elseif sc == SC.g then M.tool = "fill"
      elseif sc == SC.l then M.tool = "line"
      elseif sc == SC.r then M.tool = "rect"
      elseif sc == SC.o then M.tool = "ellipse"
      elseif sc == SC.i then M.tool = "pick"
      elseif sc == SC.f then M.fill_shapes = not M.fill_shapes
      elseif sc == SC.x then M.prim, M.sec = M.sec, M.prim; M.set_prim(M.prim) end
    end
  end
end

-- Shift-constrain a shape's endpoints: line snaps to horizontal / vertical /
-- 45°, rect/ellipse to a square / circle (the shorter axis wins).
local function constrain_shape(sx, sy, ex, ey)
  local dx, dy = ex - sx, ey - sy
  if M.tool == "line" then
    local adx, ady = math.abs(dx), math.abs(dy)
    if adx > 2 * ady then ey = sy
    elseif ady > 2 * adx then ex = sx
    else
      local m = min(adx, ady)
      ex = sx + (dx < 0 and -m or m)
      ey = sy + (dy < 0 and -m or m)
    end
  else
    local m = min(math.abs(dx), math.abs(dy))
    ex = sx + (dx < 0 and -m or m)
    ey = sy + (dy < 0 and -m or m)
  end
  return sx, sy, ex, ey
end

-- draw the active shape tool into `img` between two corners (one undo step on
-- commit; the same call paints the live preview).
local function stroke_shape(img, sx, sy, ex, ey, color)
  if M.tool == "line" then
    paint.line(img, sx, sy, ex, ey, color)
  elseif M.tool == "rect" then
    paint.rect(img, min(sx, ex), min(sy, ey),
               math.abs(ex - sx) + 1, math.abs(ey - sy) + 1, color, M.fill_shapes)
  elseif M.tool == "ellipse" then
    paint.ellipse(img, sx, sy, ex, ey, color, M.fill_shapes)
  end
end

-- the current shape's endpoints (start pixel + the cursor), Shift-constrained.
local function resolve_shape()
  local sx, sy = M.shape_sx, M.shape_sy
  local ex, ey = M.doc_pixel_raw(ui.inp.mx, ui.inp.my)
  if M.shift then return constrain_shape(sx, sy, ex, ey) end
  return sx, sy, ex, ey
end

-- rebuild the shape-preview texture (a transparent cell with just the shape) so
-- draw_canvas can overlay it as one quad — nothing touches real pixels until
-- release. Called each tick; clears the flag when no shape is in progress.
local function build_preview()
  if not M.shape_drawing then M.has_preview = false; return end
  local doc = M.doc
  if not M.preview or M.preview.w ~= doc.w or M.preview.h ~= doc.h then
    M.preview = paint.image(doc.w, doc.h)
  end
  paint.fill(M.preview, 0)
  local sx, sy, ex, ey = resolve_shape()
  stroke_shape(M.preview, sx, sy, ex, ey,
               M.shape_which == "prim" and M.prim or M.sec)
  if M.preview_tex then pal.tex_free(M.preview_tex) end
  M.preview_tex = pal.tex_create(doc.w, doc.h, M.preview.buf:str(0, doc.w * doc.h * 4))
  M.has_preview = true
end

local function dab(px, py)
  local color = M.tool == "eraser" and 0 or (M.stroke == "prim" and M.prim or M.sec)
  local cell = M.cell()
  if M.last_px then
    paint.line(cell, M.last_px, M.last_py, px, py, color)
  else
    paint.set(cell, px, py, color)
  end
  M.last_px, M.last_py = px, py
  M.dirty = true
end

local function handle_paint(over)
  local inp = ui.inp
  local tool = M.alt and "pick" or M.tool
  local pressed = inp.clicked[1] or inp.clicked[3]
  local held = inp.buttons[1] or inp.buttons[3]
  local which = (inp.clicked[1] or inp.buttons[1]) and "prim" or "sec"
  local dpx, dpy = M.doc_pixel(inp.mx, inp.my)

  -- a shape already in progress owns the gesture until release (so a tapped Alt
  -- can't divert it to the eyedropper); the preview tracks the cursor meanwhile
  if M.shape_drawing then
    if not held then
      local sx, sy, ex, ey = resolve_shape()
      sprite.begin_edit(M.doc)
      stroke_shape(M.cell(), sx, sy, ex, ey, M.shape_which == "prim" and M.prim or M.sec)
      sprite.end_edit(M.doc)
      M.shape_drawing, M.dirty = false, true
    end
    return
  end

  if tool == "pick" then
    if over and pressed and dpx then
      local c = paint.get(M.cell(), dpx, dpy)
      if which == "prim" then M.set_prim(c) else M.sec = c end
    end
    return
  end
  if tool == "fill" then
    if over and pressed and dpx and not ui.active then
      sprite.begin_edit(M.doc)
      paint.flood(M.cell(), dpx, dpy, which == "prim" and M.prim or M.sec)
      sprite.end_edit(M.doc)
      M.dirty = true
    end
    return
  end
  if SHAPE[tool] then
    -- press anchors a corner; the preview tracks the cursor; release commits
    -- (handled by the in-progress block above)
    if over and pressed and dpx and not ui.active then
      M.shape_drawing, M.shape_sx, M.shape_sy, M.shape_which = true, dpx, dpy, which
    end
    return
  end
  -- pencil / eraser: a press-to-release stroke (one undo step, line-continuous)
  if over and pressed and dpx and not ui.active then
    M.stroke = which
    M.last_px, M.last_py = nil, nil
    sprite.begin_edit(M.doc)
    dab(dpx, dpy)
  elseif M.stroke and held then
    if dpx then dab(dpx, dpy) end
  elseif M.stroke and not held then
    sprite.end_edit(M.doc)
    M.stroke = nil
  end
end

local function handle_zoom(over)
  if not over or ui.inp.wheel == 0 then return end
  local r = M.canvas
  local oz = M.zoom
  local nz = max(1, min(64, oz + (ui.inp.wheel > 0 and 1 or -1)
                               * (oz >= 8 and 2 or 1)))
  if nz == oz then return end
  local fx = (ui.inp.mx - r.x - M.pan_x) / oz -- doc coord under the cursor
  local fy = (ui.inp.my - r.y - M.pan_y) / oz
  M.zoom = nz
  M.pan_x = ui.inp.mx - r.x - fx * nz -- keep it under the cursor (anchored zoom)
  M.pan_y = ui.inp.my - r.y - fy * nz
end

local function handle_pan()
  local inp = ui.inp
  if inp.buttons[2] then -- middle-drag pans
    if M.pan_last then
      M.pan_x = M.pan_x + (inp.mx - M.pl_x)
      M.pan_y = M.pan_y + (inp.my - M.pl_y)
    end
    M.pan_last, M.pl_x, M.pl_y = true, inp.mx, inp.my
  else
    M.pan_last = nil
  end
end

-- ---- drawing ----

local function draw_canvas(r)
  local st = ui.style
  ui.rect(r.x, r.y, r.w, r.h, { 0.07, 0.07, 0.09, 1 }) -- the canvas void
  local z = M.zoom
  local ix, iy = r.x + floor(M.pan_x), r.y + floor(M.pan_y)
  local iw, ih = M.doc.w * z, M.doc.h * z
  -- clip to the image rect intersected with the canvas region
  local clx, cly = max(r.x, ix), max(r.y, iy)
  local crx, cry = min(r.x + r.w, ix + iw), min(r.y + r.h, iy + ih)
  pal.clip(clx, cly, max(0, crx - clx), max(0, cry - cly))
  -- checkerboard (transparency), 8px ui blocks
  ui.rect(ix, iy, iw, ih, { 0.18, 0.18, 0.21, 1 })
  local cs = 8
  for by = 0, ceil(ih / cs) - 1 do
    for bx = 0, ceil(iw / cs) - 1 do
      if (bx + by) % 2 == 0 then
        ui.rect(ix + bx * cs, iy + by * cs, cs, cs, { 0.25, 0.25, 0.29, 1 })
      end
    end
  end
  -- the composited sprite as one scaled quad (alpha-over the checker, nearest)
  pal.quad(ix, iy, iw, ih, 1, 1, 1, 1, M.canvas_tex, 0, 0, 1, 1)
  -- the live shape preview rides on top as one more quad (no real pixels yet)
  if M.has_preview and M.preview_tex then
    pal.quad(ix, iy, iw, ih, 1, 1, 1, 1, M.preview_tex, 0, 0, 1, 1)
  end
  -- pixel grid when zoomed in enough to place pixels by it
  if z >= 8 then
    local grid = { 1, 1, 1, 0.06 }
    for gx = 0, M.doc.w do ui.rect(ix + gx * z, iy, 1, ih, grid) end
    for gy = 0, M.doc.h do ui.rect(ix, iy + gy * z, iw, 1, grid) end
  end
  -- hover cell outline
  local dpx, dpy = M.doc_pixel(ui.inp.mx, ui.inp.my)
  if dpx and not ui.over_panel then
    ui.frame_rect(ix + dpx * z, iy + dpy * z, z, z, { 1, 1, 1, 0.7 })
  end
  pal.clip()
  ui.frame_rect(ix - 1, iy - 1, iw + 2, ih + 2, st.panel_edge) -- image border
end

local function tool_button(t, x, y, w, h)
  local st = ui.style
  local active = M.tool == t.id
  local clicked, hot = ui.hit("tool/" .. t.id, x, y, w, h)
  ui.rect(x, y, w, h, active and st.widget_active
                       or (hot and st.widget_hot or st.widget))
  ui.frame_rect(x, y, w, h, active and st.accent or st.panel_edge)
  ui.text(x + (w - ui.style.gw) // 2, y + (h - ui.style.gh) // 2, t.key,
          active and st.accent or st.text)
  if clicked then M.tool = t.id end
end

local function draw_rail(r)
  local st = ui.style
  ui.rect(r.x, r.y, r.w, r.h, st.panel)
  ui.frame_rect(r.x, r.y, r.w, r.h, st.panel_edge)
  local bw, bh = r.w - 4, 16
  for i, t in ipairs(TOOLS) do
    tool_button(t, r.x + 2, r.y + 2 + (i - 1) * (bh + 2), bw, bh)
  end
  -- shape fill/outline mode (lit when filling); also keyed to F
  local fy = r.y + 2 + #TOOLS * (bh + 2) + 4
  local on = M.fill_shapes
  local clicked, hot = ui.hit("tool/fillmode", r.x + 2, fy, bw, bh)
  ui.rect(r.x + 2, fy, bw, bh, on and st.widget_active or (hot and st.widget_hot or st.widget))
  ui.frame_rect(r.x + 2, fy, bw, bh, on and st.accent or st.panel_edge)
  if on then ui.rect(r.x + 5, fy + 4, bw - 6, bh - 8, st.accent) -- a filled glyph
  else ui.frame_rect(r.x + 5, fy + 4, bw - 6, bh - 8, st.text) end  -- hollow glyph
  if clicked then M.fill_shapes = not M.fill_shapes end
end

local function swatch(rgba, x, y)
  local st = ui.style
  local inp = ui.inp
  local hot = pin(inp.mx, inp.my, x, y, SWATCH, SWATCH)
  -- a tiny checker under partial-alpha swatches so transparency reads
  ui.rect(x, y, SWATCH, SWATCH, { 0.25, 0.25, 0.29, 1 })
  ui.rect(x, y, SWATCH, SWATCH, col(rgba))
  if M.prim == rgba then ui.frame_rect(x, y, SWATCH, SWATCH, st.accent)
  elseif hot then ui.frame_rect(x, y, SWATCH, SWATCH, st.widget_hot) end
  if hot then
    if inp.clicked[1] then M.prim = rgba end
    if inp.clicked[3] then M.sec = rgba end
  end
end

-- LAYERS: the active layer's opacity, add/dup/delete/reorder, and the stack
-- (drawn top layer first — the artist's mental order). Returns the next y.
local function draw_layers(x, y, cw)
  local st, inp = ui.style, ui.inp
  local doc = M.doc
  ui.text(x, y, "LAYERS", st.accent); y = y + 11

  -- structural action buttons (each op is one undo step)
  local acts = { { "+", "add" }, { "dup", "dup" }, { "del", "del" },
                 { "up", "up" }, { "dn", "dn" } }
  local bw = (cw - (#acts - 1) * 2) // #acts
  for i, a in ipairs(acts) do
    local bx = x + (i - 1) * (bw + 2)
    if ui.button(a[1], { rect = { bx, y, bw, 12 }, id = "ly_" .. a[2] }) then
      if a[2] == "add" then sprite.add_layer(doc)
      elseif a[2] == "dup" then sprite.dup_layer(doc, doc.cur_layer)
      elseif a[2] == "del" then sprite.delete_layer(doc, doc.cur_layer)
      elseif a[2] == "up" then sprite.move_layer(doc, doc.cur_layer, 1)
      elseif a[2] == "dn" then sprite.move_layer(doc, doc.cur_layer, -1) end
      M.dirty = true
    end
  end
  y = y + 14

  -- the active layer's opacity (a render property; not on the undo stack)
  local L = doc.layers[doc.cur_layer]
  local nv, ch = ui.slider("op", L.opacity, 0, 255,
    { rect = { x, y, cw, 11 }, id = "ly_op", label_w = 2 * st.gw })
  if ch then L.opacity, doc.dirty, M.dirty = nv, true, true end
  y = y + 13

  -- the layer rows: display row d=1 is the TOP layer (= doc.layers[#]).
  local n = #doc.layers
  for d = 1, n do
    local li = n - d + 1
    local L2 = doc.layers[li]
    local ry = y + (d - 1) * LROW
    local active = li == doc.cur_layer
    ui.rect(x, ry, cw, LROW,
            active and st.widget_active or (li % 2 == 0 and st.widget or st.track))
    -- visibility toggle (filled = shown)
    if ui.hit("ly_eye" .. li, x + 1, ry + 2, 9, 9) then
      L2.hidden = not L2.hidden; doc.dirty, M.dirty = true, true
    end
    ui.rect(x + 1, ry + 2, 9, 9, st.widget); ui.frame_rect(x + 1, ry + 2, 9, 9, st.panel_edge)
    if not L2.hidden then ui.rect(x + 3, ry + 4, 5, 5, st.accent) end
    -- lock toggle ("L" lit when locked)
    if ui.hit("ly_lk" .. li, x + 12, ry + 2, 9, 9) then L2.locked = not L2.locked end
    ui.rect(x + 12, ry + 2, 9, 9, st.widget); ui.frame_rect(x + 12, ry + 2, 9, 9, st.panel_edge)
    ui.text(x + 14, ry + 2, "L", L2.locked and st.accent or st.text_dim)
    -- name (click selects the layer)
    if ui.hit("ly_row" .. li, x + 23, ry, cw - 23, LROW) then
      doc.cur_layer, M.dirty = li, true
    end
    ui.text(x + 24, ry + (LROW - st.gh) // 2, L2.name, active and st.accent or st.text)
  end
  return y + n * LROW + 5
end

local function draw_dock(r)
  local st = ui.style
  local inp = ui.inp
  ui.rect(r.x, r.y, r.w, r.h, st.panel)
  ui.frame_rect(r.x, r.y, r.w, r.h, st.panel_edge)
  -- the dock can be taller than the window (layers + palette + picker), so the
  -- whole content scrolls vertically; the wheel scrolls when hovering it (but
  -- not mid-pick, where the wheel would fight a colour drag).
  local over = pin(inp.mx, inp.my, r.x, r.y, r.w, r.h)
  if over and inp.wheel ~= 0 and not M.pick then
    M.dock_scroll = clamp(M.dock_scroll - inp.wheel * 18, 0, M.dock_over or 0)
  end
  M.dock_scroll = clamp(M.dock_scroll, 0, M.dock_over or 0)
  pal.clip(r.x, r.y + 1, r.w, r.h - 2)
  local x = r.x + 4
  local cw = r.w - 8
  local y = r.y + 4 - M.dock_scroll
  y = draw_layers(x, y, cw)

  -- PALETTE: swatch grid + add-current + preset slots
  ui.text(x, y, "PALETTE", st.accent); y = y + 11
  local cols = (cw + 1) // (SWATCH + 1)
  for i, c in ipairs(M.doc.palette) do
    swatch(c, x + ((i - 1) % cols) * (SWATCH + 1),
           y + ((i - 1) // cols) * (SWATCH + 1))
  end
  y = y + ceil(#M.doc.palette / cols) * (SWATCH + 1) + 3
  if ui.button("+ add color", { rect = { x, y, cw, 12 }, id = "st_addcol" }) then
    local has = false
    for _, c in ipairs(M.doc.palette) do if c == M.prim then has = true end end
    if not has then M.doc.palette[#M.doc.palette + 1] = M.prim; M.doc.dirty = true end
  end
  y = y + 15
  ui.text(x, y, "slots  L=load R=save", st.text_dim); y = y + 10
  local psw = (cw - 5 * 2) // 6
  for k = 1, 6 do
    local bx = x + (k - 1) * (psw + 2)
    local filled = M.palettes and M.palettes[k]
    local hot = pin(inp.mx, inp.my, bx, y, psw, 12)
    ui.rect(bx, y, psw, 12, hot and st.widget_hot or st.widget)
    ui.frame_rect(bx, y, psw, 12, filled and st.accent or st.panel_edge)
    ui.text(bx + (psw - st.gw) // 2, y + 2, tostring(k),
            filled and st.accent or st.text_dim)
    if hot and inp.clicked[1] and filled then
      M.doc.palette = {}
      for i, c in ipairs(M.palettes[k]) do M.doc.palette[i] = c end
      M.doc.dirty = true
    elseif hot and inp.clicked[3] then
      M.palettes = M.palettes or {}
      M.palettes[k] = {}
      for i, c in ipairs(M.doc.palette) do M.palettes[k][i] = c end
      M.save_palettes()
    end
  end
  y = y + 18

  -- COLOR: primary/secondary chips, the HSV picker, hex entry
  ui.text(x, y, "COLOR", st.accent); y = y + 11
  ui.rect(x, y, 20, 20, { 0.25, 0.25, 0.29, 1 }); ui.rect(x, y, 20, 20, col(M.prim))
  ui.frame_rect(x, y, 20, 20, st.accent)
  ui.rect(x + 24, y, 16, 16, { 0.25, 0.25, 0.29, 1 }); ui.rect(x + 24, y, 16, 16, col(M.sec))
  ui.frame_rect(x + 24, y, 16, 16, st.panel_edge)
  if ui.button("swap", { rect = { x + 44, y, cw - 44, 9 }, id = "st_swap" }) then
    M.prim, M.sec = M.sec, M.prim; M.set_prim(M.prim)
  end
  ui.text(x + 44, y + 11, "L / R  (X)", st.text_dim)
  y = y + 24

  if not M.sv_tex or M.sv_hue ~= M.hsv.h then rebuild_sv() end
  if not M.hue_tex then build_hue() end
  local sq = 84
  pal.quad(x, y, sq, sq, 1, 1, 1, 1, M.sv_tex, 0, 0, 1, 1)
  ui.frame_rect(x - 1, y - 1, sq + 2, sq + 2, st.panel_edge)
  local hx = x + sq + 4
  pal.quad(hx, y, 12, sq, 1, 1, 1, 1, M.hue_tex, 0, 0, 1, 1)
  ui.frame_rect(hx - 1, y - 1, 14, sq + 2, st.panel_edge)
  -- drag picks (continues past the widget edges while the button is held)
  if inp.clicked[1] and pin(inp.mx, inp.my, x, y, sq, sq) then M.pick = "sv" end
  if inp.clicked[1] and pin(inp.mx, inp.my, hx, y, 12, sq) then M.pick = "hue" end
  if not inp.buttons[1] then M.pick = nil end
  if M.pick == "sv" then
    M.hsv.s = clamp((inp.mx - x) / (sq - 1), 0, 1)
    M.hsv.v = clamp(1 - (inp.my - y) / (sq - 1), 0, 1)
    M.prim = paint.hsv(M.hsv.h, M.hsv.s, M.hsv.v)
  elseif M.pick == "hue" then
    M.hsv.h = clamp((inp.my - y) / (sq - 1), 0, 1)
    M.prim = paint.hsv(M.hsv.h, M.hsv.s, M.hsv.v)
  end
  -- cursors
  local sxp, syp = x + floor(M.hsv.s * (sq - 1)), y + floor((1 - M.hsv.v) * (sq - 1))
  ui.frame_rect(sxp - 2, syp - 2, 5, 5, { 0, 0, 0, 1 })
  ui.frame_rect(sxp - 1, syp - 1, 3, 3, { 1, 1, 1, 1 })
  ui.frame_rect(hx - 1, y + floor(M.hsv.h * (sq - 1)) - 1, 14, 3, { 1, 1, 1, 1 })
  y = y + sq + 5

  -- hex entry (synced to prim when not being typed into)
  if ui.focus ~= "st_hex" then M.hex_edit = hexstr(M.prim) end
  local newhex, hchanged, hsub = ui.text_input("st_hex", M.hex_edit or hexstr(M.prim),
    { hint = "#rrggbb", rect = { x, y, cw, 11 } })
  M.hex_edit = newhex
  if hchanged or hsub then
    local p = parse_hex(newhex)
    if p then M.set_prim(p) end
  end
  y = y + 11

  -- measure the content, reset the clip, draw a scroll thumb when it overflows
  local content_h = y - (r.y - M.dock_scroll)
  M.dock_over = max(0, content_h - (r.h - 6))
  pal.clip()
  if M.dock_over > 0 then
    local trk = r.h - 4
    local th = max(10, trk * trk // content_h)
    local ty = r.y + 2 + floor((trk - th) * (M.dock_scroll / M.dock_over))
    ui.rect(r.x + r.w - 3, ty, 2, th, st.accent)
  end
end

local function draw_menu(r)
  local st = ui.style
  ui.rect(r.x, r.y, r.w, r.h, st.title)
  ui.rect(r.x, r.y + r.h - 1, r.w, 1, st.panel_edge)
  ui.text(r.x + 3, r.y + 3, "STUDIO", st.accent)
  local name = M.doc and (M.doc.name ..
    ("  %dx%d  %d/%d"):format(M.doc.w, M.doc.h, M.doc.cur_frame, M.doc.frames))
    or "no document"
  ui.text(r.x + 52, r.y + 3, name .. (M.doc and M.doc.dirty and " *" or ""), st.text)
  -- right-aligned actions
  local acts = { { "browse", M.open_browser }, { "new", function() M.new_doc(32, 32) end },
                 { "save", M.save }, { "close", function() M.on = false end } }
  local bw = 40
  local bx = r.x + r.w - (bw + 2) * #acts - 2
  for i, a in ipairs(acts) do
    if ui.button(a[1], { rect = { bx + (i - 1) * (bw + 2), r.y + 1, bw, r.h - 2 },
                         id = "st_mb" .. i }) then a[2]() end
  end
end

-- the asset browser overlay (modal): a grid of baked thumbnails from the
-- project's art dir; click opens, plus new / refresh / close.
local function draw_browser(uw, uh)
  local st = ui.style
  ui.capture_mouse(); ui.capture_keys()
  ui.rect(0, 0, uw, uh, { 0.05, 0.05, 0.07, 1 })
  local proj = (cm.main and cm.main.args and cm.main.args.project) or "?"
  ui.text(8, 7, "ASSET BROWSER", st.accent)
  ui.text(8 + 15 * st.gw, 7, proj .. "/art", st.text_dim)
  local bw = 50
  local acts = { { "new", function() M.new_doc(32, 32); M.browser = false end },
                 { "refresh", M.scan_assets }, { "close", function() M.browser = false end } }
  for i, a in ipairs(acts) do
    if ui.button(a[1], { rect = { uw - (bw + 2) * (#acts - i + 1) - 6, 4, bw, 12 },
                         id = "br_act" .. i }) then a[2]() end
  end
  local items = M.browse_items or {}
  if #items == 0 then
    ui.text(8, 32, "no .spr assets yet — paint one and Save, then it appears here.",
            st.text_dim)
    return
  end
  local cell, gap = 76, 12
  local cols = max(1, (uw - 16) // (cell + gap))
  for i, it in ipairs(items) do
    local cx = 8 + ((i - 1) % cols) * (cell + gap)
    local cy = 26 + ((i - 1) // cols) * (cell + gap + 10)
    local clicked, hot = ui.hit("br_it" .. i, cx, cy, cell, cell)
    ui.rect(cx, cy, cell, cell, hot and st.widget_hot or st.widget)
    local s = min((cell - 10) / it.w, (cell - 10) / it.h)
    local dw, dh = max(1, floor(it.w * s)), max(1, floor(it.h * s))
    local tx, ty = cx + (cell - dw) // 2, cy + (cell - dh) // 2
    ui.rect(tx, ty, dw, dh, { 0.18, 0.18, 0.21, 1 }) -- transparency backdrop
    pal.quad(tx, ty, dw, dh, 1, 1, 1, 1, it.tex, 0, 0, 1, 1)
    ui.frame_rect(cx, cy, cell, cell, hot and st.accent or st.panel_edge)
    ui.text(cx, cy + cell + 1, it.name, st.text_dim)
    if clicked then
      local doc = sprite.load(it.path)
      if doc then M.doc, M.dirty, M.need_fit, M.browser = doc, true, true, false end
    end
  end
end

local function draw_timeline(r)
  local st = ui.style
  ui.rect(r.x, r.y, r.w, r.h, st.panel)
  ui.rect(r.x, r.y, r.w, 1, st.panel_edge)
  ui.text(r.x + 4, r.y + (r.h - st.gh) // 2, "TIMELINE", st.text_dim)
  ui.text(r.x + 64, r.y + (r.h - st.gh) // 2,
          "frame 1/1   (animation: phase 4)", st.text_dim)
  -- right side: tool (+ shape dims / fill mode) + cursor + zoom status
  local tool = M.alt and "pick" or M.tool
  local extra = ""
  if M.shape_drawing then
    local sx, sy, ex, ey = resolve_shape()
    extra = ("  %dx%d"):format(math.abs(ex - sx) + 1, math.abs(ey - sy) + 1)
  elseif SHAPE[tool] then
    extra = M.fill_shapes and "  fill" or "  outl"
  end
  local dpx, dpy = M.doc_pixel(ui.inp.mx, ui.inp.my)
  local stat = ("%s%s   %s   %dx"):format(
    tool, extra, dpx and (dpx .. "," .. dpy) or "--,--", M.zoom)
  ui.text(r.x + r.w - #stat * st.gw - 4, r.y + (r.h - st.gh) // 2, stat, st.text)
end

-- ---- per-tick entry (cm.main: after editor.frame, on the ui canvas) ----

function M.frame()
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep and k.scancode == KEY_F2 then M.toggle() end
  end
  if not M.on then return end
  if M.locked() then M.on = false; return end
  ui.capture_mouse()
  ui.capture_keys()
  if not M.doc then M.new_doc(32, 32) end
  if not M.palettes then M.load_palettes() end

  local uw, uh = view.surface_size()
  if M.browser then draw_browser(uw, uh); return end -- modal overlay
  local body_h = uh - MENU_H - TIME_H
  M.menu = { x = 0, y = 0, w = uw, h = MENU_H }
  M.rail = { x = 0, y = MENU_H, w = RAIL_W, h = body_h }
  M.dock = { x = uw - DOCK_W, y = MENU_H, w = DOCK_W, h = body_h }
  M.canvas = { x = RAIL_W, y = MENU_H, w = uw - RAIL_W - DOCK_W, h = body_h }
  M.time = { x = 0, y = uh - TIME_H, w = uw, h = TIME_H }
  if M.need_fit then M.fit(); M.need_fit = nil end

  handle_keys()
  local over = pin(ui.inp.mx, ui.inp.my, M.canvas.x, M.canvas.y, M.canvas.w, M.canvas.h)
  handle_zoom(over)
  handle_pan()
  handle_paint(over)
  build_preview()
  if M.dirty or not M.canvas_tex then M.rebuild_tex() end

  ui.rect(0, 0, uw, uh, { 0.05, 0.05, 0.07, 1 }) -- opaque base hides the game
  draw_canvas(M.canvas)
  draw_menu(M.menu)
  draw_rail(M.rail)
  draw_dock(M.dock)
  draw_timeline(M.time)
end

return M
