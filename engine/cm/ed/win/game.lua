-- cm.ed.win.game — the live game window (EDITOR.md §7/§12.3): the game
-- internal target drawn straight off the GPU via x_ig_image(-1), aspect-
-- locked to the game's internal size.
--
-- R4: FOCUSED = PLAYING (heuristics-for-intent: content-click focuses, so
-- clicking into the game plays it; clicking anywhere else stops). While
-- playing, the shell's filter_events passes keys through to cm.input and
-- remaps mouse events over the letterboxed image (drawn rect recorded here
-- each frame, ephemeral) into FOV px — the synthesized input rides the
-- normal recorded path, so it is replayable by construction.
--
-- Live round 3 (D054): resizing is ALWAYS aspect-locked, and it drives the
-- game's FOV. Height is fixed at the project's internal height; width runs
-- 4:3 .. 16:9 of it (base 540 → 720..960). A horizontal edge drag walks
-- the width through that range at constant scale, then scales past the
-- ends; vertical/corner drags scale at the current width. CTRL snaps the
-- scale to integers (the window lands on exact multiples of the res). The
-- chosen width lands in win.fw (captured — a rewound frame shows it) and
-- reaches the target via cm.view.canvas_fov → pal.x_fov before the next
-- frame's game draw (render-only, D036 — never sim state).

local M = select(2, ...) or {}

M.kind = "game"
M.menu = "game window"
M.wants_keys = true -- plain-key shell hotkeys suspend while focused (§12.3)
M.game_input = true -- and filter_events feeds the SIM (R8b split: other
                    -- wants_keys kinds claim keys for their tool, not play)

-- window px ↔ game image px: the chrome around the letterboxed image.
-- KEEP IN SYNC with cm.ed's draw_win geometry (content inset 4, HDR 24)
-- plus our own well margin (3): a window sized image + PAD shows the
-- image with zero letterbox — that is what makes pixel-perfect possible.
local INSET, WELL, HDR = 4, 3, 24
M.PAD_W = 2 * (INSET + WELL)        -- 14
M.PAD_H = HDR + INSET + 2 * WELL    -- 34

-- the game's DESIGN res (the project's, not the live target — x_fov moves
-- the latter): height is the fixed axis, width is the boot choice
local function base_res()
  local proj = cm.main and cm.main.proj
  if proj and proj.internal_w and proj.internal_h then
    return proj.internal_w, proj.internal_h
  end
  return pal.gfx_size()
end

-- the supported FOV width range at the fixed internal height: 4:3 .. 16:9
-- (the human's spec, D054 — base 540 → 720..960), widened to include the
-- project's own design width so odd-aspect projects (selftest is 1:1)
-- never get a forced res change
local function res_range(tw, th)
  return math.min(tw, math.ceil(th * 4 / 3)),
         math.max(tw, math.floor(th * 16 / 9))
end

function M.defaults()
  local w, h = pal.gfx_size()
  -- spawn with the image at native 1:1 — pixel-perfect at 100% zoom
  return {}, w + M.PAD_W, h + M.PAD_H
end

function M.title(win)
  return "game"
end

-- header: the restart button (D056) — boot state at the current frame,
-- routed through the recorded EVAL path so recordings replay it (the
-- frame counter keeps running: the restart itself is rewindable).
-- Walled while parked (the past is read-only; resume first).
function M.header(win, ctx)
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local i = cm.require("cm.ui").inp
  local label = "restart"
  local bw = pal.x_ig_text_size(label, px, 1) + px * 0.6
  local x = ctx.hx - bw
  local parked = cm.require("cm.scrub").paused()
  local hov = not parked and ctx.hot and i.wx >= x and i.wx < x + bw
              and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
  pal.x_ig_text(x + px * 0.3, ctx.hy + (ctx.hh - px) * 0.45, px,
                parked and 0x5a5480ff
                or (hov and 0xE8E4FFff or 0xb0a8dcff), label, 1)
  if hov and i.clicked[1] then
    cm.require("cm.repl").submit("cm.main.reset_game()")
  end
  -- audio monitor mutes (editor dev tool): chips left of restart, lit when
  -- that category is silenced. Device-output only — pal.x_snd_mute never
  -- touches the sim bank or the PCM hash, so it is dev/render, never sim.
  local s = cm.require("cm.ed.chips").strip(ctx)
  s.x = x - 4 * z -- lay the chips left of the restart button
  if s:chip("mute sfx", win.mute_sfx) then
    win.mute_sfx = not win.mute_sfx
    ctx.ed.touch()
  end
  if s:chip("mute music", win.mute_music) then
    win.mute_music = not win.mute_music
    ctx.ed.touch()
  end
  if pal.x_snd_mute then pal.x_snd_mute(win.mute_music, win.mute_sfx) end
  return bw + s.used
end

-- push the window's FOV width to the live target: cm.view applies it in
-- canvas mode before the next frame's game draw (pal.x_fov must run
-- before begin_frame). Multiple game windows: the last resized/loaded
-- wins; the others letterbox the shared target.
function M.apply_fov(win)
  local tw, th = base_res()
  if not th or th <= 0 then return end
  local lo, hi = res_range(tw, th)
  local fw = win.fw
  if fw and fw >= lo and fw <= hi then
    cm.require("cm.view").canvas_fov = { w = fw, h = th }
  end
end

