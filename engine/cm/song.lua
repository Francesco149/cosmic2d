-- cm.song — the song asset codec (R9d, AUDIO.md §4.2): the CSNG chunk
-- container. Time is integer ticks at PPQ 96 (1 beat = 96 ticks);
-- tempo is BPM; beats/bars are derived views.
--
-- The model (round 7 — the human): an ARRANGEMENT of clips. A clip
-- places a pattern on a track at a bar, with a length; **resizing a
-- clip longer than its pattern LOOPS the pattern to fill** (the "auto
-- loop"). Clicking a clip drills into the roll to edit ITS pattern.
-- Stamping a NEW clip makes a FRESH pattern (nothing shares by
-- accident), but clips MAY deliberately SHARE a pattern (round 8 — the
-- human: place the same pattern multiple times, edit it once, every
-- placement follows; ctrl+drag / ctrl+press in the arrangement).
--
--   HEAD v1: <u16 bpm> <u8 beats_per_bar> <u8 grid> <u32 loop0> <u32 loop1>
--   TRKS v1: <u8 n> n x { <s1 name> <s1 ins> <u8 gain> <i8 pan> <u8 mute> }
--            (v2 carried a per-track pat — round 6; migrated to clips)
--   PATN v1 (xN): <u16 id> <u32 len> <u16 nnotes>
--                 nnotes x { <u32 tick> <u32 dur> <u8 pitch> <u8 vel> }
--   ARRG v1: <u16 nclips> nclips x { <u8 track> <u32 tick> <u32 len>
--                                    <u16 pattern id> }
--
-- doc = { bpm, beats_per_bar, grid, loop0, loop1,
--         tracks = { {name, ins, gain, pan, mute} },
--         patterns = { [id] = {id, len, notes={{tick,dur,pitch,vel}}} },
--         clips = { {track, tick, len, pattern} } }

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")

M.MAGIC = "CSNG"
M.PPQ = 96
local BAR = 96 * 4
local DEF_LOOP = 4 * BAR -- 4 bars

local pack, unpack = string.pack, string.unpack

-- produce a canonical clip-arrangement doc from any input: migrate a
-- round-6 per-track doc (tracks have `pat`, no clips) into clips, give
-- an empty doc a starter clip, and heal any clip pointing at a MISSING
-- pattern. Deliberate SHARING is allowed (round 8) — normalize no longer
-- splits shared patterns; stamping still makes a fresh pattern so nothing
-- shares by accident. Idempotent; preserves notes.
function M.normalize(doc)
  doc.patterns = doc.patterns or {}
  doc.tracks = doc.tracks or {}
  doc.clips = doc.clips or {}
  local maxid = 0
  for id in pairs(doc.patterns) do if id > maxid then maxid = id end end
  local function newid() maxid = maxid + 1; return maxid end

  -- migrate round-6 (track.pat, no clips) -> one clip per track
  if #doc.clips == 0 then
    for ti, tr in ipairs(doc.tracks) do
      if tr.pat and doc.patterns[tr.pat] then
        doc.clips[#doc.clips + 1] = {
          track = ti - 1, tick = 0, pattern = tr.pat,
          len = doc.patterns[tr.pat].len or DEF_LOOP }
      end
    end
  end
  for _, tr in ipairs(doc.tracks) do tr.pat = nil end

  -- a doc with tracks but nothing to edit gets a starter clip
  if #doc.clips == 0 and #doc.tracks > 0 then
    local pid = newid()
    doc.patterns[pid] = { id = pid, len = DEF_LOOP, notes = {} }
    doc.clips[1] = { track = 0, tick = 0, len = DEF_LOOP, pattern = pid }
  end

  -- heal clips that point at a missing pattern (create a fresh one);
  -- clips that share an EXISTING pattern are left linked (deliberate
  -- reuse — round 8)
  for _, c in ipairs(doc.clips) do
    if not doc.patterns[c.pattern] then
      local pid = newid()
      doc.patterns[pid] = { id = pid, len = c.len or DEF_LOOP, notes = {} }
      c.pattern = pid
    end
  end
  if not doc.loop1 or doc.loop1 <= 0 then doc.loop1 = DEF_LOOP end
  return doc
end

function M.fresh()
  return M.normalize({
    bpm = 120, beats_per_bar = 4, grid = 8, loop0 = 0, loop1 = DEF_LOOP,
    tracks = { { name = "track 1", ins = "", gain = 128, pan = 0,
                 mute = false } },
    patterns = { [1] = { id = 1, len = DEF_LOOP, notes = {} } },
    clips = { { track = 0, tick = 0, len = DEF_LOOP, pattern = 1 } },
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
    t[#t + 1] = pack("<s1s1I1i1I1", tr.name or "", tr.ins or "",
                     tr.gain or 128, tr.pan or 0, tr.mute and 1 or 0)
  end
  w.chunk("TRKS", 1, table.concat(t))
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
  local clips = {} -- canonical: sorted by (track, tick)
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
  return M.normalize(doc)
end

-- the flatten: arrangement -> per-track absolute-tick note lists. A clip
-- LOOPS its pattern to fill its length (the "auto loop"); notes clip at
-- the clip edge. Pure — the sequencer walks this, never the doc.
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

-- total song ticks (the arrangement extent; at least loop1, one bar)
function M.length(doc)
  local n = doc.loop1 or DEF_LOOP
  for _, c in ipairs(doc.clips or {}) do
    if c.tick + c.len > n then n = c.tick + c.len end
  end
  return math.max(BAR, n)
end

-- a pattern's length GROWS to fit its notes (whole bars, min one) but
-- never auto-shrinks (the human, round 6: clips loop it, so a short
-- pattern is fine). Editors call this after a note edit.
function M.fit_pattern(doc, pt)
  if not pt then return end
  local bar = M.PPQ * (doc.beats_per_bar or 4)
  local ext = pt.len or bar
  for _, n in ipairs(pt.notes) do
    if n.tick + n.dur > ext then ext = ((n.tick + n.dur + bar - 1) // bar) * bar end
  end
  pt.len = math.max(bar, ext)
end

return M
