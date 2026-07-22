-- tools/drive/tape-palette-tutorial.lua — drives win-palette.md's
-- "color-script a moonlit vale" walkthrough AS WRITTEN (HELPDOCS H3):
-- every picker, field, ramp, swatch operation, save, asset drag, and final
-- recolor through the real UI, with VERDICT probes and CROP lines.
--
-- THE CAPTURE RECIPE (HELPDOCS §3, chained on H1 — the final step uses the
-- sprite tutorial's hero as a real receiving surface):
--   1. fresh smoke copy:   cp -r projects/smoke <scratch>/smoke-h3
--   2. the H1 prologue:    bin/cosmic <scratch>/smoke-h3 --edit --headless \
--        --win 1280x800 --frames 900 --eval \
--        "dofile('tools/drive/tape-sprite-tutorial.lua')"
--      -> art/hero.spr is saved and its view-mode window persists.
--   3. full proof run:     bin/cosmic <scratch>/smoke-h3 --edit --headless \
--        --win 1280x800 --frames 700 --eval \
--        "dofile('tools/drive/tape-palette-tutorial.lua')" --shot <scratch>/full.png
--      -> every VERDICT line must read true.
--   4. screenshots are the tape's own frames AT 2x (D163). Repeat steps
--      1-2 on a FRESH copy per shot, then run step 3 with SHOT set and
--      --frames at the shot frame PLUS ONE (the drive plan fires one frame
--      behind the process counter), and crop to the logged CROP rect:
--        bin/cosmic <copy> ... --win 1280x1120 --frames 127 --eval \
--          "rawset(_G,'SHOT','palette-ramp'); dofile('tools/drive/tape-palette-tutorial.lua')" \
--          --shot raw.png
--        magick raw.png -crop WxH+X+Y media/palette-ramp@2x.png
--      Palette-window shots fit the REAL window around its content one frame
--      before capture (SHOT reruns only), so --win 1280x800 is ample. The
--      proof run and the tutorial steps never resize behind the user's back.
--   5. stage crops as media/<name>@2x.png (layout <=700x550), inspect each,
--      and push a montage to llm-feed with a title + taste-check note.
--
-- Shot frames (stable while the tape above them is unchanged):
--   f96  palette-pickers  · f126 palette-ramp
--   f166 palette-adopted  · f450 palette-finished
--   f650 palette-hero
local D = dofile("tools/drive/drive.lua")
local SC = D.SC
local paint = cm.require("cm.paint")
local palette = cm.require("cm.palette")

local PASS, FAIL = 0, 0
local function log(s) pal.log("[tape] " .. s) end
local function verdict(name, ok, extra)
  if ok then PASS = PASS + 1 else FAIL = FAIL + 1 end
  log("VERDICT " .. name .. " " .. tostring(ok)
      .. (extra and (" " .. extra) or ""))
end
local function probe(f, fn) D.at(f, fn) end
local function crop(name, x, y, w, h)
  log(("CROP %s %d %d %d %d"):format(name, math.floor(x), math.floor(y),
                                      math.floor(w), math.floor(h)))
end

-- The palette's ordinary 500px canvas is intentionally generous for large
-- grids, but these 5/16-color tutorial states use only its upper half. During
-- a named screenshot rerun only, move the real bottom border up around the
-- live controls; cropping the whole resized window keeps its rounded frame
-- instead of publishing hundreds of blank pixels. Each shot starts from its
-- own fresh H1 copy, so this capture-only layout never leaks to another step.
local function shot_fit(name, frame, h)
  if rawget(_G, "SHOT") ~= name then return end
  D.at(frame - 1, function()
    local r = D.win("palette")
    if r then r.win.h = h; cm.ed.touch() end
  end)
end

local PAL = "pal/moonlit-vale.pal"
local HERO = "art/hero.spr"

-- ---- palette-window geometry (mirrors win/palette.lua at live z) ----
local function P()
  local r = D.win("palette")
  if not r then return nil end
  return r, cm.ed.g.pw and cm.ed.g.pw[r.win.path], r.win
end

local function pgeo()
  local r, p, win = P()
  if not (r and p and p.doc) then return nil end
  local z, cols = r.z, p.doc.colors
  local g = { r = r, p = p, win = win, cols = cols, z = z }
  g.x0, g.y0 = r.cx + 6 * z, r.cy + 6 * z
  g.cw = r.cw - 12 * z
  g.px = math.max(4, 10 * z)
  local grid_h = r.ch * 0.40
  local sw = math.max(14, 26 * z)
  local gap
  while true do
    gap = math.max(1, math.floor(sw * 0.12))
    local per_try = math.max(1, math.floor(g.cw / (sw + gap)))
    if sw <= 8 or math.ceil(#cols / per_try) * (sw + gap) <= grid_h then break end
    sw = sw - 2
  end
  g.sw, g.gap = sw, gap
  g.per = math.max(1, math.floor(g.cw / (sw + gap)))
  local rows = math.ceil(#cols / g.per)
  g.ey = g.y0
         + math.min(rows, math.max(1, math.floor(grid_h / (sw + gap))))
           * (sw + gap) + 8 * z
  g.hx = g.x0 + 42 * z
  g.sy = g.ey + 40 * z
  g.sh = g.px * 1.5
  g.svy, g.svh = g.sy + g.sh + 2 * z, 84 * z
  if (win.pick or "sv") == "sv" then
    g.oy = g.svy + g.svh + 5 * z
  else
    g.oy = g.sy + g.sh * 3 + 5 * z
  end
  g.bw = (g.cw - 5 * 3 * z) / 6
  g.rr0 = g.oy + g.px * 2.0
  g.rr1 = g.rr0 + g.px * 1.6
  g.rr2 = g.rr1 + g.px * 1.7
  return g
end

local function swatch_xy(g, idx)
  return g.x0 + ((idx - 1) % g.per) * (g.sw + g.gap) + g.sw * 0.5,
         g.y0 + ((idx - 1) // g.per) * (g.sw + g.gap) + g.sw * 0.5
end

local function mode_xy(g, idx) -- sv=1, hsv=2, rgb=3
  return g.hx + (idx - 1) * (26 * g.z + 3 * g.z) + 13 * g.z,
         g.ey + 7 * g.z
end

local function op_xy(g, idx) -- add=1, set=2, dup=3, del=4, left=5, right=6
  return g.x0 + (idx - 1) * (g.bw + 3 * g.z) + g.bw * 0.5,
         g.oy + g.px * 0.8
end

local function ramp_xy(g, which)
  if which == "append" then return g.x0 + (g.cw * 0.5 - 3 * g.z) * 0.5,
                                  g.rr2 + g.px * 0.85 end
  return g.x0 + g.cw * 0.75, g.rr2 + g.px * 0.85
end

-- Palette sliders have a content-sized label and a fixed 40z value bay.
local function slider_x(g, x, w, label, lo, hi, value)
  local px = math.max(4, 8.5 * g.z)
  local bx = x + pal.x_ig_text_size(label, px, 0) + 6 * g.z
  local bw = math.max(12 * g.z, x + w - 40 * g.z - bx)
  return bx + (value - lo) / (hi - lo) * bw
end

local function set_slider(f, which, value)
  D.at(f, function()
    local g = pgeo()
    local x, y, w, label, lo, hi
    if which == "H" then
      x, y, w, label, lo, hi = g.x0, g.sy, g.cw, "H", 0, 359
    elseif which == "S" then
      x, y, w, label, lo, hi = g.x0, g.sy + g.sh, g.cw, "S", 0, 100
    elseif which == "V" then
      x, y, w, label, lo, hi = g.x0, g.sy + g.sh * 2, g.cw, "V", 0, 100
    elseif which == "R" then
      x, y, w, label, lo, hi = g.x0, g.sy, g.cw, "R", 0, 255
    elseif which == "G" then
      x, y, w, label, lo, hi = g.x0, g.sy + g.sh, g.cw, "G", 0, 255
    elseif which == "B" then
      x, y, w, label, lo, hi = g.x0, g.sy + g.sh * 2, g.cw, "B", 0, 255
    else
      log("unknown slider " .. tostring(which)); return
    end
    local tx = slider_x(g, x, w, label, lo, hi, value)
    D.drag(D.f + 1, tx, y + g.sh * 0.5, tx, y + g.sh * 0.5, 2)
  end)
end

local function set_hex(f, hex)
  D.at(f, function()
    local g = pgeo()
    D.click(D.f + 1, g.hx + 44 * g.z, g.ey + 26 * g.z)
    D.chord(D.f + 4, SC.ctrl, SC.a)
    D.at(D.f + 8, function() return { D.textev(hex) } end)
    D.tap(D.f + 10, SC.enter)
  end)
end

local function click_swatch(f, idx)
  D.at(f, function()
    local g = pgeo()
    local x, y = swatch_xy(g, idx)
    D.click(D.f + 1, x, y)
  end)
end

local function spawn_kind(f, sx, sy, menu_index)
  D.rclick(f, sx, sy)
  D.at(f + 4, function()
    local m = cm.ed.g.menu
    if not m then log("SPAWNMENU MISSING") return end
    local chrome = cm.require("cm.ed.chrome")
    local iw, ih, pad = 150, 26, 6
    local mh = 20 * ih + pad * 2
    local mx = math.min(m.sx / chrome.scale(), 1280 - iw - 8)
    local my = math.min(m.sy / chrome.scale(), 800 - mh - 8)
    D.click(D.f + 1, mx + 40,
            my + pad + (menu_index - 1) * ih + ih * 0.5)
  end)
end

local function type_path(f, kind, path)
  D.at(f, function()
    local r = D.win(kind)
    local fy = r.cy + 8 + 10 * 1.8
    D.click(D.f + 1, r.cx + 90, fy + 8)
    D.chord(D.f + 4, SC.ctrl, SC.a)
    D.at(D.f + 8, function() return { D.textev(path) } end)
    D.tap(D.f + 10, SC.enter)
  end)
end

-- ---- receiving sprite geometry after one attached palette ----
local function sgeo()
  local r = D.win("sprite")
  local g = { r = r, px = 11, z = r.z }
  g.cvh = r.ch - (54 + 16) * r.z
  g.py0 = r.cy + g.cvh + 4 * r.z
  g.fy = g.py0 + 13 * r.z + 3 * r.z
  g.att_y = r.cy + g.cvh + 54 * r.z
  return g
end

local function spix(px, py)
  local v = cm.ed.g.sw[HERO].canvas_rect
  return v.ox + (px + 0.5) * v.zoom, v.oy + (py + 0.5) * v.zoom
end

-- the @2x shot declarations (all gesture-quiet frames)
D.shot_zoom("palette-pickers", 96, "palette")
D.shot_zoom("palette-ramp", 126, "palette")
D.shot_zoom("palette-adopted", 166, "palette")
D.shot_zoom("palette-finished", 450, "palette")
D.shot_zoom("palette-hero", 650, "sprite")
shot_fit("palette-pickers", 96, 292)
shot_fit("palette-ramp", 126, 292)
shot_fit("palette-adopted", 166, 240)
shot_fit("palette-finished", 450, 270)

-- ============ step 1: restored H1 hero, then a fresh palette ============
probe(5, function()
  local r = D.win("sprite")
  verdict("restored-hero", r ~= nil and r.win.path == HERO
          and r.win.edit == false and r.z == 1,
          "z=" .. tostring(r and r.z))
  cm.ed.g.anim = nil
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
end)

-- palette is menu item 18 of 20; spawn it to the hero's right
spawn_kind(12, 800, 90, 18)
probe(28, function()
  local r = D.win("palette")
  verdict("palette-window", r ~= nil and r.win.path == "")
end)
type_path(32, "palette", PAL)
probe(54, function()
  local g = pgeo()
  verdict("palette-created", g ~= nil and g.win.path == PAL
          and #g.cols == 6 and g.win.wcol == 0xffffffff)
end)

-- ============ step 2: night-violet fundamental in the SV picker ============
set_slider(62, "H", 260)
probe(72, function()
  local g = pgeo()
  verdict("hue-260", g and math.floor((g.p.ui[g.win.id].wh or 0) * 360) == 260)
end)
D.at(76, function()
  local g = pgeo()
  D.click(D.f + 1, g.x0 + g.cw * 0.60, g.svy + g.svh * 0.50)
end)
probe(86, function()
  local g = pgeo()
  local want = paint.hsv(260 / 360, 0.60, 0.50, 255)
  verdict("sv-night-violet", g and g.win.wcol == want,
          g and palette.to_hex { g.win.wcol } or "no-window")
end)
probe(96, function()
  local g = pgeo(); crop("palette-pickers", g.r.x, g.r.y, g.r.w, g.r.h)
end)

-- ============ step 3: replace the starter with one five-shade ramp ============
D.at(104, function()
  local g = pgeo(); local x, y = ramp_xy(g, "replace")
  D.click(D.f + 1, x, y)
end)
probe(116, function()
  local g = pgeo()
  local _, _, va = paint.to_hsv(g.cols[1])
  local _, _, vb = paint.to_hsv(g.cols[5])
  verdict("violet-ramp", #g.cols == 5 and vb > va
          and g.win.rampn == 5 and g.win.ramph == 14)
end)
probe(126, function()
  local g = pgeo(); crop("palette-ramp", g.r.x, g.r.y, g.r.w, g.r.h)
end)

-- ============ step 4: adopt a saved shade without editing the ramp ============
click_swatch(134, 3)
click_swatch(140, 3)
probe(150, function()
  local g = pgeo()
  verdict("double-click-adopts", g.win.sel == 3
          and g.win.wcol == g.cols[3] and #g.cols == 5)
end)
D.at(154, function()
  local g = pgeo(); local x, y = mode_xy(g, 2)
  D.click(D.f + 1, x, y)
end)
probe(166, function()
  local g = pgeo()
  verdict("hsv-mode", g.win.pick == "hsv")
  crop("palette-adopted", g.r.x, g.r.y, g.r.w, g.r.h)
end)

-- ============ step 5: moss-teal through the exact HSV sliders ============
set_slider(176, "H", 165)
set_slider(188, "S", 55)
set_slider(200, "V", 55)
probe(214, function()
  local g = pgeo()
  local u = g.p.ui[g.win.id]
  verdict("hsv-moss", math.floor(u.wh * 360) == 165
          and math.floor(u.ws * 100 + 0.5) == 55
          and math.floor(u.wv * 100 + 0.5) == 55,
          palette.to_hex { g.win.wcol })
end)
D.at(220, function()
  local g = pgeo(); local x, y = ramp_xy(g, "append")
  D.click(D.f + 1, x, y)
end)
probe(232, function()
  local g = pgeo(); verdict("teal-ramp-appended", #g.cols == 10)
end)

-- ============ step 6: lantern gold through RGB ============
D.at(238, function()
  local g = pgeo(); local x, y = mode_xy(g, 3)
  D.click(D.f + 1, x, y)
end)
set_slider(248, "R", 209)
set_slider(260, "G", 138)
set_slider(272, "B", 72)
probe(286, function()
  local g = pgeo(); local r, gg, b = paint.unpack(g.win.wcol)
  verdict("rgb-gold", r == 209 and gg == 138 and b == 72,
          palette.to_hex { g.win.wcol })
end)
D.at(292, function()
  local g = pgeo(); local x, y = ramp_xy(g, "append")
  D.click(D.f + 1, x, y)
end)
probe(304, function()
  local g = pgeo(); verdict("gold-ramp-appended", #g.cols == 15)
end)

-- ============ step 7: one saturated rose accent through hex + add ============
set_hex(310, "f25f7a")
click_swatch(326, 15)
D.at(336, function()
  local g = pgeo(); local x, y = op_xy(g, 1)
  D.click(D.f + 1, x, y)
end)
probe(348, function()
  local g = pgeo()
  verdict("accent-add", #g.cols == 16 and g.win.sel == 16
          and palette.to_hex { g.cols[16] } == "f25f7a")
end)

-- ============ step 8: ONE shared shadow, without duplicate swatches ============
set_hex(354, "171525")
click_swatch(370, 1)
D.at(378, function() local g = pgeo(); local x,y = op_xy(g,2); D.click(D.f+1,x,y) end)
click_swatch(388, 16)
D.tap(396, SC.enter) -- adopt the accent: selection + working swatch agree
probe(426, function()
  local g = pgeo()
  local hex = palette.to_hex(g.cols)
  local want = table.concat({
    "171525", "302b5f", "54398e", "8f55bd", "d990ec",
    "223528", "31634b", "41917e", "5fc0be", "99dbee",
    "4f2e2e", "7a4331", "a46c38", "ceab53", "f8f38e", "f25f7a",
  }, "\n")
  local shadows = 0
  for _, c in ipairs(g.cols) do
    if palette.to_hex { c } == "171525" then shadows = shadows + 1 end
  end
  verdict("one-shared-shadow", hex == want and shadows == 1,
          ("copies=%d"):format(shadows))
end)
probe(450, function()
  local g = pgeo()
  verdict("finished-16", #g.cols == 16 and g.win.sel == 16
          and g.win.wcol == g.cols[16])
  crop("palette-finished", g.r.x, g.r.y, g.r.w, g.r.h)
end)

-- ============ step 9: save the .pal ============
D.chord(456, SC.ctrl, SC.s)
probe(470, function()
  local g = pgeo()
  local bytes = pal.read_file(cm.ed.root .. "/" .. PAL)
  local ok, doc = pcall(palette.decode, bytes or "")
  verdict("palette-saved", ok and #doc.colors == 16
          and cm.ed.kinds.palette.dirty(g.win, cm.ed) == false)
end)

-- ============ step 10: assets -> drag the palette onto the hero ============
D.chord(476, SC.ctrl, SC.w) -- close the palette; its work is safely on disk
spawn_kind(486, 800, 90, 4) -- assets is menu item 4
probe(502, function()
  verdict("assets-open", D.win("assets") ~= nil)
end)
D.at(508, function()
  local r = D.win("assets")
  local px, top = 10.5, 10.5 * 1.7 + 8
  local fy = r.cy + top
  D.click(D.f + 1, r.cx + 90, fy + px * 0.8)
  D.chord(D.f + 4, SC.ctrl, SC.a)
  D.at(D.f + 8, function() return { D.textev("moonlit") } end)
end)
probe(524, function()
  local r = D.win("assets")
  verdict("asset-filter", r.win.filter == "moonlit")
end)
D.at(530, function()
  local a, s = D.win("assets"), D.win("sprite")
  local px = 10.5
  local top = px * 1.7 + 8
  local gy0 = a.cy + top + px * 1.7 + 6
  local tile = a.win.tile or 84
  D.drag(D.f + 1, a.cx + 6 + tile * 0.5, gy0 + tile * 0.5,
         s.cx + s.cw * 0.5, s.cy + s.ch * 0.45, 8)
end)
probe(550, function()
  local s = D.win("sprite")
  verdict("palette-attached", s and #(s.win.palettes or {}) == 1
          and s.win.palettes[1] == PAL)
end)

-- ============ steps 11-12: use a swatch on the hero ============
D.at(556, function() -- view header: edit is the rightmost kind chip
  local r = D.win("sprite")
  local hdrx = cm.ed.g.hdrx[r.win.id]
  local we = pal.x_ig_text_size("edit", 10.5, 0) + 14
  local wa = pal.x_ig_text_size("anim", 10.5, 0) + 14
  local used = we + 4 + wa + 4
  D.click(D.f + 1, hdrx + used - we * 0.5, r.y + 12)
end)
probe(568, function()
  local r = D.win("sprite"); verdict("hero-edit-mode", r.win.edit == true)
end)
D.at(572, function() -- bottom of the 3-row stack = body layer 1
  local g = sgeo()
  local rows0 = g.r.cy + 4 + g.px * 1.3
  local row3 = rows0 + 2 * (g.px * 1.6 + 2) + 8
  D.click(D.f + 1, g.r.cx + g.r.cw - 96 + 43, row3)
end)
D.at(580, function() -- frame chip 1
  local g = sgeo(); D.click(D.f + 1, g.r.cx + 9, g.fy + 7)
end)
D.at(588, function() -- attached palette's eighth color: the teal midtone
  local g = sgeo()
  local first = g.r.cx + 63
  D.click(D.f + 1, first + 7 * 13 + 5.5, g.att_y + 8)
end)
probe(596, function()
  local s = D.win("sprite")
  local pdoc = palette.decode(assert(pal.read_file(cm.ed.root .. "/" .. PAL)))
  verdict("attached-swatch-picked", s.win.color == pdoc.colors[8])
end)
D.tap(600, SC.f)
D.at(606, function()
  local x, y = spix(18, 15); D.click(D.f + 1, x, y)
end)
probe(620, function()
  local sp = cm.ed.g.sw[HERO]
  local cell = cm.require("cm.sprite").cell(sp.doc, 1, 1)
  local pd = palette.decode(assert(pal.read_file(cm.ed.root .. "/" .. PAL)))
  verdict("hero-recolored", paint.get(cell, 18, 15) == pd.colors[8]
          and sp.doc.cur_layer == 1 and sp.doc.cur_frame == 1)
end)
D.chord(626, SC.ctrl, SC.s)
probe(638, function()
  verdict("hero-saved", pal.read_file(cm.ed.root .. "/art/hero.png") ~= nil)
end)
probe(650, function()
  local g = D.win("sprite")
  crop("palette-hero", g.x, g.y, g.w, g.h)
  verdict("summary", FAIL == 0, ("%d/%d"):format(PASS, PASS + FAIL))
  log("TAPE DONE")
end)
