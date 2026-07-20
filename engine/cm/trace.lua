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

-- feel knobs (console-tunable; read live). seconds = the RAM-resident
-- window, kf = frames per segment = keyframe cadence of exported traces.
-- R6b (REWIND.md §3): spill = stream closed segments to
-- <project>/.ed/history (cm.main turns it on for real windowed sessions;
-- headless/CI never write); budget_mb bounds the total retained history
-- (whole oldest segment files evicted past it). The seconds window is
-- RAM residency, not the history bound, once spill is on.
M.ring = M.ring or { seconds = 30, kf = 60, spill = false, budget_mb = 1024,
                      thumbs = false, rec_paused = false }

-- A7 §11 presented-frame previews (THMB): about one game-FOV thumbnail every
-- this many recorded frames. Console-tunable; read live by thumb_pump. The
-- default is one per minute at the fixed 60 Hz.
M.thumb_period = M.thumb_period or 60 * 60

-- Read-only timeline marker bits returned by ring_timeline(). They are chrome
-- metadata derived from existing records, never sim state and never verified.
-- SAVE/ERROR/RESTART ride observer chunks (FSAV/MARK) the editor emits at the
-- render/dev phase; INPUT/CODE/EVAL are read back out of the sim chunk stream;
-- SESSION is the adopted<->live structural boundary.
M.timeline_event = { INPUT = 1, CODE = 2, EVAL = 4, SESSION = 8,
                     SAVE = 16, ERROR = 32, RESTART = 64, IMPORT = 128 }

-- M._R = ring session { project, stream_id, segs, next_id, prev, prev_doc,
--                       last_frame }
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

-- ---- the timeline activity/event summary (A7 §12) ----
--
-- Each closed segment carries a coarse { sim, editor, files, events } digest:
-- the max single-frame changed bytes for named sim buffers+doc, the editor
-- doc, and project files (asset saves + code epochs), plus the OR of the
-- frame event bits. It is observer-only — never a named buffer, never the sim
-- doc, never verified — and it is what lets the tray draw the WHOLE retained
-- window (including demoted, spilled, and adopted cross-session segments)
-- without decoding a single frame of state. Resident segments still render
-- exactly from their chunk streams; the digest is the zoomed-out / cross-
-- session fallback. It is persisted in the segment blob (SUMM) and, so boot
-- adoption never reads the blobs, in the manifest line.

