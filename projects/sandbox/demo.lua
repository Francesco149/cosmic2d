-- demo — the attract-mode input scripts: action "key states" as a pure
-- function of the frame relative to demo start (doc.demo_t0). Pure data +
-- arithmetic means a demo is deterministic by construction, so it doubles
-- as the input source for recorded goldens and montages (enable with
-- `game.demo(1)` in the console, or --eval "game.demo(1)" when recording).
-- Any real move/jump/grab press hands control back to the player.
--
-- Two timelines: 1 = the attract TOUR (the showcase), 2 = the KIT CHECK
-- (game.demo(2)) — a short scripted exercise of the air-move rules from
-- the spawn area, for goldens that pin rule changes with real
-- choreographed input rather than demo_t0 offset tricks.

local M = {}

-- timeline: each row is { duration_frames, "action", "action", ... };
-- rows run back to back. After the last row the demo just idles.
-- Choreography against the LOCKED stock knobs (2026-06-11 dial-in).
-- World refs: run 1.27 px/f; a full hop (hold ~26f, no cut) rises
-- ~36 px with the apex hang — a 2-row ledge with the 4px mantle; a
-- jump+dj stack rises ~63 px (3 rows); the dive is a GLIDE: 270 px/s
-- forward at a ~40 px/s² sink — the fast-travel move. Tour story:
-- up the plank tower, double-jump to the balcony, glide the lowlands
-- to the plateau, glide clean over the pillar into the crate pit,
-- carry a crate out and up a stair plank, throw it back, drop
-- through, glide home, then the air-kit finale.
local TIMELINE = {
  -- phase A: up the left plank tower to the balcony
  { 20 }, -- settle
  { 40, "right" }, -- line up under plank 1
  { 26, "right", "jump" }, { 26, "right" }, { 8 }, -- onto plank 1
  { 14, "right" }, -- to its right edge
  { 26, "right", "jump" }, { 26, "right" }, { 8 }, -- onto plank 2
  { 16, "left" }, -- turn around
  { 26, "left", "jump" }, { 26, "left" }, { 8 }, -- onto plank 3
  { 30, "left" },
  { 26, "left", "jump" }, { 26, "left" }, { 8 }, -- onto plank 4
  { 6, "left" }, -- stop just RIGHT of the balcony slab (don't get under it)
  { 30, "jump" }, -- full jump up its face, held past the apex (no cut)...
  { 2, "left" },
  { 24, "left", "jump" }, -- ...DOUBLE JUMP at the top, steering in over it
  { 22, "left" }, -- land on the balcony
  { 30 }, -- admire the view
  -- phase B: glide off the balcony, clear across to the plateau
  { 24, "right" }, -- walk off the balcony edge
  { 16, "right" }, -- fall, drift right
  { 6, "dive" }, -- GLIDE from balcony height: 270 px/s over the lowlands
  { 56 }, -- sail toward the plateau
  { 6, "up" }, -- flip out of the glide
  { 40 }, -- drop onto the plateau top (or its doorstep)
  { 24 }, -- land, settle
  { 30, "right" }, -- approach (self-healing: run-up if we landed short)
  { 26, "right", "jump" }, { 24, "right" }, { 8 }, -- hop: a skip on top, or
  -- the mount over the lip if the glide came up short of the plateau
  { 120, "right" }, -- across the plateau to its edge
  -- phase C: into the gap, perch the pillar, glide into the pit
  { 26, "right" }, -- off the edge, drop into the gap
  { 26 }, -- land between the walls
  { 8, "right" }, -- line up on the pillar
  { 26, "right", "jump" }, { 20, "right" }, { 8 }, -- hop up: the PERCH
  { 16 }, -- hold the pose
  { 16, "right", "jump" }, { 4, "right" }, -- hop off the perch...
  { 6, "dive" }, -- ...glide over the pit lip...
  { 50 }, -- ...crash the crate pile, slide out
  { 30 }, -- dust settles
  -- phase D: crate out of the pit, crate back in
  { 6, "left" }, -- cancel the slide: flip up at the right wall
  { 24 }, -- land
  { 18, "left" }, -- walk back into the strewn pile
  { 5, "grab" }, -- pick one up
  { 18 },
  { 56, "right" }, -- carry to the right wall (over the crates)
  { 26, "right", "jump" }, { 24, "right" }, { 12 }, -- hop out of the pit
  { 14, "right" }, -- under the stair plank
  { 26, "right", "jump" }, { 22, "right" }, { 8 }, -- up onto the stair
  { 6, "left" }, -- face the pit
  { 5, "grab" }, -- THROW it back in
  { 45 }, -- watch it land
  -- phase E: drop through, hop the skyline home, glide the last stretch
  { 8, "down", "jump" }, -- drop through the plank
  { 26 },
  { 24, "left" }, -- toward the pit
  { 180, "left" }, -- across the whole pit floor — crate-hopping is slow;
  -- overrun just presses the left wall (the sync point)
  { 12 }, -- settle grounded at the left wall (no airborne jump press)
  { 26, "left", "jump" }, { 22, "left" }, { 8 }, -- hop out the left side
  { 8 }, -- square up at the pillar's right face
  { 30, "left", "jump" }, -- jump hugging the face (blocked, then over)...
  { 2, "left" },
  { 24, "left", "jump" }, -- ...DOUBLE JUMP, steering in over the top
  { 26, "left" }, -- cross it, drop into the gap beyond
  { 40 }, -- land at the plateau wall, settle DEAD (re-sync any drift)
  { 30, "left", "jump" }, -- jump hugging the wall face...
  { 2, "left" },
  { 24, "left", "jump" }, -- ...DOUBLE JUMP, steering in over the lip
  { 24, "left" }, -- land on top
  { 36 }, -- settle dead again
  { 30, "left", "jump" }, -- stack flourish on top — or the RETRY, if
  { 2, "left" }, -- drift ate the first one at the wall
  { 24, "left", "jump" },
  { 24, "left" },
  { 12 },
  { 120, "left" }, -- across the plateau
  { 30, "left" }, -- off its left wall, drop to the lowlands
  { 16, "left", "jump" }, { 4, "left" }, -- hop...
  { 6, "dive" }, -- ...glide home
  { 40 }, -- sail, flop, slide
  { 6, "up" }, -- flip up
  { 24 }, -- land near the spawn
  { 20 }, -- settle
  -- finale: the air kit at the locked feel
  { 14, "right" }, -- turn around
  { 16, "right", "jump" }, { 4, "right" }, -- hop...
  { 6, "dive" }, -- ...glide out
  { 30 }, -- let it sink toward the ground
  { 4, "right" }, -- late cancel holding the glide direction: BOOST
  { 24, "right" }, -- ride the burst to touchdown
  { 16 }, -- settle
  { 14, "left" }, -- turn around
  { 16, "left", "jump" }, { 4, "left" }, -- hop...
  { 6, "dive" }, -- ...glide...
  { 26 }, -- no cancel: belly-flop, slide
  { 20 }, -- lie there a beat
  { 6, "up" }, -- flip up (a cancel; no new dive till touchdown)
  { 26 }, -- land
  { 14, "right" }, -- runway for the closer
  { 26, "right", "jump" }, -- full jump, held through the apex...
  { 4, "right" },
  { 24, "right", "jump" }, -- ...DOUBLE JUMP from the top, held through...
  { 2, "right" },
  { 6, "dive" }, -- ...and glide out of the stack
  { 40 }, -- sail, flop
  { 6, "up" }, -- flip up
  { 26 }, -- land
  { 30 }, -- bow
}

-- timeline 2 — the kit check: hop-dive, cancel WITH JUMP, immediately
-- press jump again (must NOT double jump: dives spend the charge — the
-- attempt buffers a landing hop at most), land; hop-dive to a belly
-- flop, slide, flip out (the cancel_grav arc), land; hop back. The
-- run-up drifts into the left plank tower's airspace, so one-way
-- landings are part of the exercise; any arc lands somewhere — the
-- rules fire regardless of knob evals layered on top. Coda: hop-dive,
-- cancel holding the dive direction in the window (DIVE BOOST), press
-- dive mid-boost (must NOT start: dead until touchdown), ride it out.
-- Coda 2: hop-dive, cancel HIGH with a neutral press (never a boost),
-- press dive again (must NOT start: one dive per airtime), land; then
-- jump -> double jump (the dj.scale impulse riding the jump curve).
local KITCHECK = {
  { 20 }, -- settle
  { 18, "right" }, -- run-up
  { 12, "right", "jump" }, { 4, "right" }, -- hop...
  { 6, "dive" }, -- ...dive
  { 5 }, -- commit
  { 3, "jump" }, -- cancel with jump (the spent press: not a jump)
  { 4 }, -- beat
  { 4, "jump" }, -- dj attempt: the dive spent the charge -> no dj
  { 24 }, -- fall, land (buffered hop fires here if anywhere)
  { 16 }, -- settle
  { 12, "right", "jump" }, { 4, "right" }, -- hop...
  { 6, "dive" }, -- ...dive, no cancel
  { 26 }, -- belly flop, slide out
  { 5, "up" }, -- cancel from the slide: flip up
  { 26 }, -- land
  { 12, "left", "jump" }, { 18, "left" }, -- hop back toward home
  { 24 }, -- bow out
  -- the boost coda (timed for the LOCKED knobs: boost_win 3 + the slow
  -- glide sink means a mid-air cancel must come within ~4 px of the
  -- floor — instead let the glide FLOP and cancel in the fresh slide
  -- (slide_t <= boost_win also boosts). Drift tolerance: a hair early
  -- still boosts via the near-ground probe, a hair late via the slide)
  { 12, "left", "jump" }, { 4, "left" }, -- hop...
  { 6, "dive" }, -- ...dive left
  { 22 }, -- commit; the glide sinks to the floor and flops
  { 6, "left" }, -- cancel in the young slide, holding the dive
  -- direction: DIVE BOOST (ground-bounce burst)
  { 4, "dive" }, -- dive press mid-boost: dead button (locked till ground)
  { 26, "left" }, -- ride the boost to touchdown (it evaporates there)
  { 24 }, -- settle
  -- the cancel-lockout + scaled-dj coda
  { 16, "right" }, -- turn, run-up
  { 12, "right", "jump" }, { 4, "right" }, -- hop...
  { 6, "dive" }, -- ...dive right
  { 4 }, -- commit, still high
  { 4, "up" }, -- cancel high, neutral press (never a boost): plain flip
  { 4, "dive" }, -- dive press post-cancel: dead (one dive per airtime)
  { 46 }, -- the cancel_grav arc is long: ride it down, land
  { 14 }, -- settle grounded (the closer must be a deliberate press)
  { 12, "right", "jump" }, { 6, "right" }, -- full jump...
  { 10, "right", "jump" }, -- ...DOUBLE JUMP (dj.scale * the jump impulse)
  { 28, "right" }, -- ride to landing
  { 20 }, -- bow out
}

-- exported for choreography tooling (boundary dumps, montages); the
-- tables are data, not state — readers must not mutate them
M.TIMELINE = TIMELINE
M.KITCHECK = KITCHECK

-- is `action` held on relative frame `rel`? (pure; edges derive from
-- rel-1). variant 2 = the kit check; anything else = the tour.
function M.down(rel, action, variant)
  if rel < 0 then return false end
  local t = 0
  for _, row in ipairs(variant == 2 and KITCHECK or TIMELINE) do
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
