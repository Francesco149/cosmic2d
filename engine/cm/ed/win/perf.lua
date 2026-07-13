-- cm.ed.win.perf — the F3 overlay re-hosted as a canvas window (the
-- EDITOR.md §8 leftover: the legacy ui-canvas panel renders UNDER the
-- opaque ig canvas in editor mode, i.e. invisibly). Pure dev view over
-- cm.perf's warm rings + pal.frame_stats — no working state, no
-- journal; spawn it from the rclick menu, close it fearlessly.

local M = select(2, ...) or {}

M.kind = "perf"
M.menu = "perf"
M.DEF_W, M.DEF_H = 240, 170

local COL = {
  dim = 0x8a84b0ff, text = 0xd8d2f2ff, hot = 0xE8E4FFff,
  track = 0x262238ff, ok = 0x59d973ff, warn = 0xffb46eff,
  bad = 0xf07a7aff, budget = 0xe8e4ff59,
}

local BUDGET_MS = 1000.0 / 60.0
local CLAMP_MS = 2 * BUDGET_MS

function M.defaults()
  return {}
end

function M.title(win)
  return "perf"
end

function M.draw(win, ctx)
  local perf = cm.require("cm.perf")
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local x0, y = ctx.cx + 4 * z, ctx.cy + 4 * z
  local HIST = 180

  local function avg(ring, n)
    local sum, c = 0.0, 0
    for i = 0, n - 1 do
      local v = ring[(perf.cur - i - 1) % HIST + 1]
      if v then
        sum = sum + v
        c = c + 1
      end
    end
    return c > 0 and sum / c or 0.0
  end

  local tick = avg(perf.t, 60)
  local fps = tick > 0 and 1000.0 / tick or 0.0
  pal.x_ig_text(x0, y, px, COL.hot,
                ("%5.1f fps  %5.2f ms"):format(fps, tick), 1)
  y = y + px * 1.5

  -- frame-time bars, newest right, the budget line at 16.7
  local gh = math.max(10, 30 * z)
  local gw = ctx.cw - 8 * z
  pal.x_ig_rect_fill(x0, y, gw, gh, COL.track, 2 * z)
  local n = math.min(math.floor(gw) - 2, HIST)
  local bw = math.max(1, z)
  for i = 0, n - 1 do
    local v = perf.t[(perf.cur - i - 1) % HIST + 1]
    if v then
      local h = math.max(1, math.floor(math.min(v, CLAMP_MS) / CLAMP_MS * gh))
      local c = v <= BUDGET_MS + 0.8 and COL.ok
                or (v <= 1.25 * BUDGET_MS and COL.warn or COL.bad)
      local bx = x0 + gw - 1 - (i + 1) * bw
      if bx < x0 then break end
      pal.x_ig_rect_fill(bx, y + gh - h, bw, h, c)
    end
  end
  local by = y + gh - BUDGET_MS / CLAMP_MS * gh
  pal.x_ig_rect_fill(x0 + 1, by, gw - 2, 1, COL.budget)
  y = y + gh + px * 0.5

  local function line(s)
    pal.x_ig_text(x0, y, px, COL.dim, s, 1)
    y = y + px * 1.4
  end
  line(("sim %5.2f  draw %5.2f"):format(avg(perf.s, 60), avg(perf.d, 60)))
  local fs = pal.frame_stats()
  line(("quads %d  segs %d"):format(fs.quads, fs.segs))
  line(("vbuf %dK  tex %d"):format(fs.vbytes // 1024, fs.textures))
  line(("bufs %d (%dK)  lua %dK"):format(
    fs.bufs, fs.buf_bytes // 1024, collectgarbage("count") // 1))
end

return M
