-- cm.hud — the runtime-UI slice of A5 (D096). Anchored HUD text and
-- device-flavored binding labels: the two blocks every bundled demo and
-- starter template hand-rolls. The votes: the demo's centered-title
-- measure dance ((W - measure) // 2), the arcade starter's hand-tuned
-- W/2 - 70 game-over line (brittle the moment the string changes), six
-- sites of margin arithmetic against pal.gfx_size(), and four copies of
-- the `local k = input.pad_connected(1) and "pad" or "key"` label dance
-- (cellar, swarm, arcade, top-down). §2's "runtime UI recipes/components
-- for HUDs" line.
--
-- Render-only: nothing here touches doc or module state; determinism is
-- untouched by construction (draw code may call freely). Integer math
-- only — centering uses floor division exactly like the demo did, so a
-- retrofit is pixel-identical.
--
--   local hud = cm.require("cm.hud")
--   -- in draw: nine anchors, insets push INWARD from the named edge
--   hud.text("t", 0, 3, title, { r = 1, g = 0.92, b = 0.7, a = 0.97 })
--   hud.text("tl", 4, 3, ("coins %d"):format(n), { r = 1, g = 0.9, b = 0.4 })
--   hud.text("b", 0, 2, "walk into a door", { a = 0.95 })
--   -- the live binding, flavored for the device in hand (pad 1 else keys)
--   hud.text("bl", 12, 8, hud.label("act") .. " unlocks the door")
--
-- Semantics, pinned by KATs:
--   * Anchors: "tl" "t" "tr" / "l" "c" "r" / "bl" "b" "br" — the block's
--     corresponding point lands on that screen point. dx/dy are insets
--     pushing inward from the named edges ("br": dx from the right edge,
--     dy from the bottom); on a centered axis they are plain signed
--     shifts. Centering floors: x = (w - tw) // 2 + dx.
--   * text(anchor, dx, dy, str, opts) draws through cm.text (same opts:
--     font/r/g/b/a), multi-line aware: the block is placed by its
--     measured bounds and each line aligns to the anchor's horizontal
--     side (left/center/right). Returns the block's resolved top-left
--     x, y (badges and underlines draw relative to it).
--   * place(anchor, dx, dy, tw, th, w, h) -> x, y is the pure anchor
--     math over an explicit box — text() is place() over gfx_size and
--     cm.text.measure. Unknown anchors and non-number insets are
--     refused loudly.
--   * label(action) -> input.label(action, "pad") while pad 1 is
--     connected, else input.label(action, "key") — the exact dance the
--     demos agreed on. Rebinds show live (D084's contract); reading pad
--     connectivity in draw is the swarm idiom and touches no sim state.
--
-- Deliberately NOT here (absorb the demonstrated pain, no more): panels/
-- legibility bars (one vote — the demo keeps its quads), menus, focus/
-- navigation, dialogue, pause screens (zero hand-rolled votes; Esc is
-- the engine's menu). Later packets earn those from real demo pain.

local M = select(2, ...) or {}
local text = cm.require("cm.text")
local input = cm.require("cm.input")

local ANCHOR = {
  tl = { "l", "t" }, t = { "c", "t" }, tr = { "r", "t" },
  l  = { "l", "m" }, c = { "c", "m" }, r  = { "r", "m" },
  bl = { "l", "b" }, b = { "c", "b" }, br = { "r", "b" },
}

local function axis(side, inset, size, extent)
  if side == "l" or side == "t" then return inset end
  if side == "c" or side == "m" then return (extent - size) // 2 + inset end
  return extent - inset - size
end

-- place(anchor, dx, dy, tw, th, w, h) -> x, y: the pure anchor math.
-- tw/th = the block being placed, w/h = the box it anchors inside.
function M.place(anchor, dx, dy, tw, th, w, h)
  local a = ANCHOR[anchor]
  if not a then
    error("hud.place: unknown anchor " .. tostring(anchor)
          .. ' (want "tl" "t" "tr" "l" "c" "r" "bl" "b" "br")', 2)
  end
  if type(dx) ~= "number" or type(dy) ~= "number" then
    error("hud.place: dx and dy must be numbers", 2)
  end
  return axis(a[1], dx, tw, w), axis(a[2], dy, th, h)
end

-- text(anchor, dx, dy, str, opts) -> x, y (the block's resolved
-- top-left). opts flow through to cm.text.draw (font, r/g/b/a).
function M.text(anchor, dx, dy, str, opts)
  if type(str) ~= "string" then
    error("hud.text: str must be a string", 2)
  end
  opts = opts or {}
  local fontname = opts.font
  local w, h = pal.gfx_size()
  local tw, th = text.measure(str, fontname)
  local x, y = M.place(anchor, dx, dy, tw, th, w, h)
  local side = ANCHOR[anchor][1]
  if side == "l" or not str:find("\n", 1, true) then
    text.draw(x, y, str, opts) -- one call; cm.text left-aligns \n itself
  else
    local _, gh = text.measure("", fontname)
    local ly = y
    for line in (str .. "\n"):gmatch("(.-)\n") do
      local lw = text.measure(line, fontname)
      local lx = x
      if side == "c" then lx = x + (tw - lw) // 2
      elseif side == "r" then lx = x + tw - lw end
      text.draw(lx, ly, line, opts)
      ly = ly + gh
    end
  end
  return x, y
end

-- label(action) -> the live binding label flavored for the device in
-- hand: pad names while pad 1 is connected, else key names.
function M.label(action)
  local kind = input.pad_connected(1) and "pad" or "key"
  return input.label(action, kind)
end

return M
