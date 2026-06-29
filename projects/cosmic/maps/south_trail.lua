-- maps/south_trail — GREYBOX of Map 2 "The Long Light" (docs/maps/south-trail.md).
-- A descending sunlit trail: switchbacks -> horde shelf -> flash-jump span ->
-- Gemma's overlook. Blockout geometry + annotated MARKERS; rich render deferred.

local T = 16
local STONE, GRASS, PLANK = 1, 2, 3

local M = { title = "SOUTH TRAIL - The Long Light", w = 130, h = 56, tile = T }

function M.build(tm)
  -- TRAILHEAD: arrival shelf (top-left), from the Rim portal
  tm:fill(0, 14, 16, 3, STONE)

  -- SWITCHBACKS: alternating one-way ledges descending right
  tm:fill(16, 18, 8, 1, PLANK)
  tm:fill(10, 22, 8, 1, PLANK)
  tm:fill(18, 26, 8, 1, PLANK)
  tm:fill(12, 30, 8, 1, PLANK)
  tm:fill(20, 34, 10, 1, PLANK)

  -- SUNSHELF: a wide solid horde arena
  tm:fill(28, 38, 26, 3, STONE)

  -- CRACKED SPAN: flash-jump gaps (solid stubs with gaps between)
  tm:fill(56, 40, 4, 2, STONE)
  tm:fill(64, 40, 4, 2, STONE)
  tm:fill(72, 40, 4, 2, STONE)

  -- hidden TP-WALL vault: a thin wall hides a stardust nook behind it
  tm:fill(80, 36, 2, 8, STONE)         -- the wall (teleport mode-B through it)
  tm:fill(82, 42, 6, 1, PLANK)         -- the vault ledge

  -- descent to the OVERLOOK (Gemma's domain), bottom-right
  tm:fill(90, 44, 10, 1, PLANK)
  tm:fill(100, 48, 30, 4, STONE)       -- overlook arena floor
  -- (no floor past x~128 -> the gulch drop / down-portal)
end

M.spawn = { x = 3 * T, y = 14 * T - 24 }
M.prop_spots = {}

local function mk(tx, ty, tw, th, kind, label, note, extra)
  local r = { x = tx * T, y = ty * T, w = tw * T, h = th * T,
              kind = kind, label = label, note = note }
  if extra then for k, v in pairs(extra) do r[k] = v end end
  return r
end

M.markers = {
  mk(2, 12, 14, 2, "spawn", "TRAILHEAD (from Rim)",
     "arrival shelf; town noise fades behind you", { name = "from_rim" }),
  mk(0, 10, 4, 2, "portal", "PORTAL -> Rim",
     "press UP to return to the hub", { to = "rim_hub", at = "from_south" }),
  mk(8, 16, 22, 20, "poi", "SWITCHBACKS",
     "one-way descent gym; flash-jump the corners for strung stardust"),
  mk(28, 34, 26, 4, "arena", "SUNSHELF (horde arena)",
     "Q2 first horde: Fold Slimes SPLIT, Pebble Drones charge - carve clean"),
  mk(40, 36, 6, 2, "poi", "CACTUS HAZARD",
     "Cactus Satellites: orbiting-spike hazards to fight AROUND"),
  mk(56, 37, 20, 3, "poi", "CRACKED SPAN",
     "flash-jump gap test; the movement check before the boss"),
  mk(80, 32, 2, 4, "secret", "TP-WALL (hidden)",
     "teleport (mode B) THROUGH the thin wall -> the Sun-Cache"),
  mk(82, 40, 6, 2, "secret", "SUN-CACHE (vault)",
     "fat stardust + a cactus-bloom farmable; rewards tp curiosity"),
  mk(100, 44, 30, 4, "arena", "THE OVERLOOK",
     "Q3 Gemma's 'domain' - comedic boss duel; Thread Imp adds"),
  mk(110, 44, 7, 3, "npc", "GEMMA'S THRONE",
     "she hard-light-renders a camp chair into an 'eternal throne'"),
  mk(125, 46, 4, 5, "portal", "PORTAL -> Whisper Gulch",
     "(future) Gemma flees down here; Q4 the first dread beat", { to = "whisper_gulch" }),
}

-- DEFERRED (post-art): M.parallax / M.decor (see rim_hub note)
M.bg = { tint = { 1.05, 0.9, 0.72 } }  -- warm canyon daylight (placeholder)

return M
