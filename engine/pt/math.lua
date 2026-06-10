-- pt.math — deterministic transcendentals for sim code.
--
-- libm sin/cos/atan differ in the last bits between platforms/libcs, which
-- breaks bit-exact replay; these implementations use only IEEE-754 f64
-- + - * / (and sqrt/floor, also exact), so results are identical everywhere.
-- Kernels and constants follow fdlibm (Sun, the classic reference libm).
--
-- Domain: |x| <= 2^20 radians for sin/cos/tan (keep accumulated angles
-- wrapped!); larger args error loudly rather than silently losing accuracy.
-- Accuracy: a few ulp; the selftest cartridge enforces <= 1e-11 absolute
-- against the host libm over dense sweeps.
--
-- Sim-safe stock functions (exact by IEEE/Lua semantics, use freely):
--   math.floor/ceil/abs/min/max/sqrt/fmod/modf/tointeger, integer ops, % //
-- Banned in sim code: math.sin/cos/tan/asin/acos/atan/exp/log/pow/random.

local M = {}

M.pi = 3.14159265358979311600e+00 -- nearest f64 to pi
M.tau = 6.28318530717958623200e+00

local floor, sqrt, abs = math.floor, math.sqrt, math.abs

local MAXARG = 1048576.0 -- 2^20

-- ---- sin/cos ----
-- Cody-Waite reduction: n = nearest int to x*(2/pi); r = x - n*pi/2 using a
-- two-part pi/2 (high part's low mantissa bits are zero, so n*PIO2_1 and the
-- subtraction are exact for |n| < 2^26); kernels evaluate on |r| <= pi/4.
local INV_PIO2 = 6.36619772367581382433e-01
local PIO2_1 = 1.57079632673412561417e+00
local PIO2_1T = 6.07710050650619224932e-11

local S1 = -1.66666666666666324348e-01
local S2 = 8.33333333332248946124e-03
local S3 = -1.98412698298579493134e-04
local S4 = 2.75573137070700676789e-06
local S5 = -2.50507602534068634195e-08
local S6 = 1.58969099521155010221e-10

local C1 = 4.16666666666666019037e-02
local C2 = -1.38888888888741095749e-03
local C3 = 2.48015872894767294178e-05
local C4 = -2.75573143513906633035e-07
local C5 = 2.08757232129817482790e-09
local C6 = -1.13596475577881948265e-11

local function ksin(x)
  local z = x * x
  local v = z * x
  local r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
  return x + v * (S1 + z * r)
end

local function kcos(x)
  local z = x * x
  local r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
  return 1.0 - (0.5 * z - z * r)
end

local function reduce(x)
  local n = floor(x * INV_PIO2 + 0.5)
  local r = (x - n * PIO2_1) - n * PIO2_1T
  return n % 4, r
end

local function checkangle(x, who)
  if not (x >= -MAXARG and x <= MAXARG) then
    error("pt.math." .. who .. ": |x| > 2^20 (or NaN) — wrap your angles", 3)
  end
end

function M.sin(x)
  checkangle(x, "sin")
  if x > -0.7853981633974483 and x < 0.7853981633974483 then return ksin(x) end
  local q, r = reduce(x)
  if q == 0 then return ksin(r)
  elseif q == 1 then return kcos(r)
  elseif q == 2 then return -ksin(r)
  else return -kcos(r) end
end

function M.cos(x)
  checkangle(x, "cos")
  if x > -0.7853981633974483 and x < 0.7853981633974483 then return kcos(x) end
  local q, r = reduce(x)
  if q == 0 then return kcos(r)
  elseif q == 1 then return -ksin(r)
  elseif q == 2 then return -kcos(r)
  else return ksin(r) end
end

function M.tan(x)
  checkangle(x, "tan")
  return M.sin(x) / M.cos(x)
end

