-- tools/drive/tape-assets-stock-tutorial.lua — drives the paired
-- win-assets.md / win-stock.md "curate the moonlit courier kit" walkthrough
-- AS WRITTEN (HELPDOCS H4): organize H1's sprite into a real folder, prove
-- its open window follows, route an image into the stamp well, audition and
-- adopt a stock song, copy and rename a stock instrument, then bind that
-- project-local instrument into the song. VERDICT probes and CROP lines make
-- the tutorial executable documentation rather than illustrative prose.
--
-- THE CAPTURE RECIPE (HELPDOCS §3, chained on H1 for art/hero.spr):
--   1. fresh smoke copy:   cp -r projects/smoke <scratch>/smoke-h4
--   2. the H1 prologue:    bin/cosmic <scratch>/smoke-h4 --edit --headless \
--        --win 1280x800 --frames 900 --eval \
--        "dofile('tools/drive/tape-sprite-tutorial.lua')"
--      -> art/hero.spr plus its baked family exist, and its view window
--         persists in the session.
--   3. full proof run:     bin/cosmic <scratch>/smoke-h4 --edit --headless \
--        --win 1280x800 --frames 820 --eval \
--        "dofile('tools/drive/tape-assets-stock-tutorial.lua')" \
--        --shot <scratch>/full.png
--      -> every VERDICT line must read true.
--   4. screenshots are the tape's own frames at @2x (D163). Repeat steps
--      1-2 on a FRESH copy per shot, then run step 3 with SHOT set and
--      --frames at the shot frame PLUS ONE (the drive plan fires one frame
--      behind the process counter), and crop to the logged CROP rect:
--        bin/cosmic <copy> ... --win 1280x1000 --frames 106 --eval \
--          "rawset(_G,'SHOT','assets-rename'); dofile('tools/drive/tape-assets-stock-tutorial.lua')" \
--          --shot raw.png
--        magick raw.png -crop WxH+X+Y media/assets-rename@2x.png
--      The assets-drag rerun restages the already-proven carry one frame
--      before capture, after the @2x camera move, so the real drag ghost and
--      hot destination well are visible without remapping an active gesture.
--      One-result browser shots also move the REAL lower border around their
--      live rows before capture; proof/default windows retain ordinary sizes.
--   5. stage crops as media/<name>@2x.png (layout <=700x550), inspect each,
--      and push a montage to llm-feed with a title + taste-check note.
--
-- Shot frames (stable while the tape above them is unchanged):
--   f105 assets-rename  · f215 assets-drag
--   f320 stock-filter   · f365 stock-unsaved

local D = dofile("tools/drive/drive.lua")
local SC = D.SC

local OLD_HERO = "art/hero.spr"
local HERO = "art/characters/moonrunner.spr"
local STAMP = "art/plank.png"
local STOCK_SONG = "engine/stock/songs/noir-sleuth.song"
local SONG0 = "sound/noir-sleuth.song"
local SONG = "sound/moonlit-route.song"
local STOCK_INS = "engine/stock/ins/fm-glass.ins"
local INS0 = "ins/fm-glass.ins"
local INS = "ins/moon-glass.ins"

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

local function latest(kind)
  local out
  for _, w in ipairs(cm.ed.doc.wins) do
    if w.kind == kind then out = w end
  end
  return out
end

local function spawn_kind(f, sx, sy, wanted)
  D.rclick(f, sx, sy)
  D.at(f + 4, function()
    local m = cm.ed.g.menu
    if not m then log("SPAWNMENU MISSING for " .. wanted); return end
    local index, count
    local rows = cm.ed.spawnable()
    count = #rows
    for n, item in ipairs(rows) do
      if item[1] == wanted then index = n; break end
    end
    if not index then log("SPAWN KIND MISSING " .. wanted); return end
    local iw, ih, pad = 150, 26, 6
    local mx = math.min(m.sx, 1280 - iw - 8)
    local my = math.min(m.sy, 800 - (count * ih + pad * 2) - 8)
    D.click(D.f + 1, mx + 40, my + pad + (index - 1) * ih + ih / 2)
  end)
