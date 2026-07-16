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
M.menu = "sprite" -- spawn-menu entry: an unbound sprite ed → type a path to make one
M.help = "win-sprite"
M.exts = { "spr" }
M.DEF_W, M.DEF_H = 460, 380
M.JCAP = 512

local COL = {
  rail = 0x1a1728ff, btn = 0x262238ff, btn_on = 0x4a4370ff,
  btn_hot = 0x3a3560ff, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  hot = 0xE8E4FFff, accent = 0x7fd8a8ff, danger = 0xf07a7aff,
  checker_a = 0x232030ff, checker_b = 0x2b2838ff,
}

local TOOLS = { { "pen", "P" }, { "eraser", "E" }, { "fill", "F" },
                { "pick", "K" }, { "curve", "~" } }

function M.defaults()
  return { path = "", edit = false, tool = "pen", color = 0xffffffff,
           color2 = 0x000000ff, palettes = {} }
end

-- per-window hotkeys (EDITOR.md §13): tool keys mirror the rail chips
-- (edit mode only), shift+1 refits the view — dispatched by the shell
-- to the focused window, hints render under it
local function editing(win) return win.edit == true and win.path ~= "" end
local function set_tool(t)
  return function(win, ed)
    win.tool = t
    ed.touch()
  end
end
M.hotkeys = {
  { key = "p", hint = "pen", when = editing, fn = set_tool("pen") },
  { key = "e", hint = "eraser", when = editing, fn = set_tool("eraser") },
  { key = "f", hint = "fill", when = editing, fn = set_tool("fill") },
  { key = "k", hint = "pick", when = editing, fn = set_tool("pick") },
  { key = "c", hint = "curve", when = editing, fn = set_tool("curve") },
  { key = "x", hint = "swap colors", when = editing,
    fn = function(win, ed)
      win.color, win.color2 = win.color2 or 0x000000ff, win.color or 0xffffffff
      ed.touch()
    end },
  { key = "shift+1", hint = "fit",
    when = function(win) return win.path ~= "" end,
    fn = function(win, ed)
      win.zoom, win.px, win.py = nil, nil, nil
      ed.touch()
    end },
}

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

