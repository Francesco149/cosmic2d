-- genart — a ONE-SHOT art bootstrap for the sandbox (M10 Phase 4 / D040). It
-- authors the placeholder mecha-girl sprite as a real studio document and bakes
-- the build product the game loads, demonstrating the asset pipeline end to end:
--
--     genart.girl()  →  art/girl.spr   (editable source — open it in F2 studio)
--                       art/girl.png   (the baked 12-frame strip the game draws)
--                       art/girl.anim  (the clip table cm.anim plays)
--
-- This replaces player.lua's procedural build_sprite() as the SOURCE of the
-- sprite — but build_sprite stays as the fallback when the asset is missing.
-- Run once (the .spr is the truth thereafter; the human edits it in the studio):
--     bin/cosmic projects/sandbox --headless --frames 1 \
--       --eval "cm.require('genart').girl()"
--
-- It is NOT required by the game — only by that eval — so it sits inert. The art
-- is a faithful port of build_sprite's 12-pose set (the 11 moveset poses + a
-- breathing variant of idle for the timed idle clip). Dev/render class: no sim.

local paint = cm.require("cm.paint")
local sprite = cm.require("cm.sprite")

local M = {}

local P = paint.pack
-- the build_sprite palette, as raw RGBA bytes (the floats × 255)
local HAIR, SKIN, SUIT, SHAD, CYAN, DARK =
  P(77, 66, 107), P(247, 219, 189), P(237, 240, 250),
  P(168, 179, 214), P(107, 219, 250), P(38, 36, 51)

local function R(c, x, y, w, h, col) paint.rect(c, x, y, w, h, col, true) end
local function PX(c, x, y, col) paint.set(c, x, y, col) end

local function head(c, hx, hy, eye)
  R(c, hx, hy, 6, 3, HAIR)
  PX(c, hx - 1, hy + 1, HAIR); PX(c, hx + 6, hy + 1, HAIR)
  R(c, hx, hy + 3, 6, 4, SKIN)
  PX(c, hx + 2 + (eye or 0), hy + 4, DARK)
  PX(c, hx + 4 + (eye or 0), hy + 4, DARK)
  R(c, hx, hy + 7, 6, 1, HAIR) -- fringe shadow
end

