-- tools/drive/tape-sprite-tutorial.lua — drives win-sprite.md's
-- "paint the hero" walkthrough AS WRITTEN (HELPDOCS H1): every click,
-- key and drag through the real UI, with VERDICT probes at each stage
-- and CROP lines logged for the screenshot set.
--
-- THE CAPTURE RECIPE (HELPDOCS §3 — every tool-docs session repeats it):
--   1. fresh smoke copy:   cp -r projects/smoke <scratch>/smoke-h1
--   2. full proof run:     bin/cosmic <scratch>/smoke-h1 --edit --headless \
--        --win 1280x800 --frames 900 --eval \
--        "dofile('tools/drive/tape-sprite-tutorial.lua')" --shot <scratch>/full.png
--      → every VERDICT line in the log must read true.
--   3. screenshots are the tape's own frames AT 2x (the D163 @2x capture
--      contract — D.shot_zoom in drive.lua): re-run ON A FRESH COPY with
--      --frames at the shot's frame and SHOT set (the run ends there;
--      --shot captures that state), then crop to the logged CROP rect
--      (nix run nixpkgs#imagemagick), e.g.
--        bin/cosmic <scratch>/smoke-h1 ... --frames 430 --eval \
--          "rawset(_G,'SHOT','sprite-shading'); dofile('tools/drive/tape-sprite-tutorial.lua')" \
--          --shot raw.png
--        magick raw.png -crop WxH+X+Y media/sprite-shading@2x.png
--      The full-window shots (920x760 at 2x) rerun at --win 1280x860 so
--      the window clears the shell's top HUD and bottom hint bar — the
--      tape's math is surface-size independent (the spawn clamps never
--      engage at these menu positions).
--   4. stage crops under engine/stock/docs/media/ as <name>@2x.png (layout
--      size ≤700x550 = intrinsic ≤1400x1100, window crops, alt text on
--      every image), look at each one yourself, montage to llm-feed with
--      title+note.
--
-- Shot frames (stable while the tape above them is unchanged; shots sit
-- at gesture-QUIET frames — the @2x camera bump two frames earlier would
-- remap a held drag's remaining motion events):
--   f430 sprite-shading  · f634 sprite-stroke · f735 sprite-layers
--   f855 sprite-hero
local D = dofile("tools/drive/drive.lua")
local SC = D.SC

local function log(s) pal.log("[tape] " .. s) end
local paint = cm.require("cm.paint")

-- ---- geometry mirrors (z = 1 asserted by the created VERDICT) ----
-- the sprite draw() layout, content rect from D.win: TR=26 tool rail,
-- LR=96 layers rail, BB=54 bottom rows (palette/frames/brush)
local function geo()
  local r = D.win("sprite")
  local g = { r = r, z = r.z, px = 11 }
  g.cvx, g.cvy = r.cx + 26, r.cy
  g.cvw, g.cvh = r.cw - 26 - 96, r.ch - 54
  g.lx = r.cx + r.cw - 96 + 3 -- layers rail x
  g.py0 = r.cy + g.cvh + 4 -- palette row
  g.fy = g.py0 + 13 + 3 -- frames row
  g.by = r.cy + g.cvh + 38 -- brush row
  return g
end
-- palette swatch n (1-based color index; 0 = the transparent swatch)
local function swatch_xy(g, n)
  return g.r.cx + 2 + n * 15 + 6, g.py0 + 6
end
-- layers-rail row y's for the CURRENT layer count (rh=17.6, +2 gap)
local function rail(g, nlayers)
  local rows0 = g.r.cy + 4 + g.px * 1.3
  local rh = g.px * 1.6
  local t = { buttons = rows0 + nlayers * (rh + 2) }
  t.op = t.buttons + rh + 4
  t.mix = t.op + rh + 2
  t.fill = t.mix + rh + 2
  t.sd = t.fill + rh + 2
  t.lv = t.sd + rh + 2 -- gradient fills: no px/oct row between
  t.cols = t.lv + rh + 2
  t.half = (96 - 9 - 2) / 2
  return t
end
-- sprite pixel -> screen center, via the live captured view
local function pix(px_, py_)
  local p = cm.ed.g.sw["art/hero.spr"]
  local v = p.canvas_rect
  return v.ox + (px_ + 0.5) * v.zoom, v.oy + (py_ + 0.5) * v.zoom
end
-- a paint stroke through sprite-pixel waypoints (one gesture)
local function stroke(f, pts, gap)
  gap = gap or 2
  D.at(f, function()
    local x, y = pix(pts[1][1], pts[1][2])
    return { D.mouse(x, y) }
  end)
  D.at(f + 1, function()
    local x, y = pix(pts[1][1], pts[1][2])
    return { D.btn(x, y, true) }
  end)
  for k = 2, #pts do
    D.at(f + 1 + (k - 1) * gap, function()
      local x, y = pix(pts[k][1], pts[k][2])
      return { D.mouse(x, y) }
    end)
  end
  D.at(f + 2 + (#pts - 1) * gap, function()
    local x, y = pix(pts[#pts][1], pts[#pts][2])
    return { D.btn(x, y, false) }
  end)
end
local function dab(f, x, y)
  D.at(f, function()
    local sx, sy = pix(x, y)
    D.click(D.f + 1, sx, sy)
  end)
end
local function doc_of()
  local p = cm.ed.g.sw["art/hero.spr"]
  return p and p.doc, p
end
local function probe(f, fn) D.at(f, fn) end
local function crop(name, x, y, w, h)
  log(("CROP %s %d %d %d %d"):format(name, math.floor(x), math.floor(y),
                                     math.floor(w), math.floor(h)))
end

-- the @2x shot declarations (fire only when SHOT matches; see header)
D.shot_zoom("sprite-shading", 430, "sprite")
D.shot_zoom("sprite-stroke", 634, "sprite")
D.shot_zoom("sprite-layers", 735, "sprite")
D.shot_zoom("sprite-hero", 855, "sprite")

-- ================= stage 0: clear the session windows =================
-- the smoke project ships a saved editor session; cycle focus + close
-- until the canvas is bare, then normalize the camera so z = 1 holds
for k = 0, 21 do
  D.chord(4 + k * 8, SC.ctrl, SC.tab)
  D.chord(8 + k * 8, SC.ctrl, SC.w)
end
probe(182, function()
  log("wins after clear: " .. #cm.ed.doc.wins)
  cm.ed.g.anim = nil
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
end)

-- ============ step 1: spawn a sprite window, type the path ============
-- (menu roster: sprite = the 15th of 20 items)
D.rclick(184, 330, 90)
D.at(188, function()
  local m = cm.ed.g.menu
  if not m then log("SPAWNMENU MISSING") return end
  local chrome = cm.require("cm.ed.chrome")
  local iw, ih, pad = 150, 26, 6
  local mh = 20 * ih + pad * 2
  local mx = math.min(m.sx / chrome.scale(), 1280 - iw - 8)
  local my = math.min(m.sy / chrome.scale(), 800 - mh - 8)
  D.click(D.f + 1, mx + 40, my + pad + 14 * ih + ih / 2)
end)
probe(206, function()
  cm.ed.g.anim = nil
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
end)
D.at(210, function()
  local r = D.win("sprite")
  local fy = r.cy + 8 + 10.5 * 1.8
  D.click(D.f + 1, r.cx + 60, fy + 8)
  D.chord(D.f + 4, SC.ctrl, SC.a)
  D.at(D.f + 8, function() return { D.textev("art/hero.spr") } end)
  D.tap(D.f + 10, SC.enter)
end)
probe(232, function()
  local r = D.win("sprite")
  log("VERDICT created " ..
      tostring(r ~= nil and r.win.path == "art/hero.spr"
               and r.win.edit == true and r.z == 1) ..
      " z=" .. tostring(r and r.z))
end)

-- ================= step 2: the silhouette =================
D.at(240, function()
  local g = geo()
  local x, y = swatch_xy(g, 16) -- the leaf green
  D.click(D.f + 1, x, y)
end)
probe(248, function()
  local r = D.win("sprite")
  log("VERDICT primary-green " ..
      tostring(r.win.color == paint.pack(122, 200, 142, 255)))
end)
stroke(252, { { 16, 4 }, { 12, 6 }, { 10, 9 }, { 9, 13 }, { 10, 16 },
              { 8, 21 }, { 7, 26 }, { 16, 26 }, { 24, 26 }, { 23, 21 },
              { 21, 16 }, { 22, 13 }, { 21, 9 }, { 19, 6 }, { 16, 4 } })
probe(290, function()
  local doc = doc_of()
  local cell = cm.require("cm.sprite").cell(doc, 1, 1)
  local n = 0
  for yy = 0, 31 do
    for xx = 0, 31 do
      if paint.get(cell, xx, yy) ~= 0 then n = n + 1 end
    end
  end
  log("VERDICT outline " .. tostring(n > 50 and n < 150) .. " n=" .. n)
end)

-- ================= step 3: flood the interior =================
D.tap(296, SC.f)
dab(300, 16, 16)
probe(310, function()
  local doc = doc_of()
  local cell = cm.require("cm.sprite").cell(doc, 1, 1)
  log("VERDICT flooded " ..
      tostring(paint.get(cell, 16, 16) == paint.pack(122, 200, 142, 255)))
end)

-- ============ step 4: hex-add the dark green, set the secondary ============
D.at(316, function()
  local g = geo()
  D.click(D.f + 1, g.r.cx + g.r.cw - 100 + 13 + 3 + 30, g.py0 + 6)
  D.at(D.f + 5, function() return { D.textev("#2e5c40") } end)
  D.tap(D.f + 7, SC.enter)
end)
D.at(336, function()
  local g = geo()
  local x, y = swatch_xy(g, 16)
  D.rclick(D.f + 1, x, y)
end)
probe(344, function()
  local r = D.win("sprite")
  local doc = doc_of()
  log("VERDICT ramp-colors " ..
      tostring(r.win.color == paint.pack(0x2e, 0x5c, 0x40, 255)
               and r.win.color2 == paint.pack(122, 200, 142, 255)
               and #doc.palette == 18))
end)

-- ================= step 5: fill linear =================
D.at(350, function()
  local g = geo()
  local t = rail(g, 1)
  D.click(D.f + 1, g.lx + 40, t.fill + 8)
end)
probe(360, function()
  local doc = doc_of()
  local fl = doc.layers[1].fill
  log("VERDICT fill-linear " .. tostring(fl ~= nil and fl.type == "linear"))
end)

-- ==== step 6: di down to 30% (shot after the release: f430 — a held
-- drag can't cross the @2x bump) ====
D.at(370, function()
  local g = geo()
  local t = rail(g, 1)
  local x0 = g.lx + t.half + 2 + 6
  -- long slow drag (-42px total = -7 steps) held across the shot frame
  D.at(D.f + 1, function() return { D.mouse(x0, t.lv + 8) } end)
  D.at(D.f + 2, function() return { D.btn(x0, t.lv + 8, true) } end)
  for s = 1, 42 do
    D.at(D.f + 2 + s, function()
      return { D.mouse(x0 - s, t.lv + 8) }
    end)
  end
  D.at(D.f + 55, function() return { D.btn(x0 - 42, t.lv + 8, false) } end)
end)
probe(430, function()
  local g = geo()
  crop("sprite-shading", g.r.x, g.r.y, g.r.w, g.r.h)
end)
probe(432, function()
  local doc = doc_of()
  local fl = doc.layers[1].fill
  log("VERDICT dither-30 " ..
      tostring(fl ~= nil and fl.dither > 0.25 and fl.dither < 0.35) ..
      " di=" .. tostring(fl and fl.dither))
end)

-- ================= step 7: bake =================
D.at(438, function()
  local g = geo()
  local t = rail(g, 1)
  D.click(D.f + 1, g.lx + t.half + 2 + 21, t.cols + 8)
end)
probe(448, function()
  local doc = doc_of()
  local cell = cm.require("cm.sprite").cell(doc, 1, 1)
  local _, gt = paint.unpack(paint.get(cell, 16, 6))
  local _, gb = paint.unpack(paint.get(cell, 16, 24))
  log("VERDICT baked " ..
      tostring(doc.layers[1].fill == nil and gt > gb) ..
      " gtop=" .. tostring(gt) .. " gbot=" .. tostring(gb))
end)

-- ================= step 8: the face =================
D.tap(452, SC.p) -- back to the pen (the bucket shows no brush strip)
D.at(454, function()
  local g = geo()
  D.drag(D.f + 1, g.r.cx + 27, g.by + 6, g.r.cx + 27 + 18, g.by + 6, 6)
  D.click(D.f + 14, g.r.cx + 133, g.by + 6) -- shape -> square
end)
D.at(474, function()
  local g = geo()
  local x, y = swatch_xy(g, 7) -- light skin
  D.click(D.f + 1, x, y)
end)
dab(480, 16, 11)
D.at(488, function() -- size back to 1 (clamps)
  local g = geo()
  D.drag(D.f + 1, g.r.cx + 27, g.by + 6, g.r.cx + 27 - 24, g.by + 6, 6)
end)
D.at(502, function()
  local g = geo()
  local x, y = swatch_xy(g, 2) -- the dark ink
  D.click(D.f + 1, x, y)
end)
dab(508, 15, 11)
dab(514, 17, 11)
D.at(520, function()
  local g = geo()
  local x, y = swatch_xy(g, 14) -- gold
  D.click(D.f + 1, x, y)
end)
dab(526, 16, 15)
probe(536, function()
  local doc = doc_of()
  local cell = cm.require("cm.sprite").cell(doc, 1, 1)
  local ok = paint.get(cell, 15, 11) == paint.pack(32, 28, 44, 255)
             and paint.get(cell, 17, 11) == paint.pack(32, 28, 44, 255)
             and paint.get(cell, 16, 11) == paint.pack(247, 219, 188, 255)
             and paint.get(cell, 16, 15) == paint.pack(248, 214, 122, 255)
  log("VERDICT face " .. tostring(ok))
end)

-- ==== step 9: the shadow layer (shot between the strokes: f634 — a
-- held stroke can't cross the @2x bump; the brush cursor still shows) ====
D.at(542, function()
  local g = geo()
  local t = rail(g, 1)
  D.click(D.f + 1, g.lx + 9, t.buttons + 8) -- + add layer
end)
D.at(552, function()
  local g = geo()
  local t = rail(g, 2)
  D.click(D.f + 1, g.lx + 40, t.mix + 8) -- mix -> mul
end)
probe(560, function()
  local doc = doc_of()
  log("VERDICT layer2-mul " ..
      tostring(#doc.layers == 2 and doc.layers[2].blend == "mul"
               and doc.cur_layer == 2))
end)
D.at(564, function()
  local g = geo()
  local x, y = swatch_xy(g, 11) -- suit shadow
  D.click(D.f + 1, x, y)
end)
D.at(572, function()
  local g = geo()
  -- pen size 5 (+24px), opacity 50% (-60px), shape back to circle
  D.drag(D.f + 1, g.r.cx + 27, g.by + 6, g.r.cx + 27 + 24, g.by + 6, 6)
  D.at(D.f + 12, function()
    D.drag(D.f + 1, g.r.cx + 83, g.by + 6, g.r.cx + 83 - 60, g.by + 6, 8)
  end)
  D.at(D.f + 26, function()
    D.click(D.f + 1, g.r.cx + 133, g.by + 6)
  end)
end)
-- the flank stroke, slow, held across the shot frame (starts well
-- clear of the dial/chip clicks above — an overlapping gesture drags
-- the stroke through the chip, painting a line off the body)
stroke(608, { { 12, 14 }, { 12, 18 }, { 11, 21 }, { 11, 24 } }, 6)
probe(634, function()
  local g = geo()
  crop("sprite-stroke", g.r.x, g.r.y, g.r.w, g.r.h)
end)
stroke(640, { { 12, 24 }, { 16, 24 }, { 21, 24 } }, 4)
probe(660, function()
  local doc = doc_of()
  local cell = cm.require("cm.sprite").cell(doc, 2, 1)
  local n = 0
  for yy = 0, 31 do
    for xx = 0, 31 do
      if paint.get(cell, xx, yy) ~= 0 then n = n + 1 end
    end
  end
  local r = D.win("sprite")
  log("VERDICT shadow " ..
      tostring(n > 30 and n < 300
               and r.win.bsize == 5 and r.win.bshape == "circle"
               and math.abs(r.win.bop - 0.5) < 0.01) ..
      " n=" .. n .. " bsize=" .. tostring(r.win.bsize) ..
      " bop=" .. tostring(r.win.bop))
end)

-- ============ step 10: the light layer (shot after: f735) ============
D.at(666, function()
  local g = geo()
  local t = rail(g, 2)
  D.click(D.f + 1, g.lx + 9, t.buttons + 8)
end)
D.at(676, function()
  local g = geo()
  local t = rail(g, 3)
  D.click(D.f + 1, g.lx + 40, t.mix + 8) -- normal -> mul
  D.click(D.f + 5, g.lx + 40, t.mix + 8) -- mul -> add
end)
D.at(688, function()
  local g = geo()
  local x, y = swatch_xy(g, 14) -- gold
  D.click(D.f + 1, x, y)
end)
D.at(696, function()
  local g = geo()
  -- size 2 (-18px), opacity 60% (+12px)
  D.drag(D.f + 1, g.r.cx + 27, g.by + 6, g.r.cx + 27 - 18, g.by + 6, 6)
  D.at(D.f + 12, function()
    D.drag(D.f + 1, g.r.cx + 83, g.by + 6, g.r.cx + 83 + 12, g.by + 6, 4)
  end)
end)
stroke(720, { { 20, 7 }, { 21, 10 }, { 21, 12 } }, 3)
probe(735, function()
  local g = geo()
  crop("sprite-layers", g.r.x + g.r.w - 252 * g.z, g.r.y,
       252 * g.z, 300 * g.z)
end)
stroke(738, { { 21, 15 }, { 22, 18 } }, 3)
probe(752, function()
  local doc = doc_of()
  local cell = cm.require("cm.sprite").cell(doc, 3, 1)
  local n = 0
  for yy = 0, 31 do
    for xx = 0, 31 do
      if paint.get(cell, xx, yy) ~= 0 then n = n + 1 end
    end
  end
  log("VERDICT light " ..
      tostring(#doc.layers == 3 and doc.layers[3].blend == "add"
               and n > 5 and n < 200) .. " n=" .. n)
end)

-- ================= step 11: two duplicate frames =================
D.at(758, function()
  local g = geo()
  D.click(D.f + 1, g.r.cx + g.r.cw - 78 + 25 + 11, g.fy + 7)
  D.click(D.f + 9, g.r.cx + g.r.cw - 78 + 25 + 11, g.fy + 7)
end)
probe(778, function()
  local doc = doc_of()
  local sprite = cm.require("cm.sprite")
  local a = paint.get(sprite.cell(doc, 1, 1), 16, 11)
  local b = paint.get(sprite.cell(doc, 1, 3), 16, 11)
  log("VERDICT frames " .. tostring(doc.frames == 3 and a == b))
end)

-- ================= step 12: save, then view mode =================
D.chord(784, SC.ctrl, SC.s)
probe(796, function()
  local spr = pal.read_file(cm.ed.root .. "/art/hero.spr")
  local png = pal.read_file(cm.ed.root .. "/art/hero.png")
  local ok = spr ~= nil and png ~= nil
  if png then
    local _, w, h = pal.png_read(png)
    ok = ok and w == 96 and h == 32
    log("strip " .. tostring(w) .. "x" .. tostring(h))
  end
  log("VERDICT saved " .. tostring(ok))
end)
D.at(804, function()
  -- header chips lay right-to-left in call order: done (first) is the
  -- RIGHTMOST — rebuild the strip x from the labels' widths (H7 recipe)
  local r = D.win("sprite")
  local hdrx = cm.ed.g.hdrx[r.win.id]
  local used = 0
  for _, l in ipairs({ "done", "size", "anim" }) do
    used = used + pal.x_ig_text_size(l, 10.5, 0) + 14 + 4
  end
  local w1 = pal.x_ig_text_size("done", 10.5, 0) + 14
  D.click(D.f + 1, hdrx + used - w1 / 2, r.y + 12)
end)
probe(820, function()
  local r = D.win("sprite")
  log("VERDICT view-mode " .. tostring(r.win.edit == false))
end)
probe(855, function()
  local g = D.win("sprite")
  crop("sprite-hero", g.x, g.y, g.w, g.h)
  log("TAPE DONE")
end)
