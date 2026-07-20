-- cm.snd — the sim-side audio surface (R9b, docs/AUDIO.md §6): a thin
-- layer over pal.snd_*. Patches are friendly Lua tables packed to the
-- 80-byte flat struct the kernel reads (pure both ways — KAT'd); voice
-- calls forward to the sim bank (snd.bank — recorded, replayed,
-- rewound by construction). The sequencer (cm.snd.seq) and the .ins
-- slot cache land at R9d/R9c; the editor bank's audition mirror is
-- x_snd_ed_* with the same packed bytes.
--
-- The patch table (every field defaulted — the wstudio lesson):
--   { type = "fm"|"sample", alg = 0..7, fb = 0..7, pan = -64..64,
--     gain = 0..255 (128 unity),
--     -- voice-wide fx (R9f): a 1-pole filter (hp = the GB "sizzle") and
--     -- a pitch sweep (dash / whoosh / kick-drop). Omit = bypass.
--     filter = "off"|"lp"|"hp", cutoff = 0..255 (index; ~20Hz..16kHz),
--     sweep = semitones (signed), sweep_ms = glide time,
--     ops = { { wave = "sine"|"square"|"pulse25"|"pulse12"|"saw"|
--                      "tri"|"noise"|"noise2",
--               coarse = 0..15 (0 = x0.5), fine = -63..63,
--               level = 0..255, a/d/r = ms, s = 0..255,
--               detune = -63..63, fixed = hz|nil }, x4 },
--     -- type "sample":
--     pcm = "<named buffer>" (mono i16 @48k), root = midi note,
--     loop = bool, loop0/loop1 = sample frames, a/d/r = ms, s = 0..255 }

local M = select(2, ...) or {}

M.WAVES = { sine = 0, square = 1, pulse25 = 2, pulse12 = 3,
            saw = 4, tri = 5, noise = 6, noise2 = 7 }
local WAVE_NAMES = {}
for k, v in pairs(M.WAVES) do WAVE_NAMES[v] = k end

local pack, unpack = string.pack, string.unpack

local OP_FMT = "<I1I1i1I1I2I2I2I1i1I1I1I2"
local HDR_FMT = "<I1I1I1I1i1I1I2"

-- the voice-wide effects trailer (R9f): the SndPatch pad1[8] tail —
-- filter + pitch sweep. All-zero = bypass, so a pre-R9f patch packs
-- byte-identical (goldens safe). See AUDIO.md §6 / pal/src/snd.c.
M.FILTERS = { off = 0, lp = 1, hp = 2 }
local FILTER_NAMES = { [0] = "off", "lp", "hp" }
local function pack_fx(t)
  return pack("<I1I1i1I2", M.FILTERS[t.filter or "off"] or 0,
              t.cutoff or 0, t.sweep or 0, t.sweep_ms or 0) .. "\0\0\0"
end

local function pack_op(op)
  op = op or {}
  return pack(OP_FMT,
    M.WAVES[op.wave or "sine"] or 0,
    op.coarse or 1, op.fine or 0, op.level or 0,
    op.a or 5, op.d or 100, op.r or 80, op.s or 200,
    op.detune or 0, op.fixed and 1 or 0, 0, op.fixed or 0)
end

-- the pure packer: patch table -> the kernel's 80 bytes
function M.pack(t)
  t = t or {}
  local typ = t.type == "sample" and 1 or t.type == "stream" and 2 or 0
  local head = pack(HDR_FMT, typ, t.alg or 0, t.fb or 0, 0,
                    t.pan or 0, t.gain or 128, 0)
  if typ ~= 0 then
    local name = tostring(t.pcm or "")
    assert(#name <= 24, "pcm buffer name over 24 bytes")
    local body = name .. string.rep("\0", 24 - #name)
      .. pack("<I1I1I2I2I2I1I1I4I4", t.root or 60, t.loop and 1 or 0,
              t.a or 2, t.d or 0, t.r or 30, t.s or 255, 0,
              t.loop0 or 0, t.loop1 or 0)
      .. string.rep("\0", 22)
    return head .. body .. pack_fx(t)
  end
  local ops = t.ops or {}
  return head .. pack_op(ops[1]) .. pack_op(ops[2]) .. pack_op(ops[3])
         .. pack_op(ops[4]) .. pack_fx(t)
end

-- the inverse (the synth window edits over decoded tables)
function M.unpack(bytes)
  assert(#bytes == 80, "patch must be 80 bytes")
  local typ, alg, fb, _, pan, gain = unpack(HDR_FMT, bytes)
  local t = { alg = alg, fb = fb, pan = pan, gain = gain }
  local ft, fc, sw, sms = unpack("<I1I1i1I2", bytes, 73)
  t.filter, t.cutoff, t.sweep, t.sweep_ms =
    FILTER_NAMES[ft] or "off", fc, sw, sms
  if typ ~= 0 then
    t.type = typ == 2 and "stream" or "sample"
    t.pcm = bytes:sub(9, 32):gsub("%z+$", "")
    local root, sflags, a, d, r, s, _, l0, l1 =
      unpack("<I1I1I2I2I2I1I1I4I4", bytes, 33)
    t.root, t.loop = root, sflags % 2 == 1
    t.a, t.d, t.r, t.s = a, d, r, s
    t.loop0, t.loop1 = l0, l1
    return t
  end
  t.type = "fm"
  t.ops = {}
  local off = 9
  for i = 1, 4 do
    local wave, coarse, fine, level, a, d, r, s, detune, ofl, _, fhz =
      unpack(OP_FMT, bytes, off)
    t.ops[i] = { wave = WAVE_NAMES[wave] or "sine", coarse = coarse,
                 fine = fine, level = level, a = a, d = d, r = r, s = s,
                 detune = detune, fixed = ofl % 2 == 1 and fhz or nil }
    off = off + 16
  end
  return t
end

-- ---- the sim bank (recorded; call from sim code only) ----

function M.patch(slot, t)
  pal.snd_patch(slot, type(t) == "string" and t or M.pack(t))
end

function M.on(slot, note, vel)
  return pal.snd_on(slot, note, vel or 100)
end

function M.off(voice)
  pal.snd_off(voice)
end

-- ---- the editor bank (render-only audition; editor code only) ----

function M.ed_patch(slot, t)
  pal.x_snd_ed_patch(slot, type(t) == "string" and t or M.pack(t))
end

M.ed_on = pal and pal.x_snd_ed_on
M.ed_off = pal and pal.x_snd_ed_off

-- A track fader is centred on the instrument author's chosen gain, but both
-- halves of its 0..255 travel must stay useful. A straight multiply clips a
-- loud preset early and can never bring a quiet preset all the way forward.
-- Interpolate 0 -> preset -> 255 instead: 128 remains exact unity while the
-- endpoints are real silence and the loudest representable patch gain.
function M.track_gain(base_gain, track_gain)
  local base = math.max(0, math.min(255,
    math.floor(tonumber(base_gain) or 128)))
  local track = math.max(0, math.min(255,
    math.floor(tonumber(track_gain) or 128)))
  if track <= 128 then return base * track // 128 end
  return base + (255 - base) * (track - 128) // 127
end

-- ---- the sequencer (R9d, AUDIO.md §6/§10) ----
--
-- Music is SIM STATE: the transport lives in the doc tree
-- (state.doc.snd = { song, start frame, loop, held }) so snapshots/
-- traces/rewind carry it; the flattened note list is a derived cache
-- (rebuilt on any miss — rewind-safe by construction). Tick math is
-- pure integer: at PPQ 96 and 48 kHz, ticks(s) = s*bpm*96 // 2880000.
-- cm.main calls M.step() inside the sim step, right before
-- pal.snd_render().

M.seq = {}
local PPQ = 96
local SR60 = 48000 * 60 -- 2880000

function M.seq.ticks_at(samples, bpm)
  return samples * bpm * PPQ // SR60
end

function M.seq.samples_at(ticks, bpm)
  return ticks * SR60 // (bpm * PPQ)
end

-- the derived caches (NOT state: rebuilt whenever they don't match)
local cache = { path = nil, flat = nil, doc = nil, slots = nil }

-- forget the derived song cache. The uploaded track patches live in the
-- snd.bank named buffer, but this cache is a module upvalue: a game RESTART
-- (cm.main.reset_game) frees snd.bank and re-runs game.init WITHOUT rebooting
-- the VM, so without this the next step()'s load_song short-circuits on the
-- stale cache and never re-uploads the patches into the fresh (empty) bank —
-- the music then triggers silent voices ("music stops after restarting in
-- town", the human's bug). reset_game calls this; a VM reboot re-requires the
-- module fresh so its cache starts empty anyway.
function M.seq.reset()
  cache.path, cache.flat, cache.doc, cache.slots = nil, nil, nil, nil
end

-- resolve a track's instrument: direct first (absolute / cwd-relative),
-- then relative to the song's PROJECT dir (a song at <proj>/sound/x.song
-- storing tr.ins "ins/y.ins" -> <proj>/ins/y.ins). Makes a self-contained
-- project's songs play from any cwd (the game runs from the engine root;
-- packaging relocates the tree) — the editor stores project-relative ins.
local function read_ins(song_path, ins_path)
  if not ins_path or ins_path == "" then return nil end
  local b = pal.read_file(ins_path)
  if b then return b end
  local sdir = song_path and song_path:match("^(.*)/[^/]*$") -- .../sound
  local proj = sdir and sdir:match("^(.*)/[^/]*$")           -- the project
  if proj then return pal.read_file(proj .. "/" .. ins_path) end
  return nil
end

local function load_song(path)
  if cache.path == path and cache.flat then return true end
  local bytes = pal.read_file(path)
  if not bytes then return false end
  local song = cm.require("cm.song")
  local ok, doc = pcall(song.decode, bytes)
  if not ok then return false end
  cache.path, cache.doc, cache.flat = path, doc, song.flatten(doc)
  -- track instruments -> sim-bank slots 32..47 (game sfx keep 0..31 by
  -- convention); per-track gain/pan bake into the uploaded patch
  cache.slots = {}
  for ti, tr in ipairs(doc.tracks) do
    local slot = 31 + ti
    if slot > 47 then break end
    local ibytes = read_ins(path, tr.ins)
    if ibytes then
      local iok, idoc = pcall(cm.require("cm.ins").decode, ibytes)
      if iok then
        idoc.patch.gain = M.track_gain(idoc.patch.gain, tr.gain)
        idoc.patch.pan = math.max(-64, math.min(64,
          (idoc.patch.pan or 0) + (tr.pan or 0)))
        cm.require("cm.ins").upload(idoc, slot, "sim", "t" .. ti)
      end
    end
    cache.slots[ti] = slot
  end
  return true
end

-- start a song (sim code; the path is engine-cwd-relative or project-
-- relative — pass what pal.read_file can open). Recorded, replayed,
-- rewound like everything else.
function M.music(path, opts)
  local st = cm.require("cm.state")
  -- release the previous song's ringing voices — else a note held at the
  -- swap (room change) rings forever over the new song (the human's bug)
  local prev = st.doc.snd
  if prev and prev.held then
    for _, h in pairs(prev.held) do pal.snd_off(h.v) end
  end
  st.doc.snd = { song = path, start = st.frame(), held = {},
                 loop = not (opts and opts.loop == false) }
end

function M.music_stop()
  local st = cm.require("cm.state")
  local s = st.doc.snd
  if s and s.held then
    for _, h in pairs(s.held) do pal.snd_off(h.v) end
  end
  st.doc.snd = nil
end

-- one sim frame of sequencing: emit the ons/offs whose ticks land in
-- this frame's 800-sample window. Loop wraps split the window in two.
function M.step()
  local st = cm.require("cm.state")
  local s = st.doc.snd
  if not s then return end
  if not load_song(s.song) then return end
  local doc, flat, slots = cache.doc, cache.flat, cache.slots
  local bpm = doc.bpm
  local L = cm.require("cm.song").length(doc)
  if L <= 0 then return end
  local SL = M.seq.samples_at(L, bpm) -- song length in samples
  if SL <= 0 then return end
  local rel = (st.frame() - s.start) * 800
  if rel < 0 then return end
  local windows -- up to two [s0,s1) sample spans in song space
  if s.loop then
    local w0 = rel % SL
    if w0 + 800 <= SL then
      windows = { { w0, w0 + 800 } }
    else
      windows = { { w0, SL }, { 0, w0 + 800 - SL } }
    end
  else
    if rel >= SL then -- past the end: release stragglers, stop
      M.music_stop()
      return
    end
    windows = { { rel, math.min(SL, rel + 800) } }
  end
  for _, w in ipairs(windows) do
    local t0 = M.seq.ticks_at(w[1], bpm)
    local t1 = M.seq.ticks_at(w[2], bpm)
    if w[2] >= SL then t1 = L end -- the last window closes the song
    -- offs first (a retrigger on the same tick wants its voice back);
    -- the song-closing window includes off == L (notes held to the end)
    for key, h in pairs(s.held) do
      if h.off >= t0 and (h.off < t1 or (h.off == t1 and t1 == L)) then
        pal.snd_off(h.v)
        s.held[key] = nil
      end
    end
    for ti, lane in ipairs(flat) do
      local tr = doc.tracks[ti]
      if not (tr and tr.mute) and slots[ti] then
        for _, n in ipairs(lane) do
          if n.tick >= t1 then break end
          if n.tick >= t0 then
            local v = pal.snd_on(slots[ti], n.pitch, n.vel)
            s.held[ti .. ":" .. n.tick .. ":" .. n.pitch] =
              { v = v, off = n.tick + n.dur }
          end
        end
      end
    end
  end
end

return M
