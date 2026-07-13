-- cm.song — the song asset codec (R9d, AUDIO.md §4.2): the CSNG chunk
-- container. Time is integer ticks at PPQ 96 (1 beat = 96 ticks);
-- tempo is BPM; beats/bars are derived views.
--
-- The model (round 6 — the human, matching wstudio): **each track OWNS
-- one pattern** (its live loop). All tracks loop together over
-- `loop1` ticks. The roll edits the current track's pattern; there is
-- no separate arrangement/clip layer in the loop workflow (song mode
-- is a later growth — old ARRG chunks still read, and migrate).
--
--   HEAD v1: <u16 bpm> <u8 beats_per_bar> <u8 grid> <u32 loop0> <u32 loop1>
--   TRKS v2: <u8 n> n x { <s1 name> <s1 ins> <u8 gain> <i8 pan>
--                         <u8 mute> <u16 pat> }   (v1 had no pat)
--   PATN v1 (xN): <u16 id> <u32 len ticks> <u16 nnotes> nnotes x
--                 { <u32 tick> <u32 dur> <u8 pitch> <u8 vel> }
--   ARRG v1: legacy clips (read-tolerant; migrated to track.pat)
--
-- doc = { bpm, beats_per_bar, grid, loop0, loop1 (the loop length),
--         tracks = { {name, ins, gain, pan, mute, pat} },
--         patterns = { [id] = {id, len, notes = {{tick,dur,pitch,vel}}} } }
--
-- flatten -> one absolute-tick note list per track (the track's own
-- pattern; the sequencer loops it over loop1). Playback never walks
-- the doc [wstudio].

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")

M.MAGIC = "CSNG"
M.PPQ = 96
local DEF_LOOP = 4 * 96 * 4 -- 4 bars of 4/4

local pack, unpack = string.pack, string.unpack

-- ensure every track owns a valid pattern (creates or migrates from an
-- old clip on that track); ensure a sane loop length. Idempotent —
-- called after decode + by fresh; the editor calls it after adding a
-- track. Preserves existing notes.
function M.normalize(doc)
  doc.patterns = doc.patterns or {}
  doc.tracks = doc.tracks or {}
  local maxid = 0
  for id in pairs(doc.patterns) do if id > maxid then maxid = id end end
  for ti, tr in ipairs(doc.tracks) do
    if not tr.pat or not doc.patterns[tr.pat] then
      local pid
      for _, c in ipairs(doc.clips or {}) do -- migrate an old clip
        if c.track == ti - 1 and doc.patterns[c.pattern] then
          pid = c.pattern
          break
        end
      end
      if not pid then
        maxid = maxid + 1
        pid = maxid
        doc.patterns[pid] = { id = pid, len = doc.loop1 or DEF_LOOP,
                              notes = {} }
      end
      tr.pat = pid
    end
  end
  if not doc.loop1 or doc.loop1 <= 0 then doc.loop1 = DEF_LOOP end
  doc.clips = nil -- the loop model has no clips
  return doc
end

function M.fresh()
  return M.normalize({
    bpm = 120, beats_per_bar = 4, grid = 8, loop0 = 0, loop1 = DEF_LOOP,
    tracks = { { name = "track 1", ins = "", gain = 128, pan = 0,
                 mute = false, pat = 1 } },
    patterns = { [1] = { id = 1, len = DEF_LOOP, notes = {} } },
  })
end