end

local function chips(kind)
  return kind == "stock" and { "all", "ins", "songs", "art", "fig", "pal" }
         or { "all", "code", "image", "sound" }
end

local function chip_xy(kind, label)
  local r = D.win(kind)
  local x = r.cx + 4 * r.z
  local y = r.cy + 3 * r.z
  local px = math.max(4, 10.5 * r.z)
  local h = px * 1.7
  for _, name in ipairs(chips(kind)) do
    local w = pal.x_ig_text_size(name, px, 0) + 14 * r.z
    if name == label then return x + w * 0.5, y + h * 0.5 end
    x = x + w + 4 * r.z
  end
end

local function choose_chip(f, kind, label)
  D.at(f, function()
    local x, y = chip_xy(kind, label)
    D.click(D.f + 1, x, y)
  end)
end

local function filter_xy(kind)
  local r = D.win(kind)
  local px = math.max(4, 10.5 * r.z)
  local top = px * 1.7 + 8 * r.z
  return r.cx + 80 * r.z, r.cy + top + px * 0.85
end

local function set_filter(f, kind, value)
  D.at(f, function()
    local x, y = filter_xy(kind)
    D.click(D.f + 1, x, y)
    D.chord(D.f + 4, SC.ctrl, SC.a)
    D.at(D.f + 8, function() return { D.textev(value) } end)
  end)
end

local function first_tile_xy(kind)
  local r = D.win(kind)
  local px = math.max(4, 10.5 * r.z)
  local top = px * 1.7 + 8 * r.z
  local gy0 = r.cy + top + px * 1.7 + 6 * r.z
  local tile = (r.win.tile or 84) * r.z
  return r.cx + 6 * r.z + tile * 0.5, gy0 + tile * 0.5
end

local function click_first(f, kind)
  D.at(f, function()
    local x, y = first_tile_xy(kind)
    D.click(D.f + 1, x, y)
  end)
end

local function double_first(f, kind, clock_key)
  D.at(f, function()
    cm.ed.g[clock_key] = nil
    local x, y = first_tile_xy(kind)
    D.click(D.f + 1, x, y)
    D.click(D.f + 6, x, y)
  end)
end

local function rename_field_xy()
  local r = D.win("assets")
  local px = math.max(4, 10.5 * r.z)
  local by = r.cy + r.ch - px * 1.6
  local lx = r.cx + 6 * r.z
       + pal.x_ig_text_size("rename:", px * 0.9, 0) + 6 * r.z
  return lx + 90 * r.z, by + px * 0.65
end

local function begin_rename(f, path)
  D.tap(f, SC.r)
  D.at(f + 5, function()
    local x, y = rename_field_xy()
    D.click(D.f + 1, x, y)
    D.chord(D.f + 4, SC.ctrl, SC.a)
    D.at(D.f + 8, function() return { D.textev(path) } end)
  end)
end

local function sprite_edit(f)
  D.at(f, function()
    local r = D.win("sprite")
    local hdrx = cm.ed.g.hdrx[r.win.id]
    local we = pal.x_ig_text_size("edit", 10.5 * r.z, 0) + 14 * r.z
    local wa = pal.x_ig_text_size("anim", 10.5 * r.z, 0) + 14 * r.z
    local used = we + 4 * r.z + wa + 4 * r.z
    D.click(D.f + 1, hdrx + used - we * 0.5, r.y + 12 * r.z)
  end)
end

-- Capture-only fit for the music window: its ordinary 720px width is 20px
-- over the reader's 700px layout budget. The proof/tutorial retain the real
-- default; the named shot moves the actual border to 680 before @2x capture.
if rawget(_G, "SHOT") == "assets-rename" then
  D.at(101, function()
    local w = latest("assets")
    if w then w.h = 250; cm.ed.touch() end
  end)
