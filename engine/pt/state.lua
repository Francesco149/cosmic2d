-- pt.state — the sim state model (ARCHITECTURE "State model"):
--
--  * named buffers (C-owned, byte-exact, survive VM reboots) for bulk data;
--  * the doc tree (M.doc): one plain-data Lua table for irregular state —
--    tables/integers/floats/strings/booleans only, integer/string keys only,
--    a tree (no shared subtables), no NaN. Bulk data belongs in buffers.
--
-- The "pt.sim" buffer is the engine's own sim state, layout FROZEN:
--   [0..7]  i64 sim frame counter
--   [8..39] xoshiro256++ s0..s3 (pt.rand)
--   [40..63] reserved (zero)
--
-- A snapshot is a PSNP container (pt.chunk) holding the code bundle (D012),
-- every named buffer, and the canonical doc bytes. Restore writes buffers,
-- repopulates M.doc in place, and re-executes bundle code via
-- pt.restore_bundle — afterwards the caller re-runs game.init(), which must
-- be reload-idempotent (the same contract hot reload already demands).
--
-- Canonical serialization v1, FROZEN: value =
--   0x00 nil | 0x01 false | 0x02 true | 0x03 <i64 LE> integer |
--   0x04 <f64 bits LE> float | 0x05 <u32 len LE><bytes> string |
--   0x06 <u32 n LE> then n key/value pairs, integer keys ascending first,
--        then string keys bytewise ascending
-- Two equal doc trees always produce identical bytes (hash/delta-stable).

local M = select(2, ...) or {}
local chunk = pt.require("pt.chunk")

M.doc = M.doc or {}

local pack, unpack = string.pack, string.unpack

-- ---- sim buffer ----

local function simbuf()
  return pal.buf("pt.sim", 64)
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

-- ---- canonical serializer ----

local function canon_value(v, parts, seen)
  local t = type(v)
  if v == nil then
    parts[#parts + 1] = "\0"
  elseif t == "boolean" then
    parts[#parts + 1] = v and "\2" or "\1"
  elseif t == "number" then
    if math.type(v) == "integer" then
      parts[#parts + 1] = "\3" .. pack("<i8", v)
    elseif v ~= v then
      error("doc tree cannot hold NaN", 0)
    else
      parts[#parts + 1] = "\4" .. pack("<d", v)
    end
  elseif t == "string" then
    parts[#parts + 1] = "\5" .. pack("<s4", v)
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
    parts[#parts + 1] = "\6" .. pack("<I4", #ikeys + #skeys)
    for _, k in ipairs(ikeys) do
      parts[#parts + 1] = "\3" .. pack("<i8", k)
      canon_value(v[k], parts, seen)
    end
    for _, k in ipairs(skeys) do
      parts[#parts + 1] = "\5" .. pack("<s4", k)
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

-- ---- snapshots ----

local SNAP_MAGIC = "PSNP"

local function sorted_buf_list()
  local list = pal.buf_list()
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- opts.code = false omits the bundle (trace keyframes: the trace's starting
-- snapshot + epoch records already pin the code)
function M.snapshot(opts)
  local w = chunk.writer(SNAP_MAGIC)

  if not (opts and opts.code == false) then
    local code = {}
    for _, mod in ipairs(pt.modules()) do
      code[#code + 1] = pack("<s4s4s4", mod.name, mod.path, mod.source)
    end
    w.chunk("CODE", 1, pack("<I4", #code) .. table.concat(code))
  end

  local bufs = {}
  for _, b in ipairs(sorted_buf_list()) do
    local view = pal.buf(b.name, b.size)
    bufs[#bufs + 1] = pack("<s4", b.name) .. pack("<s4", view:str(0, b.size))
  end
  w.chunk("BUFS", 1, pack("<I4", #bufs) .. table.concat(bufs))

  w.chunk("DOCT", 1, M.doc_bytes())

  return w.result()
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

-- restore from a snapshot blob. Does NOT call game.init(); flows that
-- restore (snapshot load, trace verify) re-run init themselves afterwards.
function M.restore(blob)
  local snap = M.parse_snapshot(blob)
  local code, bufs, doct = snap.code, snap.bufs, snap.doct
  if not code then error("snapshot has no code bundle to restore", 0) end

  -- buffers: free what the snapshot doesn't have (or has at another size),
  -- then write contents (creating as needed)
  local want = {}
  for _, b in ipairs(bufs) do want[b.name] = b.bytes end
  for _, b in ipairs(sorted_buf_list()) do
    if want[b.name] == nil or #want[b.name] ~= b.size then
      pal.buf_free(b.name)
    end
  end
  for _, b in ipairs(bufs) do
    pal.buf(b.name, #b.bytes):setstr(0, b.bytes)
  end

  -- doc: repopulate in place so module references to M.doc stay valid
  local newdoc = M.parse(doct)
  if type(newdoc) ~= "table" then error("snapshot DOCT is not a table", 0) end
  for k in pairs(M.doc) do M.doc[k] = nil end
  for k, v in pairs(newdoc) do M.doc[k] = v end

  -- code last: re-executes changed modules against the restored state
  pt.restore_bundle(code)
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
