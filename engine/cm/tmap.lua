-- cm.tmap — the .tm tilemap object (MAPS.md §2/§8, D057): a pure-visual
-- grid placed on a map like any sprite, moved/z-ordered as one unit. The
-- tileset is a .spr whose FRAMES are the tiles; cell 0 is empty. No
-- collision here ever — collision is collider chains like everything
-- else's (cm.collide). CTLM chunk container, codec pure + canonical:
--
--   HEAD v1: <i4 w cells> <i4 h cells> <I4 tile px> <s4 tileset path>
--   GRID v1: w*h u16 cell ids, row-major (raw string, bulk)
--   TAIL v1: empty

local M = select(2, ...) or {}

local chunk = cm.require("cm.chunk")

local pack, unpack = string.pack, string.unpack
local MAGIC = "CTLM"

-- doc = { w=, h=, tile=, tileset=, cells = <raw u16 string, w*h> }
function M.encode(doc)
  assert(#doc.cells == doc.w * doc.h * 2, "tmap: cells size mismatch")
  local w = chunk.writer(MAGIC)
  w.chunk("HEAD", 1, pack("<i4i4I4s4", doc.w, doc.h, doc.tile,
                          doc.tileset or ""))
  w.chunk("GRID", 1, doc.cells)
  w.chunk("TAIL", 1, "")
  return w.result()
end

function M.decode(bytes)
  local doc
  local grid, seen_tail
  for _, c in ipairs(chunk.read(bytes, MAGIC)) do
    if c.tag == "HEAD" and c.version == 1 then
      doc = {}
      doc.w, doc.h, doc.tile, doc.tileset = unpack("<i4i4I4s4", c.payload)
    elseif c.tag == "GRID" and c.version == 1 then
      grid = c.payload
    elseif c.tag == "TAIL" then
      seen_tail = true
    end
  end
  if not doc then error("tmap: no HEAD chunk", 0) end
  if not seen_tail then error("tmap: no TAIL chunk (truncated?)", 0) end
  if not grid or #grid ~= doc.w * doc.h * 2 then
    error("tmap: GRID size mismatch", 0)
  end
  doc.cells = grid
  return doc
end

-- fresh all-empty doc
function M.blank(w, h, tile, tileset)
  return { w = w, h = h, tile = tile, tileset = tileset or "",
           cells = string.rep("\0", w * h * 2) }
end

function M.get(doc, tx, ty)
  if tx < 0 or tx >= doc.w or ty < 0 or ty >= doc.h then return 0 end
  return (unpack("<I2", doc.cells, (ty * doc.w + tx) * 2 + 1))
end

function M.set(doc, tx, ty, id)
  if tx < 0 or tx >= doc.w or ty < 0 or ty >= doc.h then return end
  local o = (ty * doc.w + tx) * 2
  doc.cells = doc.cells:sub(1, o) .. pack("<I2", id) .. doc.cells:sub(o + 3)
end

return M
