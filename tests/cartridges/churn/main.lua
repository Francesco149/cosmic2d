-- churn — golden-trace fixture: deliberately exercises the trace format's
-- edges every few frames so the golden suite guards them forever:
-- mid-trace buffer create / free / resize (FRAM kinds 1 and 2), doc-tree
-- key add/remove, and steady PRNG consumption.

local rand = cm.require("cm.rand")
local state = cm.require("cm.state")

local game = {}
local sim

function game.init()
  sim = pal.buf("churn.sim", 32)
  state.doc.churn = state.doc.churn or { tick = 0 }
end

function game.step()
  local f = sim:u32(0) + 1
  sim:u32(0, f)

  local d = state.doc.churn
  d.tick = f
  d["k" .. (f % 7)] = rand.range(100)
  if f % 11 == 0 then d["k" .. ((f // 11) % 7)] = nil end

  -- a buffer that appears, lives, and dies — with a different size each
  -- generation so restore/verify also cover the resize path
  if f % 30 == 5 then
    local b = pal.buf("churn.tmp", 64 + ((f // 30) % 3) * 32)
    for i = 0, 15 do b:u8(i, rand.range(0, 255)) end
  elseif f % 30 == 20 then
    pal.buf_free("churn.tmp")
  end

  sim:i64(8, rand.u64())
  sim:f64(16, rand.float())
end

function game.draw()
  pal.begin_frame(0.1, 0, 0.1, 1)
end

return game
