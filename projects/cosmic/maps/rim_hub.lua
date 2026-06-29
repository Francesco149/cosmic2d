-- maps/rim_hub — GREYBOX of Map 1 "First Survey" (docs/maps/rim-hub.md).
-- The geometry is a deliberate blockout; the MARKERS carry the plan (what goes
-- where + why). Rendering is utilitarian on purpose — the rich parallax/decor
-- bake comes AFTER the human's art mockup (2026-06-29), so `parallax`/`decor`
-- are left as open slots, not built here.

local T = 16
local STONE, GRASS, PLANK = 1, 2, 3

local M = { title = "RIM HUB - First Survey", w = 120, h = 36, tile = T }

function M.build(tm)
  tm:fill(0, 32, 120, 4, STONE)        -- ground slab (solid bottom; GAME §4)

  -- FOLD-IN: the upper-left landing ledge + a couple steps down into town
  tm:fill(3, 18, 7, 1, PLANK)
  tm:fill(12, 22, 5, 1, PLANK)
  tm:fill(6, 26, 5, 1, PLANK)

  -- RIM PLAZA + the carved gate (the town's "you are here")
  tm:fill(20, 24, 6, 8, STONE)         -- petroglyph cliff wall, left of gate
  tm:fill(30, 22, 2, 10, STONE)        -- gate post L
  tm:fill(36, 22, 2, 10, STONE)        -- gate post R
  tm:fill(30, 22, 8, 2, STONE)         -- gate lintel ("RIM")

  -- COFFEE SHOP: counter (solid) + awning (one-way)
  tm:fill(42, 30, 5, 2, STONE)
  tm:fill(41, 27, 7, 1, PLANK)

  -- LUMI'S STAGE: a raised performance platform + a lighting bar above
  tm:fill(52, 30, 8, 2, STONE)
  tm:fill(52, 26, 8, 1, PLANK)

  -- SANDBOX NOOK: a flat testbed terrace (crates live here)
  tm:fill(64, 30, 8, 2, STONE)

  -- ROOFTOP GYM: stepped one-ways climbing toward the bell-tower
  tm:fill(76, 29, 4, 1, PLANK)
  tm:fill(82, 26, 4, 1, PLANK)
  tm:fill(88, 23, 4, 1, PLANK)         -- chimney gap sits between here and the tower
  tm:fill(96, 20, 4, 1, PLANK)
  tm:fill(100, 12, 2, 20, STONE)       -- bell-tower column (grapple node up top)

  -- TRAILHEADS: the rim's far arm, over the vista
  tm:fill(106, 28, 6, 1, PLANK)
  tm:fill(112, 30, 8, 2, STONE)        -- portal terrace
end

M.spawn = { x = 5 * T, y = 18 * T - 24 }

M.prop_spots = {                       -- crates in the sandbox nook
  { 65 * T, 30 * T - 12 }, { 67 * T, 30 * T - 12 }, { 69 * T, 30 * T - 12 },
  { 66 * T, 30 * T - 24 },
}

local function mk(tx, ty, tw, th, kind, label, note, extra)
  local r = { x = tx * T, y = ty * T, w = tw * T, h = th * T,
              kind = kind, label = label, note = note }
  if extra then for k, v in pairs(extra) do r[k] = v end end
  return r
end

M.markers = {
  mk(3, 6, 4, 4, "poi", "SKY-SEAM",
     "the parked fold-door she fell through (skybox north star)"),
  mk(3, 16, 7, 2, "spawn", "FOLD-IN (spawn)",
     "Vesper lands hat-first; cold-open = the air-control tutorial", { name = "start" }),
  mk(20, 22, 6, 2, "poi", "PETROGLYPH WALL",
     "Sunwright echoes (flavor only; the deep dread lives in the Gulch)"),
  mk(29, 20, 9, 2, "poi", "RIM GATE / PLAZA",
     "town hub + minimap landmark; festival bunting (decor pass later)"),
  mk(41, 25, 7, 3, "shop", "COFFEE SHOP",
     "shopkeep (Bridger?); noticeboard = menu; coffee = town heart"),
  mk(52, 24, 8, 4, "npc", "LUMI'S STAGE",
     "idol; ambient music; Q2 giver; vein footlights flicker on leak"),
  mk(64, 28, 8, 2, "sandbox", "SANDBOX NOOK",
     "prop-spawn ALWAYS on here (GAME §7); the dev testbed; knock crates"),
  mk(76, 17, 28, 13, "poi", "ROOFTOP GYM",
     "the movement toy: flash-jump awnings -> grapple tower -> tp chimney"),
  mk(99, 11, 4, 2, "poi", "BELL-TOWER (grapple node)",
     "the gym's high point; a grapple target"),
  mk(91, 21, 5, 2, "poi", "CHIMNEY GAP",
     "teleport-across gap (mode A/B blink)"),
  mk(106, 26, 4, 2, "portal", "PORTAL -> South Trail",
     "press UP to travel; lights at the end of Q1", { to = "south_trail", at = "from_rim" }),
  mk(112, 28, 6, 2, "spawn", "(arrival from South)", "", { name = "from_south" }),
  mk(116, 28, 3, 2, "portal", "PORTAL (locked)",
     "second trailhead; a future area, dark until unlocked"),
}

-- DEFERRED to the post-art pass (human 2026-06-29): richer environment render
-- M.parallax = { ... baked zoomed/dimmed bg layers ... }
-- M.decor    = { ... non-grid scenery sprites: lanterns, bunting, signs ... }
M.bg = { tint = { 1.04, 0.92, 0.78 } } -- golden-hour warmth (placeholder)

return M
