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
-- Extension tag 2 = MREL, the frame's relative mouse motion (the v21
-- captured-cursor look; the cosmic3d merge):
--   i16 LE dx, i16 LE dy — whole internal pixels this frame (the live
--   sampler carries the float remainder, so slow motion is never lost).
-- Emitted every sample once capture_mouse() has been used this session
-- (the _pad_live model), so a capture-free session stays byte-identical
-- to before. Applying ANY record zeroes the deltas first — a record
-- without MREL means "no relative motion", so v1 replays read (0,0).
-- Capture itself (pal.x_mouse_capture) is live-side chrome policy like
-- device identity: replay never re-captures, the recorded deltas are the
-- authority.
--
-- Extension tag 3 = FSIZ, the frame's live game-target size (D123 — the
-- editor's game window resizes the FOV live; 3D aspect + screen->world
-- unprojection must see it deterministically):
--   i16 LE w, i16 LE h — pal.gfx_size() at sample time.
-- Emitted every sample once game_size() has been read this session (the
-- _pad_live model), so a size-blind session stays byte-identical to
-- before. Unlike MREL this is a LATCH, not a delta: a record without
-- FSIZ leaves the applied size untouched, and until any sized record
-- applies, game_size() returns the project's design resolution — which
-- IS the boot target, so pre-FSIZ traces and record/replay agree by
-- construction. Sim code reads game_size(), never pal.gfx_size().
--
-- Applied v1 state lives in the "cm.input" named buffer (32 bytes, layout
-- below) — pressed/released derive from cur vs prev bits, so snapshots and
-- trace verify see identical edges to live play.
--   [0] u32 cur bits | [4] u32 prev bits | [8] i16 mx | [10] i16 my
--   [12] u8 buttons | [13] u8 prev buttons | [14] i8 wheel
--   [16] i16 rel dx | [18] i16 rel dy (MREL, v21)
--   [20] i16 fsiz w | [22] i16 fsiz h (FSIZ, D123; 0 = never sized)
--   rest reserved
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

M.defs = M.defs or {} -- array of {name=, binds=, canon=, defaults=} (below)
M.bit_of = M.bit_of or {} -- name -> bit index (0-based)
-- user rebinds (A4/D084): action name -> array of canonical binding strings,
-- replacing that action's code-declared defaults. Loaded from the project's
-- machine-local input.dat (video.dat class: interactive sessions only, never
-- exported), mutated by the options-menu rebind UI. Lives on M so a hot
-- reload keeps the player's bindings.
M._overrides = M._overrides or {}
local live_keys = {} -- scancode -> true while physically held
local live_tap = {} -- scancodes that saw a down event this frame
local live_mx, live_my = 0.0, 0.0
local live_buttons = 0
local wheel_carry = 0.0
-- relative-mouse accumulation (MREL, v21): float game-px deltas gather
-- here between samples; sample() emits whole pixels and carries the
-- remainder (the wheel_carry model). M._mrel_live is the domain latch —
-- capture_mouse() sets it and sample() then emits the MREL extension
-- every record (zeros included) for the rest of the session.
local rel_carry_x, rel_carry_y = 0.0, 0.0
-- live pad registry: slot (1..4) -> { held = u32, tap = u32, ax = {6 raw
-- i16} }. Populated by feed()'s pad events. M._pad_live is the domain
-- latch: once any pad has ever been part of a record this engine run,
-- sample() keeps emitting the PAD extension (n=0 when empty) so edges
-- always resolve. It lives on M so a hot reload cannot silently strand
-- held pad state.
local live_pads = {}
-- device->slot assignment (live-only, the A4 policy): the PAL hands feed()
-- DEVICE-level gpad/gpadbtn/gpadaxis events keyed by SDL instance id; the
-- first-connected device claims the lowest free slot 1..4 and keeps it
-- until disconnect, a fifth device is ignored (logged) until a slot frees,
-- and a reconnect is just a fresh claim. The slot-level pad/padbtn/padaxis
-- shapes remain feed()'s direct vocabulary (tests, future remote input).
local live_dev = {}

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

