-- demo — the KITCHECK input script: action "key states" as a pure function
-- of the frame relative to demo start (doc.demo_t0). Pure data + arithmetic,
-- deterministic by construction — the input source for the recorded golden
-- (record with --eval "game.demo(1)"). Any real action press hands control
-- back to the player.
--
-- Ported from the old sandbox's kit check (timeline 2) at revamp R0: a short
-- scripted exercise of every moveset RULE from spawn, the determinism oracle
-- for rule changes. Calibrated against the DEFAULT move knobs over the smoke
-- room (level.lua — a plank sits above spawn for the grapple); retuning
-- knobs or the room means re-choreographing (D025). The arcs need not land
-- anywhere precise — the recorded STATE is the oracle.

local M = {}

-- each row is { duration_frames, "action", ... }; rows run back to back.
-- A "press edge" comes from a row that holds an action when the prior frame
-- didn't (jump→flash-jump is jump-row, gap-row, jump-row). After the last
-- row the demo just idles.
local KITCHECK = {
  { 16 }, -- settle
  -- grapple from spawn (plank A sits above): engage, jump-cancel, re-block
  { 4, "grapple" }, -- GRAPPLE engages — reel up
  { 10 }, -- reel
  { 4, "jump" }, -- JUMP cancels it (no flash jump; arms grapple_cd)
  { 6 },
  { 4, "grapple" }, -- BLOCKED (grapple_used this airtime)
  { 36 }, -- land (resets used; grapple_cd still counting)
  -- flash jump is ONCE per airtime: a 2nd airborne press is ignored, and it
  -- re-arms after landing
  { 8, "right", "jump" }, -- ground jump
  { 6, "right" },
  { 4, "right", "jump" }, -- FLASH JUMP #1
  { 6, "right" },
  { 4, "right", "jump" }, -- 2nd airborne press -> BLOCKED (once per airtime)
  { 34 }, -- land
  { 8, "right", "jump" }, -- jump (fresh airtime)
  { 6, "right" },
  { 4, "right", "jump" }, -- FLASH JUMP again -> WORKS (re-armed on landing)
  { 34 }, -- land
  -- up jump locks out flash jump for the airtime
  { 8, "jump" }, -- ground jump
  { 5 },
  { 7, "up", "jump" }, -- UP JUMP
  { 6 },
  { 4, "jump" }, -- jump press airborne -> NO flash jump (locked)
  { 26 }, -- land
  -- hop once per airtime (1-frame TAPs — a multi-frame hold would flutter
  -- and arm the 10 s cooldown, blocking every later hop test)
  { 8, "jump" }, { 5 },
  { 6, "hop" }, -- HOP #1 (a TAP — released before the fall, so no flutter)
  { 5 },
  { 6, "hop" }, -- HOP #2 -> ignored (once per airtime)
  { 26 }, -- land
  -- a normal TAP hop never arms the flutter cooldown
  { 8, "jump" }, { 5 }, { 6, "hop" }, { 28 }, -- tap, land
  { 8, "jump" }, { 5 }, { 6, "hop" }, { 26 }, -- WORKS next airtime (no cd)
  -- a FLUTTER (E held into the FALL) rhythm-boosts then arms the cooldown;
  -- the next airtime's hop is blocked. Kept LAST: its 10 s cd blocks any
  -- hop after.
  { 44 }, -- land FULLY first — the prior arcs leave you airborne here, and
          -- an airborne jump below would fire as a flash jump
  { 8, "jump" }, { 5 },
  { 4, "hop" }, -- hop (a fresh grounded airtime)...
  { 130, "hop" }, -- ...HOLD E into the fall -> rhythmic flutter (arms hop_cd)
  { 40 }, -- land
  { 8, "jump" }, { 5 },
  { 6, "hop" }, -- hop -> BLOCKED (hop_cd still counting)
  { 26 }, -- land
  -- teleport rate-limits its spam and flips A<->B each blink
  { 64, "teleport" }, -- hold -> blinks at the 2/s cap, mode flips
  -- continuous slice while advancing (the attack stub; enemies at M12)
  { 40, "left", "attack" },
  { 24 }, -- bow out
}

-- exported for choreography tooling (boundary dumps, montages); data, not
-- state — readers must not mutate it
M.KITCHECK = KITCHECK

-- is `action` held on relative frame `rel`? (pure; edges derive from rel-1)
function M.down(rel, action)
  if rel < 0 then return false end
  local t = 0
  for _, row in ipairs(KITCHECK) do
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
  for _, row in ipairs(KITCHECK) do t = t + row[1] end
  return t
end

return M
