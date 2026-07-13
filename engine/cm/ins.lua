-- cm.ins — the instrument asset codec (R9c, AUDIO.md §4.1): the CINS
-- chunk container over the kernel's flat 80-byte patch. Pure encode/
-- decode + canonical bytes (the cm.chunk idiom: versioned tagged
-- chunks, unknown tags skipped, KAT'd headless).
--
--   HEAD v1: <s1 name>
--   PTCH v1: the 80-byte packed patch (cm.snd.pack) — the pcm NAME
--            field inside is runtime-only noise; encode canonicalizes
--            it to "" so files never carry session buffer names
--   SPCM v1: sample instruments EMBED their mono i16 @48k PCM (the
--            asset moves with the project — AUDIO.md §4.1)
--
-- doc = { name = "bell", patch = <cm.snd patch table>, pcm = bytes|nil }
--
-- Upload (`M.upload`) is the runtime door: pushes the doc into a bank
-- slot — sample PCM lands in a named buffer first ("snd.pcm/<key>" for
-- the sim bank — sim state by design; "ed.snd.pcm/<key>" for the
-- editor bank — snapshot-invisible by the ed.* domain rule).

local M = select(2, ...) or {}
local chunk = cm.require("cm.chunk")
local snd = cm.require("cm.snd")

M.MAGIC = "CINS"

function M.fresh(name)
  return {
    name = name or "instrument",
    patch = { type = "fm", alg = 0, fb = 0, pan = 0, gain = 128,
              ops = { { wave = "sine", coarse = 1, level = 255,
                        a = 5, d = 120, s = 180, r = 90 },
                      { wave = "sine", coarse = 2, level = 0 },
                      { wave = "sine", coarse = 1, level = 0 },
                      { wave = "sine", coarse = 1, level = 0 } } },
  }
end

function M.encode(doc)
  local w = chunk.writer(M.MAGIC)
  w.chunk("HEAD", 1, string.pack("<s1", doc.name or ""))
  local patch = doc.patch or M.fresh().patch
  local keep = patch.pcm
  patch.pcm = "" -- canonical: files never carry runtime buffer names
  local ok, packed = pcall(snd.pack, patch)
  patch.pcm = keep
  if not ok then error(packed, 0) end
  w.chunk("PTCH", 1, packed)
  if doc.pcm and #doc.pcm > 0 then w.chunk("SPCM", 1, doc.pcm) end
  return w.result()
end

function M.decode(bytes)
  local chunks = chunk.read(bytes, M.MAGIC)
  local doc = { name = "", patch = M.fresh().patch }
  for _, c in ipairs(chunks) do
    if c.tag == "HEAD" and c.version == 1 then
      doc.name = string.unpack("<s1", c.payload)
    elseif c.tag == "PTCH" and c.version == 1 then
      doc.patch = snd.unpack(c.payload)
    elseif c.tag == "SPCM" and c.version == 1 then
      doc.pcm = c.payload
    end
  end
  return doc
end

-- push a doc into a bank slot. bank = "sim" | "ed"; key names the PCM
-- buffer for sample instruments (callers pass something stable — the
-- asset path, a slot id). Returns the patch table it uploaded.
function M.upload(doc, slot, bank, key)
  local patch = doc.patch
  if patch.type == "sample" and doc.pcm and #doc.pcm > 0 then
    local name = (bank == "ed" and "ed.snd.pcm/" or "snd.pcm/")
                 .. tostring(key or slot)
    name = name:sub(1, 24) -- the kernel's fixed name field
    local existing
    for _, info in ipairs(pal.buf_list()) do
      if info.name == name then existing = info end
    end
    if existing and existing.size ~= #doc.pcm then pal.buf_free(name) end
    local buf = pal.buf(name, #doc.pcm)
    buf:setstr(0, doc.pcm)
    patch.pcm = name
  end
  if bank == "ed" then
    snd.ed_patch(slot, patch)
  else
    snd.patch(slot, patch)
  end
  return patch
end

return M
