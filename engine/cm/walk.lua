-- cm.walk — click-to-move over a walk grid: the RO movement model as an
-- engine slice (§12; born in projects/rovale, D3D-026 logged it as
-- engine-shaped: "the pick ray + walk-grid A* are engine-shaped"). Not
-- cm.pick — upstream A5 owns that name (§12's collision ban). D3D-030.
--
-- The pieces, all pure functions (no module state, no buffers of its
-- own — determinism by construction):
--
--   K.cell(gw, wx, wz)              world point -> clamped cell coords
--   K.snap(gw, ok, cx, cz, r)       nearest walkable cell within r rings
--   K.astar(gw, ok, sx, sz, gx, gz) heap A*, 8-dir, no corner cutting
--   K.raycast(ground, ex,ey,ez, kx,ky,kz [,step,maxs,iters])
--                                   ray -> ground hit (march + bisect)
--   K.command(buf, path_max, gw, ok, wx, wz, snap_r, marker_ttl)
--   K.step(buf, gw, speed, turn)    follow the cell-center chain
--
-- The GRID is the caller's: gw = its width (cells index i = cz*gw + cx),
-- ok = a walkable predicate ok(cx, cz) -> bool. What makes a cell
-- walkable (water depth, steepness, blockers, prop decks) is project
-- policy and stays in the cartridge; the suite's honesty rule holds as
-- long as ok reads only sim-legal ground (never pixels, never rc.*).
--
-- The WALKER is a caller-named f32/u32 buffer whose layout this module
-- owns (the cm.rig precedent — ro.player's exact shape):
--
--   [0]x [4]z [8]facing [12]dist_phase (walk-anim odometer)
--   [16]u32 path_len [20]u32 path_idx [24/28]marker x/z [32]marker ttl
--   [40..] u32 path cell indices (path_max of them; buffer size
--   40 + path_max*4)
--
-- K.command snaps a world-point order to the grid, paths, and arms the
-- click marker; K.step walks the chain at speed (u/s at 60fps), easing
-- facing toward travel (short arc) and accumulating dist_phase — sheet
-- row/frame stays a pure function of (moving, dist_phase) in the caller
-- (zero animation state, the movers precedent). Facing snaps to octants
-- only at sprite time (the caller's cm.spr.oct call).
--
-- Deliberately NOT here: the walkable-rules builder (project policy),
-- screen->ray construction (the camera model's — rovale's bespoke RO rig
-- builds its own NDC ray, cm.rig users would build theirs), path
-- smoothing/string-pulling, dynamic re-path on blocked cells, moving
-- obstacles — later cuts earn them from real demo pain.

local m = cm.require("cm.math")

local K = select(2, ...) or {}

local floor = math.floor

function K.cell(gw, wx, wz) -- world -> cell (clamped into the grid)
  return m.clamp(floor(wx), 0, gw - 1), m.clamp(floor(wz), 0, gw - 1)
end

-- nearest walkable cell to (cx,cz) within r rings (the RO click snap)
function K.snap(gw, ok, cx, cz, r)
  if ok(cx, cz) then return cx, cz end
  for ring = 1, r do
    local best, bd = nil, 1e18
    for dz = -ring, ring do
      for dx = -ring, ring do
        if m.max(m.abs(dx), m.abs(dz)) == ring and ok(cx + dx, cz + dz) then
          local d = dx * dx + dz * dz
          if d < bd then bd, best = d, { cx + dx, cz + dz } end
        end
      end
    end
    if best then return best[1], best[2] end
  end
  return nil
end

-- heap A*, 8-dir, no corner cutting; returns a list of cell indices
-- (start cell excluded, goal included) or nil. ~3 ms worst case on a
-- 64x64 grid (§11's measurement).
function K.astar(gw, ok, sx, sz, gx, gz)
  if not ok(gx, gz) then return nil end
  if sx == gx and sz == gz then return {} end
  local INF = 1e18
  local gs, came, closed = {}, {}, {}
  local heap, hn = {}, 0
  local function hpush(node, f)
    hn = hn + 1
    heap[hn] = { node, f }
    local i = hn
    while i > 1 do
      local p = i // 2
      if heap[p][2] <= heap[i][2] then break end
      heap[p], heap[i] = heap[i], heap[p]
      i = p
    end
  end
  local function hpop()
    local top = heap[1]
    heap[1] = heap[hn]
    heap[hn] = nil
    hn = hn - 1
    local i = 1
    while true do
      local l, r = 2 * i, 2 * i + 1
      local sm = i
      if l <= hn and heap[l][2] < heap[sm][2] then sm = l end
      if r <= hn and heap[r][2] < heap[sm][2] then sm = r end
      if sm == i then break end
      heap[sm], heap[i] = heap[i], heap[sm]
      i = sm
    end
    return top[1]
  end
  local function hc(x, z)
    local dx, dz = m.abs(x - gx), m.abs(z - gz)
    local mn = dx < dz and dx or dz
    return (dx + dz) - 0.5858 * mn
  end
  local s0 = sz * gw + sx
  gs[s0] = 0
  hpush(s0, hc(sx, sz))
  local goal = gz * gw + gx
  while hn > 0 do
    local cur = hpop()
    if not closed[cur] then
      closed[cur] = true
      if cur == goal then break end
      local cx, cz = cur % gw, cur // gw
      for dz = -1, 1 do
        for dx = -1, 1 do
          if dx ~= 0 or dz ~= 0 then
            local nx, nz = cx + dx, cz + dz
            if ok(nx, nz) then
              local ni = nz * gw + nx
              if not closed[ni]
                 and (dx == 0 or dz == 0
                      or (ok(nx, cz) and ok(cx, nz))) then
                local step = (dx == 0 or dz == 0) and 1.0 or 1.4142135
                local ng = gs[cur] + step
                if ng < (gs[ni] or INF) then
                  gs[ni] = ng
                  came[ni] = cur
                  hpush(ni, ng + hc(nx, nz))
                end
              end
            end
          end
        end
      end
    end
  end
  if not came[goal] and s0 ~= goal then return nil end
  local path = {}
  local cur = goal
  while cur and cur ~= s0 do
    path[#path + 1] = cur
    cur = came[cur]
  end
  -- reverse in place (came walks goal -> start)
  for i = 1, #path // 2 do
    path[i], path[#path - i + 1] = path[#path - i + 1], path[i]
  end
  return path
end

-- ray -> ground hit: coarse march then bisect (the click ray's second
-- half; ~60 us measured, §11). ground(x, z) -> height is the caller's
-- sim-legal ground function. Returns hit x, z or nil past maxs steps.
function K.raycast(ground, ex, ey, ez, kx, ky, kz, step, maxs, iters)
  step = step or 0.35
  maxs = maxs or 400
  iters = iters or 14
  local prev = 0
  for s = 1, maxs do
    local t = s * step
    local x, y, z = ex + kx * t, ey + ky * t, ez + kz * t
    if y < ground(x, z) then
      local lo, hi = prev, t
      for _ = 1, iters do
        local mid = (lo + hi) * 0.5
        if ey + ky * mid < ground(ex + kx * mid, ez + kz * mid) then
          hi = mid
        else
          lo = mid
        end
      end
      local t2 = (lo + hi) * 0.5
      return ex + kx * t2, ez + kz * t2
    end
    prev = t
  end
  return nil
end

-- a world-point walk command: snap to walkable, path, arm the marker.
-- Returns true if a path exists. Silent — the caller owns the click sfx
-- (a held-repeat re-command must not spam it; D3D-027).
function K.command(buf, path_max, gw, ok, wx, wz, snap_r, marker_ttl)
  local px, pz = buf:f32(0), buf:f32(4)
  local scx, scz = K.cell(gw, px, pz)
  local gcx, gcz = K.cell(gw, wx, wz)
  gcx, gcz = K.snap(gw, ok, gcx, gcz, snap_r)
  if not gcx then return false end
  local path = K.astar(gw, ok, scx, scz, gcx, gcz)
  if not path then return false end
  local n = m.min(#path, path_max)
  for i = 1, n do buf:u32(36 + i * 4, path[i]) end
  buf:u32(16, n)
  buf:u32(20, 0)
  buf:f32(24, wx)
  buf:f32(28, wz)
  buf:f32(32, marker_ttl)
  return true
end

-- one sim step of chain-following: speed u/s (fixed 60fps), turn = the
-- facing ease factor. Also decays the click-marker ttl.
function K.step(buf, gw, speed, turn)
  local x, z = buf:f32(0), buf:f32(4)
  local len, idx = buf:u32(16), buf:u32(20)
  local left = speed / 60.0
  while idx < len and left > 1e-6 do
    local cell = buf:u32(36 + (idx + 1) * 4)
    local tx = (cell % gw) + 0.5
    local tz = (cell // gw) + 0.5
    local dx, dz = tx - x, tz - z
    local d = m.sqrt(dx * dx + dz * dz)
    if d < 1e-4 then
      idx = idx + 1
    else
      local step = m.min(d, left)
      x = x + dx / d * step
      z = z + dz / d * step
      left = left - step
      buf:f32(12, buf:f32(12) + step)
      -- ease the facing toward the travel direction (short arc)
      local want = m.atan2(dx, dz)
      local face = buf:f32(8)
      local da = m.atan2(m.sin(want - face), m.cos(want - face))
      buf:f32(8, m.fmod(face + da * turn, m.tau))
      if step >= d - 1e-6 then idx = idx + 1 end
    end
  end
  buf:f32(0, x)
  buf:f32(4, z)
  buf:u32(20, idx)
  buf:f32(32, m.max(0, buf:f32(32) - 1))
end

function K.moving(buf)
  return buf:u32(20) < buf:u32(16)
end

return K