-- Bindings (A4/D084): an action holds a LIST of bindings, each a keyboard
-- key, a pad button, or a pad axis direction, all feeding the same v1
-- action bit at sample() time — pure live-side policy, so rebinding can
-- never invalidate a trace (D082 planned exactly this). A binding is a
-- raw scancode number or a descriptor string; the canonical forms are
--   "key:<scancode>"       keyboard (numbers normalize to this)
--   "pad:<button>"         pad 1 standard button, e.g. "pad:south"
--   "pad:<axis><+|->"      pad 1 axis past the threshold, e.g. "pad:lx-"
--   "pad<2|3|4>:..."       the same, pinned to another pad slot
-- Buttons/axes use the SDL names in M.pad_btn / M.pad_ax (numbers 0..31
-- are accepted for buttons and canonicalize to the name when one exists).

-- how far a bound stick axis must deflect (quantized, of 127) to count as
-- "down". Live-side policy like the deadzone: recorded action bits bake it
-- in, so retuning never touches replay. Player knob (A4/D085): set through
-- set_axis_threshold, persisted beside the rebinds in input.dat.
M.DEF_AXIS_THRESHOLD = 40
M.axis_threshold = M.axis_threshold or M.DEF_AXIS_THRESHOLD

-- the knob setters (the options menu / project code): clamp to sane ranges,
-- return the applied value. Call save_binds() to persist — the knobs live in
-- the same machine-local store as the rebind overrides.
function M.set_axis_threshold(v)
  v = math.floor(tonumber(v) or M.DEF_AXIS_THRESHOLD)
  if v < 1 then v = 1 elseif v > 127 then v = 127 end
  M.axis_threshold = v
  return v
end

function M.set_deadzone(v)
  v = math.floor(tonumber(v) or M.DEF_DEADZONE)
  if v < 0 then v = 0 elseif v > 32000 then v = 32000 end
  M.deadzone = v
  return v
end

local AXIS_DIR = { ["+"] = 1, ["-"] = -1 }

-- reverse name tables for canonicalization + labels (filled after the
-- constant tables at the bottom of the module, at load time)
local btn_name, ax_name = {}, {}

-- parse one binding (number or descriptor string) -> {k="key", sc=} |
-- {k="btn", pad=, btn=} | {k="ax", pad=, ax=, dir=}. Errors name the
-- binding so a bad store entry / rebind call is loud.
local function parse_bind(bind, lvl)
  lvl = (lvl or 2) + 1
  if type(bind) == "number" then
    local sc = math.floor(bind)
    if sc < 0 or sc > 511 then error("bad scancode: " .. bind, lvl) end
    return { k = "key", sc = sc }
  end
  if type(bind) ~= "string" then
    error("bad binding: " .. tostring(bind), lvl)
  end
  local kind, rest = bind:match("^(%l+%d?):(.+)$")
  if kind == "key" then
    local sc = rest:match("^%d+$") and math.tointeger(rest)
    if not sc or sc > 511 then error("bad binding: " .. bind, lvl) end
    return { k = "key", sc = sc }
  end
  local padn = kind == "pad" and 1 or kind and kind:match("^pad([1-4])$")
  if padn then
    padn = math.tointeger(padn)
    local ax, dir = rest:match("^(%l+)([%+%-])$")
    if ax and M.pad_ax[ax] then
      return { k = "ax", pad = padn, ax = M.pad_ax[ax], dir = AXIS_DIR[dir] }
    end
    local btn = M.pad_btn[rest]
    if not btn and rest:match("^%d+$") then
      btn = math.tointeger(rest)
      if btn > 31 then btn = nil end
    end
    if btn then return { k = "btn", pad = padn, btn = btn } end
  end
  error("bad binding: " .. bind, lvl)
end

local function canon_bind(b)
  if b.k == "key" then return "key:" .. b.sc end
  local prefix = b.pad == 1 and "pad:" or ("pad" .. b.pad .. ":")
  if b.k == "btn" then return prefix .. (btn_name[b.btn] or b.btn) end
  return prefix .. ax_name[b.ax] .. (b.dir > 0 and "+" or "-")
