-- cm.ed.win.sprite — the sprite ed (R4, EDITOR.md §12.6): the studio's
-- successor as a canvas citizen. READ-ONLY by default (the composited
-- current frame over a checker, aspect-fit) with an obvious edit toggle
-- in the header.
--
-- The working state is the CSPR bytes — doc.assets[path].spr — so the §6
-- three-layer model applies verbatim: dirty = bytes ≠ disk, journal
-- entries are full .spr snapshots (cap 512 — they're big), Ctrl+Z/Y walk
-- them, revert is an edit, restart survival rides session.dat. The
-- decoded cm.sprite doc + its GPU textures are ephemeral plumbing keyed
-- by path. One gesture (stroke / fill / structure op) = one encode + one
-- journal push — the studio's in-memory undo is not used.
--
-- v1 roster (D051 — deliberately lean): pencil / eraser / bucket /
-- eyedropper, the doc palette + hex add, layer list (select/eye/add/del),
-- frame chips (select/add/dup/del), wheel zoom + middle-drag pan.
-- Gradients/transforms/clips/pivot editing return as content work
-- demands them (.spr carries them; saving preserves what we don't show).

local M = select(2, ...) or {}
local sprite = cm.require("cm.sprite")
local paint = cm.require("cm.paint")

M.kind = "sprite"
M.DEF_W, M.DEF_H = 460, 380
M.JCAP = 512

local COL = {
  rail = 0x1a1728ff, btn = 0x262238ff, btn_on = 0x4a4370ff,
  btn_hot = 0x3a3560ff, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  hot = 0xE8E4FFff, accent = 0x7fd8a8ff, danger = 0xf07a7aff,
  checker_a = 0x232030ff, checker_b = 0x2b2838ff,
}

local TOOLS = { { "pen", "P" }, { "eraser", "E" }, { "fill", "F" },
                { "pick", "K" } }

function M.defaults()
  return { path = "", edit = false, tool = "pen", color = 0xffffffff }
end

function M.title(win)
  local base = win.path:match("([^/]+)$") or "sprite"
  return base .. (win.edit and "" or "  · view")
end

function M.accepts(win, path)
  return path:lower():find("%.spr$") ~= nil
end

function M.rebind(win, ed, path)
  win.path = path
  win.zoom, win.px, win.py = nil, nil, nil
  ed.touch()
end

-- ---- the asset citizen (cm.ed.kit, R9a) — plumbing on ed.g.sw[path],
-- working CSPR bytes in doc.assets[path].spr, the §6 contract generated

local function decode_into(p, bytes)
  local ok, doc = pcall(sprite.decode, bytes)
  if ok then
    p.doc = doc
    p.err = nil
  else
    p.doc = nil
    p.err = tostring(doc)
  end
  p.comp_dirty = true
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "sw", field = "spr", jcap = M.JCAP,
  fresh = function(ed, path) -- a new sprite: start a fresh 32x32 doc
    local name = path:match("([^/]+)%.spr$") or "sprite"
    return sprite.encode(sprite.new(32, 32, { name = name }))
  end,
  adopt = decode_into,
  encode = sprite.encode,
  write = function(ed, path, a, p) -- sprite.save writes + bakes siblings
    return sprite.save(p.doc, ed.root .. "/" .. path)
  end,
  after_save = function(ed, path) return "[ed] saved + baked " .. path end,
}

local open_asset, commit = A.open_asset, A.commit

-- public open (spawn-time adoption, console driving, proofs)
M.open_win = A.open_win

-- shared working-state door for other kinds over the SAME .spr bytes
-- (the anim window edits clips through the same journal — both windows
-- stay in sync through the shared decoded doc); commit_path is the
-- other half: a finished gesture from another kind commits through the
-- same encode + journal push
M.open_path = A.open_asset
M.commit_path = A.commit

-- the §6 focused-window commands (shell kind_call dispatch)
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- ---- header: the edit toggle (the board's "obvious toggle") ----

function M.header(win, ctx)
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local i = cm.require("cm.ui").inp
  local x, used = ctx.hx, 0
  local function chip(label, on)
    local w = pal.x_ig_text_size(label, px, 0) + 14 * z
    x = x - w
    used = used + w + 4 * z
    local hov = ctx.hot and i.wx >= x and i.wx < x + w
                and i.wy >= ctx.hy and i.wy < ctx.hy + ctx.hh
    pal.x_ig_rect_fill(x, ctx.hy + 3 * z, w, ctx.hh - 6 * z,
                       on and COL.btn_on or COL.btn, 4 * z)
    pal.x_ig_text(x + 7 * z, ctx.hy + (ctx.hh - px) * 0.45, px,
                  (hov or on) and COL.hot or COL.dim, label, 0)
    x = x - 4 * z
    return hov and i.clicked[1]
  end
  if chip(win.edit and "done" or "edit", win.edit) then
    win.edit = not win.edit
    ctx.ed.touch()
  end
  -- the animation window door (the board's "split animation stuff"):
  -- open (or focus) an anim window bound to this sprite
  if win.path ~= "" and chip("anim", false) then
    local ed = ctx.ed
    local wm = cm.require("cm.ed.wm")
    local found
    for _, w2 in ipairs(ed.doc.wins) do
      if w2.kind == "anim" and w2.path == win.path then found = w2 end
    end
    if found then
      ed.doc.focus = found.id
      wm.to_front(ed.doc, found.id)
    else
      local K = ed.kinds.anim
      local aw = wm.spawn(ed.doc, "anim", win.x + win.w + 20, win.y,
                          K.DEF_W, K.DEF_H, K.defaults())
      aw.path = win.path
    end
    ed.touch()
  end
  return used
end

-- ---- view helpers ----

local function checker(x, y, w, h, z)
  pal.x_ig_rect_fill(x, y, w, h, COL.checker_a, 3 * z)
  local step = 10 * z
  pal.x_ig_clip_push(x, y, w, h)
  for iy = 0, math.ceil(h / step) - 1 do
    for ix = 0, math.ceil(w / step) - 1 do
      if (ix + iy) % 2 == 0 then
        pal.x_ig_rect_fill(x + ix * step, y + iy * step, step, step,
                           COL.checker_b)
      end
    end
  end
  pal.x_ig_clip_pop()
end

-- rebuild the composite texture for the current frame (fast path: blit32
-- composite + tex_update in place, the studio's proven pipeline)
local function refresh_tex(p)
  local doc = p.doc
  if not doc then return end
  if not p.comp or p.comp.w ~= doc.w or p.comp.h ~= doc.h then
    p.comp = paint.image(doc.w, doc.h)
    if p.tex then
      pal.tex_free(p.tex)
      p.tex = nil
    end
  end
  sprite.composite_into(doc, doc.cur_frame, p.comp)
  if p.tex and pal.tex_update(p.tex, p.comp.buf, doc.w, doc.h) then
    -- updated in place
  else
    if p.tex then pal.tex_free(p.tex) end
    p.tex = pal.tex_create(doc.w, doc.h, p.comp.buf:str(0, doc.w * doc.h * 4))
  end
  p.comp_dirty = nil
end

-- focused = the view lock (the map window's model — the human's ask,
-- 2026-07-13): an edit-mode sprite ed owns wheel + middle-drag only
-- WHILE FOCUSED; unfocused = inert view (the canvas pans/zooms over
-- it). View mode never locks.
function M.own_view(win)
  return win.edit == true and (win.path or "") ~= ""
end

-- content wheel: zoom the sprite view at the cursor (focused edit mode
-- only — FOCUS IS THE ONE GATE, the map window's contract). Under the
-- lock the wheel arrives from anywhere — a cursor outside the canvas
-- anchors at the view center. The math lives in cm.ed.winview.
function M.wheel(win, ed, dy)
  if not win.edit or ed.doc.focus ~= win.id then return false end
  local p = ed.g.sw and ed.g.sw[win.path]
  local r = p and p.canvas_rect
  if not (r and p.doc) then return false end
  local i = cm.require("cm.ui").inp
  local ax, ay = i.wx, i.wy
  if ax < r.cx or ax >= r.cx + r.w or ay < r.cy or ay >= r.cy + r.h then
    ax, ay = r.cx + r.w * 0.5, r.cy + r.h * 0.5
  end
  cm.require("cm.ed.winview").wheel_zoom(win, r, ax, ay, dy, 0.25, 64)
  ed.touch()
  return true
end

-- middle-drag pans the sprite view — focused edit mode only (§12.6 +
-- the view-lock contract); unfocused, the canvas pans
function M.takes_middle(win, ed)
  return win.edit == true and ed ~= nil and ed.doc.focus == win.id
end

-- Esc while the global eyedropper is armed drops back to the pen — the
-- visible exit from pick-anywhere (the shell's Esc ladder calls this)
function M.escape(win, ed)
  if win.edit and win.tool == "pick" then
    win.tool = "pen"
    ed.touch()
    return true
  end
  return false
end

-- ---- structure rows (layers / frames / palette) ----

local function button(i, ctx, x, y, w, h, label, on, px)
  local hov = ctx.hot and i.wx >= x and i.wx < x + w
              and i.wy >= y and i.wy < y + h
  pal.x_ig_rect_fill(x, y, w, h, on and COL.btn_on
                     or (hov and COL.btn_hot or COL.btn), 3 * ctx.z)
  local tw = pal.x_ig_text_size(label, px, 1)
  pal.x_ig_text(x + (w - tw) * 0.5, y + (h - px) * 0.45, px,
                (on or hov) and COL.hot or COL.dim, label, 1)
  return hov and i.clicked[1]
end

-- colors: win.color + doc.palette are in cm.paint's packing (R low byte —
-- the buffer byte order); the drawlist wants 0xRRGGBBAA. Convert at draw.
local function disp(c)
  local r, g, b, a = paint.unpack(c)
  return (r << 24) | (g << 16) | (b << 8) | a
end

local function hex_parse(s) -- "#RRGGBB[AA]" → paint packing
  s = s:gsub("^#", ""):gsub("%s", "")
  if not s:find("^%x+$") then return nil end
  if #s == 6 then
    local v = tonumber(s, 16)
    return paint.pack((v >> 16) & 255, (v >> 8) & 255, v & 255, 255)
  end
  if #s == 8 then
    local v = tonumber(s, 16)
    return paint.pack((v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255,
                      v & 255)
  end
  return nil
end

-- ---- content ----

function M.draw(win, ctx)
  local ed = ctx.ed
  if win.path == "" then
    pal.x_ig_text(ctx.cx + 8 * ctx.z, ctx.cy + 8 * ctx.z,
                  math.max(4, 12 * ctx.z), COL.dim,
                  "no sprite bound — drag a .spr from an assets window", 0)
    return
  end
  local a, p = open_asset(ed, win.path)
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local i = cm.require("cm.ui").inp

  if p.err or not p.doc then
    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, COL.danger,
                  "unreadable .spr: " .. tostring(p.err), 0)
    return
  end
  local doc = p.doc
  if p.comp_dirty then refresh_tex(p) end

  -- ---- read-only: aspect-fit view ----
  if not win.edit then
    checker(ctx.cx, ctx.cy, ctx.cw, ctx.ch, z)
    local m = 4 * z
    local s = math.min((ctx.cw - 2 * m) / doc.w, (ctx.ch - 2 * m) / doc.h)
    local dw, dh = doc.w * s, doc.h * s
    if p.tex then
      pal.x_ig_image(p.tex, ctx.cx + (ctx.cw - dw) * 0.5,
                     ctx.cy + (ctx.ch - dh) * 0.5, dw, dh)
    end
    local info = ("%dx%d · %d frame%s · %d layer%s"):format(
      doc.w, doc.h, doc.frames, doc.frames == 1 and "" or "s",
      #doc.layers, #doc.layers == 1 and "" or "s")
    pal.x_ig_text(ctx.cx + 6 * z, ctx.cy + ctx.ch - px * 1.4, px * 0.9,
                  COL.dim, info, 1)
    return
  end

  -- ---- edit mode layout ----
  local TR = 26 * z -- tools rail
  local LR = math.min(96 * z, ctx.cw * 0.3) -- layers rail
  local BB = 40 * z -- palette + frames rows
  local cvx, cvy = ctx.cx + TR, ctx.cy
  local cvw, cvh = ctx.cw - TR - LR, ctx.ch - BB
  if cvw < 40 or cvh < 40 then return end

  -- tools rail
  pal.x_ig_rect_fill(ctx.cx, ctx.cy, TR - 3 * z, cvh, COL.rail, 4 * z)
  local ty = ctx.cy + 4 * z
  for _, t in ipairs(TOOLS) do
    if button(i, ctx, ctx.cx + 3 * z, ty, TR - 9 * z, TR - 9 * z, t[2],
              win.tool == t[1], px) then
      win.tool = t[1]
      ctx.touch()
    end
    ty = ty + TR - 5 * z
  end
  -- current color swatch at the rail bottom
  pal.x_ig_rect_fill(ctx.cx + 3 * z, ctx.cy + cvh - TR + 2 * z,
                     TR - 9 * z, TR - 9 * z, disp(win.color or 0xffffffff),
                     3 * z)
  pal.x_ig_rect(ctx.cx + 3 * z, ctx.cy + cvh - TR + 2 * z,
                TR - 9 * z, TR - 9 * z, 0x00000066, 1, 3 * z)

  -- the canvas, via cm.ed.winview: captured fields in WORLD units
  -- (win.zoom = world units per sprite px, win.px/py = world-unit pan)
  -- so the content stays glued to the frame at any canvas zoom
  checker(cvx, cvy, cvw, cvh, z)
  local wv = cm.require("cm.ed.winview")
  local view = wv.view(win, z, cvx, cvy, cvw, cvh, doc.w, doc.h, 4)
  local zoom, ox, oy = view.zoom, view.ox, view.oy
  p.canvas_rect = view
  pal.x_ig_clip_push(cvx, cvy, cvw, cvh)
  if p.tex then
    pal.x_ig_image(p.tex, ox, oy, doc.w * zoom, doc.h * zoom)
  end
  pal.x_ig_rect(ox - 1, oy - 1, doc.w * zoom + 2, doc.h * zoom + 2,
                0x4a4370aa, 1)

  -- the focus lock + pick-anywhere, unmissable (the EDITING-chip
  -- idiom): focused = this view owns wheel/mmb everywhere; the pick
  -- tool widens that to "the whole screen is a color source"
  if ctx.focused then
    pal.x_ig_rect(cvx + 1, cvy + 1, cvw - 2, cvh - 2, COL.accent,
                  math.max(1, 1.5 * z), 3 * z)
    local picking = ctx.ed.pick_armed and ctx.ed.pick_armed() == win
    local fl = picking and "PICKING — click anywhere · esc out"
               or "EDITING — wheel/mmb here · esc out"
    local fpx = math.max(4, 10 * z)
    local fw2 = pal.x_ig_text_size(fl, fpx, 0)
    pal.x_ig_rect_fill(cvx + 4 * z, cvy + 4 * z, fw2 + 10 * z, fpx * 1.5,
                       0x7fd8a8cc, 4 * z)
    pal.x_ig_text(cvx + 9 * z, cvy + 4 * z + fpx * 0.22, fpx, 0x10241aff,
                  fl, 0)
  end
  pal.x_ig_clip_pop()

  local over_canvas = ctx.hot and i.wx >= cvx and i.wx < cvx + cvw
                      and i.wy >= cvy and i.wy < cvy + cvh

  -- middle-drag pans the view — focused only (the lock grabs from
  -- anywhere over the window; an unfocused view is inert)
  if ctx.focused and i.clicked[2] then
    p.pan = { mx = i.wx, my = i.wy, ox = ox, oy = oy }
  end
  if p.pan then
    if i.buttons[2] then
      wv.pan(win, view, p.pan.ox, p.pan.oy, i.wx - p.pan.mx,
             i.wy - p.pan.my)
      ctx.touch()
    else
      p.pan = nil
    end
  end

  -- paint gestures
  local layer = doc.layers[doc.cur_layer]
  local cell = layer and sprite.cell(doc, doc.cur_layer, doc.cur_frame)
  local function pixel_at(wxp, wyp)
    return math.floor((wxp - ox) / zoom), math.floor((wyp - oy) / zoom)
  end
  if over_canvas and cell and not (layer.locked) and not p.pan then
    local mx, my = pixel_at(i.wx, i.wy)
    -- hover cell outline
    if paint.in_bounds(cell, mx, my) then
      pal.x_ig_rect(ox + mx * zoom, oy + my * zoom, zoom, zoom,
                    0xE8E4FF66, 1)
    end
    if i.clicked[1] then
      if win.tool == "pick" then
        local c = paint.get(p.comp, mx, my)
        if c and c ~= 0 then
          win.color = c
          ctx.touch()
        end
      elseif win.tool == "fill" then
        if paint.in_bounds(cell, mx, my) then
          paint.flood(cell, mx, my, win.color or 0xffffffff)
          p.comp_dirty = true
          commit(ed, win.path)
        end
      else
        p.stroke = { lx = mx, ly = my }
        local c = win.tool == "eraser" and 0 or (win.color or 0xffffffff)
        if paint.in_bounds(cell, mx, my) then paint.set(cell, mx, my, c) end
        p.comp_dirty = true
      end
    end
  end
  if p.stroke then
    if i.buttons[1] then
      local mx, my = pixel_at(i.wx, i.wy)
      if mx ~= p.stroke.lx or my ~= p.stroke.ly then
        local c = win.tool == "eraser" and 0 or (win.color or 0xffffffff)
        if cell then
          paint.line(cell, p.stroke.lx, p.stroke.ly, mx, my, c)
        end
        p.stroke.lx, p.stroke.ly = mx, my
        p.comp_dirty = true
      end
    else
      p.stroke = nil
      commit(ed, win.path) -- the gesture = one journal entry
    end
  end

  -- layers rail (right)
  local lx = ctx.cx + ctx.cw - LR + 3 * z
  pal.x_ig_rect_fill(lx - 3 * z, ctx.cy, LR, cvh, COL.rail, 4 * z)
  local ly = ctx.cy + 4 * z
  local rh = px * 1.6
  pal.x_ig_text(lx + 2 * z, ly, px * 0.85, COL.dim, "layers", 0)
  ly = ly + px * 1.3
  for li = #doc.layers, 1, -1 do
    local l = doc.layers[li]
    local on = doc.cur_layer == li
    local hov = ctx.hot and i.wx >= lx and i.wx < lx + LR - 8 * z
                and i.wy >= ly and i.wy < ly + rh
    if on or hov then
      pal.x_ig_rect_fill(lx, ly, LR - 9 * z, rh,
                         on and COL.btn_on or COL.btn_hot, 3 * z)
    end
    -- eye toggle
    local ex = lx + 2 * z
    local eyec = l.hidden and COL.dim or COL.accent
    pal.x_ig_circle_fill(ex + 4 * z, ly + rh * 0.5, 2.5 * z, eyec)
    if hov and i.clicked[1] then
      if i.wx < ex + 9 * z then
        l.hidden = not l.hidden
        p.comp_dirty = true
        commit(ed, win.path)
      else
        doc.cur_layer = li
        ctx.touch()
      end
    end
    pal.x_ig_clip_push(lx + 10 * z, ly, LR - 22 * z, rh)
    pal.x_ig_text(lx + 12 * z, ly + (rh - px) * 0.45, px * 0.95,
                  on and COL.hot or COL.text, l.name or ("layer " .. li), 0)
    pal.x_ig_clip_pop()
    ly = ly + rh + 2 * z
  end
  local bw = (LR - 14 * z) / 2
  if button(i, ctx, lx, ly, bw, rh, "+", false, px) then
    sprite.add_layer(doc)
    p.comp_dirty = true
    commit(ed, win.path)
  end
  if button(i, ctx, lx + bw + 2 * z, ly, bw, rh, "-", false, px)
     and #doc.layers > 1 then
    sprite.delete_layer(doc, doc.cur_layer)
    p.comp_dirty = true
    commit(ed, win.path)
  end

  -- palette row
  local py0 = ctx.cy + cvh + 4 * z
  local sw = math.max(8, 13 * z)
  local sx0 = ctx.cx + 2 * z
  local n = 0
  for ci, c in ipairs(doc.palette) do
    local x = sx0 + n * (sw + 2 * z)
    if x + sw > ctx.cx + ctx.cw - 90 * z then break end
    pal.x_ig_rect_fill(x, py0, sw, sw, disp(c), 2 * z)
    if (win.color or 0) == c then
      pal.x_ig_rect(x - 1, py0 - 1, sw + 2, sw + 2, COL.hot, 1, 2 * z)
    end
    local hov = ctx.hot and i.wx >= x and i.wx < x + sw
                and i.wy >= py0 and i.wy < py0 + sw
    if hov and i.clicked[1] then
      win.color = c
      ctx.touch()
    end
    n = n + 1
  end
  -- hex add (enter commits)
  local hx = ctx.cx + ctx.cw - 86 * z
  pal.x_ig_rect(hx, py0, 82 * z, sw, 0x4a437088, 1, 2 * z)
  if not ctx.occluded then
    local text, _, _, st = pal.x_ig_edit {
      id = "sphex" .. win.id, x = hx + 2 * z, y = py0 + 1,
      w = 78 * z, h = sw - 2, text = p.hex or "", px = px * 0.9, font = 1,
      enter = true, multiline = false,
    }
    p.hex = text
    if st and st.submit then
      local c = hex_parse(text)
      if c then
        win.color = c
        doc.palette[#doc.palette + 1] = c
        commit(ed, win.path)
        p.hex = ""
      end
    end
  end

  -- frames row
  local fy = py0 + sw + 3 * z
  local fh = math.max(8, 14 * z)
  local fx = sx0
  for fi = 1, doc.frames do
    local label = tostring(fi)
    local fw = pal.x_ig_text_size(label, px * 0.9, 1) + 8 * z
    if button(i, ctx, fx, fy, fw, fh, label, doc.cur_frame == fi, px * 0.9) then
      doc.cur_frame = fi
      p.comp_dirty = true
      ctx.touch()
    end
    fx = fx + fw + 2 * z
    if fx > ctx.cx + ctx.cw - 80 * z then break end
  end
  local ops = { { "+", function() sprite.add_frame(doc) end },
                { "⧉", function() sprite.dup_frame(doc, doc.cur_frame) end },
                { "-", function()
                    if doc.frames > 1 then
                      sprite.delete_frame(doc, doc.cur_frame)
                    end
                  end } }
  local opx = ctx.cx + ctx.cw - 78 * z
  for _, op in ipairs(ops) do
    if button(i, ctx, opx, fy, 22 * z, fh, op[1], false, px * 0.9) then
      op[2]()
      p.comp_dirty = true
      commit(ed, win.path)
    end
    opx = opx + 25 * z
  end
end

return M
