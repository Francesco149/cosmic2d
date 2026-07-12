-- cm.collide — the R8 static collider world (MAPS.md §3, D057/a/b): line
-- chains (solid = blocks both ways, one-way = support from above) + circles
-- (overlap queries only), replacing the tile grid as the sim's collision
-- truth. The world lives in a named buffer, so it is sim state
-- (snapshot/trace/rewind-proof) and self-describing:
--
--   [0] u32 version (1) | [4] u32 collider count | [8] i32 bounds w px
--   [12] i32 bounds h px
--   then per collider:
--     u8 kind (0 chain, 1 circle) | u8 flags (bit0 oneway, bit1 closed)
--     u16 nverts
--     chain: nverts * (i32 x, i32 y)   circle: i32 cx, i32 cy, i32 r
--
-- The wrapper (build()/open()) is plain Lua glue rebuilt each reload; only
-- the buffer is truth (the cm.tilemap pattern). Vertices are integer px by
-- format; slopes come from non-axis-aligned segments.
--
-- Collision model (deterministic: f64 + - * / floor/ceil compares only —
-- no trig, no sqrt in the mover; segments scan in stored order, first-best
-- ties, so results are insertion-ordered by construction):
--  * AABBs are half-open [x, x+w) x [y, y+h); a segment covers the
--    half-open span of its major axis ([xmin, xmax) for floors,
--    [ymin, ymax) for walls) so chain seams neither gap nor double-hit.
--  * classification by slope, not authoring: |dy| <= |dx| (up to 45°) is
--    a FLOOR (supports from above; solid also blocks from below as the
--    ceiling under it), steeper is a WALL (blocks x; solid only). One-way
--    walls don't exist: steep one-way segments are ignored.
--  * move() sweeps axis-separated (x then y), TM:move's exact contract:
--    returns nx, ny, hit { left, right, up, down, oneway }. On flat
--    axis-aligned worlds it reproduces cm.tilemap byte-for-byte (KAT'd).
--  * slopes: while falling-or-level (dy >= 0) a solid floor penetrated by
--    this call's own x motion snaps the AABB up onto the surface (the
--    walk-uphill case; penetration can't exceed SMAX*|dx| by geometry, so
--    the cap is airtight). opts.ground = true (caller was grounded) also
--    arms the descent stick — a floor within SMAX*|dx| below the feet
--    catches, so walking downhill never micro-falls — and lets one-ways
--    snap-up too (walking up a one-way slope). Flat worlds never trigger
--    either branch (no penetration, no sub-step gaps), preserving parity.
--  * outside the bounds: left/right/below = solid walls, above = open sky
--    (the tilemap OOB rules).
--  * move() does not eject an AABB already overlapping a solid — don't
--    spawn things inside walls.

local M = select(2, ...) or {}

local floor = math.floor
local HDR = 16
local EPS = 1e-6

M.SMAX = 1.0 -- max walkable |dy/dx|; 45° inclusive (MAPS.md §3)

local W = {}
W.__index = W

-- ---- build / adopt ----

