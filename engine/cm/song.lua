-- cm.song — the song asset codec (R9d, AUDIO.md §4.2): the CSNG chunk
-- container. Time is integer ticks at PPQ 96 (1 beat = 96 ticks);
-- tempo is BPM; beats/bars are derived views, steps are presentation.
-- Pure encode/decode + canonical bytes + the FLATTEN (arrangement ->
-- one absolute-tick note list per track — playback never walks song
-- structure [wstudio]).
--
--   HEAD v1: <u16 bpm> <u8 beats_per_bar> <u8 grid> <u32 loop0> <u32 loop1>
--   TRKS v1: <u8 n> n x { <s1 name> <s1 ins path> <u8 gain> <i8 pan>
--                         <u8 mute> }
--   PATN v1 (xN): <u16 id> <u32 len ticks> <u16 nnotes> nnotes x
--                 { <u32 tick> <u32 dur> <u8 pitch> <u8 vel> }
--   ARRG v1: <u16 nclips> nclips x { <u8 track> <u32 tick> <u32 len>
--                                    <u16 pattern id> }
--
-- doc = { bpm, beats_per_bar, grid, loop0, loop1,
--         tracks = { {name, ins, gain, pan, mute} },
--         patterns = { [id] = {id, len, notes = {{tick,dur,pitch,vel}}} },
--         clips = { {track, tick, len, pattern} } }
--
-- A clip longer than its pattern LOOPS the content to fill; editing a
-- placed clip's notes copies-on-write in the editor (the codec itself
-- is dumb bytes).

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")

M.MAGIC = "CSNG"
M.PPQ = 96

local pack, unpack = string.pack, string.unpack

function M.fresh()
  return {
    bpm = 120, beats_per_bar = 4, grid = 8, loop0 = 0,
    loop1 = 16 * M.PPQ * 4, -- 16 bars of 4/4
    tracks = { { name = "track 1", ins = "", gain = 128, pan = 0,
                 mute = false } },
    patterns = { [1] = { id = 1, len = 4 * M.PPQ * 4, notes = {} } },
    clips = {},
  }
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
                          doc.loop0 or 0, doc.loop1 or 0))
  local t = { pack("<I1", #(doc.tracks or {})) }
  for _, tr in ipairs(doc.tracks or {}) do
    t[#t + 1] = pack("<s1s1I1i1I1", tr.name or "", tr.ins or "",
                     tr.gain or 128, tr.pan or 0, tr.mute and 1 or 0)
  end
  w.chunk("TRKS", 1, table.concat(t))
  for _, id in ipairs(sorted_pattern_ids(doc)) do
    local pt = doc.patterns[id]
    -- canonical: notes sorted by (tick, pitch)
    local notes = {}
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
  -- canonical: clips sorted by (track, tick)
  local clips = {}
  for _, c in ipairs(doc.clips or {}) do clips[#clips + 1] = c end
  table.sort(clips, function(x, y)
    if x.track ~= y.track then return x.track < y.track end
    return x.tick < y.tick
  end)
  local b = { pack("<I2", #clips) }
  for _, c in ipairs(clips) do
    b[#b + 1] = pack("<I1I4I4I2", c.track, c.tick, c.len, c.pattern)
  end
  w.chunk("ARRG", 1, table.concat(b))
  return w.result()
end

function M.decode(bytes)
  local chunks = chunk.read(bytes, M.MAGIC)
  local doc = { tracks = {}, patterns = {}, clips = {} }
  for _, c in ipairs(chunks) do
    if c.tag == "HEAD" and c.version == 1 then
      doc.bpm, doc.beats_per_bar, doc.grid, doc.loop0, doc.loop1 =
        unpack("<I2I1I1I4I4", c.payload)
    elseif c.tag == "TRKS" and c.version == 1 then
      local n, pos = unpack("<I1", c.payload)
      for _ = 1, n do
        local name, ins, gain, pan, mute
        name, ins, gain, pan, mute, pos = unpack("<s1s1I1i1I1", c.payload, pos)
        doc.tracks[#doc.tracks + 1] = { name = name, ins = ins,
                                        gain = gain, pan = pan,
                                        mute = mute == 1 }
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
    elseif c.tag == "ARRG" and c.version == 1 then
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
  return doc
end

-- the flatten: arrangement -> per-track absolute-tick note lists,
-- sorted by tick. Clips loop their pattern to fill their length; notes
-- clip at the clip edge (a note starting inside plays, held past the
-- edge releases there). Pure — the sequencer walks this, never the doc.
function M.flatten(doc)
  local out = {}
  for ti = 1, #(doc.tracks or {}) do out[ti] = {} end
  for _, c in ipairs(doc.clips or {}) do
    local pt = doc.patterns[c.pattern]
    local lane = out[c.track + 1]
    if pt and lane and pt.len and pt.len > 0 then
      local reps = (c.len + pt.len - 1) // pt.len
      for rep = 0, reps - 1 do
        local base = c.tick + rep * pt.len
        for _, n in ipairs(pt.notes) do
          local at = base + n.tick
          if n.tick < pt.len and at < c.tick + c.len then
            local dur = math.min(n.dur, c.tick + c.len - at)
            lane[#lane + 1] = { tick = at, dur = dur, pitch = n.pitch,
                                vel = n.vel }
          end
        end
      end
    end
  end
  for _, lane in ipairs(out) do
    table.sort(lane, function(x, y)
      if x.tick ~= y.tick then return x.tick < y.tick end
      return x.pitch < y.pitch
    end)
  end
  return out
end

-- total ticks (the arrangement's extent; loop1 when set wins)
function M.length(doc)
  local n = doc.loop1 or 0
  for _, c in ipairs(doc.clips or {}) do
    if c.tick + c.len > n then n = c.tick + c.len end
  end
  return n
end

return M
