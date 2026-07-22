-- cm.ed.win.palette — the color palette designer (.pal). A windowkit
-- asset citizen (journal / dirty / ctrl+Z/S / unsaved-persists / rewind).
--
-- The WORKING COLOR model (the human's ramp-appending report): the color
-- being mixed is a separate scratch, NOT a live edit of a saved swatch —
-- so appending ramps back to back never mutates the previous ramp's tail,
-- and generating a ramp never needs the base added (and duplicated)
-- first. Saved swatches load INTO the working color only on double-click
-- or enter; `+add` / `set` move it the other way. Pickers: a 2D SV
-- square + hue bar (pick by eye), HSV sliders, RGB sliders, hex entry.
-- The RAMP generator (from the working color) bakes the pixel-art
-- principles: value spread, warm-highlight/cool-shadow hue shift,
-- saturation bell. Copy/paste the whole palette as Lospec hex.
--
-- Integration: swatches sit on the canvas, so the sprite ed's global
-- eyedropper samples them straight off the screen — that IS "pick from
-- the canvas color picker". Games reference a palette via cm.palette.load.

local M = select(2, ...) or {}
local palette = cm.require("cm.palette")
local paint = cm.require("cm.paint")

M.kind = "palette"
M.help = "win-palette"
M.menu = "palette"
M.exts = { "pal" }
M.DEF_W, M.DEF_H = 380, 500
M.JCAP = 256

local COL = {
  rail = 0x1a1728ff, well = 0x141220ff, btn = 0x262238ff,
  btn_on = 0x4a4370ff, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  hot = 0xE8E4FFff, accent = 0x7fd8a8ff, slider = 0x4a4370ff,
  sel = 0xE8E4FFff, warn = 0xf07a7aff,
}

function M.defaults()
  -- wcol = the packed working color (persists with the layout);
  -- pick = the active picker mode ("sv" | "hsv" | "rgb")
  return { path = "", sel = 1, rampn = 5, ramph = 14,
           wcol = 0xffffffff, pick = "sv" }
end

function M.title(win)
  return win.path:match("([^/]+)$") or "palette"
end

function M.accepts(win, path)
  return path:lower():find("%.pal$") ~= nil
end

function M.rebind(win, ed, path)
  win.path = path
  ed.touch()
end

-- ---- asset citizen ----

local function decode_into(p, bytes)
  local ok, doc = pcall(palette.decode, bytes)
  if ok then p.doc, p.err = doc, nil
  else p.doc, p.err = nil, tostring(doc) end
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "pw", field = "pal", jcap = M.JCAP,
  fresh = function(ed, path)
    local name = path:match("([^/]+)%.pal$") or "palette"
    return palette.encode(palette.fresh(name))
  end,
  adopt = decode_into,
  encode = palette.encode,
  write = function(ed, path, a, p)
    -- `_save_fail` exists only as the focused durability-test seam. Keeping
    -- it on ephemeral plumbing means it can never enter session state.
    return palette.save(p.doc, ed.root .. "/" .. path, p._save_fail)
  end,
}
local open_asset, commit = A.open_asset, A.commit
M.open_win = A.open_win
M.seed = A.seed -- the stock window's open-a-copy door (D147)
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- ---- widgets ----

