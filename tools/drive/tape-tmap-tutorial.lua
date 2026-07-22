-- tools/drive/tape-tmap-tutorial.lua — drives win-tmap.md's "build the
-- Moonlit Gate" walkthrough AS WRITTEN (HELPDOCS H6): size/bind a fresh CTLM,
-- fill its wall mass, right-erase the door, paint all six stock variants,
-- pick/erase/undo/redo, save, place it twice on H5's Moonlit Crossing, then
-- edit the shared source and prove both map records still point at the update.
-- VERDICT probes pin the exact cells, saved bytes, and placements.
--
-- THE CAPTURE RECIPE (HELPDOCS §3, chained on H5):
--   1. fresh smoke copy: cp -r projects/smoke <scratch>/smoke-h6
--   2. build the prerequisite map through its own executable lesson:
--        bin/cosmic <scratch>/smoke-h6 --edit --headless \
--          --win 1280x1000 --frames 1721 --eval \
--          "dofile('tools/drive/tape-map-tutorial.lua')"
--      -> H5 must finish 21/21 and save maps/moonlit-crossing.map.
--   3. full H6 proof run:
--        bin/cosmic <scratch>/smoke-h6 --edit --headless \
--          --win 1280x1000 --frames 1131 --eval \
--          "dofile('tools/drive/tape-tmap-tutorial.lua')" \
--          --shot <scratch>/full.png
--      -> every H6 VERDICT line must read true.
--   4. screenshots are the H6 tape's own @2x frames. Repeat steps 1-2 on a
--      FRESH copy per shot, set SHOT, stop at the named frame PLUS ONE, and
--      crop to the logged CROP rectangle:
--        bin/cosmic <copy> --edit --headless --win 1280x1000 \
--          --frames 392 --eval \
--          "rawset(_G,'SHOT','tmap-carve'); dofile('tools/drive/tape-tmap-tutorial.lua')" \
--          --shot raw.png
--      Stage the crops under engine/stock/docs/media as <name>@2x.png, inspect
--      each at source resolution and in the real reader, then montage them.
--
-- Shot frames:
--   f390  tmap-carve · f680 tmap-ruin · f1110 tmap-reused

local D = dofile("tools/drive/drive.lua")
local SC = D.SC
local tmap = cm.require("cm.tmap")
local KEY_K = 14

local TM = "maps/moonlit-gate.tm"
local MAP = "maps/moonlit-crossing.map"

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