-- ---- atan / atan2 ----
-- fdlibm s_atan: reduce |x| into one of five intervals via exact-ish
-- transforms, evaluate an odd/even split polynomial, add back the interval's
-- two-part arctangent constant.
local ATANHI = {
  4.63647609000806093515e-01, -- atan(0.5)
  7.85398163397448278999e-01, -- atan(1.0)
  9.82793723247329054082e-01, -- atan(1.5)
  1.57079632679489655800e+00, -- atan(inf) = pi/2
}
local ATANLO = {
  2.26987774529616870924e-17,
  3.06161699786838301793e-17,
  1.39033110312309984516e-17,
  6.12323399573676603587e-17,
}
local AT0 = 3.33333333333329318027e-01
local AT1 = -1.99999999998764832476e-01
local AT2 = 1.42857142725034663711e-01
local AT3 = -1.11111104054623557880e-01
local AT4 = 9.09088713343650656196e-02
local AT5 = -7.69187620504482999495e-02
local AT6 = 6.66107313738753120669e-02
local AT7 = -5.83357013379057348645e-02
local AT8 = 4.97687799461593236017e-02
local AT9 = -3.65315727442169155270e-02
local AT10 = 1.62858201153657823623e-02

local function atan_poly(x)
  local z = x * x
  local w = z * z
  local s1 = z * (AT0 + w * (AT2 + w * (AT4 + w * (AT6 + w * (AT8 + w * AT10)))))
  local s2 = w * (AT1 + w * (AT3 + w * (AT5 + w * (AT7 + w * AT9))))
  return s1 + s2
end

function M.atan(x)
  if x ~= x then error("pt.math.atan: NaN", 2) end
  local sign = x < 0
  local ax = abs(x)
  local r
  if ax >= 7.37869762948382064634e+19 then -- 2^66: poly transforms degenerate
    r = ATANHI[4] + ATANLO[4]
  elseif ax < 0.4375 then -- 7/16: no reduction
    r = ax - ax * atan_poly(ax)
  else
    local id
    if ax < 0.6875 then -- 11/16
      id = 1
      ax = (2.0 * ax - 1.0) / (2.0 + ax)
    elseif ax < 1.1875 then -- 19/16
      id = 2
      ax = (ax - 1.0) / (ax + 1.0)
    elseif ax < 2.4375 then -- 39/16
      id = 3
      ax = (ax - 1.5) / (1.0 + 1.5 * ax)
    else
      id = 4
      ax = -1.0 / ax
    end
    r = ATANHI[id] - ((ax * atan_poly(ax) - ATANLO[id]) - ax)
  end
  if sign then return -r end
  return r
end

local PI_LO = 1.22464679914735317720e-16 -- pi = M.pi + PI_LO

-- atan2(y, x): angle of the point (x, y), in (-pi, pi]
function M.atan2(y, x)
  if y ~= y or x ~= x then error("pt.math.atan2: NaN", 2) end
  if y == 0.0 then
    if x >= 0.0 then return y end -- +-0 by sign of y
    if 1.0 / y < 0.0 then return -(M.pi + PI_LO) end -- y is -0
    return M.pi + PI_LO
  end
  if x == 0.0 then
    if y > 0.0 then return ATANHI[4] + ATANLO[4] end
    return -(ATANHI[4] + ATANLO[4])
  end
  local z = M.atan(abs(y / x))
  if x > 0.0 then
    if y < 0 then return -z end
    return z
  end
  -- x < 0: fold into the far quadrants with the two-part pi for accuracy
  local r = M.pi - (z - PI_LO)
  if y < 0 then return -r end
  return r
end

-- asin/acos via atan2 identities; inputs clamped to [-1, 1] (game-friendly:
-- dot products drift a hair out of range and should not crash the sim)
function M.asin(x)
  if x ~= x then error("pt.math.asin: NaN", 2) end
  if x < -1.0 then x = -1.0 elseif x > 1.0 then x = 1.0 end
  return M.atan2(x, sqrt((1.0 - x) * (1.0 + x)))
end

function M.acos(x)
  if x ~= x then error("pt.math.acos: NaN", 2) end
  if x < -1.0 then x = -1.0 elseif x > 1.0 then x = 1.0 end
  return M.atan2(sqrt((1.0 - x) * (1.0 + x)), x)
end

-- exact IEEE; provided here so sim code can grab everything from pt.math
M.sqrt = math.sqrt
M.floor = math.floor
M.ceil = math.ceil
M.abs = math.abs
M.min = math.min
M.max = math.max
M.fmod = math.fmod

function M.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function M.round(x)
  return floor(x + 0.5)
end

function M.lerp(a, b, t)
  return a + (b - a) * t
end

return M
