-- cm.input — the action map between raw PAL events and the sim
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
-- Input record v2 (D082) is ADDITIVE: the first 10 bytes are exactly v1,
-- then zero or more tagged extensions, each `u8 tag, u8 len, len bytes`.
-- A bare 10-byte record is therefore a valid v2 record, every historical
-- trace replays unchanged, and records of different lengths mix freely
-- inside one trace (FRAM stores them length-prefixed). apply() SKIPS
-- unknown tags (a future record degrades instead of erroring) but rejects
-- malformed framing or a malformed known extension loudly.
--
-- Extension tag 1 = PAD, the complete gamepad state for the frame:
--   u8 n (0..4 entries, ascending by slot, each slot at most once), then
--   per entry (11 bytes):
--     u8   slot (0..3; Lua-facing pad number minus 1)
--     u32  LE button bits (bit = SDL3 standard gamepad button number)
--     6*i8 quantized axes in wire order lx ly rx ry lt rt
-- An entry present means "connected"; absence means that slot is neutral
-- and disconnected. Deadzone + quantization to -127..127 happen on the
-- LIVE side only (integer math, quantize_axis below); the recorded value
-- is authoritative, so replay and cross-platform verify never re-derive
-- axis math from host hardware or float behavior. Device identity and
-- hot-plug are live-only concerns: an SDL device maps to a slot before
-- sampling, and connect/disconnect appears in the record purely as entry
-- presence at a frame boundary.
--
-- Applied v1 state lives in the "cm.input" named buffer (32 bytes, layout
-- below) — pressed/released derive from cur vs prev bits, so snapshots and
-- trace verify see identical edges to live play.
--   [0] u32 cur bits | [4] u32 prev bits | [8] i16 mx | [10] i16 my
--   [12] u8 buttons | [13] u8 prev buttons | [14] i8 wheel | rest reserved
--
-- Applied pad state lives in the "cm.input.pad" named buffer (96 bytes,
-- 4 slots x 24-byte stride), created only by a PAD-carrying record or a
-- pad reader — both sim-deterministic — so v1 replays never observe it.
--   slot base = slot*24:
--   [0] u32 cur buttons | [4] u32 prev buttons | [8] 6*i8 cur axes
--   [14] 6*i8 prev axes | [20] u8 connected | [21] u8 prev connected
--   [22..23] reserved
-- apply() touches pad state IFF the record carries a PAD extension (pure
-- record->state, no ambient conditions). The live sampler guarantees the
-- extension keeps coming (n=0 when nothing is connected) once the pad
-- domain has ever been active, so held buttons always see their release
-- edge; a chunkless record leaves pad state untouched (v1 exactness).
--
-- Live-side sampling quirk ("sticky tap"): a key (or pad button) pressed
-- and released between two samples still sets its bit for one record, so
-- sub-frame taps never vanish. The raw key/pad sets are live-only state;
-- replay needs only the records.

local M = select(2, ...) or {}

local pack = string.pack

M.defs = M.defs or {} -- array of {name=, keys={scancode,...}}
M.bit_of = M.bit_of or {} -- name -> bit index (0-based)
local live_keys = {} -- scancode -> true while physically held
local live_tap = {} -- scancodes that saw a down event this frame
local live_mx, live_my = 0.0, 0.0
local live_buttons = 0
local wheel_carry = 0.0
-- live pad registry: slot (1..4) -> { held = u32, tap = u32, ax = {6 raw
-- i16} }. Populated by feed()'s pad events; device->slot assignment is the
-- caller's (live-only) concern. M._pad_live is the domain latch: once any
-- pad has ever been part of a record this engine run, sample() keeps
-- emitting the PAD extension (n=0 when empty) so edges always resolve.
-- It lives on M so a hot reload cannot silently strand held pad state.
local live_pads = {}

local BUF = "cm.input"
local PADBUF = "cm.input.pad"
local PAD_SLOTS, PAD_STRIDE = 4, 24

local function buf()
  return pal.buf(BUF, 32)
end

local function padbuf()
  -- reading pad state activates the live pad domain (see the latch above):
  -- a game that polls pads keeps its record stream self-consistent even if
  -- its state was restored from a snapshot that carried pad bytes
  M._pad_live = true
  return pal.buf(PADBUF, PAD_SLOTS * PAD_STRIDE)
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

