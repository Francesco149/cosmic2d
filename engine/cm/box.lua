-- cm.box — pure AABB ergonomics: the first cut of the A5 query slice
-- (D090). Overlap tests, point/rect containment, rect-list queries, and
-- the axis-at-a-time slide move that every top-down/arena game here had
-- hand-rolled (demo `overlap`, topdown starter `blocked`, cellar, swarm —
-- four copies was the evidence).
--
-- Pure functions over plain numbers and rect tables — no module state, no
-- buffers, so determinism is trivial: results are exact float/integer math
-- on the inputs. Rects are keyed tables { x=, y=, w=, h= } (extra fields
-- welcome — your actor tables pass through untouched).
--
-- Semantics, pinned by KATs:
--   * overlap is STRICT: rects sharing only an edge do NOT overlap. This
--     matches every hand-rolled copy it replaces, and it means a body
--     resting flush against a wall is not "inside" it.
--   * slide() moves axis-at-a-time in one whole step per axis: the x move
--     is cancelled entirely if it would overlap a rect, then the y move
--     likewise (the classic wall-slide feel). It is NOT swept: a step
--     larger than a wall's thickness tunnels. For fast movers against map
--     colliders use cm.map's mover (see "Moving against map collision" in
--     the scripting guide); this is the lightweight game-object variant.
--
-- Tasks:
--   pick up a coin        if box.touch(d.x, d.y, PW, PH, coin, 8) then ...
--   first solid you hit   local i, r = box.hit(solids, x, y, w, h)
--   walk with wall slide  d.x, d.y = box.slide(d.x, d.y, PW, PH, dx, dy, solids)
--   interaction reach     box.overlap(box.expand(d.x, d.y, PW, PH, 6),
--                                     door.x, door.y, door.w, door.h) — or
--                         use the 8-arg form with expanded numbers

local M = select(2, ...) or {}

-- overlap(ax,ay,aw,ah, bx,by,bw,bh) -> bool. Strict edges (see header).
function M.overlap(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end

-- overlap_rect(ax,ay,aw,ah, r) -> bool: the keyed-rect half of the pair
function M.overlap_rect(ax, ay, aw, ah, r)
  return ax < r.x + r.w and ax + aw > r.x and ay < r.y + r.h and ay + ah > r.y
end

-- touch(ax,ay,aw,ah, p, s): overlap with a CENTERED square of side s at
-- point p = {x=,y=} — the item-pickup shape (coins, keys, gems)
function M.touch(ax, ay, aw, ah, p, s)
  local half = s / 2
  return M.overlap(ax, ay, aw, ah, p.x - half, p.y - half, s, s)
end

-- contains(x,y,w,h, px,py): the point is inside (right/bottom exclusive,
-- matching overlap's strictness)
function M.contains(x, y, w, h, px, py)
  return px >= x and px < x + w and py >= y and py < y + h
end

-- expand(x,y,w,h, e) -> x,y,w,h grown by e on every side (negative shrinks)
function M.expand(x, y, w, h, e)
  return x - e, y - e, w + 2 * e, h + 2 * e
end

-- hit(rects, x,y,w,h) -> index, rect of the FIRST overlapping entry in
-- array order, or nil — the query the four hand-rolled loops performed
function M.hit(rects, x, y, w, h)
  for i, r in ipairs(rects) do
    if x < r.x + r.w and x + w > r.x and y < r.y + r.h and y + h > r.y then
      return i, r
    end
  end
  return nil
end

-- hits(rects, x,y,w,h [,out]) -> array of overlapping indices, in array
-- order. Pass `out` to reuse a table (it is cleared first).
function M.hits(rects, x, y, w, h, out)
  out = out or {}
  for i = #out, 1, -1 do out[i] = nil end
  for i, r in ipairs(rects) do
    if x < r.x + r.w and x + w > r.x and y < r.y + r.h and y + h > r.y then
      out[#out + 1] = i
    end
  end
  return out
end

-- slide(x,y,w,h, dx,dy, rects) -> nx, ny, hitx, hity. Axis-at-a-time
-- whole-step move with the wall-slide feel (see header for semantics and
-- the tunneling caveat). hitx/hity report which axis moves were cancelled.
function M.slide(x, y, w, h, dx, dy, rects)
  local hitx, hity = false, false
  if dx ~= 0 then
    if M.hit(rects, x + dx, y, w, h) then hitx = true else x = x + dx end
  end
  if dy ~= 0 then
    if M.hit(rects, x, y + dy, w, h) then hity = true else y = y + dy end
  end
  return x, y, hitx, hity
end

return M
