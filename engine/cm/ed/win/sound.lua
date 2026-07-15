-- cm.ed.win.sound — the generic sound player (R9c, AUDIO.md §8): drop
-- any .wav/.mp3/.ogg anywhere and it opens here. Read-only (no journal,
-- no working bytes — the file IS the truth): the plumbing holds the
-- decoded PCM, a peaks cache, and the editor-bank stream voice. Playing
-- rides the render-only editor bank (D036 for sound) — headless
-- sessions decode nothing and play nothing.
--
-- Mouse: click the waveform = seek. Header chips: play/pause, stop,
-- loop. Hotkeys (§13 tables): space play/pause, home = start, L = loop.

local M = select(2, ...) or {}

M.kind = "sound"
M.help = "win-sound"
M.exts = { "wav", "mp3", "ogg" }
M.DEF_W, M.DEF_H = 460, 170

local COL = {
  well = 0x141220ff, wave = 0x7fd8a8ff, wave_dim = 0x4a8a6cff,
  head = 0xE8E4FFff, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  loopsh = 0x7fd8a822, err = 0xf07a7aff,
}

function M.defaults()
  return { path = "", loop = false }
end

function M.title(win)
  return win.path:match("([^/]+)$") or "sound"
end

function M.accepts(win, path)
  local ext = path:match("%.([%w_]+)$")
  ext = ext and ext:lower()
  return ext == "wav" or ext == "mp3" or ext == "ogg"
end

function M.rebind(win, ed, path)
  win.path = path
  ed.touch()
end

-- ---- plumbing (per WINDOW — two players on one file stay separate) ----

local function plumb(ed, win)
  local g = ed.g
  g.sndw = g.sndw or {}
  local p = g.sndw[win.id]
  if not p then
    p = {}
    g.sndw[win.id] = p
  end
  return p
end

local function stop(p)
  if p.playing then
    pal.x_snd_ed_off(p.voice)
    p.playing = false
  end
end

-- (re)send the stream patch — loop state rides the patch
local function send_patch(p, loop)
  cm.require("cm.snd").ed_patch(p.slot, {
    type = "stream", pcm = p.buf, gain = 128,
    a = 4, d = 0, s = 255, r = 20,
    loop = loop or false, loop0 = 0, loop1 = p.frames,
  })
end

