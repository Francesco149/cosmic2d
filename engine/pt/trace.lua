-- pt.trace — trace recorder + verifier (D014). One PTRC file is a replay,
-- a frame-addressable debugging timeline, and the determinism oracle.
--
-- PTRC container (pt.chunk), chunk order is meaningful:
--   HEAD v1  u32 keyframe_interval, s4 project, u32 n, n * s4 action names
--   SNAP v1  full pt.state snapshot (with code bundle) — state before frame 1
--   FRAM v1  one per sim frame, in order:
--              s4 input record (pt.input v1)
--              u32 buffer count, then per live named buffer sorted by name:
--                s4 name, u8 kind, s4 payload
--                kind 0 = delta1 vs previous frame (payload may be empty)
--                kind 1 = created/resized this frame (payload = full bytes)
--                kind 2 = freed this frame (payload empty)
--              u8 doc kind: 0 = unchanged, 1 = changed (then s4 canon bytes)
--   KEYF v1  code-less snapshot of the state right after the preceding FRAM
--            (seek accelerator; the verifier cross-checks it)
--   EPOC v1  mid-recording hot reload: u32 n, n * (s4 name, s4 path,
--            s4 source) — changed files only, applied in order on replay
--   TAIL v1  u32 total frames (clean-end marker)
--
-- Recording mirrors every named buffer into an anonymous twin to delta
-- against; that doubles state memory while recording (fine for 2D sims).
-- The recorder is an observer: its own bookkeeping lives in the Lua heap,
-- never in named buffers, so recording does not perturb the sim.

local M = select(2, ...) or {}
local chunk = pt.require("pt.chunk")
local state = pt.require("pt.state")
local input = pt.require("pt.input")

local pack, unpack = string.pack, string.unpack

local rec -- active recording session (nil when not recording)

local function sorted_buf_list()
  local list = pal.buf_list()
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

local function mirror_of(view, size)
  local m = pal.buf(nil, size)
  m:copy(0, view, 0, size)
  return m
end

-- ---- recording ----

function M.recording()
  return rec ~= nil
end

function M.record_start(path, opts)
  if rec then error("already recording", 2) end
  rec = {
    path = path,
    w = chunk.writer("PTRC"),
    kf = (opts and opts.keyframe) or 60,
    frames = 0,
    prev = {},
  }
  local names = input.actions()
  local head = { pack("<I4s4I4", rec.kf, (opts and opts.project) or "", #names) }
  for _, n in ipairs(names) do head[#head + 1] = pack("<s4", n) end
  rec.w.chunk("HEAD", 1, table.concat(head))
  rec.w.chunk("SNAP", 1, state.snapshot())
  for _, b in ipairs(sorted_buf_list()) do
    rec.prev[b.name] = { mirror = mirror_of(pal.buf(b.name, b.size), b.size),
                         size = b.size }
  end
  rec.prev_doc = state.doc_bytes()
  pal.log("[trace] recording -> " .. path)
end

-- called after each sim step (post-advance, pre-draw) with that step's
-- input record
function M.record_frame(input_record)
  if not rec then return end
  local recs = {}
  local seen = {}
  for _, b in ipairs(sorted_buf_list()) do
    seen[b.name] = true
    local cur = pal.buf(b.name, b.size)
    local p = rec.prev[b.name]
    if p and p.size == b.size then
      recs[#recs + 1] = { name = b.name, kind = 0,
                          payload = pal.buf_delta1(p.mirror, cur) }
      p.mirror:copy(0, cur, 0, b.size)
    else
      recs[#recs + 1] = { name = b.name, kind = 1,
                          payload = cur:str(0, b.size) }
      rec.prev[b.name] = { mirror = mirror_of(cur, b.size), size = b.size }
    end
  end
  local freed = {}
  for name in pairs(rec.prev) do
    if not seen[name] then freed[#freed + 1] = name end
  end
  table.sort(freed)
  for _, name in ipairs(freed) do
    recs[#recs + 1] = { name = name, kind = 2, payload = "" }
    rec.prev[name] = nil
  end
  table.sort(recs, function(a, b) return a.name < b.name end)

  local parts = { pack("<s4", input_record), pack("<I4", #recs) }
  for _, r in ipairs(recs) do
    parts[#parts + 1] = pack("<s4I1s4", r.name, r.kind, r.payload)
  end
  local doc = state.doc_bytes()
  if doc == rec.prev_doc then
    parts[#parts + 1] = "\0"
  else
    parts[#parts + 1] = "\1" .. pack("<s4", doc)
    rec.prev_doc = doc
  end
  rec.w.chunk("FRAM", 1, table.concat(parts))

  rec.frames = rec.frames + 1
  if rec.frames % rec.kf == 0 then
    rec.w.chunk("KEYF", 1, state.snapshot({ code = false }))
  end
end

-- called when hot reload swapped modules mid-recording
function M.on_code_change(changed_names)
  if not rec or #changed_names == 0 then return end
  local mods = {}
  for _, m in ipairs(pt.modules()) do mods[m.name] = m end
  local names = {}
  for _, n in ipairs(changed_names) do names[#names + 1] = n end
  table.sort(names)
  local parts = { pack("<I4", #names) }
  for _, n in ipairs(names) do
    local m = mods[n] or error("epoch for unknown module " .. n)
    parts[#parts + 1] = pack("<s4s4s4", m.name, m.path, m.source)
  end
  rec.w.chunk("EPOC", 1, table.concat(parts))
  pal.log("[trace] code epoch: " .. table.concat(names, ", "))
end

function M.record_stop()
  if not rec then return end
  rec.w.chunk("TAIL", 1, pack("<I4", rec.frames))
  local blob = rec.w.result()
  local ok = pal.write_file(rec.path, blob)
  pal.log(("[trace] wrote %s: %d frames, %d bytes%s")
          :format(rec.path, rec.frames, #blob, ok and "" or " (WRITE FAILED)"))
  rec = nil
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
  local chunks = chunk.read(blob, "PTRC")

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

  for _, c in ipairs(chunks) do
    if c.tag == "FRAM" and c.version == 1 then
      frame = frame + 1
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
      pt.restore_bundle(files)
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
