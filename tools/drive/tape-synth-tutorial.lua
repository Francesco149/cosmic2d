-- tools/drive/tape-synth-tutorial.lua — drives win-synth.md's
-- "four-sound chip kit" walkthrough AS WRITTEN (HELPDOCS H7, D160):
-- lead / bass / kick / jump plus the sound-player feeder, with VERDICT
-- probes at each stage and CROP lines logged for the screenshot set.
-- (Adopted in-repo under the D161 tapes-ship convention; the H7 session
-- ran it from a scratchpad.)
--
-- THE CAPTURE RECIPE (HELPDOCS §3):
--   1. fresh smoke copy:   cp -r projects/smoke <scratch>/smoke-h7
--   2. full proof run:     bin/cosmic <scratch>/smoke-h7 --edit --headless \
--        --win 1280x800 --frames 990 --eval \
--        "dofile('tools/drive/tape-synth-tutorial.lua')" --shot <scratch>/full.png
--      → every VERDICT line in the log must read true.
--   3. screenshots are the tape's own frames AT 2x (the D163 @2x capture
--      contract — D.shot_zoom in drive.lua): re-run ON A FRESH COPY with
--      --frames at the shot's frame and SHOT set, then crop to the
--      logged CROP rect:
--        bin/cosmic <copy> ... --frames 284 --eval \
--          "rawset(_G,'SHOT','synth-fresh'); dofile('tools/drive/tape-synth-tutorial.lua')" \
--          --shot raw.png
--        magick raw.png -crop WxH+X+Y media/synth-fresh@2x.png
--      The synth window is 420x560: the full-height shots (synth-fresh,
--      synth-presets) rerun at --win 1280x1200 so the 2x window fits the
--      surface — the tape's math is surface-size independent (the spawn
--      clamps never engage at these menu positions).
--   4. stage crops under engine/stock/docs/media/ as <name>@2x.png
--      (layout ≤700x550 = intrinsic ≤1400x1100), look at each one
--      yourself, montage to llm-feed with title+note.
--
-- Shot frames (stable while the tape above them is unchanged):
--   f284 synth-fresh · f360 synth-adsr · f544 synth-presets
--   f739 synth-kick · f936 sound-player
local D = dofile("tools/drive/drive.lua")
local SC = D.SC

local function log(s) pal.log("[tape] " .. s) end

-- ---- geometry mirrors (z = 1 through the input phase; crops read the
-- live z so the @2x reruns scale their rects) ----
-- the synth draw() layout, content rect from D.win
local function syn(kind_r, pre)
  local r = kind_r
  local z = r.z
  local px = math.max(4, 10.5 * z)
  local x0, y0 = r.cx + 4 * z, r.cy + 4 * z
  local cw, ch = r.cw - 8 * z, r.ch
  if pre then
    local rw = math.min(130 * z, cw * 0.35)
    x0 = x0 + rw
    cw = cw - rw
  end
  local g = { z = z, px = px, x0 = x0, y0 = y0, cw = cw }
  g.y_gain = y0 + px * 2.0
  g.y_flt = g.y_gain + px * 1.6
  g.y_swp = g.y_flt + px * 1.5
  g.y_ops = g.y_swp + px * 1.7
  g.pw = cw / 2 - 3 * z
  g.ph = (r.ch - (g.y_ops - r.cy) - 60 * z) / 2 - 4 * z
  g.sh = px * 1.25
  return g
