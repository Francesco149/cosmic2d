-- tools/drive/tape-anim-tutorial.lua — drives win-anim.md's "bring the
-- hero to life" walkthrough AS WRITTEN (HELPDOCS H2): every click, key
-- and field through the real UI, with VERDICT probes at each stage and
-- CROP lines logged for the screenshot set.
--
-- THE CAPTURE RECIPE (HELPDOCS §3, chained on H1 — the tutorial starts
-- from the sprite tutorial's saved hero, so its tape runs FIRST):
--   1. fresh smoke copy:   cp -r projects/smoke <scratch>/smoke-h2
--   2. the H1 prologue:    bin/cosmic <scratch>/smoke-h2 --edit --headless \
--        --win 1280x800 --frames 900 --eval \
--        "dofile('tools/drive/tape-sprite-tutorial.lua')"
--      → art/hero.spr saved on disk, the editor session left in view mode
--        (unsaved-persists restores it for the next run).
--   3. full proof run:     bin/cosmic <scratch>/smoke-h2 --edit --headless \
--        --win 1280x800 --frames 640 --eval \
--        "dofile('tools/drive/tape-anim-tutorial.lua')" --shot <scratch>/full.png
--      → every VERDICT line in the log must read true.
--   4. screenshots are the tape's own frames: repeat steps 1–2 on a FRESH
--      copy per shot (the H1 save makes step-3 reruns non-idempotent on a
--      shared copy), then run step 3 with --frames at the shot's frame and
--      crop to the logged CROP rect (nix run nixpkgs#imagemagick):
--        magick raw.png -crop WxH+X+Y media/anim-timing.png
--   5. stage crops under engine/stock/docs/media/ (at most 700x550, window
--      crops, alt text on every image), look at each one yourself, montage
--      to llm-feed with title+note.
--
-- Shot frames (stable while the tape above them is unchanged):
--   f292 anim-timing · f410 anim-preview-a · f416 anim-preview-b
--   f556 anim-clips
local D = dofile("tools/drive/drive.lua")
local SC = D.SC
local SCK_K = 14 -- 'k' (the pick tool; not in drive.lua's SC table)
local SCK_L = 15 -- 'l' (the loop hotkey)

local function log(s) pal.log("[tape] " .. s) end
local paint = cm.require("cm.paint")
local anim = cm.require("cm.anim")

local HERO = "art/hero.spr"

-- ---- geometry mirrors (z = 1 asserted by the restored VERDICT) ----
local function sgeo() -- the sprite window (the H1 tape's layout math)
  local r = D.win("sprite")
  local g = { r = r, px = 11 }
  g.cvh = r.ch - 54
  g.lx = r.cx + r.cw - 96 + 3
  g.py0 = r.cy + g.cvh + 4
  g.fy = g.py0 + 13 + 3
  g.by = r.cy + g.cvh + 38
  return g
end
local function swatch_xy(g, n)
  return g.r.cx + 2 + n * 15 + 6, g.py0 + 6
end
-- sprite-window layers-rail row k (1-based from the top) for n layers
local function lrow_y(g, k)
  return g.r.cy + 4 + g.px * 1.3 + (k - 1) * (g.px * 1.6 + 2) + 8
end
-- sprite frames-row chip n center (labels are "1".."N")
local function fchip_xy(g, n)
  local x = g.r.cx + 2
  for fi = 1, n - 1 do
    x = x + pal.x_ig_text_size(tostring(fi), 9.9, 1) + 8 + 2
  end
  return x + (pal.x_ig_text_size(tostring(n), 9.9, 1) + 8) / 2, g.fy + 7
end
local function pix(px_, py_)
  local v = cm.ed.g.sw[HERO].canvas_rect
  return v.ox + (px_ + 0.5) * v.zoom, v.oy + (py_ + 0.5) * v.zoom
end
local function dab(f, x, y)
  D.at(f, function()
    local sx, sy = pix(x, y)
    D.click(D.f + 1, sx, sy)
  end)
end
local function doc_of()
  local p = cm.ed.g.sw[HERO]
  return p and p.doc, p
end

local function ageo() -- the anim window (win/anim.lua's layout math)
  local r = D.win("anim")
  local g = { r = r, px = 11 }
  g.RR = math.min(110, r.cw * 0.34)
  g.cvw, g.cvh = r.cw - g.RR, r.ch - 11 * 3.6
  g.rx = r.cx + r.cw - g.RR + 3
  g.rows0 = r.cy + 4 + 11 * 1.3 -- first clip row
  g.rowdy = 11 * 1.6 + 2
  g.ty = r.cy + g.cvh + 3 -- transport row
  g.y2 = g.ty + 11 * 1.6 + 3 -- entry-ops row
  return g
end
local function cur_clip()
  local doc = doc_of()
  local aw = D.win("anim")
  return anim.find(doc.clips or {}, aw.win.clip) or (doc.clips or {})[1]
end
-- rail row k / the + and - buttons under n rows
local function rail_row_xy(g, k)
  return g.rx + 40, g.rows0 + (k - 1) * g.rowdy + 8
end
local function rail_plus_xy(g, n)
  return g.rx + 24, g.rows0 + n * g.rowdy + 8
end
-- transport chips + entry chips
local function play_xy(g) return g.r.cx + 2 + 18, g.ty + 8 end
local function loop_xy(g) return g.r.cx + 2 + 11 * 3.4 + 4 + 18, g.ty + 8 end
local function entry_chip_xy(g, k)
  local cur = cur_clip()
  local x = g.r.cx + 2 + 11 * 3.4 + 4 + 11 * 3.4 + 8
  for ei = 1, k - 1 do
    local e = cur.frames[ei]
    local label = ("%d:%d"):format(e.frame + 1, e.dur or 1)
    x = x + pal.x_ig_text_size(label, 11 * 0.85, 0) + 8 + 3
  end
  local e = cur.frames[k]
  local label = ("%d:%d"):format(e.frame + 1, e.dur or 1)
  return x + (pal.x_ig_text_size(label, 11 * 0.85, 0) + 8) / 2, g.ty + 8
end
local function fbtn_xy(g, which) -- "+f" | "-f"
  local x = g.r.cx + 2
  if which == "-f" then x = x + 11 * 2.4 + 3 end
  return x + 11 * 1.2, g.y2 + 8
end
local function field_xy(g, which) -- "frame" | "dur" | "name"
  local x = g.r.cx + 2 + 11 * 2.4 + 3 + 11 * 2.4 + 8
  for _, f in ipairs({ { "frame", 30 }, { "dur", 30 }, { "name", 52 } }) do
    local lx = x + pal.x_ig_text_size(f[1], 11 * 0.8, 0) + 3
    if f[1] == which then return lx + f[2] / 2, g.y2 + 8 end
    x = lx + f[2] + 6
  end
end
-- click a field, select-all, retype, enter (the H1 path-field pattern)
local function set_field(f, which, text)
  D.at(f, function()
    local g = ageo()
    local x, y = field_xy(g, which)
    D.click(D.f + 1, x, y)
    D.chord(D.f + 4, SC.ctrl, SC.a)
    D.at(D.f + 8, function() return { D.textev(text) } end)
    D.tap(D.f + 10, SC.enter)
  end)
end
local function probe(f, fn) D.at(f, fn) end
local function crop(name, x, y, w, h)
  log(("CROP %s %d %d %d %d"):format(name, math.floor(x), math.floor(y),
                                     math.floor(w), math.floor(h)))
end

-- ============ stage 0: the restored session (H1's ending) ============
probe(5, function()
  local r = D.win("sprite")
  log("VERDICT restored " ..
      tostring(r ~= nil and r.win.path == HERO and r.win.edit == false
               and r.z == 1) .. " z=" .. tostring(r and r.z))
  cm.ed.g.anim = nil
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
end)

-- ============ step 1: edit mode, then the anim header button ============
-- header chips lay right-to-left in call order (the H1 recipe): view
-- mode shows [anim][edit], edit rightmost
D.at(10, function()
  local r = D.win("sprite")
  local hdrx = cm.ed.g.hdrx[r.win.id]
  local used = 0
  for _, l in ipairs({ "edit", "anim" }) do
    used = used + pal.x_ig_text_size(l, 10.5, 0) + 14 + 4
  end
  local w1 = pal.x_ig_text_size("edit", 10.5, 0) + 14
  D.click(D.f + 1, hdrx + used - w1 / 2, r.y + 12)
end)
probe(20, function()
  local r = D.win("sprite")
  log("VERDICT edit-mode " .. tostring(r.win.edit == true))
end)
D.at(24, function() -- edit mode shows [anim][size][done], anim leftmost
  local r = D.win("sprite")
  local hdrx = cm.ed.g.hdrx[r.win.id]
  local used = 0
  for _, l in ipairs({ "done", "size", "anim" }) do
    used = used + pal.x_ig_text_size(l, 10.5, 0) + 14 + 4
  end
  local wd = pal.x_ig_text_size("done", 10.5, 0) + 14
  local ws = pal.x_ig_text_size("size", 10.5, 0) + 14
  local wa = pal.x_ig_text_size("anim", 10.5, 0) + 14
  D.click(D.f + 1, hdrx + used - wd - 4 - ws - 4 - wa / 2, r.y + 12)
end)
probe(36, function()
  local r = D.win("anim")
  local doc = doc_of()
  log("VERDICT anim-open " ..
      tostring(r ~= nil and r.win.path == HERO
               and #(doc.clips or {}) == 0) ..
      " at=" .. tostring(r and (r.x .. "," .. r.y)))
end)

-- ============ step 2: layer 1, pen size 1 op 100% ============
D.at(42, function() -- bottom row of the 3-layer stack = layer 1
  local g = sgeo()
  D.click(D.f + 1, g.lx + 40, lrow_y(g, 3))
end)
probe(52, function()
  local doc = doc_of()
  log("VERDICT layer1 " .. tostring(doc.cur_layer == 1))
end)
D.tap(56, SC.p)
D.at(58, function() -- size to 1 (clamps), op to 100% (clamps)
  local g = sgeo()
  D.drag(D.f + 1, g.r.cx + 27, g.by + 6, g.r.cx + 27 - 24, g.by + 6, 6)
  D.at(D.f + 14, function()
    D.drag(D.f + 1, g.r.cx + 83, g.by + 6, g.r.cx + 83 + 60, g.by + 6, 8)
  end)
end)
probe(86, function()
  local r = D.win("sprite")
  log("VERDICT brush-reset " ..
      tostring(r.win.tool == "pen" and r.win.bsize == 1
               and math.abs(r.win.bop - 1) < 0.01) ..
      " bsize=" .. tostring(r.win.bsize) .. " bop=" .. tostring(r.win.bop))
end)

-- ============ step 3: frame 2, the breathe frame ============
D.at(90, function()
  local g = sgeo()
  D.click(D.f + 1, fchip_xy(g, 2))
end)
probe(96, function()
  local doc = doc_of()
  log("VERDICT frame2 " .. tostring(doc.cur_frame == 2))
end)
D.tap(100, SCK_K) -- pick
D.at(104, function()
  local sx, sy = pix(18, 15)
  D.click(D.f + 1, sx, sy)
end)
probe(110, function()
  local r = D.win("sprite")
  rawset(_G, "__sampled", r.win.color)
  log("sampled body color " .. string.format("%08x", r.win.color))
end)
D.tap(112, SC.p)
dab(116, 16, 15)
D.at(122, function()
  local g = sgeo()
  D.click(D.f + 1, swatch_xy(g, 14)) -- gold
end)
dab(128, 16, 16)
probe(136, function()
  local doc = doc_of()
  local sprite = cm.require("cm.sprite")
  local c2 = sprite.cell(doc, 1, 2)
  local c1 = sprite.cell(doc, 1, 1)
  local gold = paint.pack(248, 214, 122, 255)
  local ok = paint.get(c2, 16, 15) == rawget(_G, "__sampled")
             and paint.get(c2, 16, 16) == gold
             and paint.get(c1, 16, 15) == gold -- frame 1 untouched
  log("VERDICT breathe " .. tostring(ok))
end)

-- ============ step 4: frame 3, the blink frame ============
D.at(140, function()
  local g = sgeo()
  D.click(D.f + 1, fchip_xy(g, 3))
end)
probe(146, function()
  local doc = doc_of()
  log("VERDICT frame3 " .. tostring(doc.cur_frame == 3))
end)
D.at(150, function()
  local g = sgeo()
  D.click(D.f + 1, swatch_xy(g, 7)) -- skin
end)
dab(156, 15, 11)
dab(162, 17, 11)
probe(170, function()
  local doc = doc_of()
  local sprite = cm.require("cm.sprite")
  local c3 = sprite.cell(doc, 1, 3)
  local c1 = sprite.cell(doc, 1, 1)
  local skin = paint.pack(247, 219, 188, 255)
  local ink = paint.pack(32, 28, 44, 255)
  local ok = paint.get(c3, 15, 11) == skin and paint.get(c3, 17, 11) == skin
             and paint.get(c1, 15, 11) == ink and paint.get(c1, 17, 11) == ink
  log("VERDICT blink " .. tostring(ok))
end)

-- ============ step 5: focus the anim window ============
D.at(176, function()
  local r = D.win("anim")
  D.click(D.f + 1, r.cx + 60, r.cy + 60) -- the preview pane, no widgets
end)
probe(182, function()
  local r = D.win("anim")
  log("VERDICT anim-focused " .. tostring(cm.ed.doc.focus == r.win.id))
end)

-- ============ steps 6-7: the idle clip ============
D.at(186, function()
  local g = ageo()
  D.click(D.f + 1, rail_plus_xy(g, 0))
end)
probe(194, function()
  local doc = doc_of()
  local c = (doc.clips or {})[1]
  log("VERDICT clip-born " ..
      tostring(c ~= nil and c.name == "clip1" and #c.frames == 1
               and c.frames[1].dur == 8))
end)
set_field(198, "name", "idle")
probe(212, function()
  local doc = doc_of()
  local aw = D.win("anim")
  log("VERDICT renamed-idle " ..
      tostring(doc.clips[1].name == "idle" and aw.win.clip == "idle"))
end)
D.at(216, function()
  local g = ageo()
  D.click(D.f + 1, entry_chip_xy(g, 1)) -- select + pause
end)
set_field(222, "frame", "1")
set_field(236, "dur", "40")
probe(250, function()
  local c = cur_clip()
  log("VERDICT idle-entry1 " ..
      tostring(c.frames[1].frame == 0 and c.frames[1].dur == 40))
end)
D.at(254, function()
  local g = ageo()
  D.click(D.f + 1, fbtn_xy(g, "+f"))
end)
set_field(260, "frame", "2")
set_field(274, "dur", "8")
probe(288, function()
  local c = cur_clip()
  log("VERDICT idle-done " ..
      tostring(#c.frames == 2 and c.frames[2].frame == 1
               and c.frames[2].dur == 8 and c.loop == "loop"))
end)
probe(292, function()
  local g = ageo()
  crop("anim-timing", g.r.x, g.r.y + 210, g.r.w, g.r.h - 210)
end)
D.at(296, function() -- defocus the field, then space = play
  local r = D.win("anim")
  D.click(D.f + 1, r.cx + 60, r.cy + 60)
end)
D.tap(302, SC.space)
probe(308, function()
  local p = cm.ed.g.aw[HERO]
  log("VERDICT space-plays " .. tostring(p.playing == true))
end)

-- ============ step 9: the walk clip ============
D.at(312, function()
  local g = ageo()
  D.click(D.f + 1, rail_plus_xy(g, 1))
end)
set_field(318, "name", "walk")
D.at(332, function()
  local g = ageo()
  D.click(D.f + 1, entry_chip_xy(g, 1))
end)
set_field(338, "frame", "1")
set_field(352, "dur", "6")
D.at(366, function()
  local g = ageo()
  D.click(D.f + 1, fbtn_xy(g, "+f"))
end)
set_field(372, "frame", "2")
set_field(386, "dur", "6")
probe(400, function()
  local c = cur_clip()
  log("VERDICT walk-done " ..
      tostring(c.name == "walk" and #c.frames == 2
               and c.frames[1].frame == 0 and c.frames[1].dur == 6
               and c.frames[2].frame == 1 and c.frames[2].dur == 6))
end)
D.at(402, function()
  local r = D.win("anim")
  D.click(D.f + 1, r.cx + 60, r.cy + 60)
end)
D.tap(406, SC.space) -- play the march; t=0 at the keydown
probe(410, function() -- t ~ 3: the base frame
  local g = ageo()
  local p = cm.ed.g.aw[HERO]
  log("VERDICT phase-a " .. tostring(p.playing and p.frame == 1)
      .. " fi=" .. tostring(p.frame))
  crop("anim-preview-a", g.r.x, g.r.y, g.cvw + 8, g.r.h - 30)
end)
probe(416, function() -- t ~ 9: the exhale frame
  local g = ageo()
  local p = cm.ed.g.aw[HERO]
  log("VERDICT phase-b " .. tostring(p.playing and p.frame == 2)
      .. " fi=" .. tostring(p.frame))
  crop("anim-preview-b", g.r.x, g.r.y, g.cvw + 8, g.r.h - 30)
end)

-- ============ step 10: the blink clip ============
D.at(424, function()
  local g = ageo()
  D.click(D.f + 1, rail_plus_xy(g, 2))
end)
set_field(430, "name", "blink")
D.at(444, function()
  local g = ageo()
  D.click(D.f + 1, entry_chip_xy(g, 1))
end)
set_field(450, "frame", "1")
set_field(464, "dur", "1")
D.at(478, function()
  local g = ageo()
  D.click(D.f + 1, fbtn_xy(g, "+f"))
end)
set_field(484, "frame", "3")
set_field(498, "dur", "3")
D.at(512, function()
  local g = ageo()
  D.click(D.f + 1, fbtn_xy(g, "+f"))
end)
set_field(518, "frame", "1")
set_field(532, "dur", "1")
D.at(546, function() -- defocus the field, then l = loop -> once
  local r = D.win("anim")
  D.click(D.f + 1, r.cx + 60, r.cy + 60)
end)
D.tap(550, SCK_L)
probe(554, function()
  local c = cur_clip()
  log("VERDICT blink-done " ..
      tostring(c.name == "blink" and c.loop == "once" and #c.frames == 3
               and c.frames[1].frame == 0 and c.frames[1].dur == 1
               and c.frames[2].frame == 2 and c.frames[2].dur == 3
               and c.frames[3].frame == 0 and c.frames[3].dur == 1))
end)
probe(556, function()
  local g = ageo()
  crop("anim-clips", g.r.x, g.r.y, g.r.w, g.r.h)
end)

-- ============ step 11: tour, then save ============
D.at(560, function()
  local g = ageo()
  D.click(D.f + 1, rail_row_xy(g, 1)) -- back to idle
end)
probe(566, function()
  local aw = D.win("anim")
  log("VERDICT tour-idle " .. tostring(aw.win.clip == "idle"))
end)
D.tap(570, SC.space)
D.chord(576, SC.ctrl, SC.s)
probe(590, function()
  local root = cm.ed.root
  local clips = anim.load(root .. "/art/hero.anim")
  local walk = clips and anim.find(clips, "walk")
  local idle = clips and anim.find(clips, "idle")
  local blink = clips and anim.find(clips, "blink")
  local ok = clips ~= nil and #clips == 3 and walk and idle and blink
  if ok then -- the game.step math from the doc's snippet, verbatim keys
    ok = anim.frame_at(walk, 0) == 0 and anim.frame_at(walk, 6) == 1
         and anim.frame_at(walk, 11) == 1 and anim.frame_at(walk, 12) == 0
         and anim.duration(idle) == 48
         and blink.loop == "once" and anim.frame_at(blink, 100) == 0
  end
  log("VERDICT saved-anim " .. tostring(ok))
  local dirty = cm.require("cm.ed.win.sprite").dirty(D.win("anim").win, cm.ed)
  log("VERDICT clean " .. tostring(not dirty))
  log("TAPE DONE")
end)
