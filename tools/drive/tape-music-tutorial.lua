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
--          --win 1280x1000 --frames 2362 --eval \
--          "dofile('tools/drive/tape-music-tutorial.lua')" \
--          --shot <scratch>/full.png
--      -> every H8 VERDICT line must read true.
--   4. screenshots are the H8 tape's own @2x frames. Repeat steps 1-2 on a
--      FRESH copy per shot, set SHOT, use --win 1440x1000, stop at the named
--      frame PLUS ONE, and crop to the logged CROP rectangle:
--        bin/cosmic <copy> --edit --headless --win 1440x1000 \
--          --frames 971 --eval \
--          "rawset(_G,'SHOT','music-roll'); dofile('tools/drive/tape-music-tutorial.lua')" \
--          --shot raw.png
--      Stage under engine/stock/docs/media as <name>@2x.png, inspect each at
--      source resolution and in the real reader, then montage them.
--
-- Shot frames:
--   f970 music-roll · f1460 music-arrangement · f1670 music-mix ·
--   f1800 music-steps · f1988 music-snap

local D = dofile("tools/drive/drive.lua")
local SC = D.SC
local song = cm.require("cm.song")
local view = cm.require("cm.view")

-- The final polish proof drives the real machine-wide toggle. Keep its atomic
-- persistence hermetic to this scratch project rather than touching the
-- developer's actual user preference while the tape runs.
view._access_path = cm.ed.root .. "/.ed/tape-editor.dat"
pal.x_remove(view._access_path)
view.cfg.smooth_views = true

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

local function view_low(f, pitch)
  D.at(f, function()
    local r = D.win("music")
    r.win.lownote = pitch
    r.win.lownote_target = nil
    cm.ed.touch()
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
  local suby = (low - lowf) * v.row_h
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
  D.at(f, function() return { D.keyev(SC.ctrl, true) } end)
  D.at(f + 2, function()
    local x0, y0 = roll_xy(tick0, pitch_hi)
    local x1, y1 = roll_xy(tick1, pitch_lo)
    D.drag(D.f + 1, x0, y0, x1, y1, 7)
  end)
  D.at(f + 14, function() return { D.keyev(SC.ctrl, false) } end)
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
    D.at(f, function() return { D.keyev(SC.shift, true) } end)
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
    D.at(f + 16, function() return { D.keyev(SC.shift, false) } end)
  end
end

local function click_new_pattern(f)
  D.at(f, function()
    local r = D.win("music")
    local z, px = r.z, math.max(4, 10 * r.z)
    local x = r.cx + math.min(120 * z, r.cw * 0.22)
    local function chip(label)
      local w = pal.x_ig_text_size(label, px * 0.95, 0) + 12 * z
      local cx = x + w * 0.5
      x = x + w + 4 * z
      return cx
    end
    chip("song play")
    x = x + pal.x_ig_text_size("bpm", px * 0.72, 0) + 2 * z
            + 34 * z + 4 * z
    x = x + pal.x_ig_text_size("time", px * 0.72, 0) + 2 * z
            + 34 * z + 4 * z
    chip("1/8")
    D.click(D.f + 1, chip("+ pat"), r.cy + px * 0.8)
  end)
end

local function click_steps(f)
  D.at(f, function()
    local r = D.win("music")
    local z, px = r.z, math.max(4, 10 * r.z)
    local x = r.cx + math.min(120 * z, r.cw * 0.22)
    local function chip(label)
      local w = pal.x_ig_text_size(label, px * 0.95, 0) + 12 * z
      local cx = x + w * 0.5
      x = x + w + 4 * z
      return cx
    end
    chip("song play")
    x = x + pal.x_ig_text_size("bpm", px * 0.72, 0) + 2 * z
            + 34 * z + 4 * z
    x = x + pal.x_ig_text_size("time", px * 0.72, 0) + 2 * z
            + 34 * z + 4 * z
    chip("1/8")
    chip("+ pat")
    D.click(D.f + 1, chip("steps"), r.cy + px * 0.8)
  end)
end

local function set_transport_field(f, which, value)
  D.at(f, function()
    local r = D.win("music")
    local z, px = r.z, math.max(4, 10 * r.z)
    local x = r.cx + math.min(120 * z, r.cw * 0.22)
    local sw = pal.x_ig_text_size("song play", px * 0.95, 0) + 12 * z
    x = x + sw + 4 * z
    x = x + pal.x_ig_text_size("bpm", px * 0.72, 0) + 2 * z
    local bpm_x = x + 17 * z
    x = x + 34 * z + 4 * z
    x = x + pal.x_ig_text_size("time", px * 0.72, 0) + 2 * z
    local time_x = x + 17 * z
    replace_text(D.f + 1, which == "bpm" and bpm_x or time_x,
                 r.cy + px * 0.8, value)
  end)
end

local function set_pattern_name(f, value)
  D.at(f, function()
    local r = D.win("music")
    local z, px = r.z, math.max(4, 10 * r.z)
    local x = r.cx + math.min(120 * z, r.cw * 0.22)
    local function chip(label)
      local w = pal.x_ig_text_size(label, px * 0.95, 0) + 12 * z
      x = x + w + 4 * z
    end
    chip("song play")
    x = x + pal.x_ig_text_size("bpm", px * 0.72, 0) + 2 * z
            + 34 * z + 4 * z
    x = x + pal.x_ig_text_size("time", px * 0.72, 0) + 2 * z
            + 34 * z + 4 * z
    chip("1/8")
    chip("+ pat")
    chip("steps")
    local pid = r.win.pat or 1
    x = x + pal.x_ig_text_size("p" .. tostring(pid), px * 0.72, 0)
            + 2 * z
    replace_text(D.f + 1, x + 38 * z, r.cy + px * 0.8, value)
  end)
end

local function step_xy(ti, si, roll)
  local p = plumb()
  local steps = p and p.steps
  if not steps then return nil end
  if roll then
    local g = steps.rolls and steps.rolls[ti]
    return g and g.x + g.w * 0.5, g and g.y + g.h * 0.5
  end
  local visible = si - steps.step0
  if visible < 1 or visible > steps.draw_steps then return nil end
  return steps.x + (visible - 0.5) * steps.step_w,
         steps.y + (ti - steps.first_track + 0.5) * steps.row_h
end

local function click_step(f, ti, si, button)
  D.at(f, function()
    local x, y = step_xy(ti, si)
    if not x then log("STEP GEOMETRY MISSING"); return end
    D.click(D.f + 1, x, y, button)
  end)
end

local function step_plus_xy()
  local steps = plumb() and plumb().steps
  local g = steps and steps.plus
  return g and g.x + g.w * 0.5, g and g.y + g.h * 0.5
end

local function step_handle_xy(ti)
  local steps = plumb() and plumb().steps
  local g = steps and steps.handles and steps.handles[ti]
  return g and g.x + g.w * 0.5, g and g.y + g.h * 0.5
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

local function click_song_ruler(f, tick)
  D.at(f, function()
    local p = plumb()
    local a = p and p.arr
    local x = a.x + (tick - a.t0) * a.atpp
    local y = a.y - 6 * D.win("music").z
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
  { "music-roll", 970 }, { "music-arrangement", 1460 },
  { "music-mix", 1670 }, { "music-steps", 1800 },
  { "music-snap", 1988 },
}) do
  if rawget(_G, "SHOT") == spec[1] then
    D.at(spec[2] - 4, function()
      local w = latest("music")
      if w then w.w = 680; cm.ed.touch() end
    end)
  end
