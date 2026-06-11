-- demo — the attract-mode input script: action "key states" as a pure
-- function of the frame relative to demo start (doc.demo_t0). Pure data +
-- arithmetic means the demo is deterministic by construction, so it doubles
-- as the input source for recorded goldens and montages (enable with
-- `game.demo(1)` in the console, or --eval "game.demo(1)" when recording).
-- Any real move/jump/grab press hands control back to the player.

local M = {}

-- timeline: each row is { duration_frames, "action", "action", ... };
-- rows run back to back. After the last row the demo just idles.
-- Choreography (world refs: run 2.17 px/f, full jump rises 56 px in 24 f):
-- up the left plank tower to the balcony, big drop, across the plateau,
-- long-jump the pillar, into the crate pit, grab one, carry it out and up
-- a stair plank, throw it back in, drop-through, and run home.
-- A cut hop (13f hold) rises ~47px and covers ~65px ground in ~30 frames;
-- a full hop (20f+ hold) rises 56px and covers ~104px. Run is 2.17 px/f
-- after a ~5f ramp. Hop rows are {13,dir,jump} {17,dir} {settle}.
local TIMELINE = {
  -- phase A: up the left plank tower to the balcony
  { 20 }, -- settle
  { 18, "right" }, -- line up under plank 1
  { 13, "right", "jump" }, { 17, "right" }, { 6 }, -- onto plank 1 (~199)
  { 17, "right" }, -- to its right edge
  { 13, "right", "jump" }, { 17, "right" }, { 6 }, -- onto plank 2 (~295)
  { 12, "left" }, -- turn around
  { 13, "left", "jump" }, { 17, "left" }, { 6 }, -- onto plank 3 (~207)
  { 21, "left" },
  { 13, "left", "jump" }, { 17, "left" }, { 6 }, -- onto plank 4 (~103)
  { 18, "jump" }, -- straight up past the balcony lip...
  { 20, "left" }, -- ...steer left at the apex, land on it
  { 30 }, -- admire the view
  -- phase B: big drop, across the plateau, long-jump the pillar, pit dive
  { 110, "right" }, -- off the balcony edge, big drop, run on
  { 55, "right" },
  { 20, "right" }, -- line up on the plateau wall
  { 13, "right", "jump" }, { 17, "right" }, { 4 }, -- mount the plateau
  { 66, "right" }, -- across it to the edge
  { 22, "right", "jump" }, -- full jump: clear the gap to the pillar
  { 26, "right" }, -- off the pillar
  { 30, "right" }, -- over the lip, into the pit
  { 35 }, -- dust settles
  -- phase C: crate out, crate back in
  { 16, "right" }, -- to the pile
  { 5, "grab" }, -- pick one up
  { 15 },
  { 52, "right" }, -- carry toward the right wall
  { 20, "right", "jump" }, { 20, "right" }, { 20 }, -- full jump out (32px wall)
  { 13, "right", "jump" }, { 17, "right" }, { 6 }, -- up the stair plank
  { 6, "left" }, -- face the pit
  { 5, "grab" }, -- THROW
  { 45 }, -- watch it land
  -- phase D: drop through, run home
  { 8, "down", "jump" }, -- drop through the plank
  { 20 },
  { 35, "left" }, { 100, "left" }, -- into the pit, across the floor
  { 20, "left", "jump" }, { 26, "left" }, -- full jump out the left side
  { 20, "left", "jump" }, { 28, "left" }, -- full jump: clear the pillar
  { 30, "left" },
  { 13, "left", "jump" }, { 17, "left" }, -- onto the plateau
  { 58, "left" }, -- across, stop near its left edge
  -- finale: the air kit
  { 12, "left", "jump" }, { 4, "left" }, -- hop off the edge...
  { 8, "jump" }, -- ...DIVE out over the lower ground
  { 18 }, -- committed drop
  { 8, "left" }, -- cancel in the window holding left: DIVE BOOST + flip
  { 30, "left" }, -- ride it out, land (the boost evaporates)
  { 16 }, -- settle
  { 14, "right" }, -- turn around
  { 12, "right", "jump" }, { 4, "right" }, -- hop...
  { 8, "jump" }, -- ...DIVE (jump pressed in mid-air)...
  { 20 }, -- no cancel: belly-flop, slide
  { 22 }, -- lie there a beat
  { 6, "left" }, -- any press cancels (opposite dir too): flip up
  { 24 }, -- land (facing unlocks on touchdown)
  { 14, "right" }, -- runway for the closer
  { 12, "right", "jump" }, { 5, "right" }, -- jump...
  { 12, "right", "up", "jump" }, -- ...DOUBLE JUMP (up held + new press)...
  { 6, "right" },
  { 8, "jump" }, -- ...and dive out of it
  { 22 }, -- belly-flop, short slide
  { 6, "up" }, -- flip up
  { 26 }, -- land
  { 30 }, -- bow
}

-- is `action` held on relative frame `rel`? (pure; edges derive from rel-1)
function M.down(rel, action)
  if rel < 0 then return false end
  local t = 0
  for _, row in ipairs(TIMELINE) do
    local t1 = t + row[1]
    if rel < t1 then
      for i = 2, #row do
        if row[i] == action then return true end
      end
      return false
    end
    t = t1
  end
  return false
end

function M.length()
  local t = 0
  for _, row in ipairs(TIMELINE) do t = t + row[1] end
  return t
end

return M
