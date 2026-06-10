-- pt.input — the action map between raw PAL events and the sim
-- (ARCHITECTURE "Input"). The sim NEVER reads events: each sim frame is fed
-- one compact input record, and live play and trace replay go through the
-- same apply() path, so record & replay are symmetrical by construction.
--
-- Input record v1, FROZEN (10 bytes, the per-frame trace unit):
--   u32 LE  action down-bits (bit = action definition order, max 32)
--   i16 LE  mouse x, i16 LE mouse y (internal pixels, floored, clamped)
--   u8      mouse buttons bitfield (button 1..8 -> bit 0..7)
--   i8      wheel steps this frame (accumulated, clamped)
--
-- Applied state lives in the "pt.input" named buffer (32 bytes, layout
-- below) — pressed/released derive from cur vs prev bits, so snapshots and
-- trace verify see identical edges to live play.
--   [0] u32 cur bits | [4] u32 prev bits | [8] i16 mx | [10] i16 my
--   [12] u8 buttons | [13] u8 prev buttons | [14] i8 wheel | rest reserved
--
-- Live-side sampling quirk ("sticky tap"): a key pressed and released
-- between two samples still sets its bit for one record, so sub-frame taps
-- never vanish. The raw key set is live-only state; replay needs only the
-- records.

local M = select(2, ...) or {}

local pack = string.pack

M.defs = M.defs or {} -- array of {name=, keys={scancode,...}}
M.bit_of = M.bit_of or {} -- name -> bit index (0-based)
local live_keys = {} -- scancode -> true while physically held
local live_tap = {} -- scancodes that saw a down event this frame
local live_mx, live_my = 0.0, 0.0
local live_buttons = 0
local wheel_carry = 0.0

local BUF = "pt.input"

local function buf()
  return pal.buf(BUF, 32)
end

-- ---- map definition ----

-- define("jump", {44, 82}): appends an action (bit = order of first
-- definition); redefining an existing name just rebinds its keys
function M.define(name, keys)
  if M.bit_of[name] == nil then
    if #M.defs >= 32 then error("action map full (32 actions max)", 2) end
    M.bit_of[name] = #M.defs
    M.defs[#M.defs + 1] = { name = name, keys = {} }
  end
  local def = M.defs[M.bit_of[name] + 1]
  def.keys = {}
  for _, sc in ipairs(keys) do def.keys[#def.keys + 1] = sc end
end

-- map{ {"jump", 44}, {"left", 80, 4}, ... } — array form so action order
-- (and therefore record bit layout) is deterministic
function M.map(list)
  for _, row in ipairs(list) do
    local keys = table.move(row, 2, #row, 1, {})
    M.define(row[1], keys)
  end
end

-- action names in bit order (trace headers store this)
function M.actions()
  local names = {}
  for i, def in ipairs(M.defs) do names[i] = def.name end
  return names
end

-- ---- live sampling: raw events -> record ----

local function iclamp(v, lo, hi)
  v = math.floor(v)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function M.collect(events)
  for _, e in ipairs(events) do
    if e.type == "key" then
      if e.down then
        if not e.rep then live_tap[e.scancode] = true end
        live_keys[e.scancode] = true
      else
        live_keys[e.scancode] = nil
      end
    elseif e.type == "motion" then
      live_mx, live_my = e.x, e.y
    elseif e.type == "button" then
      live_mx, live_my = e.x, e.y
      local bit = 1 << ((e.button - 1) & 7)
      if e.down then
        live_buttons = live_buttons | bit
      else
        live_buttons = live_buttons & ~bit
      end
    elseif e.type == "wheel" then
      wheel_carry = wheel_carry + e.dy
    end
  end

  local bits = 0
  for i, def in ipairs(M.defs) do
    for _, sc in ipairs(def.keys) do
      if live_keys[sc] or live_tap[sc] then
        bits = bits | (1 << (i - 1))
        break
      end
    end
  end
  live_tap = {}

  local wheel = 0
  if wheel_carry >= 1.0 or wheel_carry <= -1.0 then
    wheel = math.tointeger(wheel_carry >= 0 and math.floor(wheel_carry)
                           or -math.floor(-wheel_carry))
    wheel_carry = wheel_carry - wheel
    if wheel > 127 then wheel = 127 elseif wheel < -127 then wheel = -127 end
  end

  return pack("<I4i2i2I1i1", bits,
              iclamp(live_mx, -32768, 32767), iclamp(live_my, -32768, 32767),
              live_buttons, wheel)
end

-- ---- the deterministic half: record -> sim-visible state ----

function M.apply(record)
  if #record ~= 10 then error("bad input record (" .. #record .. " bytes)", 2) end
  local bits, mx, my, buttons, wheel = string.unpack("<I4i2i2I1i1", record)
  local b = buf()
  b:u32(4, b:u32(0)) -- prev bits = old cur
  b:u32(0, bits)
  b:i16(8, mx)
  b:i16(10, my)
  b:u8(13, b:u8(12)) -- prev buttons
  b:u8(12, buttons)
  b:i8(14, wheel)
end

local function bitfor(name)
  local i = M.bit_of[name]
  if i == nil then error("unknown action: " .. tostring(name), 3) end
  return 1 << i
end

function M.down(name)
  return buf():u32(0) & bitfor(name) ~= 0
end

function M.pressed(name)
  local b = buf()
  local m = bitfor(name)
  return b:u32(0) & m ~= 0 and b:u32(4) & m == 0
end

function M.released(name)
  local b = buf()
  local m = bitfor(name)
  return b:u32(0) & m == 0 and b:u32(4) & m ~= 0
end

function M.mouse()
  local b = buf()
  return b:i16(8), b:i16(10)
end

function M.button_down(n)
  return buf():u8(12) & (1 << ((n - 1) & 7)) ~= 0
end

function M.button_pressed(n)
  local b = buf()
  local m = 1 << ((n - 1) & 7)
  return b:u8(12) & m ~= 0 and b:u8(13) & m == 0
end

function M.wheel()
  return buf():i8(14)
end

-- common SDL/USB-HID scancodes so projects don't hardcode magic numbers
-- (full names via pal.scancode_name)
M.key = {
  a = 4, b = 5, c = 6, d = 7, e = 8, f = 9, g = 10, h = 11, i = 12, j = 13,
  k = 14, l = 15, m = 16, n = 17, o = 18, p = 19, q = 20, r = 21, s = 22,
  t = 23, u = 24, v = 25, w = 26, x = 27, y = 28, z = 29,
  ["1"] = 30, ["2"] = 31, ["3"] = 32, ["4"] = 33, ["5"] = 34,
  ["6"] = 35, ["7"] = 36, ["8"] = 37, ["9"] = 38, ["0"] = 39,
  ret = 40, escape = 41, backspace = 42, tab = 43, space = 44,
  minus = 45, equals = 46,
  grave = 53, -- engine-reserved: console toggle (M2)
  f1 = 58, f2 = 59, f3 = 60, f4 = 61, f5 = 62, f6 = 63,
  insert = 73, home = 74, pageup = 75, delete = 76, ["end"] = 77,
  pagedown = 78,
  right = 79, left = 80, down = 81, up = 82,
  lctrl = 224, lshift = 225, lalt = 226,
}

return M