elseif rawget(_G, "SHOT") == "stock-filter" then
  D.at(316, function()
    local w = latest("stock")
    if w then w.h = 230; cm.ed.touch() end
  end)
elseif rawget(_G, "SHOT") == "stock-unsaved" then
  D.at(361, function()
    local w = latest("music")
    if w then w.w = 680; cm.ed.touch() end
  end)
end

D.shot_zoom("assets-rename", 105, "assets")
D.shot_zoom("assets-drag", 215, "sprite")
D.shot_zoom("stock-filter", 320, "stock")
D.shot_zoom("stock-unsaved", 365, "music")

-- ============ stage 0: H1's saved hero is the real project fixture =========
probe(4, function()
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  local hero = latest("sprite")
  if hero then hero.x, hero.y = 650, 70 end
  cm.ed.g.anim = nil
  cm.ed.touch()
  verdict("h1-fixture", hero ~= nil and hero.path == OLD_HERO
          and pal.read_file(cm.ed.root .. "/" .. OLD_HERO) ~= nil
          and pal.read_file(cm.ed.root .. "/art/hero.png") ~= nil)
end)

-- ============ steps 1-3: filter, select, rename + move as one action ========
spawn_kind(12, 80, 70, "assets")
probe(30, function()
  local r = D.win("assets")
  verdict("assets-open", r ~= nil and r.z == 1)
end)
choose_chip(34, "assets", "image")
set_filter(42, "assets", "hero")
probe(58, function()
  local r = D.win("assets")
  verdict("hero-filter", r and r.win.chip == "image"
          and r.win.filter == "hero")
end)
click_first(62, "assets")
probe(70, function()
  verdict("hero-selected", D.win("assets").win.sel == OLD_HERO)
end)
begin_rename(74, HERO)
probe(96, function()
  local a = cm.ed.g.arn
  verdict("rename-armed", a and a.path == OLD_HERO and a.buf == HERO)
end)
probe(105, function()
  local r = D.win("assets")
  crop("assets-rename", r.x, r.y, r.w, r.h)
end)
D.tap(110, SC.enter)
probe(126, function()
  local hero = D.win("sprite")
  local ok = hero and hero.win.path == HERO
             and pal.read_file(cm.ed.root .. "/" .. OLD_HERO) == nil
             and pal.read_file(cm.ed.root .. "/" .. HERO) ~= nil
             and pal.read_file(cm.ed.root .. "/art/hero.png") == nil
             and pal.read_file(cm.ed.root .. "/art/characters/moonrunner.png")
                 ~= nil
  verdict("rename-family-and-window", ok)
end)

-- ============ steps 4-5: route a project image into the stamp well =========
set_filter(134, "assets", "plank")
-- First carry: release on bare canvas, where the shell opens the matching
-- inspector at the drop point.
D.at(148, function()
  cm.ed.g.aclick = nil
  local x0, y0 = first_tile_xy("assets")
  D.drag(D.f + 1, x0, y0, 220, 540, 6)
end)
probe(164, function()
  local image = D.win("image")
  verdict("canvas-drop-opens", image and image.win.path == STAMP)
end)
sprite_edit(170)
probe(182, function()
  local hero = D.win("sprite")
  verdict("hero-edit", hero and hero.win.edit == true)
end)
D.at(188, function()
  cm.ed.g.aclick = nil
  local a = D.win("assets")
  local x0, y0 = first_tile_xy("assets")
  local hero = D.win("sprite")
  local p = cm.ed.g.sw and cm.ed.g.sw[HERO]
  local well = p and p.wellrect
  if not (a and hero and well) then log("STAMP DRAG GEOMETRY MISSING"); return end
  D.drag(D.f + 1, x0, y0, well.x + well.w * 0.5,
         well.y + well.h * 0.5, 8)
end)
probe(210, function()
  local hero = D.win("sprite")
  verdict("stamp-well-drop", hero and hero.win.stamp == STAMP
          and hero.win.tool == "stamp")
end)

