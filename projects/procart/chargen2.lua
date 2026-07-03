-- procart.chargen2 — round 2 characters: 48x64, anime-ish per the reference
-- sheets (Wadanohara + the oc goldens), with the CAST baked in.
--
-- The round-2 brief (STATUS 2026-07-03): double the resolution (24x32 ->
-- 48x64), push toward the references' anime read (big expressive eyes with a
-- real iris gradient + catchlight, chunky blunt fringes, flat 2-tone cel
-- fills), and shift the baked:procedural ratio TOWARD baked for the identity
-- carriers — hairstyles, faces, outfits and body types authored from the
-- actual cast (Vesper / Gemma / Lumi, docs/STORY.md §3) — while the seed
-- keeps filling everything unpinned, so the same generator still makes
-- crowds.
--
-- Same contract as chargen: generate(seed, knobs) is pure; every choice
-- consumes its rng roll even when a knob pins it (pin()), so pinning never
-- reshuffles the rest. Baked cast entries are just knob tables (M.CAST) —
-- the production workflow is "pin what IS the character, reroll the rest".
-- Dev/render class (D040) — never sim state.

local paint = cm.require("cm.paint")
local palgen = cm.require("palgen")
local prng = cm.require("prng")
local chargen = cm.require("chargen") -- MOODS + the sel-out outline pass

local M = {}

M.W, M.H = 48, 64
local XMAX = M.W - 1 -- mirror axis: x <-> XMAX-x
local CX = M.W // 2

M.MOODS = chargen.MOODS
M.MOOD_NAMES = chargen.MOOD_NAMES

M.HAIR_NAMES = { "bob", "long", "twin_huge", "ponytail", "buns", "short" }
M.OUTFIT_NAMES = { "dress", "sailor", "armor", "bodysuit", "idol", "hoodie" }
M.ACC_NAMES = { "none", "fins", "horns", "bunny_ears", "ribbon", "ahoge", "halo" }
M.BACK_NAMES = { "none", "hardlight_wings", "crystal", "spade_tail", "fluffy_tail" }

-- the designed cast: baked knob bundles (docs/STORY.md §3 + the oc sheets).
-- Everything left nil is the seed's to roll (crowd-variety survives pinning).
M.CAST = {
  vesper = { -- the auditor: white bob + fin crest, cyan deadpan, silver armor
    mood = "cool", hair = "bob", fringe = "center_strand", acc = "fins",
    outfit = "armor", back = "none", body = "slim", stature = 2, legs = "dark",
    hair_h = 0.55, hair_s = 0.04, hair_v = 0.97,
    eye_h = 0.50, eye_s = 0.75, eye_v = 0.95,
    out_h = 0.58, out_s = 0.05, out_v = 0.93, accent_h = 0.50,
  },
  gemma = { -- the rival architect in succubus cosplay: smug, black+gold
    mood = "smug", hair = "long", fringe = "center_part", acc = "horns",
    outfit = "bodysuit", back = "hardlight_wings", body = "soft", stature = 1,
    hair_h = 0.75, hair_s = 0.22, hair_v = 0.88,
    eye_h = 0.92, eye_s = 0.75, eye_v = 0.95,
    out_h = 0.75, out_s = 0.30, out_v = 0.16, accent_h = 0.13,
  },
  lumi = { -- the bunny idol: huge twintails, sunny, white/purple stage dress
    mood = "sunny", hair = "twin_huge", fringe = "blunt", acc = "bunny_ears",
    outfit = "idol", back = "none", body = "std", stature = 1,
    hair_h = 0.72, hair_s = 0.07, hair_v = 0.98,
    eye_h = 0.97, eye_s = 0.72, eye_v = 0.95,
    out_h = 0.78, out_s = 0.45, out_v = 0.92, accent_h = 0.13,
  },
}
M.CAST_NAMES = { "vesper", "gemma", "lumi" }

-- knob override that still consumes the roll (constant rng draw count)
local function pin(kv, roll)
  if kv ~= nil then return kv end
  return roll
end

-- ---- tiny drawing helpers ----

local function px(img, x, y, c) paint.set(img, x, y, c) end

local function hline(img, x0, x1, y, c)
  if x1 < x0 then x0, x1 = x1, x0 end
  for x = x0, x1 do paint.set(img, x, y, c) end
end

local function vline(img, x, y0, y1, c)
  if y1 < y0 then y0, y1 = y1, y0 end
  for y = y0, y1 do paint.set(img, x, y, c) end
end

local function rect(img, x, y, w, h, c) paint.rect(img, x, y, w, h, c, true) end

local function sym(img, x, y, c)
  paint.set(img, x, y, c)
  paint.set(img, XMAX - x, y, c)
end

