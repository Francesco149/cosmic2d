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
M.tool = M.tool or "pencil" -- pencil | eraser | fill | pick
M.prim = M.prim or paint.pack(246, 248, 252) -- primary color (LMB)
M.sec = M.sec or paint.pack(32, 28, 44) -- secondary color (RMB)
M.dirty = true -- the canvas composite texture needs a rebuild
M.alt, M.ctrl = false, false

-- layout metrics (ui-canvas px); regions computed each frame from these
local MENU_H, RAIL_W, DOCK_W, TIME_H = 14, 22, 116, 24
local SWATCH = 12

-- scancodes
local KEY_F2 = 59
local ALT_L, ALT_R, CTRL_L, CTRL_R = 226, 230, 224, 228
local SC = { z = 29, y = 28, s = 22, b = 5, e = 8, g = 10, i = 12, x = 27 }

local TOOLS = {
  { id = "pencil", key = "B", tip = "pencil" },
  { id = "eraser", key = "E", tip = "eraser" },
  { id = "fill",   key = "G", tip = "bucket fill" },
  { id = "pick",   key = "I", tip = "eyedropper (or hold Alt)" },
}

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
  for _, k in ipairs(ui.inp.keys) do
    local sc = k.scancode
    if sc == ALT_L or sc == ALT_R then M.alt = k.down end
    if sc == CTRL_L or sc == CTRL_R then M.ctrl = k.down end
    if k.down and not k.rep then
      if M.ctrl then
        if sc == SC.z then sprite.undo(M.doc); M.dirty = true
        elseif sc == SC.y then sprite.redo(M.doc); M.dirty = true
        elseif sc == SC.s then M.save() end
      elseif sc == SC.b then M.tool = "pencil"
      elseif sc == SC.e then M.tool = "eraser"
      elseif sc == SC.g then M.tool = "fill"
      elseif sc == SC.i then M.tool = "pick"
      elseif sc == SC.x then M.prim, M.sec = M.sec, M.prim end
    end
  end
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

  if tool == "pick" then
    if over and pressed and dpx then
      local c = paint.get(M.cell(), dpx, dpy)
      if which == "prim" then M.prim = c else M.sec = c end
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

local function draw_dock(r)
  local st = ui.style
  ui.rect(r.x, r.y, r.w, r.h, st.panel)
  ui.frame_rect(r.x, r.y, r.w, r.h, st.panel_edge)
  local x, y = r.x + 4, r.y + 4
  ui.text(x, y, "PALETTE", st.accent); y = y + 11
  local cols = (r.w - 8) // (SWATCH + 1)
  for i, c in ipairs(M.doc.palette) do
    local cx = x + ((i - 1) % cols) * (SWATCH + 1)
    local cy = y + ((i - 1) // cols) * (SWATCH + 1)
    swatch(c, cx, cy)
  end
  y = y + (ceil(#M.doc.palette / cols)) * (SWATCH + 1) + 6

  ui.text(x, y, "COLOR", st.accent); y = y + 11
  -- primary / secondary chips (LMB / RMB) + hex
  ui.rect(x, y, 18, 18, { 0.25, 0.25, 0.29, 1 }); ui.rect(x, y, 18, 18, col(M.prim))
  ui.frame_rect(x, y, 18, 18, st.accent)
  ui.rect(x + 22, y, 14, 14, { 0.25, 0.25, 0.29, 1 }); ui.rect(x + 22, y, 14, 14, col(M.sec))
  ui.frame_rect(x + 22, y, 14, 14, st.panel_edge)
  ui.text(x + 42, y, "L", st.text_dim); ui.text(x + 42, y + 9, "R", st.text_dim)
  ui.text(x, y + 21, hexstr(M.prim), st.text)
  if ui.button("swap (X)", { rect = { x, y + 32, r.w - 8, 12 } }) then
    M.prim, M.sec = M.sec, M.prim
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
  local bw = 34
  local bx = r.x + r.w - (bw + 2) * 3 - 2
  if ui.button("new", { rect = { bx, r.y + 1, bw, r.h - 2 } }) then M.new_doc(32, 32) end
  if ui.button("save", { rect = { bx + bw + 2, r.y + 1, bw, r.h - 2 } }) then M.save() end
  if ui.button("close", { rect = { bx + (bw + 2) * 2, r.y + 1, bw, r.h - 2 } }) then
    M.on = false
  end
end

local function draw_timeline(r)
  local st = ui.style
  ui.rect(r.x, r.y, r.w, r.h, st.panel)
  ui.rect(r.x, r.y, r.w, 1, st.panel_edge)
  ui.text(r.x + 4, r.y + (r.h - st.gh) // 2, "TIMELINE", st.text_dim)
  ui.text(r.x + 64, r.y + (r.h - st.gh) // 2,
          "frame 1/1   (animation: phase 4)", st.text_dim)
  -- right side: tool + cursor + zoom status
  local dpx, dpy = M.doc_pixel(ui.inp.mx, ui.inp.my)
  local stat = ("%s   %s   %dx"):format(
    (M.alt and "pick" or M.tool),
    dpx and (dpx .. "," .. dpy) or "--,--", M.zoom)
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

  local uw, uh = view.surface_size()
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
  if M.dirty or not M.canvas_tex then M.rebuild_tex() end

  ui.rect(0, 0, uw, uh, { 0.05, 0.05, 0.07, 1 }) -- opaque base hides the game
  draw_canvas(M.canvas)
  draw_menu(M.menu)
  draw_rail(M.rail)
  draw_dock(M.dock)
  draw_timeline(M.time)
end

return M