end

D.shot_zoom("music-roll", 970, "music")
D.shot_zoom("music-arrangement", 1460, "music")
D.shot_zoom("music-mix", 1670, "music")
D.shot_zoom("music-steps", 1800, "music")
D.shot_zoom("music-snap", 1988, "music")

-- The roll shot catches a REAL held C3 key after the @2x camera move. Refresh
-- the pointer against the shifted key geometry; the button remains held.
if rawget(_G, "SHOT") == "music-roll" then
  D.at(969, function()
    local r, p = D.win("music"), plumb()
    local v = p and p.view
    if not (r and v) then return end
    local _, y = roll_xy(0, 48)
    return { D.mouse(v.rx - 9 * r.z, y) }
  end)
end

-- The snapped-marquee shot zooms after the drag began at proof scale. Refresh
-- its held endpoint against the moved @2x window, exactly like the held piano
-- key above, so the screenshot remains a real in-flight gesture.
if rawget(_G, "SHOT") == "music-snap" then
  D.at(1987, function()
    local x, y = arr_xy(2 * BAR + 30, 2)
    return x and { D.mouse(x, y) } or nil
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
D.tap(236, 33) -- key 4: the tutorial's 1/8 placement grid
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
view_low(716, 42)
click_note(720, 0, 48)
click_note(730, 96, 48)
click_note(740, 96, 48, 3)
click_note(750, 192, 48)
click_note(760, 336, 48)
probe(778, function()
  verdict("kick-pattern", notes_sig(doc().patterns[2]) ==
          "0:48:48:100/192:48:48:100/336:48:48:100")
end)

-- Step 6: four short off-beat hats. Their patch envelope decays immediately,
-- so the sustained-gate lesson deliberately moves to the audible bass.
click_track(784, 2)
view_low(790, 58)
click_note(794, 48, 72)
click_note(814, 144, 72)
click_note(824, 240, 72)
click_note(834, 336, 72)
probe(884, function()
  verdict("hat-pattern", notes_sig(doc().patterns[3]) ==
          "144:48:72:100/240:48:72:100/336:48:72:100/48:48:72:100"
          and not plumb().g)
end)

-- Step 7: a two-bar bass answer. Dragging the first note makes quarter-note
-- length the new default; the first bar-2 note grows BOTH the pattern and its
-- still-exact-fit selected clip. Hold C3 on the playable keys for the audible
-- sustained-gate lesson and the named mid-audition shot.
click_track(896, 3)
view_low(904, 42)
add_drag(908, 0, 48, 96)
click_note(928, 192, 51)
click_note(940, 384, 46)
click_note(952, 576, 55)
D.at(958, function()
  local r, p = D.win("music"), plumb()
  local v = p and p.view
  local _, y = roll_xy(0, 48)
  local x = v.rx - 9 * r.z
  D.at(D.f + 1, function() return { D.mouse(x, y) } end)
  D.at(D.f + 2, function() return { D.btn(x, y, true) } end)
  D.at(D.f + 20, function() return { D.btn(x, y, false) } end)
end)
probe(970, function()
  local r = D.win("music")
  crop("music-roll", r.x, r.y, r.w, r.h)
end)
probe(972, function()
  local pt = doc().patterns[4]
  local _, c = find_clip(2, 4, 0)
  local p = plumb()
  verdict("bass-pattern-and-clip-grow", pt.len == 2 * BAR
          and c and c.len == 2 * BAR and p.g and p.g.t == "keys"
          and p.g.kp == 48 and notes_sig(pt) ==
          "0:96:48:100/192:96:51:100/384:96:46:100/576:96:55:100",
          "pat=" .. tostring(pt.len) .. " clip=" .. tostring(c and c.len)
          .. " " .. notes_sig(pt))
end)

-- Steps 8-9: write lead motif A, shorten its two pickups, marquee-copy it,
-- place a visible ghost in bar 2, move that selected answer down two
-- semitones, and soften the whole selected group to velocity 82.
click_track(980, 4)
view_low(986, 59)
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
  local _, c = find_clip(3, 5, 0)
  verdict("lead-a-selection-copy", cm.ed.g.musicclip
          and #cm.ed.g.musicclip == 4 and p.nsels
          and (function() local n=0 for _ in pairs(p.nsels) do n=n+1 end return n end)()
              == 4,
          "clip=" .. tostring(cm.ed.g.musicclip and #cm.ed.g.musicclip)
          .. " sel=" .. tostring((function()
            local n=0 for _ in pairs(p.nsels or {}) do n=n+1 end return n
          end)()))
  verdict("lead-a-two-bars", pt.len == 2 * BAR and c and c.len == 2 * BAR
          and notes_sig(pt) ==
          "0:96:67:100/144:48:70:100/192:96:72:100/336:48:75:100/"
          .. "384:96:65:82/528:48:68:82/576:96:70:82/720:48:73:82",
          "len=" .. tostring(pt.len) .. " " .. notes_sig(pt))
end)

-- Steps 10-11: stretch the three backing clips to eight bars. Pattern A's
-- exact-fit clip already followed its two-bar growth; move it to bar 3 and
-- linked-duplicate it at bar 5.
resize_clip(1188, 0, 2, 0, 8 * BAR)
resize_clip(1208, 1, 3, 0, 8 * BAR)
resize_clip(1228, 2, 4, 0, 8 * BAR)
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

-- Step 12: create a fresh named pattern, place it at bar 7, then use the
-- fixed-pitch cross-pattern clipboard and explicitly move each answer.
click_new_pattern(1328)
set_pattern_name(1334, "lead answer")
click_arr(1350, 6 * BAR, 3)
paste_at(1362, 0, 72)
move_note(1376, 0, 67, 0, 72)
paste_at(1394, 384, 70)
move_note(1408, 384, 67, 384, 70)
probe(1442, function()
  local d = doc()
  local _, c = find_clip(3, 6, 6 * BAR)
  verdict("lead-b-independent", d.patterns[6]
          and d.patterns[6].name == "lead answer"
          and d.patterns[6].len == 2 * BAR
          and c and c.len == 2 * BAR and D.win("music").win.pat == 6
          and notes_sig(d.patterns[6]) ==
          "0:96:72:100/144:48:75:100/192:96:77:100/336:48:80:100/"
          .. "384:96:70:100/528:48:73:100/576:96:75:100/720:48:78:100",
          d.patterns[6] and ("len=" .. tostring(d.patterns[6].len)
            .. " " .. notes_sig(d.patterns[6])) or "missing p6")
end)
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

-- Steps 14-15: use the arrangement's song ruler at bar 3, preview from there,
-- stop, then publish and
-- prove the canonical source and its runtime flatten.
click_song_ruler(1686, 2 * BAR)
D.tap(1700, SC.space)
probe(1718, function()
  local w, p = D.win("music").win, plumb()
  verdict("preview-from-bar-three", w.song_cursor == 2 * BAR
          and p.playing == true and p.play_scope == "song",
          ("cursor=%s playing=%s win_scope=%s p_scope=%s"):format(
            tostring(w.song_cursor), tostring(p.playing),
            tostring(w.play_scope), tostring(p.play_scope)))
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
end)

-- Post-lesson UX proof: the channel-rack view edits the same pattern bytes,
-- left-add/right-erase are exact, and "roll" drills back into the piano view.
click_steps(1784)
probe(1796, function()
  local s = plumb().steps
  verdict("step-view-open", D.win("music").win.edit_mode == "steps"
          and s and s.span_beats == 8 and s.nsteps == 32
          and doc().patterns[4].len == 2 * BAR,
          s and ("%db/%d steps"):format(s.span_beats, s.nsteps)
          or "missing geometry")
end)
probe(1800, function()
  local r = D.win("music")
  crop("music-steps", r.x, r.y, r.w, r.h)
end)
click_step(1804, 1, 2)
probe(1816, function()
  verdict("step-left-add", note_at(doc().patterns[2], 24, 48) ~= nil)
end)
click_step(1822, 1, 2, 3)
probe(1834, function()
  verdict("step-right-erase", note_at(doc().patterns[2], 24, 48) == nil)
end)
D.at(1840, function()
  local x, y = step_xy(1, 1, true)
  D.click(D.f + 1, x, y)
end)
probe(1852, function()
  local w = D.win("music").win
  verdict("step-roll-drill", w.edit_mode == "piano" and w.pat == 2
          and w.trk == 1)
end)
set_transport_field(1860, "bpm", "137")
set_transport_field(1880, "time", "7/8")
probe(1900, function()
  local d = doc()
  verdict("typed-song-timing", d.bpm == 137 and d.beats_per_bar == 7
          and d.beat_unit == 8 and song.beat_ticks(d) == 48
          and song.bar_ticks(d) == 336)
end)
D.chord(1910, SC.ctrl, SC.z)
D.chord(1920, SC.ctrl, SC.z)
probe(1932, function()
  local d = doc()
  verdict("timing-undo", d.bpm == 120 and d.beats_per_bar == 4
          and d.beat_unit == 4)
end)

-- Post-lesson polish proof: wheel zoom first writes a destination and visibly
-- chases it, then settles exactly. A Ctrl marquee starts/ends off the grid but
-- keeps those time edges raw, snaps to whole track rows, previews live, and
-- selects precisely the three backing lanes.
local smooth_tpp0
D.at(1940, function()
  local r, p = D.win("music"), plumb()
  local v = p and p.view
  if not (r and v) then return end
  smooth_tpp0 = r.win.tpp
  local x, y = v.rx + v.rw * 0.55, v.ry + v.rh * 0.5
  return { D.mouse(x, y), D.wheelev(1) }
end)
probe(1943, function()
  local r, p = D.win("music"), plumb()
  local m = cm.require("cm.ed.kit").winui(p, r.win).motion
  verdict("smooth-wheel-chases", smooth_tpp0 and m.tpp
          and r.win.tpp > smooth_tpp0 and r.win.tpp < m.tpp,
          ("from=%s now=%s target=%s"):format(
            tostring(smooth_tpp0), tostring(r.win.tpp), tostring(m.tpp)))
end)
probe(1970, function()
  local r, p = D.win("music"), plumb()
  local m = cm.require("cm.ed.kit").winui(p, r.win).motion
  verdict("smooth-wheel-settles", smooth_tpp0
          and math.abs(r.win.tpp - smooth_tpp0 * 1.2) < 0.0002
          and m.tpp == nil,
          ("now=%s target=%s"):format(tostring(r.win.tpp), tostring(m.tpp)))
end)
D.at(1974, function() return { D.keyev(SC.ctrl, true) } end)
D.at(1976, function()
  local x, y = arr_xy(37, 0)
  return { D.mouse(x, y) }
end)
D.at(1977, function()
  local x, y = arr_xy(37, 0)
  return { D.btn(x, y, true) }
end)
D.at(1979, function()
  local x, y = arr_xy(2 * BAR + 30, 2)
  return { D.mouse(x, y) }
end)
probe(1988, function()
  local r, p = D.win("music"), plumb()
  crop("music-snap", r.x, r.y, r.w, math.min(r.h, 190 * r.z))
  local g = p.g
  local selected = 0
  for _ in pairs(g and g.preview or {}) do selected = selected + 1 end
  verdict("arrangement-marquee-live", p.g and p.g.t == "clipmarquee"
          and p.g.moved == true and selected == 3 and g.bounds
          and math.abs(g.bounds[1] - 37) < 1e-6
          and math.abs(g.bounds[2] - (2 * BAR + 30)) < 1e-6
          and g.bounds[3] == 0 and g.bounds[4] == 3,
          ("preview=%d bounds=%s/%s/%s/%s"):format(
            selected, tostring(g and g.bounds and g.bounds[1]),
            tostring(g and g.bounds and g.bounds[2]),
            tostring(g and g.bounds and g.bounds[3]),
            tostring(g and g.bounds and g.bounds[4])))
end)
D.at(1992, function()
  local x, y = arr_xy(2 * BAR + 30, 2)
  return { D.btn(x, y, false) }
end)
D.at(1994, function() return { D.keyev(SC.ctrl, false) } end)
probe(2000, function()
  local n = 0
  for _ in pairs(plumb().csels or {}) do n = n + 1 end
  verdict("arrangement-vertical-snap-marquee", n == 3, "selected=" .. n)
end)

-- Open the actual Aa panel, toggle smoothing off, and prove the same wheel
-- lands immediately with no pending target. Restore ON before leaving.
D.at(2004, function()
  local a = cm.ed.g.display_pill
  if a then D.click(D.f + 1, a.x + a.w * 0.5, a.y + a.h * 0.5) end
end)
D.at(2010, function()
  local a = cm.ed.g.display_rect
  if a then D.click(D.f + 1, a.x + 244, a.y + 117) end
end)
probe(2016, function()
  local stored = pal.read_file(view._access_path)
  local ok, t = pcall(cm.require("cm.state").parse, stored or "")
  verdict("smoothing-toggle-off", view.cfg.smooth_views == false
          and ok and t.smooth_views == false)
end)
local instant_tpp0
D.at(2020, function()
  local r, p = D.win("music"), plumb()
  local v = p and p.view
  if not (r and v) then return end
  instant_tpp0 = r.win.tpp
  local x, y = v.rx + v.rw * 0.55, v.ry + v.rh * 0.5
  return { D.mouse(x, y), D.wheelev(-1) }
end)
probe(2024, function()
  local r, p = D.win("music"), plumb()
  local m = cm.require("cm.ed.kit").winui(p, r.win).motion
  verdict("smoothing-off-immediate", instant_tpp0
          and math.abs(r.win.tpp - instant_tpp0 / 1.2) < 1e-9
          and m.tpp == nil)
end)
D.at(2028, function()
  local a = cm.ed.g.display_rect
  if a then D.click(D.f + 1, a.x + 244, a.y + 117) end
end)
probe(2034, function()
  local stored = pal.read_file(view._access_path)
  local ok, t = pcall(cm.require("cm.state").parse, stored or "")
  verdict("smoothing-toggle-restored", view.cfg.smooth_views == true
          and ok and t.smooth_views == nil)
end)

-- Regression for the human's held-pan report: continuously retarget the real
-- outer-canvas MMB gesture for twelve consecutive motion frames. It must make
-- substantial visible progress BEFORE release, then settle exactly afterward.
local canvas_pan0, canvas_pan_target
D.at(2044, function()
  canvas_pan0 = cm.ed.doc.cam.x
  return { D.mouse(1240, 760) }
end)
D.at(2045, function() return { D.btn(1240, 760, true, 2) } end)
for f = 2046, 2057 do
  D.at(f, function()
    local n = D.f - 2045
    return { D.mouse(1240 - n * 16, 760) }
  end)
end
probe(2058, function()
  local a = cm.ed.g.anim
  canvas_pan_target = a and a.to and a.to.x
  local span = canvas_pan_target and canvas_pan_target - canvas_pan0 or 0
  local progress = span ~= 0 and
    (cm.ed.doc.cam.x - canvas_pan0) / span or 0
  verdict("canvas-pan-live-while-held", cm.ed.g.pan ~= nil
          and a and a.mode == "chase"
          and progress > 0.25 and progress < 1,
          ("progress=%.3f now=%s target=%s"):format(
            progress, tostring(cm.ed.doc.cam.x), tostring(canvas_pan_target)))
end)
D.at(2060, function() return { D.btn(1240 - 12 * 16, 760, false, 2) } end)
probe(2102, function()
  verdict("canvas-pan-settles-after-release", canvas_pan_target
          and math.abs(cm.ed.doc.cam.x - canvas_pan_target) < 1e-9
          and cm.ed.g.pan == nil and cm.ed.g.anim == nil,
          ("now=%s target=%s"):format(
            tostring(cm.ed.doc.cam.x), tostring(canvas_pan_target)))
end)

-- The roll's vertical origin is fractional. A sub-row real MMB drag must move
-- continuously while held and settle to that fractional destination rather
-- than reversing within the row and jumping at its next integer boundary.
local roll_pan0, roll_pan_target, roll_pan_x, roll_pan_y, roll_pan_row_h
D.at(2112, function()
  local r, p = D.win("music"), plumb()
  local v = p and p.view
  if not (r and v) then return end
  cm.ed.doc.focus = r.win.id
  roll_pan0, roll_pan_row_h = r.win.lownote, v.row_h
  roll_pan_x, roll_pan_y = v.rx + v.rw * 0.72, v.ry + v.rh * 0.56
  return { D.mouse(roll_pan_x, roll_pan_y) }
end)
D.at(2113, function()
  return { D.btn(roll_pan_x, roll_pan_y, true, 2) }
end)
for f = 2114, 2119 do
  D.at(f, function()
    local dy = D.f - 2113
    return { D.mouse(roll_pan_x, roll_pan_y + dy) }
  end)
end
probe(2120, function()
  local r, p = D.win("music"), plumb()
  roll_pan_target = r.win.lownote_target
  verdict("piano-mmb-pan-continuous", p.pan ~= nil and roll_pan_target
          and r.win.lownote > roll_pan0
          and r.win.lownote < roll_pan_target
          and math.abs(roll_pan_target - math.floor(roll_pan_target)) > 0.01,
          ("from=%.6f now=%.6f target=%s"):format(
            roll_pan0, r.win.lownote, tostring(roll_pan_target)))
end)
D.at(2121, function()
  return { D.btn(roll_pan_x, roll_pan_y + 6, false, 2) }
end)
probe(2150, function()
  local r, p = D.win("music"), plumb()
  verdict("piano-mmb-pan-settles-fractional", roll_pan_target
          and math.abs(r.win.lownote - roll_pan_target) < 1e-9
          and math.abs(roll_pan_target
                       - (roll_pan0 + 6 / roll_pan_row_h)) < 1e-9
          and r.win.lownote_target == nil and p.pan == nil,
          ("now=%s target=%s"):format(
            tostring(r.win.lownote), tostring(roll_pan_target)))
end)

-- A real piano marquee keeps time edges exactly under the pointer, snaps only
-- its pitch-row edges, and exposes the hit set to rendering before mouse-up.
local live_note, live_t0, live_t1, note_count0
D.at(2154, function()
  local r, p = D.win("music"), plumb()
  local pt = p and p.doc and p.doc.patterns[r.win.pat]
  live_note = pt and pt.notes[1]
  if not live_note then return end
  note_count0 = #pt.notes
  p.nsels, p.nsel = {}, nil
  p.g = nil
  r.win.lownote = math.max(0, live_note.pitch - 5.25)
  r.win.lownote_target = nil
  r.win.tick0 = 0
  local motion = cm.require("cm.ed.kit").winui(p, r.win).motion
  if motion then motion.tick0 = nil end
  cm.ed.g.display = false
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.g.anim = 0, 0, nil
  cm.ed.doc.focus = r.win.id
end)
D.at(2156, function() return { D.keyev(SC.ctrl, true) } end)
D.at(2157, function()
  local r = D.win("music")
  live_t0 = live_note.tick + math.min(12.25, live_note.dur * 0.25)
  local x, y = roll_xy(live_t0, live_note.pitch)
  x = x - 1.5 * r.z
  return { D.mouse(x, y) }
end)
D.at(2158, function()
  local r = D.win("music")
  local x, y = roll_xy(live_t0, live_note.pitch)
  x = x - 1.5 * r.z
  return { D.btn(x, y, true) }
end)
D.at(2160, function()
  local r = D.win("music")
  live_t1 = live_note.tick + live_note.dur - 2.75
  local x, y = roll_xy(live_t1, live_note.pitch)
  x = x - 1.5 * r.z
  return { D.mouse(x, y) }
end)
probe(2162, function()
  local p, g = plumb(), plumb().g
  local b = g and g.bounds
  verdict("piano-marquee-highlights-live", g and g.t == "marquee"
          and g.moved and g.preview and g.preview[live_note]
          and not p.nsels[live_note] and b
          and math.abs(b[1] - live_t0) < 1e-6
          and math.abs(b[2] - live_t1) < 1e-6
          and math.type(b[3]) == "integer" and math.type(b[4]) == "integer",
          ("bounds=%s/%s rows=%s/%s"):format(
            tostring(b and b[1]), tostring(b and b[2]),
            tostring(b and b[3]), tostring(b and b[4])))
end)
D.at(2164, function()
  local r = D.win("music")
  local x, y = roll_xy(live_t1, live_note.pitch)
  x = x - 1.5 * r.z
  return { D.btn(x, y, false) }
end)
D.at(2165, function() return { D.keyev(SC.ctrl, false) } end)
probe(2168, function()
  verdict("piano-marquee-commits-preview",
          plumb().nsels[live_note] == true)
end)

-- Both deletion doors leave only presentation geometry: a bright inner rim
-- and faint body collapse/fade in place while the source item is already gone.
D.tap(2172, SC.del)
probe(2176, function()
  local r, p = D.win("music"), plumb()
  local pt = p.doc.patterns[r.win.pat]
  local fx = p.delete_fx and p.delete_fx[#p.delete_fx]
  verdict("piano-delete-inner-glow", #pt.notes == note_count0 - 1
          and fx and fx.kind == "note" and fx.pattern == pt.id
          and fx.k and fx.k > 0 and fx.k <= 1)
end)
local deleted_clip
D.at(2180, function()
  local d = doc()
  deleted_clip = d and d.clips[1]
  if not deleted_clip then return end
  local x, y = arr_xy(deleted_clip.tick
                      + math.min(2, deleted_clip.len - 0.25),
                      deleted_clip.track)
  D.rclick(D.f + 1, x, y)
end)
probe(2186, function()
  local p, found, still = plumb(), false, false
  for _, c in ipairs(p.doc.clips) do
    if c == deleted_clip then still = true end
  end
  for _, fx in ipairs(p.delete_fx or {}) do
    if fx.kind == "clip" and fx.tick == deleted_clip.tick
       and fx.track == deleted_clip.track and fx.k and fx.k > 0 then
      found = true
    end
  end
  verdict("arrangement-delete-inner-glow", found and not still)
end)

-- Empty-space left drag is the arrangement paint tool: the first copy lands
-- on press, then a single fast motion across three ends must fill every
-- adjacent pattern-length slot while the button remains down. Release is one
-- journal entry, proven by one undo and one redo.
local paint_before, paint_anchor, paint_len, paint_pattern, paint_track
local paint_undo_ok
local function painted_clips()
  local out = {}
  for _, c in ipairs(doc().clips) do
    if c.pattern == paint_pattern and c.track == paint_track
       and c.tick >= paint_anchor
       and c.tick <= paint_anchor + 3 * paint_len then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b) return a.tick < b.tick end)
  return out
