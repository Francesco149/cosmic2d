-- procart main.lua — the PROCEDURAL ART experiment gallery (docs/PROCART.md).
--
-- An experimental cartridge, separate from the game projects: can
-- mostly-procedural pixel art (chargen + tilegen over prng/pnoise/palgen) hit
-- a cute aesthetic with personality? Pages:
--
--   1 CAST    — 12 characters from 12 seeds (the variety check)
--   2 MOODS   — ONE seed, every mood knob (the personality check: same girl,
--               different face)
--   3 TRIO    — Vesper/Gemma/Lumi via pinned knobs (the production workflow)
--   4 MOBS    — the STORY.md roster from Bollinger half-masks
--   5 TILES   — each material: one repeating tile at 3x + the same tile 3x3
--               (the clean-tiling check)
--   6 MARRY   — material pairs butted together: hard per-tile pick vs the
--               married bake (the no-visible-seam check)
--   7 TERRAIN — a composed material map, married + surface-lit, under a
--               dithered dusk sky (the "could this be a game?" check)
--   8 CANYON  — round 2: the Rim-Hub-shaped scene under the STYLE system —
--               S cycles style preset, G cycles grade (day/dusk/dread),
--               F facet-size dial, D dither-band dial (the tunable demo)
--   9 STYLES  — round 2: the same scene in every style preset, side by side
--
-- Controls: left/right or 1..9 = page · R = reroll seed · S/G/F/D on canyon ·
-- F2 studio · ` console.
--
-- Determinism: sim state is just {page, seed, style, grade, facet, dith} in
-- the doc tree, driven by input edges. All generation is dev/render class
-- (D040) — pure functions of (seed, knobs) built in draw on demand, uploaded
-- to a texture, never traced.

local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local paint = cm.require("cm.paint")
local chargen = cm.require("chargen")
local chargen2 = cm.require("chargen2")
local tilegen = cm.require("tilegen")

local W, H = pal.gfx_size()
local game = {}

local PAGES = { "cast", "moods", "trio", "mobs", "tiles", "marry", "terrain",
  "canyon", "styles" }

-- the tunable dials the canyon page cycles (F/D keys — indices live in sim
-- state, values are render policy here)
local FACETS = { 0.7, 1.0, 1.4 }
local DITHS = { 0.5, 1.0, 2.0 }

local BG = paint.pack(30, 26, 40, 255) -- deep violet-gray checker
local BG2 = paint.pack(38, 33, 51, 255)
local HEADC = { r = 1, g = 0.92, b = 0.7, a = 0.95 }
local LABC = { r = 0.85, g = 0.82, b = 0.95, a = 0.95 }
local DIMC = { r = 0.62, g = 0.58, b = 0.75, a = 0.9 }

-- render cache: one composed page texture + live text labels (dev/render)
local cache = { key = nil, id = nil, tw = 0, th = 0, labels = {} }

local function label(labels, x, y, s, col)
  labels[#labels + 1] = { x = x, y = y, s = s, col = col or LABC }
end

local function blit_scaled(page, img, x, y, s)
  local big = paint.scale(img, img.w * s, img.h * s)
  paint.blit(page, x, y, big, 0, 0, big.w, big.h, "stamp")
end

local function checker(page)
  for y = 0, page.h - 1, 8 do
    for x = 0, page.w - 1, 8 do
      paint.rect(page, x, y, 8, 8, ((x // 8 + y // 8) % 2 == 0) and BG or BG2, true)
    end
  end
end

-- ---- page builders (page image + labels; all pure of seed) ----

local build = {}

function build.cast(page, labels, seed)
  checker(page)
  for i = 0, 9 do
    local col, row = i % 5, i // 5
    local x, y = 4 + col * 96, 14 + row * 124
    local img, d = chargen2.generate(seed * 1000 + i)
    blit_scaled(page, img, x, y, 2)
    label(labels, x + 26, y + 106, d.mood)
    label(labels, x + 12, y + 114, d.hair .. "/" .. d.outfit, DIMC)
  end
  label(labels, 8, 4, ("CAST - 10 characters at 48x64, seeds %d000+"):format(seed), HEADC)
end

function build.moods(page, labels, seed)
  checker(page)
  local _, base = chargen2.generate(seed) -- design sheet for the caption
  for i, m in ipairs(chargen2.MOOD_NAMES) do
    local x = i <= 4 and (28 + (i - 1) * 108) or (82 + (i - 5) * 108)
    local y = i <= 4 and 16 or 142
    local img = chargen2.generate(seed, { mood = m })
    blit_scaled(page, img, x, y, 2)
    label(labels, x + 34, y + 108, m)
  end
  label(labels, 8, 4, ("MOODS - seed %d (%s/%s), one knob turned"):format(
    seed, base.hair, base.outfit), HEADC)
end

-- the designed-cast proof, round 2: the baked cast bundles live in
-- chargen2.CAST — pin what IS the character, the seed fills the rest
local TRIO_NOTES = {
  vesper = "the auditor (protagonist)",
  gemma = "rival architect, cosplay",
  lumi = "the bunny idol",
}

function build.trio(page, labels, seed)
  checker(page)
  for i, name in ipairs(chargen2.CAST_NAMES) do
    local x = 24 + (i - 1) * 152
    local img, d = chargen2.generate(seed + i, chargen2.CAST[name])
    blit_scaled(page, img, x, 22, 3)
    label(labels, x + 40, 216, name, HEADC)
    label(labels, x + 8, 225, TRIO_NOTES[name], DIMC)
    label(labels, x + 8, 234, d.mood .. "/" .. d.hair .. "/" .. d.outfit, DIMC)
  end
  label(labels, 8, 4, ("TRIO - the baked cast (chargen2.CAST) + seed %d fill"):format(seed), HEADC)
end

function build.mobs(page, labels, seed)
  checker(page)
  local mobgen = cm.require("mobgen")
  for row, kind in ipairs(mobgen.KINDS) do
    local y = 20 + (row - 1) * 40
    label(labels, 8, y + 12, kind, LABC)
    for i = 0, 5 do
      local img = mobgen.generate(kind, seed * 100 + i)
      blit_scaled(page, img, 70 + i * 66, y, 4)
    end
  end
  label(labels, 8, 6, ("MOBS - Bollinger half-masks + the cute stamp (seed %d)"):format(seed), HEADC)
end

function build.tiles(page, labels, seed)
  checker(page)
  for i, mat in ipairs(tilegen.MATERIALS) do
    local col, row = (i - 1) % 3, (i - 1) // 3
    local x, y = 10 + col * 158, 24 + row * 122
    local t = tilegen.wrap_tile(mat, seed, 16)
    blit_scaled(page, t, x, y, 3) -- the tile itself
    local t2 = paint.scale(t, 32, 32)
    for ty = 0, 2 do -- the same tile 3x3: the seams must vanish
      for tx = 0, 2 do
        paint.blit(page, x + 52 + tx * 32, y + ty * 32, t2, 0, 0, 32, 32, "set")
      end
    end
    label(labels, x, y + 100, mat)
    label(labels, x + 52, y + 100, "3x3 wrap", DIMC)
  end
  label(labels, 8, 6, ("TILES - repeating tile + self-tiled 3x3 (seed %d)"):format(seed), HEADC)
end

function build.marry(page, labels, seed)
  checker(page)
  local pairs_ = { { "rock", "dirt" }, { "sand", "grass" }, { "brick", "void" } }
  for i, pr in ipairs(pairs_) do
    local a, b = pr[1], pr[2]
    local grid = { { a, a, b, b }, { a, a, b, b } }
    local y = 26 + (i - 1) * 80
    local hard = tilegen.bake(grid, seed, { married = false, gy = i * 64 })
    local wed = tilegen.bake(grid, seed, { gy = i * 64 })
    blit_scaled(page, hard, 52, y, 2)
    blit_scaled(page, wed, 260, y, 2)
    label(labels, 52, y - 9, a .. " | " .. b .. "  (hard seam)", DIMC)
    label(labels, 260, y - 9, "married", LABC)
  end
  label(labels, 8, 6, ("MARRY - per-tile pick vs indicator-field + dither (seed %d)"):format(seed), HEADC)
end

-- the terrain material map: a little side-view scene exercising every border
local function terrain_grid()
  local tw, th = 30, 13
  local prng = cm.require("prng")
  local g = {}
  for ty = 1, th do
    g[ty] = {}
    for tx = 1, tw do g[ty][tx] = "air" end
  end
  for tx = 1, tw do
    -- rolling ground height (hash-wave, 5..7 rows of ground)
    local top = th - 5 - (prng.hash2(42, tx // 3, 0) % 3)
    if tx >= 10 and tx <= 14 then top = top - 2 end -- the rock outcrop rises
    for ty = top, th do
      local depth = ty - top
      local m
      if tx >= 10 and tx <= 14 then m = "rock" -- outcrop: bare rock
      elseif tx >= 22 and tx <= 27 then m = depth < 2 and "sand" or (depth < 5 and "dirt" or "rock")
      else m = depth < 1 and "grass" or (depth < 5 and "dirt" or "rock") end
      g[ty][tx] = m
    end
  end
  -- a cosmic leak pocket in the deep rock
  for ty = th - 2, th do
    for tx = 4, 8 do g[ty][tx] = "void" end
  end
  -- a ruined brick platform floating over the middle
  for tx = 17, 20 do g[4][tx] = "brick" end
  return g
end

-- dithered sky gradient for a grade (stops live in tilegen.GRADES) + stars
-- above the horizon on the dark grades
local function sky(page, grade, seed)
  local stops = tilegen.GRADES[grade].sky
  for y = 0, page.h - 1 do
    local t = y / (page.h - 1)
    for x = 0, page.w - 1 do
      local td = paint.dither_t(t, 9, 1, paint.bayer(8, x, y))
      paint.set(page, x, y, paint.ramp(stops, td))
    end
  end
  if grade ~= "day" then
    local prng = cm.require("prng")
    for i = 0, 40 do
      local sx = prng.hash2(seed, i, 1) % page.w
      local sy = prng.hash2(seed, i, 2) % (page.h // 3)
      paint.set(page, sx, sy, paint.hsv(0.6, 0.1, 0.6 + (i % 3) * 0.15))
    end
  end
end

function build.terrain(page, labels, seed)
  sky(page, "dusk", seed)
  local terr = tilegen.bake(terrain_grid(), seed)
  paint.blit(page, 0, page.h - terr.h, terr, 0, 0, terr.w, terr.h, "stamp")
  label(labels, 8, 6, ("TERRAIN - married material map under a dusk sky (seed %d)"):format(seed), HEADC)
end

local max = math.max

-- ---- round 2: the Rim-Hub-shaped canyon scene (docs/maps/rim-hub.md) ----
-- A cliffside town on a canyon rim, the drop always on the right shoulder:
-- plaza + brick tower at the left, stepped ledges descending rightward into
-- the canyon, the far wall rising at the right edge, a leak pocket glowing in
-- the deep. Pure of seed.
local function canyon_grid(seed)
  local prng = cm.require("prng")
  local tw, th = 30, 15
  local g = {}
  for ty = 1, th do
    g[ty] = {}
    for tx = 1, tw do g[ty][tx] = "air" end
  end
  local function column(tx, top, cap)
    for ty = max(1, top), th do
      local depth = ty - top
      local m
      if depth < 1 then m = cap
      elseif depth < 3 then m = cap == "grass" and "dirt" or cap
      else m = "rock" end
      g[ty][tx] = m
    end
  end
  -- the town plaza (left), with a little height wobble
  for tx = 1, 12 do
    column(tx, 6 - (prng.hash2(seed, tx // 5, 3) % 2), "grass")
  end
  -- stepped rim ledges descending into the canyon
  local steps = { { 13, 15, 8, "grass" }, { 16, 18, 10, "sand" }, { 19, 21, 12, "dirt" } }
  for _, s in ipairs(steps) do
    for tx = s[1], s[2] do column(tx, s[3], s[4]) end
  end
  -- the canyon floor + the leak pocket in the deep
  for tx = 22, 27 do column(tx, 14, "dirt") end
  for tx = 23, 26 do g[15][tx] = "void" end
  -- the far wall at the right edge
  for tx = 28, 30 do column(tx, 4 + (tx == 28 and 2 or 0), "rock") end
  -- the bell tower on the plaza (brick), rim-hub's grapple landmark
  for ty = 2, 5 do
    for tx = 3, 5 do g[ty][tx] = "brick" end
  end
  return g
end

function build.canyon(page, labels, seed, d)
  local style = tilegen.STYLE_NAMES[d.style]
  local grade = tilegen.GRADE_NAMES[d.grade]
  local st = tilegen.style(style, grade,
    { facet_mul = FACETS[d.facet], band_mul = DITHS[d.dith] })
  sky(page, grade, seed)
  local terr = tilegen.bake(canyon_grid(seed), seed, { style = st })
  paint.blit(page, 0, page.h - terr.h, terr, 0, 0, terr.w, terr.h, "stamp")
  label(labels, 8, 6, ("CANYON - rim hub in [%s/%s] (seed %d)"):format(style, grade, seed), HEADC)
  label(labels, 8, 15, ("S style  G grade  F facet x%.1f  D dither x%.1f"):
    format(FACETS[d.facet], DITHS[d.dith]), DIMC)
end

function build.styles(page, labels, seed, d)
  checker(page)
  local grade = tilegen.GRADE_NAMES[d.grade]
  local grid = canyon_grid(seed)
  for i, name in ipairs(tilegen.STYLE_NAMES) do
    local col, row = (i - 1) % 2, (i - 1) // 2
    local x, y = 4 + col * 238, 18 + row * 122
    local st = tilegen.style(name, grade)
    local terr = tilegen.bake(grid, seed, { style = st, tile = 8 })
    paint.blit(page, x, y + 100 - terr.h, terr, 0, 0, terr.w, terr.h, "stamp")
    label(labels, x + 2, y + 102, name, LABC)
  end
  label(labels, 8, 6, ("STYLES - one scene, every preset [%s] (seed %d, G grade)"):
    format(grade, seed), HEADC)
end

-- ---- cartridge ----

local function doc()
  local d = state.doc
  d.procart = d.procart or { page = 1, seed = 1 }
  local p = d.procart
  -- round-2 style knobs (self-heal docs saved before they existed)
  p.style = p.style or 1
  p.grade = p.grade or 2
  p.facet = p.facet or 2
  p.dith = p.dith or 2
  return p
end

-- dev/eval helpers: bin/cosmic projects/procart --eval "game.page(3)"
function game.page(n)
  doc().page = n
end

function game.seed(n)
  doc().seed = n
end

-- dev/eval: set the style knobs directly (indices into the cycles)
function game.knobs(style, grade, facet, dith)
  local d = doc()
  d.style = style or d.style
  d.grade = grade or d.grade
  d.facet = facet or d.facet
  d.dith = dith or d.dith
end

function game.init()
  doc()
  input.map({
    { "prev", input.key.left }, { "next", input.key.right },
    { "reroll", input.key.r },
    { "style", input.key.s }, { "grade", input.key.g },
    { "facet", input.key.f }, { "dith", input.key.d },
    { "p1", input.key["1"] }, { "p2", input.key["2"] }, { "p3", input.key["3"] },
    { "p4", input.key["4"] }, { "p5", input.key["5"] }, { "p6", input.key["6"] },
    { "p7", input.key["7"] }, { "p8", input.key["8"] }, { "p9", input.key["9"] },
  })
end

function game.step()
  local d = doc()
  if input.pressed("next") then d.page = d.page % #PAGES + 1 end
  if input.pressed("prev") then d.page = (d.page - 2) % #PAGES + 1 end
  for i = 1, #PAGES do
    if input.pressed("p" .. i) then d.page = i end
  end
  if input.pressed("reroll") then d.seed = d.seed + 1 end
  if input.pressed("style") then d.style = d.style % #tilegen.STYLE_NAMES + 1 end
  if input.pressed("grade") then d.grade = d.grade % #tilegen.GRADE_NAMES + 1 end
  if input.pressed("facet") then d.facet = d.facet % #FACETS + 1 end
  if input.pressed("dith") then d.dith = d.dith % #DITHS + 1 end
end

local function rebuild(d)
  local key = table.concat({ d.page, d.seed, d.style, d.grade, d.facet, d.dith }, ":")
  if cache.key == key then return end
  local page = paint.image(W, H)
  local labels = {}
  build[PAGES[d.page]](page, labels, d.seed, d)
  if cache.id then pal.tex_free(cache.id) end
  cache.id = pal.tex_create(W, H, page.buf:str(0, W * H * 4))
  cache.key, cache.labels, cache.tw, cache.th = key, labels, W, H
end

function game.draw()
  pal.begin_frame(0.10, 0.09, 0.14, 1)
  local d = doc()
  rebuild(d)
  pal.quad(0, 0, cache.tw, cache.th, 1, 1, 1, 1, cache.id, 0, 0, 1, 1)
  for _, l in ipairs(cache.labels) do
    text.draw(l.x, l.y, l.s, l.col)
  end
  text.draw(3, H - 11,
    ("page %d/%d [%s]  <- -> or 1-9: page  R: reroll  S/G/F/D: style knobs"):format(d.page, #PAGES, PAGES[d.page]),
    { r = 0.9, g = 0.88, b = 0.78, a = 0.9 })
end

return game