-- colors are in cm.paint's packing (R low byte); the drawlist wants
-- 0xRRGGBBAA (the sprite window's disp, verbatim). The original ARGB
-- shift here rendered every swatch channel-rotated — pure red drew
-- INVISIBLE (alpha 0), pure blue drew red; pixel-probed in the rework.
local function disp(c)
  local r, g, b, a = paint.unpack(c)
  return (r << 24) | (g << 16) | (b << 8) | a
end

local function button(ctx, x, y, w, h, label, on)
  local i = cm.require("cm.ui").inp
  local z, px = ctx.z, math.max(4, 9 * ctx.z)
  local hov = ctx.hot and i.wx >= x and i.wx < x + w and i.wy >= y and i.wy < y + h
  pal.x_ig_rect_fill(x, y, w, h, on and COL.btn_on or COL.btn, 3 * z)
  pal.x_ig_text(x + (w - pal.x_ig_text_size(label, px, 0)) * 0.5,
                y + (h - px) * 0.45, px, (hov or on) and COL.hot or COL.dim, label, 0)
  return hov and i.clicked[1]
end

-- per-window UI scratch (drag / selection cache), keyed by win.id INSIDE
-- the path-keyed plumbing — so two windows on the same .pal don't share
-- drag or selection state (the human's multi-window bug: shared p.drag
-- made a drag in one window move sliders in the other). Generalized into
-- the kit (R9g) so map/synth/music can adopt the same pattern.
local function winui(p, win)
  return cm.require("cm.ed.kit").winui(p, win)
end

-- working-color sync: the HSV scratch (u.wh/ws/wv) is the master while
-- mixing (deriving HSV from the packed color each frame loses hue on
-- grays / mid-drag); win.wcol is the packed mirror that persists with
-- the layout. Adopting a swatch keeps its EXACT bytes (alpha included)
-- and re-derives the scratch.
local function seed_working(u, win)
  if u.winit then return end
  u.winit = true
  win.wcol = win.wcol or 0xffffffff
  u.wh, u.ws, u.wv = paint.to_hsv(win.wcol)
end

local function adopt_working(u, win, c)
  win.wcol = c
  u.wh, u.ws, u.wv = paint.to_hsv(c)
  u.hexbuf = nil
end

-- per-window hotkeys (EDITOR.md §13): no-modifier swatch ops; the hint strip
-- renders them under the focused window. Each op runs on the working doc.
local function bound(win) return win.path ~= "" end
local function palop(fn)
  return function(win, ed)
    local _, p = open_asset(ed, win.path)
    if not p or not p.doc then return end
    if fn(win, p.doc, winui(p, win)) then commit(ed, win.path) end
    ed.touch()
  end
end
M.hotkeys = {
  { key = "left", hint = "prev", when = bound, rep = true, fn = palop(
    function(win, doc, u) win.sel = math.max(1, (win.sel or 1) - 1) end) },
  { key = "right", hint = "next", when = bound, rep = true, fn = palop(
    function(win, doc, u) win.sel = math.min(#doc.colors, (win.sel or 1) + 1)
      end) },
  { key = "enter", hint = "pick", when = bound, fn = palop(
    function(win, doc, u)
      seed_working(u, win)
      adopt_working(u, win, doc.colors[win.sel or 1] or 0xffffffff) end) },
  { key = "a", hint = "add", when = bound, fn = palop(
    function(win, doc, u)
      if #doc.colors >= palette.MAX then return end
      seed_working(u, win)
      table.insert(doc.colors, (win.sel or 1) + 1, win.wcol or 0xffffffff)
      win.sel = (win.sel or 1) + 1; return true end) },
  { key = "d", hint = "dup", when = bound, fn = palop(
    function(win, doc, u)
      if #doc.colors >= palette.MAX then return end
      local s = win.sel or 1
      table.insert(doc.colors, s + 1, doc.colors[s])
      win.sel = s + 1; return true end) },
  { key = "del", hint = "del", when = bound, fn = palop(
    function(win, doc, u) if #doc.colors > 1 then
        table.remove(doc.colors, win.sel or 1)
        win.sel = math.max(1, (win.sel or 1) - 1); return true
      end end) },
}

-- horizontal drag slider; `st` holds the per-window drag state (st.drag).
-- Returns new value while dragging, done on release.
local function slider(st, ctx, id, x, y, w, h, val, lo, hi, label, format)
  local i = cm.require("cm.ui").inp
  local z, px = ctx.z, math.max(4, 8.5 * ctx.z)
  local shown = format and format(val) or tostring(val)
  pal.x_ig_text(x, y + (h - px) * 0.5, px, COL.dim, label, 0)
  local vw = pal.x_ig_text_size(shown, px, 1)
  pal.x_ig_text(x + w - vw, y + (h - px) * 0.5, px, COL.text, shown, 1)
  -- Every slider says the value it will commit. The old position-only
  -- display made exact tutorial steps (notably a signed ramp hue) impossible
  -- to follow without reverse-engineering pixels. Keep a fixed-width value
  -- bay so the track never moves underneath a drag as "9" becomes "10".
  local lw = pal.x_ig_text_size(label, px, 0)
  local bx = x + lw + 6 * z
  local bw = math.max(12 * z, x + w - 40 * z - bx)
  local by, bh = y + h * 0.5 - 3 * z, 6 * z
  pal.x_ig_rect_fill(bx, by, bw, bh, COL.well, 2 * z)
  -- clamp the drawn fraction: a value legally past the slider's span (the
  -- typed shades count vs the drag range) must not draw off the scale
  local f = (val - lo) / (hi - lo)
  f = f < 0 and 0 or (f > 1 and 1 or f)
  pal.x_ig_rect_fill(bx, by, bw * f, bh, COL.slider, 2 * z)
  pal.x_ig_rect_fill(bx + bw * f - 2 * z, y + 1 * z, 4 * z, h - 2 * z, COL.hot, 1 * z)
  local over = ctx.hot and i.wx >= bx - 4 * z and i.wx < bx + bw + 4 * z
               and i.wy >= y and i.wy < y + h
  if over and i.clicked[1] and not st.drag then st.drag = id end
  if st.drag == id then
    local nf = math.max(0, math.min(1, (i.wx - bx) / bw))
    local nv = math.floor(lo + nf * (hi - lo) + 0.5)
    if not i.buttons[1] then st.drag = nil; return nv, true end
    return nv, false
  end
  return nil, false
end

-- the 2D SV picker: a saturation(x) × value(y) field at the working hue,
-- baked to a small texture only when the hue bucket moves (the sprite
-- window's tex_create/tex_update pipeline) and drawn scaled. Picking
-- precision is the drag math, not the texture grid. Returns s, v while
-- dragging (nil otherwise), done on release.
local SVW, SVH = 96, 64
local function sv_square(u, ctx, x, y, w, h)
  local i = cm.require("cm.ui").inp
  local z = ctx.z
  local hue = math.floor((u.wh or 0) * 360 + 0.5) % 360
  if not u.svtex or u.svhue ~= hue then
    u.svimg = u.svimg or paint.image(SVW, SVH)
    for py = 0, SVH - 1 do
      local v = 1 - py / (SVH - 1)
      for sx = 0, SVW - 1 do
        u.svimg.buf:u32((py * SVW + sx) * 4,
                        paint.hsv(hue / 360, sx / (SVW - 1), v, 255))
      end
    end
    if not (u.svtex and pal.tex_update(u.svtex, u.svimg.buf, SVW, SVH)) then
      if u.svtex then pal.tex_free(u.svtex) end
      u.svtex = pal.tex_create(SVW, SVH, u.svimg.buf:str(0, SVW * SVH * 4))
    end
    u.svhue = hue
  end
  pal.x_ig_image(u.svtex, x, y, w, h)
  pal.x_ig_rect(x, y, w, h, 0x6a5a8cff, 1, 0)
  -- crosshair at (s, 1-v); flips dark over bright ground
  local mx = x + (u.ws or 0) * w
  local my = y + (1 - (u.wv or 0)) * h
  pal.x_ig_circle(mx, my, 4 * z,
                  (u.wv or 0) > 0.6 and 0x000000ff or 0xffffffff, 1.5)
  local over = ctx.hot and i.wx >= x and i.wx < x + w
               and i.wy >= y and i.wy < y + h
  if over and i.clicked[1] and not u.drag then u.drag = "sv" end
  if u.drag == "sv" then
    local s = math.max(0, math.min(1, (i.wx - x) / w))
    local v = math.max(0, math.min(1, 1 - (i.wy - y) / h))
    if not i.buttons[1] then u.drag = nil; return s, v, true end
    return s, v, false
  end
  return nil
end

-- The shell drops per-asset plumbing on every rewind seek; raw PAL texture
-- ids are not GC-owned (the sprite window's rule), so free the per-window
-- SV textures before the plumbing disappears.
function M.drop_ephemeral(ed)
  for _, p in pairs(ed.g.pw or {}) do
    for _, u in pairs(p.ui or {}) do
      if u.svtex then
        pal.tex_free(u.svtex)
        u.svtex, u.svhue, u.svimg = nil, nil, nil
      end
    end
  end
end

-- ---- draw ----

function M.header(win, ctx)
  if win.path == "" then return 0 end
  local s = cm.require("cm.ed.chips").strip(ctx)
  local p = A.plumb(ctx.ed, win.path)
  if s:chip("paste", false) and p.doc then
    local txt = pal.x_clipboard()
    local cols = txt and palette.parse_hex(txt)
    if cols and #cols > 0 then
      local kept = {}
      for n = 1, math.min(#cols, palette.MAX) do kept[n] = cols[n] end
      p.doc.colors = kept
      win.sel = math.min(win.sel or 1, #kept)
      commit(ctx.ed, win.path)
    end
  end
  if s:chip("copy", false) and p.doc then
    pal.x_clipboard(palette.to_hex(p.doc.colors))
  end
  return s.used
end

function M.draw(win, ctx)
  local z = ctx.z
  local px = math.max(4, 10 * z)
  local ed = ctx.ed
  if win.path == "" then
    A.pathfield(win, ed, ctx, { ext = "pal", default = "pal/",
                                label = "new palette path:" })
    return
  end
  local _, p = open_asset(ed, win.path)
  if p.err then
    pal.x_ig_text(ctx.cx + 6 * z, ctx.cy + 6 * z, px, COL.warn,
                  "bad .pal: " .. p.err, 0)
    return
  end
  local doc = p.doc
  if not doc then return end
  local u = winui(p, win) -- per-window UI state (multi-window safe)
  local cols = doc.colors
  if #cols == 0 then cols[1] = 0xffffffff end
  local i = cm.require("cm.ui").inp
  win.sel = math.max(1, math.min(win.sel or 1, #cols))
  local closed = false

  local x0, y0 = ctx.cx + 6 * z, ctx.cy + 6 * z
  local cw = ctx.cw - 12 * z

  seed_working(u, win)

  -- swatch grid (the SAVED colors — the top ~40%): swatches shrink so the
  -- whole palette stays visible (a few 32-shade ramps must not vanish off
  -- the grid). Click selects; double-click loads into the working color.
  local grid_h = ctx.ch * 0.40
  local sw = math.max(14, 26 * z)
  local gap
  while true do
    gap = math.max(1, math.floor(sw * 0.12))
    local per_try = math.max(1, math.floor(cw / (sw + gap)))
    if sw <= 8 or math.ceil(#cols / per_try) * (sw + gap) <= grid_h then break end
    sw = sw - 2
  end
  local per = math.max(1, math.floor(cw / (sw + gap)))
  for idx, c in ipairs(cols) do
    local sx = x0 + ((idx - 1) % per) * (sw + gap)
    local sy = y0 + ((idx - 1) // per) * (sw + gap)
    if sy + sw > y0 + grid_h then break end
    pal.x_ig_rect_fill(sx, sy, sw, sw, disp(c), 2 * z)
    if idx == win.sel then
      pal.x_ig_rect(sx - 1, sy - 1, sw + 2, sw + 2, COL.sel, 2, 2 * z)
    end
    if ctx.hot and i.clicked[1] and i.wx >= sx and i.wx < sx + sw
       and i.wy >= sy and i.wy < sy + sw then
      -- double-click (the assets-window 320ms rule) ADOPTS the swatch as
      -- the working color; a single click only selects — saved colors
      -- never clobber the mix by accident (the human's contract)
      local now = pal.time_ns()
      if win.sel == idx and u.swclick and (now - u.swclick) < 320 * 1e6 then
        adopt_working(u, win, c)
      end
      u.swclick = now
      win.sel = idx; ctx.touch()
    end
  end
  local rows = math.ceil(#cols / per)
  local ey = y0 + math.min(rows, math.max(1, math.floor(grid_h / (sw + gap))))
             * (sw + gap) + 8 * z

  -- ---- the working color (the mix scratch; never a saved swatch) ----
  local function apply_hsv() -- HSV scratch -> packed mirror
    win.wcol = paint.hsv(u.wh, u.ws, u.wv, 255)
    u.hexbuf = nil
    ed.touch()
  end
  pal.x_ig_rect_fill(x0, ey, 34 * z, 34 * z, disp(win.wcol), 3 * z)
  pal.x_ig_rect(x0, ey, 34 * z, 34 * z, 0x6a5a8cff, 1, 3 * z)
  local hx = x0 + 42 * z
  -- picker mode chips + the swatch counter
  local mw = 26 * z
  for mi, mode in ipairs { "sv", "hsv", "rgb" } do
    if button(ctx, hx + (mi - 1) * (mw + 3 * z), ey, mw, 14 * z, mode,
              (win.pick or "sv") == mode) then
      win.pick = mode; ctx.touch()
    end
  end
  pal.x_ig_text(hx + 3 * (mw + 3 * z) + 4 * z, ey + 3 * z, px * 0.8, COL.dim,
                ("swatch %d/%d"):format(win.sel, #cols), 0)
  if not ctx.occluded then
    local r, g, b = paint.unpack(win.wcol)
    pal.x_ig_rect(hx, ey + 18 * z, cw - 42 * z, 16 * z, 0x4a437088, 1, 2 * z)
    local text = pal.x_ig_edit {
      id = "palhex" .. win.id, x = hx + 4 * z, y = ey + 19 * z,
      w = cw - 50 * z, h = 14 * z,
      text = u.hexbuf ~= nil and u.hexbuf
             or string.format("%02x%02x%02x", r, g, b),
      px = px * 0.9, font = 1, enter = true, multiline = false,
    }
    u.hexbuf = text
    -- the field is RGB-only (Lospec hex), so compare RGB only: writing
    -- back on an alpha difference would silently strip an adopted
    -- swatch's alpha every frame (the tape caught it)
    local parsed = text and #text >= 6 and palette.parse_hex(text)
    if parsed and parsed[1]
       and (parsed[1] ~ win.wcol) & 0xffffff ~= 0 then
      win.wcol = parsed[1]
      u.wh, u.ws, u.wv = paint.to_hsv(win.wcol)
      ed.touch()
    end
  end

  -- ---- the picker (sv square | hsv sliders | rgb sliders) ----
  local sy = ey + 40 * z
  local sh = px * 1.5
  local nv, done
  local pick = win.pick or "sv"
  if pick == "sv" then
    nv = slider(u, ctx, "wh", x0, sy, cw, sh,
                math.floor(u.wh * 360) % 360, 0, 359, "H",
                function(v) return ("%d°"):format(v) end)
    if nv then u.wh = nv / 360; apply_hsv() end
    local s, v = sv_square(u, ctx, x0, sy + sh + 2 * z, cw, 84 * z)
    if s then u.ws, u.wv = s, v; apply_hsv() end
    sy = sy + sh + 2 * z + 84 * z
  elseif pick == "hsv" then
    nv = slider(u, ctx, "wh", x0, sy, cw, sh,
                math.floor(u.wh * 360) % 360, 0, 359, "H",
                function(v) return ("%d°"):format(v) end)
    if nv then u.wh = nv / 360; apply_hsv() end
    nv = slider(u, ctx, "ws", x0, sy + sh, cw, sh,
                math.floor(u.ws * 100 + 0.5), 0, 100, "S",
                function(v) return ("%d%%"):format(v) end)
    if nv then u.ws = nv / 100; apply_hsv() end
    nv = slider(u, ctx, "wv", x0, sy + sh * 2, cw, sh,
                math.floor(u.wv * 100 + 0.5), 0, 100, "V",
                function(v) return ("%d%%"):format(v) end)
    if nv then u.wv = nv / 100; apply_hsv() end
    sy = sy + sh * 3
  else -- rgb
    local r, g, b = paint.unpack(win.wcol)
    local function apply_rgb(nr, ng, nb) -- packed mirror -> HSV scratch
      win.wcol = paint.pack(nr, ng, nb, 255)
      u.wh, u.ws, u.wv = paint.to_hsv(win.wcol)
      u.hexbuf = nil
      ed.touch()
    end
    nv = slider(u, ctx, "wr", x0, sy, cw, sh, r, 0, 255, "R")
    if nv then apply_rgb(nv, g, b) end
    nv = slider(u, ctx, "wg", x0, sy + sh, cw, sh, g, 0, 255, "G")
    if nv then apply_rgb(r, nv, b) end
    nv = slider(u, ctx, "wb", x0, sy + sh * 2, cw, sh, b, 0, 255, "B")
    if nv then apply_rgb(r, g, nv) end
    sy = sy + sh * 3
  end

  -- ---- swatch ops (working -> saved, plus order/del) ----
  local oy = sy + 5 * z
  local bw = (cw - 5 * 3 * z) / 6
  if button(ctx, x0, oy, bw, px * 1.6, "+add")
     and #cols < palette.MAX then
    table.insert(cols, win.sel + 1, win.wcol)
    win.sel = win.sel + 1; closed = true
  end
  if button(ctx, x0 + (bw + 3 * z), oy, bw, px * 1.6, "set") then
    if cols[win.sel] ~= win.wcol then
      cols[win.sel] = win.wcol; closed = true
    end
  end
  if button(ctx, x0 + 2 * (bw + 3 * z), oy, bw, px * 1.6, "dup")
     and #cols < palette.MAX then
    table.insert(cols, win.sel + 1, cols[win.sel])
    win.sel = win.sel + 1; closed = true
  end
  if button(ctx, x0 + 3 * (bw + 3 * z), oy, bw, px * 1.6, "del") and #cols > 1 then
    table.remove(cols, win.sel); win.sel = math.max(1, win.sel - 1); closed = true
  end
  if button(ctx, x0 + 4 * (bw + 3 * z), oy, bw, px * 1.6, "◄") and win.sel > 1 then
    cols[win.sel], cols[win.sel - 1] = cols[win.sel - 1], cols[win.sel]
    win.sel = win.sel - 1; closed = true
  end
  if button(ctx, x0 + 5 * (bw + 3 * z), oy, bw, px * 1.6, "►") and win.sel < #cols then
    cols[win.sel], cols[win.sel + 1] = cols[win.sel + 1], cols[win.sel]
    win.sel = win.sel + 1; closed = true
  end

  -- ---- the ramp generator (from the WORKING color): an n slider AND a
  -- typed count, + a hue-shift, then append / replace. The slider spans
  -- the full typed range so the two can never disagree off-scale.
  win.rampn = win.rampn or 5
  local ry = oy + px * 2.0
  pal.x_ig_text(x0, ry + 2 * z, px * 0.85, COL.accent, "ramp from working", 0)
  if not ctx.occluded then
    local fx = x0 + cw - 50 * z
    pal.x_ig_text(fx - 44 * z, ry + 2 * z, px * 0.82, COL.dim, "shades", 0)
    pal.x_ig_rect(fx, ry, 46 * z, 15 * z, 0x4a437088, 1, 2 * z)
    local t = pal.x_ig_edit {
      id = "rampn" .. win.id, x = fx + 4 * z, y = ry + 1 * z,
      w = 38 * z, h = 13 * z,
      text = u.rampbuf ~= nil and u.rampbuf or tostring(win.rampn),
      px = px * 0.85, font = 1, enter = true, multiline = false,
    }
    u.rampbuf = t
    local rn = tonumber(t)
    if rn then win.rampn = math.max(2, math.min(32, math.floor(rn))) end
  end
  ry = ry + px * 1.6
  nv, done = slider(u, ctx, "rn", x0, ry, cw * 0.5 - 3 * z, px * 1.4,
                    win.rampn, 2, 32, "n")
  if nv then win.rampn = nv; u.rampbuf = nil; ctx.touch() end
  nv, done = slider(u, ctx, "rh", x0 + cw * 0.5, ry, cw * 0.5, px * 1.4,
                    win.ramph or 14, -30, 30, "hue",
                    function(v) return ("%+d°"):format(v) end)
  if nv then win.ramph = nv; ctx.touch() end
  ry = ry + px * 1.7
  if button(ctx, x0, ry, cw * 0.5 - 3 * z, px * 1.7, "append ramp") then
    for _, c in ipairs(palette.ramp(win.wcol, win.rampn,
                                    { hue_shift = win.ramph or 14 })) do
      if #cols >= palette.MAX then break end
      cols[#cols + 1] = c
    end
    closed = true
  end
  if button(ctx, x0 + cw * 0.5, ry, cw * 0.5, px * 1.7, "replace all") then
    doc.colors = palette.ramp(win.wcol, win.rampn,
                              { hue_shift = win.ramph or 14 })
    win.sel = 1; closed = true
  end

  if closed then commit(ed, win.path) end
end

return M
