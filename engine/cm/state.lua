-- cm.state — the sim state model (ARCHITECTURE "State model"):
--
--  * named buffers (C-owned, byte-exact, survive VM reboots) for bulk data;
--  * the doc tree (M.doc): one plain-data Lua table for irregular state —
--    tables/integers/floats/strings/booleans only, integer/string keys only,
--    a tree (no shared subtables), no NaN. Bulk data belongs in buffers.
--
-- The "cm.sim" buffer is the engine's own sim state, layout FROZEN:
--   [0..7]  i64 sim frame counter
--   [8..39] xoshiro256++ s0..s3 (cm.rand)
--   [40..63] reserved (zero)
--
-- A snapshot is a CSNP container (cm.chunk) holding the code bundle (D012),
-- every named buffer, and the canonical doc bytes. Restore writes buffers,
-- repopulates M.doc in place, and re-executes bundle code via
-- cm.restore_bundle — afterwards the caller re-runs game.init(), which must
-- be reload-idempotent (the same contract hot reload already demands).
--
-- Canonical serialization v1, FROZEN: value =
--   0x00 nil | 0x01 false | 0x02 true | 0x03 <i64 LE> integer |
--   0x04 <f64 bits LE> float | 0x05 <u32 len LE><bytes> string |
--   0x06 <u32 n LE> then n key/value pairs, integer keys ascending first,
--        then string keys bytewise ascending
-- Two equal doc trees always produce identical bytes (hash/delta-stable).

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")

M.doc = M.doc or {}

local pack, unpack = string.pack, string.unpack

-- ---- sim buffer ----

local function simbuf()
  return pal.buf("cm.sim", 64)
end

function M.frame()
  return simbuf():i64(0)
end

function M.advance_frame()
  local b = simbuf()
  local f = b:i64(0) + 1
  b:i64(0, f)
  return f
end