-- a .pal dropped on the sprite ed STACKS as an extra swatch source at the
-- bottom (the human's ask: drag palettes in, multiple, each removable). A .spr
-- still rebinds (accepts/rebind above); everything else falls through. Returns
-- true = the drop is handled here (kind.drop outranks rebind, ed.lua §drop).
function M.drop(win, ed, path, wx, wy)
  if not path:lower():find("%.pal$") then return false end
  win.palettes = win.palettes or {}
  for _, q in ipairs(win.palettes) do if q == path then return true end end
  win.palettes[#win.palettes + 1] = path
  ed.touch()
  return true
end

-- an attached .pal's colors (cm.paint-packed, same as doc.palette), cached on
-- the window's plumbing + refreshed when the file's mtime changes.
local function attached_colors(ed, p, path)
  p.palc = p.palc or {}
  local mt = pal.mtime(ed.root .. "/" .. path) or 0
  local hit = p.palc[path]
  if hit and hit.mt == mt then return hit.colors, hit.name end
  local colors, name = {}, path:match("([^/]+)%.pal$") or path
  local bytes = pal.read_file(ed.root .. "/" .. path)
  if bytes then
    local ok, d = pcall(cm.require("cm.palette").decode, bytes)
    if ok and d then colors, name = d.colors or {}, (d.name ~= "" and d.name) or name end
  end
  p.palc[path] = { mt = mt, colors = colors, name = name }
  return colors, name
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
  after_save = function(ed, path)
    -- render-only hot-reload: tilemaps + maps using this sprite re-read its
    -- baked texture next frame (the tmap-save convention, cm.asset_epoch)
    cm.asset_epoch = (cm.asset_epoch or 0) + 1
    return "[ed] saved + baked " .. path
  end,
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

-- The shell drops per-asset plumbing on every rewind seek. Raw PAL texture
-- IDs are not GC-owned, so the owner must release them before g.sw disappears.
-- tex_free is deferred by the PAL and is safe even when this frame sampled it.
function M.drop_ephemeral(ed)
  for _, p in pairs(ed.g.sw or {}) do
    if p.tex then
      pal.tex_free(p.tex)
      p.tex = nil
    end
  end
end

-- ---- header: the edit toggle (the board's "obvious toggle") ----

function M.header(win, ctx)
  local s = cm.require("cm.ed.chips").strip(ctx)
  if s:chip(win.edit and "done" or "edit", win.edit) then
    win.edit = not win.edit
    ctx.ed.touch()
  end
  -- the animation window door (the board's "split animation stuff"):
  -- open (or focus) an anim window bound to this sprite
  if win.path ~= "" and s:chip("anim", false) then
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
  return s.used
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

-- focused = the view lock (the map window's model, generalized —
-- kit.viewlock installs own_view/wheel/takes_middle): an edit-mode
-- sprite ed owns wheel + middle-drag only WHILE FOCUSED; unfocused =
-- inert view (the canvas pans/zooms over it). View mode never locks.
cm.require("cm.ed.kit").viewlock(M, {
  gkey = "sw", rect = "canvas_rect", zmin = 0.25, zmax = 64,
  lock = function(win) return win.edit == true and (win.path or "") ~= "" end,
})

-- Esc while the global eyedropper is armed drops back to the pen — the
-- visible exit from pick-anywhere (the shell's Esc ladder calls this)
function M.escape(win, ed)
  local p = ed.g.sw and ed.g.sw[win.path]
  if p and p.curve then p.curve = nil; ed.touch(); return true end
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

-- the 2-point curve (paint.curve = the MS-Paint cubic Bézier): a quadratic
-- through a single bend point B is the cubic with each control 2/3 of the way
-- from its endpoint toward B — a "simple 2-point curve" (the old editor's).
local function commit_curve(cell, cur, bx, by, color)
  paint.curve(cell, cur.x0, cur.y0,
    cur.x0 + (bx - cur.x0) * 2 / 3, cur.y0 + (by - cur.y0) * 2 / 3,
    cur.x3 + (bx - cur.x3) * 2 / 3, cur.y3 + (by - cur.y3) * 2 / 3,
    cur.x3, cur.y3, color)
end

-- preview the same quadratic as an imgui polyline (screen space, pixel centers)
local function curve_preview(ox, oy, zoom, x0, y0, bx, by, x3, y3, col, lt)
  local pxp, pyp
  for s = 0, 14 do
    local t = s / 14
    local u = 1 - t
    local qx = u * u * x0 + 2 * u * t * bx + t * t * x3
    local qy = u * u * y0 + 2 * u * t * by + t * t * y3
    local sx2, sy2 = ox + (qx + 0.5) * zoom, oy + (qy + 0.5) * zoom
    if pxp then pal.x_ig_line(pxp, pyp, sx2, sy2, col, lt) end
    pxp, pyp = sx2, sy2
  end
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
  local g = ed.g
  local TR = 26 * z -- tools rail
  local LR = math.min(96 * z, ctx.cw * 0.3) -- layers rail
  local nAtt = #(win.palettes or {})
  local ATT_H = 16 * z -- one row per dragged-in palette (the human's stack)
  local BB = 40 * z + nAtt * ATT_H -- palette + frames rows + attached palettes
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
  -- primary + secondary color swatches (LEFT paints primary, RIGHT paints the
  -- secondary — the 2-color ask; the X key or a right-click here swaps them)
  local swz = TR - 9 * z
  local sbx, sby = ctx.cx + 3 * z, ctx.cy + cvh - TR + 2 * z
  local s2 = swz * 0.62
  pal.x_ig_rect_fill(sbx + swz - s2, sby + swz - s2, s2, s2,
                     disp(win.color2 or 0x000000ff), 2 * z)
  pal.x_ig_rect(sbx + swz - s2, sby + swz - s2, s2, s2, 0x000000aa, 1, 2 * z)
  pal.x_ig_rect_fill(sbx, sby, swz * 0.78, swz * 0.78,
                     disp(win.color or 0xffffffff), 2 * z)
  pal.x_ig_rect(sbx, sby, swz * 0.78, swz * 0.78, 0x000000aa, 1, 2 * z)
  if ctx.hot and i.wx >= sbx and i.wx < sbx + swz and i.wy >= sby
     and i.wy < sby + swz and i.clicked[3] then
    win.color, win.color2 = win.color2 or 0x000000ff, win.color or 0xffffffff
    ctx.touch()
  end

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

  -- ---- paint gestures ----
  local layer = doc.layers[doc.cur_layer]
  local cell = layer and sprite.cell(doc, doc.cur_layer, doc.cur_frame)
  local function pixel_at(wxp, wyp)
    return math.floor((wxp - ox) / zoom), math.floor((wyp - oy) / zoom)
  end
  -- the paint color for a mouse button: RIGHT paints the secondary color (the
  -- 2-color ask); the eraser always clears
  local function paintcol(rmb)
    if win.tool == "eraser" then return 0 end
    return rmb and (win.color2 or 0x000000ff) or (win.color or 0xffffffff)
  end
  local mx, my = pixel_at(i.wx, i.wy)
  local paintable = over_canvas and cell and not (layer and layer.locked)
                    and not p.pan
  local inb = cell and paint.in_bounds(cell, mx, my)
  local lt = math.max(1, math.min(2, zoom * 0.5))

  if win.tool == "curve" then
    -- click A, click B (endpoints), then move to bow it, click to lay it.
    if paintable and inb then
      pal.x_ig_rect(ox + mx * zoom, oy + my * zoom, zoom, zoom, 0xE8E4FF66, 1)
    end
    local cur = p.curve
    if cur then
      if cur.stage == "p3" then
        pal.x_ig_line(ox + (cur.x0 + 0.5) * zoom, oy + (cur.y0 + 0.5) * zoom,
                      ox + (mx + 0.5) * zoom, oy + (my + 0.5) * zoom,
                      COL.accent, lt)
        if over_canvas and i.clicked[1] then
          cur.x3, cur.y3, cur.stage = mx, my, "bend"
          ctx.touch()
        end
      else -- "bend": preview the quadratic through the cursor
        curve_preview(ox, oy, zoom, cur.x0, cur.y0, mx, my, cur.x3, cur.y3,
                      COL.accent, lt)
        if over_canvas and i.clicked[1] and cell then
          commit_curve(cell, cur, mx, my, win.color or 0xffffffff)
          p.last = { x = cur.x3, y = cur.y3 }
          p.curve, p.comp_dirty = nil, true
          commit(ed, win.path)
        end
      end
      if i.clicked[3] then p.curve = nil; ctx.touch() end -- rmb cancels
    elseif paintable and i.clicked[1] and inb then
      p.curve = { x0 = mx, y0 = my, stage = "p3" }
      ctx.touch()
    end

  elseif paintable then
    if inb then
      pal.x_ig_rect(ox + mx * zoom, oy + my * zoom, zoom, zoom, 0xE8E4FF66, 1)
    end
    -- shift = a straight line from the LAST painted pixel (pen / eraser)
    local lineable = g.shift and p.last
                     and (win.tool == "pen" or win.tool == "eraser")
    if lineable and inb then
      pal.x_ig_line(ox + (p.last.x + 0.5) * zoom, oy + (p.last.y + 0.5) * zoom,
                    ox + (mx + 0.5) * zoom, oy + (my + 0.5) * zoom,
                    COL.accent, lt)
    end
    local rmb = i.clicked[3]
    if i.clicked[1] or rmb then
      if win.tool == "pick" then
        local c = paint.get(p.comp, mx, my)
        if c and c ~= 0 then
          if rmb then win.color2 = c else win.color = c end
          ctx.touch()
        end
      elseif win.tool == "fill" then
        if inb then
          paint.flood(cell, mx, my, paintcol(rmb))
          p.last, p.comp_dirty = { x = mx, y = my }, true
          commit(ed, win.path)
        end
      elseif lineable and not rmb then
        paint.line(cell, p.last.x, p.last.y, mx, my, paintcol(false))
        p.last, p.comp_dirty = { x = mx, y = my }, true
        commit(ed, win.path)
      else
        p.stroke = { lx = mx, ly = my, rmb = rmb }
        if inb then paint.set(cell, mx, my, paintcol(rmb)) end
        p.comp_dirty = true
      end
    end
  end
  if p.stroke then
    if i.buttons[p.stroke.rmb and 3 or 1] then
      local nx, ny = pixel_at(i.wx, i.wy)
      if nx ~= p.stroke.lx or ny ~= p.stroke.ly then
        if cell then
          paint.line(cell, p.stroke.lx, p.stroke.ly, nx, ny,
                     paintcol(p.stroke.rmb))
        end
        p.stroke.lx, p.stroke.ly = nx, ny
        p.comp_dirty = true
      end
    else
      p.last = { x = p.stroke.lx, y = p.stroke.ly }
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
    if x + sw > ctx.cx + ctx.cw - 108 * z then break end
    pal.x_ig_rect_fill(x, py0, sw, sw, disp(c), 2 * z)
    if (win.color or 0) == c then
      pal.x_ig_rect(x - 1, py0 - 1, sw + 2, sw + 2, COL.hot, 1, 2 * z)
    end
    local hov = ctx.hot and i.wx >= x and i.wx < x + sw
                and i.wy >= py0 and i.wy < py0 + sw
    if hov and i.clicked[1] then
      win.color = c
      ctx.touch()
    elseif hov and i.clicked[3] then
      win.color2 = c
      ctx.touch()
    end
    n = n + 1
  end
  -- hex ADD field (bottom-right): type #RRGGBB[AA] + Enter to add that color
  -- to the palette (and select it). A live preview swatch + a placeholder make
  -- what it does obvious (the human couldn't tell) — the swatch shows the
  -- parsed color, or a dim "+" while the text isn't a valid hex yet.
  local addw = 100 * z
  local pvw = sw
  local hx = ctx.cx + ctx.cw - addw
  local boxx = hx + pvw + 3 * z
  local boxw = addw - pvw - 3 * z
  local pv = hex_parse(p.hex or "")
  if pv then
    pal.x_ig_rect_fill(hx, py0, pvw, sw, disp(pv), 2 * z)
    pal.x_ig_rect(hx, py0, pvw, sw, COL.accent, 1, 2 * z)
  else
    pal.x_ig_rect_fill(hx, py0, pvw, sw, COL.btn, 2 * z)
    local gw = pal.x_ig_text_size("+", px * 0.9, 1)
    pal.x_ig_text(hx + (pvw - gw) * 0.5, py0 + (sw - px * 0.9) * 0.4, px * 0.9,
                  COL.dim, "+", 1)
  end
  pal.x_ig_rect(boxx, py0, boxw, sw, 0x4a437088, 1, 2 * z)
  if (p.hex or "") == "" then
    pal.x_ig_text(boxx + 3 * z, py0 + (sw - px * 0.8) * 0.45, px * 0.8,
                  0x8a84b088, "#hex adds color", 1)
  end
  if not ctx.occluded then
    local text, _, _, st = pal.x_ig_edit {
      id = "sphex" .. win.id, x = boxx + 2 * z, y = py0 + 1,
      w = boxw - 4 * z, h = sw - 2, text = p.hex or "", px = px * 0.9, font = 1,
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

  -- ---- attached palettes: dragged-in .pal files, stacked, each removable
  -- (the human's ask). Left-click a swatch = primary, right-click = secondary
  local aty = ctx.cy + cvh + 40 * z
  local ssz = math.max(7, 11 * z)
  local remove_idx
  for ai, ppath in ipairs(win.palettes or {}) do
    local rowy = aty + (ai - 1) * ATT_H
    local colors, pname = attached_colors(ed, p, ppath)
    local xw = ATT_H - 4 * z
    if button(i, ctx, sx0, rowy, xw, ATT_H - 3 * z, "×", false, px * 0.85) then
      remove_idx = ai
    end
    local nx = sx0 + xw + 3 * z
    pal.x_ig_clip_push(nx, rowy, 44 * z, ATT_H)
    pal.x_ig_text(nx, rowy + (ATT_H - px * 0.8) * 0.4, px * 0.8, COL.dim,
                  pname, 0)
    pal.x_ig_clip_pop()
    local cx = nx + 46 * z
    for _, c in ipairs(colors) do
      if cx + ssz > ctx.cx + ctx.cw - 4 * z then break end
      local sy = rowy + (ATT_H - ssz) * 0.5
      pal.x_ig_rect_fill(cx, sy, ssz, ssz, disp(c), 1)
      if win.color == c or win.color2 == c then
        pal.x_ig_rect(cx - 1, sy - 1, ssz + 2, ssz + 2, COL.hot, 1)
      end
      local hov = ctx.hot and i.wx >= cx and i.wx < cx + ssz
                  and i.wy >= sy and i.wy < sy + ssz
      if hov and i.clicked[1] then win.color = c; ctx.touch()
      elseif hov and i.clicked[3] then win.color2 = c; ctx.touch() end
      cx = cx + ssz + 2 * z
    end
  end
  if remove_idx then table.remove(win.palettes, remove_idx); ctx.touch() end
end

return M
