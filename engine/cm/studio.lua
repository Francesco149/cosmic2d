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
local anim = cm.require("cm.anim")

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

-- gradient-tool state: the params a NEW fill inherits (last-used), + the panel's
-- selected ramp stop (a reference into the active fill, validated each draw).
M.g_type = M.g_type or "linear"
M.g_levels = M.g_levels or 8
M.g_dither = M.g_dither or 0.6
M.g_bayer = M.g_bayer or 4
M.g_phase = M.g_phase or 0
M.g_sel = M.g_sel -- the selected stop table, or nil

-- animation / timeline state (Phase 4, STUDIO.md §7): the preview fps, the
-- onion-skin toggle, the active clip (dock CLIPS selection) + the selected
-- frame-entry within it, the live-playback flag + its WALL-CLOCK anchor (dev
-- only, pal.time_ns — never sim), and the strip's horizontal scroll.
M.fps = M.fps or 12
M.onion = M.onion or false
M.playing = M.playing or false
M.play_t0 = M.play_t0 or 0
M.clip_i = M.clip_i           -- active clip index, or nil
M.clip_entry = M.clip_entry   -- selected entry index within the active clip
M.tl_scroll = M.tl_scroll or 0

-- layout metrics (ui-canvas px); regions computed each frame from these
local MENU_H, RAIL_W, DOCK_W, TIME_H = 14, 22, 116, 46
local SWATCH = 12
local LROW = 12 -- a layers-panel row

-- scancodes
local KEY_F2 = 59
local ALT_L, ALT_R, CTRL_L, CTRL_R = 226, 230, 224, 228
local SHIFT_L, SHIFT_R = 225, 229
local KEY_RET, KEY_DEL, KEY_BKSP = 40, 76, 42
local KEY_LBRK, KEY_RBRK = 47, 48
local SC = { z = 29, y = 28, s = 22, b = 5, e = 8, g = 10, i = 12, x = 27,
             l = 15, r = 21, o = 18, f = 9, m = 16, v = 25, c = 6, d = 7,
             h = 11, j = 13 }

