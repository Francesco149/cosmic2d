-- tools/drive/tape-music-tutorial.lua — drives win-music.md's "arrange
-- Moonlit Relay" walkthrough AS WRITTEN (HELPDOCS H8): create a four-track
-- song from H7's kick/bass/lead, import a stock hat through a real drag,
-- author three looping backing patterns plus linked/answer lead patterns,
-- exercise held auditions, selection/move, ghost paste, velocity, clips,
-- exact stereo mix fields, transport, save, and canonical CSNG playback data.
-- VERDICT probes pin every meaningful intermediate and final state.
--
-- THE CAPTURE RECIPE (HELPDOCS §3, chained on H7):
--   1. fresh smoke copy: cp -r projects/smoke <scratch>/smoke-h8
--   2. build the prerequisite instrument kit through its executable lesson:
--        bin/cosmic <scratch>/smoke-h8 --edit --headless \
--          --win 1280x1200 --frames 990 --eval \
--          "dofile('tools/drive/tape-synth-tutorial.lua')"
--      -> H7 must finish with every VERDICT true and save lead/bass/kick.
--   3. full H8 proof run:
--        bin/cosmic <scratch>/smoke-h8 --edit --headless \
--          --win 1280x1000 --frames 1810 --eval \
--          "dofile('tools/drive/tape-music-tutorial.lua')" \
--          --shot <scratch>/full.png
--      -> every H8 VERDICT line must read true.
--   4. screenshots are the H8 tape's own @2x frames. Repeat steps 1-2 on a
--      FRESH copy per shot, set SHOT, use --win 1440x1000, stop at the named
--      frame PLUS ONE, and crop to the logged CROP rectangle:
--        bin/cosmic <copy> --edit --headless --win 1440x1000 \
--          --frames 861 --eval \
--          "rawset(_G,'SHOT','music-roll'); dofile('tools/drive/tape-music-tutorial.lua')" \
--          --shot raw.png
--      Stage under engine/stock/docs/media as <name>@2x.png, inspect each at
--      source resolution and in the real reader, then montage them.
--
-- Shot frames:
--   f860 music-roll · f1460 music-arrangement · f1670 music-mix

local D = dofile("tools/drive/drive.lua")
local SC = D.SC
local song = cm.require("cm.song")

local SONG = "sound/moonlit-relay.song"
local INS = {
  "ins/kick.ins", "ins/gb-noise-hat.ins", "ins/bass.ins", "ins/lead.ins",
}
local BAR = song.PPQ * 4

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
    local index, rows
    rows = cm.ed.spawnable()
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

local function type_music_path(f, value)
  D.at(f, function()
    local r = D.win("music")
    local fy = r.cy + 8 * r.z + math.max(4, 10 * r.z) * 1.8
    replace_text(D.f + 1, r.cx + 105 * r.z, fy + 8 * r.z, value)
  end)
end

local function plumb()
  return cm.ed.g.muw and cm.ed.g.muw[SONG]
end

local function doc()
  local p = plumb()
  return p and p.doc
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

local function track_xy(ti)
  local r, p = D.win("music"), plumb()
  local rd = p and p.rdrop and p.rdrop[r.win.id]
  local row = rd and rd.rows and rd.rows[ti]
  if not row then return nil end
  return rd.x0 + 34 * r.z, row.y0 + 11 * r.z
end

local function click_track(f, ti)
  D.at(f, function()
    local x, y = track_xy(ti)
    if not x then log("TRACK GEOMETRY MISSING " .. ti); return end
    D.click(D.f + 1, x, y)
  end)
end