-- The named screenshot pauses a fresh carry over the already-proven well.
-- It is injected only after shot_zoom has moved the camera, so this is a real
-- shell drag state at @2x rather than a 1x bitmap enlarged after capture.
if rawget(_G, "SHOT") == "assets-drag" then
  D.at(214, function()
    local hero = D.win("sprite")
    local p = cm.ed.g.sw and cm.ed.g.sw[HERO]
    local well = p and p.wellrect
    if not (hero and well) then return end
    local x, y = well.x + well.w * 0.5, well.y + well.h * 0.5
    local from = D.win("assets")
    cm.ed.g.adrag = { path = STAMP, sx = x - 24, sy = y - 18,
                      from = from and from.win.id, moved = true }
    return { D.mouse(x, y), D.btn(x, y, true) }
  end)
end
probe(215, function()
  local r = D.win("sprite")
  crop("assets-drag", r.x, r.y, r.w, r.h)
end)
D.tap(218, SC.p) -- keep the adopted stamp in its well, return to ordinary paint

-- ============ steps 6-9: shop, filter, open unsaved, audition, save =========
probe(226, function()
  -- Layout staging only: keep the next window readable and the spawn point
  -- empty. Window positions are not part of either asset workflow.
  local a, s = latest("assets"), latest("sprite")
  if a then a.x, a.y = 720, 70 end
  if s then s.x, s.y = 720, 440 end
  cm.ed.doc.focus = 0
  cm.ed.touch()
end)
spawn_kind(234, 80, 70, "stock")
probe(252, function()
  verdict("stock-open", D.win("stock") ~= nil)
end)
choose_chip(256, "stock", "songs")
set_filter(266, "stock", "noir")
click_first(288, "stock")
probe(304, function()
  local r = D.win("stock")
  verdict("stock-song-filter", r and r.win.chip == "songs"
          and r.win.filter == "noir" and r.win.sel == STOCK_SONG)
end)
probe(320, function()
  local r = D.win("stock")
  crop("stock-filter", r.x, r.y, r.w, r.h)
end)
double_first(328, "stock", "stclick")
probe(352, function()
  local r = D.win("music")
  local K = cm.ed.kinds.music
  verdict("song-open-unsaved", r and r.win.path == SONG0
          and K.dirty(r.win, cm.ed)
          and pal.read_file(cm.ed.root .. "/" .. SONG0) == nil)
end)
probe(365, function()
  local r = D.win("music")
  crop("stock-unsaved", r.x, r.y, r.w, r.h)
end)
D.tap(374, SC.space)
probe(384, function()
  local p = cm.ed.g.muw and cm.ed.g.muw[SONG0]
  verdict("song-audition-playing", p and p.playing == true)
end)
D.tap(390, SC.space)
D.chord(400, SC.ctrl, SC.s)
probe(416, function()
  local r = D.win("music")
  verdict("song-adopted", pal.read_file(cm.ed.root .. "/" .. SONG0) ~= nil
          and r and not cm.ed.kinds.music.dirty(r.win, cm.ed))
end)

-- ============ step 10: give the adopted song a project-specific name =======
probe(424, function()
  local a, m, st = latest("assets"), latest("music"), latest("stock")
  if a then a.x, a.y = 60, 70 end
  if m then m.x, m.y = 600, 70 end
  if st then st.x, st.y = 1600, 70 end
  cm.ed.touch()
end)
choose_chip(430, "assets", "sound")
set_filter(440, "assets", "noir")
click_first(456, "assets")
begin_rename(466, SONG)
D.tap(488, SC.enter)
probe(502, function()
  local m = D.win("music")
  verdict("song-renamed", m and m.win.path == SONG
          and pal.read_file(cm.ed.root .. "/" .. SONG0) == nil
          and pal.read_file(cm.ed.root .. "/" .. SONG) ~= nil)
end)

