-- pt.tilemap — buffer-backed tile grids: bulk-path rendering and AABB
-- collision (M3). The grid lives in a named buffer, so the map is sim state
-- (snapshot/trace/reboot-proof) and self-describing for future tools:
--
--   [0] u32 w (cells) | [4] u32 h | [8] u32 tile px | [12] reserved (zero)
--   [16..] u16 tile ids, row-major, y*w + x
--
-- The wrapper object (new()) is plain Lua glue rebuilt by game.init each
-- reload; only the buffer is truth. Tile *meaning* — which ids are solid,
-- which are one-way platforms, what they look like — is the `tiles` table
-- (code, travels in bundles): tiles[id] = { solid=true } or { oneway=true }
-- plus draw fields u,v (atlas px) and optional r,g,b,a tint. id 0 (or any
-- id with no entry) is empty air.
--
-- Collision model (deterministic: f64 + - * / floor/ceil only):
--  * AABBs are half-open [x, x+w) x [y, y+h) in pixels; cells likewise.
--  * move() sweeps axis-separated (x then y), scanning every cell boundary
--    crossed, so nothing tunnels at any speed.
--  * one-way platforms: collide only when falling onto the cell's TOP edge
--    from at or above (the row-entry scan gives this exactly); never block
--    sideways or upward movement. opts.drop lets a controller fall through
--    (down+jump in the MapleStory vocabulary).
--  * outside the map: left/right/below = solid walls, above = open sky.
--  * move() does not eject an AABB already overlapping a solid — don't
--    spawn things inside walls.

local M = select(2, ...) or {}

local floor, ceil = math.floor, math.ceil
local HDR = 16

local TM = {}
TM.__index = TM

-- new{ name=, w=, h=, tile=, tiles= } — create or adopt the named buffer.
-- An existing buffer with a matching header keeps its cells (init stays
-- idempotent); a header mismatch (live level resize) frees and rebuilds.
-- Second return `fresh` is true when the cells did NOT survive (buffer
-- created or rebuilt) — callers seed a first-boot map only then.
function M.new(o)
  local w = o.w or error("tilemap.new: w", 2)
  local h = o.h or error("tilemap.new: h", 2)
  local tile = o.tile or 16
  local name = o.name or error("tilemap.new: name", 2)
  local size = HDR + w * h * 2
  local existing
  for _, b in ipairs(pal.buf_list()) do
    if b.name == name then existing = b break end
  end
  if existing and existing.size ~= size then
    pal.buf_free(name)
    existing = nil
  end
  local buf = pal.buf(name, size)
  if existing and (buf:u32(0) ~= w or buf:u32(4) ~= h or buf:u32(8) ~= tile)
     and (buf:u32(0) ~= 0 or buf:u32(4) ~= 0) then
    -- same byte size but different shape: rebuild
    pal.buf_free(name)
    buf = pal.buf(name, size)
    existing = nil
  end
  buf:u32(0, w)
  buf:u32(4, h)
  buf:u32(8, tile)
  return setmetatable({ buf = buf, name = name, w = w, h = h, tile = tile,
                        pw = w * tile, ph = h * tile,
                        tiles = o.tiles or {} }, TM), existing == nil
end

-- adopt an existing map buffer by name (tools/inspector path): dimensions
-- come from the header
function M.open(name, tiles)
  local found
  for _, b in ipairs(pal.buf_list()) do
    if b.name == name then found = b break end
  end
  if not found then error("tilemap.open: no buffer " .. name, 2) end
  local buf = pal.buf(name, found.size)
  local w, h, tile = buf:u32(0), buf:u32(4), buf:u32(8)
  if w == 0 or h == 0 or tile == 0 or HDR + w * h * 2 ~= found.size then
    error("tilemap.open: " .. name .. " has no valid tilemap header", 2)
  end
  return setmetatable({ buf = buf, name = name, w = w, h = h, tile = tile,
                        pw = w * tile, ph = h * tile,
                        tiles = tiles or {} }, TM)
end

