-- cm.trace — the segment ring recorder + verifier (D014, D019, D032).
-- One CTRC file is a replay, a frame-addressable debugging timeline, and
-- the determinism oracle.
--
-- CTRC container (cm.chunk), chunk order is meaningful:
--   HEAD v1  u32 keyframe_interval, s4 project, u32 n, n * s4 action names
--   SNAP v1  full cm.state snapshot (with code bundle) — state before frame 1
--   FRAM v1  one per sim frame, in order:
--              s4 input record (cm.input v1)
--              u32 buffer count, then per live named buffer sorted by name:
--                s4 name, u8 kind, s4 payload
--                kind 0 = delta1 vs previous frame (payload may be empty)
--                kind 1 = created/resized this frame (payload = full bytes)
--                kind 2 = freed this frame (payload empty)
--              u8 doc kind: 0 = unchanged, 1 = changed (then s4 canon bytes)
--   EVAL v1  console commands drained at the START of the next FRAM's sim
--            frame, before its input record applies (D022): u32 n,
--            n * s4 command. Verify re-executes them via cm.repl.exec at
--            the same point; replay-without-re-sim can ignore them (their
--            effects are inside the deltas)
--   KEYF v1  code-less snapshot of the state right after the preceding FRAM
--            (seek accelerator; the verifier cross-checks it)
--   EPOC v1  mid-recording hot reload: u32 n, n * (s4 name, s4 path,
--            s4 source) — changed files only, applied in order on replay
--   TAIL v1  u32 total frames (clean-end marker)
--
-- The ring IS the recorder (D032): every live session keeps the last
-- M.ring.seconds of play as a ring of segments — a segment is a code-less
-- keyframe (captured from the delta mirrors = state after the previous
-- segment's last frame), a reference snapshot of the loaded bundle, and
-- the encoded EVAL/FRAM/EPOC chunk bytes, eagerly closed at M.ring.kf
-- frames. Whole segments are evicted once the rest still covers the
-- window. On top of the ring:
--   * record_start pins segments against eviction; record_stop writes
--     HEAD + SNAP (first pinned keyframe + its bundle) + chunks with KEYF
--     at the boundaries + TAIL — same bytes the pre-D032 linear recorder
--     produced for the same session.
--   * ring_export writes whatever the ring still holds the same way
--     ("save what just happened").
--   * ring_state_at(f) decodes any retained frame without executing game
--     code: nearest keyframe + forward delta walk.
--   * rewind(f) writes that state back into the live buffers/doc, restores
--     the bundle as of f if it differs, truncates the ring after f. The
--     caller re-runs game.init() (same contract as every restore). Do NOT
--     call rewind from the console while the sim runs — the eval would be
--     recorded into the very timeline it rewrites; the scrubber calls it
--     between frames, and the error pause drains evals unrecorded.
--
-- Recording mirrors every named buffer into an anonymous twin to delta
-- against; that doubles state memory (fine for 2D sims). The recorder is
-- an observer: its bookkeeping lives on M (survives trace.lua's own
-- reload) and in anonymous buffers, never in named buffers or the doc
-- tree, so recording does not perturb the sim — and ring knobs never
-- enter traces. record_frame watches the cm.sim frame counter: a
-- non-monotonic step means an out-of-band restore happened and the ring
-- resets (an active pin is flushed first, valid up to its last frame).

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local repl = cm.require("cm.repl")

local pack, unpack = string.pack, string.unpack

-- feel knobs (console-tunable; read live). seconds = retained window,
-- kf = frames per segment = keyframe cadence of exported traces
M.ring = M.ring or { seconds = 30, kf = 60 }

-- M._R = ring session { project, segs, next_id, prev, prev_doc, last_frame }
-- M._rec = active pin { path, project, kf, from_id }

local function sorted_buf_list()
  local list = {}
  for _, b in ipairs(pal.buf_list()) do -- editor-domain (ed.*) buffers are
    if state.sim_buffer(b.name) then -- never traced (D050; see cm.state)
      list[#list + 1] = b
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function mirror_of(view, size)
  local m = pal.buf(nil, size)
  m:copy(0, view, 0, size)
  return m
end

local function ring_kf()
  return math.max(1, math.floor(M.ring.kf or 60))
end

-- ---- the segment ring ----

-- keyframe = the mirrors' contents = state after the last recorded frame
local function capture_keyframe(R)
  local names = {}
  for name in pairs(R.prev) do names[#names + 1] = name end
  table.sort(names)
  local bufs = {}
  for i, name in ipairs(names) do
    local p = R.prev[name]
    bufs[i] = { name = name, bytes = p.mirror:str(0, p.size) }
  end
  return bufs, R.prev_doc
end

local function open_segment(R, first)
  local bufs, doct = capture_keyframe(R)
  local seg = { id = R.next_id, first = first, kf_bufs = bufs,
                kf_doct = doct, bundle = cm.modules(), chunks = {},
                frames = 0, bytes = 0 }
  R.next_id = R.next_id + 1
  R.segs[#R.segs + 1] = seg
  return seg
end

local function seg_append(seg, tag, payload)
  seg.chunks[#seg.chunks + 1] = { tag = tag, payload = payload }
  seg.bytes = seg.bytes + #payload
end

-- drop whole oldest segments while what remains still covers the window
-- (pinned segments are never dropped)
local function evict(R)
  local want = math.max(1, math.floor((M.ring.seconds or 30) * 60))
  local total = 0
  for _, s in ipairs(R.segs) do total = total + s.frames end
  while #R.segs > 1 do
    local s = R.segs[1]
    if M._rec and s.id >= M._rec.from_id then break end
    if total - s.frames < want then break end
    total = total - s.frames
    table.remove(R.segs, 1)
  end
end

-- (re)initialize the mirrors from live state and open a fresh segment
local function ring_init(R)
  R.segs = {}
  R.prev = {}
  for _, b in ipairs(sorted_buf_list()) do
    R.prev[b.name] = { mirror = mirror_of(pal.buf(b.name, b.size), b.size),
                       size = b.size }
  end
  R.prev_doc = state.doc_bytes()
  R.last_frame = state.frame()
  open_segment(R, R.last_frame + 1)
end

function M.ring_start(opts)
  local R = { project = (opts and opts.project) or "", next_id = 1 }
  ring_init(R)
  M._R = R
end

-- out-of-band restore: history no longer connects to the present
function M.ring_reset()
  local R = M._R
  if not R then return end
  if M._rec then
    pal.log("[trace] recording stopped by ring reset")
    M.record_stop()
  end
  ring_init(R)
end

function M.ring_range()
  local R = M._R
  if not R or #R.segs == 0 then return nil end
  local sn = R.segs[#R.segs]
  local newest = sn.frames > 0 and (sn.first + sn.frames - 1) or (sn.first - 1)
  return R.segs[1].first - 1, newest
end

function M.ring_stats()
  local R = M._R
  if not R then return nil end
  local frames, bytes, kfbytes = 0, 0, 0
  for _, s in ipairs(R.segs) do
    frames = frames + s.frames
    bytes = bytes + s.bytes
    for _, b in ipairs(s.kf_bufs) do kfbytes = kfbytes + #b.bytes end
  end
  local lo, hi = M.ring_range()
  return { segs = #R.segs, frames = frames, chunk_bytes = bytes,
           keyframe_bytes = kfbytes, oldest = lo, newest = hi,
           pinned = M._rec ~= nil }
end

-- ---- recording ----

function M.recording()
  return M._rec ~= nil
end

-- pin segments against eviction from here on; the trace file is written
-- at record_stop (pinned long sessions grow memory — D032 revisit)
function M.record_start(path, opts)
  if M._rec then error("already recording", 2) end
  local R = M._R or error("ring not started", 2)
  local seg = R.segs[#R.segs]
  if seg.frames > 0 or #seg.chunks > 0 then
    seg = open_segment(R, R.last_frame + 1) -- recordings start on a keyframe
  end
  M._rec = { path = path, project = (opts and opts.project) or "",
             kf = ring_kf(), from_id = seg.id }
  pal.log("[trace] recording -> " .. path)
end

-- called after each sim step (post-advance, pre-draw) with that step's
-- input record and the console commands drained at its start (or nil)
function M.record_frame(input_record, evals)
  local R = M._R
  if not R then return end
  local f = state.frame()
  if f ~= R.last_frame + 1 then
    pal.log(("[trace] sim frame %d after %d: out-of-band restore, ring reset")
            :format(f, R.last_frame))
    M.ring_reset() -- reseeds from live (post-frame) state; resumes next frame
    return
  end
  local seg = R.segs[#R.segs]
  if evals and #evals > 0 then
    local ep = { pack("<I4", #evals) }
    for _, cmd in ipairs(evals) do ep[#ep + 1] = pack("<s4", cmd) end
    seg_append(seg, "EVAL", table.concat(ep))
  end
  local recs = {}
  local seen = {}
  for _, b in ipairs(sorted_buf_list()) do
    seen[b.name] = true
    local cur = pal.buf(b.name, b.size)
    local p = R.prev[b.name]
    if p and p.size == b.size then
      recs[#recs + 1] = { name = b.name, kind = 0,
                          payload = pal.buf_delta1(p.mirror, cur) }
      p.mirror:copy(0, cur, 0, b.size)
    else
      recs[#recs + 1] = { name = b.name, kind = 1,
                          payload = cur:str(0, b.size) }
      R.prev[b.name] = { mirror = mirror_of(cur, b.size), size = b.size }
    end
  end
  local freed = {}
  for name in pairs(R.prev) do
    if not seen[name] then freed[#freed + 1] = name end
  end
  table.sort(freed)
  for _, name in ipairs(freed) do
    recs[#recs + 1] = { name = name, kind = 2, payload = "" }
    R.prev[name] = nil
  end
  table.sort(recs, function(a, b) return a.name < b.name end)

  local parts = { pack("<s4", input_record), pack("<I4", #recs) }
  for _, r in ipairs(recs) do
    parts[#parts + 1] = pack("<s4I1s4", r.name, r.kind, r.payload)
  end
  local doc = state.doc_bytes()
  if doc == R.prev_doc then
    parts[#parts + 1] = "\0"
  else
    parts[#parts + 1] = "\1" .. pack("<s4", doc)
    R.prev_doc = doc
  end
  seg_append(seg, "FRAM", table.concat(parts))
  seg.frames = seg.frames + 1
  R.last_frame = f

  if seg.frames >= ring_kf() then
    open_segment(R, f + 1) -- eager close: its keyframe = state after f
    evict(R)
  end
end

-- called when hot reload swapped modules mid-session
function M.on_code_change(changed_names)
  local R = M._R
  if not R or #changed_names == 0 then return end
  local mods = {}
  for _, m in ipairs(cm.modules()) do mods[m.name] = m end
  local names = {}
  for _, n in ipairs(changed_names) do names[#names + 1] = n end
  table.sort(names)
  local parts = { pack("<I4", #names) }
  for _, n in ipairs(names) do
    local m = mods[n] or error("epoch for unknown module " .. n)
    parts[#parts + 1] = pack("<s4s4s4", m.name, m.path, m.source)
  end
  seg_append(R.segs[#R.segs], "EPOC", table.concat(parts))
  pal.log("[trace] code epoch: " .. table.concat(names, ", "))
end

-- serialize segments first_i.. as a CTRC blob and write it
local function write_trace(path, project, kf, first_i)
  local R = M._R
  local w = chunk.writer("CTRC")
  local names = input.actions()
  local head = { pack("<I4s4I4", kf, project, #names) }
  for _, n in ipairs(names) do head[#head + 1] = pack("<s4", n) end
  w.chunk("HEAD", 1, table.concat(head))
  local s1 = R.segs[first_i]
  w.chunk("SNAP", 1, state.encode_snapshot(s1.kf_bufs, s1.kf_doct, s1.bundle))
  local frames = 0
  for i = first_i, #R.segs do
    local s = R.segs[i]
    if i > first_i then
      w.chunk("KEYF", 1, state.encode_snapshot(s.kf_bufs, s.kf_doct))
    end
    for _, c in ipairs(s.chunks) do w.chunk(c.tag, 1, c.payload) end
    frames = frames + s.frames
  end
  w.chunk("TAIL", 1, pack("<I4", frames))
  local blob = w.result()
  local ok = pal.write_file(path, blob)
  pal.log(("[trace] wrote %s: %d frames, %d bytes%s")
          :format(path, frames, #blob, ok and "" or " (WRITE FAILED)"))
  return ok, frames
end

function M.record_stop()
  local rec = M._rec
  if not rec then return end
  local R = M._R
  local first_i
  for i, s in ipairs(R.segs) do
    if s.id >= rec.from_id then first_i = i break end
  end
  write_trace(rec.path, rec.project, rec.kf, first_i)
  M._rec = nil
  evict(R) -- pins released
end

-- "save what just happened": everything the ring still holds
function M.ring_export(path)
  local R = M._R
  if not R or #R.segs == 0 then error("ring empty", 2) end
  return write_trace(path, R.project, ring_kf(), 1)
end

-- load a .ctrace as the ring (replay playback, M5): the live ring is
-- REPLACED by the trace's frames and live state+code restore to the
-- trace's SNAP. The caller must freeze the sim before the next
-- record_frame and re-run game.init (cm.scrub does both, then scrubs/
-- plays); leaving adopts the trace's timeline via rewind, which rebases
-- the mirrors — until then they are deliberately stale. EVAL effects are
-- already inside the deltas; EPOC code is folded into each segment's
-- bundle so rewind restores the right code at any frame.
function M.ring_load(path)
  local blob, err = pal.read_file(path)
  if not blob then error("can't read trace " .. path .. ": " .. err, 0) end
  local chunks = chunk.read(blob, "CTRC")
  if M._rec then
    pal.log("[trace] recording stopped by replay load")
    M.record_stop()
  end

  local segs, cur, snap_blob, f0
  local frames = 0
  local bundle, border -- working file map + insertion order
  local function bundle_list()
    local out = {}
    for i, n in ipairs(border) do out[i] = bundle[n] end
    return out
  end
  for _, c in ipairs(chunks) do
    if c.tag == "SNAP" and c.version == 1 and not snap_blob then
      snap_blob = c.payload
      local s = state.parse_snapshot(c.payload)
      if not s.code then error("trace SNAP has no code bundle", 0) end
      bundle, border = {}, {}
      for _, fl in ipairs(s.code) do
        bundle[fl.name] = fl
        border[#border + 1] = fl.name
      end
      for _, b in ipairs(s.bufs) do
        if b.name == "cm.sim" then f0 = string.unpack("<i8", b.bytes) end
      end
      f0 = f0 or 0
      cur = { id = 1, first = f0 + 1, kf_bufs = s.bufs, kf_doct = s.doct,
              bundle = bundle_list(), chunks = {}, frames = 0, bytes = 0 }
      segs = { cur }
    elseif not cur then -- HEAD (and anything else) before SNAP
    elseif c.tag == "FRAM" and c.version == 1 then
      seg_append(cur, "FRAM", c.payload)
      cur.frames = cur.frames + 1
      frames = frames + 1
    elseif c.tag == "EVAL" and c.version == 1 then
      seg_append(cur, "EVAL", c.payload)
    elseif c.tag == "EPOC" and c.version == 1 then
      seg_append(cur, "EPOC", c.payload)
      local n, pos = unpack("<I4", c.payload)
      for _ = 1, n do
        local name, fpath, source
        name, fpath, source, pos = unpack("<s4s4s4", c.payload, pos)
        if not bundle[name] then border[#border + 1] = name end
        bundle[name] = { name = name, path = fpath, source = source }
      end
    elseif c.tag == "KEYF" and c.version == 1 then
      local s = state.parse_snapshot(c.payload)
      cur = { id = #segs + 1, first = f0 + 1 + frames, kf_bufs = s.bufs,
              kf_doct = s.doct, bundle = bundle_list(), chunks = {},
              frames = 0, bytes = 0 }
      segs[#segs + 1] = cur
    elseif c.tag == "TAIL" and c.version == 1 then
      local n = unpack("<I4", c.payload)
      if n ~= frames then
        pal.log(("[trace] ring_load: TAIL says %d frames, file has %d")
                :format(n, frames))
      end
    end
  end
  if not snap_blob then error("trace has no SNAP chunk", 0) end

  state.restore(snap_blob) -- buffers/doc/counter + bundle code
  local R = M._R or { project = "" }
  R.segs = segs
  R.next_id = #segs + 1
  R.last_frame = f0 + frames -- the loaded newest; exits rewind to rebase
  R.prev, R.prev_doc = {}, nil
  M._R = R
  pal.log(("[trace] replay loaded: %s (%d frames)"):format(path, frames))
  return f0, f0 + frames
end

-- ---- scrub access (no game code runs) ----

local function decode_fram(p)
  local irec, pos = unpack("<s4", p)
  local nbufs
  nbufs, pos = unpack("<I4", p, pos)
  local recs = {}
  for i = 1, nbufs do
    local name, kind, payload
    name, kind, payload, pos = unpack("<s4I1s4", p, pos)
    recs[i] = { name = name, kind = kind, payload = payload }
  end
  local doc
  if p:byte(pos) == 1 then doc = unpack("<s4", p, pos + 1) end
  return irec, recs, doc
end

-- the segment whose FRAMs contain frame f (so its input record and EPOC
-- positions are visible); the oldest keyframe state (f = segs[1].first-1)
-- resolves to segs[1] with zero frames to walk
local function seg_containing(R, f)
  for i = #R.segs, 1, -1 do
    if R.segs[i].first <= f then return R.segs[i], i end
  end
  return R.segs[1], 1
end

-- decoded copy of the state after frame f: { frame, bufs = name -> bytes,
-- doct, input = that frame's input record (nil at the oldest keyframe) }
function M.ring_state_at(f)
  local R = M._R
  local lo, hi = M.ring_range()
  if not lo or f < lo or f > hi then
    error(("frame %s outside ring [%s..%s]")
          :format(tostring(f), tostring(lo), tostring(hi)), 2)
  end
  local seg = seg_containing(R, f)
  local scratch = {} -- name -> anon view (GC-owned)
  local sizes = {}
  for _, b in ipairs(seg.kf_bufs) do
    local v = pal.buf(nil, #b.bytes)
    v:setstr(0, b.bytes)
    scratch[b.name], sizes[b.name] = v, #b.bytes
  end
  local doct = seg.kf_doct
  local irec
  local need, done = f - (seg.first - 1), 0
  for _, c in ipairs(seg.chunks) do
    if done >= need then break end
    if c.tag == "FRAM" then
      local recs, doc
      irec, recs, doc = decode_fram(c.payload)
      for _, r in ipairs(recs) do
        if r.kind == 0 then
          if #r.payload > 0 then
            local v = scratch[r.name]
              or error("ring delta for unknown buffer " .. r.name, 0)
            pal.buf_apply_delta1(v, r.payload)
          end
        elseif r.kind == 1 then
          local v = pal.buf(nil, #r.payload)
          v:setstr(0, r.payload)
          scratch[r.name], sizes[r.name] = v, #r.payload
        elseif r.kind == 2 then
          scratch[r.name], sizes[r.name] = nil, nil
        end
      end
      if doc then doct = doc end
      done = done + 1
    end
  end
  local bufs = {}
  for name, v in pairs(scratch) do bufs[name] = v:str(0, sizes[name]) end
  return { frame = f, bufs = bufs, doct = doct, input = irec }
end

-- ---- rewind (D032) ----

-- restore live state to "after frame f" and truncate the ring there; the
-- caller re-runs game.init() afterwards (the restore contract)
function M.rewind(f)
  local R = M._R or error("ring not started", 2)
  if M._rec then
    pal.log("[trace] recording stopped by rewind")
    M.record_stop()
  end
  local st = M.ring_state_at(f) -- validates the range
  local seg, si = seg_containing(R, f)

  -- code as of frame f: the segment bundle + EPOCs that landed before it
  local files, order = {}, {}
  for _, m in ipairs(seg.bundle) do
    files[m.name] = { name = m.name, path = m.path, source = m.source }
    order[#order + 1] = m.name
  end
  local need, done, cut = f - (seg.first - 1), 0, 0
  for ci, c in ipairs(seg.chunks) do
    if c.tag == "FRAM" then
      done = done + 1
      if done == need then cut = ci break end
    elseif c.tag == "EPOC" and done < need then
      local n, pos = unpack("<I4", c.payload)
      for _ = 1, n do
        local name, fpath, source
        name, fpath, source, pos = unpack("<s4s4s4", c.payload, pos)
        if not files[name] then order[#order + 1] = name end
        files[name] = { name = name, path = fpath, source = source }
      end
    end
  end

  -- only re-execute the bundle when it differs from the loaded code:
  -- the common rewind (no reload since f) must not enter bundle mode
  local cur = {}
  for _, m in ipairs(cm.modules()) do cur[m.name] = m.source end
  local list, diff = {}, false
  for _, name in ipairs(order) do
    list[#list + 1] = files[name]
    if cur[name] ~= files[name].source then diff = true end
  end

  state.restore_tables(st.bufs, st.doct)
  if diff then cm.restore_bundle(list) end

  -- truncate the ring after f and rebase the mirrors there
  for i = #R.segs, si + 1, -1 do R.segs[i] = nil end
  for i = #seg.chunks, cut + 1, -1 do seg.chunks[i] = nil end
  seg.frames = need
  local bytes = 0
  for _, c in ipairs(seg.chunks) do bytes = bytes + #c.payload end
  seg.bytes = bytes
  R.prev = {}
  for name, b in pairs(st.bufs) do
    local m = pal.buf(nil, #b)
    m:setstr(0, b)
    R.prev[name] = { mirror = m, size = #b }
  end
  R.prev_doc = st.doct
  R.last_frame = f
  if seg.frames >= ring_kf() then open_segment(R, f + 1) end
  pal.log(("[trace] rewound to frame %d"):format(f))
end

-- ---- verify (the golden runner) ----

local function hex(s)
  return (s:gsub(".", function(c) return ("%02x "):format(c:byte()) end))
end

local function count_runs(delta)
  local n, pos = 0, 1
  while pos + 8 <= #delta + 1 do
    local _, len = unpack("<I4I4", delta, pos)
    n = n + 1
    pos = pos + 8 + len
  end
  return n
end

-- report the first divergence: d = delta1(actual, expected) ~= ""
local function report_divergence(frame, name, d, actual_view, expect_view)
  local off, len = unpack("<I4I4", d)
  local n = math.min(len, 16)
  pal.log(("[trace] DIVERGENCE at frame %d, buffer '%s' (%d byte run%s):")
          :format(frame, name, count_runs(d), count_runs(d) == 1 and "" or "s"))
  pal.log(("  first diff at byte %d (%d bytes): expected %s| got %s")
          :format(off, len, hex(expect_view:str(off, n)),
                  hex(actual_view:str(off, n))))
end

-- replay input records against a fresh restore of the starting snapshot and
-- byte-compare every frame against the recorded deltas. game is the running
-- entry module (its table survives the bundle restore). Returns ok, frames.
function M.verify(path, game)
  local blob, err = pal.read_file(path)
  if not blob then error("can't read trace " .. path .. ": " .. err, 0) end
  local chunks = chunk.read(blob, "CTRC")

  local snap
  for _, c in ipairs(chunks) do
    if c.tag == "SNAP" and c.version == 1 then snap = c.payload break end
  end
  if not snap then error("trace has no SNAP chunk", 0) end

  state.restore(snap)
  game.init() -- same reload-idempotence contract as hot reload

  -- expected-state mirrors, driven by the recorded deltas
  local mirrors = {}
  for _, b in ipairs(state.parse_snapshot(snap).bufs) do
    local m = pal.buf(nil, #b.bytes)
    m:setstr(0, b.bytes)
    mirrors[b.name] = { mirror = m, size = #b.bytes }
  end
  local expect_doc = state.parse_snapshot(snap).doct

  local frame = 0
  local tail_frames
  local pending_evals = {}

  for _, c in ipairs(chunks) do
    if c.tag == "EVAL" and c.version == 1 then
      local n, pos = unpack("<I4", c.payload)
      for _ = 1, n do
        local cmd
        cmd, pos = unpack("<s4", c.payload, pos)
        pending_evals[#pending_evals + 1] = cmd
      end
    elseif c.tag == "FRAM" and c.version == 1 then
      frame = frame + 1
      -- recorded console evals ran at the start of this sim frame (D022)
      if #pending_evals > 0 then
        for _, cmd in ipairs(pending_evals) do repl.exec(cmd) end
        pending_evals = {}
      end
      local p = c.payload
      local irec, pos = unpack("<s4", p)
      input.apply(irec)
      game.step()
      state.advance_frame()

      -- decode recorded per-buffer records, update expected mirrors
      local nbufs
      nbufs, pos = unpack("<I4", p, pos)
      local recorded = {}
      for _ = 1, nbufs do
        local name, kind, payload
        name, kind, payload, pos = unpack("<s4I1s4", p, pos)
        recorded[#recorded + 1] = { name = name, kind = kind, payload = payload }
      end
      local dockind = p:byte(pos)
      pos = pos + 1
      if dockind == 1 then
        expect_doc = unpack("<s4", p, pos)
      end

      local live = {}
      for _, b in ipairs(sorted_buf_list()) do live[b.name] = b.size end

      for _, r in ipairs(recorded) do
        local m = mirrors[r.name]
        if r.kind == 0 then
          if not m then
            pal.log(("[trace] frame %d: delta for unknown buffer '%s'")
                    :format(frame, r.name))
            return false, frame
          end
          if #r.payload > 0 then pal.buf_apply_delta1(m.mirror, r.payload) end
        elseif r.kind == 1 then
          local nm = pal.buf(nil, #r.payload)
          nm:setstr(0, r.payload)
          mirrors[r.name] = { mirror = nm, size = #r.payload }
          m = mirrors[r.name]
        elseif r.kind == 2 then
          mirrors[r.name] = nil
          if live[r.name] then
            pal.log(("[trace] frame %d: buffer '%s' should be freed but is live")
                    :format(frame, r.name))
            return false, frame
          end
        end
        if r.kind ~= 2 then
          if live[r.name] ~= mirrors[r.name].size then
            pal.log(("[trace] frame %d: buffer '%s' size %s, recorded %d")
                    :format(frame, r.name, tostring(live[r.name]),
                            mirrors[r.name].size))
            return false, frame
          end
          local actual = pal.buf(r.name, live[r.name])
          local d = pal.buf_delta1(actual, mirrors[r.name].mirror)
          if d ~= "" then
            report_divergence(frame, r.name, d, actual, mirrors[r.name].mirror)
            return false, frame
          end
        end
      end
      -- buffers the sim created that the recording never had
      local known = {}
      for _, r in ipairs(recorded) do known[r.name] = true end
      for name in pairs(live) do
        if not known[name] then
          pal.log(("[trace] frame %d: unexpected new buffer '%s'")
                  :format(frame, name))
          return false, frame
        end
      end

      local doc = state.doc_bytes()
      if doc ~= expect_doc then
        pal.log(("[trace] DIVERGENCE at frame %d in the doc tree " ..
                 "(%d vs %d bytes)"):format(frame, #doc, #expect_doc))
        return false, frame
      end
    elseif c.tag == "KEYF" and c.version == 1 then
      -- cross-check the seek accelerator against live state
      local ks = state.parse_snapshot(c.payload)
      for _, b in ipairs(ks.bufs) do
        local cur = pal.buf(b.name, #b.bytes)
        if cur:str(0, #b.bytes) ~= b.bytes then
          pal.log(("[trace] keyframe mismatch at frame %d, buffer '%s'")
                  :format(frame, b.name))
          return false, frame
        end
      end
      if ks.doct ~= state.doc_bytes() then
        pal.log(("[trace] keyframe doc mismatch at frame %d"):format(frame))
        return false, frame
      end
    elseif c.tag == "EPOC" and c.version == 1 then
      local files = {}
      local n, pos = unpack("<I4", c.payload)
      for _ = 1, n do
        local name, fpath, source
        name, fpath, source, pos = unpack("<s4s4s4", c.payload, pos)
        files[#files + 1] = { name = name, path = fpath, source = source }
      end
      cm.restore_bundle(files)
    elseif c.tag == "TAIL" and c.version == 1 then
      tail_frames = unpack("<I4", c.payload)
    end
  end

  if tail_frames and tail_frames ~= frame then
    pal.log(("[trace] frame count mismatch: TAIL says %d, replayed %d")
            :format(tail_frames, frame))
    return false, frame
  end
  pal.log(("[trace] verify PASS: %d frames (%s)"):format(frame, path))
  return true, frame
end

return M