local function symv(img, x, y0, y1, c)
  vline(img, x, y0, y1, c)
  vline(img, XMAX - x, y0, y1, c)
end

local function symrect(img, x, y, w, h, c)
  rect(img, x, y, w, h, c)
  rect(img, XMAX - x - w + 1, y, w, h, c)
end

-- ---- the generator ----

-- generate(seed, knobs) -> img(48x64), design
-- knobs may pin anything M.CAST pins, plus: eye, mouth, blush, outline(false)
function M.generate(seed, knobs)
  knobs = knobs or {}
  local rng = prng.new(seed)
  local d = { seed = seed }

  -- --- choices (rng always rolls; knobs override — see pin) ---
  d.mood = pin(knobs.mood, M.MOOD_NAMES[rng:range(#M.MOOD_NAMES)])
  d.hair = pin(knobs.hair, M.HAIR_NAMES[rng:range(#M.HAIR_NAMES)])
  -- crowds only roll the civilian outfits; armor/bodysuit/idol are cast wear
  local outfit_roll = rng:pick({ "dress", "sailor", "hoodie", "dress" })
  d.outfit = pin(knobs.outfit, outfit_roll)
  local acc_roll = rng:range(4, #M.ACC_NAMES) -- crowds skip fins/horns
  d.acc = pin(knobs.acc, rng:chance(0.6) and M.ACC_NAMES[acc_roll] or "none")
  local back_roll = rng:range(3, #M.BACK_NAMES)
  d.back = pin(knobs.back, rng:chance(0.3) and M.BACK_NAMES[back_roll] or "none")
  d.body = pin(knobs.body, rng:pick({ "slim", "std", "std", "soft" }))
  d.stature = pin(knobs.stature, rng:range(0, 2))
  d.fringe = pin(knobs.fringe, rng:pick({ "blunt", "center_part", "swept", "center_strand" }))
  local mood = M.MOODS[d.mood] or M.MOODS.cheery

  -- --- palettes ---
  local hair_h = pin(knobs.hair_h, rng:float())
  local pastel = rng:chance(0.6)
  local hair_s = pin(knobs.hair_s, pastel and rng:uniform(0.25, 0.5) or rng:uniform(0.55, 0.75))
  local hair_v = pin(knobs.hair_v, pastel and rng:uniform(0.85, 1.0) or rng:uniform(0.7, 0.9))
  d.hair_hsv = { hair_h, hair_s, hair_v }
  local hairR = palgen.ramp(hair_h, hair_s, hair_v, 5)

  local skin_h = rng:uniform(0.05, 0.095)
  local skinR = palgen.ramp(skin_h, rng:uniform(0.16, 0.30), rng:uniform(0.94, 1.0), 3,
    { hue_swing = 0.15, v_lo = 0.66 })

  local eye_pick = rng:chance(0.5)
  local eye_drift = rng:uniform(0.1, 0.2)
  local eye_h = pin(knobs.eye_h, (hair_h + (eye_pick and 0.5 or eye_drift)) % 1)
  local eye_s = pin(knobs.eye_s, rng:uniform(0.6, 0.85))
  local eye_v = pin(knobs.eye_v, rng:uniform(0.8, 0.95))
  local irisR = palgen.ramp(eye_h, eye_s, eye_v, 4)

  d.scheme = pin(knobs.outfit_scheme, rng:pick({ "mono", "complement", "analogous", "triad" }))
  local triad_flip, ana_amt, ana_sign =
    rng:chance(0.5), rng:uniform(0.08, 0.16), (rng:chance(0.5) and 1 or -1)
  local scheme_h
  if d.scheme == "mono" then scheme_h = hair_h
  elseif d.scheme == "complement" then scheme_h = (hair_h + 0.5) % 1
  elseif d.scheme == "triad" then scheme_h = (hair_h + (triad_flip and 1 or 2) / 3) % 1
  else scheme_h = (hair_h + ana_amt * ana_sign) % 1 end
  local out_h = pin(knobs.out_h, scheme_h)
  local out_s = pin(knobs.out_s, rng:uniform(0.35, 0.6))
  local out_v = pin(knobs.out_v, rng:uniform(0.75, 0.95))
  local outR = palgen.ramp(out_h, out_s, out_v, 4)
  local out2_h = (out_h + rng:uniform(0.4, 0.6)) % 1
  local out2R = palgen.ramp(out2_h, rng:uniform(0.15, 0.4), rng:uniform(0.88, 1.0), 3)
  local accent_h = pin(knobs.accent_h, (eye_h + rng:uniform(-0.06, 0.06)) % 1)
  local accent = paint.hsv(accent_h, 0.72, 1.0)
  local accent2 = paint.hsv(accent_h, 0.35, 1.0)
  local blushC = paint.hsv(0.98, 0.40, 1.0)
  local dark = palgen.outline(out_h, out_s, out_v)
  local hair_dark = palgen.outline(hair_h, hair_s, hair_v)
  local WHITE = 0xffffffff

  -- --- layout (48x64; the refs' chibi: a BIG round head, stubby legs) ---
  local hw = ({ slim = 26, std = 28, soft = 28 })[d.body]
  local hh = 23
  local hx0 = (M.W - hw) // 2
  local hx1 = hx0 + hw - 1
  local hy0 = 10
  local hy1 = hy0 + hh - 1 -- chin
  local feet = 56 + d.stature -- shoe bottom row (low hems keep legs short)
  local sy0 = hy1 + 2 -- shoulders (1 neck row)
  local bw = ({ slim = 12, std = 14, soft = 16 })[d.body]
  local bx0 = (M.W - bw) // 2
  local bx1 = bx0 + bw - 1
  local capy0 = hy0 - 2 -- hair cap top (the cap rides the head ellipse)

  local img = paint.image(M.W, M.H)

  -- ---- 1. back layer: back hair, wings, tails ----

  if d.hair == "long" then
    -- a full sheet of back hair to the hips, gently widening, ragged hem
    local blen = sy0 + 16
    for yy = hy0 + 3, blen do
      local grow = math.min((yy - hy0 - 3) // 5 + 1, 4)
      local c = yy > blen - 4 and hairR[2] or hairR[3]
      hline(img, hx0 - grow, hx1 + grow, yy, c)
    end
    for x = hx0 - 4, hx1 + 4, 4 do vline(img, x, sy0 + 4, blen, hairR[2]) end
    for x = hx0 - 4, hx1 + 4 do -- ragged hem
      if prng.hash2(seed, x, 77) % 3 ~= 0 then px(img, x, blen + 1, hairR[2]) end
    end
  elseif d.hair == "twin_huge" then
    -- Lumi's: two enormous tails from high on the head down past the knees,
    -- swaying outward then back in — drawn as stacked rows whose center
    -- drifts on a hash-wobbled S-curve, 2-tone banded
    local tl = feet - 6 - (hy0 + 3)
    for i = 0, tl do
      local yy = hy0 + 3 + i
      local t = i / tl
      -- the S: out fast, hold, drift a little further at the tip
      -- (quadratic ease, not libm trig — pixels must match cross-platform)
      local u = math.min(t * 2.2, 1)
      local sway = math.floor(6 * (1 - (1 - u) * (1 - u)) + t * 2)
      local w = i < 3 and 4 or (t > 0.85 and 2 or 6 - (t > 0.6 and 1 or 0))
      local cxx = hx0 - 3 - sway
      local c = (i % 6 < 2) and hairR[2] or hairR[3]
      rect(img, cxx - w // 2, yy, w, 1, c)
      rect(img, XMAX - (cxx - w // 2) - w + 1, yy, w, 1, c)
      if i % 6 == 3 then -- a light band catch
        px(img, cxx, yy, hairR[4]); px(img, XMAX - cxx, yy, hairR[4])
      end
    end
  elseif d.hair == "ponytail" then
    local side = rng:chance(0.5) and 1 or -1
    local tx = side > 0 and hx1 + 2 or hx0 - 2
    local tl = rng:range(16, 24)
    for i = 0, tl do
      local sway = (i > tl // 2) and side * (1 + i // 8) or 0
      local w = i < 3 and 5 or (i > tl - 5 and 2 or 4)
      local xx = tx + sway
      rect(img, side < 0 and xx - w + 1 or xx, hy0 + 2 + i, w, 1,
        i % 5 == 4 and hairR[2] or hairR[3])
    end
  end

  if d.back == "hardlight_wings" then
    -- Gemma's cosplay wings: hard-light magenta bat silhouettes at shoulder
    -- height — a flat translucent-reading fill ribbed darker, lit at the tip
    local wingR = palgen.ramp((accent_h + 0.85) % 1, 0.55, 0.95, 3)
    for i = 0, 11 do
      local yy = sy0 - 6 + i
      -- membrane spread: sweep out over the top rows, scallop back under
      local spread = i < 7 and i or 7 - (i - 7) * 3
      if spread >= 0 then
        local x0 = bx0 - 5 - spread
        local x1 = bx0 - 2
        hline(img, x0, x1, yy, wingR[2])
        hline(img, XMAX - x1, XMAX - x0, yy, wingR[2])
      end
    end
    for k = 0, 2 do -- ribs
      symv(img, bx0 - 6 - k * 3, sy0 - 4 + k, sy0 + 3 - k, wingR[1])
    end
    sym(img, bx0 - 11, sy0 - 6, wingR[3]) -- lit tip
    sym(img, bx0 - 12, sy0 - 5, wingR[3])
  elseif d.back == "crystal" then
    local iceR = palgen.ramp(0.52, 0.30, 1.0, 3)
    for i = 0, 3 do
      local cxx, cyy = bx0 - 4 - i * 2, sy0 - 2 + i * 4
      symrect(img, cxx, cyy, 3, 5 - i, iceR[3 - i % 2])
      sym(img, cxx + 1, cyy, WHITE)
    end
  elseif d.back == "spade_tail" then
    local ty = sy0 + 8
    for i = 0, 6 do px(img, bx1 + 3 + i // 2, ty + i, dark) end
    px(img, bx1 + 6, ty + 7, dark)
    rect(img, bx1 + 6, ty + 5, 3, 2, dark) -- spade
    px(img, bx1 + 7, ty + 5, accent)
  elseif d.back == "fluffy_tail" then
    rect(img, bx1 + 2, sy0 + 8, 7, 8, hairR[3])
    px(img, bx1 + 3, sy0 + 9, hairR[4]); px(img, bx1 + 4, sy0 + 10, hairR[4])
    vline(img, bx1 + 8, sy0 + 12, sy0 + 15, hairR[2])
  end

  -- ---- 2. legs + shoes (outfit hem decides how much shows) ----
  local hem_y -- last torso/skirt row (chibi legs stay SHORT under it)
  if d.outfit == "bodysuit" then hem_y = feet - 3 -- the suit IS the legs
  elseif d.outfit == "armor" then hem_y = sy0 + rng:range(12, 13)
  elseif d.outfit == "idol" then hem_y = sy0 + rng:range(11, 12)
  else hem_y = sy0 + rng:range(12, 14) end
  hem_y = math.min(hem_y, feet - 4)

  local leg_x = CX - 5 -- inner-left leg column (legs are 3 wide each)
  local stock = pin(knobs.legs, rng:pick({ "skin", "skin", "stock", "dark" }))
  if d.outfit == "bodysuit" then stock = "suit" end
  local legC = ({ skin = skinR[3], stock = out2R[2], dark = dark, suit = outR[2] })[stock]
  if hem_y < feet - 3 then
    symrect(img, leg_x, hem_y + 1, 3, feet - 3 - hem_y, legC)
    if stock == "skin" then symv(img, leg_x, hem_y + 1, feet - 3, skinR[2]) end
  end

  -- shoes / boots
  if d.outfit == "armor" then -- silver knee boots with an accent trim
    symrect(img, leg_x - 1, feet - 7, 4, 6, outR[3])
    sym(img, leg_x, feet - 7, accent)
    symv(img, leg_x - 1, feet - 4, feet - 2, outR[2])
    symrect(img, leg_x - 1, feet - 1, 5, 2, outR[4])
  elseif d.outfit == "idol" then -- fluffy cuff + little boot
    symrect(img, leg_x - 1, feet - 5, 4, 2, WHITE)
    sym(img, leg_x + 1, feet - 5, out2R[2])
    symrect(img, leg_x - 1, feet - 3, 4, 4, outR[2])
    sym(img, leg_x - 1, feet - 1, outR[4])
  else
    symrect(img, leg_x - 1, feet - 2, 4, 3, outR[2])
    sym(img, leg_x - 1, feet - 1, outR[4]) -- toe shine
  end

  -- ---- 3. torso / outfit ----
  local belt = sy0 + 5
  if d.outfit == "armor" then
    -- Vesper: silver plate, cyan core, pauldrons, faulds (skirt panels)
    rect(img, bx0, sy0, bw, 6, outR[3])
    hline(img, bx0 + 1, bx1 - 1, sy0, outR[4]) -- collar light
    symrect(img, bx0 - 2, sy0, 3, 3, outR[4]) -- pauldrons
    sym(img, bx0 - 2, sy0 + 1, outR[2])
    rect(img, CX - 1, sy0 + 2, 2, 3, accent) -- the core
    px(img, CX - 1, sy0 + 2, accent2)
    hline(img, bx0, bx1, sy0 + 6, outR[1]) -- waist seam
    for r = 0, hem_y - (sy0 + 7) do -- faulds: angular panels, widening
      local grow = math.min(r // 2 + 1, 4)
      local yy = sy0 + 7 + r
      hline(img, bx0 - grow, bx1 + grow, yy, r % 3 == 2 and outR[2] or outR[3])
    end
    symv(img, CX - 4, sy0 + 7, hem_y, outR[1]) -- panel seams
    vline(img, CX, sy0 + 7, hem_y, outR[1])
  elseif d.outfit == "bodysuit" then
    -- Gemma: near-black suit + gold trim + the chest gem
    rect(img, bx0, sy0, bw, hem_y - sy0 + 1, outR[3])
    symv(img, bx0, sy0, hem_y, outR[2]) -- side shade
    hline(img, bx0 + 1, bx1 - 1, sy0, paint.hsv(accent_h, 0.7, 0.95)) -- gold collar
    -- gold waist V
    for i = 0, 2 do sym(img, bx0 + 2 + i, belt + i, paint.hsv(accent_h, 0.7, 0.9)) end
    rect(img, CX - 1, sy0 + 3, 2, 3, paint.hsv((accent_h + 0.8) % 1, 0.75, 1)) -- gem
    px(img, CX - 1, sy0 + 3, WHITE)
    if d.body == "soft" then -- chest shading
      sym(img, bx0 + 2, sy0 + 3, outR[2])
      sym(img, bx0 + 3, sy0 + 4, outR[2])
    end
  elseif d.outfit == "idol" then
    -- Lumi: white bodice, puff sleeves, gold hem, purple pleated bell skirt
    local whiteR = palgen.ramp(out_h, 0.06, 0.98, 3)
    rect(img, bx0, sy0, bw, 5, whiteR[3])
    hline(img, bx0, bx1, sy0, whiteR[2]) -- neckline
    symrect(img, bx0 - 3, sy0, 3, 4, whiteR[3]) -- puff sleeves
    sym(img, bx0 - 3, sy0 + 3, whiteR[2])
    sym(img, CX - 1, sy0 + 2, accent) -- brooch pair
    hline(img, bx0, bx1, sy0 + 5, paint.hsv(accent_h, 0.65, 0.95)) -- gold waist
    for r = 0, hem_y - (sy0 + 6) do -- bell skirt
      local grow = math.min(r + 1, 6)
      local yy = sy0 + 6 + r
      local c = r >= hem_y - (sy0 + 6) - 1 and outR[2] or outR[3]
      hline(img, bx0 - grow, bx1 + grow, yy, c)
      for x = bx0 - grow + 1, bx1 + grow - 1, 3 do px(img, x, yy, outR[2]) end -- pleats
    end
    hline(img, bx0 - 6, bx1 + 6, hem_y + 1, paint.hsv(accent_h, 0.65, 0.95)) -- gold hem
  elseif d.outfit == "dress" then
    rect(img, bx0, sy0, bw, 4, outR[3])
    for r = 0, hem_y - (sy0 + 4) do
      local grow = math.min(r, 5)
      if r == hem_y - (sy0 + 4) then grow = grow - 1 end
      local rows = hem_y - (sy0 + 4)
      local c = r > rows - 3 and outR[1] or (r > rows // 2 and outR[2] or outR[3])
      hline(img, bx0 - grow, bx1 + grow, sy0 + 4 + r, c)
      if r < rows - 2 then
        for x = bx0 - grow + 2, bx1 + grow - 2, 4 do px(img, x, sy0 + 4 + r, outR[2]) end
      end
    end
    sym(img, bx0 + 1, sy0, out2R[3]) -- collar
    sym(img, CX - 1, sy0 + 1, accent) -- brooch
  elseif d.outfit == "sailor" then
    rect(img, bx0, sy0, bw, 6, out2R[3]) -- white top
    for i = 0, 3 do sym(img, bx0 + i, sy0 + i, outR[3]) end -- collar V
    for r = 0, hem_y - (sy0 + 6) do
      local grow = math.min(r, 4)
      hline(img, bx0 - 1 - grow, bx1 + 1 + grow, sy0 + 6 + r, outR[3])
      for x = bx0 - 1, bx1 + 1, 3 do px(img, x, sy0 + 6 + r, outR[2]) end -- pleats
    end
    sym(img, CX - 1, sy0 + 4, accent) -- scarf knot
  else -- hoodie
    rect(img, bx0 - 2, sy0, bw + 4, hem_y - sy0 + 1, outR[3])
    hline(img, bx0 - 2, bx1 + 2, sy0, out2R[2]) -- bunched hood
    hline(img, bx0 - 1, bx1 + 1, hem_y - 2, outR[2]) -- pocket
    sym(img, CX - 3, sy0 + 3, accent2) -- drawstrings
    vline(img, CX, sy0 + 1, hem_y - 3, outR[2]) -- zip
  end

  -- arms (skip hoodie — sleeves read within the silhouette)
  if d.outfit ~= "hoodie" then
    local arm_len = rng:range(7, 9)
    local sleeve_roll = rng:chance(0.5)
    local sleeved = (d.outfit ~= "dress" and d.outfit ~= "idol") or sleeve_roll
    local armC = sleeved and (d.outfit == "bodysuit" and outR[2] or outR[3]) or skinR[3]
    local ax = bx0 - (d.outfit == "idol" and 4 or 2)
    symrect(img, ax, sy0 + (d.outfit == "idol" and 4 or 3), 2, arm_len - 3, armC)
    symrect(img, ax, sy0 + arm_len + 1, 2, 2, skinR[3]) -- hands
  else
    rng:range(7, 9); rng:chance(0.5)
  end

  -- ---- 4. head (a truly round chibi mask: one filled ellipse) ----
  paint.ellipse(img, hx0, hy0, hx1, hy1, skinR[3], true)
  hline(img, hx0 + 9, hx1 - 9, hy1, skinR[2]) -- chin shade
  -- neck
  rect(img, CX - 2, hy1 + 1, 4, 2, skinR[2])

  -- ---- 5. front hair ----
  local fy0 = hy0 + 4 -- first fringe row
  -- cap: the head ellipse grown 1px, drawn only above the fringe line — the
  -- cap follows the skull's curve exactly (this is what keeps heads ROUND)
  paint.ellipse(img, hx0 - 1, hy0 - 2, hx1 + 1, hy1 + 2, hairR[3], true,
    function(im, x, y, c) if y < fy0 then paint.set(im, x, y, c) end end)
  hline(img, hx0 + 5, hx0 + hw // 2 + 2, hy0 - 1, hairR[4]) -- shine arc
  hline(img, hx0 + 4, hx0 + hw // 2 - 1, hy0, hairR[4])

  -- fringe: chunky teeth from the cap down over the brow line
  local ncol = hw - 4
  for i = 0, ncol - 1 do
    local xx = hx0 + 2 + i
    local c = math.abs(i - (ncol - 1) / 2)
    local fl -- fringe length in px (below fy0)
    if d.fringe == "blunt" then
      fl = 3 + (prng.hash2(seed, i // 3, 5) % 2)
    elseif d.fringe == "center_part" then
      fl = c < 2 and 0 or math.min(2 + (c - 2) * 1.4, 7)
    elseif d.fringe == "center_strand" then
      -- Vesper: parted, with one long strand falling between the eyes
      fl = c < 1.5 and 8 or math.max(2, 6 - (c - 1) * 1.2)
    else -- swept
      fl = 2 + (i * 5) // ncol
    end
    fl = math.floor(fl)
    if fl > 0 then
      vline(img, xx, fy0, fy0 + fl - 1, hairR[3])
      px(img, xx, fy0 + fl - 1, hairR[2]) -- tip shade
      if fl > 2 and i % 4 == 1 then px(img, xx, fy0, hairR[4]) end -- strand light
    end
  end
  hline(img, hx0 + 2, hx1 - 2, fy0 - 1, hairR[3]) -- seal cap->fringe
  -- side locks framing the face
  local lock_len = ({ bob = 9, long = 14, twin_huge = 7, ponytail = 6,
    buns = 6, short = 4 })[d.hair]
  symrect(img, hx0 - 2, hy0 + 2, 2, lock_len + 1, hairR[3])
  symv(img, hx0, hy0 + 3, hy0 + lock_len - 1, hairR[2])
  sym(img, hx0 - 2, hy0 + lock_len + 3, hairR[2]) -- lock tip
  if d.hair == "bob" then -- the bob flips outward at the jaw
    sym(img, hx0 - 3, hy0 + lock_len + 2, hairR[3])
    sym(img, hx0 - 3, hy0 + lock_len + 3, hairR[2])
  elseif d.hair == "buns" then
    symrect(img, hx0 + 4, capy0 - 3, 5, 4, hairR[3])
    sym(img, hx0 + 5, capy0 - 3, hairR[4])
    sym(img, hx0 + 4, capy0 - 4, hairR[2])
  elseif d.hair == "twin_huge" then -- tie ribbons where the tails start
    sym(img, hx0 - 1, hy0 + 3, accent)
    sym(img, hx0 - 2, hy0 + 2, accent)
  end

  -- ---- 6. face (drawn over the fringe — anime brows/eyes read on top) ----
  local ey = hy0 + hh // 2 - 1 -- eye top row (lash line) — chibi eyes sit low
  local esep = 2 -- inner eye edge from center (close-set = cuter)
  local look = (mood.look or 0) * 2
  local eyestyle = pin(knobs.eye, mood.eye)
  local ew = 7 -- eye box: a 5-wide iris + lash overhang

  -- one eye: ex = left col of the box, dirn -1 left eye / +1 right eye.
  -- Big anime eye (the refs): heavy lash cap, 5-wide iris shaded DARK at the
  -- top (lash shadow) to LIGHT at the bottom, a 2x2 catchlight high-outer, a
  -- 1px low-inner reflection. The catchlight is the cuteness carrier.
  local function eye(ex, dirn)
    local ix0 = ex + 1 -- iris box left (5 wide)
    local co = dirn < 0 and ix0 or ix0 + 3 -- catchlight left col (2 wide)
    local ri = dirn < 0 and ix0 + 4 or ix0 -- low reflection col (inner)
    if eyestyle == "round" then
      hline(img, ex, ex + ew - 1, ey, dark) -- lash cap
      px(img, ex + (dirn < 0 and 0 or ew - 1), ey - 1, dark) -- outer lash lift
      local rows = { irisR[1], irisR[2], irisR[3], irisR[4], irisR[3] }
      for r = 1, 5 do
        local inset = (r == 1 or r == 5) and 1 or 0 -- round the iris
        hline(img, ix0 + inset, ix0 + 4 - inset, ey + r, rows[r])
      end
      rect(img, co, ey + 1, 2, 2, WHITE) -- catchlight
      px(img, ri, ey + 4, WHITE) -- low reflection
    elseif eyestyle == "half" then -- smug lid: flat top, iris cut by it
      hline(img, ex, ex + ew - 1, ey + 1, dark)
      px(img, ex + (dirn < 0 and 0 or ew - 1), ey, dark)
      local rows = { irisR[2], irisR[3], irisR[2] }
      for r = 1, 3 do
        local inset = r == 3 and 1 or 0
        hline(img, ix0 + inset, ix0 + 4 - inset, ey + 1 + r, rows[r])
      end
      rect(img, co, ey + 2, 2, 1, WHITE) -- squished catchlight
    elseif eyestyle == "sharp" then -- Vesper: narrow wedge, liner, NO catchlight
      hline(img, ex, ex + ew - 1, ey + 1, dark)
      px(img, ex + (dirn < 0 and 0 or ew - 1), ey, dark) -- upward flick
      px(img, ex + (dirn < 0 and 1 or ew - 2), ey, dark)
      hline(img, ix0, ix0 + 4, ey + 2, irisR[3])
      hline(img, ix0, ix0 + 4, ey + 3, irisR[2])
      hline(img, ix0 + 1, ix0 + 3, ey + 4, irisR[1])
    elseif eyestyle == "droopy" then -- lid sags outward
      local o = dirn < 0 and ex or ex + ew - 1
      px(img, o, ey + 2, dark)
      hline(img, math.min(o + dirn * -1, o + dirn * -(ew - 2)),
        math.max(o + dirn * -1, o + dirn * -(ew - 2)), ey + 1, dark)
      local rows = { irisR[3], irisR[2], irisR[1] }
      for r = 1, 3 do
        local inset = r == 3 and 1 or 0
        hline(img, ix0 + inset, ix0 + 4 - inset, ey + 1 + r, rows[r])
      end
      px(img, co, ey + 2, WHITE)
    else -- closed: a happy (n) arc, thick at the ends
      px(img, ex, ey + 3, dark); px(img, ex + ew - 1, ey + 3, dark)
      px(img, ex, ey + 2, dark); px(img, ex + ew - 1, ey + 2, dark)
      px(img, ex + 1, ey + 1, dark); px(img, ex + ew - 2, ey + 1, dark)
      hline(img, ex + 2, ex + ew - 3, ey, dark)
    end
  end
  local exL = CX - esep - ew + look
  local exR = CX + esep + look
  eye(exL, -1)
  eye(exR, 1)

  -- brows
  local brow = mood.brow or 0
  local by = ey - 3
  if eyestyle ~= "closed" or brow < 0 then
    local function brow1(bx, dirn)
      local o = dirn < 0 and bx or bx + 3
      local n = dirn < 0 and bx + 3 or bx
      if brow <= -2 then -- fierce V
        hline(img, math.min(o, n) + (dirn < 0 and 0 or 0), math.max(o, n), by + 1, 0)
        px(img, o, by, dark); px(img, (o + n) // 2, by + 1, dark); px(img, n, by + 2, dark)
        px(img, o + (dirn < 0 and 1 or -1), by, dark)
      elseif brow < 0 then
        px(img, o, by, dark)
        hline(img, math.min(o, n) + 1, math.max(o, n) - 1, by + 1, dark)
        px(img, n, by + 1, dark)
      elseif brow > 0 then
        px(img, o, by + 1, dark)
        hline(img, math.min(o, n) + 1, math.max(o, n) - 1, by, dark)
        px(img, n, by + 1, dark)
      else
        hline(img, math.min(o, n), math.max(o, n), by, dark)
      end
    end
    brow1(exL + 1, -1)
    brow1(exR, 1)
  end

  -- mouth
  local my = hy1 - 4
  local mx = CX + look
  local mouth = pin(knobs.mouth, mood.mouth)
  if mouth == "open" then -- happy open smile
    hline(img, mx - 2, mx + 1, my - 1, dark)
    rect(img, mx - 1, my, 2, 1, paint.hsv(0.99, 0.55, 0.95))
    px(img, mx - 2, my, dark); px(img, mx + 1, my, dark)
    hline(img, mx - 1, mx, my + 1, dark)
  elseif mouth == "cat" then
    px(img, mx - 3, my, dark); px(img, mx - 2, my - 1, dark)
    px(img, mx - 1, my, dark); px(img, mx, my - 1, dark)
    px(img, mx + 1, my, dark)
  elseif mouth == "flat" then
    hline(img, mx - 2, mx + 1, my, dark)
  elseif mouth == "small" then
    hline(img, mx - 1, mx, my, dark)
  elseif mouth == "frown" then
    hline(img, mx - 1, mx, my - 1, dark)
    px(img, mx - 2, my, dark); px(img, mx + 1, my, dark)
  else -- smile arc
    px(img, mx - 3, my - 1, dark); px(img, mx + 2, my - 1, dark)
    hline(img, mx - 2, mx + 1, my, dark)
  end

  -- blush
  local blush = pin(knobs.blush, mood.blush or 0)
  if blush > 0 then
    local bly = ey + 7
    symrect(img, hx0 + 4, bly, 3, 1, blushC)
    if blush >= 1 then sym(img, hx0 + 5, bly + 1, blushC) end
    if blush >= 2 then symrect(img, hx0 + 3, bly - 1, 4, 1, blushC) end
  end

  -- ---- 7. head accessory ----
  if d.acc == "fins" then
    -- Vesper: crystalline fin crest swept back from the head sides
    local finR = palgen.ramp(0.50, 0.30, 1.0, 3)
    for i = 0, 5 do
      local w = 6 - i
      local yy = hy0 + 2 - i
      hline(img, hx0 - 3 - i, hx0 - 4 - i + w, yy, i % 2 == 0 and finR[3] or finR[2])
      hline(img, XMAX - (hx0 - 4 - i + w), XMAX - (hx0 - 3 - i), yy, i % 2 == 0 and finR[3] or finR[2])
    end
    sym(img, hx0 - 4, hy0 - 3, WHITE) -- glint
  elseif d.acc == "horns" then
    -- Gemma: big curved horns sweeping up-out from the cap
    local hornC = paint.hsv(0.78, 0.35, 0.16)
    local hornL = paint.hsv(0.78, 0.25, 0.34)
    for i = 0, 6 do
      local w = i < 2 and 3 or 2
      local xx = hx0 + 3 - (i > 2 and i - 2 or 0)
      local yy = capy0 - i
      rect(img, xx, yy, w, 1, hornC)
      rect(img, XMAX - xx - w + 1, yy, w, 1, hornC)
      if i > 1 then
        px(img, xx, yy, hornL) -- lit outer edge
        px(img, XMAX - xx, yy, hornL)
      end
    end
    sym(img, hx0 - 1, capy0 - 7, hornL) -- tip
  elseif d.acc == "bunny_ears" then
    -- Lumi: tall soft ears with pink inners, one kinked
    local ex = hx0 + 6
    for i = 0, 9 do
      local kink = i > 6 and 1 or 0 -- left ear tips over
      rect(img, ex - kink, capy0 - 10 + i, 3, 1, out2R[3])
      rect(img, XMAX - ex - 2, capy0 - 10 + i, 3, 1, out2R[3])
      if i > 1 and i < 9 then
        px(img, ex + 1 - kink, capy0 - 10 + i, paint.hsv(0.97, 0.35, 1))
        px(img, XMAX - ex - 1, capy0 - 10 + i, paint.hsv(0.97, 0.35, 1))
      end
    end
    sym(img, ex, capy0 - 10, out2R[2])
  elseif d.acc == "ribbon" then
    local rx = hx0 + 3
    rect(img, rx, capy0 - 1, 3, 3, accent)
    px(img, rx + 3, capy0, dark)
    rect(img, rx + 4, capy0 - 1, 3, 3, accent)
    px(img, rx + 2, capy0 - 1, accent2)
  elseif d.acc == "ahoge" then
    px(img, CX, capy0 - 1, hairR[3])
    px(img, CX + 1, capy0 - 2, hairR[3])
    px(img, CX + 1, capy0 - 3, hairR[3])
    px(img, CX, capy0 - 4, hairR[3])
  elseif d.acc == "halo" then
    local gold, gold2 = paint.hsv(0.13, 0.55, 1), paint.hsv(0.13, 0.30, 1)
    hline(img, CX - 4, CX + 3, capy0 - 6, gold)
    sym(img, CX - 5, capy0 - 5, gold2)
    hline(img, CX - 3, CX + 2, capy0 - 5, 0) -- keep the ring hollow
  end

  -- ---- 8. sel-out outline ----
  if knobs.outline ~= false then
    chargen.selout(img)
  end

  return img, d
end

return M
