-- cm.ed.win.palette — the color palette designer (.pal). A windowkit
-- asset citizen (journal / dirty / ctrl+Z/S / unsaved-persists / rewind).
--
-- Design a palette: a swatch grid (add / dup / del / reorder / select),
-- per-color HSV sliders + hex entry, and the signature RAMP generator —
-- a hue-shifted value ramp from the selected color (the pixel-art
-- principles baked in: value spread, warm-highlight/cool-shadow hue
-- shift, saturation bell). Copy/paste the whole palette as Lospec hex.
--
-- Integration: swatches sit on the canvas, so the sprite ed's global
-- eyedropper samples them straight off the screen — that IS "pick from
-- the canvas color picker". Games reference a palette via cm.palette.load.

local M = select(2, ...) or {}
local palette = cm.require("cm.palette")
local paint = cm.require("cm.paint")

M.kind = "palette"
M.menu = "palette"
M.exts = { "pal" }
M.DEF_W, M.DEF_H = 380, 476
M.JCAP = 256

local COL = {
  rail = 0x1a1728ff, well = 0x141220ff, btn = 0x262238ff,
  btn_on = 0x4a4370ff, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  hot = 0xE8E4FFff, accent = 0x7fd8a8ff, slider = 0x4a4370ff,
  sel = 0xE8E4FFff, warn = 0xf07a7aff,
}

function M.defaults()
  return { path = "", sel = 1, rampn = 5, ramph = 14 }
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
}
local open_asset, commit = A.open_asset, A.commit
M.open_win = A.open_win
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- ---- widgets ----

local function disp(c) -- ARGB screen order from cm.paint RGBA packing
  local r, g, b = paint.unpack(c)
  return (0xff << 24) | (r << 16) | (g << 8) | b
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
-- made a drag in one window move sliders in the other).
local function winui(p, win)
  p.ui = p.ui or {}
  local u = p.ui[win.id]
  if not u then u = {}; p.ui[win.id] = u end
  return u
end

-- horizontal drag slider; `st` holds the per-window drag state (st.drag).
-- Returns new value while dragging, done on release.
local function slider(st, ctx, id, x, y, w, h, val, lo, hi, label)
  local i = cm.require("cm.ui").inp
  local z, px = ctx.z, math.max(4, 8.5 * ctx.z)
  pal.x_ig_text(x, y + (h - px) * 0.5, px, COL.dim, label, 0)
  local bx = x + 26 * z
  local bw = w - 26 * z
  local by, bh = y + h * 0.5 - 3 * z, 6 * z
  pal.x_ig_rect_fill(bx, by, bw, bh, COL.well, 2 * z)
  local f = (val - lo) / (hi - lo)
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

-- ---- draw ----

