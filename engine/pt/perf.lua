-- pt.perf — F3-toggled performance overlay (M2): frame-time graph against
-- the 16.7 ms budget, sim/draw split, draw batch stats (pal.frame_stats),
-- buffer/texture/Lua-heap sizes. pt.main feeds note() every tick; history
-- stays warm while the panel is closed so opening it shows the recent past.
--
-- All dev-side (module state only). The numbers describe the WALL cost of
-- the last ticks — under vsync the tick bar sits at ~16.7 with the wait
-- included; what matters is the sim/draw split and the spikes.

local M = select(2, ...) or {}

local ui = pt.require("pt.ui")

local HIST = 180 -- ~3s at 60
local GRAPH_H = 30
local BUDGET_MS = 1000.0 / 60.0
local CLAMP_MS = 2 * BUDGET_MS -- graph top

M.open = M.open or false
M.t = M.t or {} -- tick wall ms ring
M.s = M.s or {} -- sim ms ring
M.d = M.d or {} -- draw ms ring
M.cur = M.cur or 0

function M.note(tick_ms, sim_ms, draw_ms)
  M.cur = M.cur % HIST + 1
  M.t[M.cur], M.s[M.cur], M.d[M.cur] = tick_ms, sim_ms, draw_ms
end

local function avg(ring, n)
  local sum, c = 0.0, 0
  for i = 0, n - 1 do
    local v = ring[(M.cur - i - 1) % HIST + 1]
    if v then
      sum = sum + v
      c = c + 1
    end
  end
  return c > 0 and sum / c or 0.0
end

function M.toggle(on)
  if on == nil then on = not M.open end
  M.open = on
end

function M.frame()
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep and k.scancode == 60 then M.toggle() end -- F3
  end
  if not M.open then return end

  local W = pal.gfx_size()
  local st = ui.style
  local pw = 132
  ui.begin_panel("perf", W - pw - 2, 2, pw, 116, { title = "perf  [f3]" })

  local tick = avg(M.t, 60)
  local fps = tick > 0 and 1000.0 / tick or 0.0
  ui.label(("%5.1f fps  %5.2f ms"):format(fps, tick))

  -- frame-time bars, newest right, budget line at 16.7
  local g = ui.canvas(GRAPH_H + 2)
  ui.rect(g.x, g.y, g.w, GRAPH_H + 2, st.track)
  local n = math.min(g.w - 2, HIST)
  for i = 0, n - 1 do
    local v = M.t[(M.cur - i - 1) % HIST + 1]
    if v then
      local h = math.floor(math.min(v, CLAMP_MS) / CLAMP_MS * GRAPH_H)
      if h < 1 then h = 1 end
      local c = v <= BUDGET_MS + 0.8 and { 0.35, 0.85, 0.45, 1.0 }
                or (v <= 1.25 * BUDGET_MS and st.accent or st.error)
      ui.rect(g.x + g.w - 2 - i, g.y + 1 + GRAPH_H - h, 1, h, c)
    end
  end
  local by = g.y + 1 + GRAPH_H - math.floor(BUDGET_MS / CLAMP_MS * GRAPH_H)
  ui.rect(g.x + 1, by, g.w - 2, 1, { 0.9, 0.9, 0.9, 0.35 })

  ui.label(("sim %5.2f  draw %5.2f"):format(avg(M.s, 60), avg(M.d, 60)),
           { color = st.text_dim })

  local fs = pal.frame_stats()
  ui.label(("quads %d  segs %d"):format(fs.quads, fs.segs),
           { color = st.text_dim })
  ui.label(("vbuf %dK  tex %d"):format(fs.vbytes // 1024, fs.textures),
           { color = st.text_dim })
  ui.label(("bufs %d (%dK)  lua %dK"):format(
    fs.bufs, fs.buf_bytes // 1024, collectgarbage("count") // 1),
    { color = st.text_dim })

  ui.end_panel()
end

return M