-- ---- by-name statics (tools / the editor's eval path) ----

-- poke/peek mutate/read one cell of a map buffer BY NAME, so an edit is a
-- single self-contained command string. poke is a sim-state mutation: live
-- tools must route it through pt.repl.submit (the D022 EVAL path) so a
-- recording replays the edit; calling it directly mid-frame would make an
-- active trace diverge on verify. OOB is ignored (poke) / 0 (peek), same
-- as TM:set/get.
function M.poke(name, tx, ty, id)
  M.open(name):set(tx, ty, id)
end

function M.peek(name, tx, ty)
  return M.open(name):get(tx, ty)
end

-- save/load a map buffer to/from a file: the raw self-describing bytes
-- (header + cells). save is a pure read (safe anywhere); load REPLACES the
-- named buffer from disk — boot-time only by convention: file contents are
-- not sim input, so a live load would not replay (re-wrap via M.open after).
function M.save(name, path)
  local tm = M.open(name)
  return pal.write_file(path, tm.buf:str(0, tm.buf:size()))
end

function M.load(name, path)
  local bytes = pal.read_file(path)
  if not bytes then return nil, "no file" end
  if #bytes < HDR then return nil, "truncated header" end
  local w, h, tile = string.unpack("<I4I4I4", bytes)
  if w == 0 or h == 0 or tile == 0 or HDR + w * h * 2 ~= #bytes then
    return nil, "not a tilemap file"
  end
  pal.buf_free(name)
  pal.buf(name, #bytes):setstr(0, bytes)
  return true
end

-- walk the supercover cells of the segment (tx0,ty0)->(tx1,ty1), calling
-- fn(tx,ty) for each INCLUDING both ends: brush drags paint every cell the
-- cursor crossed even when motion events skip. Integer cells, pure.
function M.cell_line(tx0, ty0, tx1, ty1, fn)
  local dx = tx1 > tx0 and tx1 - tx0 or tx0 - tx1
  local dy = ty1 > ty0 and ty1 - ty0 or ty0 - ty1
  local sx = tx0 < tx1 and 1 or -1
  local sy = ty0 < ty1 and 1 or -1
  local err = dx - dy
  while true do
    fn(tx0, ty0)
    if tx0 == tx1 and ty0 == ty1 then return end
    local e2 = 2 * err
    if e2 > -dy then
      err = err - dy
      tx0 = tx0 + sx
    end
    if e2 < dx then
      err = err + dx
      ty0 = ty0 + sy
    end
  end
end

-- ---- cells ----

function TM:get(tx, ty)
  if tx < 0 or tx >= self.w or ty < 0 or ty >= self.h then return 0 end
  return self.buf:u16(HDR + (ty * self.w + tx) * 2)
end

function TM:set(tx, ty, id)
  if tx < 0 or tx >= self.w or ty < 0 or ty >= self.h then return end
  self.buf:u16(HDR + (ty * self.w + tx) * 2, id)
end

function TM:fill(tx, ty, w, h, id)
  for y = ty, ty + h - 1 do
    for x = tx, tx + w - 1 do self:set(x, y, id) end
  end
end

function TM:clear()
  self.buf:fill(HDR, self.w * self.h * 2, 0)
end

-- ---- classes ----

-- cell class with out-of-bounds rules: side/bottom walls, open sky
local function class_at(self, tx, ty)
  if ty < 0 then return nil end
  if tx < 0 or tx >= self.w or ty >= self.h then return { solid = true } end
  return self.tiles[self:get(tx, ty)]
end

local function span_solid(self, tx0, tx1, ty0, ty1)
  for ty = ty0, ty1 do
    for tx = tx0, tx1 do
      local c = class_at(self, tx, ty)
      if c and c.solid then return true end
    end
  end
  return false
end

local function span_oneway(self, tx0, tx1, ty)
  for tx = tx0, tx1 do
    local c = class_at(self, tx, ty)
    if c and c.oneway then return true end
  end
  return false
end

-- is the pixel inside a solid cell?
function TM:solid_at(px, py)
  local c = class_at(self, floor(px / self.tile), floor(py / self.tile))
  return (c and c.solid) or false
end

-- ---- the mover ----

-- cells covered by the half-open span [a, b): first, last (inclusive)
local function span(a, b, t)
  return floor(a / t), ceil(b / t) - 1
end

-- sweep an AABB by (dx, dy); returns nx, ny, hit where hit = { left=, right=,
-- up=, down=, oneway= } (oneway: the down contact was a one-way platform).
-- opts.drop = true falls through one-way platforms this call.
function TM:move(x, y, w, h, dx, dy, opts)
  local t = self.tile
  local drop = opts and opts.drop
  local hit = {}

  if dx > 0 then
    local ty0, ty1 = span(y, y + h, t)
    local _, c_last = span(x, x + w, t)
    local _, want = span(x + dx, x + w + dx, t)
    local nx = x + dx
    for c = c_last + 1, want do
      if span_solid(self, c, c, ty0, ty1) then
        nx = c * t - w
        hit.right = true
        break
      end
    end
    x = nx
  elseif dx < 0 then
    local ty0, ty1 = span(y, y + h, t)
    local c_first = floor(x / t)
    local want = floor((x + dx) / t)
    local nx = x + dx
    for c = c_first - 1, want, -1 do
      if span_solid(self, c, c, ty0, ty1) then
        nx = (c + 1) * t
        hit.left = true
        break
      end
    end
    x = nx
  end

  if dy > 0 then
    local tx0, tx1 = span(x, x + w, t)
    local _, r_last = span(y, y + h, t)
    local _, want = span(y + dy, y + h + dy, t)
    local ny = y + dy
    for r = r_last + 1, want do
      -- entering row r from above: old bottom <= r*t by construction
      if span_solid(self, tx0, tx1, r, r) then
        ny = r * t - h
        hit.down = true
        break
      elseif not drop and span_oneway(self, tx0, tx1, r) then
        ny = r * t - h
        hit.down = true
        hit.oneway = true
        break
      end
    end
    y = ny
  elseif dy < 0 then
    local tx0, tx1 = span(x, x + w, t)
    local r_first = floor(y / t)
    local want = floor((y + dy) / t)
    local ny = y + dy
    for r = r_first - 1, want, -1 do
      if span_solid(self, tx0, tx1, r, r) then
        ny = (r + 1) * t
        hit.up = true
        break
      end
    end
    y = ny
  end

  return x, y, hit
end

-- standing support probe: would moving down 1px collide? (controllers call
-- this to distinguish "on ground" from "fell off the ledge" without moving)
function TM:grounded(x, y, w, h, opts)
  local _, ny, hit = self:move(x, y, w, h, 0, 1, opts)
  return hit.down and ny == y, hit.oneway
end

-- ---- rendering ----

-- pack the camera-visible window into a scratch buffer and draw in one
-- pal.draw_quads call. tex = {id=, w=, h=} (pt.gfx.texture shape); each
-- visible id needs tiles[id].u,v (atlas px). Render-only.
local F32 = 4
local QUAD = 12 * F32

function TM:draw(tex, camx, camy)
  local t = self.tile
  local vw, vh = pal.gfx_size()
  local c0 = floor(camx / t)
  local c1 = ceil((camx + vw) / t) - 1
  local r0 = floor(camy / t)
  local r1 = ceil((camy + vh) / t) - 1
  if c0 < 0 then c0 = 0 end
  if r0 < 0 then r0 = 0 end
  if c1 >= self.w then c1 = self.w - 1 end
  if r1 >= self.h then r1 = self.h - 1 end
  if c1 < c0 or r1 < r0 then return end

  local need = (c1 - c0 + 1) * (r1 - r0 + 1) * QUAD
  if not self.scratch or self.scratch:size() < need then
    self.scratch = pal.buf(nil, need)
  end
  local s = self.scratch
  local tiles = self.tiles
  local tw, th = tex.w, tex.h
  local n = 0
  for r = r0, r1 do
    local base = HDR + r * self.w * 2
    for c = c0, c1 do
      local id = self.buf:u16(base + c * 2)
      if id ~= 0 then
        local d = tiles[id]
        if d and d.u then
          local o = n * QUAD
          s:f32(o, c * t)
          s:f32(o + 4, r * t)
          s:f32(o + 8, t)
          s:f32(o + 12, t)
          s:f32(o + 16, d.u / tw)
          s:f32(o + 20, d.v / th)
          s:f32(o + 24, (d.u + t) / tw)
          s:f32(o + 28, (d.v + t) / th)
          s:f32(o + 32, d.r or 1)
          s:f32(o + 36, d.g or 1)
          s:f32(o + 40, d.b or 1)
          s:f32(o + 44, d.a or 1)
          n = n + 1
        end
      end
    end
  end
  if n > 0 then pal.draw_quads(tex.id, s, n) end
end

return M
