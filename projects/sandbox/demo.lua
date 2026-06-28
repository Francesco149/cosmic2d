-- demo — the attract-mode input scripts: action "key states" as a pure
-- function of the frame relative to demo start (doc.demo_t0). Pure data +
-- arithmetic means a demo is deterministic by construction, so it doubles
-- as the input source for recorded goldens and montages (enable with
-- `game.demo(1)` in the console, or --eval "game.demo(1)" when recording).
-- Any real action press hands control back to the player.
--
-- Two timelines: 1 = the attract TOUR (the moveset showcase), 2 = the KIT
-- CHECK (game.demo(2)) — a short scripted exercise of every moveset RULE
-- from the spawn area, the determinism oracle for rule changes.
--
-- Re-choreographed for the M7 MapleStory moveset (D035). A "press edge"
-- comes from a row that holds an action when the prior frame didn't, so
-- jump→flash-jump is jump-row, gap-row, jump-row; holding "hop" past its
-- press edge is a flutter; "teleport" held auto-spams at the 2/s limit.
-- Calibrated against the DEFAULT move knobs over the PROCEDURAL map (no
-- map.dat); retuning knobs or the map means re-choreographing (D025).

local M = {}

-- timeline: each row is { duration_frames, "action", "action", ... };
-- rows run back to back. After the last row the demo just idles.
local TIMELINE = {
  -- A: jump, then grapple in the air to the plank above — by connect-time
  -- you've fallen back to downward velocity, so the reel is damped (no
  -- slingshot). Shows the extend→connect→reel arc.
  { 30 }, -- settle
  { 6, "jump" }, -- jump up toward the plank
  { 8 }, -- crest, start falling
  { 4, "grapple" }, -- GRAPPLE in the air: the hook extends, then reels
  { 70 }, -- ride the reel up, settle onto the plank
  -- B: flash-jump off the plank, land, then jump + flash again — it's ONCE
  -- per airtime now (re-arms on landing), so the staple is jump->flash->land
  { 20, "right" }, -- walk to the plank edge, off
  { 8, "right" },
  { 5, "right", "jump" }, -- FLASH JUMP — dash + sonic boom
  { 46, "right" }, -- sail forward, land (floatier now)
  { 10, "right", "jump" }, -- jump (a fresh airtime)
  { 8, "right" },
  { 5, "right", "jump" }, -- FLASH JUMP again (re-armed)
  { 44, "right" }, -- sail, land
  { 22 }, -- settle
  -- C: jump -> up-jump climb, hop to fine-tune the apex
  { 10, "jump" }, -- JUMP (fixed apex)
  { 6 }, -- release
  { 7, "up", "jump" }, -- UP JUMP (vertical; the ~5 CH chain)
  { 12 }, -- rise
  { 1, "hop" }, -- HOP near the top — a TAP fine-tuner (no flutter cooldown)
  { 34 }, -- arc back down
  { 26 }, -- land
  -- D: jump, hop at the rise, then hold E -> a high, long flutter hover
  { 30 }, -- settle grounded from C
  { 8, "jump" }, -- JUMP up first (height for a longer hover)
  { 8 }, -- rise
  { 4, "hop" }, -- HOP higher (air hop, fresh airtime)
  { 96, "hop" }, -- HOLD E -> FLUTTER, hover/slow-fall from up high
  { 40 }, -- release: fall the rest, land
  { 24 }, -- settle (hop now on cooldown)
  -- E: teleport blinks (A<->B phase flips) advancing
  { 78, "right", "teleport" }, -- TELEPORT spam — blink, momentum dump, flip
  { 26 }, -- settle
  -- F: continuous slice while advancing (enemies arrive at M12)
  { 56, "left", "attack" }, -- SLICE — slash trail, hop disabled
  { 20 },
  -- G: finale — a flash-jump chain into a teleport flourish. (No hop here:
  -- D's flutter armed the 10 s hop cooldown, which is still counting.)
  { 9, "left", "jump" }, -- jump
  { 6, "left" },
  { 5, "left", "jump" }, -- FLASH JUMP (dash left)
  { 8, "left" },
  { 5, "left", "jump" }, -- FLASH JUMP again
  { 16, "left" },
  { 44, "teleport" }, -- TELEPORT flourish — blink + phase flips
  { 40 }, -- settle, bow
}

-- timeline 2 — the kit check: every moveset RULE exercised from spawn, so a
-- golden trace localizes the first divergent byte if a rule regresses. The
-- arcs need not land anywhere precise — the recorded STATE is the oracle.
local KITCHECK = {
  { 16 }, -- settle
  -- grapple from spawn (a plank sits above): engage, jump-cancel, re-block
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
  -- hop once per airtime (1-frame TAPs — a multi-frame hold would flutter and
  -- arm the 10 s cooldown, which would then block every later hop test)
  { 8, "jump" }, { 5 },
  { 6, "hop" }, -- HOP #1 (a TAP — released before the fall, so no flutter)
  { 5 },
  { 6, "hop" }, -- HOP #2 -> ignored (once per airtime)
  { 26 }, -- land
  -- a normal TAP hop never arms the flutter cooldown
  { 8, "jump" }, { 5 }, { 6, "hop" }, { 28 }, -- tap, land
  { 8, "jump" }, { 5 }, { 6, "hop" }, { 26 }, -- WORKS next airtime (no cd)
  -- a FLUTTER (E held into the FALL) rhythm-boosts then arms the cooldown; the
  -- next airtime's hop is blocked. Kept LAST: its 10 s cd blocks any hop after.
  { 8, "jump" }, { 5 },
  { 4, "hop" }, -- hop...
  { 95, "hop" }, -- ...HOLD E into the fall -> rhythmic flutter (arms hop_cd)
  { 40 }, -- land
  { 8, "jump" }, { 5 },
  { 6, "hop" }, -- hop -> BLOCKED (hop_cd still counting)
  { 26 }, -- land
  -- teleport rate-limits its spam and flips A<->B each blink
  { 64, "teleport" }, -- hold -> blinks at the 2/s cap, mode flips
  { 24 }, -- bow out
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
