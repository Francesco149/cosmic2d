-- W3 UI immediate-mode churn: 300 widgets/frame x 240 frames.
-- Per widget: id-path string build (push_id shape), per-id retained-state
-- lookup/create, hit-test math, 2 rect() C calls, a formatted value label.
-- Garbage-heavy on purpose: this is where GC pauses show.
local floor = math.floor
local NW, FRAMES = 300, 240

local state = {}   -- per-id retained state, keyed by id path string
local path = "root"

local function widget(label, i, f, mx, my)
  local id = path .. "/" .. label .. i
  local st = state[id]
  if not st then st = { scroll = 0, open = false, t = 0 } state[id] = st end
  local x = (i % 3) * 130 + 8
  local y = floor(i / 3) * 22 + 30 - st.scroll
  local w, h = 120, 18
  local hot = mx >= x and mx < x + w and my >= y and my < y + h
  if hot then st.t = st.t + 1 end
  rect(x, y, w, h, hot and 0x3a3a52 or 0x2a2a3a)
  rect(x + 2, y + 2, w - 4, h - 4, 0x1a1a24)
  local txt = label .. i .. ": " .. string.format("%.1f", st.t * 0.1)
  -- measure stand-in: iterate the label's chars (cm.text measures per glyph)
  local tw = 0
  for k = 1, #txt do tw = tw + ((txt:byte(k) < 128) and 6 or 8) end
  st.scroll = (st.scroll + (hot and 1 or 0)) % 40
  return tw
end

local times = {}
for f = 1, FRAMES do
  local t0 = now()
  local mx = (f * 3) % 400
  local my = (f * 2) % 300
  local acc = 0
  for i = 0, NW - 1 do
    -- panels re-scope the path every 50 widgets (push_id/pop_id shape)
    if i % 50 == 0 then path = "root/panel" .. floor(i / 50) end
    acc = acc + widget("w", i, f, mx, my)
  end
  path = "root"
  times[f] = now() - t0
  if f == 1 then times.acc = acc end
end

table.sort(times)
local sum = 0
for i = 1, FRAMES do sum = sum + times[i] end
emit(string.format("w_ui %d widgets: avg %.1f us  p50 %.1f  p99 %.1f  max %.1f",
  NW, sum / FRAMES / 1000, times[floor(FRAMES / 2)] / 1000,
  times[floor(FRAMES * 0.99)] / 1000, times[FRAMES] / 1000))