local function seg_add(self, ax, ay, bx, by, oneway)
  if ax == bx and ay == by then return end -- degenerate
  local adx = bx > ax and bx - ax or ax - bx
  local ady = by > ay and by - ay or ay - by
  local is_floor = ady <= adx * M.SMAX
  if oneway and not is_floor then return end -- steep one-ways are ignored
  local s = { ax = ax, ay = ay, bx = bx, by = by,
              floor = is_floor, oneway = oneway or false,
              x0 = ax < bx and ax or bx, x1 = ax < bx and bx or ax,
              y0 = ay < by and ay or by, y1 = ay < by and by or ay }
  self.segs[#self.segs + 1] = s
end

-- decode the buffer into the ephemeral seg/circle lists (the glue)
local function decode(self)
  local buf, o = self.buf, HDR
  self.segs, self.circs = {}, {}
  for _ = 1, buf:u32(4) do
    local kind, flags, n = buf:u8(o), buf:u8(o + 1), buf:u16(o + 2)
    o = o + 4
    if kind == 1 then
      self.circs[#self.circs + 1] =
        { cx = buf:i32(o), cy = buf:i32(o + 4), r = buf:i32(o + 8) }
      o = o + 12
    else
      local oneway = flags & 1 ~= 0
      local closed = flags & 2 ~= 0
      local px, py
      local fx, fy
      for i = 1, n do
        local vx, vy = buf:i32(o), buf:i32(o + 4)
        o = o + 8
        if i == 1 then fx, fy = vx, vy
        else seg_add(self, px, py, vx, vy, oneway) end
        px, py = vx, vy
      end
      if closed and n > 2 then seg_add(self, px, py, fx, fy, oneway) end
    end
  end
end

-- build{ name=, w=, h=, colliders= } — encode into the named buffer (frees
-- any previous shape) and return the wrapper. colliders = array of
--   { kind = "chain", oneway=, closed=, verts = {x0,y0,x1,y1,...} }
--   { kind = "circle", cx=, cy=, r= }
-- w/h = map bounds in px (the OOB walls). All coords integers.
function M.build(o)
  local name = o.name or error("collide.build: name", 2)
  local cols = o.colliders or {}
  local size = HDR
  for _, c in ipairs(cols) do
    size = size + 4 + (c.kind == "circle" and 12 or #c.verts // 2 * 8)
  end
  pal.buf_free(name)
  local buf = pal.buf(name, size)
  buf:u32(0, 1)
  buf:u32(4, #cols)
  buf:i32(8, o.w or error("collide.build: w", 2))
  buf:i32(12, o.h or error("collide.build: h", 2))
  local at = HDR
  for _, c in ipairs(cols) do
    if c.kind == "circle" then
      buf:u8(at, 1)
      buf:u8(at + 1, 0)
      buf:u16(at + 2, 0)
      buf:i32(at + 4, c.cx)
      buf:i32(at + 8, c.cy)
      buf:i32(at + 12, c.r)
      at = at + 16
    else
      local n = #c.verts // 2
      buf:u8(at, 0)
      buf:u8(at + 1, (c.oneway and 1 or 0) | (c.closed and 2 or 0))
      buf:u16(at + 2, n)
      at = at + 4
      for i = 0, n - 1 do
        buf:i32(at, c.verts[i * 2 + 1])
        buf:i32(at + 4, c.verts[i * 2 + 2])
        at = at + 8
      end
    end
  end
  return M.open(name)
end

-- adopt an existing world buffer by name (post-snapshot/reboot path)
function M.open(name)
  local found
  for _, b in ipairs(pal.buf_list()) do
    if b.name == name then found = b break end
  end
  if not found then error("collide.open: no buffer " .. name, 2) end
  local buf = pal.buf(name, found.size)
  if buf:u32(0) ~= 1 then
    error("collide.open: " .. name .. " has no v1 collider header", 2)
  end
  local self = setmetatable({ buf = buf, name = name,
                              w = buf:i32(8), h = buf:i32(12) }, W)
  decode(self)
  return self
end

-- ---- segment math (pure, inlined shapes) ----

-- y of segment s at x (only called with x inside [x0, x1], x0 < x1)
local function y_at(s, x)
  return s.ay + (s.by - s.ay) * ((x - s.ax) / (s.bx - s.ax))
end

-- min/max segment y over the span overlap [ox0, ox1] (linear: ends only)
local function y_minmax(s, ox0, ox1)
  if s.ay == s.by then return s.ay, s.ay end
  local ya, yb = y_at(s, ox0), y_at(s, ox1)
  if ya < yb then return ya, yb end
  return yb, ya
end

-- x of segment s at y (walls; only inside [y0, y1], y0 < y1)
local function x_at(s, y)
  return s.ax + (s.bx - s.ax) * ((y - s.ay) / (s.by - s.ay))
end

local function x_minmax(s, oy0, oy1)
  if s.ax == s.bx then return s.ax, s.ax end
  local xa, xb = x_at(s, oy0), x_at(s, oy1)
  if xa < xb then return xa, xb end
  return xb, xa
end

-- ---- the mover ----

-- sweep an AABB by (dx, dy); returns nx, ny, hit (TM:move's contract).
-- opts.drop = fall through one-ways this call; opts.ground = the caller
-- was grounded last frame (arms the descent stick + one-way slope snap).
function W:move(x, y, w, h, dx, dy, opts)
  local drop = opts and opts.drop
  local ground = opts and opts.ground
  local hit = {}
  local segs = self.segs
  local x0pass = x

  -- X: walls (steep solids) + the border walls. Band is the pre-move
  -- half-open [y, y+h); plane = the wall's extreme x over the overlap.
  -- A plane behind the leading edge never blocks (the no-eject rule) —
  -- including the borders, so an OOB start is never yanked back in.
  if dx > 0 then
    local plane
    if self.w >= x + w then plane = self.w end -- right border
    for i = 1, #segs do
      local s = segs[i]
      if not s.floor and s.y0 < y + h and s.y1 > y then
        local oy0 = s.y0 > y and s.y0 or y
        local oy1 = s.y1 < y + h and s.y1 or y + h
        local px = x_minmax(s, oy0, oy1)
        if px >= x + w and (not plane or px < plane) then plane = px end
      end
    end
    if plane and plane < x + w + dx then
      x = plane - w
      hit.right = true
    else
      x = x + dx
    end
  elseif dx < 0 then
    local plane
    if x >= 0 then plane = 0 end -- left border
    for i = 1, #segs do
      local s = segs[i]
      if not s.floor and s.y0 < y + h and s.y1 > y then
        local oy0 = s.y0 > y and s.y0 or y
        local oy1 = s.y1 < y + h and s.y1 or y + h
        local _, px = x_minmax(s, oy0, oy1)
        if px <= x and (not plane or px > plane) then plane = px end
      end
    end
    if plane and plane > x + dx then
      x = plane
      hit.left = true
    else
      x = x + dx
    end
  end
  local adx = x - x0pass -- the applied displacement drives the slope caps
  if adx < 0 then adx = -adx end

  -- Y: floors/ceilings over the post-X span [x, x+w).
  if dy >= 0 then
    -- support = the highest catching floor. Three catch bands, nearest
    -- (min sy) wins: snap-up (penetrated by this call's x motion, solid
    -- always / one-way when grounded), landing [y+h, y+h+dy), and the
    -- grounded descent stick (y+h+dy .. +SMAX*|dx|].
    local cap = M.SMAX * adx + EPS
    local stick = ground and cap or 0
    local best, best_ow
    for i = 1, #segs do
      local s = segs[i]
      if s.floor and (not s.oneway or not drop)
         and s.x0 < x + w and s.x1 > x then
        local ox0 = s.x0 > x and s.x0 or x
        local ox1 = s.x1 < x + w and s.x1 or x + w
        local sy = y_minmax(s, ox0, ox1)
        local pen = y + h - sy
        local ok
        if pen > 0 then
          -- snap-up: only a genuine cross onto rising ground — the surface
          -- at the approach-side edge of the overlap must have been at or
          -- above the feet (rules out block undersides and lateral clips)
          local ex = dx < 0 and ox1 or ox0
          local ey = s.ay == s.by and s.ay or y_at(s, ex)
          ok = pen <= cap and (not s.oneway or ground)
               and ey >= y + h - EPS
        else -- at/below the feet: landing window + the grounded stick
          ok = sy < y + h + dy or (stick > 0 and sy <= y + h + dy + stick)
        end
        if ok and (not best or sy < best
                   or (sy == best and best_ow and not s.oneway)) then
          best, best_ow = sy, s.oneway -- solid outranks one-way at a tie
        end
      end
    end
    -- bottom border floor (solid, spans everything)
    if not best and self.h >= y + h and self.h < y + h + dy then
      best, best_ow = self.h, false
    end
    if best then
      y = best - h
      hit.down = true
      hit.oneway = best_ow or nil
    else
      y = y + dy
    end
  else
    -- rising: ceilings = solid floors approached from below (their max y
    -- over the span is the lowest hanging point)
    local plane -- no top border: open sky
    for i = 1, #segs do
      local s = segs[i]
      if s.floor and not s.oneway and s.x0 < x + w and s.x1 > x then
        local ox0 = s.x0 > x and s.x0 or x
        local ox1 = s.x1 < x + w and s.x1 or x + w
        local _, cy = y_minmax(s, ox0, ox1)
        if cy <= y and (not plane or cy > plane) then plane = cy end
      end
    end
    if plane and plane > y + dy then
      y = plane
      hit.up = true
    else
      y = y + dy
    end
  end

  return x, y, hit
end

-- standing support probe (TM:grounded's contract)
function W:grounded(x, y, w, h, opts)
  local _, ny, hit = self:move(x, y, w, h, 0, 1, opts)
  return (hit.down and ny == y) or false, hit.oneway
end

-- ---- queries ----

-- standable floors crossing the vertical ray x, y in [y0, y1]: returns
-- an array of { y=, oneway= } sorted by y ascending (ties keep stored
-- order). The grapple/mantle probe.
function W:stand_ray(x, y0, y1)
  local out = {}
  for i = 1, #self.segs do
    local s = self.segs[i]
    if s.floor and s.x0 <= x and x < s.x1 then
      local sy = s.ay == s.by and s.ay or y_at(s, x)
      if sy >= y0 and sy <= y1 then
        out[#out + 1] = { y = sy, oneway = s.oneway }
      end
    end
  end
  table.sort(out, function(a, b) return a.y < b.y end)
  return out
end

-- is the point inside a closed solid chain (even-odd), or OOB-solid?
function W:solid_at(px, py)
  if py < 0 then return false end -- open sky
  if px < 0 or px >= self.w or py >= self.h then return true end -- borders
  -- even-odd cast along +x: count solid closed-chain edge crossings.
  -- decode() flattens chains to segs, so parity works over ALL solid segs
  -- of closed chains; open solid lines have no interior. We tagged segs
  -- with oneway/floor but not chain-closedness — re-walk the buffer here
  -- (a cold query; the mover never calls this).
  local buf, o = self.buf, HDR
  local inside = false
  for _ = 1, buf:u32(4) do
    local kind, flags, n = buf:u8(o), buf:u8(o + 1), buf:u16(o + 2)
    o = o + 4
    if kind == 1 then
      o = o + 12
    else
      if flags & 2 ~= 0 and flags & 1 == 0 and n > 2 then -- closed solid
        local X, Y = {}, {}
        for i = 1, n do
          X[i], Y[i] = buf:i32(o), buf:i32(o + 4)
          o = o + 8
        end
        local j = n
        for i = 1, n do
          if (Y[i] > py) ~= (Y[j] > py) then
            local cx = X[i] + (X[j] - X[i]) * ((py - Y[i]) / (Y[j] - Y[i]))
            if px < cx then inside = not inside end
          end
          j = i
        end
      else
        o = o + n * 8
      end
    end
  end
  return inside
end

-- circles overlapping the AABB (hazard/hit-zone queries): array of
-- { cx=, cy=, r=, i= } in stored order. Clamp-distance², no sqrt.
function W:circles(x, y, w, h)
  local out = {}
  for i = 1, #self.circs do
    local c = self.circs[i]
    local qx = c.cx < x and x or (c.cx > x + w and x + w or c.cx)
    local qy = c.cy < y and y or (c.cy > y + h and y + h or c.cy)
    local ddx, ddy = c.cx - qx, c.cy - qy
    if ddx * ddx + ddy * ddy <= c.r * c.r then
      out[#out + 1] = { cx = c.cx, cy = c.cy, r = c.r, i = i }
    end
  end
  return out
end

return M
