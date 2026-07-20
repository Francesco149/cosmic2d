-- tools/trace/replay-driver.lua — the golden re-cut vehicle (D093/D094).
--
-- Replays an existing .ctrace's input records through a REAL virtual SDL
-- pad against a fresh boot of the (usually just-changed) project, while
-- --record cuts the new golden. Every re-cut so far was pad-driven; a
-- trace with keyboard/mouse records needs this extended through
-- cm.input.feed (see projects/inputproof for that idiom).
--
-- Usage (from the repo root; see docs/PROCESS.md):
--
--   bin/cosmic <proj> --headless --frames <N> --record /tmp/new.ctrace \
--     --eval 'local a=cm.require("cm.main").args if not a.verify then
--             _G.RECUT_SRC="tests/traces/old.ctrace"
--             dofile("tools/trace/replay-driver.lua") end'
--
-- (`_G.` matters: a bare assignment in a console eval lands in the repl's
-- sandbox env, invisible to the dofile'd chunk.)
--
--   nix develop -c lua tools/trace/dump.lua /tmp/new.ctrace   # sanity
--   nix develop -c lua tools/trace/strip-eval.lua /tmp/new.ctrace out.ctrace
--   bin/cosmic <proj> --verify out.ctrace
--
-- <N> = the old trace's frame count (tools/trace/dump.lua prints it).
-- The arm eval is guarded (inert under verify) and stripped afterwards so
-- the committed trace is input-only. Honesty checks the session must do:
-- the new trace's record stream is byte-identical to the old one
-- (tools/trace/dump.lua on both), and the replayed outcome matches the
-- old fight (instrument here or compare final doc state).
--
-- Render-side module-local dev state only — never sim state; patching the
-- in-memory game.draw does not touch the recorded source bundle.
local chunk = cm.require("cm.chunk")
local state = cm.require("cm.state")
local main = cm.require("cm.main")

local SRC = RECUT_SRC or error("set RECUT_SRC before dofile")
local blob = assert(pal.read_file(SRC), "old trace unreadable: " .. SRC)
local recs = {}
for _, c in ipairs(chunk.read(blob, "CTRC")) do
  if c.tag == "FRAM" then
    recs[#recs + 1] = string.unpack("<s4", c.payload)
  end
end
pal.log(("[recut] %d input records loaded from %s"):format(#recs, SRC))
pal.log(("[recut] fresh boot doc canon: %d bytes"):format(
  #state.canon(state.doc)))

-- the PAD extension of one record -> {btn, ax[6]} | {none=true} | nil.
-- Only single-pad traces are handled; extend for pinned pads 2..4.
local function pad_of(rec)
  local p = 11
  while p <= #rec do
    local tag, len = string.unpack("BB", rec, p)
    if tag == 1 then
      local pay = rec:sub(p + 2, p + 1 + len)
      local n, q = string.unpack("B", pay)
      if n == 0 then return { none = true } end
      assert(n == 1, "multi-pad trace: extend the driver")
      local _, btn = string.unpack("<BI4", pay, q)
      q = q + 5
      local ax = {}
      for a = 1, 6 do ax[a], q = string.unpack("b", pay, q) end
      return { btn = btn, ax = ax }
    end
    p = p + 2 + len
  end
  return nil
end

-- preimage of cm.input.quantize_axis at the DEFAULT 8000 deadzone (the
-- driver assumes no input.dat overrides it): the smallest-magnitude raw
-- SDL value that quantizes back to exactly q
local function raw_of(q)
  if q == 0 then return 0 end
  local a = q < 0 and -q or q
  local raw = 8000 + (a * 24767 + 126) // 127
  if raw > 32767 then raw = 32767 end
  return q < 0 and -raw or raw
end

local vid                       -- attached at the first PAD-carrying record
local cur_btn = 0
local cur_ax = { 0, 0, 0, 0, 0, 0 }
local done = false

-- at draw of frame f, stage the live pad so frame f+1's sample reproduces
-- record f+1 exactly (events reach cm.input at the pump below)
local function drive()
  local f = state.frame()
  local want = recs[f + 1]
  if want == nil then
    if not done then
      done = true
      pal.log(("[recut] end of records at frame %d"):format(f))
    end
    return
  end
  local pe = pad_of(want)
  if pe == nil then return end  -- pre-attach frames keep the pad away
  if vid == nil then
    vid = assert(pal.x_pad_virtual(), "virtual pad refused")
    -- SDL exposes the attached joystick to SetJoystickVirtual* only after its
    -- hot-plug event is pumped and the PAL opens it. Some traces carry a
    -- non-neutral axis in their very first PAD record, so waiting for the
    -- ordinary end-of-drive pump makes that first poke fail instead of merely
    -- delaying it. Pump once to open, then stage the wanted state below; the
    -- final pump emits those button/axis events into the same polled frame.
    pal.x_events_pump()
    pal.log("[recut] virtual pad attached before frame " .. (f + 1))
  end
  if not pe.none then
    if pe.btn ~= cur_btn then
      for b = 0, 31 do
        local mask = 1 << b
        if (pe.btn & mask) ~= (cur_btn & mask) then
          pal.x_pad_virtual_button(vid, b, (pe.btn & mask) ~= 0)
        end
      end
      cur_btn = pe.btn
    end
    for a = 1, 6 do
      if pe.ax[a] ~= cur_ax[a] then
        pal.x_pad_virtual_axis(vid, a - 1, raw_of(pe.ax[a]))
        cur_ax[a] = pe.ax[a]
      end
    end
  end
  pal.x_events_pump()
end

local game = main.game
local orig_draw = game.draw
game.draw = function(...)
  drive()
  return orig_draw(...)
end
pal.log("[recut] armed: replaying " .. #recs .. " records")
