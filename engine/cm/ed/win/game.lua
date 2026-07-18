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

function M.design_res() -- the shell's door to the project design res
  return base_res()
end

-- pure (KAT'd): the live target FOV width picked from the doc's game
-- windows — the every-frame authority the shell asserts (D125: the FOV is
-- DERIVED, never a latch; D124's park re-aim latched the recorded size and
-- nothing restored the live one, so unpark letterboxed until a manual
-- resize). The explicit owner (last resized, cm.ed.g.fov_owner) wins, else
-- the last sized window in doc order (the D054 multi-window rule), else the
-- design width when any game window exists; nil when none does (nothing
-- shows the target — leave it alone).
function M.pick_fov(wins, owner_id, tw, th)
  local lo, hi = res_range(tw, th)
  local pick, any
  for _, w in ipairs(wins or {}) do
    if w.kind == "game" then
      any = true
      if w.fw and w.fw >= lo and w.fw <= hi then
        if owner_id and w.id == owner_id then return w.fw end
        pick = w.fw
      end
    end
  end
  if pick then return pick end
  if any then return tw end
  return nil
end

-- pure (KAT'd): reconcile a game window's doc rect from the Aa scale it
-- was laid out at (aa0) to the current one (ds). The image area scales by
-- aa0/ds so the SCREEN footprint stays constant (the pads keep their
-- chrome-scaled world size); a rect that encodes a crisp integer design
-- multiple is recomputed exactly as fw*k/ds so repeated flips never
-- accumulate float drift. Returns (w2, h2) ONLY — the top-left corner is
-- deliberately untouched (D125 follow-up 3, the human's call): every
-- other window's x,y is Aa-invariant, so the game window's must be too —
-- it resizes in place from its corner instead of being the one window
-- that shifts. This replaces D123's process-global edge detector: the
-- per-window stamp (win.aa) also heals a session opened at a DIFFERENT
-- Aa than it was saved at (boot / cross-machine), which the live-only
-- detector silently missed.
function M.aa_rect(w, h, aa0, ds, th)
  local iw, ih = w - M.PAD_W, h - M.PAD_H
  local w2, h2
  local k = th > 0 and ih * aa0 / th or 0 -- intended design multiple
  local r = math.floor(k + 0.5)
  if iw > 0 and ih > 0 and r >= 1 and math.abs(k - r) < 0.002 then
    local fwr = iw / ih * th -- the FOV width the rect encodes
    local fr = math.floor(fwr + 0.5)
    if math.abs(fwr - fr) < 0.01 then fwr = fr end
    w2, h2 = fwr * r / ds, th * r / ds
  else
    local f = aa0 / ds
    w2, h2 = iw * f, ih * f
  end
  return w2 + M.PAD_W, h2 + M.PAD_H
end

-- pure (KAT'd): the CTRL-resize snap — land the window on an exact
-- SCREEN design multiple. The doc rect lives in world units, which the
-- Aa scale multiplies on screen, so the integer to hit is s*ds, not s:
-- at Aa 1.25 a world-integer multiple reads 2.5x on screen and the blit
-- never snaps crisp (the human's report, D125 follow-up 2). Returns the
-- world-unit scale whose screen multiple (at 100% canvas zoom) is a
-- whole number >= 1 — the same k/ds shape the win.aa reconcile
-- recomputes exactly, so a CTRL-snapped window stays crisp across Aa
-- flips.
function M.snap_mult(s, ds)
  ds = ds or 1
  return math.max(1, math.floor(s * ds + 0.5)) / ds
end

-- the resize constraint (threaded through wm.resize by the shell): sees
-- the raw dragged size, returns the aspect-locked one. r0 is the
-- gesture-start rect, so the start scale/width stay the gesture's anchor.
function M.constrain(win, part, r0, ww, wh, ctrl)
  local tw, th = base_res()
  if not th or tw <= 0 or th <= 0 then return end
  local lo, hi = res_range(tw, th)
  local ds = cm.require("cm.view").cfg.editor_scale or 1
  local W = math.min(hi, math.max(lo, win.fw or tw)) -- current FOV width
  local s0 = math.max((r0.h - M.PAD_H) / th, 1e-6)   -- gesture-start scale
  local iw, ih = ww - M.PAD_W, wh - M.PAD_H          -- dragged image size
  local s
  if part == "e" or part == "w" then
    -- horizontal: walk the width through the range at constant scale,
    -- then scale past the ends (16:9 out, 4:3 in)
    s = ctrl and M.snap_mult(s0, ds) or s0
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
  if ctrl then s = M.snap_mult(s, ds) end
  s = math.max(s, 16 / th) -- never collapse
  if win.fw ~= W then
    win.fw = W
    M.apply_fov(win) -- same-frame during the drag; the shell's per-frame
    -- pick_fov assert (D125) carries it from the next frame on
  end
  cm.require("cm.ed").g.fov_owner = win.id -- last resized wins (D054)
  return W * s + M.PAD_W, th * s + M.PAD_H
end

-- pure (KAT'd): the blit scale for a well scale `s`. The Aa compensation
-- lives entirely in the RECT now (the win.aa reconcile, D123/D125), so a
-- game window's well scale is already Aa-invariant — design multiple ×
-- canvas zoom — and the snap tests s ITSELF: a near-integer well scale
-- snaps to the exact integer (and, in draw, to a whole-px origin) so the
-- game reads 1:1 crisp. Returns (scale, exact).
-- History: D122 divided the machine Aa scale out here because the rect
-- was NOT yet compensated (the well grew with Aa). After D123 moved the
-- compensation into the rect, keeping BOTH made the snap fire at
-- s/ds-integer points where s was NOT integer — collapsing the image to
-- r < s (a 2x blit in a 3.0x well at Aa 1.5, zoom 1.5), so a zoom sweep
-- flickered between filling and letterboxing at every crossing (the
-- human's report, D125 follow-up).
function M.blit_scale(s)
  local r = math.floor(s + 0.5)
  if r < 1 or math.abs(s - r) >= 0.002 then return s, false end
  return r, true
end

function M.draw(win, ctx)
  -- the target FOV (live: the owning window's fw; time-travelling: the
  -- recorded FSIZ) is asserted by the SHELL every frame — cm.ed.frame's
  -- resolve, D125 — not pushed from here: a draw-side push only runs for
  -- visible windows and D124's paused-only re-aim proved the latch class
  -- stale (unpark letterboxed until a manual resize).
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
  -- scale and the origin to exact px so the game reads 1:1 crisp. The
  -- machine Aa scale never appears here: the win.aa rect reconcile
  -- (D123/D125) already divides it out of the well, so s is the design
  -- multiple × canvas zoom on every machine.
  local exact
  s, exact = M.blit_scale(s)
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
