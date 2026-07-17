-- cm.camera — the camera slice of A5 (D092). Follow with per-axis lerp +
-- deadzone, world bounds clamping, the room-swap cut, screen shake, and
-- world<->screen conversion — the math the platformer demo hand-rolled in
-- cam_step/enter_room (the PAIN(camera) evidence; §2's camera line).
--
-- A camera is plain data: keep it in state.doc and canon, snapshots,
-- traces, and rewind carry it by construction. No module state, no
-- buffers. Extra fields on the table are yours (the demo stores its
-- smoothed lookahead there), exactly like cm.box rects.
--
--   local camera = cm.require("cm.camera")
--   d.cam = d.cam or camera.new()          -- view-sized, at 0,0
--   camera.bounds(d.cam, 0, 0, level.pw, level.ph)
--   camera.center(d.cam, px, py)           -- the cut (init / room swap)
--   -- each step:
--   camera.tick(d.cam)                     -- ONCE per step: shake decay
--   camera.follow(d.cam, px, py, { lerp = 0.1, dead_y = 26 })
--   -- in draw, before world layers:
--   local camx, camy = camera.apply(d.cam)
--
-- Semantics, pinned by KATs:
--   * the camera is its top-left corner: c.x/c.y, view c.w x c.h (new()
--     defaults to pal.gfx_size()). All motion doors (center/follow/
--     bounds/clamp) end clamped to the bounds; no bounds = free.
--   * follow(c, x, y, o) eases the view CENTER toward the point:
--     per-axis o.lerp/o.lerp_y (default 1 = snap) over the error beyond
--     the per-axis deadzone o.dead/o.dead_y (default 0 — plain lerp).
--     o.ox/o.oy offset the target (lookahead: pass facing * dist; smooth
--     it yourself with cm.math.lerp on a field of the cam table).
--   * a bounds axis SMALLER than the view centers over it instead of
--     jittering between clamp edges.
--   * shake(c, mag, frames) arms integer frame counters in the table;
--     tick(c) — once per step — counts down and removes them at zero.
--     offset(c)/apply(c) derive the render-only wobble from the counters
--     (cm.math sin off the remaining count — never the PRNG, exactly the
--     swarm idiom), amplitude fading linearly from mag to zero. Arming
--     replaces any running shake. Sim results must never read offset().
--   * to_world/to_screen convert through the UNSHAKEN camera: mouse aim
--     stays deterministic while the view wobbles.
--   * apply(c) is render-side: hands the shaken top-left to cm.gfx's
--     camera (parallax layers, pixel snap — gfx.pixel_snap owns the
--     rounding policy) and returns it for your own draw calls.
--
-- Deliberately NOT here (absorb the demonstrated pain, no more): zones/
-- rails, dual-target framing, zoom, smooth pans between rooms (cut with
-- center; ease a field yourself), lookahead smoothing policy. Later
-- slices earn those from real demo pain.

local M = select(2, ...) or {}
local m = cm.require("cm.math")

-- clamp one axis of the top-left into [lo, lo+size-view]; a span smaller
-- than the view centers over it (no edge jitter)
local function clamp_axis(pos, view, lo, size)
  if size <= view then return lo + (size - view) / 2 end
  return m.clamp(pos, lo, lo + size - view)
end

-- clamp(c) -> c: pull the camera inside its bounds (no bounds: no-op).
-- The motion doors call this; it is exposed for hand-moved cameras.
function M.clamp(c)
  if c.bx ~= nil then
    c.x = clamp_axis(c.x, c.w, c.bx, c.bw)
    c.y = clamp_axis(c.y, c.h, c.by, c.bh)
  end
  return c
end

-- new([o]) -> a fresh camera table. Keep it in state.doc. o may set x/y
-- (top-left, default 0) and w/h (view size, default pal.gfx_size()).
function M.new(o)
  o = o or {}
  local w, h = o.w, o.h
  if w == nil or h == nil then
    local gw, gh = pal.gfx_size()
    w, h = w or gw, h or gh
  end
  return { x = o.x or 0, y = o.y or 0, w = w, h = h }
end

-- bounds(c, x, y, w, h): confine the view to a world rect (then clamp
-- into it now). bounds(c) clears them — the camera roams free.
function M.bounds(c, x, y, w, h)
  if x == nil then
    c.bx, c.by, c.bw, c.bh = nil, nil, nil, nil
    return c
  end
  c.bx, c.by, c.bw, c.bh = x, y, w, h
  return M.clamp(c)
end

-- center(c, x, y): put the view center on a point NOW — the cut. Init,
-- room swaps, respawns: anywhere a follow would whip-pan.
function M.center(c, x, y)
  c.x = x - c.w / 2
  c.y = y - c.h / 2
  return M.clamp(c)
end

-- follow(c, x, y [, o]): ease the view center toward a point (see the
-- header for o). Call once per step after moving the target.
function M.follow(c, x, y, o)
  o = o or {}
  local lerp = o.lerp or 1
  local lerp_y = o.lerp_y or lerp
  local dead = o.dead or 0
  local dead_y = o.dead_y or dead
  local ex = (x + (o.ox or 0)) - (c.x + c.w / 2)
  if ex > dead then c.x = c.x + (ex - dead) * lerp
  elseif ex < -dead then c.x = c.x + (ex + dead) * lerp end
  local ey = (y + (o.oy or 0)) - (c.y + c.h / 2)
  if ey > dead_y then c.y = c.y + (ey - dead_y) * lerp_y
  elseif ey < -dead_y then c.y = c.y + (ey + dead_y) * lerp_y end
  return M.clamp(c)
end

-- shake(c, mag, frames): arm a shake — peak offset mag px, fading to
-- zero over an integer frame count. Replaces a running shake; 0 frames
-- (or 0 mag) clears. tick(c) does the counting.
function M.shake(c, mag, frames)
  if type(mag) ~= "number" or mag < 0 then
    error("camera.shake: mag must be a number >= 0", 2)
  end
  if math.type(frames) ~= "integer" or frames < 0 then
    error("camera.shake: frames must be an integer >= 0", 2)
  end
  if mag == 0 or frames == 0 then
    c.shake, c.shake_t0, c.shake_mag = nil, nil, nil
  else
    c.shake, c.shake_t0, c.shake_mag = frames, frames, mag
  end
  return c
end

-- tick(c): once per step (beside your world's tick). Counts the shake
-- down; at zero the fields leave the table.
function M.tick(c)
  local t = c.shake
  if t == nil then return end
  t = t - 1
  if t <= 0 then c.shake, c.shake_t0, c.shake_mag = nil, nil, nil
  else c.shake = t end
end

-- offset(c) -> ox, oy: the render-only shake wobble (0, 0 when idle).
-- Pure math off the doc counters; never sim input.
function M.offset(c)
  local t = c.shake
  if t == nil then return 0, 0 end
  local a = c.shake_mag * t / c.shake_t0
  return m.sin(t * 2.7) * a, m.sin(t * 3.1 + 2) * a
end

-- apply(c) -> camx, camy: render-side. Set cm.gfx's camera to the shaken
-- top-left (parallax layers pick it up; gfx.pixel_snap owns rounding)
-- and return it for draw calls that want the numbers.
function M.apply(c)
  local ox, oy = M.offset(c)
  local x, y = c.x + ox, c.y + oy
  cm.require("cm.gfx").camera(x, y)
  return x, y
end

-- to_screen(c, wx, wy) -> sx, sy — world to screen through the UNSHAKEN
-- camera (see header). to_world inverts it (mouse px -> world).
function M.to_screen(c, wx, wy)
  return wx - c.x, wy - c.y
end

function M.to_world(c, sx, sy)
  return sx + c.x, sy + c.y
end

return M