local function spawn_kind(f, sx, sy, wanted)
  D.rclick(f, sx, sy)
  D.at(f + 4, function()
    local m = cm.ed.g.menu
    if not m then log("SPAWNMENU MISSING for " .. wanted); return end
    local index, rows = nil, cm.ed.spawnable()
    for n, item in ipairs(rows) do
      if item[1] == wanted or item[2] == wanted then index = n; break end
    end
    if not index then log("SPAWN KIND MISSING " .. wanted); return end
    local iw, ih, pad = 150, 26, 6
    local mx = math.min(m.sx, 1280 - iw - 8)
    local my = math.min(m.sy, 1000 - (#rows * ih + pad * 2) - 8)
    D.click(D.f + 1, mx + 40, my + pad + (index - 1) * ih + ih / 2)
  end)
end

local function replace_text(f, x, y, value)
  D.click(f, x, y)
  D.chord(f + 3, SC.ctrl, SC.a)
  D.at(f + 7, function() return { D.textev(value) } end)
  D.tap(f + 9, SC.enter)
end

local function t_plumb()
  return cm.ed.g.tmw and cm.ed.g.tmw[TM]
end

-- Exact Tilemap draw geometry, expressed through D.win so named shots keep
-- working after D.shot_zoom changes the editor camera to z=2.
local function tgeo()
  local r = D.win("tmap")
  if not r then return nil end
  local z = r.z
  local px = math.max(4, 11 * z)
  local TR, PB, FB = 26 * z, 18 * z, math.max(10, 20 * z)
  local cvh = r.ch - PB - FB - 4 * z
  return { r = r, z = z, px = px, TR = TR, PB = PB, FB = FB,
           cvx = r.cx + TR, cvy = r.cy, cvw = r.cw - TR, cvh = cvh,
           py0 = r.cy + cvh + 2 * z,
           iy = r.cy + cvh + 2 * z + PB + 2 * z }
end

local function tcell(tx, ty)
  local p = t_plumb()
  local v, doc = p and p.canvas_rect, p and p.doc
  if not (v and doc) then return nil end
  return v.ox + (tx + 0.5) * doc.tile * v.zoom,
         v.oy + (ty + 0.5) * doc.tile * v.zoom
end

local function palette_xy(id)
  local g = tgeo()
  local sw = g.PB - 2 * g.z
  return g.r.cx + 2 * g.z + (id - 1) * (sw + 2 * g.z) + sw * 0.5,
         g.py0 + sw * 0.5
end

local function click_palette(f, id)
  D.at(f, function()
    local x, y = palette_xy(id)
    D.click(D.f + 1, x, y)
  end)
end

local function set_tfield(f, index, value)
  D.at(f, function()
    local g = tgeo()
    local x = g.r.cx + 2 * g.z
    local widths = { 30, 30, 30 }
    local labels = { "w", "h", "tile", "tileset" }
    for n, label in ipairs(labels) do
      local lx = x + pal.x_ig_text_size(label, g.px * 0.9, 0) + 3 * g.z
      local w = n <= 3 and widths[n] * g.z
                or math.max(40 * g.z, g.r.cx + g.r.cw - x - 8 * g.z)
      if n == index then
        replace_text(D.f + 1, lx + w * 0.5, g.iy + g.FB * 0.5, value)
        return
      end
      x = lx + w + 6 * g.z
    end
  end)
end

local function type_tpath(f, value)
  D.at(f, function()
    local r = D.win("tmap")
    local fy = r.cy + 8 * r.z + math.max(4, 10 * r.z) * 1.8
    replace_text(D.f + 1, r.cx + 100 * r.z, fy + 8 * r.z, value)
  end)
end

local function drag_cells(f, x0, y0, x1, y1, button)
  D.at(f, function()
    local sx0, sy0 = tcell(x0, y0)
    local sx1, sy1 = tcell(x1, y1)
    D.drag(D.f + 1, sx0, sy0, sx1, sy1,
           math.max(math.abs(x1 - x0), math.abs(y1 - y0), 4) + 2, button)
  end)
end

local function click_cell(f, tx, ty, button)
  D.at(f, function()
    local x, y = tcell(tx, ty)
    D.click(D.f + 1, x, y, button)
  end)
end

local function tgrid(doc)
  local rows = {}
  for y = 0, doc.h - 1 do
    local row = {}
    for x = 0, doc.w - 1 do row[#row + 1] = tostring(tmap.get(doc, x, y)) end
    rows[#rows + 1] = table.concat(row, "")
  end
  return table.concat(rows, "/")
end

local function assets_filter(f, value)
  D.at(f, function()
    local r = D.win("assets")
    local px = math.max(4, 10.5 * r.z)
    local top = px * 1.7 + 8 * r.z
    replace_text(D.f + 1, r.cx + 82 * r.z,
                 r.cy + top + px * 0.85, value)
  end)
end

local function first_asset_xy()
  local r = D.win("assets")
  local px = math.max(4, 10.5 * r.z)
  local top = px * 1.7 + 8 * r.z
  local gy0 = r.cy + top + px * 1.7 + 6 * r.z
  local tile = (r.win.tile or 84) * r.z
  return r.cx + 6 * r.z + tile * 0.5, gy0 + tile * 0.5
end

local function map_plumb()
  return cm.ed.g.mw and cm.ed.g.mw[MAP]
end

local function map_xy(x, y)
  local p = map_plumb()
  local v = p and p.view
  if not v then return nil end
  return v.ox + x * v.zoom, v.oy + y * v.zoom
end

local function map_geo()
  local r = D.win("map")
  if not r then return nil end
  local z, px = r.z, math.max(4, 11 * r.z)
  local insp, lpw = math.max(10, 20 * z), math.max(78, 104 * z)
  return { r = r, z = z, px = px, insp = insp,
           iy = r.cy + (r.ch - insp - 2 * z) + 2 * z }
end

local function set_place_field(f, index, value)
  D.at(f, function()
    local g = map_geo()
    local x = g.r.cx + 2 * g.z
    for n, spec in ipairs({ { "x", 34 }, { "y", 34 }, { "name", 52 },
                            { "L", 22 } }) do
      local lx = x + pal.x_ig_text_size(spec[1], g.px * 0.9, 0) + 3 * g.z
      local w = spec[2] * g.z
      if n == index then
        replace_text(D.f + 1, lx + w * 0.5, g.iy + g.insp * 0.5, value)
        return
      end
      x = lx + w + 6 * g.z
    end
  end)
end

local function click_active_layer_lock(f)
  D.at(f, function()
    local g = map_geo()
    local lpw = math.max(78, 104 * g.z)
    local cvw = g.r.cw - lpw - 4 * g.z
    local x0, y0 = g.r.cx + cvw + 4 * g.z, g.r.cy
    local pad = 4 * g.z
    local rowh = math.max(12, g.px + 5 * g.z)
    local lockw = pal.x_ig_text_size("lock", g.px * 0.8, 0) + 8 * g.z
    D.click(D.f + 1, x0 + lpw - pad - lockw * 0.5,
            y0 + pad + (rowh - g.z) * 0.5)
  end)
end

local function drag_first_asset_to_map(f, mx, my)
  D.at(f, function()
    cm.ed.g.aclick = nil
    local x0, y0 = first_asset_xy()
    local x1, y1 = map_xy(mx, my)
    D.at(D.f + 1, function() return { D.keyev(SC.ctrl, true) } end)
    D.drag(D.f + 3, x0, y0, x1, y1, 8)
    D.at(D.f + 16, function() return { D.keyev(SC.ctrl, false) } end)
  end)
end

-- Map's custom header strip is right-to-left. Reconstruct it from the stored
-- left edge so the proof clicks the real giz/mk chips at either camera scale.
local function map_header_chip_xy(wanted)
  local g = map_geo()
  local hdrx = cm.ed.g.hdrx[g.r.win.id]
  local px = math.max(4, 10.5 * g.z)
  local labels = { "mk", "giz", "lyr", "mkr", "col", "sel", "move" }
  local used = 5 * g.z
  for _, label in ipairs(labels) do
    used = used + pal.x_ig_text_size(label, px, 0) + 15 * g.z
  end
  local x = hdrx + used
  for n, label in ipairs(labels) do
    if n == 4 then x = x - 5 * g.z end
    local w = pal.x_ig_text_size(label, px, 0) + 12 * g.z
    x = x - w - 3 * g.z
    if label == wanted then return x + w * 0.5, g.r.y + 12 * g.z end
  end
end

local function click_map_header(f, label)
  D.at(f, function()
    local x, y = map_header_chip_xy(label)
    D.click(D.f + 1, x, y)
  end)
end

local function click_tmap_edit(f)
  D.at(f, function()
    local r = D.win("tmap")
    local w = pal.x_ig_text_size("edit", math.max(4, 10.5 * r.z), 0)
              + 14 * r.z
    local x = cm.ed.g.hdrx[r.win.id] + 4 * r.z + w * 0.5
    D.click(D.f + 1, x, r.y + 12 * r.z)
  end)
end

local function ctrl_shift_tab(f)
  D.at(f, function()
    return { D.keyev(SC.ctrl, true), D.keyev(SC.shift, true) }
  end)
  D.at(f + 1, function() return { D.keyev(SC.tab, true) } end)
  D.at(f + 2, function() return { D.keyev(SC.tab, false) } end)
  D.at(f + 3, function()
    return { D.keyev(SC.shift, false), D.keyev(SC.ctrl, false) }
  end)
end

-- @2x capture declarations and post-zoom pointer refreshes. The refreshed
-- pointer makes each coordinate/status bay describe the captured scale.
D.shot_zoom("tmap-carve", 390, "tmap")
D.shot_zoom("tmap-ruin", 680, "tmap")
D.shot_zoom("tmap-reused", 1110, "map")
if rawget(_G, "SHOT") == "tmap-carve" then
  D.at(389, function() local x,y=tcell(4,5); return { D.mouse(x,y) } end)
elseif rawget(_G, "SHOT") == "tmap-ruin" then
  D.at(679, function() local x,y=tcell(6,3); return { D.mouse(x,y) } end)
elseif rawget(_G, "SHOT") == "tmap-reused" then
  D.at(1109, function() local x,y=map_xy(408,176); return { D.mouse(x,y) } end)
end

-- ============ stage 0: H5 artifacts stay, its windows leave ==============
for k = 0, 21 do
  D.chord(4 + k * 8, SC.ctrl, SC.tab)
  D.chord(8 + k * 8, SC.ctrl, SC.w)
end
probe(182, function()
  cm.ed.g.anim = nil
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
  verdict("quiet-h5-canvas", #cm.ed.doc.wins == 0
          and pal.read_file(cm.ed.root .. "/" .. MAP) ~= nil,
          "wins=" .. #cm.ed.doc.wins)
end)

-- Steps 1-2: create the CTLM and enter its four metadata values.
spawn_kind(184, 60, 60, "tmap")
probe(202, function()
  local r = D.win("tmap")
  verdict("unbound-tmap", r ~= nil and r.win.path == "")
end)
type_tpath(210, TM)
probe(232, function()
  local r, p = D.win("tmap"), t_plumb()
  verdict("tmap-created", r and r.win.path == TM and r.win.edit == true
          and p and p.doc and p.doc.w == 16 and p.doc.h == 16)
end)
set_tfield(238, 1, "7")
set_tfield(254, 2, "6")
set_tfield(270, 4, "art/tiles.spr")
probe(292, function()
  local d = t_plumb().doc
  verdict("grid-metadata", d.w == 7 and d.h == 6 and d.tile == 16
          and d.tileset == "art/tiles.spr" and #d.cells == 84,
          ("%dx%d@%d"):format(d.w, d.h, d.tile))
end)

-- Steps 3-5: Enter left the window focused. Choose via the palette (not a
-- sacrificial grid click), fill the five-row mass, right-fill its doorway away.
click_palette(310, 2)
D.tap(318, SC.f)
drag_cells(330, 0, 1, 6, 5)
probe(350, function()
  local d = t_plumb().doc
  local got = tgrid(d)
  verdict("wall-mass",
          got == "0000000/2222222/2222222/2222222/2222222/2222222", got)
end)
drag_cells(360, 2, 3, 4, 5, 3)
probe(382, function()
  local d = t_plumb().doc
  local got = tgrid(d)
  verdict("right-carved-door", got
          == "0000000/2222222/2222222/2200022/2200022/2200022"
          and D.win("tmap").win.tool == "fill", got)
end)
probe(390, function()
  local r = D.win("tmap"); crop("tmap-carve", r.x, r.y, r.w, r.h)
end)

-- Steps 6-7: top, two outer edges, two pillar jambs, four cap stones.
click_palette(400, 1)
D.tap(408, SC.p)
drag_cells(414, 0, 1, 6, 1)
click_palette(432, 3)
drag_cells(440, 0, 2, 0, 5)
click_palette(456, 4)
drag_cells(464, 6, 2, 6, 5)
probe(480, function()
  local got = tgrid(t_plumb().doc)
  verdict("dressed-edges",
          got == "0000000/1111111/3222224/3200024/3200024/3200024", got)
end)
click_palette(488, 6)
drag_cells(496, 1, 3, 1, 5)
drag_cells(512, 5, 3, 5, 5)
click_palette(530, 5)
click_cell(536, 0, 0)
click_cell(544, 1, 0)
click_cell(552, 5, 0)
click_cell(560, 6, 0)

-- Step 8: change selection, then recover slab #5 from a painted cap.
click_palette(568, 1)
D.tap(576, KEY_K)
click_cell(582, 0, 0)
probe(590, function()
  verdict("picked-cap", D.win("tmap").win.tool == "pick"
          and D.win("tmap").win.tid == 5)
end)
D.tap(596, SC.p)
click_cell(602, 3, 0)

-- Step 9: explicit eraser, pen's right-button erase, then undo/redo that chip.
D.tap(612, SC.e)
click_cell(620, 0, 4)
D.tap(630, SC.p)
click_cell(638, 6, 3, 3)
probe(646, function()
  local d = t_plumb().doc
  verdict("ruined-gaps", tgrid(d)
          == "5505055/1111111/3222224/3600060/0600064/3600064")
end)
D.chord(650, SC.ctrl, SC.z)
probe(658, function()
  verdict("undo-one-gesture", tmap.get(t_plumb().doc, 6, 3) == 4)
end)
D.chord(664, SC.ctrl, SC.y)
probe(674, function()
  verdict("redo-one-gesture", tmap.get(t_plumb().doc, 6, 3) == 0)
end)
probe(680, function()
  local r = D.win("tmap"); crop("tmap-ruin", r.x, r.y, r.w, r.h)
end)

-- Step 10: durable CTLM, view mode, then close only the window.
D.chord(690, SC.ctrl, SC.s)
probe(710, function()
  local r = D.win("tmap")
  local bytes = pal.read_file(cm.ed.root .. "/" .. TM)
  local ok, d = pcall(tmap.decode, bytes or "")
  verdict("tmap-saved", ok and tgrid(d)
          == "5505055/1111111/3222224/3600060/0600064/3600064"
          and not cm.ed.kinds.tmap.dirty(r.win, cm.ed))
end)
click_tmap_edit(720) -- edit -> done
D.chord(730, SC.ctrl, SC.w)

-- Steps 11-12: Assets opens H5's map; one drop + Ctrl+D make two references.
spawn_kind(740, 40, 50, "assets")
probe(758, function() verdict("assets-open", D.win("assets") ~= nil) end)
assets_filter(764, "moonlit-crossing.map")
D.at(780, function()
  cm.ed.g.aclick = nil
  local x, y = first_asset_xy()
  D.click(D.f + 1, x, y)
  D.click(D.f + 6, x, y)
end)
probe(806, function()
  local r, p = D.win("map"), map_plumb()
  verdict("h5-map-open", r and r.win.path == MAP and p and p.doc
          and #p.doc.places == 3 and #p.doc.layers == 2)
end)
assets_filter(812, "moonlit-gate")
probe(828, function()
  verdict("gate-in-assets", D.win("assets").win.filter == "moonlit-gate")
end)
drag_first_asset_to_map(840, 72, 176)
probe(862, function()
  local d = map_plumb().doc
  local p = d.places[#d.places]
  verdict("first-gate-placed", #d.places == 4 and p.path == TM
          and p.x == 16 and p.y == 128 and p.layer == 2)
end)
D.chord(868, SC.ctrl, SC.d)
probe(878, function()
  local d = map_plumb().doc
  local p = d.places[#d.places]
  verdict("gate-duplicated", #d.places == 5 and p.path == TM
          and p.x == 24 and p.y == 136 and p.layer == 2)
end)
set_place_field(884, 1, "352")
set_place_field(900, 2, "128")
probe(918, function()
  local d = map_plumb().doc
  local a, b = d.places[4], d.places[5]
  verdict("two-exact-gates", a.path == TM and b.path == TM
          and a.x == 16 and a.y == 128 and b.x == 352 and b.y == 128
          and a.layer == 2 and b.layer == 2)
end)
click_map_header(930, "giz")
click_map_header(940, "mk")
D.chord(950, SC.ctrl, SC.s)
probe(970, function()
  local r = D.win("map")
  local bytes = pal.read_file(cm.ed.root .. "/" .. MAP)
  local ok, d = pcall(cm.require("cm.map").decode, bytes or "")
  verdict("map-saved-with-reuse", ok and #d.places == 5
          and d.places[4].path == TM and d.places[5].path == TM
          and not cm.ed.kinds.map.dirty(r.win, cm.ed))
end)

-- Step 13: double-open either placement, add one cap, save once, return.
click_active_layer_lock(972) -- graybox beneath cannot join the click drill
D.at(978, function()
  local x, y = map_xy(72, 160)
  D.click(D.f + 1, x, y)
  D.click(D.f + 7, x, y)
end)
probe(1000, function()
  local r = D.win("tmap")
  verdict("placement-opened-source", r ~= nil and r.win.path == TM
          and r.win.edit == false)
end)
D.chord(1006, SC.ctrl, SC.tab) -- map -> new tmap; reveal it
click_tmap_edit(1022)
probe(1032, function()
  verdict("shared-source-edit", D.win("tmap").win.edit == true)
end)
D.tap(1038, KEY_K)
click_cell(1044, 3, 0)
D.tap(1052, SC.p)
click_cell(1058, 4, 0)
D.chord(1066, SC.ctrl, SC.s)
probe(1082, function()
  local bytes = pal.read_file(cm.ed.root .. "/" .. TM)
  local ok, d = pcall(tmap.decode, bytes or "")
  verdict("one-save-updates-source", ok and tgrid(d)
          == "5505555/1111111/3222224/3600060/0600064/3600064")
end)
ctrl_shift_tab(1088) -- tmap -> map, with reveal
probe(1102, function()
  local r, d = D.win("map"), map_plumb().doc
  verdict("both-still-share-update", r and r.win.path == MAP
          and d.places[4].path == TM and d.places[5].path == TM
          and not cm.ed.kinds.map.dirty(r.win, cm.ed))
end)
probe(1110, function()
  local r = D.win("map"); crop("tmap-reused", r.x, r.y, r.w, r.h)
end)
probe(1120, function()
  verdict("summary", FAIL == 0, ("%d/%d"):format(PASS, PASS + FAIL))
  log("TAPE DONE")
end)
