-- props — the crate pit: AABB crates that fall, bounce, shove each other,
-- and can be grabbed and thrown (rotation arrives with the real solver,
-- post-M10). Crates collide with the tilemap through the same mover the
-- player uses; crate-vs-crate is a cheap fixed-order separation pass that
-- keeps piles settled and lets a thrown crate plow into them.
--
-- sandbox.props layout: [0] u32 count | [4..15] reserved
--   then per prop 32B: x y vx vy w h (f32) | state (f32: 0 free, 1 held) |
--   hue (f32, draw tint variety)

local m = pt.require("pt.math")
local state = pt.require("pt.state")
local level = pt.require("level")
local fx = pt.require("fx")

local M = {}

local DT = 1.0 / 60.0
local HDR = 16
local STRIDE = 32
local MAX = 16

local buf

local function off(i) -- 1-based prop index
  return HDR + (i - 1) * STRIDE
end

function M.count()
  return buf:u32(0)
end

function M.init()
  buf = pal.buf("sandbox.props", HDR + MAX * STRIDE)
  if buf:u32(0) == 0 then -- virgin: seed the pit
    local spots = level.prop_spots
    buf:u32(0, #spots)
    for i, s in ipairs(spots) do
      local p = off(i)
      buf:f32(p, s[1])
      buf:f32(p + 4, s[2])
      buf:f32(p + 8, 0)
      buf:f32(p + 12, 0)
      buf:f32(p + 16, 12)
      buf:f32(p + 20, 12)
      buf:f32(p + 24, 0)
      buf:f32(p + 28, (i * 0.6180339887) % 1.0)
    end
  end
end

function M.get(i)
  local p = off(i)
  return buf:f32(p), buf:f32(p + 4), buf:f32(p + 16), buf:f32(p + 20)
end

function M.held(i)
  return buf:f32(off(i) + 24) == 1.0
end

-- nearest free crate whose center is within radius of (cx, cy)
function M.nearest_free(cx, cy, radius)
  local best, best_d2
  for i = 1, M.count() do
    local p = off(i)
    if buf:f32(p + 24) == 0.0 then
      local dx = buf:f32(p) + buf:f32(p + 16) * 0.5 - cx
      local dy = buf:f32(p + 4) + buf:f32(p + 20) * 0.5 - cy
      local d2 = dx * dx + dy * dy
      if d2 <= radius * radius and (not best_d2 or d2 < best_d2) then
        best, best_d2 = i, d2
      end
    end
  end
  return best
end

function M.grab(i)
  buf:f32(off(i) + 24, 1.0)
end

-- carried crate follows the player (kinematic while held)
function M.pin(i, x, y)
  local p = off(i)
  buf:f32(p, x)
  buf:f32(p + 4, y)
  buf:f32(p + 8, 0)
  buf:f32(p + 12, 0)
end

function M.throw(i, vx, vy)
  local p = off(i)
  buf:f32(p + 24, 0.0)
  buf:f32(p + 8, vx)
  buf:f32(p + 12, vy)
end

function M.step()
  local k = state.doc.knobs
  local tm = level.tm
  -- props fall under their own world gravity (knobs.prop): the player's
  -- is a derived feel curve since D029 and must not float the crates
  local g, fall_max = k.prop.gravity, k.prop.fall_max
  local rest, wall_rest, fric = k.prop.rest, k.prop.wall_rest, k.prop.fric
  local n = M.count()

  for i = 1, n do
    local p = off(i)
    if buf:f32(p + 24) == 0.0 then
      local x, y = buf:f32(p), buf:f32(p + 4)
      local vx, vy = buf:f32(p + 8), buf:f32(p + 12)
      local w, h = buf:f32(p + 16), buf:f32(p + 20)
      vy = m.min(vy + g * DT, fall_max)
      local nx, ny, hit = tm:move(x, y, w, h, vx * DT, vy * DT)
      if hit.down then
        if vy > 90 then
          fx.spawn(nx + w * 0.5, ny + h, 3 + m.floor(vy / 110),
                   { vx0 = -45, vx1 = 45, vy0 = -60, vy1 = -15,
                     shade0 = 0.2, shade1 = 0.9 })
        end
        vy = vy > 70 and -vy * rest or 0
        vx = vx * m.max(0.0, 1.0 - fric * DT)
      elseif hit.up then
        vy = -vy * 0.2
      end
      if hit.left or hit.right then
        if m.abs(vx) > 130 then
          fx.spawn(hit.left and nx or nx + w, ny + h * 0.5, 3,
                   { vx0 = hit.left and 10 or -60, vx1 = hit.left and 60 or -10,
                     vy0 = -70, vy1 = -20, shade0 = 1.6, shade1 = 2.4 })
        end
        vx = -vx * wall_rest
      end
      buf:f32(p, nx)
      buf:f32(p + 4, ny)
      buf:f32(p + 8, vx)
      buf:f32(p + 12, vy)
    end
  end

  -- separation: fixed pair order, two passes; vertical contacts settle
  -- stacks, horizontal contacts shove (inelastic with a touch of bounce)
  for _ = 1, 2 do
    for i = 1, n - 1 do
      if buf:f32(off(i) + 24) == 0.0 then
        for j = i + 1, n do
          if buf:f32(off(j) + 24) == 0.0 then
            local pi, pj = off(i), off(j)
            local ix, iy = buf:f32(pi), buf:f32(pi + 4)
            local jx, jy = buf:f32(pj), buf:f32(pj + 4)
            local iw, ih = buf:f32(pi + 16), buf:f32(pi + 20)
            local jw, jh = buf:f32(pj + 16), buf:f32(pj + 20)
            local ox = m.min(ix + iw, jx + jw) - m.max(ix, jx)
            local oy = m.min(iy + ih, jy + jh) - m.max(iy, jy)
            if ox > 0 and oy > 0 then
              if oy <= ox then -- stack: push the upper one up
                local up, upo = i, pi
                if jy + jh * 0.5 < iy + ih * 0.5 then up, upo = j, pj end
                local ux, uy = buf:f32(upo), buf:f32(upo + 4)
                local uw, uh = buf:f32(upo + 16), buf:f32(upo + 20)
                local _, ry = tm:move(ux, uy, uw, uh, 0, -oy)
                buf:f32(upo + 4, ry)
                local uvy = buf:f32(upo + 12)
                buf:f32(upo + 12, uvy > 70 and -uvy * rest or 0)
                buf:f32(upo + 8, buf:f32(upo + 8) * m.max(0, 1 - fric * DT))
              else -- side contact: split the push, damp approach
                local push = ox * 0.5
                local li, lj = pi, pj -- li = the one on the left
                if jx < ix then li, lj = pj, pi end
                local lx, ly = buf:f32(li), buf:f32(li + 4)
                local lw, lh = buf:f32(li + 16), buf:f32(li + 20)
                local rx2, ry2 = buf:f32(lj), buf:f32(lj + 4)
                local rw, rh = buf:f32(lj + 16), buf:f32(lj + 20)
                local nlx = tm:move(lx, ly, lw, lh, -push, 0)
                local nrx = tm:move(rx2, ry2, rw, rh, push, 0)
                buf:f32(li, nlx)
                buf:f32(lj, nrx)
                local vi, vj = buf:f32(li + 8), buf:f32(lj + 8)
                if vi > vj then -- approaching
                  local avg = (vi + vj) * 0.5
                  buf:f32(li + 8, avg + (vi - avg) * -rest)
                  buf:f32(lj + 8, avg + (vj - avg) * -rest)
                end
              end
            end
          end
        end
      end
    end
  end
end

function M.draw()
  local tex = level.tex
  local uv = level.crate_uv
  local u0, v0 = uv.u / tex.w, uv.v / tex.h
  local u1, v1 = (uv.u + uv.w) / tex.w, (uv.v + uv.h) / tex.h
  for i = 1, M.count() do
    local p = off(i)
    local hue = buf:f32(p + 28)
    local t = 0.88 + 0.12 * hue
    pal.quad(buf:f32(p), buf:f32(p + 4), buf:f32(p + 16), buf:f32(p + 20),
             t, t * (0.94 + 0.06 * hue), t * 0.92, 1, tex.id, u0, v0, u1, v1)
  end
end

return M