local function open_sound(ed, win)
  local p = plumb(ed, win)
  if p.for_path == win.path then return p end
  stop(p)
  p.for_path = win.path
  p.pcm, p.err, p.peaks = nil, nil, nil
  p.pos = 0
  if win.path == "" then return p end
  local pcm, ch, _, frames = pal.x_snd_decode(ed.root .. "/" .. win.path)
  if not pcm then
    p.err = tostring(ch or "decode failed")
    return p
  end
  if ch == 1 then -- the stream voice is stereo interleaved: duplicate
    local out = {}
    for i = 1, #pcm, 2 do
      local s = pcm:sub(i, i + 1)
      out[#out + 1] = s
      out[#out + 1] = s
    end
    pcm = table.concat(out)
  end
  p.pcm, p.frames = pcm, frames
  if not p.slot then
    p.slot, p.voice = cm.require("cm.ed.kit").snd_alloc(ed, 1)
  end
  p.buf = ("ed.snd.play/%d"):format(win.id)
  for _, b in ipairs(pal.buf_list()) do
    if b.name == p.buf and b.size ~= #pcm then pal.buf_free(p.buf) end
  end
  pal.buf(p.buf, #pcm):setstr(0, pcm)
  send_patch(p, win.loop)
  return p
end

function M.open_win(win, ed)
  if win.path ~= "" then return open_sound(ed, win) end
end

-- ---- transport ----

local function play_from(ed, win, pos)
  local p = open_sound(ed, win)
  if not p.pcm then return end
  stop(p)
  pal.x_snd_ed_on(p.voice, p.slot, 60, 127, pos or p.pos or 0)
  p.playing = true
  p.started = pos or p.pos or 0
  ed.touch()
end

local function toggle(win, ed)
  local p = open_sound(ed, win)
  if not p.pcm then return end
  if p.playing then
    local pos = pal.x_snd_ed_pos(p.voice)
    p.pos = pos
    stop(p)
  else
    play_from(ed, win, p.pos)
  end
  ed.touch()
end

M.hotkeys = {
  { key = "space", hint = "play/pause",
    when = function(win) return win.path ~= "" end, fn = toggle },
  { key = "home", hint = "start",
    when = function(win) return win.path ~= "" end,
    fn = function(win, ed)
      local p = plumb(ed, win)
      p.pos = 0
      if p.playing then play_from(ed, win, 0) end
      ed.touch()
    end },
  { key = "l", hint = "loop",
    when = function(win) return win.path ~= "" end,
    fn = function(win, ed)
      win.loop = not win.loop
      local p = open_sound(ed, win)
      if p.pcm then send_patch(p, win.loop) end
      ed.touch()
    end },
}

-- ---- header: transport chips ----

-- the found-sound -> instrument door (AUDIO.md §8): mono-mix the
-- decoded PCM into a sampler .ins (embedded, root C4) and open the
-- synth window on it beside this one
function M.to_ins(win, ed)
  local p = plumb(ed, win)
  if not p.pcm or ed.parked then return end
  local mono = {}
  for i = 1, #p.pcm, 4 do
    local l = string.unpack("<i2", p.pcm, i)
    local r = string.unpack("<i2", p.pcm, i + 2)
    mono[#mono + 1] = string.pack("<i2", (l + r) // 2)
  end
  local base = (win.path:match("([^/]+)%.%w+$") or "sound"):lower()
  local doc = { name = base, pcm = table.concat(mono),
                patch = { type = "sample", root = 60, loop = false,
                          a = 2, d = 0, s = 255, r = 30, gain = 128 } }
  local path = "ins/" .. base .. ".ins"
  pal.mkdir(ed.root .. "/ins")
  local ok, err = pal.write_file_atomic(ed.root .. "/" .. path,
                    cm.require("cm.ins").encode(doc), p._create_fail)
  if ok then
    cm.require("cm.ed.win.assets").invalidate(ed)
    local wm = cm.require("cm.ed.wm")
    local K = ed.kinds.synth
    local sw = wm.spawn(ed.doc, "synth", win.x + win.w + 20, win.y,
                        K.DEF_W, K.DEF_H, K.defaults())
    sw.path = path
    K.open_win(sw, ed)
    ed.doc.focus = sw.id
    pal.log("[ed] imported " .. win.path .. " -> " .. path)
    ed.touch()
  else
    pal.log(("[ed] instrument create FAILED: %s (%s)")
            :format(path, tostring(err)))
    if ed.summon_console then ed.summon_console() end
  end
end

function M.header(win, ctx)
  if win.path == "" then return 0 end
  local ed = ctx.ed
  local p = plumb(ed, win)
  local s = cm.require("cm.ed.chips").strip(ctx)
  if s:chip("→ins", false) then M.to_ins(win, ed) end
  if s:chip("loop", win.loop) then
    win.loop = not win.loop
    local pp = open_sound(ed, win)
    if pp.pcm then send_patch(pp, win.loop) end
    ed.touch()
  end
  if s:chip("stop", false) then
    stop(p)
    p.pos = 0
    ed.touch()
  end
  if s:chip(p.playing and "pause" or "play", p.playing) then
    toggle(win, ed)
  end
  return s.used
end

-- ---- content: the waveform ----

local function peaks_for(p, cols)
  if p.peaks and p.pcols == cols then return p.peaks end
  local pk = {}
  local n = p.frames
  local unpack = string.unpack
  for c = 1, cols do
    local i0 = (c - 1) * n // cols
    local i1 = c * n // cols
    local step = math.max(1, (i1 - i0) // 64) -- sample the bucket
    local m = 0
    for i = i0, i1 - 1, step do
      local l = unpack("<i2", p.pcm, i * 4 + 1)
      local r = unpack("<i2", p.pcm, i * 4 + 3)
      local a = math.max(math.abs(l), math.abs(r))
      if a > m then m = a end
    end
    pk[c] = m / 32768
  end
  p.peaks, p.pcols = pk, cols
  return pk
end

local function fmt_time(frames)
  local secs = frames / 48000
  return ("%d:%04.1f"):format(secs // 60, secs % 60)
end

function M.draw(win, ctx)
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  if win.path == "" then
    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, COL.dim,
                  "drop a wav / mp3 / ogg here", 0)
    return
  end
  local ed = ctx.ed
  local p = open_sound(ed, win)
  if p.err then
    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, COL.err,
                  "decode failed: " .. p.err, 0)
    return
  end
  if not p.pcm then return end

  local wx, wy = ctx.cx, ctx.cy + 2 * z
  local ww, wh = ctx.cw, ctx.ch - px * 1.9 - 6 * z
  pal.x_ig_rect_fill(wx, wy, ww, wh, COL.well, 4 * z)
  if win.loop then
    pal.x_ig_rect_fill(wx, wy, ww, wh, COL.loopsh, 4 * z)
  end

  -- the waveform (mirrored peak columns)
  local cols = math.max(16, math.min(1200, ww // math.max(1, 2 * z) // 1))
  local pk = peaks_for(p, cols)
  local mid = wy + wh * 0.5
  local colw = ww / cols
  for c = 1, cols do
    local h = math.max(1, pk[c] * (wh * 0.48))
    pal.x_ig_line(wx + (c - 0.5) * colw, mid - h,
                  wx + (c - 0.5) * colw, mid + h, COL.wave_dim,
                  math.max(1, colw * 0.7))
  end

  -- playhead (live while playing; the resting pos otherwise). A voice
  -- that ran off the end flips the transport back to stopped.
  local pos = p.pos or 0
  if p.playing then
    local live, active = pal.x_snd_ed_pos(p.voice)
    if active then
      pos = live
      ctx.ed.touch()
    else
      p.playing = false
      p.pos = 0
      pos = 0
    end
  end
  local hx = wx + (pos / math.max(1, p.frames)) * ww
  pal.x_ig_line(hx, wy, hx, wy + wh, COL.head, math.max(1, 1.5 * z))

  -- time readout
  pal.x_ig_text(wx + 2 * z, wy + wh + 4 * z, px, COL.text,
                fmt_time(pos) .. " / " .. fmt_time(p.frames), 0)
  pal.x_ig_text(wx + ww - 60 * z, wy + wh + 4 * z, px, COL.dim,
                p.playing and "playing" or "stopped", 0)

  -- click = seek (the pointer gate + inside the waveform well)
  local i = cm.require("cm.ui").inp
  if ctx.hot and i.clicked[1] and i.wx >= wx and i.wx < wx + ww
     and i.wy >= wy and i.wy < wy + wh then
    local f = (i.wx - wx) / ww
    local target = math.floor(f * p.frames)
    p.pos = target
    if p.playing then play_from(ed, win, target) end
    ctx.touch()
  end
end

return M