local function sorted_pattern_ids(doc)
  local ids = {}
  for id in pairs(doc.patterns or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

function M.encode(doc)
  local w = chunk.writer(M.MAGIC)
  w.chunk("HEAD", 1, pack("<I2I1I1I4I4", doc.bpm or 120,
                          doc.beats_per_bar or 4, doc.grid or 8,
                          doc.loop0 or 0, doc.loop1 or DEF_LOOP))
  local t = { pack("<I1", #(doc.tracks or {})) }
  for _, tr in ipairs(doc.tracks or {}) do
    t[#t + 1] = pack("<s1s1I1i1I1I2", tr.name or "", tr.ins or "",
                     tr.gain or 128, tr.pan or 0, tr.mute and 1 or 0,
                     tr.pat or 1)
  end
  w.chunk("TRKS", 2, table.concat(t))
  for _, id in ipairs(sorted_pattern_ids(doc)) do
    local pt = doc.patterns[id]
    local notes = {} -- canonical: sorted by (tick, pitch)
    for _, n in ipairs(pt.notes or {}) do notes[#notes + 1] = n end
    table.sort(notes, function(x, y)
      if x.tick ~= y.tick then return x.tick < y.tick end
      return x.pitch < y.pitch
    end)
    local b = { pack("<I2I4I2", id, pt.len or 0, #notes) }
    for _, n in ipairs(notes) do
      b[#b + 1] = pack("<I4I4I1I1", n.tick, n.dur, n.pitch, n.vel or 100)
    end
    w.chunk("PATN", 1, table.concat(b))
  end
  return w.result()
end

function M.decode(bytes)
  local chunks = chunk.read(bytes, M.MAGIC)
  local doc = { tracks = {}, patterns = {}, clips = {} }
  for _, c in ipairs(chunks) do
    if c.tag == "HEAD" and c.version == 1 then
      doc.bpm, doc.beats_per_bar, doc.grid, doc.loop0, doc.loop1 =
        unpack("<I2I1I1I4I4", c.payload)
    elseif c.tag == "TRKS" and (c.version == 1 or c.version == 2) then
      local n, pos = unpack("<I1", c.payload)
      for _ = 1, n do
        local name, ins, gain, pan, mute, pat
        name, ins, gain, pan, mute, pos = unpack("<s1s1I1i1I1", c.payload, pos)
        if c.version == 2 then pat, pos = unpack("<I2", c.payload, pos) end
        doc.tracks[#doc.tracks + 1] = { name = name, ins = ins,
                                        gain = gain, pan = pan,
                                        mute = mute == 1, pat = pat }
      end
    elseif c.tag == "PATN" and c.version == 1 then
      local id, len, nn, pos = unpack("<I2I4I2", c.payload)
      local pt = { id = id, len = len, notes = {} }
      for _ = 1, nn do
        local tick, dur, pitch, vel
        tick, dur, pitch, vel, pos = unpack("<I4I4I1I1", c.payload, pos)
        pt.notes[#pt.notes + 1] = { tick = tick, dur = dur,
                                    pitch = pitch, vel = vel }
      end
      doc.patterns[id] = pt
    elseif c.tag == "ARRG" and c.version == 1 then -- legacy (migrated)
      local n, pos = unpack("<I2", c.payload)
      for _ = 1, n do
        local track, tick, len, pattern
        track, tick, len, pattern, pos = unpack("<I1I4I4I2", c.payload, pos)
        doc.clips[#doc.clips + 1] = { track = track, tick = tick,
                                      len = len, pattern = pattern }
      end
    end
  end
  if not doc.bpm then doc.bpm = 120 end
  return M.normalize(doc)
end

-- flatten -> per-track absolute-tick note lists (each track's own
-- pattern, sorted). The sequencer loops each over M.length(doc).
function M.flatten(doc)
  local out = {}
  for ti, tr in ipairs(doc.tracks or {}) do
    local pt = doc.patterns[tr.pat]
    local lane = {}
    if pt then
      for _, n in ipairs(pt.notes) do
        lane[#lane + 1] = { tick = n.tick, dur = n.dur, pitch = n.pitch,
                            vel = n.vel }
      end
      table.sort(lane, function(x, y)
        if x.tick ~= y.tick then return x.tick < y.tick end
        return x.pitch < y.pitch
      end)
    end
    out[ti] = lane
  end
  return out
end

-- the loop length in ticks (doc.loop1 is the high-water mark the editor
-- grows; floored at one bar, and never below live content).
function M.length(doc)
  local bar = M.PPQ * (doc.beats_per_bar or 4)
  local n = doc.loop1 or DEF_LOOP
  for _, tr in ipairs(doc.tracks or {}) do
    local pt = doc.patterns[tr.pat]
    for _, note in ipairs(pt and pt.notes or {}) do
      local e = note.tick + note.dur
      if e > n then n = ((e + bar - 1) // bar) * bar end
    end
  end
  return math.max(bar, n)
end

return M
