-- procart.mobgen — procedural cosmic-creature mobs via Bollinger mask
-- templates (the deep-research win, PROCART.md §5): a small hand-authored
-- half-mask where each cell is EMPTY / MAYBE (body or empty) / EDGE (body or
-- border), randomized per seed and mirrored — one template yields a family of
-- silhouettes. The verified caveat (Deep-Fold, Lospec): masks alone give
-- abstract filler; personality needs parameterization on top. So each mob
-- gets the procart treatment — palgen ramps, vertical shading, an accent
-- glow, and above all BIG EYES + optional blush/antennae (the cute stamp).
--
-- These aim at STORY.md §4's roster: reality-leak creatures — cute,
-- eerie-pretty, satisfying to pop. Pure fn(seed); dev/render class (D040).

local paint = cm.require("cm.paint")
local palgen = cm.require("palgen")
local prng = cm.require("prng")

local M = {}

-- half-masks (left half, mirrored to the right — the LAST column of each
-- string sits at the sprite's center line, so body mass must hug the string
-- END or narrow rows split into two lobes; strings: . empty, ? maybe (50%),
-- # body, e edge (75% body)). Kept small — mobs read at 10-14 px.
local TEMPLATES = {
  slime = { -- Fold Slime: a hopping folded-space blob
    "......",
    "...??e",
    ".?###e",
    "?#####",
    "?#####",
    ".e####",
  },
  mote = { -- Star Mote: a loose pixel of starlight
    "....?.",
    "...?#e",
    ".?####",
    "...?#e",
    "....?.",
    "......",
  },
  drone = { -- Pebble Drone: a rock that learned to roll
    "...??.",
    "..?##e",
    ".?####",
    ".?####",
    "..e##e",
    "...ee.",
  },
  imp = { -- Thread Imp: a stitch of raw reality (winged)
    "?...?.",
    ".?..#e",
    "?e.###",
    ".?.###",
    "...e#e",
    "....e.",
  },
  wisp = { -- Mirror Wisp: a reflection that came loose
    "...??.",
    "..?##e",
    "..?##e",
    "...?#e",
    "....?.",
    "...?..",
  },
  beetle = { -- Glyph Beetle: petroglyph-shelled crawler
    "......",
    "..???.",
    ".?###e",
    "?#####",
    ".?###e",
    "..e.e.",
  },
}
M.KINDS = { "slime", "mote", "drone", "imp", "wisp", "beetle" }

-- generate(kind, seed) -> img(14x10), the mob at native scale
function M.generate(kind, seed)
  local tpl = TEMPLATES[kind] or TEMPLATES.slime
  local rng = prng.new(seed ~ prng.mix(#kind * 0x9111))
  local hw = #tpl[1] -- half width
  local h = #tpl
  local W = hw * 2 + 2 -- +1 px margin each side for the outline
  local H = h + 2
  local img = paint.image(W, H)

  -- palette: pastel-cosmic body + a complementary glow accent
  local hbase = rng:float()
  local body = palgen.ramp(hbase, rng:uniform(0.3, 0.55), rng:uniform(0.8, 1.0), 4)
  local glow = paint.hsv((hbase + 0.5) % 1, 0.65, 1.0)

  -- 1. roll the half-mask, mirror, fill (body cells get a vertical ramp:
  -- lighter up top, darker at the base — round-creature shading for free)
  local cells = {}
  for y = 1, h do
    cells[y] = {}
    for x = 1, hw do
      local c = tpl[y]:sub(x, x)
      local on
      if c == "#" then on = true
      elseif c == "?" then on = rng:chance(0.5)
      elseif c == "e" then on = rng:chance(0.75)
      else on = false end
      cells[y][x] = on
    end
  end
  for y = 1, h do
    for x = 1, hw do
      if cells[y][x] then
        local idx = 3 - ((y * 3) // (h + 1) - 1) -- 4..2 top→bottom
        local c = body[math.max(2, math.min(4, idx))]
        paint.set(img, x, y, c)
        paint.set(img, W - 1 - x, y, c)
      end
    end
  end

  -- 2. sparkle: a couple of glow pixels inside the body
  for i = 1, rng:range(1, 3) do
    local gx, gy = rng:range(1, hw), rng:range(1, h)
    if cells[gy] and cells[gy][gx] then
      if rng:chance(0.5) then paint.set(img, gx, gy, glow)
      else paint.set(img, W - 1 - gx, gy, glow) end
    end
  end

  -- 3. the cute stamp: find the widest body row in the upper half, put two
  -- big eyes on it (dark rim + white catchlight), maybe blush
  local best_y, best_w = nil, 0
  for y = 2, math.max(2, h // 2 + 1) do
    local n = 0
    for x = 1, hw do if cells[y][x] then n = n + 1 end end
    if n >= best_w then best_y, best_w = y, n end
  end
  if best_y and best_w >= 2 then
    local dark = palgen.outline(hbase, 0.5, 0.6)
    -- eye column: start from the pair-gap the body width suggests, then walk
    -- toward the center line until we're ON a body cell
    local exo = hw - math.max(1, best_w // 2)
    while exo < hw and not cells[best_y][exo] do exo = exo + 1 end
    if cells[best_y][exo] then
      paint.set(img, exo, best_y, dark)
      paint.set(img, W - 1 - exo, best_y, dark)
      paint.set(img, exo, best_y - 1, 0xffffffff)
      paint.set(img, W - 1 - exo, best_y - 1, 0xffffffff)
      if rng:chance(0.5) and best_y + 1 <= h then -- blush
        local blush = paint.hsv(0.98, 0.45, 1.0)
        if cells[best_y + 1] and cells[best_y + 1][exo - 1] then
          paint.set(img, exo - 1, best_y + 1, blush)
          paint.set(img, W - exo, best_y + 1, blush)
        end
      end
    end
  end

  -- 4. maybe an antenna / spike pair on top (silhouette variety)
  if rng:chance(0.55) then
    local ax = rng:range(2, hw)
    for y = 1, h do
      if cells[y] and cells[y][ax] then
        paint.set(img, ax, y - 1, body[3])
        paint.set(img, W - 1 - ax, y - 1, body[3])
        if rng:chance(0.5) then
          paint.set(img, ax, y - 2, glow)
          paint.set(img, W - 1 - ax, y - 2, glow)
        end
        break
      end
    end
  end

  -- 5. sel-out outline (same rule as chargen: darkened, cooled, never black)
  cm.require("chargen").selout(img)

  return img
end

return M