function M.header(win, ctx)
  if win.path == "" then return 0 end
  local s = cm.require("cm.ed.chips").strip(ctx)
  local p = A.plumb(ctx.ed, win.path)
  if s:chip("paste", false) and p.doc then
    local txt = pal.x_clipboard()
    local cols = txt and palette.parse_hex(txt)
    if cols and #cols > 0 then
      p.doc.colors = cols
      win.sel = math.min(win.sel or 1, #cols)
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
  local edited, closed = false, false

  local x0, y0 = ctx.cx + 6 * z, ctx.cy + 6 * z
  local cw = ctx.cw - 12 * z

  -- swatch grid (keeps the top ~44%)
  local sw = math.max(14, 26 * z)
  local per = math.max(1, math.floor(cw / (sw + 3 * z)))
  local grid_h = ctx.ch * 0.44
  for idx, c in ipairs(cols) do
    local sx = x0 + ((idx - 1) % per) * (sw + 3 * z)
    local sy = y0 + ((idx - 1) // per) * (sw + 3 * z)
    if sy + sw > y0 + grid_h then break end
    pal.x_ig_rect_fill(sx, sy, sw, sw, disp(c), 2 * z)
    if idx == win.sel then
      pal.x_ig_rect(sx - 1, sy - 1, sw + 2, sw + 2, COL.sel, 2, 2 * z)
    end
    if ctx.hot and i.clicked[1] and i.wx >= sx and i.wx < sx + sw
       and i.wy >= sy and i.wy < sy + sw then
      win.sel = idx; u.selc = nil; ctx.touch()
    end
  end
  local rows = math.ceil(#cols / per)
  local ey = y0 + math.min(rows, math.max(1, math.floor(grid_h / (sw + 3 * z))))
             * (sw + 3 * z) + 8 * z

  -- selected-color editor: an HSV working copy (deriving from the packed
  -- color each frame loses hue on grays / mid-drag). Per-window (u).
  if u.selc ~= win.sel then
    u.selc = win.sel
    u.eh, u.es, u.ev = paint.to_hsv(cols[win.sel])
  end
  local function apply()
    cols[win.sel] = paint.hsv(u.eh, u.es, u.ev, 255); edited = true
  end
  -- preview swatch (left) + hex field + info to its RIGHT (no overlap now)
  pal.x_ig_rect_fill(x0, ey, 34 * z, 34 * z, disp(cols[win.sel]), 3 * z)
  pal.x_ig_rect(x0, ey, 34 * z, 34 * z, 0x6a5a8cff, 1, 3 * z)
  local r, g, b = paint.unpack(cols[win.sel])
  if not ctx.occluded then
    local hx = x0 + 42 * z
    pal.x_ig_rect(hx, ey, cw - 42 * z, 16 * z, 0x4a437088, 1, 2 * z)
    local text = pal.x_ig_edit {
      id = "palhex" .. win.id, x = hx + 4 * z, y = ey + 1 * z,
      w = cw - 50 * z, h = 14 * z,
      text = u.hexbuf ~= nil and u.hexbuf or string.format("%02x%02x%02x", r, g, b),
      px = px * 0.9, font = 1, enter = true, multiline = false,
    }
    u.hexbuf = text
    local parsed = text and #text >= 6 and palette.parse_hex(text)
    if parsed and parsed[1] then
      cols[win.sel] = parsed[1]
      u.eh, u.es, u.ev = paint.to_hsv(cols[win.sel]); edited = true
    end
    pal.x_ig_text(hx, ey + 20 * z, px * 0.8, COL.dim,
                  ("swatch %d of %d"):format(win.sel, #cols), 0)
  end
  -- HSV sliders (BELOW the 34px swatch — the overlap bug)
  local sy = ey + 40 * z
  local sh = px * 1.5
  local nv, done = slider(u, ctx, "eh", x0, sy, cw, sh, math.floor(u.eh * 360), 0, 359, "H")
  if nv then u.eh = nv / 360; apply(); u.hexbuf = nil end
  closed = closed or done
  nv, done = slider(u, ctx, "es", x0, sy + sh, cw, sh, math.floor(u.es * 100), 0, 100, "S")
  if nv then u.es = nv / 100; apply(); u.hexbuf = nil end
  closed = closed or done
  nv, done = slider(u, ctx, "ev", x0, sy + sh * 2, cw, sh, math.floor(u.ev * 100), 0, 100, "V")
  if nv then u.ev = nv / 100; apply(); u.hexbuf = nil end
  closed = closed or done

  -- swatch ops
  local oy = sy + sh * 3 + 5 * z
  local bw = (cw - 4 * 3 * z) / 5
  local function ins_after(idx, c)
    table.insert(cols, idx + 1, c); win.sel = idx + 1; u.selc = nil; closed = true
  end
  if button(ctx, x0, oy, bw, px * 1.6, "+add") then
    ins_after(win.sel, 0xffffffff)
  end
  if button(ctx, x0 + (bw + 3 * z), oy, bw, px * 1.6, "dup") then
    ins_after(win.sel, cols[win.sel])
  end
  if button(ctx, x0 + 2 * (bw + 3 * z), oy, bw, px * 1.6, "del") and #cols > 1 then
    table.remove(cols, win.sel); win.sel = math.max(1, win.sel - 1); u.selc = nil; closed = true
  end
  if button(ctx, x0 + 3 * (bw + 3 * z), oy, bw, px * 1.6, "◄") and win.sel > 1 then
    cols[win.sel], cols[win.sel - 1] = cols[win.sel - 1], cols[win.sel]
    win.sel = win.sel - 1; u.selc = nil; closed = true
  end
  if button(ctx, x0 + 4 * (bw + 3 * z), oy, bw, px * 1.6, "►") and win.sel < #cols then
    cols[win.sel], cols[win.sel + 1] = cols[win.sel + 1], cols[win.sel]
    win.sel = win.sel + 1; u.selc = nil; closed = true
  end

  -- the ramp generator: an n slider AND a typed count (shows the exact
  -- number of shades), + a hue-shift, then append / replace
  win.rampn = win.rampn or 5
  local ry = oy + px * 2.0
  pal.x_ig_text(x0, ry + 2 * z, px * 0.85, COL.accent,
                ("ramp from #%d"):format(win.sel), 0)
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
                    win.rampn, 2, 16, "n")
  if nv then win.rampn = nv; u.rampbuf = nil; ctx.touch() end
  nv, done = slider(u, ctx, "rh", x0 + cw * 0.5, ry, cw * 0.5, px * 1.4,
                    win.ramph or 14, -30, 30, "hue")
  if nv then win.ramph = nv; ctx.touch() end
  ry = ry + px * 1.7
  if button(ctx, x0, ry, cw * 0.5 - 3 * z, px * 1.7, "append ramp") then
    for _, c in ipairs(palette.ramp(cols[win.sel], win.rampn,
                                    { hue_shift = win.ramph or 14 })) do
      cols[#cols + 1] = c
    end
    closed = true
  end
  if button(ctx, x0 + cw * 0.5, ry, cw * 0.5, px * 1.7, "replace all") then
    doc.colors = palette.ramp(cols[win.sel], win.rampn,
                              { hue_shift = win.ramph or 14 })
    win.sel = 1; u.selc = nil; closed = true
  end

  if edited and not closed then ed.touch() end
  if closed then commit(ed, win.path) end
end

return M