local TOOLS = {
  { id = "pencil",  key = "B", tip = "pencil" },
  { id = "eraser",  key = "E", tip = "eraser" },
  { id = "fill",    key = "G", tip = "bucket fill" },
  { id = "line",    key = "L", tip = "line (Shift = 45°)" },
  { id = "rect",    key = "R", tip = "rectangle (Shift = square)" },
  { id = "ellipse", key = "O", tip = "ellipse (Shift = circle)" },
  { id = "gradient", key = "D", tip = "gradient fill (drag an axis)" },
  { id = "pick",    key = "I", tip = "eyedropper (or hold Alt)" },
  { id = "select",  key = "M", tip = "marquee select" },
  { id = "move",    key = "V", tip = "move selection / float" },
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
  if M.reset_sel then M.reset_sel() end
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
  if doc then M.doc, M.dirty, M.need_fit = doc, true, true; M.reset_sel() end
  if not M.doc then M.new_doc(32, 32) end
  M.toggle(true)
end

-- launch the studio as a top-level session — the `--studio` boot flag and the
-- `cm.studio.launch()` console one-liner both land here. With no argument it
-- enters the mode and drops into the asset browser (the project's art picker, or
-- a blank canvas if there are none). An optional `asset` (a bare name resolved
-- under <project>/art, or an explicit path) opens straight into that document.
function M.launch(asset)
  M.toggle(true)
  if not M.on then pal.log("[studio] disabled (project locks the editor)"); return end
  if asset then
    local p = tostring(asset)
    if not p:match("/") then
      local proj = (cm.main and cm.main.args and cm.main.args.project) or "projects/sandbox"
      p = proj .. "/art/" .. p
    end
    if not p:match("%.spr$") then p = p .. ".spr" end
    local doc, err = sprite.load(p)
    if doc then M.open(doc)
    else pal.log("[studio] can't open " .. p .. ": " .. tostring(err)) end
    return
  end
  M.open_browser()
  if M.browse_items and #M.browse_items == 0 then M.browser = false end -- blank canvas
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

-- a gradient screenshot / smoke aid: the motif on a base layer, plus a 2nd
-- layer with a blob recolored by a multi-stop radial gradient fill (handles
-- shown, gradient tool armed). Dev-only, not undo-managed beyond the ops it runs.
function M.demo_gradient()
  M.toggle(true)
  M.new_doc(32, 32)
  M.demo()
  local P = paint.pack
  local l = sprite.add_layer(M.doc, "glow")
  paint.ellipse(l.cells[1], 4, 16, 27, 30, P(255, 255, 255), true) -- a blob to mask
  sprite.set_fill(M.doc, M.doc.cur_layer, {
    type = "radial", p0 = { x = 16, y = 23 }, p1 = { x = 28, y = 23 },
    stops = { { pos = 0, rgba = P(108, 220, 250) }, { pos = 0.5, rgba = P(248, 214, 122) },
              { pos = 1, rgba = P(210, 110, 120) } },
    levels = 6, dither = 0.7, bayer = 4, phase = 0 })
  M.tool, M.dirty = "gradient", true
end

-- an animation smoke / screenshot aid: a 4-frame doc with a little breathing
-- bob + leg swing, a pingpong "idle" clip, onion on, frame 2 selected — so the
-- timeline strip, the onion overlay, and the CLIPS panel all show content.
function M.demo_anim()
  M.toggle(true)
  M.new_doc(24, 24)
  local P = paint.pack
  for _ = 1, 3 do sprite.add_frame(M.doc) end -- 4 frames total
  local body, shade, ink, cyan = P(236, 232, 245), P(150, 156, 196), P(32, 28, 44), P(108, 220, 250)
  for f = 1, 4 do
    local c = M.doc.layers[1].cells[f]
    local bob = (f % 2 == 0) and 1 or 0 -- a 1px breath
    paint.ellipse(c, 6, 2 + bob, 17, 15 + bob, body, true)
    paint.ellipse(c, 6, 2 + bob, 17, 15 + bob, shade, false)
    paint.rect(c, 9, 6 + bob, 2, 2, ink, true); paint.rect(c, 13, 6 + bob, 2, 2, ink, true)
    paint.line(c, 9, 17, 9 - (f - 1) % 2 * 3, 22, cyan)  -- legs swing
    paint.line(c, 14, 17, 14 + (f - 1) % 2 * 3, 22, cyan)
  end
  local clip = sprite.add_clip(M.doc, "idle", 8)
  clip.loop = "pingpong"
  M.clip_i, M.clip_entry = 1, 1
  M.onion, M.doc.cur_frame, M.dirty = true, 2, true
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

-- fractional doc coords under a ui point (gradient handles want sub-pixel
-- precision so the axis doesn't snap-jitter while dragging).
function M.doc_pt(mx, my)
  local r = M.canvas
  return (mx - r.x - M.pan_x) / M.zoom, (my - r.y - M.pan_y) / M.zoom
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

-- ---- animation: the active clip, the displayed frame, playback ----

-- the active clip table (dock CLIPS selection), or nil — re-fetched each use so
-- a delete / undo that drops it is handled by the nil branch.
function M.active_clip()
  return M.clip_i and M.doc.clips[M.clip_i] or nil
end

-- the 1-based cell to DISPLAY: while playing, the active clip's (or, with none,
-- the all-frames cycle's) frame at the wall clock — pal.time_ns scaled to 60
-- ticks/s so the preview matches how the game runs the clip (dev-only, never
-- sim, STUDIO.md §1/§7). Otherwise the edit cursor.
function M.disp_frame()
  local doc = M.doc
  if not M.playing then return doc.cur_frame end
  local ticks = floor((pal.time_ns() - M.play_t0) / 1e9 * 60)
  local clip = M.active_clip()
  if clip and #clip.frames > 0 then
    return clamp(anim.frame_at(clip, ticks) + 1, 1, doc.frames) -- 0-based → cell
  end
  local per = max(1, floor(60 / max(1, M.fps)))
  return (floor(ticks / per) % doc.frames) + 1
end

function M.toggle_play()
  M.playing = not M.playing
  if M.playing then M.play_t0 = pal.time_ns() end
  M.dirty = true
end

-- free the timeline thumbnail + onion neighbor textures (a new/loaded doc, a
-- frame-count change, or closing). The ids leak otherwise (no in-place update).
local function free_anim_tex()
  if M.thumbs then for _, t in ipairs(M.thumbs) do pal.tex_free(t) end; M.thumbs = nil end
  if M.onion_prev then pal.tex_free(M.onion_prev); M.onion_prev = nil end
  if M.onion_next then pal.tex_free(M.onion_next); M.onion_next = nil end
end
M.free_anim_tex = free_anim_tex

-- composite frame `fi` into the reuse scratch + upload a fresh texture (caller
-- owns it). Used for onion neighbors + the per-frame thumbnails.
local function comp_tex(doc, fi, scratch)
  sprite.composite_into(doc, fi, scratch)
  return pal.tex_create(doc.w, doc.h, scratch.buf:str(0, doc.w * doc.h * 4))
end

function M.rebuild_tex()
  local doc = M.doc
  if not M.comp or M.comp.w ~= doc.w or M.comp.h ~= doc.h then
    M.comp = paint.image(doc.w, doc.h)
  end
  sprite.composite_into(doc, M.disp_frame(), M.comp)
  if M.canvas_tex then pal.tex_free(M.canvas_tex) end
  M.canvas_tex = pal.tex_create(doc.w, doc.h, M.comp.buf:str(0, doc.w * doc.h * 4))
  -- M.comp is now uploaded; reuse it as the composite scratch below.
  -- onion neighbors (prev/next frame at low alpha) — edit-time only
  if M.onion_prev then pal.tex_free(M.onion_prev); M.onion_prev = nil end
  if M.onion_next then pal.tex_free(M.onion_next); M.onion_next = nil end
  if M.onion and not M.playing and doc.frames > 1 then
    if doc.cur_frame > 1 then M.onion_prev = comp_tex(doc, doc.cur_frame - 1, M.comp) end
    if doc.cur_frame < doc.frames then M.onion_next = comp_tex(doc, doc.cur_frame + 1, M.comp) end
  end
  -- per-frame thumbnails for the timeline strip (skip during playback — pixels
  -- aren't changing then, only the playhead moves; but always build once so a
  -- play started right after creation still has a strip)
  if not M.playing or not M.thumbs then
    if M.thumbs then for _, t in ipairs(M.thumbs) do pal.tex_free(t) end end
    M.thumbs = {}
    for f = 1, doc.frames do M.thumbs[f] = comp_tex(doc, f, M.comp) end
  end
  M.dirty = false
end

-- ---- selection + floating selection + clipboard (Phase 2) ----
-- M.sel = {x,y,w,h} marquee (doc px). M.float = {img,x,y,w,h} a lifted/pasted
-- selection drawn OVER the canvas, not yet stamped in. M.clip = the clipboard.

local function free_float_tex()
  if M.float_tex then pal.tex_free(M.float_tex); M.float_tex = nil end
end

local function build_float_tex()
  local f = M.float
  if not f then return end
  free_float_tex()
  M.float_tex = pal.tex_create(f.w, f.h, f.img.buf:str(0, f.w * f.h * 4))
end

-- drop all selection state (a new / loaded doc, or an explicit deselect); also
-- the animation playhead + per-doc timeline textures (frame count may change).
function M.reset_sel()
  M.sel, M.float, M.selecting, M.moving = nil, nil, false, false
  M.grad_drag, M.g_sel = nil, nil
  M.clip_i, M.clip_entry, M.playing, M.tl_scroll = nil, nil, false, 0
  free_float_tex()
  free_anim_tex()
end

-- stamp the floating selection into the active cell (one undo step); the
-- selection rect follows it so you can keep nudging.
function M.commit_float()
  local f = M.float
  if not f then return end
  sprite.begin_edit(M.doc)
  paint.blit(M.cell(), floor(f.x), floor(f.y), f.img, 0, 0, f.w, f.h, "stamp")
  sprite.end_edit(M.doc)
  M.sel = { x = floor(f.x), y = floor(f.y), w = f.w, h = f.h }
  M.float = nil
  free_float_tex()
  M.dirty = true
end

-- lift the current selection off the layer into a float (cuts a hole)
function M.lift_selection()
  local s = M.sel
  if not s or M.float then return end
  local img = paint.copy_region(M.cell(), s.x, s.y, s.w, s.h)
  sprite.begin_edit(M.doc)
  paint.rect(M.cell(), s.x, s.y, s.w, s.h, 0, true) -- clear the source region
  sprite.end_edit(M.doc)
  M.float = { img = img, x = s.x, y = s.y, w = s.w, h = s.h }
  build_float_tex()
  M.dirty = true
end

function M.copy()
  if M.float then M.clip = paint.copy_region(M.float.img, 0, 0, M.float.w, M.float.h)
  elseif M.sel then M.clip = paint.copy_region(M.cell(), M.sel.x, M.sel.y, M.sel.w, M.sel.h) end
end

function M.cut()
  if M.float then
    M.clip = paint.copy_region(M.float.img, 0, 0, M.float.w, M.float.h)
    M.float = nil; free_float_tex(); M.dirty = true
  elseif M.sel then
    M.clip = paint.copy_region(M.cell(), M.sel.x, M.sel.y, M.sel.w, M.sel.h)
    sprite.begin_edit(M.doc)
    paint.rect(M.cell(), M.sel.x, M.sel.y, M.sel.w, M.sel.h, 0, true)
    sprite.end_edit(M.doc)
    M.dirty = true
  end
end

function M.paste()
  if not M.clip then return end
  M.commit_float() -- land any existing float first
  local cw, ch = M.clip.w, M.clip.h
  local px = M.sel and M.sel.x or floor((M.doc.w - cw) / 2)
  local py = M.sel and M.sel.y or floor((M.doc.h - ch) / 2)
  M.float = { img = paint.copy_region(M.clip, 0, 0, cw, ch), x = px, y = py, w = cw, h = ch }
  build_float_tex()
  M.tool = "move"
  M.dirty = true
end

-- Delete: drop a float (its hole stays), else clear the selected region.
function M.clear_sel_region()
  if M.float then M.float = nil; free_float_tex(); M.dirty = true; return end
  if M.sel then
    sprite.begin_edit(M.doc)
    paint.rect(M.cell(), M.sel.x, M.sel.y, M.sel.w, M.sel.h, 0, true)
    sprite.end_edit(M.doc)
    M.dirty = true
  end
end

function M.deselect() M.commit_float(); M.sel = nil end

-- ---- transforms + custom brush (Phase 2) ----
-- A transform acts on the floating selection if one exists; else it lifts the
-- current selection into a float and acts on that; else it acts on the whole
-- active-layer cell (one undo step).

local function ensure_float_from_sel()
  if not M.float and M.sel then M.lift_selection() end
end

function M.flip(horiz)
  ensure_float_from_sel()
  if M.float then
    if horiz then paint.flip_h(M.float.img) else paint.flip_v(M.float.img) end
    build_float_tex()
  else
    sprite.begin_edit(M.doc)
    if horiz then paint.flip_h(M.cell()) else paint.flip_v(M.cell()) end
    sprite.end_edit(M.doc)
  end
  M.dirty = true
end

-- rotate 90° (dir +1 CW, -1 CCW). A float / selection rotates freely; the whole
-- cell only when the sprite is square (rotation swaps width and height).
function M.rotate(dir)
  ensure_float_from_sel()
  if M.float then
    M.float.img = paint.rotate90(M.float.img, dir)
    M.float.w, M.float.h = M.float.img.w, M.float.img.h
    build_float_tex()
  elseif M.doc.w == M.doc.h then
    local rot = paint.rotate90(M.cell(), dir)
    sprite.begin_edit(M.doc)
    M.cell().buf:copy(0, rot.buf, 0, M.doc.w * M.doc.h * 4)
    sprite.end_edit(M.doc)
  else
    pal.log("[studio] rotate: select a region (a non-square sprite can't rotate whole)")
    return
  end
  M.dirty = true
end

-- scale the float / selection by a factor (nearest, no AA). Whole-sprite resize
-- is a later feature (it changes the document dimensions).
function M.scale(factor)
  ensure_float_from_sel()
  if not M.float then
    pal.log("[studio] scale: select a region first (whole-sprite resize is later)")
    return
  end
  local nw, nh = max(1, floor(M.float.w * factor)), max(1, floor(M.float.h * factor))
  M.float.img = paint.scale(M.float.img, nw, nh)
  M.float.w, M.float.h = nw, nh
  build_float_tex()
  M.dirty = true
end

-- a custom brush captured from the selection / float (sprite-as-brush); the
-- pencil then stamps it (alpha-masked). clear_brush returns to the 1px pencil.
function M.brush_from_sel()
  if M.float then M.brush = paint.copy_region(M.float.img, 0, 0, M.float.w, M.float.h)
  elseif M.sel then M.brush = paint.copy_region(M.cell(), M.sel.x, M.sel.y, M.sel.w, M.sel.h)
  else return end
  M.tool = "pencil"
end

function M.clear_brush() M.brush = nil end

-- ---- gradient tool (Phase 3, STUDIO.md §6) ----
-- A drag lays a non-destructive gradient FILL onto the active layer (masked by
-- its pixels); the two endpoints are then live-draggable handles, and the dock
-- panel tunes type / ramp / dither / levels / phase. A new fill inherits the
-- last-used params (M.g_*) and starts as a prim→sec 2-stop ramp. The whole axis
-- drag is one undo step (a struct bracket spanning frames; cm.sprite).

local function make_fill(px, py)
  return {
    type = M.g_type, p0 = { x = px, y = py }, p1 = { x = px, y = py },
    stops = { { pos = 0, rgba = M.prim }, { pos = 1, rgba = M.sec } },
    levels = M.g_levels, dither = M.g_dither, bayer = M.g_bayer, phase = M.g_phase,
  }
end

local function near_pt(mx, my, sx, sy, rad)
  local dx, dy = mx - sx, my - sy
  return dx * dx + dy * dy <= rad * rad
end

-- press: grab an endpoint handle of the active fill, else start a fresh axis
-- (creating the fill); drag: move that endpoint live; release: one undo step.
local function handle_gradient(over)
  local inp, doc = ui.inp, M.doc
  local L = doc.layers[doc.cur_layer]
  local r, z = M.canvas, M.zoom
  local ix, iy = r.x + floor(M.pan_x), r.y + floor(M.pan_y)
  if not M.grad_drag and inp.clicked[1] and over and not ui.active then
    local f = L.fill
    if f and near_pt(inp.mx, inp.my, ix + f.p0.x * z, iy + f.p0.y * z, 7) then
      sprite.begin_struct(doc); M.grad_drag, M.grad_moved = "p0", false
    elseif f and near_pt(inp.mx, inp.my, ix + f.p1.x * z, iy + f.p1.y * z, 7) then
      sprite.begin_struct(doc); M.grad_drag, M.grad_moved = "p1", false
    else -- re-anchor the axis (keeping an existing ramp) or create a fresh fill
      local px, py = M.doc_pt(inp.mx, inp.my)
      sprite.begin_struct(doc)
      if f then f.p0.x, f.p0.y, f.p1.x, f.p1.y = px, py, px, py
      else L.fill, M.g_sel = make_fill(px, py), nil end
      M.grad_drag, M.grad_moved = "p1", true
    end
    M.dirty = true
  end
  if M.grad_drag and inp.buttons[1] and L.fill then
    local px, py = M.doc_pt(inp.mx, inp.my)
    local e = M.grad_drag == "p0" and L.fill.p0 or L.fill.p1
    if e.x ~= px or e.y ~= py then e.x, e.y, M.grad_moved = px, py, true end
    M.dirty = true
  elseif M.grad_drag and not inp.buttons[1] then
    M.grad_drag = nil
    if M.grad_moved then sprite.commit_struct(doc) else sprite.cancel_struct(doc) end
  end
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
        elseif sc == SC.s then M.save()
        elseif sc == SC.c then M.copy()
        elseif sc == SC.x then M.cut()
        elseif sc == SC.v then M.paste()
        elseif sc == SC.d then M.deselect() end
      elseif sc == SC.b then M.tool = "pencil"
      elseif sc == SC.e then M.tool = "eraser"
      elseif sc == SC.g then M.tool = "fill"
      elseif sc == SC.l then M.tool = "line"
      elseif sc == SC.r then M.tool = "rect"
      elseif sc == SC.o then M.tool = "ellipse"
      elseif sc == SC.d then M.tool = "gradient"
      elseif sc == SC.i then M.tool = "pick"
      elseif sc == SC.m then M.tool = "select"
      elseif sc == SC.v then M.tool = "move"
      elseif sc == SC.f then M.fill_shapes = not M.fill_shapes
      elseif sc == SC.h then M.flip(true)
      elseif sc == SC.j then M.flip(false)
      elseif sc == KEY_LBRK then M.rotate(-1)
      elseif sc == KEY_RBRK then M.rotate(1)
      elseif sc == KEY_RET then M.commit_float()
      elseif sc == KEY_DEL or sc == KEY_BKSP then M.clear_sel_region()
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
  local cell = M.cell()
  if M.brush and M.tool == "pencil" then
    -- a custom brush: stamp it (alpha-masked) along the stroke, centered
    local b = M.brush
    local ox, oy = b.w // 2, b.h // 2
    local function plot(img, x, y)
      paint.blit(img, x - ox, y - oy, b, 0, 0, b.w, b.h, "stamp")
    end
    if M.last_px then paint.line(cell, M.last_px, M.last_py, px, py, 0, plot)
    else plot(cell, px, py) end
  else
    local color = M.tool == "eraser" and 0 or (M.stroke == "prim" and M.prim or M.sec)
    if M.last_px then
      paint.line(cell, M.last_px, M.last_py, px, py, color)
    else
      paint.set(cell, px, py, color)
    end
  end
  M.last_px, M.last_py = px, py
  M.dirty = true
end

-- two corner pixels -> a normalized {x,y,w,h} clamped inside the image
local function norm_rect(ax, ay, bx, by, W, H)
  ax, bx = clamp(ax, 0, W - 1), clamp(bx, 0, W - 1)
  ay, by = clamp(ay, 0, H - 1), clamp(by, 0, H - 1)
  local x0, x1 = min(ax, bx), max(ax, bx)
  local y0, y1 = min(ay, by), max(ay, by)
  return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
end

-- the marquee (select) + move-the-float tools
local function handle_select(over)
  local inp = ui.inp
  local pressed = inp.clicked[1]
  local held = inp.buttons[1]
  if M.tool == "select" then
    if over and pressed and not ui.active then
      M.commit_float() -- a fresh marquee lands any floating selection first
      local px, py = M.doc_pixel_raw(inp.mx, inp.my)
      M.sel_ax, M.sel_ay, M.selecting = px, py, true
    end
    if M.selecting and held then
      local px, py = M.doc_pixel_raw(inp.mx, inp.my)
      M.sel = norm_rect(M.sel_ax, M.sel_ay, px, py, M.doc.w, M.doc.h)
    elseif M.selecting and not held then
      M.selecting = false
      if M.sel and (M.sel.w < 1 or M.sel.h < 1) then M.sel = nil end
    end
  elseif M.tool == "move" then
    if pressed and not ui.active then
      local px, py = M.doc_pixel_raw(inp.mx, inp.my)
      -- press inside the selection lifts it into a float (if not already)
      if not M.float and M.sel and px >= M.sel.x and px < M.sel.x + M.sel.w
         and py >= M.sel.y and py < M.sel.y + M.sel.h then
        M.lift_selection()
      end
      if M.float then
        M.grab_dx, M.grab_dy, M.moving = px - M.float.x, py - M.float.y, true
      end
    end
    if M.moving and held and M.float then
      local px, py = M.doc_pixel_raw(inp.mx, inp.my)
      M.float.x, M.float.y = px - M.grab_dx, py - M.grab_dy
    elseif M.moving and not held then
      M.moving = false
    end
  end
end

local function handle_paint(over)
  if M.playing then return end -- the canvas shows the playhead; no editing mid-play
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

  -- a gradient axis drag in progress owns the gesture until release (an Alt tap
  -- can't divert it), exactly like a shape stroke
  if M.grad_drag then handle_gradient(over); return end

  -- selection tools (Alt overrides them with the temporary eyedropper, below)
  if not M.alt and (M.tool == "select" or M.tool == "move") then
    handle_select(over); return
  end
  -- choosing a paint/shape tool lands any floating selection onto the layer
  if M.float and not (M.tool == "select" or M.tool == "move") then M.commit_float() end

  if tool == "gradient" then handle_gradient(over); return end

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

-- marching-ants rectangle (screen px): alternating 4px white/black dashes that
-- crawl with the render clock. Used for the selection + the floating selection.
local function draw_marquee(x, y, w, h)
  local t = ui.ticks // 6
  local function seg(px, py, horiz, len)
    local i = 0
    while i < len do
      local s = min(4, len - i)
      local on = (((i // 4) + t) % 2) == 0
      ui.rect(horiz and px + i or px, horiz and py or py + i,
              horiz and s or 1, horiz and 1 or s,
              on and { 1, 1, 1, 1 } or { 0, 0, 0, 1 })
      i = i + s
    end
  end
  seg(x, y, true, w); seg(x, y + h - 1, true, w)
  seg(x, y, false, h); seg(x + w - 1, y, false, h)
end

-- the gradient axis (a dotted connector) + its two draggable endpoint handles
-- (p0 = accent, p1 = white), plus a faint rim circle for a radial fill. Drawn in
-- screen space, clipped to the canvas region (handles can sit off the image).
local function draw_grad_handles(r, ix, iy, z, f)
  pal.clip(r.x, r.y, r.w, r.h)
  local p0x, p0y = ix + f.p0.x * z, iy + f.p0.y * z
  local p1x, p1y = ix + f.p1.x * z, iy + f.p1.y * z
  local dx, dy = p1x - p0x, p1y - p0y
  local dist = math.sqrt(dx * dx + dy * dy)
  local steps = max(1, floor(dist / 4))
  for i = 0, steps do
    local t = i / steps
    ui.rect(floor(p0x + dx * t), floor(p0y + dy * t), 1, 1, { 1, 1, 1, 0.55 })
  end
  if f.type == "radial" and dist > 1 then
    local n = max(16, floor(dist / 3))
    for i = 0, n - 1 do
      local a = i / n * 2 * math.pi
      ui.rect(floor(p0x + math.cos(a) * dist), floor(p0y + math.sin(a) * dist),
              1, 1, { 1, 1, 1, 0.3 })
    end
  end
  local function dot(sx, sy, c)
    ui.rect(sx - 3, sy - 3, 6, 6, { 0, 0, 0, 0.85 })
    ui.rect(sx - 2, sy - 2, 4, 4, c)
  end
  dot(floor(p0x), floor(p0y), ui.style.accent)
  dot(floor(p1x), floor(p1y), { 1, 1, 1, 1 })
  pal.clip()
end

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
  -- onion skin: the previous (warm) + next (cool) frame at low alpha, UNDER the
  -- current frame, so they peek through wherever the current cell is transparent
  if M.onion_prev then pal.quad(ix, iy, iw, ih, 1, 0.45, 0.5, 0.4, M.onion_prev, 0, 0, 1, 1) end
  if M.onion_next then pal.quad(ix, iy, iw, ih, 0.45, 0.8, 1, 0.4, M.onion_next, 0, 0, 1, 1) end
  -- the composited sprite as one scaled quad (alpha-over the checker, nearest)
  pal.quad(ix, iy, iw, ih, 1, 1, 1, 1, M.canvas_tex, 0, 0, 1, 1)
  -- the live shape preview rides on top as one more quad (no real pixels yet)
  if M.has_preview and M.preview_tex then
    pal.quad(ix, iy, iw, ih, 1, 1, 1, 1, M.preview_tex, 0, 0, 1, 1)
  end
  -- the floating selection (its pixels lifted/pasted, drawn over the canvas)
  -- and the selection marquee (ants follow the float when one is active)
  local sel = M.sel
  if M.float and M.float_tex then
    local f = M.float
    pal.quad(ix + floor(f.x) * z, iy + floor(f.y) * z, f.w * z, f.h * z,
             1, 1, 1, 1, M.float_tex, 0, 0, 1, 1)
    sel = { x = floor(f.x), y = floor(f.y), w = f.w, h = f.h }
  end
  if sel then draw_marquee(ix + sel.x * z, iy + sel.y * z, sel.w * z, sel.h * z) end
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
  -- gradient axis + endpoint handles (gradient tool active + this layer has a fill)
  local gl = M.doc.layers[M.doc.cur_layer]
  if M.tool == "gradient" and gl.fill then draw_grad_handles(r, ix, iy, z, gl.fill) end
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
  -- custom brush: capture from the selection (lit while a brush is active),
  -- and a clear-brush button back to the 1px pencil
  local by = fy + bh + 4
  local bon = M.brush ~= nil
  local bclick, bhot = ui.hit("tool/brush", r.x + 2, by, bw, bh)
  ui.rect(r.x + 2, by, bw, bh, bon and st.widget_active or (bhot and st.widget_hot or st.widget))
  ui.frame_rect(r.x + 2, by, bw, bh, bon and st.accent or st.panel_edge)
  ui.text(r.x + 2 + (bw - 3 * st.gw) // 2, by + (bh - st.gh) // 2, "brs",
          bon and st.accent or st.text)
  if bclick then M.brush_from_sel() end
  if ui.button("1px", { rect = { r.x + 2, by + bh + 2, bw, bh }, id = "tool/nobrush" }) then
    M.clear_brush()
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

-- GRADIENT: the active layer's non-destructive gradient fill — type, the
-- multi-stop ramp editor (a click on the bar adds a stop; markers select / drag /
-- right-click-delete), dither / levels / bayer / phase, then bake/clear. Drawn
-- only when the layer has a fill (or, as a hint, when the gradient tool is armed).
local function draw_gradient(x, y, cw)
  local st, inp = ui.style, ui.inp
  local doc = M.doc
  local L = doc.layers[doc.cur_layer]
  local f = L.fill
  if not f then
    if M.tool == "gradient" then
      ui.text(x, y, "GRADIENT", st.accent); y = y + 11
      ui.text(x, y, "drag an axis on the", st.text_dim); y = y + 9
      ui.text(x, y, "layer to add a fill", st.text_dim); y = y + 12
    end
    return y
  end
  -- the selected stop is held by reference; drop it if it left the ramp
  if M.g_sel then
    local found = false
    for _, s in ipairs(f.stops) do if s == M.g_sel then found = true; break end end
    if not found then M.g_sel = nil end
  end

  ui.text(x, y, "GRADIENT", st.accent); y = y + 11

  -- type selector
  local types = { { "lin", "linear" }, { "rad", "radial" },
                  { "ang", "angular" }, { "mir", "mirror" } }
  local tw = (cw - 3 * 2) // 4
  for i, t in ipairs(types) do
    local bx = x + (i - 1) * (tw + 2)
    local on = f.type == t[2]
    local clicked, hot = ui.hit("g_ty" .. i, bx, y, tw, 12)
    ui.rect(bx, y, tw, 12, on and st.widget_active or (hot and st.widget_hot or st.widget))
    ui.frame_rect(bx, y, tw, 12, on and st.accent or st.panel_edge)
    ui.text(bx + (tw - 3 * st.gw) // 2, y + 2, t[1], on and st.accent or st.text)
    if clicked then f.type, M.g_type, M.dirty = t[2], t[2], true end
  end
  y = y + 15

  -- the ramp bar (sampled columns; click adds a stop there)
  local barh = 12
  for cx = 0, cw - 1 do
    ui.rect(x + cx, y, 1, barh, col(paint.ramp(f.stops, cx / (cw - 1))))
  end
  ui.frame_rect(x, y, cw, barh, st.panel_edge)
  if pin(inp.mx, inp.my, x, y, cw, barh) and inp.clicked[1] then
    local s = { pos = clamp((inp.mx - x) / (cw - 1), 0, 1), rgba = M.prim }
    f.stops[#f.stops + 1] = s
    table.sort(f.stops, function(a, b) return a.pos < b.pos end)
    M.g_sel, M.g_drag_stop, M.dirty = s, s, true
  end
  y = y + barh + 1

  -- stop markers: select (LMB), drag (LMB-hold), delete (RMB, keep ≥2)
  local mrow = 8
  for _, s in ipairs(f.stops) do
    local sx = x + floor(s.pos * (cw - 1))
    local hot = pin(inp.mx, inp.my, sx - 3, y, 7, mrow)
    ui.rect(sx - 3, y, 7, mrow, col(s.rgba))
    ui.frame_rect(sx - 3, y, 7, mrow,
      s == M.g_sel and st.accent or (hot and st.widget_hot or st.panel_edge))
    if hot and inp.clicked[1] then M.g_sel, M.g_drag_stop = s, s end
    if hot and inp.clicked[3] and #f.stops > 2 then
      for j = #f.stops, 1, -1 do if f.stops[j] == s then table.remove(f.stops, j) end end
      if M.g_sel == s then M.g_sel = nil end
      M.dirty = true
    end
  end
  if M.g_drag_stop and inp.buttons[1] then
    M.g_drag_stop.pos = clamp((inp.mx - x) / (cw - 1), 0, 1)
    table.sort(f.stops, function(a, b) return a.pos < b.pos end)
    M.dirty = true
  elseif M.g_drag_stop and not inp.buttons[1] then
    M.g_drag_stop = nil
  end
  y = y + mrow + 2

  -- selected-stop actions (recolor to primary / delete)
  if M.g_sel then
    local half = (cw - 2) // 2
    if ui.button("set col", { rect = { x, y, half, 11 }, id = "g_setcol" }) then
      M.g_sel.rgba, M.dirty = M.prim, true
    end
    if ui.button("del", { rect = { x + half + 2, y, cw - half - 2, 11 }, id = "g_delstop" })
       and #f.stops > 2 then
      for j = #f.stops, 1, -1 do if f.stops[j] == M.g_sel then table.remove(f.stops, j) end end
      M.g_sel, M.dirty = nil, true
    end
  else
    ui.text(x, y, "click ramp: add stop", st.text_dim)
  end
  y = y + 13

  -- dither strength / levels / phase sliders (mirror to M.g_* for new fills)
  local lw = 4 * st.gw
  local nv, ch = ui.slider("dith", floor(f.dither * 100 + 0.5), 0, 100,
    { rect = { x, y, cw, 11 }, id = "g_dith", label_w = lw })
  if ch then f.dither, M.g_dither, M.dirty = nv / 100, nv / 100, true end
  y = y + 12
  nv, ch = ui.slider("lvl", f.levels, 2, 16, { rect = { x, y, cw, 11 }, id = "g_lvl", label_w = lw })
  if ch then f.levels, M.g_levels, M.dirty = nv, nv, true end
  y = y + 12
  nv, ch = ui.slider("phs", floor(f.phase * 100 + 0.5), 0, 100,
    { rect = { x, y, cw, 11 }, id = "g_phs", label_w = lw })
  if ch then f.phase, M.g_phase, M.dirty = nv / 100, nv / 100, true end
  y = y + 12

  -- bayer pattern size 2 / 4 / 8
  ui.text(x, y + 2, "bay", st.text_dim)
  local bxs = x + lw
  local bw3 = (cw - lw - 2 * 2) // 3
  for i, n in ipairs({ 2, 4, 8 }) do
    local bx = bxs + (i - 1) * (bw3 + 2)
    local on = f.bayer == n
    local clicked, hot = ui.hit("g_by" .. i, bx, y, bw3, 11)
    ui.rect(bx, y, bw3, 11, on and st.widget_active or (hot and st.widget_hot or st.widget))
    ui.frame_rect(bx, y, bw3, 11, on and st.accent or st.panel_edge)
    ui.text(bx + (bw3 - st.gw) // 2, y + 2, tostring(n), on and st.accent or st.text)
    if clicked then f.bayer, M.g_bayer, M.dirty = n, n, true end
  end
  y = y + 14

  -- bake the fill into pixels (destructive) / clear the fill object
  local half = (cw - 2) // 2
  if ui.button("bake", { rect = { x, y, half, 12 }, id = "g_stamp" }) then
    sprite.stamp_fill(doc, doc.cur_layer); M.g_sel, M.dirty = nil, true
  elseif ui.button("clear", { rect = { x + half + 2, y, cw - half - 2, 12 }, id = "g_clear" }) then
    sprite.clear_fill(doc, doc.cur_layer); M.g_sel, M.dirty = nil, true
  end
  return y + 16
end

-- CLIPS: the animation clips (STUDIO.md §7). The list (click = make active),
-- new / delete, and the active clip's editor — rename, loop mode, and the frame
-- SEQUENCE as chips (each an entry's 0-based frame index; click selects, RMB
-- removes), an "add the current frame" button, and the selected entry's
-- duration. The timeline's ▶play previews the active clip. Returns the next y.
local function draw_clips(x, y, cw)
  local st, inp = ui.style, ui.inp
  local doc = M.doc
  ui.text(x, y, "CLIPS", st.accent); y = y + 11

  local fdur = max(1, floor(60 / max(1, M.fps))) -- new entries default to fps
  local half = (cw - 2) // 2
  if ui.button("+ clip", { rect = { x, y, half, 12 }, id = "cl_new" }) then
    sprite.add_clip(doc, nil, fdur)
    M.clip_i, M.clip_entry = #doc.clips, nil
  end
  if ui.button("del", { rect = { x + half + 2, y, cw - half - 2, 12 }, id = "cl_del" })
     and M.clip_i then
    sprite.delete_clip(doc, M.clip_i)
    M.clip_i = (#doc.clips > 0) and min(M.clip_i, #doc.clips) or nil
    M.clip_entry = nil
  end
  y = y + 14

  if #doc.clips == 0 then
    ui.text(x, y, "no clips yet", st.text_dim); return y + 11
  end
  -- the clip list (active lit); the right edge shows the frame-entry count
  for ci, c in ipairs(doc.clips) do
    local active = ci == M.clip_i
    if ui.hit("cl_row" .. ci, x, y, cw, 11) then M.clip_i, M.clip_entry = ci, nil end
    ui.rect(x, y, cw, 11, active and st.widget_active or st.widget)
    ui.frame_rect(x, y, cw, 11, active and st.accent or st.panel_edge)
    ui.text(x + 2, y + 2, c.name, active and st.accent or st.text)
    local cnt = (#c.frames) .. "f"
    ui.text(x + cw - #cnt * st.gw - 3, y + 2, cnt, st.text_dim)
    y = y + 12
  end
  y = y + 2

  local clip = M.active_clip()
  if not clip then return y end

  -- rename (synced to the clip name when not being typed into)
  if ui.focus ~= "cl_name" then M.cl_name_edit = clip.name end
  local nm, nch, nsub = ui.text_input("cl_name", M.cl_name_edit or clip.name,
    { hint = "name", rect = { x, y, cw, 11 } })
  M.cl_name_edit = nm
  if (nch or nsub) and nm ~= "" then clip.name = nm; doc.dirty = true end
  y = y + 13

  -- loop mode
  local modes = { { "loop", "loop" }, { "once", "once" }, { "png", "pingpong" } }
  local mw = (cw - 2 * 2) // 3
  for i, mo in ipairs(modes) do
    local bx = x + (i - 1) * (mw + 2)
    local on = clip.loop == mo[2]
    local cl, ht = ui.hit("cl_lp" .. i, bx, y, mw, 12)
    ui.rect(bx, y, mw, 12, on and st.widget_active or (ht and st.widget_hot or st.widget))
    ui.frame_rect(bx, y, mw, 12, on and st.accent or st.panel_edge)
    ui.text(bx + (mw - #mo[1] * st.gw) // 2, y + 2, mo[1], on and st.accent or st.text)
    if cl then clip.loop, doc.dirty = mo[2], true end
  end
  y = y + 15

  -- the frame sequence: one chip per entry (its 0-based frame index). Click
  -- selects (for the dur slider); RMB removes (keeping ≥1).
  ui.text(x, y, "sequence", st.text_dim); y = y + 10
  local chw = 20
  local perrow = max(1, (cw + 2) // (chw + 2))
  for ei, e in ipairs(clip.frames) do
    local bx = x + ((ei - 1) % perrow) * (chw + 2)
    local by = y + ((ei - 1) // perrow) * 13
    local sel = M.clip_entry == ei
    local cl, ht = ui.hit("cl_e" .. ei, bx, by, chw, 11)
    ui.rect(bx, by, chw, 11, sel and st.widget_active or (ht and st.widget_hot or st.widget))
    ui.frame_rect(bx, by, chw, 11, sel and st.accent or st.panel_edge)
    ui.text(bx + (chw - #tostring(e.frame) * st.gw) // 2, by + 2, tostring(e.frame),
            sel and st.accent or st.text)
    if cl then M.clip_entry = ei end
    if ht and inp.clicked[3] and #clip.frames > 1 then
      table.remove(clip.frames, ei)
      M.clip_entry = nil; doc.dirty = true
    end
  end
  y = y + ceil(#clip.frames / perrow) * 13 + 1

  if ui.button("+ add frame " .. (doc.cur_frame - 1),
               { rect = { x, y, cw, 12 }, id = "cl_addf" }) then
    clip.frames[#clip.frames + 1] = { frame = doc.cur_frame - 1, dur = fdur }
    M.clip_entry, doc.dirty = #clip.frames, true
  end
  y = y + 14

  local e = M.clip_entry and clip.frames[M.clip_entry]
  if e then
    local nv, ch = ui.slider("dur", e.dur, 1, 60,
      { rect = { x, y, cw, 11 }, id = "cl_dur", label_w = 3 * st.gw })
    if ch then e.dur, doc.dirty = nv, true end
    y = y + 12
  end
  return y
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
  y = draw_gradient(x, y, cw)
  y = draw_clips(x, y, cw)

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
  -- edit cluster: flip / rotate / scale (the selection/float, else the layer)
  local xf = { { "fH", function() M.flip(true) end },  { "fV", function() M.flip(false) end },
               { "rL", function() M.rotate(-1) end },   { "rR", function() M.rotate(1) end },
               { "x2", function() M.scale(2) end },     { "/2", function() M.scale(0.5) end } }
  local xw = 18
  local xstart = bx - (xw + 1) * #xf - 6
  for i, a in ipairs(xf) do
    if ui.button(a[1], { rect = { xstart + (i - 1) * (xw + 1), r.y + 1, xw, r.h - 2 },
                         id = "st_xf" .. i }) then a[2]() end
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
      if doc then
        M.doc, M.dirty, M.need_fit, M.browser = doc, true, true, false
        M.reset_sel()
      end
    end
  end
end

-- the bottom timeline (STUDIO.md §5): the frame thumbnail strip (select / add /
-- dup / delete / reorder), the onion + fps + ▶play transport, and the tool /
-- cursor / zoom status. Clip AUTHORING lives in the dock CLIPS panel; play here
-- previews the active clip (or, with none, the whole strip at fps).
local function draw_timeline(r)
  local st, inp = ui.style, ui.inp
  local doc = M.doc
  ui.rect(r.x, r.y, r.w, r.h, st.panel)
  ui.rect(r.x, r.y, r.w, 1, st.panel_edge)

  -- right-side status (tool + shape dims / fill mode + cursor + zoom)
  local tool = M.alt and "pick" or M.tool
  if tool == "pencil" and M.brush then tool = "stamp" end
  local extra = ""
  if M.shape_drawing then
    local sx, sy, ex, ey = resolve_shape()
    extra = ("  %dx%d"):format(math.abs(ex - sx) + 1, math.abs(ey - sy) + 1)
  elseif SHAPE[tool] then
    extra = M.fill_shapes and "  fill" or "  outl"
  end
  local dpx, dpy = M.doc_pixel(inp.mx, inp.my)
  local stat = ("%s%s  %s  %dx"):format(
    tool, extra, dpx and (dpx .. "," .. dpy) or "--,--", M.zoom)
  ui.text(r.x + r.w - #stat * st.gw - 4, r.y + 4, stat, st.text)

  -- ---- frame thumbnail strip (top row) ----
  local th = 22
  local tw = clamp(floor(th * doc.w / doc.h), 8, 44)
  local strip_x, strip_y = r.x + 4, r.y + 3
  local strip_vw = max(60, r.w - 8 - (#stat * st.gw + 12))
  local maxscroll = max(0, doc.frames * (tw + 2) - strip_vw)
  if pin(inp.mx, inp.my, strip_x, strip_y, strip_vw, th) and inp.wheel ~= 0 then
    M.tl_scroll = clamp(M.tl_scroll - inp.wheel * (tw + 2), 0, maxscroll)
  end
  M.tl_scroll = clamp(M.tl_scroll, 0, maxscroll)
  local playhead = M.playing and M.disp_frame() or nil
  pal.clip(strip_x, strip_y, strip_vw, th)
  for f = 1, doc.frames do
    local bx = strip_x + (f - 1) * (tw + 2) - M.tl_scroll
    if bx + tw > strip_x and bx < strip_x + strip_vw then
      ui.rect(bx, strip_y, tw, th, { 0.18, 0.18, 0.21, 1 }) -- transparency backdrop
      if M.thumbs and M.thumbs[f] then
        pal.quad(bx, strip_y, tw, th, 1, 1, 1, 1, M.thumbs[f], 0, 0, 1, 1)
      end
      local border = (f == doc.cur_frame) and st.accent
        or (f == playhead and { 0.5, 0.9, 0.6, 1 }) or st.panel_edge
      ui.frame_rect(bx, strip_y, tw, th, border)
      if ui.hit("tl_f" .. f, bx, strip_y, tw, th) then
        M.playing, doc.cur_frame, M.dirty = false, f, true
      end
    end
  end
  pal.clip()

  -- ---- transport row ----
  local cy = r.y + th + 6
  local bx = r.x + 4
  local function btn(label, w, id)
    local clicked = ui.button(label, { rect = { bx, cy, w, 13 }, id = id })
    bx = bx + w + 2
    return clicked
  end
  if btn("+f", 18, "tl_add") then sprite.add_frame(doc); M.dirty = true end
  if btn("dup", 22, "tl_dup") then sprite.dup_frame(doc, doc.cur_frame); M.dirty = true end
  if btn("del", 22, "tl_del") then sprite.delete_frame(doc, doc.cur_frame); M.dirty = true end
  if btn("<", 13, "tl_l") then sprite.move_frame(doc, doc.cur_frame, -1); M.dirty = true end
  if btn(">", 13, "tl_r") then sprite.move_frame(doc, doc.cur_frame, 1); M.dirty = true end
  ui.text(bx + 2, cy + 3, ("f %d/%d"):format(doc.cur_frame, doc.frames), st.text)
  bx = bx + 2 + 8 * st.gw

  local function toggle(label, w, on, id)
    local cl, ht = ui.hit(id, bx, cy, w, 13)
    ui.rect(bx, cy, w, 13, on and st.widget_active or (ht and st.widget_hot or st.widget))
    ui.frame_rect(bx, cy, w, 13, on and st.accent or st.panel_edge)
    ui.text(bx + (w - #label * st.gw) // 2, cy + 3, label, on and st.accent or st.text)
    bx = bx + w + 2
    return cl
  end
  if toggle("onion", 38, M.onion, "tl_onion") then M.onion = not M.onion; M.dirty = true end
  local nv, ch = ui.slider("fps", M.fps, 1, 30,
    { rect = { bx, cy, 86, 13 }, id = "tl_fps", label_w = 3 * st.gw })
  if ch then M.fps = nv end
  bx = bx + 90
  if toggle(M.playing and "stop" or "play", 38, M.playing, "tl_play") then M.toggle_play() end
  local clip = M.active_clip()
  ui.text(bx + 2, cy + 3, clip and (clip.loop .. " " .. clip.name) or "all frames",
          st.text_dim)
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
  if M.playing then M.dirty = true end -- re-composite the playhead each tick
  if M.dirty or not M.canvas_tex then M.rebuild_tex() end

  ui.rect(0, 0, uw, uh, { 0.05, 0.05, 0.07, 1 }) -- opaque base hides the game
  draw_canvas(M.canvas)
  draw_menu(M.menu)
  draw_rail(M.rail)
  draw_dock(M.dock)
  draw_timeline(M.time)
end

return M
