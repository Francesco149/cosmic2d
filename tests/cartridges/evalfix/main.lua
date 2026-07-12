-- evalfix — golden fixture for EVAL records (D022): game code submits
-- console commands at fixed frames; the live loop drains them at the start
-- of the NEXT sim frame and the recorder writes EVAL chunks; verify must
-- re-execute them at exactly that point or the byte-compare diverges —
-- which is precisely what this golden guards forever.
--
-- (Submitting from step is a test artifice standing in for a human typing
-- into the console mid-recording. On verify, these submits land in the
-- queue again but nothing drains it — execution comes from the EVAL
-- records; the queue is dev-side state and never compared.)

local rand = cm.require("cm.rand")
local state = cm.require("cm.state")
local repl = cm.require("cm.repl")

local game = {}
local sim

function game.init()
  sim = pal.buf("evalfix.sim", 32)
  state.doc.eval = state.doc.eval or { pokes = 0 }
end

function game.step()
  local f = sim:u32(0) + 1
  sim:u32(0, f)
  sim:u32(4, sim:u32(4) + rand.range(9)) -- steady PRNG consumption

  if f == 5 then
    -- doc poke through the env sugar + a buffer created by an eval
    repl.submit("doc.eval.pokes = doc.eval.pokes + 1")
    repl.submit("pal.buf('evalfix.poked', 16):u32(0, 0xbeef)")
  elseif f == 12 then
    -- an erroring command must replay identically (caught + logged), and
    -- commands after it still run
    repl.submit("error('deliberate')")
    repl.submit("doc.eval.t = cm.state.frame()")
  end
end

function game.draw()
  pal.begin_frame(0.08, 0.10, 0.08, 1)
end

return game