-- ---- by-name buffer cell pokes (tools / the inspector's eval unit) ----

-- poke/peek one typed cell of a named buffer, so a buffer edit is a single
-- self-contained command string — cm.tilemap.poke's generic sibling. poke
-- is a sim-state mutation: live tools must route it through cm.repl.submit
-- (the D022 EVAL path) so a recording replays the edit. kind is a view
-- accessor name (u8/i8/u16/i16/u32/i32/i64/f32/f64); a bad kind, an
-- unknown buffer or an OOB offset all error (contained by the repl).
local KINDS = { u8 = true, i8 = true, u16 = true, i16 = true, u32 = true,
                i32 = true, i64 = true, f32 = true, f64 = true }

local function buf_view(name)
  for _, b in ipairs(pal.buf_list()) do
    if b.name == name then return pal.buf(name, b.size) end
  end
  error("no buffer " .. tostring(name), 0)
end

function M.buf_poke(name, kind, off, v)
  if not KINDS[kind] then error("bad kind " .. tostring(kind), 0) end
  local view = buf_view(name)
  view[kind](view, off, v)
end

function M.buf_peek(name, kind, off)
  if not KINDS[kind] then error("bad kind " .. tostring(kind), 0) end
  local view = buf_view(name)
  return view[kind](view, off)
end

-- ---- canonical serializer ----

local function canon_value(v, parts, seen)
  local t = type(v)
  if v == nil then
    parts[#parts + 1] = "\0"
  elseif t == "boolean" then
    parts[#parts + 1] = v and "\2" or "\1"
  elseif t == "number" then
    if math.type(v) == "integer" then
      parts[#parts + 1] = pack("<Bi8", 3, v) -- tag in the format = 1 alloc,
    elseif v ~= v then                        -- not 2 (byte-identical output;
      error("doc tree cannot hold NaN", 0)    -- default alignment is 1, no pad)
    else
      parts[#parts + 1] = pack("<Bd", 4, v)
    end
  elseif t == "string" then
    parts[#parts + 1] = pack("<Bs4", 5, v)
  elseif t == "table" then
    if seen[v] then
      error("doc tree must be a tree: table appears twice", 0)
    end
    seen[v] = true
    local ikeys, skeys = {}, {}
    for k in pairs(v) do
      if math.type(k) == "integer" then
        ikeys[#ikeys + 1] = k
      elseif type(k) == "string" then
        skeys[#skeys + 1] = k
      else
        error("doc key must be integer or string (got " .. type(k) .. ")", 0)
      end
    end
    table.sort(ikeys)
    table.sort(skeys)
    parts[#parts + 1] = pack("<BI4", 6, #ikeys + #skeys)
    for _, k in ipairs(ikeys) do
      parts[#parts + 1] = pack("<Bi8", 3, k)
      canon_value(v[k], parts, seen)
    end
    for _, k in ipairs(skeys) do
      parts[#parts + 1] = pack("<Bs4", 5, k)
      canon_value(v[k], parts, seen)
    end
  else
    error("doc tree cannot hold a " .. t, 0)
  end
end

function M.canon(v)
  local parts = {}
  canon_value(v, parts, {})
  return table.concat(parts)
end

local function parse_value(s, pos)
  local tag = s:byte(pos)
  if tag == nil then error("truncated doc bytes", 0) end
  pos = pos + 1
  if tag == 0 then return nil, pos end
  if tag == 1 then return false, pos end
  if tag == 2 then return true, pos end
  if tag == 3 then return unpack("<i8", s, pos) end
  if tag == 4 then return unpack("<d", s, pos) end
  if tag == 5 then return unpack("<s4", s, pos) end
  if tag == 6 then
    local n
    n, pos = unpack("<I4", s, pos)
    local t = {}
    for _ = 1, n do
      local k, v
      k, pos = parse_value(s, pos)
      v, pos = parse_value(s, pos)
      t[k] = v
    end
    return t, pos
  end
  error("bad doc tag " .. tag, 0)
end

function M.parse(s)
  local v, pos = parse_value(s, 1)
  if pos ~= #s + 1 then error("trailing bytes after doc value", 0) end
  return v
end

function M.doc_bytes()
  return M.canon(M.doc)
end

-- a cheap 64-bit hash of the doc for the recorder's change detection: canon()
-- is ~100us (the doc's static config re-serializes every frame otherwise), so
-- record_frame hashes first and only re-serializes when this moves. Traversal
-- only — no key sort, no per-value string build (pairs() order is stable within
-- a run for an unchanged table, which is all equality-vs-last-frame needs).
-- Integer arithmetic wraps mod 2^64 (Lua 5.4). A 2^-64 collision would mis-skip
-- a doc change; --verify re-executes + byte-compares state, so a real one fails
-- the goldens rather than silently corrupting — safe in practice.
local FNVP = 0x100000001b3
local function hash_value(v, h)
  local t = type(v)
  if t == "number" then
    if math.type(v) == "integer" then
      h = (h ~ v) * FNVP
    else
      h = (h ~ unpack("<i8", pack("<d", v))) * FNVP
    end
  elseif t == "string" then
    h = (h ~ #v) * FNVP
    for i = 1, #v do h = (h ~ v:byte(i)) * FNVP end
  elseif t == "boolean" then
    h = (h ~ (v and 2 or 1)) * FNVP
  elseif t == "table" then
    for k, vv in pairs(v) do h = hash_value(vv, hash_value(k, h)) end
  elseif v == nil then
    h = (h ~ 7) * FNVP
  end
  return h
end

function M.doc_hash()
  return hash_value(M.doc, 0xcbf29ce484222325)
end

-- ---- snapshots ----

local SNAP_MAGIC = "CSNP"

-- the SIM's buffers: name-sorted, excluding the editor domain. Buffer names
-- prefixed "ed." belong to the R3+ editor's captured state (EDITOR.md §2 /
-- D050) — never in sim snapshots, traces or goldens; restore never frees
-- them. cm.trace applies the same filter.
function M.sim_buffer(name)
  return name:sub(1, 3) ~= "ed."
end

local function sorted_buf_list()
  local list = {}
  for _, b in ipairs(pal.buf_list()) do
    if M.sim_buffer(b.name) then list[#list + 1] = b end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- encode a snapshot from captured parts: bufs = name-sorted array of
-- {name, bytes}, doct = canonical doc bytes, code = cm.modules()-shaped
-- array or nil (code-less: trace keyframes). The ring trace (D032) uses
-- this to serialize keyframes it captured from its mirrors; sharing the
-- encoder is what keeps those byte-identical to live snapshots.
function M.encode_snapshot(bufs, doct, code)
  local w = chunk.writer(SNAP_MAGIC)
  if code then
    local parts = {}
    for _, mod in ipairs(code) do
      parts[#parts + 1] = pack("<s4s4s4", mod.name, mod.path, mod.source)
    end
    w.chunk("CODE", 1, pack("<I4", #parts) .. table.concat(parts))
  end
  local bp = {}
  for _, b in ipairs(bufs) do
    bp[#bp + 1] = pack("<s4", b.name) .. pack("<s4", b.bytes)
  end
  w.chunk("BUFS", 1, pack("<I4", #bp) .. table.concat(bp))
  w.chunk("DOCT", 1, doct)
  return w.result()
end

-- opts.code = false omits the bundle (trace keyframes: the trace's starting
-- snapshot + epoch records already pin the code)
function M.snapshot(opts)
  local bufs = {}
  for _, b in ipairs(sorted_buf_list()) do
    local view = pal.buf(b.name, b.size)
    bufs[#bufs + 1] = { name = b.name, bytes = view:str(0, b.size) }
  end
  local code
  if not (opts and opts.code == false) then code = cm.modules() end
  return M.encode_snapshot(bufs, M.doc_bytes(), code)
end

-- decode a snapshot blob: {code = array|nil, bufs = array, doct = string}
function M.parse_snapshot(blob)
  local chunks = chunk.read(blob, SNAP_MAGIC)
  local code, bufs, doct
  for _, c in ipairs(chunks) do
    if c.tag == "CODE" and c.version == 1 then
      code = {}
      local n, pos = unpack("<I4", c.payload)
      for _ = 1, n do
        local name, path, source
        name, path, source, pos = unpack("<s4s4s4", c.payload, pos)
        code[#code + 1] = { name = name, path = path, source = source }
      end
    elseif c.tag == "BUFS" and c.version == 1 then
      bufs = {}
      local n, pos = unpack("<I4", c.payload)
      for _ = 1, n do
        local name, bytes
        name, bytes, pos = unpack("<s4s4", c.payload, pos)
        bufs[#bufs + 1] = { name = name, bytes = bytes }
      end
    elseif c.tag == "DOCT" and c.version == 1 then
      doct = c.payload
    end
    -- unknown tags/versions: skipped on purpose (forward compat)
  end
  if not (bufs and doct) then error("snapshot missing BUFS/DOCT", 0) end
  return { code = code, bufs = bufs, doct = doct }
end

-- the buffer/doc half of restore (no code, no init): write a decoded state
-- back into the live buffers + doc tree. bufs = name -> bytes map. The ring
-- scrubber/rewind (D032) calls this per playhead move — no game code runs.
function M.restore_tables(bufs, doct)
  -- free what the target doesn't have (or has at another size), then write
  for _, b in ipairs(sorted_buf_list()) do
    local want = bufs[b.name]
    if want == nil or #want ~= b.size then pal.buf_free(b.name) end
  end
  local names = {}
  for name in pairs(bufs) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    pal.buf(name, #bufs[name]):setstr(0, bufs[name])
  end

  -- doc: repopulate in place so module references to M.doc stay valid
  local newdoc = M.parse(doct)
  if type(newdoc) ~= "table" then error("doc bytes are not a table", 0) end
  for k in pairs(M.doc) do M.doc[k] = nil end
  for k, v in pairs(newdoc) do M.doc[k] = v end
end

-- restore from a snapshot blob. Does NOT call game.init(); flows that
-- restore (snapshot load, trace verify) re-run init themselves afterwards.
function M.restore(blob)
  local snap = M.parse_snapshot(blob)
  if not snap.code then error("snapshot has no code bundle to restore", 0) end
  local want = {}
  for _, b in ipairs(snap.bufs) do want[b.name] = b.bytes end
  M.restore_tables(want, snap.doct)
  -- code last: re-executes changed modules against the restored state
  cm.restore_bundle(snap.code)
end

function M.save(path)
  return pal.write_file(path, M.snapshot())
end

function M.load(path)
  local blob, err = pal.read_file(path)
  if not blob then error("can't read snapshot " .. path .. ": " .. err, 0) end
  M.restore(blob)
end

return M
