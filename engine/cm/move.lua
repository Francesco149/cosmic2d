-- cm.move — the movement-input slice of A5 (D097). The stick+key merge
-- and 8-way vector dance every action game hand-rolls: swarm's
-- PAIN(move) marker was the vote, cellar carries the byte-identical
-- movement block, and the top-down starter hand-rolls the digital half
-- (ix/iy plus the diagonal factor). §2's "input plumbing" exit line.
--
-- Policy over recorded input state plus pure math — no module state, no
-- buffers, nothing touching doc. Every read goes through cm.input's
-- recorded keyboard bits and quantized pad axes, so sim code calling
-- these stays trivially deterministic: traces, rewind, and verify carry
-- the exact same answers by construction.
--
--   local move = cm.require("cm.move")
--   -- in step: one merged unit-scale vector, you supply the speed
--   local mx, my = move.dir(1)
--   d.x, d.y = d.x + mx * SPEED, d.y + my * SPEED
--   -- 8-way facing: aim stick wins, else the move direction, else keep
--   local rx, ry = move.stick(1, "r")
--   d.fx, d.fy = move.face8(rx, ry, move.face8(mx, my, d.fx, d.fy))
--   -- shots fly along the facing at full speed on diagonals too
--   local ux, uy = move.unit8(d.fx, d.fy)
--   spawn_shot(d, ux * BSPEED, uy * BSPEED)
--
-- Semantics, pinned by KATs:
--   * stick(pad, side) -> x, y in -1..1: the recorded quantized axes
--     divided by 127 (exact — the wire value is the authority; deadzone
--     already applied live-side, so 0 means "inside the deadzone").
--     side is "l" (default) or "r"; pad defaults to 1.
--   * keys(left, right, up, down) -> ix, iy in {-1, 0, 1} from four
--     action names (defaults "left"/"right"/"up"/"down"); opposite
--     directions held together cancel to 0.
--   * dir(pad) -> x, y: the merged movement vector at unit scale —
--     the left stick verbatim when deflected (raw analog: a full
--     diagonal deflection exceeds length 1, exactly like the demos),
--     else the digital keys with diagonals scaled by DIAG so 8-way
--     keyboard speed is even. Multiply by your speed.
--   * face8(x, y, fx, fy) -> per-axis signs of (x, y) when the vector
--     is nonzero (a zero component gives 0, cardinal facings exist),
--     else fx, fy passed through untouched — "keep the last facing".
--     Nest calls for a priority chain (aim stick, else move, else old).
--   * unit8(fx, fy) -> the 8-way unit vector: both components scale by
--     DIAG when both are set, cardinals pass through. Feed it signs
--     from face8.
--   * DIAG = 0.70710678 — the exact diagonal factor the demos agreed
--     on, exported so hand-rolled variants can share it.
--
-- Deliberately NOT here (absorb the demonstrated pain, no more):
-- acceleration/friction envelopes, stick response curves, radial
-- normalization/clamping, dashes, buffered jumps. Later slices earn
-- those from real demo pain.

local M = select(2, ...) or {}
local input = cm.require("cm.input")

-- the 8-way diagonal factor (the demos' shared literal)
M.DIAG = 0.70710678

local AXES = { l = { "lx", "ly" }, r = { "rx", "ry" } }

-- stick(pad, side) -> x, y in -1..1 (recorded quantized axes / 127)
function M.stick(pad, side)
  local a = AXES[side or "l"]
  if not a then
    error("move.stick: side must be 'l' or 'r'", 2)
  end
  pad = pad or 1
  return input.pad_axis(pad, a[1]) / 127, input.pad_axis(pad, a[2]) / 127
end

-- keys(left, right, up, down) -> ix, iy in {-1, 0, 1} from action names
function M.keys(left, right, up, down)
  local ix = (input.down(right or "right") and 1 or 0)
           - (input.down(left or "left") and 1 or 0)
  local iy = (input.down(down or "down") and 1 or 0)
           - (input.down(up or "up") and 1 or 0)
  return ix, iy
end

-- dir(pad) -> x, y: the merged unit-scale move vector — the left stick
-- verbatim when deflected, else digital keys with even 8-way speed
function M.dir(pad)
  local x, y = M.stick(pad, "l")
  if x ~= 0 or y ~= 0 then return x, y end
  local ix, iy = M.keys()
  if ix ~= 0 and iy ~= 0 then return ix * M.DIAG, iy * M.DIAG end
  return ix, iy
end

-- face8(x, y, fx, fy) -> per-axis signs of a nonzero (x, y), else the
-- previous facing fx, fy untouched
function M.face8(x, y, fx, fy)
  if x ~= 0 or y ~= 0 then
    return x ~= 0 and (x > 0 and 1 or -1) or 0,
           y ~= 0 and (y > 0 and 1 or -1) or 0
  end
  return fx, fy
end

-- unit8(fx, fy) -> the 8-way unit vector along a facing: diagonals
-- scale by DIAG, cardinals pass through
function M.unit8(fx, fy)
  if fx ~= 0 and fy ~= 0 then return fx * M.DIAG, fy * M.DIAG end
  return fx, fy
end

return M