-- A lightweight FRAM reader for the activity lane. It counts the bytes actually
-- carried by logical deltas/full replacements and the sim document; it does not
-- allocate buffers, apply deltas, or reconstruct frame state.
local function timeline_fram(p)
  local irec, pos = unpack("<s4", p)
  local nbufs
  nbufs, pos = unpack("<I4", p, pos)
  local changed = 0
  for _ = 1, nbufs do
    local name, kind, payload
    name, kind, payload, pos = unpack("<s4I1s4", p, pos)
    changed = changed + #payload
  end
  if p:byte(pos) == 1 then
    local doc = unpack("<s4", p, pos + 1)
    changed = changed + #doc
  end
  -- Mouse motion is intentionally not an "input transition" marker. Action
  -- bits + mouse/pad buttons (and pad connects) are discrete user decisions;
  -- wheel and analog axes already produce visible state activity when a game
  -- consumes them, and quantized stick drift must not saturate the lane.
  local input_key
  if #irec >= 10 then
    local keyparts = { irec:sub(1, 4), irec:sub(9, 9) }
    local kpos = 11
    while kpos + 1 <= #irec do -- v2 extensions (D082); malformed = stop
      local tag, len = irec:byte(kpos), irec:byte(kpos + 1)
      local fin = kpos + 1 + len
      if fin > #irec then break end
      if tag == 1 and len >= 1 then
        local n, q = irec:byte(kpos + 2), kpos + 3
        for _ = 1, math.min(n, 4) do
          if q + 4 > fin then break end
          keyparts[#keyparts + 1] = irec:sub(q, q + 4) -- slot + buttons
          q = q + 11
        end
      end
      kpos = fin + 1
    end
    input_key = table.concat(keyparts)
  else
    input_key = irec
  end
  return changed, input_key
end

-- total changed source bytes carried by an EPOC (hot-reload) chunk
local function epoc_bytes(payload)
  local ok, n, pos = pcall(unpack, "<I4", payload)
  if not ok then return 0 end
  local total = 0
  for _ = 1, n do
    local name, fpath, source
    ok, name, fpath, source, pos = pcall(unpack, "<s4s4s4", payload, pos)
    if not ok then break end
    total = total + #source
  end
  return total
end

-- Fold a segment's resident chunk stream into its coarse digest. Reused at
-- spill (the durable copy) and after a rewind truncation (the kept prefix).
-- Input transitions here are intra-segment only; the exact per-frame path in
-- ring_timeline still catches the segment-boundary transition for resident
-- segments, and the digest is a zoomed-out summary either way.
local function summarize_segment(seg)
  local E = M.timeline_event
  local s = { sim = 0, editor = 0, files = 0, events = 0 }
  local last_input
  for _, c in ipairs(seg.chunks or {}) do
    if c.tag == "FRAM" then
      local sim, ikey = timeline_fram(c.payload)
      if sim > s.sim then s.sim = sim end
      if last_input and ikey ~= last_input then s.events = s.events | E.INPUT end
      last_input = ikey
    elseif c.tag == "EDOC" then
      local ok, edoc = pcall(unpack, "<s4", c.payload, 2)
      local n = ok and #edoc or 0
      if n > s.editor then s.editor = n end
    elseif c.tag == "FSAV" then
      local ok, _, nbytes = pcall(unpack, "<s4I4", c.payload)
      if ok and nbytes > s.files then s.files = nbytes end
      s.events = s.events | E.SAVE
    elseif c.tag == "FIMP" then
      local ok, _, nbytes = pcall(unpack, "<s4I4", c.payload)
      if ok and nbytes > s.files then s.files = nbytes end
      s.events = s.events | E.IMPORT
    elseif c.tag == "EVAL" then
      s.events = s.events | E.EVAL
    elseif c.tag == "EPOC" then
      s.events = s.events | E.CODE
      local n = epoc_bytes(c.payload)
      if n > s.files then s.files = n end
    elseif c.tag == "MARK" then
      local ok, bit = pcall(unpack, "<I4", c.payload)
      if ok then s.events = s.events | bit end
    end
  end
  return s
end

local function ensure_summary(seg)
  if not seg.summary then seg.summary = summarize_segment(seg) end
  return seg.summary
end

-- ---- presented-frame previews (A7 §11) ----
--
-- A tiny thumbnail of the game FOV, captured about once a minute in a live
-- windowed session. Observer-only like the digest: never a named buffer, never
-- the sim doc, never verified, stripped from exported clips. seg.thumb is the
-- in-RAM index the tray draws from (it survives demotion and dies with the
-- segment on eviction); a durable THMB chunk rides the segment blob so a future
-- cross-session scan can recover previews the manifest is too small to carry.

local THUMB_H = 46     -- preview height (px); width follows the FOV aspect
local THUMB_WMAX = 128 -- cap very wide FOVs so one preview can't dominate

-- the preview dimensions for a source FOV, height-normalized then width-capped
local function thumb_dims(sw, sh)
  sw, sh = math.max(1, math.floor(sw)), math.max(1, math.floor(sh))
  local dh = math.min(THUMB_H, sh)
  local dw = math.max(1, math.floor(sw * dh / sh + 0.5))
  if dw > THUMB_WMAX then
    dw = THUMB_WMAX
    dh = math.max(1, math.min(sh, math.floor(sh * dw / sw + 0.5)))
  end
  return dw, dh
end

-- Point-sample a tightly-packed RGBA image (sw x sh, top-left origin) down to
-- dw x dh. Nearest-neighbour keeps it cheap enough to run inline once a minute;
-- a 46px preview does not need a box filter. sub() copies each 4-byte pixel
-- whole, so no per-channel decode/encode.
local function downscale_rgba(src, sw, sh, dw, dh)
  local out, k = {}, 0
  for dy = 0, dh - 1 do
    local row = math.floor(dy * sh / dh) * sw
    for dx = 0, dw - 1 do
      local p = (row + math.floor(dx * sw / dw)) * 4 + 1
      k = k + 1
      out[k] = src:sub(p, p + 3)
    end
  end
  return table.concat(out)
end

-- the one manifest-line spelling: id first frames fbytes + the 4 digest fields
-- (D100) + an optional project-manifest hash (D103). Legacy 4-field lines
-- (pre-A7) decode with no digest and read back as an honest "no summary" gap;
-- a segment recorded without a project manifest (spill off, empty project)
-- keeps 8 fields; hist_scan tolerates all three widths.
local function seg_index_line(seg, fbytes)
  local s = ensure_summary(seg)
  local base = ("%d %d %d %d %d %d %d %d"):format(seg.id, seg.first, seg.frames,
    fbytes, s.sim, s.editor, s.files, s.events)
  if seg.manifest_hash then base = base .. " " .. seg.manifest_hash end
  return base .. "\n"
end

-- ---- the segment ring ----

-- the editor stream (R6a, REWIND.md §2/D053): the ed doc's canon bytes
-- ride the ring as EDOC chunks, written only when cm.ed.doc_rev moved
-- AND the canon actually changed. Sessions without the shell contribute
-- nothing. An observer like everything here — never sim-visible.
local function ed_canon(R)
  local ed = cm.require("cm.ed")
  if not (ed.on and ed.doc) then return R.prev_edoc end
  local rev = ed.doc_rev or 0
  if rev == R.prev_edrev then return R.prev_edoc end
  R.prev_edrev = rev
  return state.canon(ed.doc)
end

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
                kf_doct = doct, kf_edoc = R.prev_edoc,
                bundle = cm.modules(), chunks = {},
                manifest_hash = R.manifest_hash, -- §14: the tree at this keyframe
                frames = 0, bytes = 0 }
  R.next_id = R.next_id + 1
  R.segs[#R.segs + 1] = seg
  return seg
end

local function seg_append(seg, tag, payload)
  seg.chunks[#seg.chunks + 1] = { tag = tag, payload = payload }
  seg.bytes = seg.bytes + #payload
end

-- ---- the disk tier (R6b, REWIND.md §3) ----

local function hist_dir(R)
  return R.project .. "/.ed/history"
end

local function hist_dir_for(project)
  return project .. "/.ed/history"
end

-- Each durable history generation has an exact, opaque identity. It survives
-- normal launches/adoption and changes when history is cleared or a fork can
-- no longer join the retained chain. Crash reports match this ID + a frame;
-- timestamps are never identity (D065). This tiny derived marker lives inside
-- history/ so cm.ed.clear_cache removes it with the segments it identifies.
local STREAM_MAGIC = "CHST"
local function hist_stream_path(dir) return dir .. "/stream" end

local function stream_encode(id)
  local w = chunk.writer(STREAM_MAGIC)
  w.chunk("STRM", 1, pack("<s4", id))
  return w.result()
end

local function stream_decode(blob)
  for _, c in ipairs(chunk.read(blob, STREAM_MAGIC)) do
    if c.tag == "STRM" and c.version == 1 then
      local id = unpack("<s4", c.payload)
      if #id ~= 36 or id:sub(1, 4) ~= "hs1-"
         or not id:sub(5):match("^%x+$") then
        error("invalid history stream id", 0)
      end
      return id
    end
  end
  error("history stream marker has no supported STRM chunk", 0)
end

local function stream_read(project)
  local blob = pal.read_file(hist_stream_path(hist_dir_for(project)))
  if not blob then return nil end
  local ok, id = pcall(stream_decode, blob)
  if ok then return id end
  pal.log("[trace] history stream marker unreadable: " .. tostring(id))
  return nil
end

local function stream_new(project)
  -- Observer/dev identity only: never enters named buffers, snapshots, or
  -- verification. Two independent 64-bit hashes make accidental reuse across
  -- rapid rebuilds negligible; the persisted marker, not this recipe, is the
  -- compatibility contract.
  M._stream_nonce = (M._stream_nonce or 0) + 1
  local seed = table.concat({ project, tostring(os.time()),
                              tostring(pal.time_ns()),
                              tostring(M._stream_nonce), tostring({}) }, "\0")
  return ("hs1-%016x%016x"):format(pal.hash("a\0" .. seed),
                                    pal.hash("b\0" .. seed))
end

local function stream_prepare(R, adopted)
  if not M.ring.spill or R.project == "" then
    R.stream_id = ""
    return
  end
  local id = adopted and stream_read(R.project) or nil
  if not id then
    id = stream_new(R.project)
    local dir = hist_dir(R)
    pal.mkdir(dir)
    local ok, err = pal.write_file_atomic(hist_stream_path(dir),
                                           stream_encode(id),
                         M._write_fail and M._write_fail.stream)
    if not ok then
      pal.log(("[trace] history stream identity failed (%s): %s; spill off")
              :format(hist_stream_path(dir), tostring(err)))
      M.ring.spill = false
      R.stream_id = ""
      return
    end
  end
  R.stream_id = id
end

-- ---- the content-addressed project-blob store (A7 §14, D103) ----
--
-- A durable store of the project's source+asset file bytes, keyed by their
-- sha256, so a retained segment can name a *complete* project tree (its
-- manifest, below) without copying an unchanged sprite/sound/script into every
-- segment. Observer-only like the rest of the disk tier: it rides M.ring.spill,
-- so headless / --verify / goldens never walk a tree, hash a file, or write a
-- blob. Blobs live beside the segments in .ed/history/blobs/<hex>, so
-- cm.ed.clear_cache removes them with the history they describe.

local function blob_dir(R) return hist_dir(R) .. "/blobs" end
local function blob_path(R, hash) return blob_dir(R) .. "/" .. hash end

-- store bytes content-addressed; return the hex hash (or nil,err on write
-- failure — the caller degrades, a missing blob is an honest un-materializable
-- gap, never a crash). Dedup by construction: an existing blob is never
-- rewritten, and R.blob_bytes tracks only bytes this store actually wrote.
local function blob_put_bytes(R, bytes)
  local hash = pal.sha256(bytes)
  local path = blob_path(R, hash)
  if not pal.mtime(path) then
    pal.mkdir(blob_dir(R))
    local ok, err = pal.write_file_atomic(path, bytes,
                          M._write_fail and M._write_fail.blob)
    if not ok then return nil, err end
    R.blob_bytes = (R.blob_bytes or 0) + #bytes
  end
  return hash
end

-- ---- the per-segment project manifest (A7 §14, D103) ----
--
-- A complete map { relpath -> blob hex } of the project's non-machine files at a
-- segment's keyframe. §14 keyframe granularity: the tree state at each segment's
-- first frame, so any retained segment (including an adopted cross-session one)
-- can materialize the whole project. The manifest is itself content-addressed
-- (stored as a blob → manifest hash) so unchanged trees dedupe across segments.

-- Walk the live project tree exactly like the release exporter's prune rule:
-- pal.list_dir already skips dot-directories (.ed/.git), and video.dat/input.dat
-- are per-machine policy, never project source (D036/D074/D084). Each file is
-- hashed natively (sha256_file — no Lua read) and stored only when its content
-- is new. Best-effort per file: an unreadable/unstorable file is simply omitted.
local function walk_manifest(R)
  local paths = {}
  for _, rel in ipairs(pal.list_dir(R.project) or {}) do
    if rel ~= "video.dat" and rel ~= "input.dat" then
      local full = R.project .. "/" .. rel
      local info = pal.x_path_info(full)
      if info and info.type == "file" and not info.link then
        local hash = pal.sha256_file(full)
        if hash then
          if not pal.mtime(blob_path(R, hash)) then
            local bytes = pal.read_file(full)
            if bytes then hash = blob_put_bytes(R, bytes) end
          end
          if hash then paths[rel] = hash end
        end
      end
    end
  end
  return paths
end

local function manifest_encode(paths)
  local rels = {}
  for rel in pairs(paths) do rels[#rels + 1] = rel end
  table.sort(rels) -- deterministic bytes → the same tree hashes the same
  local parts = { pack("<I4", #rels) }
  for _, rel in ipairs(rels) do
    parts[#parts + 1] = pack("<s4s4", rel, paths[rel])
  end
  return table.concat(parts)
end

local function manifest_decode(bytes)
  local n, pos = unpack("<I4", bytes)
  local paths = {}
  for _ = 1, n do
    local rel, hash
    rel, hash, pos = unpack("<s4s4", bytes, pos)
    paths[rel] = hash
  end
  return paths
end

-- Recompute R.manifest from the live tree and store it; sets R.manifest_hash
-- (nil when spill is off / no project / total failure — an honest "no manifest"
-- the tray and packaging can label). Rides spill so headless never walks a tree.
local function refresh_manifest(R)
  if not M.ring.spill or R.project == "" then
    R.manifest, R.manifest_hash = nil, nil
    return nil
  end
  local paths = walk_manifest(R)
  local mhash = blob_put_bytes(R, manifest_encode(paths))
  R.manifest, R.manifest_hash = paths, mhash
  return mhash
end

-- the manifest (R6.5): one line per spilled segment ("id first frames
-- fbytes" + the D100 digest + the D103 manifest hash), appended at spill so
-- boot adoption never has to read the segment blobs themselves. Stale lines
-- (evicted/truncated files) are dropped at scan time by an existence check; a
-- re-spilled id (rewind re-closed the same segment) is deduped last-wins.
local function hist_index(dir)
  return dir .. "/index"
end

local function index_append(R, seg)
  local path = hist_index(hist_dir(R))
  local line = seg_index_line(seg, seg.fbytes)
  local bytes = (R.index_bytes or pal.read_file(path) or "") .. line
  local ok, err = pal.write_file_atomic(path, bytes,
                                        M._write_fail and M._write_fail.index)
  if ok then R.index_bytes = bytes end
  return ok, err
end

local function spill_blob(seg)
  local w = chunk.writer("CSEG")
  w.chunk("HEAD", 1, pack("<I4I4", seg.first, seg.frames))
  local s = ensure_summary(seg)
  w.chunk("SUMM", 1, pack("<I4I4I4I4", s.sim, s.editor, s.files, s.events))
  if seg.manifest_hash then -- §14: the content-addressed project tree at kf
    w.chunk("PMAN", 1, pack("<s4", seg.manifest_hash))
  end
  for _, b in ipairs(seg.kf_bufs) do
    w.chunk("KFBF", 1, pack("<s4s4", b.name, b.bytes))
  end
  w.chunk("KFDC", 1, pack("<s4", seg.kf_doct))
  w.chunk("KFED", 1, pack("<s4", seg.kf_edoc or ""))
  for _, c in ipairs(seg.chunks) do w.chunk(c.tag, 1, c.payload) end
  return w.result()
end

local function abandon_ready(R)
  for _, seg in ipairs((R and R.spill_ready) or {}) do
    seg.spill_queued = nil
  end
  if R then R.spill_ready = {} end
end

local function spill_fail(R, path, err)
  pal.log(("[trace] history spill failed (%s): %s; spill off")
          :format(path, tostring(err)))
  M.ring.spill = false
  -- Once the durable chain fails, queued successors must not remain pinned or
  -- publish manifests that depend on the missing segment.
  abandon_ready(R)
end

local function async_writes()
  return type(pal.x_write_file_pair_atomic_async) == "function"
     and type(pal.x_write_file_atomic_poll) == "function"
     and type(pal.x_write_file_atomic_drain) == "function"
end

M._async_jobs = M._async_jobs or {}
local evict -- completion can make an old segment eligible for demotion
local start_spill

local function submit_ready(R)
  local ready = R and R.spill_ready
  local all_ok = true
  -- A cumulative manifest makes jobs within one stream dependent. Keep only
  -- one in flight so a failed segment cannot be named by a later manifest.
  -- The native worker remains globally bounded/FIFO for other streams/users.
  while ready and #ready > 0 and M.ring.spill
        and (not async_writes() or not R.spill_inflight) do
    local seg = table.remove(ready, 1)
    seg.spill_queued = nil
    if not start_spill(R, seg) then all_ok = false end
  end
  return all_ok
end

-- Consume completed worker transactions without ever waiting. This runs in
-- the render/chrome phase; record_frame only marks closed segments ready. A segment is
-- not demotable until both its container and cumulative manifest are durable.
function M.history_pump()
  if not async_writes() then
    return not start_spill or submit_ready(M._R)
  end
  local all_ok = true
  while true do
    local id, ok, err = pal.x_write_file_atomic_poll()
    if not id then break end
    local p = M._async_jobs[id]
    M._async_jobs[id] = nil
    if p then
      p.seg.spilling = nil
      if p.R.spill_inflight == id then p.R.spill_inflight = nil end
      if ok then
        p.R.index_bytes = p.index_bytes
        p.seg.file, p.seg.fbytes, p.seg.spilled = p.path, p.bytes, true
        if evict and M.ring.spill then evict(p.R) end
      else
        spill_fail(p.R, p.path, err)
        all_ok = false
      end
    elseif not ok then
      -- A VM reboot can discard the Lua bookkeeping while the native worker
      -- completes. The pair itself still failed closed; retain the evidence.
      pal.log("[trace] orphaned background history write failed: " ..
              tostring(err))
      all_ok = false
    end
  end
  -- Serialization and the native byte-copy also stay outside record_frame.
  -- Ordinarily this is one just-closed segment; the list only grows when the
  -- render loop itself was unable to run.
  local submitted = not start_spill or submit_ready(M._R)
  return submitted and all_ok
end

-- Explicit barrier for quit/crash and structural timeline changes. Never call
-- this from the ordinary sim step: Windows FlushFileBuffers may take tens of
-- milliseconds even for a small segment.
function M.history_drain()
  if not async_writes() then return M.history_pump() end
  local all_ok = true
  while true do
    if not M.history_pump() then all_ok = false end
    -- The barrier is global by design, so it also catches a completion whose
    -- Lua bookkeeping was lost during an engine-VM reboot.
    pal.x_write_file_atomic_drain()
    if not M.history_pump() then all_ok = false end
    -- A successful completion may have submitted the next dependent segment.
    if not next(M._async_jobs) then return all_ok end
  end
end

-- Compatibility path for an older PAL. Current API 13 builds always use the
-- worker below; feature detection keeps engine scripts inspectable with an
-- older binary while preserving the established failure semantics.
local function spill_seg_sync(R, seg, blob, path)
  local ok, err = pal.write_file_atomic(path, blob,
                         M._write_fail and M._write_fail.segment)
  if not ok then spill_fail(R, path, err); return false end
  seg.file, seg.fbytes, seg.spilled = path, #blob, true
  ok, err = index_append(R, seg)
  if not ok then
    -- An unindexed segment is unreachable on the next boot. Keep this
    -- session's RAM generation authoritative and remove the orphan.
    pal.x_remove(path)
    seg.file, seg.fbytes, seg.spilled = nil, nil, nil
    spill_fail(R, hist_index(hist_dir(R)), err)
    return false
  end
  return true
end

-- Queue a closed segment + cumulative manifest as one ordered native worker
-- transaction. The copied byte strings may be collected immediately on the
-- Lua side; the segment's decoded RAM stays authoritative until completion.
start_spill = function(R, seg)
  if not M.ring.spill or seg.spilled or seg.spilling or R.project == "" then
    return true
  end
  local blob = spill_blob(seg)
  pal.mkdir(hist_dir(R))
  local path = ("%s/seg_%06d"):format(hist_dir(R), seg.id)
  if not async_writes() then
    return spill_seg_sync(R, seg, blob, path)
  end

  local index_path = hist_index(hist_dir(R))
  local line = seg_index_line(seg, #blob)
  local index_bytes = (R.index_bytes or pal.read_file(index_path) or "") .. line
  local id, err = pal.x_write_file_pair_atomic_async(
    path, blob, index_path, index_bytes,
    M._write_fail and M._write_fail.segment,
    M._write_fail and M._write_fail.index)
  if not id then
    spill_fail(R, path, err)
    return false
  end
  R.spill_inflight = id
  seg.spilling = id
  M._async_jobs[id] = { R = R, seg = seg, path = path, bytes = #blob,
                        index_bytes = index_bytes }
  return true
end

-- Sim-side close is deliberately tiny: retain the decoded segment and hand a
-- pointer to render/dev maintenance. No serialization, memcpy, filesystem
-- call, flush, or sync occurs inside record_frame.
local function spill_seg(R, seg)
  if not M.ring.spill or seg.spilled or seg.spilling or seg.spill_queued
     or R.project == "" then return end
  R.spill_ready = R.spill_ready or {}
  R.spill_ready[#R.spill_ready + 1] = seg
  seg.spill_queued = true
end

-- drop a spilled segment's RAM copy (the skeleton keeps id/first/frames/
-- bytes/file/bundle — everything seek and rewind bookkeeping need)
local function demote(seg)
  seg.kf_bufs, seg.kf_doct, seg.kf_edoc, seg.chunks = nil, nil, nil, nil
end

-- materialize a demoted segment from its file; a tiny LRU caps how many
-- spilled segments sit decoded at once (scrubbing hits neighbors)
local function seg_load(R, seg)
  if seg.kf_bufs then return seg end
  local blob = pal.read_file(seg.file)
    or error("history segment missing: " .. tostring(seg.file), 0)
  local kf_bufs, chunks2, doct, edoc = {}, {}, "", ""
  for _, c in ipairs(chunk.read(blob, "CSEG")) do
    if c.tag == "HEAD" then -- id/first/frames live on the skeleton
    elseif c.tag == "SUMM" then
      local sim, ed, fi, ev = unpack("<I4I4I4I4", c.payload)
      seg.summary = { sim = sim, editor = ed, files = fi, events = ev }
    elseif c.tag == "PMAN" then
      seg.manifest_hash = seg.manifest_hash or unpack("<s4", c.payload)
    elseif c.tag == "KFBF" then
      local name, bytes = unpack("<s4s4", c.payload)
      kf_bufs[#kf_bufs + 1] = { name = name, bytes = bytes }
    elseif c.tag == "KFDC" then doct = unpack("<s4", c.payload)
    elseif c.tag == "KFED" then edoc = unpack("<s4", c.payload)
    else chunks2[#chunks2 + 1] = { tag = c.tag, payload = c.payload } end
  end
  seg.kf_bufs, seg.kf_doct, seg.kf_edoc, seg.chunks =
    kf_bufs, doct, edoc, chunks2
  R.loaded = R.loaded or {}
  R.loaded[#R.loaded + 1] = seg
  if #R.loaded > 4 then
    local old = table.remove(R.loaded, 1)
    if old ~= seg and old.spilled and old.kf_bufs then demote(old) end
  end
  return seg
end

-- ---- cross-session adoption (R6.5, REWIND.md §3) ----

-- validated manifest entries, oldest first. Existence-checks every file
-- (eviction/truncation leave stale lines), dedupes re-spilled ids
-- last-wins, and fully parses the NEWEST file — the only one a crash
-- can have half-written; a corrupt tail is deleted and the scan retries
-- on the one before it.
local function hist_scan(project)
  if project == "" then return {} end
  local dir = project .. "/.ed/history"
  local blob = pal.read_file(hist_index(dir))
  if not blob then return {} end
  -- Parse per line (last-wins dedup by id). The four digest fields are
  -- optional: legacy pre-A7 lines have only the first four and read back with
  -- no summary (an honest gap the tray labels).
  local byid, order = {}, {}
  for line in blob:gmatch("[^\n]+") do
    local id, first, frames, fbytes = line:match("^(%d+) (%d+) (%d+) (%d+)")
    if id then
      id = tonumber(id)
      if not byid[id] then order[#order + 1] = id end
      local e = { id = id, first = tonumber(first),
                  frames = tonumber(frames), fbytes = tonumber(fbytes),
                  file = ("%s/seg_%06d"):format(dir, id) }
      local sim, ed, fi, ev =
        line:match("^%d+ %d+ %d+ %d+ (%d+) (%d+) (%d+) (%d+)")
      if sim then
        e.summary = { sim = tonumber(sim), editor = tonumber(ed),
                      files = tonumber(fi), events = tonumber(ev) }
      end
      -- optional D103 project-manifest hash (9th field); absent = legacy or
      -- an empty/spill-off recording, an honest "not materializable" gap.
      e.manifest_hash =
        line:match("^%d+ %d+ %d+ %d+ %d+ %d+ %d+ %d+ (%x+)")
      byid[id] = e
    end
  end
  local ent = {}
  for _, id in ipairs(order) do
    local e = byid[id]
    local mt = pal.mtime(e.file)
    if mt and mt > 0 then ent[#ent + 1] = e end
  end
  table.sort(ent, function(a, b) return a.first < b.first end)
  while #ent > 0 do
    local tail = ent[#ent]
    local tb = pal.read_file(tail.file)
    local ok = tb and pcall(chunk.read, tb, "CSEG")
    if ok then break end
    pal.log("[trace] dropping corrupt history tail " .. tail.file)
    pal.x_remove(tail.file)
    ent[#ent] = nil
  end
  return ent
end

-- the last retained frame of the project's on-disk history, or nil.
-- cm.main seeds the sim frame counter from this BEFORE ring_start so a
-- live session continues the same timeline (one continuous past stream
-- across restarts — the human's ask, D055).
function M.hist_peek(project)
  local ent = hist_scan(project)
  local e = ent[#ent]
  return e and (e.first + e.frames - 1) or nil
end

-- adopt the on-disk history as skeleton segments: the contiguous chain
-- ending exactly at the PRESENT frame (guaranteed at boot by the
-- hist_peek seed; after an out-of-band restore usually nothing fits —
-- a forked timeline can't rejoin). Files outside the chain are wiped;
-- the manifest is rewritten compact. Adopted skeletons carry no RAM
-- bundle (their sessions' code was never spilled): browsing/parking is
-- exact; a RESUME into one keeps the current code (logged in rewind).
local function hist_adopt(R)
  if not M.ring.spill or R.project == "" then return false end
  local dir = hist_dir(R)
  local ent = hist_scan(R.project)
  local chain, expect = {}, state.frame()
  for i = #ent, 1, -1 do
    local e = ent[i]
    if e.first + e.frames - 1 == expect and e.frames > 0 then
      chain[#chain + 1] = e
      expect = e.first - 1
    else
      break
    end
  end
  local keep = {}
  for _, e in ipairs(chain) do keep[e.file] = true end
  -- A non-empty adopted chain keeps its exact identity. With no matching
  -- chain, the marker is deleted with the abandoned files and ring_init
  -- creates a fresh generation below.
  if #chain > 0 then keep[hist_stream_path(dir)] = true end
  local names = pal.list_dir(dir)
  for _, n in ipairs(names or {}) do
    local path = dir .. "/" .. n
    -- The content-addressed blob store (§14) is reclaimed by gc_blobs' mark-
    -- sweep against the surviving chain, not by this chain-file wipe — else a
    -- normal adoption would delete the very blobs its segments reference. Orphan
    -- blobs (a fork, or a previous crash) fall to gc_blobs at ring_init instead.
    if n ~= "blobs" and not n:find("^blobs/") and not keep[path] then
      pal.x_remove(path)
    end
  end
  if #chain == 0 then return false end
  local lines = {}
  for i = #chain, 1, -1 do -- chain is newest-first; adopt oldest-first
    local e = chain[i]
    R.segs[#R.segs + 1] = {
      id = e.id, first = e.first, frames = e.frames, bytes = 0,
      file = e.file, fbytes = e.fbytes, spilled = true, adopted = true,
      summary = e.summary, -- from the manifest, so the tray draws the past
      manifest_hash = e.manifest_hash, -- §14: adopted history is exportable
    }                      -- without touching a single spilled blob
    R.next_id = math.max(R.next_id, e.id + 1)
    local s, mh = e.summary, e.manifest_hash and (" " .. e.manifest_hash) or ""
    if s then
      lines[#lines + 1] = ("%d %d %d %d %d %d %d %d%s\n"):format(e.id, e.first,
        e.frames, e.fbytes, s.sim, s.editor, s.files, s.events, mh)
    else
      lines[#lines + 1] = ("%d %d %d %d\n"):format(e.id, e.first, e.frames,
                                                   e.fbytes)
    end
  end
  pal.mkdir(dir)
  local ok, err = pal.write_file_atomic(hist_index(dir), table.concat(lines),
                         M._write_fail and M._write_fail.adopt_index)
  if not ok then
    pal.log(("[trace] history index compact failed (%s): %s; spill off")
            :format(hist_index(dir), tostring(err)))
    M.ring.spill = false
  end
  pal.log(("[trace] adopted %d history segments (frames %d..%d)")
          :format(#chain, R.segs[1].first, state.frame()))
  return true
end

-- Eviction. Spill OFF = the pre-R6 rule verbatim: drop whole oldest
-- segments while the rest still covers the seconds window. Spill ON:
-- the window is RAM residency (older spilled segments demote to
-- skeletons); the disk budget bounds total retained bytes, oldest
-- files first. Pinned segments never drop either way.
evict = function(R)
  local want = math.max(1, math.floor((M.ring.seconds or 30) * 60))
  local total = 0
  for _, s in ipairs(R.segs) do total = total + s.frames end
  if not M.ring.spill then
    while #R.segs > 1 do
      local s = R.segs[1]
      if M._rec and s.id >= M._rec.from_id then break end
      if s.spilling or s.spill_queued then break end
      if total - s.frames < want then break end
      total = total - s.frames
      table.remove(R.segs, 1)
    end
    return
  end
  local ram = 0
  for i = #R.segs, 1, -1 do
    local s = R.segs[i]
    ram = ram + s.frames
    if ram > want and s.spilled and s.kf_bufs then demote(s) end
  end
  local budget = math.floor((M.ring.budget_mb or 1024) * 1024 * 1024)
  local retained = 0
  for _, s in ipairs(R.segs) do retained = retained + (s.fbytes or s.bytes) end
  while #R.segs > 1 and retained > budget do
    local s = R.segs[1]
    if M._rec and s.id >= M._rec.from_id then break end
    if s.spilling or s.spill_queued then break end
    retained = retained - (s.fbytes or s.bytes)
    if s.file then pal.x_remove(s.file) end
    table.remove(R.segs, 1)
  end
end

-- Content-addressed blobs are shared across segments, so they are reclaimed by
-- mark-and-sweep, not per-segment eviction: at (re)init, mark every retained
-- segment's manifest (and the file blobs it names) reachable and delete the
-- rest. This also sweeps orphans a crash left behind, and recomputes the store's
-- byte total so the disk meter reads true without a per-frame stat. In-session
-- the store only grows (bounded by distinct file versions saved); the next init
-- sweeps. Rides spill; a missing/corrupt manifest just keeps its files (safe).
local function gc_blobs(R)
  R.blob_bytes = nil
  if not M.ring.spill or R.project == "" then return end
  local names = pal.list_dir(blob_dir(R))
  if not names then return end
  local keep, mhashes = {}, {}
  local function mark(mh)
    if mh and not mhashes[mh] then mhashes[mh] = true; keep[mh] = true end
  end
  for _, s in ipairs(R.segs) do mark(s.manifest_hash) end
  mark(R.manifest_hash) -- the fresh baseline generation
  for mh in pairs(mhashes) do
    local mb = pal.read_file(blob_path(R, mh))
    local ok, paths = pcall(manifest_decode, mb or "")
    if mb and ok then for _, h in pairs(paths) do keep[h] = true end
    else keep[mh] = true end -- can't expand it — retain conservatively
  end
  local total = 0
  for _, n in ipairs(names) do
    local path = blob_dir(R) .. "/" .. n
    if keep[n] then
      local info = pal.x_path_info(path)
      if info and info.type == "file" then total = total + info.size end
    else
      pal.x_remove(path)
    end
  end
  R.blob_bytes = total
end

-- (re)initialize the mirrors from live state and open a fresh segment
local function ring_init(R)
  R.segs = {}
  R.loaded = nil
  local adopted = hist_adopt(R) -- R6.5: continuous cross-session stream;
                                -- adopt the chain ending at the present
  stream_prepare(R, adopted)    -- D065: exact generation identity
  R.index_bytes = R.project ~= "" and
    (pal.read_file(hist_index(hist_dir(R))) or "") or ""
  -- One capture boundary for every engine-owned Lua handle. Participants
  -- flush into ordinary named buffers/doc, so the ring needs no module-
  -- specific chunks or restore calls (cm.state owns both halves).
  state.capture_runtime()
  R.prev = {}
  for _, b in ipairs(sorted_buf_list()) do
    R.prev[b.name] = { mirror = mirror_of(pal.buf(b.name, b.size), b.size),
                       size = b.size }
  end
  R.prev_doc = state.doc_bytes()
  R.prev_doc_hash = state.doc_hash()
  R.prev_edoc, R.prev_edrev = "", nil
  R.prev_edoc = ed_canon(R) or ""
  R.last_frame = state.frame()
  -- §14 (D103): capture the project tree as this generation's manifest baseline
  -- before the first segment snapshots it, then reclaim blobs no retained
  -- segment (adopted or fresh) still names. Both are no-ops without spill.
  local ok, err = pcall(refresh_manifest, R)
  if not ok then pal.log("[trace] project manifest baseline failed: " ..
                         tostring(err)); R.manifest, R.manifest_hash = nil, nil end
  R.manifest_dirty = nil
  open_segment(R, R.last_frame + 1)
  gc_blobs(R)
end

function M.ring_start(opts)
  M.history_drain() -- finish any native work surviving a VM/project handoff
  local R = { project = (opts and opts.project) or "", next_id = 1 }
  ring_init(R)
  M._R = R
end

-- out-of-band restore: history no longer connects to the present
function M.ring_reset()
  local R = M._R
  if not R then return end
  M.history_drain()
  if M._rec then
    pal.log("[trace] recording stopped by ring reset")
    M.record_stop()
  end
  ring_init(R)
end

-- Recorder pause (A7 retention surface). Pausing freezes the always-on ring
-- so a long session stops consuming RAM/disk while the game keeps playing; the
-- retained history stays fully scrubbable meanwhile. Because the ring is a
-- single contiguous stream and the sim advanced during the pause, RESUME
-- reseeds from the present into a fresh stream — an honest session boundary,
-- the same rotation clear_cache/ring_reset perform. Transient session state
-- (never persisted, default off), so headless/verify/goldens never see it.
function M.set_rec_paused(on)
  on = on and true or false
  if M.ring.rec_paused == on then return on end
  M.ring.rec_paused = on
  if not on and M._R then M.ring_reset() end -- resume: fresh stream from now
  return on
end

function M.rec_paused()
  return M.ring.rec_paused == true
end

-- Re-run eviction now (used when the disk budget knob shrinks): oldest segment
-- files drop immediately so the meter reflects the new bound the same frame.
-- A no-op with spill off or no live ring; pinned/in-flight segments are safe.
function M.reevict()
  if M._R and evict then evict(M._R) end
end

function M.ring_range()
  local R = M._R
  if not R or #R.segs == 0 then return nil end
  local sn = R.segs[#R.segs]
  local newest = sn.frames > 0 and (sn.first + sn.frames - 1) or (sn.first - 1)
  return R.segs[1].first - 1, newest
end

-- Stable crash/replay locator for the active live source. `frame` is the last
-- fully captured state, never a partially-mutated throwing step. Empty stream
-- means there is no durable local history to resolve (headless/cache refusal).
function M.ring_locator()
  local R = M._R
  if not R then return nil end
  local _, hi = M.ring_range()
  return { project = R.project, stream = R.stream_id or "", frame = hi }
end

-- Read-only resolver used by the future crash-focus source: both fields must
-- match the report. A missing/corrupt/cleared stream returns nil rather than
-- guessing from a timestamp or whichever project happened to launch last.
function M.hist_locator(project)
  local id = stream_read(project)
  if not id then return nil end
  local ent = hist_scan(project)
  local e = ent[#ent]
  if not e then return nil end
  return { project = project, stream = id,
           frame = e.first + e.frames - 1 }
end

-- The safe pre-roll a crash focus loops: up to one minute at the fixed 60 Hz
-- ending at the last committed frame (A7 §16).
M.CRASH_PREROLL = M.CRASH_PREROLL or 60 * 60

local function short_stream(id)
  id = tostring(id or "")
  return #id <= 14 and id or (id:sub(1, 12) .. "..")
end

-- A7 §16: resolve a dropped crash report against the live/adopted history by
-- EXACT identity — the report's history stream + last-committed frame must
-- match the live ring; we never guess from wall-clock time. Returns a focus
-- plan (the pre-roll A/B bounds ending at the last committed frame, plus the
-- failed next-frame boundary) or nil + an honest reason naming the stream it
-- wanted versus what is retained locally. This only reads the ring; the tray
-- (cm.ed.rewind.drop_crash) parks and loops the plan. A future report that
-- embeds its own history tail is opened as a clip instead (never reaches here).
function M.crash_resolve(report, preroll)
  report = report or {}
  local stream = tostring(report.history_stream or "")
  local committed = math.tointeger(report.committed_frame)
  if stream == "" or not committed or committed < 0 then
    return nil, "the crash report names no durable history " ..
                "(a headless run or a boot-time failure)"
  end
  local loc = M.ring_locator()
  if not loc or loc.stream == "" then
    return nil, "no local recorded history to resolve the crash against"
  end
  if loc.stream ~= stream then
    return nil, ("this crash is from another recording (%s); the live " ..
                 "history is %s"):format(short_stream(stream),
                                         short_stream(loc.stream))
  end
  local lo, hi = M.ring_range()
  if not lo then
    return nil, "no local recorded history to resolve the crash against"
  end
  if committed < lo then
    return nil, ("the crashed moment was evicted -- history is retained " ..
                 "only from frame %d (the crash was at frame %d)")
                :format(lo, committed)
  end
  -- The crash lies in the past; clamp defensively so a stale over-count can't
  -- push the focus past the live edge.
  committed = math.min(committed, hi)
  preroll = math.max(1, math.floor(preroll or M.CRASH_PREROLL))
  local attempted = math.tointeger(report.attempted_frame)
  if not attempted or attempted < committed then attempted = committed + 1 end
  return {
    stream = stream,
    committed = committed,
    attempted = attempted, -- the failed next-frame boundary (never committed)
    a = math.max(lo, committed - preroll + 1), -- pre-roll start (up to 60s)
    b = committed,                             -- inclusive: the last safe frame
    lo = lo, hi = hi,
    kind = tostring(report.error_kind or "error"),
    report_id = tostring(report.report_id or ""),
  }
end

function M.ring_stats()
  local R = M._R
  if not R then return nil end
  local frames, bytes, kfbytes = 0, 0, 0
  local spilled, pending, disk_bytes, retained = 0, 0, 0, 0
  for _, s in ipairs(R.segs) do
    frames = frames + s.frames
    bytes = bytes + s.bytes
    retained = retained + (s.fbytes or s.bytes) -- exactly what evict bounds
    if s.kf_bufs then -- demoted skeletons keep no keyframe in RAM (R6b)
      for _, b in ipairs(s.kf_bufs) do kfbytes = kfbytes + #b.bytes end
    end
    if s.spilled then
      spilled = spilled + 1
      disk_bytes = disk_bytes + (s.fbytes or 0)
    end
    if s.spilling or s.spill_queued then pending = pending + 1 end
  end
  local lo, hi = M.ring_range()
  -- retained_bytes stays segment-only (exactly what evict bounds against the
  -- budget); blob_bytes is the shared content-addressed project-blob store
  -- (§14), reported so the disk meter can show total storage honestly. It is a
  -- running total (blob_put adds, gc_blobs recomputes) — never a per-frame stat.
  return { segs = #R.segs, frames = frames, chunk_bytes = bytes,
           keyframe_bytes = kfbytes, oldest = lo, newest = hi,
           spilled = spilled, pending = pending, disk_bytes = disk_bytes,
           retained_bytes = retained, blob_bytes = R.blob_bytes or 0,
           manifest = R.manifest_hash ~= nil, pinned = M._rec ~= nil }
end

-- ---- project-manifest / blob queries (A7 §14, D103) ----
-- The read side the tray's files lane and the packaging packet build on: the
-- live tree map, a segment's keyframe manifest, and content-addressed reads.

-- the live project manifest ({ relpath -> blob hex }) or nil (no spill / project)
function M.ring_manifest() return M._R and M._R.manifest end

-- the manifest hash a retained segment snapshotted at its keyframe, for the
-- segment containing frame f — resident, demoted, or adopted cross-session (it
-- rides the skeleton, so this never loads a blob). nil = a legacy/no-manifest
-- segment (the packaging packet marks those un-materializable).
function M.manifest_at(f)
  local R = M._R
  if not R then return nil end
  f = math.floor(f)
  for _, s in ipairs(R.segs) do
    if f >= s.first and f < s.first + s.frames then return s.manifest_hash end
  end
  return nil
end

-- raw bytes of a stored blob (file version or manifest), or nil if absent
function M.blob_get(hash)
  local R = M._R
  if not R or not hash then return nil end
  return pal.read_file(blob_path(R, hash))
end

-- decode a stored manifest blob into { relpath -> blob hex }, or nil
function M.manifest_files(hash)
  local blob = M.blob_get(hash)
  if not blob then return nil end
  local ok, paths = pcall(manifest_decode, blob)
  return ok and paths or nil
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
  -- Recorder paused (A7 retention surface): the game keeps running and
  -- presenting, but the always-on ring stops growing and the live edge holds.
  -- last_frame stays frozen; set_rec_paused reseeds a fresh contiguous stream
  -- on resume (the sim advanced while paused, so history cannot continue).
  if M.ring.rec_paused then return end
  local f = state.frame()
  if f ~= R.last_frame + 1 then
    pal.log(("[trace] sim frame %d after %d: out-of-band restore, ring reset")
            :format(f, R.last_frame))
    M.ring_reset() -- reseeds from live (post-frame) state; resumes next frame
    return
  end
  state.capture_runtime()
  local seg = R.segs[#R.segs]
  -- ring_flush may have checkpointed this still-open segment for a contained
  -- error. A successful hot-reload resume appends to the same in-memory
  -- generation and atomically replaces that checkpoint when it closes.
  if seg.spilling then M.history_drain() end
  if seg.spilled then seg.spilled = nil end
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
  -- record the doc only when it CHANGED. Re-canon() every frame dominated the
  -- recorder (~100us — the doc's static config re-serializes otherwise), so
  -- hash first (a cheap traversal) and canon only when it moves. R.prev_doc
  -- stays current either way (an unchanged hash == an unchanged doc), so the
  -- keyframe capture that reads R.prev_doc is still correct.
  local dh = state.doc_hash()
  if dh == R.prev_doc_hash then
    parts[#parts + 1] = "\0"
  else
    local doc = state.doc_bytes()
    if doc == R.prev_doc then
      parts[#parts + 1] = "\0"
    else
      parts[#parts + 1] = "\1" .. pack("<s4", doc)
      R.prev_doc = doc
    end
    R.prev_doc_hash = dh
  end
  seg_append(seg, "FRAM", table.concat(parts))
  -- the editor stream (R6a): one EDOC after this frame's FRAM when the
  -- ed doc changed; readers that don't know the tag skip it (cm.chunk)
  local ec = ed_canon(R)
  if ec ~= R.prev_edoc then
    R.prev_edoc = ec
    seg_append(seg, "EDOC", "\1" .. pack("<s4", ec))
  end
  seg.frames = seg.frames + 1
  R.last_frame = f

  if seg.frames >= ring_kf() then
    open_segment(R, f + 1) -- eager close: its keyframe = state after f
    spill_seg(R, seg) -- the closed one streams to disk (R6b; no-op off)
    evict(R)
  end
end

-- Observer hooks for the render/dev phase (not the sim step). Both append a
-- tiny chunk to the open segment so the activity/event lanes see project-file
-- and lifecycle events; both are ignored by state reconstruction and the
-- determinism verifier, so they never touch a replay's bytes. No-ops without
-- a live ring (headless/CI never records these).

-- An editor asset save. nbytes is the published source size (files activity);
-- the bytes themselves belong to the later blob/manifest packet.
function M.note_save(path, nbytes)
  local R = M._R
  if not R or #R.segs == 0 then return end
  local seg = R.segs[#R.segs]
  seg_append(seg, "FSAV",
    pack("<s4I4", tostring(path or ""), math.max(0, math.floor(nbytes or 0))))
  seg.summary = nil
  R.manifest_dirty = true -- §14: fold the saved bytes into the project manifest
end

-- An editor asset IMPORT (a file brought in from outside — the sound/preset
-- import doors): same files-activity shape as a save, its own timeline bit so
-- the tray distinguishes "brought in" from "authored here" (the A7 marker).
function M.note_import(path, nbytes)
  local R = M._R
  if not R or #R.segs == 0 then return end
  local seg = R.segs[#R.segs]
  seg_append(seg, "FIMP",
    pack("<s4I4", tostring(path or ""), math.max(0, math.floor(nbytes or 0))))
  seg.summary = nil
  R.manifest_dirty = true
end

-- The project tree changed on disk (an editor save, import, delete, or observed
-- external edit) — the next render-phase manifest_pump re-walks and stores it.
-- Cheap and idempotent; the actual (I/O-bearing) work is deferred out of the
-- sim step, exactly like history spill.
function M.mark_project_dirty()
  if M._R then M._R.manifest_dirty = true end
end

-- A lifecycle event bit (M.timeline_event.ERROR / .RESTART) at the current
-- frame. INPUT/CODE/EVAL/SAVE/SESSION derive from other chunks; this carries
-- the ones with no state footprint of their own.
function M.note_event(bit)
  local R = M._R
  if not R or #R.segs == 0 then return end
  bit = math.floor(bit or 0)
  if bit == 0 then return end
  local seg = R.segs[#R.segs]
  seg_append(seg, "MARK", pack("<I4", bit))
  seg.summary = nil
end

-- Store one presented-frame preview for the current recorded frame. `rgba` is a
-- tightly-packed w*h*4 image (the game FOV, from pal.read_pixels). Pure of the
-- GPU so the selftest drives it with synthetic pixels. The preview is attached
-- to the open segment: the in-RAM seg.thumb index the tray draws from, plus a
-- durable THMB chunk (frame,w,h,png) that rides the blob on spill.
function M.thumb_capture(rgba, w, h)
  local R = M._R
  if not R or #R.segs == 0 then return end
  w, h = math.floor(w or 0), math.floor(h or 0)
  if w < 1 or h < 1 or #rgba < w * h * 4 then return end
  local dw, dh = thumb_dims(w, h)
  local png = pal.png_encode(downscale_rgba(rgba, w, h, dw, dh), dw, dh)
  local frame = R.last_frame or (R.segs[#R.segs].first - 1)
  local seg = R.segs[#R.segs]
  seg.thumb = { frame = frame, w = dw, h = dh, png = png }
  if seg.chunks then
    seg_append(seg, "THMB", pack("<I4I4I4", frame, dw, dh) .. png)
  end
  return seg.thumb
end

-- Render/dev tick hook: capture a preview about every M.thumb_period recorded
-- frames. Gated on M.ring.thumbs — set for live windowed sessions exactly like
-- spill, and off headless/CI/capped — so goldens, traces, and --frames runs
-- never read a pixel or carry a THMB. It rides its own flag rather than spill so
-- previews are a RAM-index feature independent of whether history hits disk.
-- A read/encode failure just advances the cadence and logs; previews are chrome.
function M.thumb_pump()
  local R = M._R
  if not R or not M.ring.thumbs then return end
  local f = R.last_frame
  if not f then return end
  local period = math.max(1, math.floor(M.thumb_period or 3600))
  if R.thumb_next == nil then R.thumb_next = f end -- first eligible tick captures
  if f < R.thumb_next then return end
  local ok, err = pcall(function()
    M.thumb_capture(pal.read_pixels(), pal.gfx_size())
  end)
  if not ok then pal.log("[trace] preview capture failed: " .. tostring(err)) end
  R.thumb_next = f + period
  while R.thumb_next <= f do R.thumb_next = R.thumb_next + period end
end

-- Render/dev tick hook (A7 §14): fold on-disk project changes into the manifest
-- when something marked it dirty. Deferred out of record_frame so the sim step
-- never walks/hashes/writes; the manifest a segment carries is therefore its
-- keyframe-granular tree, caught up within a frame of the save. Best-effort:
-- a failed walk keeps the previous manifest and logs. No-op without spill.
function M.manifest_pump()
  local R = M._R
  if not R or not R.manifest_dirty then return end
  if not M.ring.spill or R.project == "" then R.manifest_dirty = nil; return end
  R.manifest_dirty = nil
  local ok, err = pcall(refresh_manifest, R)
  if not ok then pal.log("[trace] project manifest update failed: " ..
                         tostring(err)) end
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
  R.manifest_dirty = true -- reloaded code came from disk; refresh the manifest
  pal.log("[trace] code epoch: " .. table.concat(names, ", "))
end

-- Standalone-clip packaging (A7 §14): gather the project manifest at A plus
-- every file version any segment in [first_i,last_i] references, read from the
-- content-addressed store. Returns nil when the opening keyframe has no manifest
-- (legacy / spill-off history) — the caller names that missing capability rather
-- than writing a clip that cannot materialize its own project. The manifest is
-- itself content-addressed, so its blob doubles as the MFST payload the loader
-- decodes without needing the store.
local function collect_clip(R, first_i, last_i)
  local mh = R.segs[first_i].manifest_hash
  if not mh then return nil end
  local mfst = M.blob_get(mh)
  if not mfst then return nil end
  local want, order = {}, {}
  local function want_blob(hash)
    if hash and not want[hash] then want[hash] = true; order[#order + 1] = hash end
  end
  -- §14 keyframe granularity: union the blobs each in-range segment's manifest
  -- names, so a file saved mid-range ships every version needed through B.
  for i = first_i, last_i do
    local files = M.manifest_files(R.segs[i].manifest_hash)
    if files then for _, h in pairs(files) do want_blob(h) end end
  end
  local blobs = {}
  for _, h in ipairs(order) do
    local bytes = M.blob_get(h)
    if bytes then blobs[#blobs + 1] = { hash = h, bytes = bytes } end
  end
  return mfst, blobs
end

-- The module name a project-relative .lua path loads under, mirroring boot.lua's
-- module_path in reverse: "main.lua" -> "main", "player/weapons.lua" ->
-- "player.weapons", the special "project.lua" -> "@project". Returns nil for a
-- non-.lua file, an illegal module name, or a "cm.*" name (those resolve to the
-- engine dir, never the project — such a file could never be a project module).
local function mod_name_of_rel(rel)
  if rel == "project.lua" then return "@project" end
  local base = rel:match("^(.+)%.lua$")
  if not base then return nil end
  local name = base:gsub("/", ".")
  if name == "" or name:find("[^%w_%.%-]") or name:find("%.%.", 1, true)
     or name:sub(1, 1) == "." or name:sub(-1) == "." or name:sub(1, 3) == "cm." then
    return nil
  end
  return name
end

-- Reconstruct a cm.modules()-shaped code bundle for an adopted (no-bundle)
-- segment (A7 §14): the adopted session's live code bundle was never spilled, but
-- its project manifest froze every project .lua source at the keyframe, and the
-- engine cm.* modules are this same install. Project sources come from the
-- content-addressed store (the frozen tree the manifest names — never the current
-- disk, which may have been edited since); engine modules (@boot + cm.*) come from
-- the running session, exactly as browsing adopted history already uses the
-- current engine (REWIND.md §3). Returns a name-sorted bundle, or nil when the
-- manifest / its blobs are gone (evicted) so the caller names that honestly.
local function reconstruct_bundle(R, seg)
  local mh = seg.manifest_hash
  if not mh then return nil end
  local files = M.manifest_files(mh)
  if not files then return nil end
  local by_name = {}
  -- project side: every manifest .lua that maps to a legal project module name,
  -- carried at its CAPTURED source (from the store, not disk).
  for rel, hash in pairs(files) do
    local name = mod_name_of_rel(rel)
    if name then
      local source = M.blob_get(hash)
      if source then
        by_name[name] = { name = name, path = R.project .. "/" .. rel,
                          source = source }
      end
    end
  end
  -- engine side: @boot + cm.* from this install (the adopted engine was never
  -- captured; @project stays whatever the manifest named, never the running one).
  for _, m in ipairs(cm.modules()) do
    if m.name == "@boot" or m.name:sub(1, 3) == "cm." then
      by_name[m.name] = { name = m.name, path = m.path, source = m.source }
    end
  end
  local names = {}
  for n in pairs(by_name) do names[#names + 1] = n end
  if #names == 0 then return nil end
  table.sort(names) -- deterministic SNAP bytes (cm.modules() is name-sorted too)
  local out = {}
  for i, n in ipairs(names) do out[i] = by_name[n] end
  return out
end

-- serialize segments first_i..last_i into a CTRC blob (no I/O). `standalone`
-- (a { a, b } loop-bounds table) additionally embeds the clip's complete project
-- tree so it materializes on load with no dependency on this session's store; its
-- optional `bundle` overrides the SNAP code (an adopted range's reconstruction).
-- Split out of write_trace so a crash report can embed the same bytes in memory.
local function build_trace_blob(project, kf, first_i, last_i, standalone)
  local R = M._R
  last_i = last_i or #R.segs
  local w = chunk.writer("CTRC")
  local names = input.actions()
  local head = { pack("<I4s4I4", kf, project, #names) }
  for _, n in ipairs(names) do head[#head + 1] = pack("<s4", n) end
  w.chunk("HEAD", 1, table.concat(head))
  local s1 = seg_load(R, R.segs[first_i]) -- spilled segments materialize
  -- SNAP code: the segment's own live bundle, or (adopted range) the caller's
  -- reconstruction. Plain/live paths pass no override, so their bytes are
  -- byte-identical to before (goldens hold).
  local snap_bundle = (standalone and standalone.bundle) or s1.bundle
  w.chunk("SNAP", 1, state.encode_snapshot(s1.kf_bufs, s1.kf_doct, snap_bundle))
  local frames = 0
  for i = first_i, last_i do
    local s = seg_load(R, R.segs[i])
    if i > first_i then
      w.chunk("KEYF", 1, state.encode_snapshot(s.kf_bufs, s.kf_doct))
    end
    -- FSAV/FIMP/MARK/THMB/PMAN are history chrome (activity, lifecycle,
    -- previews, the project-manifest hash), not replay state; a standalone
    -- clip carries its tree through the MFST/BLOB chunks below instead, so a
    -- plain export stays byte-identical to before (goldens hold).
    for _, c in ipairs(s.chunks) do
      if c.tag ~= "FSAV" and c.tag ~= "FIMP" and c.tag ~= "MARK"
         and c.tag ~= "THMB" and c.tag ~= "PMAN" then
        w.chunk(c.tag, 1, c.payload)
      end
    end
    frames = frames + s.frames
  end
  w.chunk("TAIL", 1, pack("<I4", frames))
  if standalone then
    -- A7 §14: MFST = the project tree at A ({ relpath -> blob }); one BLOB per
    -- referenced file version (content-addressed, so already deduped); LOOP =
    -- the intended A/B bounds so loading reopens on the same range and loop.
    local mfst, blobs = collect_clip(R, first_i, last_i)
    if mfst then
      w.chunk("MFST", 1, mfst)
      for _, e in ipairs(blobs) do
        w.chunk("BLOB", 1, pack("<s4s4", e.hash, e.bytes))
      end
      if standalone.a then
        w.chunk("LOOP", 1, pack("<I4I4", standalone.a, standalone.b))
      end
    end
  end
  return w.result(), frames
end

-- serialize a range as a CTRC blob and write it atomically. A7 §13 trust: a trace
-- this session wrote is this session's own code, so dragging it back in never
-- prompts (the trust set is seeded below).
local function write_trace(path, project, kf, first_i, last_i, standalone)
  local blob, frames = build_trace_blob(project, kf, first_i, last_i, standalone)
  local ok, err = pal.write_file_atomic(path, blob,
                         M._write_fail and M._write_fail.trace)
  pal.log(("[trace] wrote %s: %d frames, %d bytes%s")
          :format(path, frames, #blob,
                  ok and "" or " (WRITE FAILED: " .. tostring(err) .. ")"))
  if ok then M._trust_written(blob) end
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

-- "save what just happened": everything the ring still holds. Adopted
-- segments (R6.5) are skipped — a CTRC needs a code bundle for its SNAP
-- and theirs was never spilled; the export covers this session's span.
function M.ring_export(path)
  local R = M._R
  if not R or #R.segs == 0 then error("ring empty", 2) end
  local first_i = 1
  while R.segs[first_i] and not R.segs[first_i].bundle do
    first_i = first_i + 1
  end
  if not R.segs[first_i] then
    error("ring holds only adopted history (nothing exportable)", 2)
  end
  return write_trace(path, R.project, ring_kf(), first_i)
end

-- Segment-align an inclusive A..B live range for a standalone clip: clamp into
-- the retained window, find the covering segments, and (for an adopted range with
-- no spilled bundle) reconstruct the SNAP code. Returns { first_i, last_i, a, b,
-- bundle } or nil + an honest reason (legacy/spill-off history, evicted blobs).
-- Shared by export_clip (writes a file) and crash_tail_bytes (embeds in memory).
local function resolve_clip_range(a, b)
  local R = M._R
  local lo, hi = M.ring_range()
  if not lo then return nil, "no history to export" end
  a = math.max(lo, math.min(math.floor(a + 0.5), hi))
  b = math.max(lo, math.min(math.floor(b + 0.5), hi))
  if b < a then a, b = b, a end
  local first_i, last_i = 1, #R.segs
  for i = 1, #R.segs do -- segments ascend by first, so the last <= wins
    if R.segs[i].first <= a then first_i = i end
    if R.segs[i].first <= b then last_i = i end
  end
  local aseg = R.segs[first_i]
  -- a clip is always standalone, so it always needs the project manifest —
  -- legacy pre-A7 / spill-off history has none and cannot produce one.
  if not aseg.manifest_hash then
    return nil, "legacy history has no project manifest — record under A7 to " ..
      "export a standalone clip"
  end
  local recon
  if not aseg.bundle then
    -- adopted cross-session range: the live code bundle was never spilled;
    -- rebuild the SNAP code from the captured tree + the host engine.
    recon = reconstruct_bundle(R, aseg)
    if not recon then
      return nil, "adopted range: its project code blobs were evicted from the " ..
        "store — cannot reconstruct the clip's code"
    end
  end
  return { first_i = first_i, last_i = last_i, a = a, b = b, bundle = recon }
end

-- Export the inclusive A..B range as a STANDALONE .ctrace (A7 §14): the exact
-- state through B plus the complete project tree (all source + assets) at A, so
-- the clip materializes its own project on load with no dependency on this
-- session's blob store. Segment-aligned: the SNAP is A's keyframe and whole
-- segments through B's are written (the LOOP metadata pins the exact A/B).
-- Returns ok, frames | nil, reason. A live range uses its own segment bundle; an
-- adopted cross-session range (no spilled bundle) reconstructs one from its
-- captured manifest + the host engine. Only legacy pre-manifest history — or a
-- store whose blobs were evicted — still refuses, named honestly, never crashed.
function M.export_clip(a, b, path)
  local pl, why = resolve_clip_range(a, b)
  if not pl then return nil, why end
  return write_trace(path, M._R.project, ring_kf(), pl.first_i, pl.last_i,
                     { a = pl.a, b = pl.b, bundle = pl.bundle })
end

-- A7 §16: the safe pre-roll ending at the crash's last committed frame, packed as
-- a self-contained standalone-clip blob (the same bytes export_clip writes, but in
-- memory). A .ccrash embeds this so a report opened on ANOTHER machine — or after
-- the local tail is evicted — still carries its timeline; the drop stages it and
-- opens it through the trust-gated clip door. Best-effort: nil + reason for
-- legacy/spill-off/adopted-evicted history (the drop then falls back to the
-- local-stream match). `preroll` defaults to CRASH_PREROLL (up to one minute).
function M.crash_tail_bytes(committed, preroll)
  local lo, hi = M.ring_range()
  if not lo then return nil, "no history to embed" end
  committed = math.max(lo, math.min(math.floor(committed or hi), hi))
  preroll = math.max(1, math.floor(preroll or M.CRASH_PREROLL))
  local pl, why = resolve_clip_range(math.max(lo, committed - preroll + 1),
                                     committed)
  if not pl then return nil, why end
  local blob, frames = build_trace_blob(M._R.project, ring_kf(),
    pl.first_i, pl.last_i, { a = pl.a, b = pl.b, bundle = pl.bundle })
  M._trust_written(blob) -- our own code this session: a self-drop never prompts
  return blob, frames
end

-- Quit/crash durability boundary (R6.5/D067): spill the open segment so the
-- session tail joins the cross-session stream (closed segments already
-- spilled). The boolean proves that the active stream's exact tail is now
-- readable from disk; crash reports omit the locator when it is false.
function M.ring_flush()
  local R = M._R
  if not R then return false end
  local seg = R.segs[#R.segs]
  if seg and not seg.spilled and not seg.spilling and seg.frames > 0 then
    spill_seg(R, seg)
  end
  if not M.history_drain() then return false end
  if not R.stream_id or R.stream_id == "" then return false end
  local _, hi = M.ring_range()
  local disk = M.hist_locator(R.project)
  return disk ~= nil and disk.stream == R.stream_id and disk.frame == hi
end

-- ---- standalone-clip materialization (A7 §14) ----
--
-- A standalone clip carries its complete project tree (MFST + BLOBs). On load
-- that tree is written into an isolated, ephemeral REPLAY WORKSPACE — a fixed
-- per-user directory well outside any project, so a replay's browsable source
-- can never touch a real project and the editor's parked write wall keeps its
-- own experiments ephemeral. The workspace is named by the manifest's content
-- hash, so identical clips share one and distinct clips never collide.

-- overridable for tests via M._workspace_root; else a fixed per-user root
local function workspace_root()
  if M._workspace_root then return M._workspace_root end
  if type(pal.user_path) ~= "function" then return nil end
  local base = pal.user_path()
  return base and (base .. "replay-workspaces")
end

-- best-effort recursive removal (list is parent-then-children; reverse empties
-- directories before removing them). Used to keep at most one workspace around.
local function remove_tree_at(root)
  if not root or not pal.mtime(root) then return end
  local names = pal.x_list_dir_all and pal.x_list_dir_all(root)
                or pal.list_dir(root) or {}
  for i = #names, 1, -1 do pal.x_remove(root .. "/" .. names[i]) end
  pal.x_remove(root)
end

-- write the clip's manifest tree into a fresh workspace and return its path (nil
-- if no per-user root). Sweeps sibling workspaces first so a replay session
-- leaves at most one behind. A blob a partial clip omitted is skipped honestly.
local function materialize_workspace(mfst_bytes, blobmap)
  local root = workspace_root()
  if not root then return nil end
  local id = pal.sha256(mfst_bytes)
  local ws = root .. "/" .. id
  pal.mkdir(root)
  for _, n in ipairs(pal.list_dir(root) or {}) do
    local top = n:match("^[^/]+")
    if top and top ~= id then remove_tree_at(root .. "/" .. top) end
  end
  remove_tree_at(ws) -- drop a stale/partial workspace of the same id
  pal.mkdir(ws)
  local paths = manifest_decode(mfst_bytes)
  local rels = {}
  for rel in pairs(paths) do rels[#rels + 1] = rel end
  table.sort(rels)
  local written, missing = 0, 0
  for _, rel in ipairs(rels) do
    local bytes = blobmap[paths[rel]]
    if bytes then
      local dir = rel:match("^(.*)/[^/]+$")
      if dir then pal.mkdir(ws .. "/" .. dir) end
      if pal.write_file(ws .. "/" .. rel, bytes) then written = written + 1 end
    else
      missing = missing + 1
    end
  end
  pal.log(("[trace] replay workspace: %s (%d files%s)"):format(ws, written,
          missing > 0 and (", %d unmaterializable"):format(missing) or ""))
  return ws
end

-- overridable for tests via M._crash_tail_root; else a per-user sibling of the
-- replay workspaces.
local function crash_tail_root()
  if M._crash_tail_root then return M._crash_tail_root end
  if type(pal.user_path) ~= "function" then return nil end
  local base = pal.user_path()
  return base and (base .. "crash-tails")
end

-- A7 §16: stage a crash report's embedded history tail (standalone-clip bytes) as
-- a .ctrace file so the SAME trust-gated clip door (clip_code_hash / open_clip)
-- opens it exactly like a dragged-in replay. Content-named + swept so at most one
-- staged tail survives. nil + reason if there is no tail or no per-user root.
function M.write_crash_tail(bytes)
  if type(bytes) ~= "string" or bytes == "" then
    return nil, "the crash report embeds no history tail"
  end
  local root = crash_tail_root()
  if not root then return nil, "no per-user path to stage the crash tail" end
  local name = pal.sha256(bytes) .. ".ctrace"
  pal.mkdir(root)
  for _, n in ipairs(pal.list_dir(root) or {}) do
    local top = n:match("^[^/]+")
    if top and top ~= name then remove_tree_at(root .. "/" .. top) end
  end
  local path = root .. "/" .. name
  local ok, err = pal.write_file_atomic(path, bytes)
  if not ok then
    return nil, "staging the crash tail failed: " .. tostring(err)
  end
  return path
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
  M.history_drain()
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
  local blobmap, mfst_bytes, loop_a, loop_b = {}, nil, nil, nil -- §14 standalone
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
    elseif c.tag == "MFST" and c.version == 1 then
      mfst_bytes = c.payload -- the project tree at A (§14 standalone clip)
    elseif c.tag == "BLOB" and c.version == 1 then
      local h, bytes = unpack("<s4s4", c.payload)
      blobmap[h] = bytes
    elseif c.tag == "LOOP" and c.version == 1 then
      loop_a, loop_b = unpack("<I4I4", c.payload)
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
  R.stream_id = "" -- a foreign/destructive v1 replay is not live history
  R.next_id = #segs + 1
  R.last_frame = f0 + frames -- the loaded newest; exits rewind to rebase
  R.prev, R.prev_doc, R.prev_doc_hash = {}, nil, nil
  R.manifest, R.manifest_hash, R.manifest_dirty = nil, nil, nil -- foreign tree
  -- §14: materialize the clip's bundled project tree into an ephemeral, isolated
  -- workspace (a legacy/partial clip with no MFST simply has none). The A/B loop
  -- the clip recorded rides alongside so the caller can reopen on the same range.
  if R.workspace then remove_tree_at(R.workspace) end
  R.workspace, R.replay_loop = nil, nil
  if mfst_bytes then
    local ok, ws = pcall(materialize_workspace, mfst_bytes, blobmap)
    if ok then R.workspace = ws
    else pal.log("[trace] replay workspace failed: " .. tostring(ws)) end
  end
  if loop_a then R.replay_loop = { a = loop_a, b = loop_b } end
  M._R = R
  pal.log(("[trace] replay loaded: %s (%d frames)"):format(path, frames))
  return f0, f0 + frames
end

-- the loaded standalone clip's materialized project tree (A7 §14), or nil for a
-- legacy / non-standalone replay. The drag-in editor mount browses this.
function M.replay_workspace() return M._R and M._R.workspace end

-- the A/B loop bounds a standalone clip recorded ({ a, b }), or nil
function M.replay_loop() return M._R and M._R.replay_loop end

-- Read a standalone clip and materialize its bundled project tree into a replay
-- workspace WITHOUT touching the live ring or state (A7 §14) — the drag-in
-- preview primitive and what a round-trip test exercises. Shares ring_load's
-- materialize core. Returns workspace, { a, b } | nil, reason.
function M.materialize_clip(path)
  local blob, err = pal.read_file(path)
  if not blob then return nil, "can't read clip: " .. tostring(err) end
  local mfst_bytes, loop, blobmap = nil, nil, {}
  for _, c in ipairs(chunk.read(blob, "CTRC")) do
    if c.tag == "MFST" and c.version == 1 then
      mfst_bytes = c.payload
    elseif c.tag == "BLOB" and c.version == 1 then
      local h, bytes = unpack("<s4s4", c.payload); blobmap[h] = bytes
    elseif c.tag == "LOOP" and c.version == 1 then
      local a, b = unpack("<I4I4", c.payload); loop = { a = a, b = b }
    end
  end
  if not mfst_bytes then return nil, "not a standalone clip (no project tree)" end
  local ws = materialize_workspace(mfst_bytes, blobmap)
  if not ws then return nil, "no per-user workspace root available" end
  return ws, loop
end

-- ---- clip trust identity (A7 §13) ----
--
-- Opening a replay executes its bundled code with the same trust boundary as
-- opening a project, and §13 requires the UI to SAY SO before running an
-- untrusted (dragged-in / downloaded) bundle. Identity is the code a replay of
-- the clip can ever execute — the SNAP bundle plus every EPOC revision, in
-- file order, hashed over module name + source only (recorded paths are
-- machine-local noise) — computed without executing anything. The session
-- trust set is transient chrome policy: never persisted, never near
-- sim/doc/buffers, seeded by write_trace (a trace this session wrote is this
-- session's own code, so a same-session self-export never prompts) and grown
-- only by an explicit user confirm at the drag-in door.

local trusted_clips = {}

-- the code-identity core over an in-memory CTRC blob; nil, reason when the
-- bytes cannot be a replay at all (bad container / no SNAP / no bundle).
local function code_hash_of_blob(blob)
  local ok, chunks = pcall(chunk.read, blob, "CTRC")
  if not ok then return nil, "not a .ctrace: " .. tostring(chunks) end
  local parts, seen_snap = {}, false
  for _, c in ipairs(chunks) do
    if c.tag == "SNAP" and c.version == 1 and not seen_snap then
      seen_snap = true
      local s = state.parse_snapshot(c.payload)
      if not s.code then return nil, "trace SNAP has no code bundle" end
      for _, fl in ipairs(s.code) do
        parts[#parts + 1] = pack("<s4s4", fl.name, fl.source)
      end
    elseif c.tag == "EPOC" and c.version == 1 and seen_snap then
      local n, pos = unpack("<I4", c.payload)
      for _ = 1, n do
        local name, _fpath, source
        name, _fpath, source, pos = unpack("<s4s4s4", c.payload, pos)
        parts[#parts + 1] = pack("<s4s4", name, source)
      end
    end
  end
  if not seen_snap then return nil, "trace has no SNAP chunk" end
  return pal.sha256(table.concat(parts))
end

-- sha256 identity of every byte of code a replay of this clip can execute,
-- or nil, reason. Reads the file; runs nothing.
function M.clip_code_hash(path)
  local blob, err = pal.read_file(path)
  if not blob then return nil, "can't read clip: " .. tostring(err) end
  return code_hash_of_blob(blob)
end

function M.clip_trusted(hash)
  return hash ~= nil and trusted_clips[hash] == true
end

function M.trust_clip(hash)
  if hash then trusted_clips[hash] = true end
end

-- test seam: forget every session trust (a fresh process starts empty)
function M._trust_reset() trusted_clips = {} end

-- write_trace calls this with the blob it just wrote: this session's own code
-- is trusted by construction. Never an error path — trust is best-effort
-- chrome (a failed hash only means a prompt later).
function M._trust_written(blob)
  local h = code_hash_of_blob(blob)
  if h then trusted_clips[h] = true end
end

-- ---- non-destructive foreign-source open (A7 §13) ----
--
-- The product UI opens a replay clip WITHOUT adopting its timeline: the live
-- ring is stashed intact, a fresh ring receives the clip's destructive load,
-- and dismissal restores the stashed ring byte-for-byte. This is the coarse
-- form of §13's "stash the live source object" — one table swap rather than a
-- polymorphic source interface. The live ring's on-disk segment/blob files are
-- never touched while stashed: recording is dormant (the sim is frozen/parked),
-- so nothing spills, evicts, or gc's meanwhile.

function M.has_stash() return M._stashed_live ~= nil end

-- Stash the live ring so a foreign clip can load into a fresh one. Drains any
-- pending native spill for the live ring first (its files must be complete
-- before we stop touching them), then clears M._R so ring_load builds fresh
-- instead of clobbering the stash. Refuses to double-stash.
function M.stash_live()
  if M._stashed_live then return nil, "a foreign source is already open" end
  M.history_drain()
  M._stashed_live = M._R or false -- false marks "was nil" (still restorable)
  M._R = nil
  return true
end

-- Restore the stashed live ring, discarding the replay ring and its ephemeral
-- workspace tree. The caller restores the live present state/editor doc/root
-- separately (cm.scrub.close_clip); this owns only the ring swap + workspace
-- sweep. Refuses when nothing is stashed.
function M.restore_live()
  if not M._stashed_live then return nil, "no stashed live ring" end
  local replay = M._R
  if replay and replay.workspace then remove_tree_at(replay.workspace) end
  M._R = M._stashed_live or nil -- the false sentinel restores to nil
  M._stashed_live = nil
  return true
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

-- Summarize a retained interval into max-per-bin activity and event bits for
-- the product timeline. Resident segments render exactly from their chunk
-- streams; demoted, spilled, and adopted cross-session segments render coarsely
-- from their persisted per-segment digest (A7 §12) — drawing the tray never
-- synchronously loads or decodes a history blob. `missing` is set only for
-- pre-A7 legacy segments that carry neither chunks nor a digest, so the UI can
-- label that honest gap. Refining a coarse segment to per-frame detail happens
-- naturally: seeking there materializes its chunks (LRU) and this reads them.
function M.ring_timeline(from_frame, to_frame, bins)
  local R = M._R
  local lo, hi = M.ring_range()
  if not R or not lo then return { data = {}, missing = false } end
  from_frame = math.max(lo, math.floor(from_frame))
  to_frame = math.min(hi, math.ceil(to_frame))
  if to_frame < from_frame then from_frame, to_frame = to_frame, from_frame end
  bins = math.max(1, math.floor(bins or 1))
  local data = {}
  for i = 1, bins do
    data[i] = { sim = 0, editor = 0, files = 0, events = 0 }
  end
  local span = math.max(1, to_frame - from_frame)
  local function bucket(f)
    if f < from_frame or f > to_frame then return nil end
    return math.min(bins,
      math.floor((f - from_frame) / span * bins) + 1)
  end
  local function event(f, bit)
    local bi = bucket(f)
    if bi then data[bi].events = data[bi].events | bit end
  end
  local function bump(bi, key, n)
    if bi and n > data[bi][key] then data[bi][key] = n end
  end

  local missing = false
  local last_input
  local prior_adopted
  local E = M.timeline_event
  for _, seg in ipairs(R.segs) do
    local sf, sl = seg.first - 1, seg.first + seg.frames - 1
    local adopted = seg.adopted == true
    if prior_adopted ~= nil and prior_adopted ~= adopted then
      event(seg.first - 1, E.SESSION)
    end
    prior_adopted = adopted
    if sl >= from_frame and sf <= to_frame then
      if seg.chunks then
        local frame = seg.first - 1
        local pending = 0
        for _, c in ipairs(seg.chunks) do
          if c.tag == "EVAL" then
            pending = pending | E.EVAL
          elseif c.tag == "EPOC" then
            event(frame, E.CODE)
            bump(bucket(frame), "files", epoc_bytes(c.payload))
          elseif c.tag == "FRAM" then
            frame = frame + 1
            local sim, ikey = timeline_fram(c.payload)
            local bi = bucket(frame)
            if bi then
              bump(bi, "sim", sim)
              data[bi].events = data[bi].events | pending
            end
            pending = 0
            if last_input and ikey ~= last_input then event(frame, E.INPUT) end
            last_input = ikey
          elseif c.tag == "EDOC" then
            local ok, edoc = pcall(unpack, "<s4", c.payload, 2)
            bump(bucket(frame), "editor", ok and #edoc or 0)
          elseif c.tag == "FSAV" then
            local ok, _, nbytes = pcall(unpack, "<s4I4", c.payload)
            bump(bucket(frame), "files", ok and nbytes or 0)
            event(frame, E.SAVE)
          elseif c.tag == "FIMP" then
            local ok, _, nbytes = pcall(unpack, "<s4I4", c.payload)
            bump(bucket(frame), "files", ok and nbytes or 0)
            event(frame, E.IMPORT)
          elseif c.tag == "MARK" then
            local ok, bit = pcall(unpack, "<I4", c.payload)
            if ok then event(frame, bit) end
          end
        end
      elseif seg.summary then
        -- Coarse: one max per segment. Paint the segment's whole visible width
        -- with its max envelope (we can't claim any bin is quieter) and place
        -- its event bits at the segment's leading visible bin.
        local s = seg.summary
        local b0 = bucket(math.max(from_frame, seg.first))
        local b1 = bucket(math.min(to_frame, sl))
        if b0 and b1 then
          for bi = b0, b1 do
            bump(bi, "sim", s.sim)
            bump(bi, "editor", s.editor)
            bump(bi, "files", s.files)
          end
          data[b0].events = data[b0].events | s.events
        end
        last_input = nil
      else
        missing = true
        last_input = nil
      end
    end
  end
  return { data = data, missing = missing, from = from_frame, to = to_frame }
end

-- The presented-frame previews (seg.thumb) whose frame falls in [from,to],
-- decimated to at most `max`, spread evenly by frame. RAM-index only — it never
-- loads or decodes a history blob, so adopted cross-session segments (which
-- carry no in-RAM preview yet) contribute none while their activity digest
-- still draws. Each entry is the shared { frame, w, h, png } table.
function M.ring_thumbs(from_frame, to_frame, max)
  local R = M._R
  local lo, hi = M.ring_range()
  if not R or not lo then return {} end
  from_frame = math.max(lo, math.floor(from_frame or lo))
  to_frame = math.min(hi, math.ceil(to_frame or hi))
  max = math.max(1, math.floor(max or 1))
  local all = {}
  for _, seg in ipairs(R.segs) do -- segments ascend, so `all` stays frame-sorted
    local t = seg.thumb
    if t and t.frame >= from_frame and t.frame <= to_frame then
      all[#all + 1] = t
    end
  end
  if #all <= max then return all end
  -- Keep the preview nearest each of `max` evenly-spaced frame slots. O(max*n),
  -- and n is tiny (previews are ~1/minute), so this only bites at hour-scale zoom.
  local out, used = {}, {}
  local span = math.max(1, to_frame - from_frame)
  for i = 1, max do
    local target = from_frame + (i - 0.5) / max * span
    local best, bestd
    for j, t in ipairs(all) do
      if not used[j] then
        local d = math.abs(t.frame - target)
        if not bestd or d < bestd then best, bestd = j, d end
      end
    end
    if best then used[best] = true; out[#out + 1] = all[best] end
  end
  table.sort(out, function(a, b) return a.frame < b.frame end)
  return out
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
  local seg = seg_load(R, seg_containing(R, f)) -- spilled segs materialize
  local scratch = {} -- name -> anon view (GC-owned)
  local sizes = {}
  for _, b in ipairs(seg.kf_bufs) do
    local v = pal.buf(nil, #b.bytes)
    v:setstr(0, b.bytes)
    scratch[b.name], sizes[b.name] = v, #b.bytes
  end
  local doct = seg.kf_doct
  local edoc = seg.kf_edoc
  local irec
  local need, done = f - (seg.first - 1), 0
  for _, c in ipairs(seg.chunks) do
    if c.tag == "FRAM" then
      if done >= need then break end
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
    elseif c.tag == "EDOC" and done <= need then
      -- the editor stream (R6a): an EDOC follows its frame's FRAM, so
      -- done == need means "frame f's own change" — included; the next
      -- FRAM breaks the walk
      edoc = unpack("<s4", c.payload, 2)
    end
  end
  local bufs = {}
  for name, v in pairs(scratch) do bufs[name] = v:str(0, sizes[name]) end
  return { frame = f, bufs = bufs, doct = doct, input = irec,
           edoc = edoc ~= "" and edoc or nil }
end

-- ---- rewind (D032) ----

-- restore live state to "after frame f" and truncate the ring there; the
-- caller re-runs game.init() afterwards (the restore contract)
function M.rewind(f)
  local R = M._R or error("ring not started", 2)
  M.history_drain() -- no worker may republish a file after truncation
  if M._rec then
    pal.log("[trace] recording stopped by rewind")
    M.record_stop()
  end
  local st = M.ring_state_at(f) -- validates the range
  local seg, si = seg_containing(R, f)
  seg_load(R, seg)

  -- code as of frame f: the segment bundle + EPOCs that landed before
  -- it. Adopted segments (R6.5) carry NO bundle — their sessions' code
  -- was never spilled — so a resume into one keeps the current code
  -- (browsing/parking never needed the bundle in the first place).
  local need = f - (seg.first - 1)
  local list, diff = {}, false
  local cut = 0
  if seg.bundle then
    local files, order = {}, {}
    for _, m in ipairs(seg.bundle) do
      files[m.name] = { name = m.name, path = m.path, source = m.source }
      order[#order + 1] = m.name
    end
    local done = 0
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
    for _, name in ipairs(order) do
      list[#list + 1] = files[name]
      if cur[name] ~= files[name].source then diff = true end
    end
  else
    pal.log("[trace] resume into adopted history: code as of that frame " ..
            "is unknown — keeping the current code")
    local done = 0
    for ci, c in ipairs(seg.chunks) do
      if c.tag == "FRAM" then
        done = done + 1
        if done == need then cut = ci break end
      end
    end
  end

  state.restore_tables(st.bufs, st.doct)
  if diff then cm.restore_bundle(list) end

  -- truncate the ring after f and rebase the mirrors there. Dropped
  -- segments take their history files with them; the containing one's
  -- file is now stale — remove it and forget the spill (it re-spills if
  -- it ever closes again)
  for i = #R.segs, si + 1, -1 do
    if R.segs[i].file then pal.x_remove(R.segs[i].file) end
    R.segs[i] = nil
  end
  if seg.file then
    pal.x_remove(seg.file)
    seg.file, seg.fbytes, seg.spilled = nil, nil, nil
  end
  R.loaded = nil
  for i = #seg.chunks, cut + 1, -1 do seg.chunks[i] = nil end
  seg.frames = need
  seg.summary = nil -- the kept prefix re-summarizes if it re-spills
  if seg.thumb and seg.thumb.frame > f then seg.thumb = nil end
  R.thumb_next = nil -- re-anchor the preview cadence after the truncation
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
  R.prev_doc_hash = nil -- force a re-hash + compare on the next recorded frame
  R.prev_edoc = st.edoc or "" -- rebase the editor stream at f (R6c);
  R.prev_edrev = nil -- force a re-check on the next recorded frame
  R.last_frame = f
  if seg.frames >= ring_kf() then
    open_segment(R, f + 1)
    spill_seg(R, seg) -- it re-closed full: back to disk — the chain must
                      -- stay gapless for the next boot's adoption (D055)
    M.history_drain() -- structural rewind returns with that chain durable
  end
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
      cm.require("cm.snd").step() -- the sim-step shape (R9b/R9d):
      pal.snd_render()            -- sequencer + render inside the
                                  -- step on record AND verify
      state.advance_frame()
      -- Match record_frame's observation boundary. Engine participants flush
      -- ergonomic Lua handles before live buffers/doc are byte-compared.
      state.capture_runtime()

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
