-- cm.tmap — the .tm tilemap object (MAPS.md §2/§8, D057): a pure-visual
-- grid placed on a map like any sprite, moved/z-ordered as one unit. The
-- tileset is a .spr whose FRAMES are the tiles — tile id N draws strip
-- frame N (1-based; the baked .png sibling lays frames L→R at tile px);
-- cell 0 is empty. No collision here ever — collision is collider chains
-- like everything else's (cm.collide). CTLM chunk container, codec pure
-- + canonical:
--
--   HEAD v1: <i4 w cells> <i4 h cells> <I4 tile px> <s4 tileset path>
--   GRID v1: w*h u16 cell ids, row-major (raw string, bulk)
--   TAIL v1: empty
--
-- R8d adds the pure grid ops the tilemap window drives (resize /
-- fill_rect), the §7 edge-run walk (the one-click collider run over
-- exposed tile edges), and the culled batched-quads draw the game and
-- the map window render placements with.

local M = select(2, ...) or {}

local chunk = cm.require("cm.chunk")

local pack, unpack = string.pack, string.unpack
local floor, ceil = math.floor, math.ceil
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

-- ---- the pure grid ops (R8d; the tilemap window drives these) ----

-- resize in place, anchored top-left: overlap survives, growth is empty,
-- the rest crops (§8's grow/crop fields)
function M.resize(doc, nw, nh)
  if nw < 1 or nh < 1 or (nw == doc.w and nh == doc.h) then return end
  local rows = {}
  local keep = nw < doc.w and nw or doc.w
  local pad = nw > doc.w and string.rep("\0", (nw - doc.w) * 2) or ""
  local blank
  for ty = 0, nh - 1 do
    if ty < doc.h then
      local o = ty * doc.w * 2
      rows[ty + 1] = doc.cells:sub(o + 1, o + keep * 2) .. pad
    else
      blank = blank or string.rep("\0", nw * 2)
      rows[ty + 1] = blank
    end
  end
  doc.w, doc.h, doc.cells = nw, nh, table.concat(rows)
end

-- fill the clamped cell rect [tx0..tx1] x [ty0..ty1] with id (either
-- corner order); the rect-fill tool's core
function M.fill_rect(doc, tx0, ty0, tx1, ty1, id)
  if tx1 < tx0 then tx0, tx1 = tx1, tx0 end
  if ty1 < ty0 then ty0, ty1 = ty1, ty0 end
  if tx0 < 0 then tx0 = 0 end
  if ty0 < 0 then ty0 = 0 end
  if tx1 >= doc.w then tx1 = doc.w - 1 end
  if ty1 >= doc.h then ty1 = doc.h - 1 end
  if tx1 < tx0 or ty1 < ty0 then return end
  local run = pack("<I2", id):rep(tx1 - tx0 + 1)
  local parts, at = {}, 1
  for ty = ty0, ty1 do
    local o = (ty * doc.w + tx0) * 2
    parts[#parts + 1] = doc.cells:sub(at, o)
    parts[#parts + 1] = run
    at = o + #run + 1
  end
  parts[#parts + 1] = doc.cells:sub(at)
  doc.cells = table.concat(parts)
end

-- ---- the §7 edge-run (R8d): one click lays a collider along a whole
-- contiguous exposed tile edge ----
--
-- (lx, ly) = a point in the doc's LOCAL px (caller subtracts the
-- placement origin), thr = distance threshold in px. Finds the nearest
-- tile-edge line within thr where the adjacent cells make an EXPOSED
-- face (solid on one side, empty on the other), then walks the run both
-- ways while that face continues. Returns x0, y0, x1, y1 (local px;
-- left→right / top→bottom) — or nil when nothing qualifies. Floors win
-- ties with ceilings, left faces with right (the canonical authoring
-- targets); horizontal edges outrank vertical at equal distance.
function M.edge_run(doc, lx, ly, thr)
  local t = doc.tile
  local bx0, by0, bx1, by1, bd
  -- horizontal edge lines: y = k*t; the solid/empty pair is the cell
  -- below (row k) vs above (row k-1)
  local tx = floor(lx / t)
  if tx >= 0 and tx < doc.w then
    local k = floor(ly / t + 0.5)
    local d = ly - k * t
    if d < 0 then d = -d end
    if k >= 0 and k <= doc.h and d <= thr then
      local function top(c) -- a floor: solid below, air above
        return M.get(doc, c, k) ~= 0 and M.get(doc, c, k - 1) == 0
      end
      local function bot(c) -- a ceiling: solid above, air below
        return M.get(doc, c, k - 1) ~= 0 and M.get(doc, c, k) == 0
      end
      local face = top(tx) and top or (bot(tx) and bot or nil)
      if face then
        local a, b = tx, tx
        while a > 0 and face(a - 1) do a = a - 1 end
        while b < doc.w - 1 and face(b + 1) do b = b + 1 end
        bx0, by0, bx1, by1, bd = a * t, k * t, (b + 1) * t, k * t, d
      end
    end
  end
  -- vertical edge lines: x = j*t; solid right (col j) vs left (col j-1)
  local ty = floor(ly / t)
  if ty >= 0 and ty < doc.h then
    local j = floor(lx / t + 0.5)
    local d = lx - j * t
    if d < 0 then d = -d end
    if j >= 0 and j <= doc.w and d <= thr and (not bd or d < bd) then
      local function lft(c) -- an exposed left face: solid right, air left
        return M.get(doc, j, c) ~= 0 and M.get(doc, j - 1, c) == 0
      end
      local function rgt(c) -- an exposed right face
        return M.get(doc, j - 1, c) ~= 0 and M.get(doc, j, c) == 0
      end
      local face = lft(ty) and lft or (rgt(ty) and rgt or nil)
      if face then
        local a, b = ty, ty
        while a > 0 and face(a - 1) do a = a - 1 end
        while b < doc.h - 1 and face(b + 1) do b = b + 1 end
        bx0, by0, bx1, by1 = j * t, a * t, j * t, (b + 1) * t
      end
    end
  end
  if bx0 then return bx0, by0, bx1, by1 end
end

-- ---- the culled batched-quads draw (render-only; MAPS.md §5) ----
--
-- Draw the doc's non-empty cells offset by (ox, oy) with the camera at
-- (camx, camy), from the tileset's baked strip texture (frame N at
-- x = (N-1)*tile). The TM:draw shape: one scratch buffer, one
-- pal.draw_quads. Ids past the strip skip (a retargeted tileset with
-- fewer tiles degrades to holes, never errors).

local F32 = 4
local QUAD = 12 * F32
local scratch -- render plumbing; rebuilt when a bigger view needs it

function M.draw(doc, tex, ox, oy, camx, camy)
  local t = doc.tile
  local vw, vh = pal.gfx_size()
  local c0 = floor((camx - ox) / t)
  local c1 = ceil((camx + vw - ox) / t) - 1
  local r0 = floor((camy - oy) / t)
  local r1 = ceil((camy + vh - oy) / t) - 1
  if c0 < 0 then c0 = 0 end
  if r0 < 0 then r0 = 0 end
  if c1 >= doc.w then c1 = doc.w - 1 end
  if r1 >= doc.h then r1 = doc.h - 1 end
  if c1 < c0 or r1 < r0 then return end

  local need = (c1 - c0 + 1) * (r1 - r0 + 1) * QUAD
  if not scratch or scratch:size() < need then
    scratch = pal.buf(nil, need)
  end
  local s = scratch
  local tw, th = tex.w, tex.h
  local cells = doc.cells
  local n = 0
  for r = r0, r1 do
    local base = r * doc.w * 2
    for c = c0, c1 do
      local id = unpack("<I2", cells, base + c * 2 + 1)
      if id ~= 0 and id * t <= tw then
        local o = n * QUAD
        s:f32(o, ox + c * t)
        s:f32(o + 4, oy + r * t)
        s:f32(o + 8, t)
        s:f32(o + 12, t)
        s:f32(o + 16, (id - 1) * t / tw)
        s:f32(o + 20, 0)
        s:f32(o + 24, id * t / tw)
        s:f32(o + 28, t / th)
        s:f32(o + 32, 1)
        s:f32(o + 36, 1)
        s:f32(o + 40, 1)
        s:f32(o + 44, 1)
        n = n + 1
      end
    end
  end
  if n > 0 then pal.draw_quads(tex.id, s, n) end
end

return M