-- the resize constraint (threaded through wm.resize by the shell): sees
-- the raw dragged size, returns the aspect-locked one. r0 is the
-- gesture-start rect, so the start scale/width stay the gesture's anchor.
function M.constrain(win, part, r0, ww, wh, ctrl)
  local tw, th = base_res()
  if not th or tw <= 0 or th <= 0 then return end
  local lo, hi = res_range(tw, th)
  local W = math.min(hi, math.max(lo, win.fw or tw)) -- current FOV width
  local s0 = math.max((r0.h - M.PAD_H) / th, 1e-6)   -- gesture-start scale
  local iw, ih = ww - M.PAD_W, wh - M.PAD_H          -- dragged image size
  local s
  if part == "e" or part == "w" then
    -- horizontal: walk the width through the range at constant scale,
    -- then scale past the ends (16:9 out, 4:3 in)
    s = ctrl and math.max(1, math.floor(s0 + 0.5)) or s0
    W = math.floor(math.min(hi, math.max(lo, iw / s)) + 0.5)
    if iw > hi * s then s = iw / hi
    elseif iw < lo * s then s = iw / lo end
  elseif part == "n" or part == "s" then
    s = ih / th -- vertical: pure scale at the current width
  else
    -- corner: scale at the current width, following the axis that moved
    -- more (relative to the gesture-start scale)
    local sw, sh = iw / W, ih / th
    s = math.abs(sw - s0) > math.abs(sh - s0) and sw or sh
  end
  if ctrl then s = math.max(1, math.floor(s + 0.5)) end
  s = math.max(s, 16 / th) -- never collapse
  if win.fw ~= W then
    win.fw = W
    M.apply_fov(win)
  end
  return W * s + M.PAD_W, th * s + M.PAD_H
end

-- pure (KAT'd): the blit scale for a well scale `s` under the machine Aa
-- scale `ds`. Snaps to the intended DESIGN multiple (s/ds) when that is
-- (float noise of) an integer, clamped to the largest integer the well
-- actually fits — so the game blit is a crisp, Aa-invariant multiple.
-- Returns (scale, exact); a non-integer intent passes through unsnapped.
function M.blit_scale(s, ds)
  local sn = s / (ds or 1)
  local r = math.floor(sn + 0.5)
  if r < 1 or math.abs(sn - r) >= 0.002 then return s, false end
  return math.max(1, math.min(r, math.floor(s + 0.01))), true
end

function M.draw(win, ctx)
  -- while time-travelling, the RECORDED target size is the authority
  -- (D123's FSIZ): a replay of a session whose FOV was resized live must
  -- re-aim the target to the recorded size, or the window letterboxes
  -- the boot FOV under a sim that thinks it is wider (the human's
  -- black-bars report). Chrome-side follow of applied sim input — the
  -- non-latching read, so watching a 2D replay never arms the domain.
  if cm.require("cm.scrub").paused() then
    local sw, sh = cm.require("cm.input").fsiz_applied()
    if sw then
      local gw2, gh2 = pal.gfx_size()
      if sw ~= gw2 or sh ~= gh2 then
        cm.require("cm.view").canvas_fov = { w = sw, h = sh }
      end
    end
  end
  -- letterbox the target into a rounded filler well, preserving aspect —
  -- the image sits inside a margin so it never touches the panel's
  -- rounded border (human feedback, live round 2)
  local tw, th = pal.gfx_size()
  if tw <= 0 or th <= 0 then return end
  pal.x_ig_rect_fill(ctx.cx, ctx.cy, ctx.cw, ctx.ch, 0x0c0a14ff, 4 * ctx.z)
  local m = WELL * ctx.z
  local aw, ah = ctx.cw - 2 * m, ctx.ch - 2 * m
  if aw <= 0 or ah <= 0 then return end
  local s = math.min(aw / tw, ah / th)
  -- pixel-perfect (D054): when the scale lands on (float noise of) an
  -- integer — 100% canvas zoom, window a multiple of the res — snap the
  -- scale and the origin to exact px so the game reads 1:1 crisp.
  -- The machine-local Aa scale (cam.display_scale) is CHROME sizing, not
  -- game zoom: divide it out before the integer test, so a CTRL-snapped
  -- window stays a crisp, constant-size integer blit at any text size
  -- (the well grows with the chrome; the image does not follow it). If
  -- the intended multiple no longer fits a shrunken well (Aa below 1),
  -- fall back to the largest integer that does.
  local exact
  s, exact = M.blit_scale(s, cm.require("cm.ed.cam").display_scale)
  local dw, dh = tw * s, th * s
  local ix = ctx.cx + m + (aw - dw) * 0.5
  local iy = ctx.cy + m + (ah - dh) * 0.5
  if exact then
    ix, iy = math.floor(ix + 0.5), math.floor(iy + 0.5)
  end
  pal.x_ig_image(-1, ix, iy, dw, dh)
  -- the image rect in window px (ephemeral): filter_events remaps mouse
  -- events through it next tick (1-frame latency, same class as ig capture)
  local ed = ctx.ed
  ed.g.grect = ed.g.grect or {}
  ed.g.grect[win.id] = { x = ix, y = iy, s = s, w = dw, h = dh }
  -- playing state, unmissable: accent chip in the top-right of the well
  if ctx.focused then
    local px = math.max(4, 10 * ctx.z)
    local label = "PLAYING"
    local lw = pal.x_ig_text_size(label, px, 0)
    pal.x_ig_rect_fill(ctx.cx + ctx.cw - lw - 14 * ctx.z, ctx.cy + 4 * ctx.z,
                       lw + 10 * ctx.z, px * 1.5, 0x7fd8a8cc, 4 * ctx.z)
    pal.x_ig_text(ctx.cx + ctx.cw - lw - 9 * ctx.z, ctx.cy + 4 * ctx.z + px * 0.22,
                  px, 0x10241aff, label, 0)
  end
end

return M