-- feed: ingest raw events into live key/mouse state. Call EVERY tick — even
-- ticks that run no sim step. This was the windowed key-stick bug: ingestion
-- used to live inside sample() (then `collect`), which only ran inside a sim
-- step, so when the render loop outran the 60 Hz sim (a >60 Hz monitor, vsync
-- on) the events polled on a zero-step tick were drained and thrown away —
-- a key-up landing on such a tick never cleared, sticking the key. live_tap
-- accumulates sub-frame taps across zero-step ticks until sample() consumes
-- them, so a press never vanishes regardless of render rate.
function M.feed(events)
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
    elseif e.type == "pad" then
      -- {type="pad", pad=1..4, connected=bool}: slot (dis)appears. Connect
      -- resets the slot; disconnect drops live state (its release edge comes
      -- from the entry vanishing off the next record).
      if e.pad >= 1 and e.pad <= PAD_SLOTS then
        if e.connected then
          live_pads[e.pad] = { held = 0, tap = 0, ax = { 0, 0, 0, 0, 0, 0 } }
          M._pad_live = true
        else
          live_pads[e.pad] = nil
        end
      end
    elseif e.type == "padbtn" then
      -- {type="padbtn", pad=1..4, button=SDL number 0..31, down=bool};
      -- events for unregistered slots are dropped (a disconnect raced them)
      local p = live_pads[e.pad]
      if p and e.button >= 0 and e.button <= 31 then
        local bit = 1 << e.button
        if e.down then
          p.held = p.held | bit
          p.tap = p.tap | bit -- sticky tap, same contract as keys
        else
          p.held = p.held & ~bit
        end
      end
    elseif e.type == "padaxis" then
      -- {type="padaxis", pad=1..4, axis=SDL number 0..5, value=raw i16}
      local p = live_pads[e.pad]
      if p and e.axis >= 0 and e.axis <= 5 then
        p.ax[e.axis + 1] = e.value
      end
    end
  end
end

-- Deadzone, live-side policy (an options knob later in A4) — NEVER part of
-- the record or the sim: records store post-deadzone quantized values, so
-- retuning it can't invalidate a trace. Default tracks XInput's stick
-- deadzone recommendation.
M.deadzone = M.deadzone or 8000

-- Quantize one raw SDL axis (-32768..32767; triggers use 0..32767) to the
-- wire's -127..127. Integer math only, exact on every platform: values at
-- or inside the deadzone collapse to 0, the remaining magnitude rescales
-- to the full range (no dead ramp), and both extremes reach exactly +-127.
function M.quantize_axis(v, dz)
  dz = math.floor(dz or M.deadzone)
  if dz < 0 then dz = 0 elseif dz > 32000 then dz = 32000 end
  local a = v < 0 and -v or v
  if a <= dz then return 0 end
  if a > 32767 then a = 32767 end
  local q = ((a - dz) * 127) // (32767 - dz)
  return v < 0 and -q or q
end