end
local function opgeom(g, o)
  local z = g.z
  local ox = g.x0 + ((o - 1) % 2) * (g.pw + 6 * z)
  local oy = g.y_ops + ((o - 1) // 2) * (g.ph + 6 * z)
  local sy = oy + g.px * 1.9
  return { ox = ox, oy = oy, sy = sy,
           adsr_x = ox + 4 * z, adsr_y = sy + 5 * g.sh + 2 * z,
           adsr_w = g.pw - 8 * z,
           adsr_h = math.max(10, g.ph - (5 * g.sh + g.px * 2.4)) }
end
-- slider target x for value (slider(x, w): bar bx = x+34, bw = w-70)
local function slx(x, w, lo, hi, v)
  return x + 34 + (v - lo) / (hi - lo) * (w - 70)
end
-- chiprow item center (row x, w, n items, item i 1-based)
local function chipx(x, w, n, i)
  local cwi = w / n
  return x + (i - 1) * cwi + (cwi - 2) / 2
end
local function env_fx(ms, tmax) -- mirrors env_ms_to_fx
  if ms <= 1 then return 0 end
  return math.max(0, math.min(1, math.log(ms) / math.log(tmax)))
end

-- set a slider to a value: press-move-release at the target x
local function set_slider(f, x, w, lo, hi, v, rowy)
  local tx = slx(x, w, lo, hi, v)
  D.drag(f, tx, rowy + 4, tx, rowy + 4, 2)
end

-- ---- spawn a synth window via right-click menu (menu item 16 = synth;
-- 20 items, iw 150 ih 26 pad 6) ----
local function spawn_synth(f, sx, sy, tries)
  D.rclick(f, sx, sy)
  D.at(f + 4, function()
    local m = cm.ed.g.menu
    if not m then
      tries = (tries or 0) + 1
      if tries <= 3 then
        log("SPAWNMENU RETRY " .. tries)
        spawn_synth(D.f + 4, sx, sy, tries)
      else
        log("SPAWNMENU GIVE UP")
      end
      return
    end
    local chrome = cm.require("cm.ed.chrome")
    local iw, ih, pad = 150, 26, 6
    local mh = 20 * ih + pad * 2
    local mx = math.min(m.sx / chrome.scale(), 1280 - iw - 8)
    local my = math.min(m.sy / chrome.scale(), 800 - mh - 8)
    local y = my + pad + 15 * ih -- synth = 16th item
    D.click(D.f + 1, mx + 40, y + ih / 2)
  end)
end

-- type a path into the kit pathfield of the newest window of `kind`
local function type_path(f, kind, path)
  D.at(f, function()
    local r = D.win(kind)
    local fy = r.cy + 8 + 10.5 * 1.8
    D.click(D.f + 1, r.cx + 60, fy + 8)
    D.chord(D.f + 4, SC.ctrl, SC.a)
    D.at(D.f + 8, function() return { D.textev(path) } end)
    D.tap(D.f + 10, SC.enter)
  end)
end

-- click the presets header chip (right-aligned; g.hdrx = left edge of
-- the chip zone, chips start 4z right of it)
local function click_presets(f, kind)
  D.at(f, function()
    local r = D.win(kind)
    local hdrx = cm.ed.g.hdrx[r.win.id]
    D.click(D.f + 1, hdrx + 14, r.y + 12)
  end)
end

-- scroll the presets rail and click the row labeled `label`
local function load_preset(f, kind, label)
  D.at(f, function()
    local r = D.win(kind)
    local p = cm.ed.g.iw[r.win.path]
    if not (p and p.rail_rect) then log("RAIL MISSING") return end
    local rr = p.rail_rect
    -- wheel until the row is inside the rail band
    D.at(D.f + 1, function()
      return { { type = "wheel", dx = 0, dy = -12 } }
    end)
    D.at(D.f + 0, function() return { D.mouse(rr.x + 40, rr.y + 100) } end)
    D.at(D.f + 6, function()
      local list = p.presets
      local idx -- first match = the stock row (stock lists first)
      for n, item in ipairs(list) do
        if item.label == label and not idx then idx = n end
      end
      if not idx then log("PRESET NOT FOUND " .. label) return end
      local u = cm.require("cm.ed.kit").winui(p, r.win)
      local row_h = 10.5 * 1.45
      local ry = rr.y + 4 - (u.prescroll or 0) + (idx - 1) * row_h
      if ry < rr.y or ry + row_h > rr.y + rr.h then
        log("PRESET ROW OFFSCREEN " .. label .. " ry=" .. ry)
        return
      end
      D.click(D.f + 1, rr.x + 40, ry + 5)
    end)
  end)
end

local function probe(f, fn) D.at(f, fn) end
local function crop(name, x, y, w, h)
  log(("CROP %s %d %d %d %d"):format(name, math.floor(x), math.floor(y),
                                     math.floor(w), math.floor(h)))
end

-- the @2x shot declarations (fire only when SHOT matches; see header)
D.shot_zoom("synth-fresh", 284, "synth")
D.shot_zoom("synth-adsr", 360, "synth")
D.shot_zoom("synth-presets", 544, "synth")
D.shot_zoom("synth-kick", 739, "synth")
D.shot_zoom("sound-player", 936, "sound")

-- ================= stage 0: clear the session windows =================
-- the smoke project ships a saved editor session; Ctrl+W needs a FOCUSED
-- window, so cycle focus (Ctrl+Tab) then close, until the canvas is bare
for k = 0, 21 do
  D.chord(4 + k * 8, SC.ctrl, SC.tab)
  D.chord(8 + k * 8, SC.ctrl, SC.w)
end
probe(182, function()
  log("wins after clear: " .. #cm.ed.doc.wins)
  -- stage management: the clear pass eased the camera; normalize so
  -- the geometry mirrors (z = 1) hold for the whole input phase
  cm.ed.g.anim = nil -- kill any in-flight camera ease
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
end)

-- ================= stage 1: the lead =================
spawn_synth(184, 350, 120)
probe(206, function() -- re-normalize once the clear-pass ease settled
  cm.ed.g.anim = nil -- kill any in-flight camera ease
  cm.ed.doc.cam.x, cm.ed.doc.cam.y, cm.ed.doc.cam.zoom = 0, 0, 1
  cm.ed.touch()
end)
type_path(210, "synth", "ins/lead.ins")

probe(232, function()
  local r = D.win("synth")
  log("VERDICT lead-created " ..
      tostring(r and r.win.path == "ins/lead.ins") ..
      " z=" .. tostring(r and r.z))
end)

-- step 2: hold z (audition) then drag op1 lvl 70 -> 95
D.at(236, function() return { D.keyev(SC.z, true) } end)
D.at(238, function() return { D.keyev(SC.z, false) } end)
D.at(244, function()
  local r = D.win("synth")
  local g = syn(r, false)
  local o1 = opgeom(g, 1)
  set_slider(D.f + 1, o1.ox + 4, g.pw - 8, 0, 255, 95, o1.sy)
end)

-- step 3: fb6 chip (fb row: x0+cw*0.58, w cw*0.42, 8 items, item 7)
D.at(260, function()
  local r = D.win("synth")
  local g = syn(r, false)
  D.click(D.f + 1, chipx(g.x0 + g.cw * 0.58, g.cw * 0.42, 8, 7),
          g.y0 + 8)
end)

-- shot: the fresh-ish window (init patch + first tweaks)
probe(284, function()
  local r = D.win("synth")
  crop("synth-fresh", r.x, r.cy, math.floor(r.cw), math.floor(r.ch))
end)

-- step 4: op2 sustain up to ~210 (ds handle: middle third), op1 D200 S180
D.at(296, function()
  local r = D.win("synth")
  local g = syn(r, false)
  local o2 = opgeom(g, 2)
  local third = o2.adsr_w / 3
  -- press on the current ds handle area then drag to D 0ms, S 210
  local tx = o2.adsr_x + third + third * env_fx(1, 2000) + 2
  local ty = o2.adsr_y + o2.adsr_h * 0.04
            + (1 - 210 / 255) * o2.adsr_h * 0.92
  local fx0 = o2.adsr_x + third + third * env_fx(120, 2000)
  local fy0 = o2.adsr_y + o2.adsr_h * 0.04
             + (1 - 180 / 255) * o2.adsr_h * 0.92
  D.at(D.f + 1, function() return { D.mouse(fx0, fy0) } end)
  D.at(D.f + 2, function() return { D.btn(fx0, fy0, true) } end)
  for s = 1, 40 do
    local t = s / 40
    local x, y = fx0 + (tx - fx0) * t, fy0 + (ty - fy0) * t
    D.at(D.f + 2 + s, function() return { D.mouse(x, y) } end)
  end
  D.at(D.f + 60, function() return { D.btn(tx, ty, false) } end)
end)

-- shot: the op2 ADSR right after the drag settles
probe(360, function()
  local r = D.win("synth")
  local g = syn(r, false)
  local o2 = opgeom(g, 2)
  crop("synth-adsr", math.floor(o2.ox), math.floor(o2.oy),
       math.floor(g.pw), math.floor(g.ph))
end)

-- op1: D 200ms S 180 (softening brightness)
D.at(376, function()
  local r = D.win("synth")
  local g = syn(r, false)
  local o1 = opgeom(g, 1)
  local third = o1.adsr_w / 3
  local tx = o1.adsr_x + third + third * env_fx(200, 2000)
  local ty = o1.adsr_y + o1.adsr_h * 0.04
            + (1 - 180 / 255) * o1.adsr_h * 0.92
  D.drag(D.f + 1, tx, ty, tx, ty, 3)
end)

-- step 5: save
D.chord(396, SC.ctrl, SC.s)
probe(406, function()
  local p = cm.ed.g.iw["ins/lead.ins"]
  local d = p and p.doc
  local ok = d and d.patch.fb == 6 and d.patch.ops[1].level == 95
             and d.patch.ops[2].s >= 200 and d.patch.ops[2].s <= 220
  log("VERDICT lead-patch " .. tostring(ok) .. " fb=" ..
      tostring(d and d.patch.fb) .. " o1lvl=" ..
      tostring(d and d.patch.ops[1].level) .. " o2s=" ..
      tostring(d and d.patch.ops[2].s))
  log("VERDICT lead-saved " ..
      tostring(pal.read_file(cm.ed.root .. "/ins/lead.ins") ~= nil))
end)

-- close the lead window (stage management)
D.chord(416, SC.ctrl, SC.w)

-- ================= stage 2: the bass =================
spawn_synth(426, 80, 60)
type_path(436, "synth", "ins/bass.ins")
click_presets(466, "synth")
load_preset(476, "synth", "gb-pulse-50")
-- two octaves down + audition
D.tap(501, 54) -- comma scancode 54
D.tap(504, 54)
D.at(507, function() return { D.keyev(SC.z, true) } end)
D.at(509, function() return { D.keyev(SC.z, false) } end)
-- flt lp + cut 110 (rail open: pre=true)
D.at(516, function()
  local r = D.win("synth")
  local g = syn(r, true)
  D.click(D.f + 1, chipx(g.x0, g.cw * 0.30, 3, 2), g.y_flt + 5)
  D.at(D.f + 5, function()
    set_slider(D.f + 1, g.x0 + g.cw * 0.32, g.cw * 0.68, 0, 255, 110,
               g.y_flt)
  end)
end)
D.chord(536, SC.ctrl, SC.s)

-- shot: presets rail with the loaded marker
probe(544, function()
  local r = D.win("synth")
  crop("synth-presets", r.x, r.y, 320 * r.z,
       math.floor(math.min(r.h, 548 * r.z)))
end)
probe(551, function()
  local p = cm.ed.g.iw["ins/bass.ins"]
  local d = p and p.doc
  local r = D.win("synth")
  local ok = d and d.name == "bass" and d.patch.ops[1].wave == "square"
             and d.patch.filter == "lp" and d.patch.cutoff == 110
  log("VERDICT bass-patch " .. tostring(ok) .. " name=" ..
      tostring(d and d.name) .. " wave=" ..
      tostring(d and d.patch.ops[1].wave) .. " flt=" ..
      tostring(d and d.patch.filter) .. " cut=" ..
      tostring(d and d.patch.cutoff) .. " oct=" ..
      tostring(r and r.win.oct))
end)
D.chord(561, SC.ctrl, SC.w)

-- ================= stage 3: the kick =================
spawn_synth(571, 80, 60)
type_path(581, "synth", "ins/kick.ins")
-- chip 8 (alg row item 8)
D.at(616, function()
  local r = D.win("synth")
  local g = syn(r, false)
  D.click(D.f + 1, chipx(g.x0, g.cw * 0.55, 8, 8), g.y0 + 8)
end)
-- op1 lvl 255, ds -> D180 S0, r -> 70
D.at(626, function()
  local r = D.win("synth")
  local g = syn(r, false)
  local o1 = opgeom(g, 1)
  set_slider(D.f + 1, o1.ox + 4, g.pw - 8, 0, 255, 255, o1.sy)
  local third = o1.adsr_w / 3
  local dx = o1.adsr_x + third + third * env_fx(180, 2000)
  local dy = o1.adsr_y + o1.adsr_h * 0.96
  D.drag(D.f + 8, dx, dy, dx, dy, 3)
  local rx = o1.adsr_x + 2 * third + third * env_fx(70, 4000)
  D.drag(D.f + 16, rx, o1.adsr_y + o1.adsr_h * 0.5, rx,
         o1.adsr_y + o1.adsr_h * 0.5, 3)
end)
-- swp -20, sw ms 70
D.at(656, function()
  local r = D.win("synth")
  local g = syn(r, false)
  set_slider(D.f + 1, g.x0, g.cw * 0.5, -48, 48, -20, g.y_swp)
  D.at(D.f + 8, function()
    set_slider(D.f + 1, g.x0 + g.cw * 0.5, g.cw * 0.5, 0, 1000, 70,
               g.y_swp)
  end)
end)
-- op2: ns wave, lvl 100, fix ~3200Hz, D30 S0
D.at(681, function()
  local r = D.win("synth")
  local g = syn(r, false)
  local o2 = opgeom(g, 2)
  D.click(D.f + 1, chipx(o2.ox + 30, g.pw - 34, 8, 7), o2.oy + 8)
  D.at(D.f + 5, function()
    set_slider(D.f + 1, o2.ox + 4, g.pw - 8, 0, 255, 100, o2.sy)
  end)
  D.at(D.f + 13, function()
    set_slider(D.f + 1, o2.ox + 4, g.pw - 8, 0, 255, 203,
               o2.sy + 4 * g.sh) -- fix idx 203 = ~3239 Hz
  end)
  D.at(D.f + 21, function()
    local third = o2.adsr_w / 3
    local dx = o2.adsr_x + third + third * env_fx(30, 2000)
    local dy = o2.adsr_y + o2.adsr_h * 0.96
    D.drag(D.f + 1, dx, dy, dx, dy, 3)
  end)
end)
-- audition the kick on two different keys (fixed op stays put)
D.at(716, function() return { D.keyev(SC.z, true) } end)
D.at(718, function() return { D.keyev(SC.z, false) } end)
D.tap(721, 12) -- 'i' scancode 12: top of the upper octave
D.chord(731, SC.ctrl, SC.s)

-- shot: voice strip + op row
probe(739, function()
  local r = D.win("synth")
  local g = syn(r, false)
  crop("synth-kick", r.x, r.y, math.floor(r.cw),
       math.floor((g.y_ops - r.y) + g.ph + 8 * r.z))
end)
probe(746, function()
  local p = cm.ed.g.iw["ins/kick.ins"]
  local d = p and p.doc
  local ok = d and d.patch.alg == 7 and d.patch.sweep == -20
             and d.patch.sweep_ms == 70 and d.patch.ops[1].level == 255
             and d.patch.ops[1].s == 0 and d.patch.ops[2].wave == "noise"
             and d.patch.ops[2].level == 100
             and d.patch.ops[2].fixed == 3239 and d.patch.ops[2].s == 0
  log("VERDICT kick-patch " .. tostring(ok) .. " alg=" ..
      tostring(d and d.patch.alg) .. " swp=" ..
      tostring(d and d.patch.sweep) .. " o2wave=" ..
      tostring(d and d.patch.ops[2].wave) .. " o2fix=" ..
      tostring(d and d.patch.ops[2].fixed))
end)
D.chord(756, SC.ctrl, SC.w)

-- ================= stage 4: the jump =================
spawn_synth(766, 80, 60)
type_path(776, "synth", "ins/jump.ins")
click_presets(806, "synth")
load_preset(816, "synth", "sfx-jump")
-- bend swp to +19 (rail open)
D.at(846, function()
  local r = D.win("synth")
  local g = syn(r, true)
  set_slider(D.f + 1, g.x0, g.cw * 0.5, -48, 48, 19, g.y_swp)
end)
D.chord(861, SC.ctrl, SC.s)
probe(871, function()
  local p = cm.ed.g.iw["ins/jump.ins"]
  local d = p and p.doc
  local ok = d and d.name == "jump" and d.patch.sweep == 19
             and d.patch.ops[1].wave == "pulse25"
  log("VERDICT jump-patch " .. tostring(ok) .. " swp=" ..
      tostring(d and d.patch.sweep) .. " wave=" ..
      tostring(d and d.patch.ops[1].wave))
end)
D.chord(881, SC.ctrl, SC.w)

-- ================= stage 5: the sound player =================
-- the doc's found-sound: a deterministic 0.15 s hit (decaying LCG
-- noise, 8 kHz mono 16-bit PCM) synthesized into the smoke copy — the
-- tape carries its own fixture instead of pointing at a scratchpad
local function gen_hit_wav(path)
  local n, rate = 1200, 8000
  local s = {}
  local seed = 12345
  for i = 0, n - 1 do
    seed = (seed * 1103515245 + 12345) % 2147483648
    local r = (seed / 2147483648) * 2 - 1
    local v = math.floor(r * (1 - i / n) * 12000)
    if v < 0 then v = v + 65536 end
    s[#s + 1] = string.char(v % 256, (v // 256) % 256)
  end
  local data = table.concat(s)
  local function u32(x)
    return string.char(x % 256, (x // 256) % 256, (x // 65536) % 256,
                       (x // 16777216) % 256)
  end
  local fmt = "fmt " .. u32(16) .. string.char(1, 0, 1, 0) .. u32(rate)
              .. u32(rate * 2) .. string.char(2, 0, 16, 0)
  pal.write_file(path, "RIFF" .. u32(4 + #fmt + 8 + #data) .. "WAVE"
                 .. fmt .. "data" .. u32(#data) .. data)
end
D.at(886, function()
  gen_hit_wav(cm.ed.root .. "/hit.wav")
end)
D.at(891, function()
  local p = cm.ed.root .. "/hit.wav"
  return { { type = "drop", path = p, x = 700, y = 300,
             wx = 700, wy = 300 } }
end)
D.tap(911, SC.space) -- play
probe(936, function()
  local r = D.win("sound")
  if r then
    crop("sound-player", r.x, r.y, math.floor(r.w) + 2,
         math.floor(r.h) + 2)
  else
    log("VERDICT sound-window false")
  end
end)
-- →ins: chips lay right-to-left in call order, so →ins (called first)
-- is the RIGHTMOST chip. Rebuild the strip x from the labels' widths.
D.at(946, function()
  local r = D.win("sound")
  local hdrx = cm.ed.g.hdrx[r.win.id]
  local p = cm.ed.g.sndw and cm.ed.g.sndw[r.win.id]
  local labels = { "→ins", "loop", "stop",
                   (p and p.playing) and "pause" or "play" }
  local used = 0
  for _, l in ipairs(labels) do
    used = used + pal.x_ig_text_size(l, 10.5, 0) + 14 + 4
  end
  local w1 = pal.x_ig_text_size("→ins", 10.5, 0) + 14
  D.click(D.f + 1, hdrx + used - w1 / 2, r.y + 12)
end)
probe(966, function()
  local r = D.win("sound")
  local sr = D.win("synth")
  local playing = cm.ed.g.sndw and cm.ed.g.sndw[r.win.id]
                  and cm.ed.g.sndw[r.win.id].playing
  log("VERDICT sound-played " .. tostring(playing ~= nil))
  log("VERDICT toins " ..
      tostring(sr ~= nil and sr.win.path == "ins/hit.ins") .. " " ..
      tostring(pal.read_file(cm.ed.root .. "/ins/hit.ins") ~= nil))
end)

probe(976, function()
  log("TAPE DONE")
end)
