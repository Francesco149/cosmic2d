-- tools/drive/drive.lua — the scripted UI tape driver (D127 proof tooling).
--
-- Drives the real editor UI in a HEADLESS CAPTURE session (--headless
-- --win WxH): wraps pal.poll_events so scheduled closures append synthetic
-- pal-shaped events to the real stream AND mirror them into the imgui io
-- via pal.x_ig_event (capture sessions have no platform backend feeding
-- it; windowed sessions no-op that door, so tapes are capture-only).
--
-- Usage — write a tape file and arm it with --eval:
--
--   local D = dofile("tools/drive/drive.lua")
--   local SC = D.SC
--   D.chord(8, SC.ctrl, SC.space)        -- the launcher
--   D.typetext(14, "main")
--   D.tap(18, SC.enter)
--   D.at(24, function()                  -- dynamic: schedule from live state
--     local r = D.win("text")            -- newest window of a kind, screen px
--     D.click(D.f + 2, r.cx + 30, r.cy + 30)
--   end)
--
--   bin/cosmic <proj> --edit --headless --win 1280x800 --frames 120 \
--     --eval "dofile('tools/drive/tape.lua')" --shot /tmp/proof.png
--
-- Frames are render frames counted from the wrapper's install (frame 1 =
-- the eval frame). A closure may return a list of events, schedule more
-- steps via D.at/D.click/... (D.f is the current frame), or just probe
-- and pal.log. See DECISIONS D127 for the walkthrough tapes this drove.
local D = rawget(_G, "__drive")
if D then return D end
D = { plan = {}, f = 0, log = {} }
rawset(_G, "__drive", D)

local real_poll = pal.poll_events
function pal.poll_events()
  local evs = real_poll()
  D.f = D.f + 1
  local fns = D.plan[D.f]
  if fns then
    for _, fn in ipairs(fns) do
      local ok, out = pcall(fn)
      if not ok then
        pal.log("[drive] step ERROR f" .. D.f .. ": " .. tostring(out))
      elseif type(out) == "table" then
        for _, e in ipairs(out) do
          evs[#evs + 1] = e
          pal.x_ig_event(e)
        end
      end
    end
  end
  return evs
end

function D.at(f, fn)
  local t = D.plan[f] or {}
  t[#t + 1] = fn
  D.plan[f] = t
end

-- event builders (window px == ui px == design px at chrome scale 1)
function D.mouse(x, y)
  return { type = "motion", x = x, y = y, ui_x = x, ui_y = y,
           wx = x, wy = y, rx = 0, ry = 0 }
end
function D.btn(x, y, down, b)
  return { type = "button", button = b or 1, down = down, x = x, y = y,
           ui_x = x, ui_y = y, wx = x, wy = y }
end
function D.keyev(sc, down)
  return { type = "key", scancode = sc, down = down, rep = false }
end
function D.textev(s) return { type = "text", text = s } end
function D.wheelev(dy) return { type = "wheel", dx = 0, dy = dy } end

-- composites (schedule over frames)
function D.click(f, x, y, b)
  D.at(f, function() return { D.mouse(x, y) } end)
  D.at(f + 1, function() return { D.btn(x, y, true, b) } end)
  D.at(f + 2, function() return { D.btn(x, y, false, b) } end)
end
function D.rclick(f, x, y) D.click(f, x, y, 3) end
function D.drag(f, x0, y0, x1, y1, steps, b)
  steps = steps or 4
  D.at(f, function() return { D.mouse(x0, y0) } end)
  D.at(f + 1, function() return { D.btn(x0, y0, true, b) } end)
  for s = 1, steps do
    local t = s / steps
    local x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
    D.at(f + 1 + s, function() return { D.mouse(x, y) } end)
  end
  D.at(f + 2 + steps, function() return { D.btn(x1, y1, false, b) } end)
end
function D.tap(f, sc)
  D.at(f, function() return { D.keyev(sc, true) } end)
  D.at(f + 1, function() return { D.keyev(sc, false) } end)
end
function D.chord(f, mod_sc, sc) -- e.g. ctrl+s: D.chord(f, 224, 22)
  D.at(f, function() return { D.keyev(mod_sc, true) } end)
  D.at(f + 1, function() return { D.keyev(sc, true) } end)
  D.at(f + 2, function() return { D.keyev(sc, false) } end)
  D.at(f + 3, function() return { D.keyev(mod_sc, false) } end)
end
function D.typetext(f, s)
  D.at(f, function() return { D.textev(s) } end)
end
-- hold a key from frame f for n frames (game input)
function D.hold(f, sc, n)
  D.at(f, function() return { D.keyev(sc, true) } end)
  D.at(f + n, function() return { D.keyev(sc, false) } end)
end

-- editor helpers: newest window of a kind → screen-space rects
function D.win(kind)
  local doc = cm.ed.doc
  local cam = cm.require("cm.ed.cam")
  local best
  for _, w in ipairs(doc.wins) do
    if w.kind == kind then best = w end
  end
  if not best then return nil end
  local sx, sy = cam.w2s(doc.cam, best.x, best.y)
  local z = cam.screen_zoom(doc.cam)
  return { win = best, x = sx, y = sy, w = best.w * z, h = best.h * z,
           z = z, cx = sx + 4 * z, cy = sy + 24 * z,
           cw = (best.w - 8) * z, ch = (best.h - 24 - 4) * z }
end

-- scancodes
D.SC = { enter = 40, esc = 41, backspace = 42, tab = 43, space = 44,
         ctrl = 224, shift = 225, alt = 226, left = 80, right = 79,
         up = 82, down = 81, home = 74, END = 77, pgup = 75, pgdn = 78,
         f4 = 61, del = 76, a = 4, c = 6, d = 7, e = 8, f = 9, g = 10,
         m = 16, p = 19, r = 21, s = 22, v = 25, w = 26, x = 27, y = 28,
         z = 29, slash = 56, dot = 55 }

return D