-- sample: build one input record from the current live state. Call once per
-- sim step. Clears the sub-frame tap set, so a tap registers for exactly one
-- record (sticky tap) and catch-up steps in the same tick see only held keys.
function M.sample()
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

  local rec = pack("<I4i2i2I1i1", bits,
                   iclamp(live_mx, -32768, 32767), iclamp(live_my, -32768, 32767),
                   live_buttons, wheel)

  -- the PAD extension (D082): complete connected-pad state, canonical
  -- ascending-slot encoding. Emitted every sample once the pad domain is
  -- live (n=0 after the last disconnect) so apply() always rolls edges;
  -- keyboard-only sessions stay byte-identical to v1.
  if M._pad_live then
    local parts, n = {}, 0
    for slot = 1, PAD_SLOTS do
      local p = live_pads[slot]
      if p then
        n = n + 1
        local held = p.held | p.tap
        p.tap = 0
        parts[#parts + 1] = pack("<I1I4i1i1i1i1i1i1", slot - 1, held,
                                 M.quantize_axis(p.ax[1]), M.quantize_axis(p.ax[2]),
                                 M.quantize_axis(p.ax[3]), M.quantize_axis(p.ax[4]),
                                 M.quantize_axis(p.ax[5]), M.quantize_axis(p.ax[6]))
      end
    end
    local payload = pack("<I1", n) .. table.concat(parts)
    rec = rec .. pack("<I1I1", 1, #payload) .. payload
  end
  return rec
end

-- Live-side reset for the pad domain: forget connected pads and stop
-- emitting the PAD extension. For project boot and tests — a new session
-- must not inherit the previous one's latch. Never touches applied state.
function M.pad_reset()
  live_pads = {}
  M._pad_live = nil
end

-- back-compat: feed then sample in one call. Headless lockstep (one tick =
-- one step) and selftest use this; the windowed loop calls feed/sample apart.
function M.collect(events)
  M.feed(events)
  return M.sample()
end

-- ---- the deterministic half: record -> sim-visible state ----

-- PAD extension payload -> the cm.input.pad buffer. Strict: the encoding
-- is canonical (count 0..4, ascending unique slots, exact length) and a
-- malformed known extension is a bug, not something to guess around.
local function apply_pads(p)
  local n = #p >= 1 and p:byte(1) or nil
  if not n or n > PAD_SLOTS or #p ~= 1 + 11 * n then
    error("bad pad extension in input record", 3)
  end
  local b = padbuf()
  for slot = 0, PAD_SLOTS - 1 do -- roll prev, neutralize + disconnect cur
    local base = slot * PAD_STRIDE
    b:u32(base + 4, b:u32(base))
    b:u32(base, 0)
    for a = 0, 5 do
      b:i8(base + 14 + a, b:i8(base + 8 + a))
      b:i8(base + 8 + a, 0)
    end
    b:u8(base + 21, b:u8(base + 20))
    b:u8(base + 20, 0)
  end
  local pos, last = 2, -1
  for _ = 1, n do
    local slot, btns = string.unpack("<I1I4", p, pos)
    if slot >= PAD_SLOTS or slot <= last then
      error("bad pad extension in input record", 3)
    end
    last = slot
    local base = slot * PAD_STRIDE
    b:u32(base, btns)
    for a = 0, 5 do
      b:i8(base + 8 + a, (string.unpack("<i1", p, pos + 5 + a)))
    end
    b:u8(base + 20, 1)
    pos = pos + 11
  end
end

function M.apply(record)
  if #record < 10 then error("bad input record (" .. #record .. " bytes)", 2) end
  local bits, mx, my, buttons, wheel = string.unpack("<I4i2i2I1i1", record)
  local b = buf()
  b:u32(4, b:u32(0)) -- prev bits = old cur
  b:u32(0, bits)
  b:i16(8, mx)
  b:i16(10, my)
  b:u8(13, b:u8(12)) -- prev buttons
  b:u8(12, buttons)
  b:i8(14, wheel)
  -- v2 extensions: `u8 tag, u8 len, payload` until the record ends. Unknown
  -- tags are skipped; broken framing errors. Pad state changes IFF a PAD
  -- extension is present — a bare v1 record leaves it untouched.
  local pos = 11
  local pads
  while pos <= #record do
    if pos + 1 > #record then
      error("bad input record extension framing", 2)
    end
    local tag, len = record:byte(pos), record:byte(pos + 1)
    local fin = pos + 1 + len
    if fin > #record then
      error("bad input record extension framing", 2)
    end
    if tag == 1 then
      if pads then error("duplicate pad extension in input record", 2) end
      pads = record:sub(pos + 2, fin)
    end
    pos = fin + 1
  end
  if pads then apply_pads(pads) end
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

-- ---- pad readers (D082) ----
-- pad is the Lua-facing player number 1..4 (slot = pad - 1 on the wire);
-- buttons/axes use SDL3 standard gamepad numbers (constants below), and
-- button/axis arguments also accept those constant names as strings.

local function pad_base(pad)
  if type(pad) ~= "number" or pad < 1 or pad > PAD_SLOTS then
    error("pad must be 1.." .. PAD_SLOTS, 3)
  end
  return (math.floor(pad) - 1) * PAD_STRIDE
end

local function padbit(btn)
  if type(btn) == "string" then
    btn = M.pad_btn[btn] or error("unknown pad button: " .. btn, 3)
  end
  if type(btn) ~= "number" or btn < 0 or btn > 31 then
    error("pad button must be 0..31 or a pad_btn name", 3)
  end
  return 1 << btn
end

function M.pad_connected(pad)
  return padbuf():u8(pad_base(pad) + 20) ~= 0
end

function M.pad_down(pad, btn)
  return padbuf():u32(pad_base(pad)) & padbit(btn) ~= 0
end

function M.pad_pressed(pad, btn)
  local b = padbuf()
  local base, m = pad_base(pad), padbit(btn)
  return b:u32(base) & m ~= 0 and b:u32(base + 4) & m == 0
end

function M.pad_released(pad, btn)
  local b = padbuf()
  local base, m = pad_base(pad), padbit(btn)
  return b:u32(base) & m == 0 and b:u32(base + 4) & m ~= 0
end

-- quantized axis value, -127..127 (triggers 0..127); integer, so sim code
-- stays trivially deterministic (divide by 127 yourself if you want -1..1)
function M.pad_axis(pad, axis)
  if type(axis) == "string" then
    axis = M.pad_ax[axis] or error("unknown pad axis: " .. axis, 2)
  end
  if type(axis) ~= "number" or axis < 0 or axis > 5 then
    error("pad axis must be 0..5 or a pad_ax name", 2)
  end
  return padbuf():i8(pad_base(pad) + 8 + axis)
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

-- SDL3 standard gamepad button numbers (SDL_GamepadButton) — the wire bit
-- for each is 1 << number. south/east/west/north are positional (south =
-- the bottom face button = Xbox A / Nintendo B).
M.pad_btn = {
  south = 0, east = 1, west = 2, north = 3,
  back = 4, guide = 5, start = 6,
  lstick = 7, rstick = 8, lshoulder = 9, rshoulder = 10,
  dpup = 11, dpdown = 12, dpleft = 13, dpright = 14,
  misc1 = 15, rpaddle1 = 16, lpaddle1 = 17, rpaddle2 = 18, lpaddle2 = 19,
  touchpad = 20,
}

-- SDL3 standard gamepad axis numbers (SDL_GamepadAxis) = the wire order
M.pad_ax = { lx = 0, ly = 1, rx = 2, ry = 3, lt = 4, rt = 5 }

return M
