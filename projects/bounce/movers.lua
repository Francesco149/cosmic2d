-- movers — kinematic moving platforms (level.movers): each shuttles its
-- TOP surface between two endpoints, cosine-eased ping-pong, period in
-- frames. Positions are PURE FUNCTIONS of the sim frame (cm.math trig,
-- phase = frame % period) — no state buffer, so snapshots/traces/rewind
-- replay them for free. player.step collides against the post-step boxes
-- (frame+1) and CARRIES a rider by the frame delta; draw emits at the
-- advanced frame counter, so visuals and colliders are the same bytes.
--
-- A moving box transiently forms narrower-than-the-player pockets against
-- static geometry — the level gap rule cannot hold for it. That is safe by
-- construction since D3D-009/010: squeezed overlaps clamp nothing and
-- resolve without teleports; course design keeps riders clear of walls.

local m = cm.require("cm.math")
local gb = cm.require("gb")
local level = cm.require("level")

local M = select(2, ...) or {}

local function ease(f, period) -- 0 -> 1 -> 0 over one period, eased
  return (1 - m.cos(m.tau * (f % period) / period)) / 2
end

-- mover i's AABB at frame f: { x0, y0, z0, x1, y1, z1 }
function M.box(i, f)
  local mv = level.movers[i]
  local t = ease(f, mv[11])
  local x = mv[5] + (mv[8] - mv[5]) * t
  local top = mv[6] + (mv[9] - mv[6]) * t
  local z = mv[7] + (mv[10] - mv[7]) * t
  local hx, hz = mv[2] / 2, mv[4] / 2
  return { x - hx, top - mv[3], z - hz, x + hx, top, z + hz }
end

function M.boxes(f)
  local out = {}
  for i = 1, #level.movers do out[i] = M.box(i, f) end
  return out
end

-- worst-case tris emit() produces (dyn buffer sizing)
function M.max_tris()
  return #level.movers * 12
end

-- emit every mover at frame f into out[]; returns { {mat, n}... } segments
-- in emit order (each mover is its own material segment)
function M.emit(out, f)
  local white = { 1, 1, 1 }
  local segs = {}
  for i, mv in ipairs(level.movers) do
    local b = M.box(i, f)
    gb.gbox(out, nil, { mv[2], mv[3], mv[4] },
            { (b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2 },
            white, 0.5)
    segs[#segs + 1] = { mat = mv[1], n = 12 }
  end
  return segs
end

return M