local function click_add_track(f)
  D.at(f, function()
    local r, p = D.win("music"), plumb()
    local rd = p and p.rdrop and p.rdrop[r.win.id]
    local rows = rd and rd.rows
    local last = rows and rows[#rows]
    if not last then log("+TRACK GEOMETRY MISSING"); return end
    D.click(D.f + 1, rd.x0 + 28 * r.z, last.y1 + 8 * r.z)
  end)
end

local function drag_first_to_track(f, kind, ti)
  D.at(f, function()
    cm.ed.g.aclick, cm.ed.g.stclick = nil, nil
    local x0, y0 = first_tile_xy(kind)
    local x1, y1 = track_xy(ti)
    if not (x0 and x1) then log("INSTRUMENT DRAG GEOMETRY MISSING"); return end
    D.drag(D.f + 1, x0, y0, x1, y1, 8)
  end)
end

local function arr_xy(tick, lane)
  local p = plumb()
  local a = p and p.arr
  if not a then return nil end
  return a.x + (tick - a.t0) * a.atpp,
         a.y + lane * a.lane_h - a.sy + a.lane_h * 0.5
end

local function click_arr(f, tick, lane)
  D.at(f, function()
    local x, y = arr_xy(tick, lane)
    D.click(D.f + 1, x + 2 * D.win("music").z, y)
  end)
end

local function roll_xy(tick, pitch)
  local r, p = D.win("music"), plumb()
  local v = p and p.view
  if not (r and v) then return nil end
  local z = r.z
  local tpp = (r.win.tpp or 0.5) * z
  local lowf = r.win.lownote or 45
  local low = math.floor(lowf)
  local suby = (lowf - low) * v.row_h
  local nrows = math.tointeger(v.rh // v.row_h) or 0
  return v.rx + (tick - (r.win.tick0 or 0)) * tpp + 1.5 * z,
         v.ry + (low + nrows - pitch + 0.5) * v.row_h - suby
end

local function click_note(f, tick, pitch, button)
  D.at(f, function()
    local x, y = roll_xy(tick, pitch)
    D.click(D.f + 1, x, y, button)
  end)
end

local function hold_note(f, tick, pitch, frames)
  D.at(f, function()
    local x, y = roll_xy(tick, pitch)
    D.at(D.f + 1, function() return { D.mouse(x, y) } end)
    D.at(D.f + 2, function() return { D.btn(x, y, true) } end)
    D.at(D.f + 2 + frames, function() return { D.btn(x, y, false) } end)
  end)
end

local function add_drag(f, tick, pitch, dur)
  D.at(f, function()
    local x0, y0 = roll_xy(tick, pitch)
    local x1 = roll_xy(tick + dur - 4, pitch)
    D.drag(D.f + 1, x0, y0, x1, y0, 5)
  end)
end

local function note_at(pt, tick, pitch)
  if not pt then return nil end
  for _, n in ipairs(pt.notes) do
    if n.tick == tick and n.pitch == pitch then return n end
  end
end

local function resize_note(f, tick, pitch, newdur)
  D.at(f, function()
    local pt = doc().patterns[D.win("music").win.pat]
    local n = note_at(pt, tick, pitch)
    if not n then log("NOTE TO RESIZE MISSING"); return end
    -- roll_xy biases ordinary adds a few ticks inside the destination cell.
    -- Back up far enough that this press is still INSIDE the stored note and
    -- within the four-pixel edge hitbox instead of adding at the next grid.
    local x0, y0 = roll_xy(tick + n.dur - 6, pitch)
    local x1 = roll_xy(tick + newdur, pitch)
    D.drag(D.f + 1, x0, y0, x1, y0, 5)
  end)
end

local function marquee(f, tick0, pitch_hi, tick1, pitch_lo)
  D.at(f, function() return { D.keyev(SC.shift, true) } end)
  D.at(f + 2, function()
    local x0, y0 = roll_xy(tick0, pitch_hi)
    local x1, y1 = roll_xy(tick1, pitch_lo)
    D.drag(D.f + 1, x0, y0, x1, y1, 7)
  end)
  D.at(f + 14, function() return { D.keyev(SC.shift, false) } end)
end

local function paste_at(f, tick, pitch)
  D.chord(f, SC.ctrl, SC.v)
  D.at(f + 6, function()
    local x, y = roll_xy(tick, pitch)
    D.click(D.f + 1, x, y)
  end)
end

local function move_note(f, tick, pitch, ntick, npitch)
  D.at(f, function()
    local pt = doc().patterns[D.win("music").win.pat]
    local n = note_at(pt, tick, pitch)
    if not n then log("NOTE TO MOVE MISSING"); return end
    local x0, y0 = roll_xy(tick + math.min(n.dur / 2, 12), pitch)
    local x1, y1 = roll_xy(ntick + math.min(n.dur / 2, 12), npitch)
    D.drag(D.f + 1, x0, y0, x1, y1, 7)
  end)
end

local function velocity_y(value)
  local r, p = D.win("music"), plumb()
  local v = p and p.vlane
  if not (r and v) then return nil end
  return v.y + 2 * r.z + (1 - value / 127) * (v.h - 4 * r.z)
end

local function drag_velocity(f, tick, from, to)
  D.at(f, function()
    local r, p = D.win("music"), plumb()
    local v = p.vlane
    local x = v.x + (tick - v.tick0) * v.tpp + 1 * r.z
    D.drag(D.f + 1, x, velocity_y(from), x, velocity_y(to), 6)
  end)
end

local function find_clip(track, pattern, tick)
  for ci, c in ipairs(doc().clips) do
    if c.track == track and (not pattern or c.pattern == pattern)
       and (tick == nil or c.tick == tick) then return ci, c end
  end
end

local function resize_clip(f, track, pattern, tick, newlen)
  D.at(f, function()
    local _, c = find_clip(track, pattern, tick)
    if not c then log("CLIP TO RESIZE MISSING"); return end
    local x0, y0 = arr_xy(c.tick + c.len, c.track)
    local x1 = arr_xy(c.tick + newlen, c.track)
    D.drag(D.f + 1, x0 - 2 * D.win("music").z, y0, x1, y0, 7)
  end)
end

local function move_clip(f, track, pattern, tick, newtick, linked)
  if linked then
    D.at(f, function() return { D.keyev(SC.ctrl, true) } end)
  end
  D.at(f + (linked and 2 or 0), function()
    local _, c = find_clip(track, pattern, tick)
    if not c then log("CLIP TO MOVE MISSING"); return end
    local grab = math.min(BAR / 2, c.len / 2)
    local x0, y0 = arr_xy(c.tick + grab, c.track)
    local x1 = arr_xy(newtick + grab, c.track)
    D.drag(D.f + 1, x0, y0, x1, y0, 8)
  end)
  if linked then
    D.at(f + 16, function() return { D.keyev(SC.ctrl, false) } end)
  end
end

local function set_mix(f, ti, key, value)
  D.at(f, function()
    local r, p = D.win("music"), plumb()
    local rd = p.rdrop[r.win.id]
    local row = rd.rows[ti]
    if not row then log("MIX ROW MISSING"); return end
    local px = math.max(4, 10 * r.z)
    local py = row.y0 + 2 * r.z + px * 2.4
    local y = key == "gain" and py + px * 0.16 or py + px * 1.72
    local fx = rd.x1 - 38 * r.z
    replace_text(D.f + 1, fx + 15 * r.z, y + px * 0.6, tostring(value))
  end)
end

local function set_pan_slider(f, ti, value)
  D.at(f, function()
    local r, p = D.win("music"), plumb()
    local rd = p.rdrop[r.win.id]
    local row = rd.rows[ti]
    if not row then log("PAN ROW MISSING"); return end
    local z, px = r.z, math.max(4, 10 * r.z)
    local py = row.y0 + 2 * z + px * 2.4
    local y = py + px * 1.72
    local lx = rd.x0 + 6 * z
    local sbx = lx + pal.x_ig_text_size("pan", px * 0.78, 0) + 5 * z
    local fx = rd.x1 - 38 * z
    local sbw = math.max(10 * z, fx - sbx - 3 * z)
    local x0 = sbx + sbw * 0.5
    local x1 = sbx + sbw * ((value + 64) / 128)
    D.drag(D.f + 1, x0, y + px * 0.36, x1, y + px * 0.36, 7)
  end)
end

local function click_ruler(f, tick)
  D.at(f, function()
    local r, p = D.win("music"), plumb()
    local v = p.view
    local tpp = (r.win.tpp or 0.5) * r.z
    local x = v.rx + (tick - (r.win.tick0 or 0)) * tpp
    local y = v.ry - 9 * r.z
    D.click(D.f + 1, x, y)
  end)
end

local function notes_sig(pt)
  local out = {}
  for _, n in ipairs(pt and pt.notes or {}) do
    out[#out + 1] = ("%d:%d:%d:%d"):format(n.tick, n.dur, n.pitch, n.vel)
  end
  table.sort(out)
  return table.concat(out, "/")
end

-- Capture-only fit: the default Music width is 720, 20px over the reader's
-- 700px layout budget. The real border moves to 680 before each @2x capture.
for _, spec in ipairs({
  { "music-roll", 860 }, { "music-arrangement", 1460 }, { "music-mix", 1670 },
}) do
  if rawget(_G, "SHOT") == spec[1] then
    D.at(spec[2] - 4, function()
      local w = latest("music")
      if w then w.w = 680; cm.ed.touch() end
    end)
  end
end

D.shot_zoom("music-roll", 860, "music")
D.shot_zoom("music-arrangement", 1460, "music")
D.shot_zoom("music-mix", 1670, "music")

-- The roll shot catches a REAL held C5 key after the @2x camera move. Refresh
-- the pointer against the shifted key geometry; the button remains held.
if rawget(_G, "SHOT") == "music-roll" then
  D.at(859, function()
    local r, p = D.win("music"), plumb()
    local v = p and p.view
    if not (r and v) then return end
    local _, y = roll_xy(0, 72)
    return { D.mouse(v.rx - 9 * r.z, y) }
  end)
end

-- ============ stage 0: H7 artifacts stay, its windows leave ==============
for k = 0, 21 do
  D.chord(4 + k * 8, SC.ctrl, SC.tab)
  D.chord(8 + k * 8, SC.ctrl, SC.w)
end
probe(182, function()
  cm.ed.g.anim = nil
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
  verdict("quiet-h7-canvas", #cm.ed.doc.wins == 0
          and pal.read_file(cm.ed.root .. "/ins/kick.ins") ~= nil
          and pal.read_file(cm.ed.root .. "/ins/bass.ins") ~= nil
          and pal.read_file(cm.ed.root .. "/ins/lead.ins") ~= nil,
          "wins=" .. #cm.ed.doc.wins)
end)

-- Steps 1-2: create the song, replace its padded starter with a compact
-- one-bar kick pattern, then add three empty track rows.
spawn_kind(184, 430, 60, "music")
type_music_path(210, SONG)
probe(234, function()
  local r, d = D.win("music"), doc()
  verdict("song-created", r and r.win.path == SONG and d
          and #d.tracks == 1 and #d.clips == 1 and d.patterns[1].len == 4 * BAR
          and pal.read_file(cm.ed.root .. "/" .. SONG) == nil)
end)
click_arr(242, 96, 0)
D.tap(252, SC.del)
click_track(262, 1)
probe(278, function()
  local d = doc()
  verdict("compact-kick-pattern", #d.clips == 1 and d.clips[1].pattern == 2
          and d.clips[1].len == BAR and d.patterns[2].len == BAR)
end)
click_add_track(284)
click_add_track(302)
click_add_track(320)
probe(340, function()
  verdict("four-track-rail", #doc().tracks == 4 and #doc().clips == 1)
end)

-- Step 3: bind H7's three local voices through Assets and a stock hat through
-- Stock. The stock drop must import a project-local copy before binding.
spawn_kind(348, 40, 60, "assets")
probe(370, function()
  local a, m = latest("assets"), latest("music")
  if a then a.x, a.y, a.w, a.h = 40, 60, 350, 320 end
  if m then m.x, m.y = 420, 60 end
  cm.ed.g.anim = nil
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
  verdict("assets-open", a ~= nil)
end)
choose_chip(376, "assets", "sound")
set_filter(386, "assets", "kick.ins")
drag_first_to_track(410, "assets", 1)
probe(438, function()
  verdict("kick-bound", doc().tracks[1].ins == INS[1])
end)
set_filter(444, "assets", "bass.ins")
drag_first_to_track(468, "assets", 3)
probe(492, function()
  verdict("bass-bound", doc().tracks[3].ins == INS[3])
end)
set_filter(498, "assets", "lead.ins")
drag_first_to_track(522, "assets", 4)
probe(546, function()
  verdict("lead-bound", doc().tracks[4].ins == INS[4])
end)
spawn_kind(552, 40, 410, "stock")
probe(574, function()
  local a, st, m = latest("assets"), latest("stock"), latest("music")
  if a then a.x, a.y = 1600, 60 end
  if st then st.x, st.y, st.w, st.h = 40, 60, 350, 320 end
  if m then m.x, m.y = 420, 60 end
  cm.ed.touch()
  verdict("stock-open", st ~= nil)
end)
choose_chip(580, "stock", "ins")
set_filter(590, "stock", "gb-noise-hat")
drag_first_to_track(614, "stock", 2)
probe(640, function()
  verdict("hat-imported-and-bound", doc().tracks[2].ins == INS[2]
          and pal.read_file(cm.ed.root .. "/" .. INS[2])
              == pal.read_file("engine/stock/ins/gb-noise-hat.ins"))
  local st, m = latest("stock"), latest("music")
  if st then st.x, st.y = 1600, 60 end
  if m then m.x, m.y = 120, 60 end
  cm.ed.doc.focus = m and m.id or cm.ed.doc.focus
  cm.ed.touch()
end)

-- Step 4: selecting each clipless row creates exactly one one-bar clip and
-- drills the roll into the matching instrument.
click_track(650, 2)
click_track(666, 3)
click_track(682, 4)
probe(700, function()
  local d = doc()
  verdict("four-drilled-patterns", #d.clips == 4
          and d.clips[1].pattern == 2 and d.clips[2].pattern == 3
          and d.clips[3].pattern == 4 and d.clips[4].pattern == 5
          and D.win("music").win.pat == 5)
end)

-- Step 5: kick pattern. Add one deliberate error and remove it with the
-- right button, leaving beats 1/3 and the final eighth-note pickup.
click_track(708, 1)
click_note(720, 0, 48)
click_note(730, 96, 48)
click_note(740, 96, 48, 3)
click_note(750, 192, 48)
click_note(760, 336, 48)
probe(778, function()
  verdict("kick-pattern", notes_sig(doc().patterns[2]) ==
          "0:48:48:100/192:48:48:100/336:48:48:100")
end)

-- Step 6: off-beat hats. The first press is deliberately held — audition
-- duration follows the hand while the stored note remains one grid cell.
click_track(784, 2)
hold_note(794, 48, 72, 12)
click_note(814, 144, 72)
click_note(824, 240, 72)
click_note(834, 336, 72)
-- Hold the visible piano key long enough for the named mid-audition shot.
D.at(848, function()
  local r, p = D.win("music"), plumb()
  local v = p and p.view
  local _, y = roll_xy(0, 72)
  local x = v.rx - 9 * r.z
  D.at(D.f + 1, function() return { D.mouse(x, y) } end)
  D.at(D.f + 2, function() return { D.btn(x, y, true) } end)
  D.at(D.f + 27, function() return { D.btn(x, y, false) } end)
end)
probe(860, function()
  local r = D.win("music")
  crop("music-roll", r.x, r.y, r.w, r.h)
end)
probe(884, function()
  local p = plumb()
  verdict("hat-pattern-and-release", notes_sig(doc().patterns[3]) ==
          "144:48:72:100/240:48:72:100/336:48:72:100/48:48:72:100"
          and not (p.g and p.g.t == "keys"))
end)

-- Step 7: a two-bar bass answer. Dragging the first note makes quarter-note
-- length the new default; content in bar 2 grows the pattern to two bars.
click_track(896, 3)
add_drag(908, 0, 48, 96)
click_note(928, 192, 51)
click_note(940, 384, 46)
click_note(952, 576, 55)
probe(972, function()
  local pt = doc().patterns[4]
  verdict("bass-grows-two-bars", pt.len == 2 * BAR and notes_sig(pt) ==
          "0:96:48:100/192:96:51:100/384:96:46:100/576:96:55:100",
          "len=" .. tostring(pt.len) .. " " .. notes_sig(pt))
end)

-- Steps 8-9: write lead motif A, shorten its two pickups, marquee-copy it,
-- place a visible ghost in bar 2, move that selected answer down two
-- semitones, and soften the whole selected group to velocity 82.
click_track(980, 4)
click_note(990, 0, 67)
click_note(1000, 144, 70)
click_note(1010, 192, 72)
click_note(1020, 336, 75)
resize_note(1032, 144, 70, 48)
resize_note(1048, 336, 75, 48)
marquee(1066, 2, 77, 380, 66)
D.chord(1086, SC.ctrl, SC.c)
paste_at(1094, 384, 67)
move_note(1120, 384, 67, 384, 65)
drag_velocity(1142, 384, 100, 82)
probe(1178, function()
  local pt, p = doc().patterns[5], plumb()
  verdict("lead-a-selection-copy", cm.ed.g.musicclip
          and #cm.ed.g.musicclip == 4 and p.nsels
          and (function() local n=0 for _ in pairs(p.nsels) do n=n+1 end return n end)()
              == 4,
          "clip=" .. tostring(cm.ed.g.musicclip and #cm.ed.g.musicclip)
          .. " sel=" .. tostring((function()
            local n=0 for _ in pairs(p.nsels or {}) do n=n+1 end return n
          end)()))
  verdict("lead-a-two-bars", pt.len == 2 * BAR and notes_sig(pt) ==
          "0:96:67:100/144:48:70:100/192:96:72:100/336:48:75:100/"
          .. "384:96:65:82/528:48:68:82/576:96:70:82/720:48:73:82",
          "len=" .. tostring(pt.len) .. " " .. notes_sig(pt))
end)

-- Steps 10-11: stretch the three backing clips to eight bars; make the A
-- lead a two-bar clip entering at bar 3; linked-duplicate it at bar 5.
resize_clip(1188, 0, 2, 0, 8 * BAR)
resize_clip(1208, 1, 3, 0, 8 * BAR)
resize_clip(1228, 2, 4, 0, 8 * BAR)
resize_clip(1248, 3, 5, 0, 2 * BAR)
move_clip(1268, 3, 5, 0, 2 * BAR, false)
move_clip(1292, 3, 5, 2 * BAR, 4 * BAR, true)
probe(1322, function()
  local _, k = find_clip(0, 2, 0)
  local _, h = find_clip(1, 3, 0)
  local _, b = find_clip(2, 4, 0)
  local _, a1 = find_clip(3, 5, 2 * BAR)
  local _, a2 = find_clip(3, 5, 4 * BAR)
  verdict("eight-bar-linked-arrangement", k and h and b and a1 and a2
          and k.len == 8 * BAR and h.len == 8 * BAR and b.len == 8 * BAR
          and a1.len == 2 * BAR and a2.len == 2 * BAR)
end)

-- Step 12: stamp a fresh answer clip at bar 7, then use the cross-pattern
-- clipboard twice at different pitches. It is independent pattern B.
click_arr(1330, 6 * BAR, 3)
paste_at(1344, 0, 72)
paste_at(1372, 384, 70)
probe(1412, function()
  local d = doc()
  verdict("lead-b-independent", d.patterns[6] and d.patterns[6].len == 2 * BAR
          and D.win("music").win.pat == 6 and notes_sig(d.patterns[6]) ==
          "0:96:72:100/144:48:75:100/192:96:77:100/336:48:80:100/"
          .. "384:96:70:100/528:48:73:100/576:96:75:100/720:48:78:100",
          d.patterns[6] and ("len=" .. tostring(d.patterns[6].len)
            .. " " .. notes_sig(d.patterns[6])) or "missing p6")
end)
resize_clip(1422, 3, 6, 6 * BAR, 2 * BAR)
probe(1460, function()
  local r = D.win("music")
  crop("music-arrangement", r.x, r.y, r.w,
       math.min(r.h, 190 * r.z))
end)

-- Step 13: an exact stereo mix through the visible typed fields.
click_track(1478, 1)
set_mix(1490, 1, "gain", 150)
set_pan_slider(1506, 1, 0)
click_track(1522, 2)
set_mix(1534, 2, "gain", 92)
set_pan_slider(1550, 2, -36)
click_track(1570, 3)
set_mix(1582, 3, "gain", 132)
set_pan_slider(1598, 3, 0)
click_track(1618, 4)
set_mix(1630, 4, "gain", 112)
set_pan_slider(1646, 4, 28)
probe(1664, function()
  local t = doc().tracks
  verdict("stereo-mix", t[1].gain == 150 and t[1].pan == 0
          and t[2].gain == 92 and t[2].pan == -36
          and t[3].gain == 132 and t[3].pan == 0
          and t[4].gain == 112 and t[4].pan == 28,
          ("%s/%s %s/%s %s/%s %s/%s"):format(
            tostring(t[1].gain), tostring(t[1].pan),
            tostring(t[2].gain), tostring(t[2].pan),
            tostring(t[3].gain), tostring(t[3].pan),
            tostring(t[4].gain), tostring(t[4].pan)))
end)
probe(1670, function()
  local r = D.win("music")
  crop("music-mix", r.x, r.y, math.min(r.w, 142 * r.z),
       math.min(r.h, 230 * r.z))
end)

-- Steps 14-15: scrub to bar 3, preview from there, stop, then publish and
-- prove the canonical source and its runtime flatten.
click_ruler(1686, 2 * BAR)
D.tap(1700, SC.space)
probe(1718, function()
  verdict("preview-from-bar-three", D.win("music").win.cursor == 2 * BAR
          and plumb().playing == true)
end)
D.tap(1728, SC.space)
D.chord(1740, SC.ctrl, SC.s)
probe(1778, function()
  local r = D.win("music")
  local bytes = pal.read_file(cm.ed.root .. "/" .. SONG)
  local ok, saved = pcall(song.decode, bytes or "")
  local flat = ok and song.flatten(saved)
  local clips = ok and saved.clips or {}
  local shared = 0
  for _, c in ipairs(clips) do if c.pattern == 5 then shared = shared + 1 end end
  verdict("song-saved-canonical", ok and song.encode(saved) == bytes
          and not cm.ed.kinds.music.dirty(r.win, cm.ed)
          and #saved.tracks == 4 and #clips == 6 and shared == 2)
  verdict("runtime-flatten", flat and #flat == 4
          and #flat[1] == 24 and #flat[2] == 32 and #flat[3] == 16
          and #flat[4] == 24,
          flat and ("%d/%d/%d/%d"):format(#flat[1], #flat[2],
            #flat[3], #flat[4]) or "decode failed")
  verdict("summary", FAIL == 0, ("%d/%d"):format(PASS, PASS + FAIL))
  log("TAPE DONE")
end)
