-- pt.chunk — the tagged binary container shared by snapshots (PSNP) and
-- traces (PTRC). Format v1, FROZEN (stability contract rule 5):
--
--   <magic 4cc> then chunks of: <tag 4cc> <u32 version LE> <u32 len LE>
--   <len payload bytes>
--
-- Every chunk is version-stamped; readers skip tags (and versions) they
-- don't know and never guess. All integers little-endian.

local M = {}

local pack, unpack = string.pack, string.unpack

function M.writer(magic)
  assert(#magic == 4, "magic must be a 4cc")
  local parts = { magic }
  local w = {}
  function w.chunk(tag, version, payload)
    assert(#tag == 4, "tag must be a 4cc")
    parts[#parts + 1] = tag .. pack("<I4I4", version, #payload) .. payload
  end
  function w.result()
    return table.concat(parts)
  end
  return w
end

-- parse into an array of {tag=, version=, payload=}; errors on truncation
-- or magic mismatch (a snapshot fed to the trace reader should fail loudly)
function M.read(blob, magic)
  if #blob < 4 or blob:sub(1, 4) ~= magic then
    error("bad container: expected magic " .. magic, 0)
  end
  local chunks = {}
  local pos = 5
  while pos <= #blob do
    if pos + 12 > #blob + 1 then error("truncated chunk header", 0) end
    local tag = blob:sub(pos, pos + 3)
    local version, len
    version, len, pos = unpack("<I4I4", blob, pos + 4)
    if pos + len > #blob + 1 then
      error("truncated chunk payload (" .. tag .. ")", 0)
    end
    chunks[#chunks + 1] =
      { tag = tag, version = version, payload = blob:sub(pos, pos + len - 1) }
    pos = pos + len
  end
  return chunks
end

return M