local function torso(c, tx, ty, tw, th)
  R(c, tx, ty, tw, th, SUIT)
  R(c, tx, ty + th - 1, tw, 1, SHAD)
  R(c, tx + tw // 2, ty + 1, 1, th - 1, CYAN) -- cyan seam
end

-- the 12 poses (0..10 are the moveset frames player.draw selects by state; 11 is
-- a breathing variant of idle the timed "idle" clip cycles with frame 0).
local FRAMES = {
  function(c) -- 0 idle
    head(c, 5, 2, 0); torso(c, 4, 10, 8, 6)
    R(c, 3, 10, 1, 4, SUIT); R(c, 12, 10, 1, 4, SUIT)
    R(c, 5, 16, 2, 5, SHAD); R(c, 9, 16, 2, 5, SHAD)
    PX(c, 5, 21, CYAN); PX(c, 10, 21, CYAN)
  end,
  function(c) -- 1 walk a
    head(c, 5, 2, 1); torso(c, 4, 10, 8, 6)
    R(c, 2, 11, 2, 3, SUIT); R(c, 12, 11, 2, 2, SUIT)
    R(c, 4, 16, 2, 5, SHAD); R(c, 10, 16, 2, 4, SHAD)
  end,
  function(c) -- 2 walk b
    head(c, 5, 2, 1); torso(c, 4, 10, 8, 6)
    R(c, 3, 11, 2, 2, SUIT); R(c, 12, 11, 2, 3, SUIT)
    R(c, 6, 16, 2, 4, SHAD); R(c, 9, 16, 2, 5, SHAD)
  end,
  function(c) -- 3 rise
    head(c, 5, 3, 0); torso(c, 4, 11, 8, 6)
    R(c, 3, 8, 2, 3, SUIT); R(c, 11, 8, 2, 3, SUIT)
    R(c, 5, 17, 2, 3, SHAD); R(c, 9, 17, 2, 3, SHAD)
  end,
  function(c) -- 4 fall
    head(c, 5, 3, 0); torso(c, 4, 11, 8, 6)
    R(c, 1, 11, 3, 2, SUIT); R(c, 12, 11, 3, 2, SUIT)
    R(c, 5, 17, 2, 5, SHAD); R(c, 9, 17, 2, 5, SHAD)
  end,
  function(c) -- 5 dash / flash jump
    head(c, 7, 3, 1); R(c, 3, 11, 9, 5, SUIT); R(c, 5, 15, 7, 1, SHAD)
    R(c, 6, 11, 1, 4, CYAN); R(c, 1, 12, 3, 2, SUIT)
    R(c, 2, 16, 4, 2, SHAD); R(c, 5, 18, 3, 2, SHAD)
  end,
  function(c) -- 6 up jump
    head(c, 5, 4, 0); torso(c, 4, 12, 8, 7)
    R(c, 4, 7, 2, 5, SUIT); R(c, 10, 7, 2, 5, SUIT)
    PX(c, 4, 7, CYAN); PX(c, 11, 7, CYAN)
    R(c, 6, 19, 2, 4, SHAD); R(c, 8, 19, 2, 4, SHAD)
  end,
  function(c) -- 7 hop
    head(c, 5, 5, 0); torso(c, 4, 12, 8, 5)
    R(c, 2, 13, 2, 2, SUIT); R(c, 12, 13, 2, 2, SUIT)
    R(c, 4, 17, 3, 3, SHAD); R(c, 9, 17, 3, 3, SHAD)
  end,
  function(c) -- 8 hover / flutter
    head(c, 5, 3, 0); torso(c, 4, 10, 8, 6)
    R(c, 0, 10, 4, 2, SUIT); R(c, 12, 10, 4, 2, SUIT)
    PX(c, 0, 10, CYAN); PX(c, 15, 10, CYAN)
    R(c, 5, 16, 2, 4, SHAD); R(c, 9, 16, 2, 4, SHAD)
    PX(c, 5, 20, CYAN); PX(c, 10, 20, CYAN)
  end,
  function(c) -- 9 grapple
    head(c, 5, 5, 0); torso(c, 4, 12, 8, 6)
    R(c, 9, 4, 2, 9, SUIT); PX(c, 9, 4, CYAN); PX(c, 10, 4, CYAN)
    R(c, 4, 13, 2, 3, SUIT)
    R(c, 5, 18, 2, 4, SHAD); R(c, 9, 18, 2, 4, SHAD)
  end,
  function(c) -- 10 attack
    head(c, 4, 3, 1); torso(c, 3, 11, 8, 6)
    R(c, 10, 12, 5, 2, SUIT); PX(c, 14, 12, CYAN); PX(c, 14, 13, CYAN)
    R(c, 4, 17, 2, 5, SHAD); R(c, 8, 17, 2, 5, SHAD)
  end,
  function(c) -- 11 idle breath (idle, upper body settled 1px — a gentle rise)
    head(c, 5, 3, 0); torso(c, 4, 11, 8, 5)
    R(c, 3, 11, 1, 4, SUIT); R(c, 12, 11, 1, 4, SUIT)
    R(c, 5, 16, 2, 5, SHAD); R(c, 9, 16, 2, 5, SHAD)
    PX(c, 5, 21, CYAN); PX(c, 10, 21, CYAN)
  end,
}

-- build the document, draw the poses, attach the clips, and save+bake.
function M.girl(proj)
  proj = proj or (cm.main and cm.main.args and cm.main.args.project) or "projects/sandbox"
  local doc = sprite.new(16, 24, { name = "girl" })
  doc.frames = #FRAMES
  local cells = doc.layers[1].cells
  for f = 2, doc.frames do cells[f] = paint.image(16, 24) end
  for f, draw in ipairs(FRAMES) do draw(cells[f]) end

  -- clips: a timed idle BREATH (the one the player consumes via cm.anim) + a
  -- walk cycle the studio/player can use later. Frame indices are 0-based.
  doc.clips = {
    { name = "idle", loop = "loop",
      frames = { { frame = 0, dur = 50 }, { frame = 11, dur = 50 } } },
    { name = "walk", loop = "loop",
      frames = { { frame = 1, dur = 8 }, { frame = 2, dur = 8 } } },
  }

  pal.mkdir(proj .. "/art")
  local ok, err = sprite.save(doc, proj .. "/art/girl.spr")
  pal.log(("[genart] girl.spr/.png/.anim → %s/art : %s%s")
    :format(proj, tostring(ok), err and (" " .. err) or ""))
  return doc
end

return M
