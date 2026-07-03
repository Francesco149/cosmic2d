-- procart.chargen — procedural chibi characters with PERSONALITY from knobs.
--
-- The experiment (docs/PROCART.md): can mostly-procedural pixel art hit the
-- cute-with-personality bar? A character is a pure function of (seed, knobs):
-- the seed rolls every unspecified choice; knobs pin any of them (that's how a
-- designed cast member coexists with a random crowd). Structure:
--
--   baked ARCHETYPE menus  — hair styles, outfits, accessories, back items
--                            (small hand-coded pixel stamps = the "sprinkle of
--                            baked choices", each with procedural sub-knobs)
--   procedural KNOBS       — proportions, palettes (hue-shifted ramps from
--                            palgen), mood (eye/brow/mouth geometry), blush,
--                            look direction, stature
--   a SEL-OUT outline pass — outline color derived per-pixel from what it
--                            borders (darkened + cooled), never flat black
--
-- Pinning a knob must not reshuffle the rest of the character: every choice
-- rolls the rng UNCONDITIONALLY and the knob only overrides the result (see
-- pin()), so generate(seed, {mood="smug"}) is the same girl as generate(seed)
-- with a different face. Canvas 24x32, feet at the bottom margin. Dev/render
-- class (D040) — never sim state.

local paint = cm.require("cm.paint")
local palgen = cm.require("palgen")
local prng = cm.require("prng")

local M = {}

M.W, M.H = 24, 32
local XMAX = M.W - 1 -- mirror axis: x <-> XMAX-x
local CX = M.W // 2

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

-- set (x,y) and its mirror — for symmetric detail
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

-- ---- moods: the personality dial (eye/brow/mouth geometry + blush) ----
-- brow: -2 fierce V .. 0 flat .. +1 raised soft. look: pupil x offset.

M.MOODS = {
  cheery = { eye = "round", brow = 1, mouth = "open", blush = 1 },
  smug = { eye = "half", brow = -1, mouth = "cat", blush = 0 },
  sleepy = { eye = "droopy", brow = 1, mouth = "small", blush = 0.5 },
  cool = { eye = "sharp", brow = 0, mouth = "flat", blush = 0 },
  shy = { eye = "round", brow = 1, mouth = "small", blush = 2, look = 1 },
  grumpy = { eye = "sharp", brow = -2, mouth = "frown", blush = 0 },
  sunny = { eye = "closed", brow = 1, mouth = "open", blush = 1 },
}
M.MOOD_NAMES = { "cheery", "smug", "sleepy", "cool", "shy", "grumpy", "sunny" }

M.HAIR_NAMES = { "bob", "twintail", "long", "ponytail", "buns", "spiky", "hime" }
M.OUTFIT_NAMES = { "dress", "suit", "hoodie", "sailor" }
M.ACC_NAMES = { "none", "cat_ears", "bunny_ears", "horns", "halo", "ribbon", "ahoge" }
M.BACK_NAMES = { "none", "butterfly", "crystal", "spade_tail", "fluffy_tail" }

-- ---- the generator ----

-- generate(seed, knobs) -> img(24x32), design
-- knobs may pin: mood, hair, outfit, acc, back, hair_h/s/v, outfit_scheme,
-- head_w, head_h, stature, fringe, eye, mouth, blush, eye_h, outline(false)
function M.generate(seed, knobs)
  knobs = knobs or {}
  local rng = prng.new(seed)
  local d = { seed = seed }

  -- --- choices (rng always rolls; knobs override — see pin) ---
  d.mood = pin(knobs.mood, M.MOOD_NAMES[rng:range(#M.MOOD_NAMES)])
  d.hair = pin(knobs.hair, M.HAIR_NAMES[rng:range(#M.HAIR_NAMES)])
  d.outfit = pin(knobs.outfit, M.OUTFIT_NAMES[rng:range(#M.OUTFIT_NAMES)])
  local acc_roll = rng:range(2, #M.ACC_NAMES)
  d.acc = pin(knobs.acc, rng:chance(0.7) and M.ACC_NAMES[acc_roll] or "none")
  local back_roll = rng:range(2, #M.BACK_NAMES)
  d.back = pin(knobs.back, rng:chance(0.35) and M.BACK_NAMES[back_roll] or "none")
  d.head_w = pin(knobs.head_w, rng:pick({ 12, 14, 14, 16 }))
  d.head_h = pin(knobs.head_h, rng:range(9, 11))
  d.stature = pin(knobs.stature, rng:range(0, 2)) -- 0 tiniest .. 2 tallest
  d.fringe = pin(knobs.fringe, rng:pick({ "straight", "m", "swept" }))
  local mood = M.MOODS[d.mood] or M.MOODS.cheery

  -- --- palettes (every ramp shares palgen's hue-shift logic) ---
  local hair_h = pin(knobs.hair_h, rng:float())
  local pastel = rng:chance(0.6)
  local hair_s = pin(knobs.hair_s, pastel and rng:uniform(0.28, 0.5) or rng:uniform(0.55, 0.75))
  local hair_v = pin(knobs.hair_v, pastel and rng:uniform(0.85, 1.0) or rng:uniform(0.7, 0.9))
  d.hair_hsv = { hair_h, hair_s, hair_v }
  local hairR = palgen.ramp(hair_h, hair_s, hair_v, 4)

  local skin_h = rng:uniform(0.05, 0.095)
  local skinR = palgen.ramp(skin_h, rng:uniform(0.18, 0.32), rng:uniform(0.93, 1.0), 3,
    { hue_swing = 0.15, v_lo = 0.62 })

  local eye_pick = rng:chance(0.5)
  local eye_drift = rng:uniform(0.1, 0.2)
  local eye_h = pin(knobs.eye_h, (hair_h + (eye_pick and 0.5 or eye_drift)) % 1)
  local irisR = palgen.ramp(eye_h, rng:uniform(0.6, 0.85), rng:uniform(0.75, 0.95), 3)

  d.scheme = pin(knobs.outfit_scheme, rng:pick({ "mono", "complement", "analogous", "triad" }))
  local triad_flip, ana_amt, ana_sign =
    rng:chance(0.5), rng:uniform(0.08, 0.16), (rng:chance(0.5) and 1 or -1)
  local out_h
  if d.scheme == "mono" then out_h = hair_h
  elseif d.scheme == "complement" then out_h = (hair_h + 0.5) % 1
  elseif d.scheme == "triad" then out_h = (hair_h + (triad_flip and 1 or 2) / 3) % 1
  else out_h = (hair_h + ana_amt * ana_sign) % 1 end
  local out_s = rng:uniform(0.35, 0.6)
  local out_v = rng:uniform(0.75, 0.95)
  local outR = palgen.ramp(out_h, out_s, out_v, 4)
  local out2_h = (out_h + rng:uniform(0.4, 0.6)) % 1
  local out2R = palgen.ramp(out2_h, rng:uniform(0.2, 0.45), rng:uniform(0.85, 1.0), 3)
  local accent = paint.hsv((eye_h + rng:uniform(-0.06, 0.06)) % 1, 0.75, 1.0)
  local blushC = paint.hsv(0.98, 0.42, 1.0)
  local dark = palgen.outline(out_h, out_s, out_v)

  -- --- layout ---
  local hw, hh = d.head_w, d.head_h
  local hx0 = (M.W - hw) // 2
  local hx1 = hx0 + hw - 1
  local hy0 = 6
  local hy1 = hy0 + hh - 1 -- chin
  local feet = 27 + d.stature -- shoe bottom row
  local sy0 = hy1 + 1 -- shoulders
  local bw_roll = rng:pick({ 4, 6, 6, 8 })
  local bw = math.max(6, hw - bw_roll)
  if bw % 2 == 1 then bw = bw + 1 end
  local bx0 = (M.W - bw) // 2
  local bx1 = bx0 + bw - 1
  local capy0 = hy0 - 2 -- hair cap top

  local img = paint.image(M.W, M.H)

  -- ---- 1. back layer: back hair, wings, tail ----

  if d.hair == "long" or d.hair == "hime" then
    local backlen = math.min(feet - 3, sy0 + rng:range(5, 9))
    rect(img, hx0, hy0 + 2, hw, backlen - (hy0 + 2) + 1, hairR[2])
    for x = hx0 + 1, hx1 - 1, 3 do vline(img, x, sy0, backlen, hairR[1]) end
    for x = hx0, hx1 do -- ragged hem
      if prng.hash2(seed, x, 77) % 3 == 0 then px(img, x, backlen + 1, hairR[2]) end
    end
  elseif d.hair == "ponytail" then
    local side = rng:chance(0.5) and 1 or -1
    local tx = side > 0 and hx1 + 1 or hx0 - 1
    local tl = rng:range(8, 12)
    for i = 0, tl do
      local sway = (i > tl // 2) and side or 0
      local w = i < 2 and 3 or (i > tl - 3 and 1 or 2)
      local xx = tx + sway
      rect(img, side < 0 and xx - w + 1 or xx - (w - 1) // 2, hy0 + 1 + i, w, 1,
        i % 4 == 3 and hairR[2] or hairR[3])
    end
  end

  if d.back == "butterfly" then
    for _, wy in ipairs({ sy0, sy0 + 3 }) do
      local wing_w = wy == sy0 and 4 or 3
      symrect(img, bx0 - wing_w, wy, wing_w, 3, out2R[3])
      sym(img, bx0 - wing_w + 1, wy + 1, accent)
      sym(img, bx0 - 1, wy - 1, out2R[2])
    end
  elseif d.back == "crystal" then
    local iceR = palgen.ramp(0.52, 0.35, 1.0, 3)
    for i = 0, 2 do
      local cxx, cyy = bx0 - 3 - i, sy0 - 1 + i * 3
      symrect(img, cxx, cyy, 2, 3, iceR[3 - i % 2])
      sym(img, cxx, cyy, paint.hsv(0.5, 0.1, 1.0))
    end
  elseif d.back == "spade_tail" then
    local ty = sy0 + 4
    vline(img, bx1 + 2, ty, ty + 3, dark)
    hline(img, bx1 + 2, bx1 + 4, ty + 4, dark)
    px(img, bx1 + 4, ty + 3, dark)
    px(img, bx1 + 5, ty + 2, dark) -- spade tip
    px(img, bx1 + 4, ty + 2, accent)
  elseif d.back == "fluffy_tail" then
    rect(img, bx1 + 1, sy0 + 4, 4, 5, hairR[3])
    px(img, bx1 + 2, sy0 + 5, hairR[4])
    px(img, bx1 + 4, sy0 + 8, hairR[2])
  end

  -- ---- 2. legs + shoes ----
  local hem_rolls = { dress = sy0 + rng:range(5, 7), hoodie = sy0 + rng:range(5, 7),
    sailor = sy0 + 5 + rng:range(0, 1) }
  -- chibi legs stay stubby: never more than 4 leg rows under the hem
  local hem_y = math.min(hem_rolls[d.outfit] or feet - 2, feet - 2)
  hem_y = math.max(hem_y, feet - 6)
  local leg_x = CX - 3 + rng:range(0, 1) -- inner-left leg column pair
  local stock = rng:pick({ "skin", "skin", "stock", "dark" })
  local legC = stock == "skin" and skinR[3] or (stock == "stock" and out2R[2] or dark)
  if hem_y < feet - 2 then
    symrect(img, leg_x, hem_y + 1, 2, feet - 2 - hem_y, legC)
    if stock == "skin" then symv(img, leg_x, hem_y + 1, feet - 2, skinR[2]) end
  end
  symrect(img, leg_x - 1, feet - 1, 3, 2, outR[2]) -- shoes
  sym(img, leg_x - 1, feet, outR[4]) -- toe shine

  -- ---- 3. torso / outfit ----
  if d.outfit == "dress" then
    rect(img, bx0, sy0, bw, 2, outR[3])
    local skirt_rows = hem_y - (sy0 + 2)
    for r = 0, skirt_rows do -- bell skirt: widen, shade darker toward the hem
      local grow = math.min(r, 3)
      if r == skirt_rows then grow = grow - 1 end -- rounded hem, never a shelf
      local c = r > skirt_rows - 2 and outR[1] or (r > skirt_rows // 2 and outR[2] or outR[3])
      hline(img, bx0 - grow, bx1 + grow, sy0 + 2 + r, c)
      if r < skirt_rows - 1 then -- fold lines on the lit part
        for x = bx0 - grow + 1, bx1 + grow - 1, 3 do px(img, x, sy0 + 2 + r, outR[2]) end
      end
    end
    sym(img, bx0 + 1, sy0, out2R[3]) -- collar
    sym(img, CX - 1, sy0 + 1, accent) -- brooch
  elseif d.outfit == "suit" then
    rect(img, bx0, sy0, bw, hem_y - sy0 + 1, outR[3])
    vline(img, CX, sy0 + 1, hem_y, accent) -- glowing center seam
    symv(img, bx0, sy0, hem_y, outR[2])
    sym(img, bx0, sy0, out2R[3]) -- shoulder pads
    local belt = sy0 + (hem_y - sy0) // 2
    hline(img, bx0, bx1, belt, outR[2])
    sym(img, CX - 1, belt, accent)
  elseif d.outfit == "hoodie" then
    rect(img, bx0 - 1, sy0, bw + 2, hem_y - sy0 + 1, outR[3])
    hline(img, bx0 - 1, bx1 + 1, sy0, out2R[2]) -- hood bunched at the neck
    hline(img, bx0, bx1, hem_y - 1, outR[2]) -- pocket
    sym(img, CX - 2, sy0 + 2, accent) -- drawstring tips (dots, not straps)
  else -- sailor
    rect(img, bx0, sy0, bw, 4, out2R[3]) -- white top (covers the waist)
    for i = 0, 2 do sym(img, bx0 + i, sy0 + i, outR[3]) end -- collar V
    for r = 0, hem_y - (sy0 + 4) do
      local grow = math.min(r, 2)
      hline(img, bx0 - 1 - grow, bx1 + 1 + grow, sy0 + 4 + r, outR[3])
      for x = bx0 - 1, bx1 + 1, 2 do px(img, x, sy0 + 4 + r, outR[2]) end -- pleats
    end
    sym(img, CX - 1, sy0 + 3, accent) -- scarf knot
  end

  -- arms: a short sleeve/skin column just off the body sides + a skin hand.
  -- Only when the silhouette has room (wide bodies read armless-cute anyway).
  if bw <= hw - 6 and d.outfit ~= "hoodie" then
    local arm_len = rng:range(3, 4)
    local sleeve_roll = rng:chance(0.5)
    local sleeved = d.outfit ~= "dress" or sleeve_roll
    symv(img, bx0 - 1, sy0 + 1, sy0 + arm_len - 1, sleeved and outR[2] or skinR[3])
    sym(img, bx0 - 1, sy0 + arm_len, skinR[3])
  else
    rng:range(3, 4); rng:chance(0.5) -- keep the draw count stable
  end

  -- ---- 4. head ----
  rect(img, hx0, hy0, hw, hh, skinR[3])
  -- round the corners
  px(img, hx0, hy0, 0); px(img, hx1, hy0, 0)
  px(img, hx0, hy1, 0); px(img, hx1, hy1, 0)
  px(img, hx0 + 1, hy1, 0); px(img, hx1 - 1, hy1, 0)
  px(img, hx0, hy1 - 1, 0); px(img, hx1, hy1 - 1, 0)
  hline(img, hx0 + 2, hx1 - 2, hy1, skinR[2]) -- chin shade

  -- ---- 5. front hair (face draws OVER it — anime brows-over-fringe) ----
  rect(img, hx0 - 1, capy0 + 1, hw + 2, 3, hairR[3]) -- cap
  hline(img, hx0, hx1, capy0, hairR[3])
  local ncol = hw - 2
  for i = 0, ncol - 1 do -- fringe teeth (lengths 1..3 — the face needs room)
    local fl
    if d.fringe == "straight" then
      fl = 1 + (prng.hash2(seed, i, 5) % 2)
    elseif d.fringe == "m" then
      local c = math.abs(i - (ncol - 1) / 2)
      fl = c < 1.5 and 1 or (c < 3.5 and 2 or 3)
    else -- swept
      fl = 1 + (i * 3) // ncol
    end
    vline(img, hx0 + 1 + i, capy0 + 4, capy0 + 3 + fl, hairR[3])
    px(img, hx0 + 1 + i, capy0 + 3 + fl, hairR[2]) -- fringe tip shade
  end
  hline(img, hx0 + 2, hx0 + hw // 2, capy0, hairR[4]) -- top shine arc
  px(img, hx0 + 1, capy0 + 1, hairR[4])
  -- side locks
  local lock_len = ({ bob = 4, twintail = 3, long = 6, ponytail = 3,
    buns = 3, spiky = 2, hime = 7 })[d.hair]
  symv(img, hx0 - 1, hy0, hy0 + lock_len, hairR[3])
  symv(img, hx0, hy0 + 1, hy0 + math.max(1, lock_len - 2), hairR[2])
  if d.hair == "hime" then -- blunt hime ends
    sym(img, hx0 - 1, hy0 + lock_len + 1, hairR[2])
    sym(img, hx0, hy0 + lock_len + 1, hairR[2])
  end

  if d.hair == "twintail" then
    -- tails HANG from ear height down past the chin, drifting gently outward
    local tl = rng:range(9, 13)
    local max_sway = math.min(2, hx0 - 3)
    for i = 0, tl do
      local sway = math.min(i // 4 + (i > tl - 3 and 1 or 0), max_sway)
      local w = i > tl - 3 and 1 or 2
      local xx = hx0 - 2 - sway
      rect(img, xx, hy0 + 2 + i, w, 1, i % 4 == 2 and hairR[2] or hairR[3])
      rect(img, XMAX - xx - w + 1, hy0 + 2 + i, w, 1, i % 4 == 2 and hairR[2] or hairR[3])
    end
    sym(img, hx0 - 1, hy0 + 2, hairR[4]) -- tie shine
  elseif d.hair == "buns" then
    symrect(img, hx0 + 2, capy0 - 1, 3, 2, hairR[3])
    sym(img, hx0 + 3, capy0 - 1, hairR[4])
    sym(img, hx0 + 2, capy0 - 2, hairR[3])
  elseif d.hair == "spiky" then
    for i = 0, ncol - 1, 2 do
      local sl = 1 + prng.hash2(seed, i, 9) % 2
      vline(img, hx0 + 1 + i, capy0 - sl, capy0 - 1, hairR[3])
    end
  end

  -- ---- 6. face ----
  local ey = hy0 + hh // 2 - 1 -- eye top row
  local esep = 2 -- eye inner edge from center (big close eyes = chibi cute)
  local look = mood.look or 0
  local exL = CX - esep - 2 + look -- left eye left col (2 wide)
  local exR = CX + esep - 1 + look
  local eyestyle = pin(knobs.eye, mood.eye)
  local WHITE = 0xffffffff

  -- every open style: a solid dark lash cap + a 2-row body so the eye reads
  -- as ONE mark at 1x; the white catchlight is the cuteness carrier.
  local function eye(ex, dirn)
    local outer = dirn < 0 and ex or ex + 1 -- outer column of this eye
    local inner = dirn < 0 and ex + 1 or ex
    if eyestyle == "round" then
      px(img, ex, ey, dark); px(img, ex + 1, ey, dark)
      px(img, outer, ey + 1, WHITE); px(img, inner, ey + 1, irisR[1])
      px(img, outer, ey + 2, irisR[2]); px(img, inner, ey + 2, irisR[3])
    elseif eyestyle == "half" then -- lidded smug: lowered lash, heavy iris
      px(img, ex, ey + 1, dark); px(img, ex + 1, ey + 1, dark)
      px(img, outer, ey + 2, WHITE); px(img, inner, ey + 2, irisR[1])
    elseif eyestyle == "sharp" then -- narrow, no catchlight, flicked lash
      px(img, outer + (dirn < 0 and -1 or 1), ey - 1, dark) -- outward flick
      px(img, outer, ey, dark); px(img, inner, ey, dark)
      px(img, outer, ey + 1, irisR[1]); px(img, inner, ey + 1, irisR[2])
    elseif eyestyle == "droopy" then -- lid sags over the outer half
      px(img, ex, ey, dark); px(img, ex + 1, ey, dark)
      px(img, outer, ey + 1, dark); px(img, inner, ey + 1, irisR[2])
      px(img, inner, ey + 2, irisR[3])
    else -- closed: a happy (n) arc
      px(img, outer, ey + 1, dark); px(img, inner, ey, dark)
      px(img, inner + (dirn < 0 and 1 or -1), ey + 1, dark)
    end
  end
  eye(exL, -1)
  eye(exR, 1)

  -- brows (over the fringe — the anime way)
  local brow = mood.brow or 0
  local by = ey - 2
  if eyestyle ~= "closed" or brow < 0 then
    local function brow1(bx, dirn)
      local outer = dirn < 0 and bx or bx + 1
      local inner = dirn < 0 and bx + 1 or bx
      if brow <= -2 then -- fierce V: inner up... no — inner DOWN toward nose
        px(img, outer, by, dark); px(img, inner, by + 1, dark)
      elseif brow < 0 then
        px(img, outer, by + 1, dark); px(img, inner, by + 1, dark)
      elseif brow > 0 then
        px(img, outer, by + 1, dark); px(img, inner, by, dark)
      else
        px(img, outer, by, dark); px(img, inner, by, dark)
      end
    end
    brow1(exL, -1)
    brow1(exR, 1)
  end

  -- mouth
  local my = hy1 - 2
  local mx = CX + look
  local mouth = pin(knobs.mouth, mood.mouth)
  if mouth == "open" then
    rect(img, mx - 1, my - 1, 2, 2, dark)
    px(img, mx - 1, my, paint.hsv(0.99, 0.55, 0.95))
  elseif mouth == "cat" then
    px(img, mx - 2, my - 1, dark); px(img, mx, my - 1, dark)
    px(img, mx - 1, my, dark); px(img, mx + 1, my, dark)
  elseif mouth == "flat" then
    hline(img, mx - 1, mx, my, dark)
  elseif mouth == "small" then
    px(img, mx, my, dark)
  elseif mouth == "frown" then
    hline(img, mx - 1, mx, my, dark)
    px(img, mx - 2, my + 1, dark); px(img, mx + 1, my + 1, dark)
  else -- smile
    hline(img, mx - 1, mx, my, dark)
    px(img, mx - 2, my - 1, dark); px(img, mx + 1, my - 1, dark)
  end

  -- blush
  local blush = pin(knobs.blush, mood.blush or 0)
  if blush > 0 then
    local bly = ey + 3
    sym(img, hx0 + 2, bly, blushC)
    if blush >= 1 then sym(img, hx0 + 3, bly, blushC) end
    if blush >= 2 then sym(img, hx0 + 2, bly + 1, blushC); sym(img, hx0 + 4, bly, blushC) end
  end

  -- ---- 7. head accessory ----
  if d.acc == "cat_ears" then
    local ex = hx0 + 2
    sym(img, ex, capy0 - 1, hairR[3]); sym(img, ex + 1, capy0 - 1, hairR[3])
    sym(img, ex, capy0 - 2, hairR[2])
    sym(img, ex + 1, capy0, paint.hsv(0.97, 0.4, 1)) -- inner ear
  elseif d.acc == "bunny_ears" then
    local ex = hx0 + 3
    symrect(img, ex, capy0 - 4, 2, 5, out2R[3])
    symv(img, ex + 1, capy0 - 3, capy0 - 1, paint.hsv(0.97, 0.35, 1))
    sym(img, ex, capy0 - 4, out2R[2])
  elseif d.acc == "horns" then
    local ex = hx0 + 1
    sym(img, ex, capy0 - 1, dark); sym(img, ex + 1, capy0 - 1, dark)
    sym(img, ex - 1, capy0 - 2, dark)
    sym(img, ex - 1, capy0 - 3, accent) -- lit tip
  elseif d.acc == "halo" then -- a floating ring with a clear gap under it
    local gold, gold2 = paint.hsv(0.13, 0.55, 1), paint.hsv(0.13, 0.35, 1)
    hline(img, CX - 2, CX + 1, capy0 - 4, gold)
    sym(img, CX - 3, capy0 - 3, gold2)
  elseif d.acc == "ribbon" then
    local rx = hx0 + 1
    rect(img, rx, capy0, 2, 2, accent)
    px(img, rx + 2, capy0 + 1, dark)
    rect(img, rx + 3, capy0, 2, 2, accent)
  elseif d.acc == "ahoge" then
    px(img, CX, capy0 - 1, hairR[3])
    px(img, CX + 1, capy0 - 2, hairR[3])
    px(img, CX, capy0 - 3, hairR[3])
  end

  -- ---- 8. sel-out outline ----
  if knobs.outline ~= false then
    M.selout(img)
  end

  return img, d
end

-- sel-out outline: every transparent pixel that borders the sprite becomes a
-- darkened, cooled version of what it borders — the outline "belongs" to each
-- region instead of being one flat color. Two-phase (collect, then apply) so
-- the outline never outlines itself.
local NB = { { 0, 1 }, { 0, -1 }, { -1, 0 }, { 1, 0 } }
function M.selout(img)
  local adds = {}
  for y = 0, img.h - 1 do
    for x = 0, img.w - 1 do
      if paint.get(img, x, y) >> 24 == 0 then
        local nb = 0
        for k = 1, 4 do
          local c = paint.get(img, x + NB[k][1], y + NB[k][2])
          if c >> 24 ~= 0 then nb = c; break end
        end
        if nb ~= 0 then
          local h, s, v = paint.to_hsv(nb)
          adds[#adds + 1] = { x, y,
            paint.hsv(h + (0.72 - h) * 0.3, math.min(1, s * 0.8 + 0.2), math.max(0.10, v * 0.32)) }
        end
      end
    end
  end
  for _, a in ipairs(adds) do paint.set(img, a[1], a[2], a[3]) end
end

return M