end
D.at(2194, function()
  local r, p, d = D.win("music"), plumb(), doc()
  local last = 0
  for _, c in ipairs(d.clips) do last = math.max(last, c.tick + c.len) end
  paint_before = #d.clips
  paint_pattern, paint_track = r.win.pat, 0
  paint_len = d.patterns[paint_pattern].len
  paint_anchor = ((last + BAR - 1) // BAR) * BAR + BAR
  r.win.ar_t0, r.win.ar_tpp, r.win.ar_sy =
    math.max(0, paint_anchor - BAR), 0.12, 0
  local motion = cm.require("cm.ed.kit").winui(p, r.win).motion
  if motion then
    motion.ar_t0, motion.ar_tpp, motion.ar_sy = nil, nil, nil
  end
  p.g = nil
  cm.ed.g.display = false
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.g.anim = 0, 0, nil
  cm.ed.doc.focus = r.win.id
end)
D.at(2197, function()
  local x, y = arr_xy(paint_anchor + 2, paint_track)
  return { D.mouse(x, y) }
end)
D.at(2198, function()
  local x, y = arr_xy(paint_anchor + 2, paint_track)
  return { D.btn(x, y, true) }
end)
D.at(2199, function()
  local x, y = arr_xy(paint_anchor + 3 * paint_len + 2, paint_track)
  return { D.mouse(x, y) }
end)
probe(2200, function()
  local r, p, g, clips = D.win("music"), plumb(), plumb().g, painted_clips()
  crop("music-paint", r.x, r.y, r.w, math.min(r.h, 190 * r.z))
  local selected = 0
  for _, c in ipairs(clips) do
    if p.csels[c] then selected = selected + 1 end
  end
  verdict("arrangement-pattern-paint-live", g and g.t == "clipdraw"
          and #clips == 4 and selected == 4
          and clips[1].tick == paint_anchor
          and clips[2].tick == paint_anchor + paint_len
          and clips[3].tick == paint_anchor + 2 * paint_len
          and clips[4].tick == paint_anchor + 3 * paint_len,
          ("clips=%d selected=%d"):format(#clips, selected))
end)
D.at(2201, function()
  local x, y = arr_xy(paint_anchor + 3 * paint_len + 2, paint_track)
  return { D.btn(x, y, false) }
end)
probe(2204, function()
  verdict("arrangement-pattern-paint-commit",
          #doc().clips == paint_before + 4 and plumb().g == nil)
end)
D.chord(2208, SC.ctrl, SC.z)
probe(2215, function()
  paint_undo_ok = #doc().clips == paint_before
end)
D.chord(2217, SC.ctrl, SC.y)
probe(2224, function()
  verdict("arrangement-pattern-paint-one-undo",
          paint_undo_ok and #doc().clips == paint_before + 4
          and #painted_clips() == 4)
end)

-- One right-drag frame crosses the entire painted run. Segment hit-testing
-- must erase all four despite the input jump, and one undo restores the stroke.
D.at(2228, function()
  local x, y = arr_xy(paint_anchor + 2, paint_track)
  return { D.mouse(x, y) }
end)
D.at(2229, function()
  local x, y = arr_xy(paint_anchor + 2, paint_track)
  return { D.btn(x, y, true, 3) }
end)
D.at(2230, function()
  local x, y = arr_xy(paint_anchor + 4 * paint_len - 2, paint_track)
  return { D.mouse(x, y) }
end)
probe(2231, function()
  local g = plumb().g
  verdict("arrangement-right-drag-erase-live",
          g and g.t == "cliperase" and g.changed
          and #doc().clips == paint_before and #painted_clips() == 0)
end)
D.at(2232, function()
  local x, y = arr_xy(paint_anchor + 4 * paint_len - 2, paint_track)
  return { D.btn(x, y, false, 3) }
end)
D.chord(2236, SC.ctrl, SC.z)
probe(2243, function()
  verdict("arrangement-right-drag-erase-one-undo",
          #doc().clips == paint_before + 4 and #painted_clips() == 4
          and plumb().g == nil)
end)

-- The piano eraser follows the same held-stroke contract. Walk three stored
-- notes with the real pointer, then prove the entire multi-frame stroke is one
-- undo entry.
local erase_notes, erase_note_before
D.at(2247, function()
  local r, p, d = D.win("music"), plumb(), doc()
  local pt = d.patterns[paint_pattern]
  erase_notes = {}
  for j = 1, math.min(3, #pt.notes) do
    local n = pt.notes[j]
    erase_notes[j] = {
      tick = n.tick, dur = n.dur, pitch = n.pitch, vel = n.vel,
    }
  end
  erase_note_before = #pt.notes
  r.win.edit_mode, r.win.pat = "piano", paint_pattern
  for ci, c in ipairs(d.clips) do
    if c.pattern == paint_pattern then
      p.csel, r.win.trk = ci, c.track + 1
      break
    end
  end
  local min_pitch = 127
  for _, n in ipairs(erase_notes) do min_pitch = math.min(min_pitch, n.pitch) end
  r.win.tick0, r.win.tpp = 0, 0.5
  r.win.row_h = 8
  r.win.lownote, r.win.lownote_target = math.max(0, min_pitch - 4), nil
  local motion = cm.require("cm.ed.kit").winui(p, r.win).motion
  if motion then motion.tick0, motion.tpp, motion.row_h = nil, nil, nil end
  p.nsels, p.nsel, p.g = {}, nil, nil
end)
D.at(2250, function()
  local n = erase_notes[1]
  local x, y = roll_xy(n.tick + n.dur * 0.5, n.pitch)
  return { D.mouse(x, y) }
end)
D.at(2251, function()
  local n = erase_notes[1]
  local x, y = roll_xy(n.tick + n.dur * 0.5, n.pitch)
  return { D.btn(x, y, true, 3) }
end)
for f = 2252, 2253 do
  D.at(f, function()
    local n = erase_notes[f - 2250]
    local x, y = roll_xy(n.tick + n.dur * 0.5, n.pitch)
    return { D.mouse(x, y) }
  end)
end
probe(2254, function()
  local r, pt, g = D.win("music"), doc().patterns[paint_pattern], plumb().g
  crop("music-erase", r.x, r.y, r.w, math.min(r.h, 440 * r.z))
  local targets_left = 0
  for _, n in ipairs(pt.notes) do
    for _, target in ipairs(erase_notes) do
      if n.tick == target.tick and n.pitch == target.pitch
         and n.dur == target.dur then
        targets_left = targets_left + 1
      end
    end
  end
  verdict("piano-right-drag-erase-live",
          g and g.t == "noteerase" and g.changed
          and targets_left == 0 and #pt.notes <= erase_note_before - 3,
          ("left=%d notes=%d"):format(targets_left, #pt.notes))
end)
D.at(2255, function()
  local n = erase_notes[#erase_notes]
  local x, y = roll_xy(n.tick + n.dur * 0.5, n.pitch)
  return { D.btn(x, y, false, 3) }
end)
D.chord(2260, SC.ctrl, SC.z)
probe(2267, function()
  verdict("piano-right-drag-erase-one-undo",
          #doc().patterns[paint_pattern].notes == erase_note_before
          and plumb().g == nil)
end)

-- Final rack proof: the shared span exposes every beat of an existing
-- two-bar row, +beat grows every represented pattern in one undoable edit
-- while content-fit arrangement blocks stay concise, and the grip reorders
-- the actual tracks without detaching any clip from its instrument.
local rack_span_before, rack_target_len, rack_lengths
local rack_pids, rack_auto_clip, rack_auto_used
local rack_names, rack_clip_owners
click_steps(2270)
probe(2282, function()
  local p, d, s = plumb(), doc(), plumb().steps
  rack_span_before = s and s.span_beats
  rack_target_len = s and (s.span_beats + 1) * song.beat_ticks(d)
  rack_lengths, rack_pids = {}, {}
  local seen = {}
  for _, pid in pairs(s and s.patterns or {}) do
    if pid and not seen[pid] then
      seen[pid] = true
      rack_pids[#rack_pids + 1] = pid
      rack_lengths[pid] = d.patterns[pid].len
    end
  end
  for _, c in ipairs(d.clips) do
    local pt = seen[c.pattern] and d.patterns[c.pattern]
    if not rack_auto_clip and pt and c.len == pt.len
       and pt.len < rack_target_len then
      rack_auto_clip = c
      rack_auto_used = cm.ed.kinds.music.pattern_used_len(d, pt)
    end
  end
  local rack_rows = 0
  for ti = 1, #d.tracks do
    if s and s.patterns[ti] then rack_rows = rack_rows + 1 end
  end
  verdict("steps-adapt-long-pattern",
          s and s.span_beats == 8 and s.nsteps == 32
          and d.patterns[4].len == 2 * BAR
          and rack_rows == #d.tracks and #rack_pids >= 1,
          s and ("%db/%d steps rows=%d unique=%s"):format(
            s.span_beats, s.nsteps, rack_rows, table.concat(rack_pids, ","))
          or "missing geometry")
end)
D.at(2286, function()
  local x, y = step_plus_xy()
  if not x then log("STEP +BEAT GEOMETRY MISSING"); return end
  D.click(D.f + 1, x, y)
end)
probe(2300, function()
  local d, s, aligned = doc(), plumb().steps, true
  for _, pid in ipairs(rack_pids or {}) do
    aligned = aligned and d.patterns[pid].len == rack_target_len
  end
  verdict("steps-plus-beat-all-rows",
          aligned and s and s.span_beats == rack_span_before + 1
          and rack_auto_clip and rack_auto_clip.len == rack_auto_used
          and rack_auto_clip.len < d.patterns[rack_auto_clip.pattern].len,
          s and ("span=%d auto=%d"):format(
            s.span_beats, rack_auto_clip and rack_auto_clip.len or -1)
          or "missing geometry")
end)
D.chord(2304, SC.ctrl, SC.z)
probe(2314, function()
  local d, restored = doc(), true
  for _, pid in ipairs(rack_pids or {}) do
    restored = restored and d.patterns[pid].len == rack_lengths[pid]
  end
  rack_names, rack_clip_owners = {}, {}
  for ti, tr in ipairs(d.tracks) do rack_names[ti] = tr.name end
  for _, c in ipairs(d.clips) do
    rack_clip_owners[#rack_clip_owners + 1] = {
      clip = c, track = d.tracks[c.track + 1],
    }
  end
  verdict("steps-plus-beat-one-undo",
          restored and plumb().steps.span_beats == rack_span_before)
end)
D.at(2318, function()
  local x0, y0 = step_handle_xy(4)
  local x1, y1 = step_handle_xy(2)
  if not (x0 and x1) then log("STEP HANDLE GEOMETRY MISSING"); return end
  D.drag(D.f + 1, x0, y0, x1, y1, 7)
end)
probe(2334, function()
  local r, d, attached = D.win("music"), doc(), true
  for _, owned in ipairs(rack_clip_owners or {}) do
    attached = attached
      and d.tracks[owned.clip.track + 1] == owned.track
  end
  verdict("steps-handle-reorders-tracks",
          attached and d.tracks[1].name == rack_names[1]
          and d.tracks[2].name == rack_names[4]
          and d.tracks[3].name == rack_names[2]
          and d.tracks[4].name == rack_names[3]
          and r.win.trk == 2 and plumb().g == nil)
end)
D.chord(2340, SC.ctrl, SC.z)
probe(2348, function()
  local d, restored = doc(), true
  for ti, name in ipairs(rack_names or {}) do
    restored = restored and d.tracks[ti].name == name
  end
  verdict("steps-handle-one-undo", restored and plumb().g == nil)
end)

probe(2354, function()
  verdict("summary", FAIL == 0, ("%d/%d"):format(PASS, PASS + FAIL))
  log("TAPE DONE")
end)