-- ============ steps 11-12: copy an instrument, open, audition, rename =======
probe(508, function()
  local st, a, m = latest("stock"), latest("assets"), latest("music")
  if st then st.x, st.y = 60, 70 end
  if a then a.x, a.y = 650, 70 end
  if m then m.x, m.y = 650, 430 end
  cm.ed.touch()
end)
choose_chip(514, "stock", "ins")
set_filter(524, "stock", "fm-glass")
click_first(542, "stock")
D.tap(550, SC.c)
probe(564, function()
  verdict("instrument-copied",
    pal.read_file(cm.ed.root .. "/" .. INS0)
      == pal.read_file(STOCK_INS)
    and cm.ed.g.aflash and cm.ed.g.aflash.path == INS0)
end)
probe(570, function()
  local a, st = latest("assets"), latest("stock")
  if a then a.x, a.y = 60, 70 end
  if st then st.x, st.y = 720, 70 end
  cm.ed.touch()
end)
choose_chip(576, "assets", "sound")
set_filter(586, "assets", "fm-glass")
double_first(604, "assets", "aclick")
probe(626, function()
  local s = D.win("synth")
  verdict("instrument-open-clean", s and s.win.path == INS0
          and not cm.ed.kinds.synth.dirty(s.win, cm.ed))
end)
D.hold(632, SC.z, 8)
probe(644, function()
  cm.ed.g.aclick = nil
  local x, y = first_tile_xy("assets")
  D.click(D.f + 1, x, y)
end)
begin_rename(652, INS)
D.tap(674, SC.enter)
probe(688, function()
  local s = D.win("synth")
  verdict("instrument-renamed", s and s.win.path == INS
          and pal.read_file(cm.ed.root .. "/" .. INS0) == nil
          and pal.read_file(cm.ed.root .. "/" .. INS) ~= nil)
end)

-- ============ steps 13-14: bind local instrument to song, save kit =========
probe(694, function()
  local a, m, st, sy = latest("assets"), latest("music"),
                        latest("stock"), latest("synth")
  if a then a.x, a.y, a.w, a.h = 60, 70, 360, 330 end
  if m then m.x, m.y = 440, 70 end
  if st then st.x, st.y = 2000, 70 end
  if sy then sy.x, sy.y = 2000, 650 end
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
end)
set_filter(700, "assets", "moon-glass")
D.at(720, function()
  -- This is a new drag gesture, not the second click of the earlier open.
  -- Headless frames can run quickly enough that the wall-clock double-click
  -- threshold still spans those tutorial beats, so reset only the ephemeral
  -- click clock before pressing the tile again.
  cm.ed.g.aclick = nil
  local x0, y0 = first_tile_xy("assets")
  local m = D.win("music")
  local p = cm.ed.g.muw and cm.ed.g.muw[SONG]
  local rd = p and p.rdrop and p.rdrop[m.win.id]
  local row = rd and rd.rows and rd.rows[1]
  if not (m and row) then log("MUSIC DROP GEOMETRY MISSING"); return end
  D.drag(D.f + 1, x0, y0, rd.x0 + 30,
         (row.y0 + row.y1) * 0.5, 8)
end)
probe(744, function()
  local m = D.win("music")
  local p = cm.ed.g.muw and cm.ed.g.muw[SONG]
  local tr = p and p.doc and p.doc.tracks[1]
  verdict("local-instrument-bound", m and tr and tr.ins == INS
          and cm.ed.kinds.music.dirty(m.win, cm.ed))
end)
D.chord(752, SC.ctrl, SC.s)
probe(772, function()
  local bytes = pal.read_file(cm.ed.root .. "/" .. SONG)
  local ok, doc = pcall(cm.require("cm.song").decode, bytes or "")
  verdict("finished-kit-on-disk", ok and doc.tracks[1].ins == INS
          and pal.read_file(cm.ed.root .. "/" .. HERO) ~= nil
          and pal.read_file(cm.ed.root .. "/" .. INS) ~= nil)
  verdict("summary", FAIL == 0, ("%d/%d"):format(PASS, PASS + FAIL))
  log("TAPE DONE")
end)
