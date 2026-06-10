-- pt.ease — easing curves, a first-class citizen of the feel pillar.
-- Every curve is a pure deterministic f(t): [0,1] -> [0,1] built on pt.math
-- (sim-safe everywhere: knobs, timelines, tweens, camera, audio envelopes).
--
-- Curves are addressable BY NAME through a registry: sim state can't hold
-- functions, so anything stored in the doc tree / buffers (a tween's curve,
-- a knob's response) stores the *name* and resolves at use time with
-- pt.ease.get(name). Game-defined curves join via pt.ease.register — the
-- registering code travels in snapshots/traces (D012), so named curves
-- replay exactly.
--
-- Naming: <family>_in accelerates, <family>_out decelerates, <family>_inout
-- does both. "linear" is the identity. Use out-curves for things that react
-- to the player (snappy start, soft landing).

local M = select(2, ...) or {}
local m = pt.require("pt.math")

local curves = {}

-- registered curves are endpoint-pinned: f(t<=0) = 0 and f(t>=1) = 1
-- exactly, so eased values land precisely on their targets (no 1-6e-17
-- residue from trig-based curves drifting a snapped position)
function M.register(name, fn)
  if type(name) ~= "string" or type(fn) ~= "function" then
    error("pt.ease.register(name, fn)", 2)
  end
  local pinned = function(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return fn(t)
  end
  curves[name] = pinned
  M[name] = pinned
  return pinned
end

-- resolve a curve: accepts a name (sim-state friendly) or a function
-- (code-side convenience); errors loudly on unknown names
function M.get(curve)
  if type(curve) == "function" then return curve end
  local fn = curves[curve]
  if not fn then error("unknown easing: " .. tostring(curve), 2) end
  return fn
end

-- eased interpolation: mix(a, b, t, "cubic_out")
function M.mix(a, b, t, curve)
  return a + (b - a) * M.get(curve)(m.clamp(t, 0.0, 1.0))
end

-- the curve names, sorted — for editor pickers and docs
function M.names()
  local out = {}
  for n in pairs(curves) do out[#out + 1] = n end
  table.sort(out)
  return out
end

-- ---- the standard family ----

local function reg(name, fin)
  -- derive out/inout from in: out(t) = 1 - in(1-t); inout splices at 0.5
  M.register(name .. "_in", fin)
  M.register(name .. "_out", function(t) return 1.0 - fin(1.0 - t) end)
  M.register(name .. "_inout", function(t)
    if t < 0.5 then return 0.5 * fin(2.0 * t) end
    return 1.0 - 0.5 * fin(2.0 - 2.0 * t)
  end)
end

M.register("linear", function(t) return t end)

reg("quad", function(t) return t * t end)
reg("cubic", function(t) return t * t * t end)
reg("quart", function(t) return t * t * t * t end)
reg("quint", function(t) return t * t * t * t * t end)

reg("sine", function(t)
  return 1.0 - m.cos(t * (m.pi * 0.5))
end)

reg("expo", function(t)
  if t <= 0.0 then return 0.0 end
  return m.exp2(10.0 * t - 10.0)
end)

reg("circ", function(t)
  return 1.0 - m.sqrt(1.0 - t * t)
end)

local BACK_S = 1.70158 -- classic Penner overshoot (~10%)
reg("back", function(t)
  return t * t * ((BACK_S + 1.0) * t - BACK_S)
end)

reg("elastic", function(t)
  if t <= 0.0 then return 0.0 end
  if t >= 1.0 then return 1.0 end
  return -m.exp2(10.0 * t - 10.0) * m.sin((t * 10.0 - 10.75) * (m.tau / 3.0))
end)

-- bounce is authored as an out-curve (balls land, they don't launch);
-- derive in/inout from it instead
local function bounce_out(t)
  local n1, d1 = 7.5625, 2.75
  if t < 1.0 / d1 then
    return n1 * t * t
  elseif t < 2.0 / d1 then
    t = t - 1.5 / d1
    return n1 * t * t + 0.75
  elseif t < 2.5 / d1 then
    t = t - 2.25 / d1
    return n1 * t * t + 0.9375
  end
  t = t - 2.625 / d1
  return n1 * t * t + 0.984375
end
M.register("bounce_out", bounce_out)
M.register("bounce_in", function(t) return 1.0 - bounce_out(1.0 - t) end)
M.register("bounce_inout", function(t)
  if t < 0.5 then return 0.5 * (1.0 - bounce_out(1.0 - 2.0 * t)) end
  return 0.5 * bounce_out(2.0 * t - 1.0) + 0.5
end)

return M