end

-- the active bindings for one def: the user override when one exists,
-- else the code-declared defaults. def.binds = parsed, def.canon = the
-- matching canonical strings. A malformed override entry is skipped with
-- a log line (the store is machine-local data, never fatal).
local function apply_binds(def)
  local src = M._overrides[def.name] or def.defaults
  def.binds, def.canon = {}, {}
  for _, c in ipairs(src) do
    local ok, b = pcall(parse_bind, c)
    if ok then
      def.binds[#def.binds + 1] = b
      def.canon[#def.canon + 1] = canon_bind(b)
    else
      pal.log(("[input] dropping bad binding %q on %s")
              :format(tostring(c), def.name))
    end
  end
end

-- define("jump", {44, 82, "pad:south"}): appends an action (bit = order of
-- first definition); redefining an existing name just rebinds it. The list
-- is the action's DEFAULT bindings; a user override, when present, wins.
function M.define(name, binds)
  -- validate every binding BEFORE touching the map: a bad descriptor must
  -- not leave a half-defined action behind its error
  local defaults = {}
  for _, b in ipairs(binds) do
    defaults[#defaults + 1] = canon_bind(parse_bind(b, 2))
  end
  if M.bit_of[name] == nil then
    if #M.defs >= 32 then error("action map full (32 actions max)", 2) end
    M.bit_of[name] = #M.defs
    M.defs[#M.defs + 1] = { name = name }
  end
  local def = M.defs[M.bit_of[name] + 1]
  def.defaults = defaults
  apply_binds(def)
end

-- map{ {"jump", 44}, {"left", 80, 4, "pad:dpleft"}, ... } — array form so
-- action order (and therefore record bit layout) is deterministic
function M.map(list)
  for _, row in ipairs(list) do
    local binds = table.move(row, 2, #row, 1, {})
    M.define(row[1], binds)
  end
end

local function def_of(name, lvl)
  local i = M.bit_of[name]
  if i == nil then error("unknown action: " .. tostring(name), (lvl or 2) + 1) end
  return M.defs[i + 1]
end

-- the action's active bindings as canonical strings (a copy)
function M.bindings(name)
  local c = def_of(name).canon
  return table.move(c, 1, #c, 1, {})
end

-- the action's code-declared defaults as canonical strings (a copy)
function M.default_bindings(name)
  local def = def_of(name)
  return table.move(def.defaults, 1, #def.defaults, 1, {})
end

function M.overridden(name)
  return M._overrides[def_of(name).name] ~= nil
end

-- rebind(name, {binds}) replaces the action's bindings as a user override;
-- rebind(name, nil) drops the override and returns to the defaults. Call
-- save_binds() to persist. Duplicate bindings within the list collapse.
function M.rebind(name, binds)
  local def = def_of(name)
  if binds == nil then
    M._overrides[name] = nil
  else
    local o, seen = {}, {}
    for _, b in ipairs(binds) do
      local c = canon_bind(parse_bind(b, 2))
      if not seen[c] then
        seen[c] = true
        o[#o + 1] = c
      end
    end
    M._overrides[name] = o
  end
  apply_binds(def)
end

-- bindings claimed by two or more actions, for the rebind UI's conflict
-- marks: a sorted array of { bind = canon, actions = {name, ...} } (the
-- actions in bit order). The API deliberately ALLOWS overloads — context-
-- dependent actions sharing a key is a real pattern — so conflict handling
-- is surfacing, not refusal.
function M.conflicts()
  local users = {}
  for _, def in ipairs(M.defs) do
    local seen = {}
    for _, c in ipairs(def.canon or {}) do
      if not seen[c] then
        seen[c] = true
        users[c] = users[c] or {}
        users[c][#users[c] + 1] = def.name
      end
    end
  end
  local out = {}
  for c, actions in pairs(users) do
    if #actions >= 2 then out[#out + 1] = { bind = c, actions = actions } end
  end
  table.sort(out, function(a, b) return a.bind < b.bind end)
  return out
end

-- ---- binding stores (A4/D084) ----
-- Project code declares the defaults (input.map above); the player's
-- overrides persist in <project>/input.dat — machine-local video.dat-class
-- state: adopted only by interactive windowed sessions, atomic replacement,
-- never part of exports/duplicates/archives, and never a sim input (the
-- recorded action bits are). Store shape (cm.state canon):
--   { schema = 1, actions = { [name] = { "key:44", "pad:south", ... } } }
-- Overrides for actions the project no longer defines stay in the store
-- inert (a hot reload or version skew must not eat a player's bindings).

local function state_mod()
  return cm and cm.require and cm.require("cm.state")
end

-- adopt the store for this session (project boot). Missing file = defaults;
-- a malformed file or entry is logged and ignored, never fatal, and stays
-- on disk untouched until the next explicit save.
function M.load_binds(project_root)
  M._binds_path = project_root and (project_root .. "/input.dat") or nil
  M._overrides = {}
  -- the knobs reset to code defaults first: switching projects must never
  -- leak the previous store's tuning
  M.deadzone, M.axis_threshold = M.DEF_DEADZONE, M.DEF_AXIS_THRESHOLD
  local bytes = M._binds_path and pal.read_file(M._binds_path)
  if bytes then
    local ok, t = pcall(state_mod().parse, bytes)
    if ok and type(t) == "table" and t.schema == 1
       and type(t.actions) == "table" then
      -- the tuning knobs (A4/D085) ride the same schema additively: absent
      -- in old stores (defaults), non-numbers ignored, values clamped
      if type(t.deadzone) == "number" then M.set_deadzone(t.deadzone) end
      if type(t.axis_threshold) == "number" then
        M.set_axis_threshold(t.axis_threshold)
      end
      for name, list in pairs(t.actions) do
        if type(name) == "string" and type(list) == "table" then
          local o = {}
          for _, c in ipairs(list) do
            if type(c) == "string" and pcall(parse_bind, c) then
              o[#o + 1] = canon_bind(parse_bind(c))
            else
              pal.log(("[input] %s: dropping bad binding %q on %s")
                      :format(M._binds_path, tostring(c), name))
            end
          end
          M._overrides[name] = o
        end
      end
    else
      pal.log("[input] " .. M._binds_path .. " unreadable; using default bindings")
    end
  end
  for _, def in ipairs(M.defs) do apply_binds(def) end
end

-- persist the overrides (atomic). `fail` is the injectable test seam of
-- pal.write_file_atomic. Returns true or nil, error (already logged).
function M.save_binds(fail)
  if not M._binds_path then return nil, "no binding store this session" end
  local actions = {}
  for name, list in pairs(M._overrides) do
    actions[name] = table.move(list, 1, #list, 1, {})
  end
  -- knobs persist only when off their defaults: an untouched player never
  -- freezes today's defaults against a future engine retune
  local bytes = state_mod().canon({
    schema = 1, actions = actions,
    deadzone = M.deadzone ~= M.DEF_DEADZONE and M.deadzone or nil,
    axis_threshold = M.axis_threshold ~= M.DEF_AXIS_THRESHOLD
                     and M.axis_threshold or nil,
  })
  local ok, err = pal.write_file_atomic(M._binds_path, bytes, fail)
  if not ok then
    pal.log(("[input] save FAILED %s: %s"):format(M._binds_path, tostring(err)))
  end
  return ok, err
end

-- normalize one raw pad event (slot or device shape, from cm.ui's raw pad
-- stream) into a capturable binding for the rebind UI. Buttons on ANY pad
-- capture as pad-1 bindings — the store is player-one policy; pinning
-- pads 2..4 stays an API affair. An axis captures once its quantized
-- deflection reaches 64 (well past axis_threshold, so stick noise and
-- resting drift cannot bind). Returns the canonical string or nil.
function M.bind_of_pad_event(e)
  if (e.type == "padbtn" or e.type == "gpadbtn") and e.down
     and type(e.button) == "number" and e.button >= 0 and e.button <= 31 then
    return canon_bind({ k = "btn", pad = 1, btn = e.button })
  end
  if (e.type == "padaxis" or e.type == "gpadaxis")
     and type(e.axis) == "number" and e.axis >= 0 and e.axis <= 5 then
    local q = M.quantize_axis(e.value)
    if q >= 64 or q <= -64 then
      return canon_bind({ k = "ax", pad = 1, ax = e.axis,
                          dir = q > 0 and 1 or -1 })
    end
  end
  return nil
end

-- ---- binding display strings (honest HUD/UI names) ----

local AXIS_LABEL = {
  lx = { "stick left", "stick right" }, ly = { "stick up", "stick down" },
  rx = { "rstick left", "rstick right" }, ry = { "rstick up", "rstick down" },
  lt = { "ltrigger", "ltrigger" }, rt = { "rtrigger", "rtrigger" },
}
local BTN_LABEL = {
  dpup = "dpad up", dpdown = "dpad down",
  dpleft = "dpad left", dpright = "dpad right",
}

-- one binding -> a short player-facing name: keys through the real
-- scancode name ("Space", "Left"; "key N" where the host can't say), pads
-- through the positional SDL vocabulary ("south", "dpad left",
-- "stick left"; pads 2..4 prefix their number, "p2 south").
function M.bind_label(bind)
  local b = type(bind) == "table" and bind or parse_bind(bind, 2)
  if b.k == "key" then
    local n = pal.scancode_name and pal.scancode_name(b.sc)
    if n and n ~= "" then return n end
    return "key " .. b.sc
  end
  local s
  if b.k == "ax" then
    s = AXIS_LABEL[ax_name[b.ax]][b.dir > 0 and 2 or 1]
  else
    local name = btn_name[b.btn]
    s = name and (BTN_LABEL[name] or name) or ("pad #" .. b.btn)
  end
  if b.pad ~= 1 then s = "p" .. b.pad .. " " .. s end
  return s
end

-- label(name) -> every active binding joined with "/"; label(name, "key")
-- or label(name, "pad") -> the first binding of that kind (falling back to
-- the first of any kind), for compact HUD lines that follow the device the
-- player is holding. "unbound" when the action has no bindings.
function M.label(name, kind)
  local def = def_of(name)
  if #def.binds == 0 then return "unbound" end
  if kind then
    local want_key = kind == "key"
    for _, b in ipairs(def.binds) do
      if (b.k == "key") == want_key then return M.bind_label(b) end
    end
    return M.bind_label(def.binds[1])
  end
  local parts = {}
  for i, b in ipairs(def.binds) do parts[i] = M.bind_label(b) end
  return table.concat(parts, "/")
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
-- slot-level pad primitives shared by the slot shapes (pad/padbtn/padaxis)
-- and the device shapes (gpad/gpadbtn/gpadaxis) after id->slot translation
local function pad_connect(slot)
  live_pads[slot] = { held = 0, tap = 0, ax = { 0, 0, 0, 0, 0, 0 } }
  M._pad_live = true
end

local function pad_button(slot, button, down)
  -- events for unregistered slots are dropped (a disconnect raced them)
  local p = live_pads[slot]
  if p and button >= 0 and button <= 31 then
    local bit = 1 << button
    if down then
      p.held = p.held | bit
      p.tap = p.tap | bit -- sticky tap, same contract as keys
    else
      p.held = p.held & ~bit
    end
  end
end

local function pad_axis(slot, axis, value)
  local p = live_pads[slot]
  if p and axis >= 0 and axis <= 5 then
    p.ax[axis + 1] = value
  end
end

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
      rel_carry_x = rel_carry_x + (e.rx or 0)
      rel_carry_y = rel_carry_y + (e.ry or 0)
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
          pad_connect(e.pad)
        else
          live_pads[e.pad] = nil
        end
      end
    elseif e.type == "padbtn" then
      -- {type="padbtn", pad=1..4, button=SDL number 0..31, down=bool}
      pad_button(e.pad, e.button, e.down)
    elseif e.type == "padaxis" then
      -- {type="padaxis", pad=1..4, axis=SDL number 0..5, value=raw i16}
      pad_axis(e.pad, e.axis, e.value)
    elseif e.type == "gpad" then
      -- {type="gpad", id=SDL instance id, connected=bool}: PAL hot-plug.
      -- Assignment policy in the registry comment above; a reconnect of a
      -- still-registered id resets its slot in place.
      if e.connected then
        local slot = live_dev[e.id]
        for s = 1, PAD_SLOTS do
          if not slot and not live_pads[s] then slot = s end
        end
        if slot then
          live_dev[e.id] = slot
          pad_connect(slot)
        else
          pal.log(("[input] gamepad %d ignored: all %d pad slots taken")
                  :format(e.id, PAD_SLOTS))
        end
      else
        local slot = live_dev[e.id]
        live_dev[e.id] = nil
        if slot then live_pads[slot] = nil end
      end
    elseif e.type == "gpadbtn" then
      -- {type="gpadbtn", id=, button=SDL number, down=bool}; events for
      -- unassigned devices are dropped (all slots were taken, or a
      -- disconnect raced them)
      local slot = live_dev[e.id]
      if slot then pad_button(slot, e.button, e.down) end
    elseif e.type == "gpadaxis" then
      -- {type="gpadaxis", id=, axis=SDL number 0..5, value=raw i16}
      local slot = live_dev[e.id]
      if slot then pad_axis(slot, e.axis, e.value) end
    end
  end
end

-- Deadzone, live-side policy (a player knob since A4/D085, set_deadzone
-- above) — NEVER part of the record or the sim: records store post-deadzone
-- quantized values, so retuning it can't invalidate a trace. Default tracks
-- XInput's stick deadzone recommendation.
M.DEF_DEADZONE = 8000
M.deadzone = M.deadzone or M.DEF_DEADZONE

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
    for _, b in ipairs(def.binds or {}) do
      local on
      if b.k == "key" then
        on = live_keys[b.sc] or live_tap[b.sc]
      elseif b.k == "btn" then
        local p = live_pads[b.pad]
        -- taps included here, cleared below by the PAD encode (any live
        -- pad implies the latched domain), so the bit and the recorded
        -- pad entry always agree within one record
        on = p and (p.held | p.tap) & (1 << b.btn) ~= 0
      else -- axis direction past the threshold, on the quantized value
        local p = live_pads[b.pad]
        if p then
          local q = M.quantize_axis(p.ax[b.ax + 1])
          on = b.dir > 0 and q >= M.axis_threshold
               or b.dir < 0 and q <= -M.axis_threshold
        end
      end
      if on then
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

  -- the MREL extension (v21): whole game-px relative motion, remainder
  -- carried. Drained even while the domain is dormant so a later capture
  -- never inherits stale motion.
  local rdx = rel_carry_x >= 0 and math.floor(rel_carry_x)
              or -math.floor(-rel_carry_x)
  local rdy = rel_carry_y >= 0 and math.floor(rel_carry_y)
              or -math.floor(-rel_carry_y)
  rel_carry_x = rel_carry_x - rdx
  rel_carry_y = rel_carry_y - rdy
  if M._mrel_live then
    rec = rec .. pack("<I1I1i2i2", 2, 4, iclamp(rdx, -32768, 32767),
                      iclamp(rdy, -32768, 32767))
  end

  -- the FSIZ extension (D123): the frame's live target size, once the
  -- size domain latched. The recorded value is the authority — replay
  -- never re-reads the live target.
  if M._fsiz_live then
    local fw, fh = pal.gfx_size()
    rec = rec .. pack("<I1I1i2i2", 3, 4, iclamp(fw, 0, 32767),
                      iclamp(fh, 0, 32767))
  end
  return rec
end

-- Live-side reset for the pad domain: forget connected pads, drop every
-- device->slot assignment, and stop emitting the PAD extension. Never
-- touches applied state.
function M.pad_reset()
  live_pads = {}
  live_dev = {}
  M._pad_live = nil
end

-- Project boot (and tests): reset, then adopt the PAL's CURRENT physical
-- reality from pal.pad_list(). SDL announced those controllers' hot-plug
-- long ago and will not re-fire it for a fresh VM, so a still-connected
-- controller claims its slot before frame one — while a session with
-- nothing connected never inherits the previous project's latch and stays
-- byte-identical to v1. Ascending instance id = original connect order.
function M.pad_sync()
  M.pad_reset()
  if not pal.pad_list then return end -- host-loaded/fake pal (tests)
  local list = pal.pad_list()
  table.sort(list, function(a, b) return a.id < b.id end)
  local evs = {}
  for _, p in ipairs(list) do
    evs[#evs + 1] = { type = "gpad", id = p.id, connected = true }
  end
  M.feed(evs)
end

-- Return every live axis to neutral (buttons/connectivity untouched). The
-- editor calls this when game-input focus leaves: a stick held across the
-- focus change must not keep driving the sim, while held buttons follow
-- the key rule (their release event always passes). Live-side only.
function M.pad_neutralize()
  for _, p in pairs(live_pads) do
    for a = 1, 6 do p.ax[a] = 0 end
  end
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
  -- relative motion is a per-frame DELTA: every record resets it, an MREL
  -- extension below then overwrites — so a v1 replay always reads (0,0)
  b:i16(16, 0)
  b:i16(18, 0)
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
    elseif tag == 2 then
      if len ~= 4 then error("bad MREL extension in input record", 2) end
      local rdx, rdy = string.unpack("<i2i2", record, pos + 2)
      b:i16(16, rdx)
      b:i16(18, rdy)
    elseif tag == 3 then
      if len ~= 4 then error("bad FSIZ extension in input record", 2) end
      local fw, fh = string.unpack("<i2i2", record, pos + 2)
      b:i16(20, fw)
      b:i16(22, fh)
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

-- record-backed relative mouse motion this frame (whole internal px; the
-- captured-cursor look's input). (0,0) unless an MREL-carrying record
-- applied — so v1 traces and capture-free sessions read no motion.
function M.mouse_rel()
  local b = buf()
  return b:i16(16), b:i16(18)
end

-- Live-side capture door (chrome policy, the device-identity model):
-- flips the OS relative-mouse mode via pal.x_mouse_capture (a headless
-- run stays uncaptured — deltas simply never arrive) and latches the
-- MREL domain so every later record carries the extension. Sim code
-- reads mouse_rel(), never the capture state.
function M.capture_mouse(on)
  M._mrel_live = true
  if pal.x_mouse_capture then pal.x_mouse_capture(on and true or false) end
end

-- Boot-path reset beside pad_sync (cm.main): fresh project, fresh domain.
function M.mrel_reset()
  rel_carry_x, rel_carry_y = 0.0, 0.0
  M._mrel_live = nil
  if pal.x_mouse_capture then pal.x_mouse_capture(false) end
end

-- Record-backed live game-target size (the FSIZ domain, D123): what sim
-- code reads for 3D aspect and screen->world unprojection — the editor's
-- game window resizes the FOV live, and this is the deterministic view of
-- it. First use latches the domain so every later record carries the
-- frame's target size; until a sized record applies (and in every
-- pre-FSIZ trace) it returns the project's design resolution — which IS
-- the boot target, so record and replay agree by construction. Sim code
-- reads this, never pal.gfx_size().
function M.game_size()
  M._fsiz_live = true
  local b = buf()
  local fw, fh = b:i16(20), b:i16(22)
  if fw > 0 and fh > 0 then return fw, fh end
  local cfg = cm.require("cm.view").cfg
  return cfg.ref_w, cfg.ref_h
end

-- Boot-path reset beside mrel_reset (cm.main): fresh project, fresh
-- domain, applied size forgotten.
function M.fsiz_reset()
  M._fsiz_live = nil
  local b = buf()
  b:i16(20, 0)
  b:i16(22, 0)
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

-- reverse lookups for canonical strings + labels (locals near the top)
for name, n in pairs(M.pad_btn) do btn_name[n] = name end
for name, n in pairs(M.pad_ax) do ax_name[n] = name end

return M
