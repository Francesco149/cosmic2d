-- cm.ed.win.tmap — the tilemap window (R8d, MAPS.md §8): the .tm asset
-- as a canvas citizen on the sprite-ed model verbatim. READ-ONLY by
-- default (aspect-fit) with the header edit toggle.
--
-- The working state is the CTLM bytes — doc.assets[path].tm — so the §6
-- EDITOR.md three-layer model applies: dirty = bytes ≠ disk, journal
-- entries are full .tm snapshots (cap 512), one gesture = one entry,
-- Ctrl+Z/Y walk them, revert is an edit, restart survival + rewind
-- (EDOC) for free. The decoded doc + tileset texture are ephemeral
-- plumbing keyed by path (ed.g.tmw).
--
-- v1 roster (§8, deliberately lean): tile palette strip from the bound
-- tileset (a .spr whose FRAMES are the tiles — the baked strip .png is
-- what draws), paint / erase / rect-fill / pick, grid resize (grow/crop
-- fields), tileset retarget field, wheel zoom + middle-drag pan (edit
-- mode; cm.ed.winview world-unit fields). Not v1: autotiling,
-- multi-cell stamps, animated tiles (D057 records the gap).
--
-- Save writes the .tm and bumps cm.asset_epoch (the sprite-save
-- convention): .tm is pure visual, so the running game and any map
-- window re-read their render caches — no recorded EVAL needed.

local M = select(2, ...) or {}
local tmap = cm.require("cm.tmap")
local wv = cm.require("cm.ed.winview")

M.kind = "tmap"
M.help = "win-tmap"
M.menu = "tilemap"
M.exts = { "tm" }
M.DEF_W, M.DEF_H = 460, 380
M.JCAP = 512

local COL = {
  rail = 0x1a1728ff, well = 0x141220ff, btn = 0x262238ff,
  btn_on = 0x4a4370ff, btn_hot = 0x3a3560ff,
  text = 0xd8d2f2ff, dim = 0x8a84b0ff, hot = 0xE8E4FFff,
  accent = 0x7fd8a8ff, danger = 0xf07a7aff, bounds = 0x4a4370ff,
  grid = 0x4a437055, sel = 0x7fd8a8ff,
  checker_a = 0x232030ff, checker_b = 0x2b2838ff,
}

local TOOLS = { { "pen", "P" }, { "eraser", "E" }, { "fill", "F" },
                { "pick", "K" } }

function M.defaults()
  return { path = "", edit = false, tool = "pen", tid = 1 }
end

-- per-window hotkeys (EDITOR.md §13): tool keys mirror the rail chips
-- (edit mode only), shift+1 refits the view
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
  { key = "shift+1", hint = "fit",
    when = function(win) return win.path ~= "" end,
    fn = function(win, ed)
      win.zoom, win.px, win.py = nil, nil, nil
      ed.touch()
    end },
}

function M.title(win)
  local base = win.path:match("([^/]+)$") or "tilemap"
  return base .. (win.edit and "" or "  · view")
end

function M.accepts(win, path)
  return path:lower():find("%.tm$") ~= nil
end

function M.rebind(win, ed, path)
  win.path = path
  win.zoom, win.px, win.py = nil, nil, nil
  ed.touch()
end

-- ---- the asset citizen (cm.ed.kit, R9a) — plumbing on ed.g.tmw[path],
-- working CTLM bytes in doc.assets[path].tm, the §6 contract generated

local function decode_into(p, bytes)
  local ok, doc = pcall(tmap.decode, bytes)
  if ok then
    p.doc = doc
    p.err = nil
  else
    p.doc = nil
    p.err = tostring(doc)
  end
end

local A = cm.require("cm.ed.kit").asset {
  gkey = "tmw", field = "tm", jcap = M.JCAP,
  fresh = function() -- a new tilemap: a fresh empty 16x16 @ 16px grid
    return tmap.encode(tmap.blank(16, 16, 16, ""))
  end,
  adopt = decode_into,
  encode = tmap.encode,
  after_save = function(ed, path)
    -- render-only hot-reload: map windows + the running game re-read
    -- their .tm caches on the epoch (the sprite-save convention, D040)
    cm.asset_epoch = (cm.asset_epoch or 0) + 1
    return "[ed] saved " .. path
  end,
}

local plumb, working, open_asset, commit =
  A.plumb, A.working, A.open_asset, A.commit

M.open_win = A.open_win -- spawn-time adoption (proof scripting too)

-- the §6 focused-window commands (shell kind_call dispatch)
M.dirty, M.save, M.undo, M.redo, M.revert =
  A.dirty, A.save, A.undo, A.redo, A.revert

-- Esc: cancel the live gesture (a mutating stroke re-adopts the
-- committed bytes); the shell's cascade unfocuses after that
function M.escape(win, ed)
  local p = ed.g.tmw and ed.g.tmw[win.path]
  if not (p and p.g) then return false end
  if p.g.mutates then
    decode_into(p, working(ed, win.path).tm)
  end
  p.g = nil
  ed.touch()
  return true
end

-- ---- header: the edit toggle (the sprite ed's, verbatim) ----

function M.header(win, ctx)
  local s = cm.require("cm.ed.chips").strip(ctx)
  if s:chip(win.edit and "done" or "edit", win.edit) then
    win.edit = not win.edit
    ctx.ed.touch()
  end
  return s.used
end

-- ---- view helpers ----

-- focused = the view lock (the map/sprite model, generalized —
-- kit.viewlock installs own_view/wheel/takes_middle): an edit-mode
-- tilemap window owns wheel + middle-drag only WHILE FOCUSED;
-- unfocused = inert view. View mode never locks.
cm.require("cm.ed.kit").viewlock(M, {
  gkey = "tmw", rect = "canvas_rect",
  lock = function(win) return win.edit == true and (win.path or "") ~= "" end,
})

-- the tileset strip texture (ed-root baked .png sibling; a raw .png
-- tileset draws directly). Epoch-aware: a sprite-ed save of the tileset
-- re-reads the strip on the next frame. Shared with the map window's
-- .tm placement draw (p is any plumbing table; ts_ep lives on it).
function M.tileset_tex(ed, p, tsp)
  if not tsp or tsp == "" then return nil end
  local png = tsp:lower():find("%.png$") and tsp
              or tsp:gsub("%.[sS][pP][rR]$", ".png")
  if not png:lower():find("%.png$") then return nil end
  local ep = cm.asset_epoch or 0
  local reload = p.ts_ep ~= nil and p.ts_ep ~= ep or nil
  p.ts_ep = ep
  local ok, t = pcall(cm.require("cm.gfx").texture, ed.root .. "/" .. png,
                      reload)
  if ok then return t end
end

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

-- draw the doc's visible cells into the view (screen coords); the
-- window-side mirror of cm.tmap.draw (the drawlist wants per-image
-- calls, not the bulk buffer). view = { zoom, ox, oy } in screen px —
-- the map window offsets ox/oy by the placement to reuse this.
function M.draw_cells(doc, tex, view, cvx, cvy, cvw, cvh)
  local t = doc.tile
  local zoom, ox, oy = view.zoom, view.ox, view.oy
  local c0 = math.max(0, math.floor((cvx - ox) / (t * zoom)))
  local c1 = math.min(doc.w - 1, math.ceil((cvx + cvw - ox) / (t * zoom)))
  local r0 = math.max(0, math.floor((cvy - oy) / (t * zoom)))
  local r1 = math.min(doc.h - 1, math.ceil((cvy + cvh - oy) / (t * zoom)))
  local tw, th = tex.w, tex.h
  for r = r0, r1 do
    for c = c0, c1 do
      local id = tmap.get(doc, c, r)
      if id ~= 0 and id * t <= tw then
        pal.x_ig_image(tex.id, ox + c * t * zoom, oy + r * t * zoom,
                       t * zoom, t * zoom, (id - 1) * t / tw, 0,
                       id * t / tw, t / th)
      end
    end
  end
end

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

-- ---- content ----

function M.draw(win, ctx)
  local ed = ctx.ed
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local i = cm.require("cm.ui").inp

  -- unbound: the kit's new-file prompt (forced .tm, overwrite-aware)
  if win.path == "" then
    local was = win.path
    A.pathfield(win, ed, ctx, {
      ext = "tm", default = "maps/",
      label = "no tilemap bound — drag a .tm here, or type a path:",
    })
    if win.path ~= was then win.edit = true end -- fresh .tm opens editable
    return
  end

  local a, p = open_asset(ed, win.path)
  if p.err or not p.doc then
    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, COL.danger,
                  "unreadable .tm: " .. tostring(p.err), 0)
    return
  end
  local doc = p.doc
  local t = doc.tile
  local W, H = doc.w * t, doc.h * t
  local tex = M.tileset_tex(ed, p, doc.tileset)
  local ntiles = tex and math.max(0, tex.w // t) or 0

  -- ---- read-only: aspect-fit view ----
  if not win.edit then
    checker(ctx.cx, ctx.cy, ctx.cw, ctx.ch, z)
    local m = 4 * z
    local s = math.min((ctx.cw - 2 * m) / W, (ctx.ch - 2 * m) / H)
    local view = { zoom = s, ox = ctx.cx + (ctx.cw - W * s) * 0.5,
                   oy = ctx.cy + (ctx.ch - H * s) * 0.5 }
    if tex then
      M.draw_cells(doc, tex, view, ctx.cx, ctx.cy, ctx.cw, ctx.ch)
    end
    pal.x_ig_rect(view.ox - 1, view.oy - 1, W * s + 2, H * s + 2,
                  COL.bounds, 1)
    local info = ("%dx%d cells · %dpx · %s"):format(doc.w, doc.h, t,
      doc.tileset ~= "" and doc.tileset or "no tileset")
    pal.x_ig_text(ctx.cx + 6 * z, ctx.cy + ctx.ch - px * 1.4, px * 0.9,
                  COL.dim, info, 1)
    return
  end

  -- ---- edit mode layout: tools rail · canvas · palette + fields ----
  local TR = 26 * z
  local PB = 18 * z -- palette strip
  local FB = math.max(10, 20 * z) -- fields row
  local cvx, cvy = ctx.cx + TR, ctx.cy
  local cvw, cvh = ctx.cw - TR, ctx.ch - PB - FB - 4 * z
  if cvw < 40 or cvh < 40 then return end

  -- tools rail
  pal.x_ig_rect_fill(ctx.cx, ctx.cy, TR - 3 * z, cvh, COL.rail, 4 * z)
  local ty = ctx.cy + 4 * z
  for _, tl in ipairs(TOOLS) do
    if button(i, ctx, ctx.cx + 3 * z, ty, TR - 9 * z, TR - 9 * z, tl[2],
              win.tool == tl[1], px) then
      win.tool = tl[1]
      ctx.touch()
    end
    ty = ty + TR - 5 * z
  end
  -- current tile swatch at the rail bottom
  local swr = TR - 9 * z
  local swx, swy = ctx.cx + 3 * z, ctx.cy + cvh - TR + 2 * z
  pal.x_ig_rect_fill(swx, swy, swr, swr, COL.well, 3 * z)
  if tex and (win.tid or 0) >= 1 and win.tid * t <= tex.w then
    pal.x_ig_image(tex.id, swx, swy, swr, swr, (win.tid - 1) * t / tex.w,
                   0, win.tid * t / tex.w, t / tex.h)
  end
  pal.x_ig_rect(swx, swy, swr, swr, 0x00000066, 1, 3 * z)

  -- the canvas, via cm.ed.winview (world-unit captured fields)
  checker(cvx, cvy, cvw, cvh, z)
  local view = wv.view(win, z, cvx, cvy, cvw, cvh, W, H, 4)
  local zoom, ox, oy = view.zoom, view.ox, view.oy
  p.canvas_rect = view
  pal.x_ig_clip_push(cvx, cvy, cvw, cvh)
  pal.x_ig_rect_fill(ox, oy, W * zoom, H * zoom, COL.well)
  if tex then
    M.draw_cells(doc, tex, view, cvx, cvy, cvw, cvh)
  else
    pal.x_ig_text(ox + 4, oy + 4, px, COL.danger,
                  doc.tileset == "" and "no tileset — set one below"
                  or "tileset strip unreadable: " .. doc.tileset, 0)
  end
  -- tile grid (legible zooms only) + bounds
  if t * zoom >= 5 then
    for c = 1, doc.w - 1 do
      pal.x_ig_line(ox + c * t * zoom, oy, ox + c * t * zoom, oy + H * zoom,
                    COL.grid, 1)
    end
    for r = 1, doc.h - 1 do
      pal.x_ig_line(ox, oy + r * t * zoom, ox + W * zoom, oy + r * t * zoom,
                    COL.grid, 1)
    end
  end
  pal.x_ig_rect(ox - 1, oy - 1, W * zoom + 2, H * zoom + 2, COL.bounds, 1)

  local over = ctx.hot and i.wx >= cvx and i.wx < cvx + cvw
               and i.wy >= cvy and i.wy < cvy + cvh
  local cellx = math.floor((i.wx - ox) / (t * zoom))
  local celly = math.floor((i.wy - oy) / (t * zoom))
  local inmap = cellx >= 0 and cellx < doc.w and celly >= 0 and celly < doc.h

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

  -- hover cell outline
  if over and inmap and not p.pan then
    pal.x_ig_rect(ox + cellx * t * zoom, oy + celly * t * zoom,
                  t * zoom, t * zoom, 0xE8E4FF66, 1)
  end

  -- tool gestures (one gesture = one journal entry)
  local function apply_cell(cx2, cy2)
    local id = win.tool == "eraser" and 0 or (win.tid or 1)
    if tmap.get(doc, cx2, cy2) ~= id then
      tmap.set(doc, cx2, cy2, id)
      return true
    end
  end
  if p.g then
    local gd = p.g
    if gd.mode == "stroke" then
      if i.buttons[1] then
        if inmap and (cellx ~= gd.lx or celly ~= gd.ly) then
          gd.lx, gd.ly = cellx, celly
          if apply_cell(cellx, celly) then gd.moved = true end
          ctx.touch()
        end
      else
        p.g = nil
        if gd.moved then commit(ed, win.path) end
      end
    elseif gd.mode == "frect" then
      local x0, x1 = math.min(gd.x0, cellx), math.max(gd.x0, cellx)
      local y0, y1 = math.min(gd.y0, celly), math.max(gd.y0, celly)
      pal.x_ig_rect(ox + x0 * t * zoom, oy + y0 * t * zoom,
                    (x1 - x0 + 1) * t * zoom, (y1 - y0 + 1) * t * zoom,
                    COL.sel, math.max(1, 1.2 * z))
      if not i.buttons[1] then
        p.g = nil
        tmap.fill_rect(doc, gd.x0, gd.y0, cellx, celly,
                       win.tool == "eraser" and 0 or (win.tid or 1))
        commit(ed, win.path)
      end
    end
  elseif over and inmap and i.clicked[1] and not p.pan then
    if win.tool == "pick" then
      local id = tmap.get(doc, cellx, celly)
      if id ~= 0 then
        win.tid = id
        ctx.touch()
      end
    elseif win.tool == "fill" then
      p.g = { mode = "frect", x0 = cellx, y0 = celly }
    else -- pen / eraser
      p.g = { mode = "stroke", lx = cellx, ly = celly, mutates = true,
              moved = apply_cell(cellx, celly) or false }
      ctx.touch()
    end
  end

  -- zoom chip
  local chip = ("%d%%"):format(math.floor(zoom * 100 + 0.5))
  local cw2 = pal.x_ig_text_size(chip, px * 0.85, 0)
  pal.x_ig_text(cvx + cvw - cw2 - 6 * z, cvy + 4 * z, px * 0.85, COL.dim,
                chip, 0)

  -- the focus lock, unmissable (the map window's EDITING-chip idiom)
  if ctx.focused and win.edit then
    pal.x_ig_rect(cvx + 1, cvy + 1, cvw - 2, cvh - 2, COL.hot,
                  math.max(1, 1.5 * z), 3 * z)
    local fl = "EDITING — wheel/mmb here · esc out"
    local fpx = math.max(4, 10 * z)
    local fw2 = pal.x_ig_text_size(fl, fpx, 0)
    pal.x_ig_rect_fill(cvx + 4 * z, cvy + 4 * z, fw2 + 10 * z, fpx * 1.5,
                       0x7fd8a8cc, 4 * z)
    pal.x_ig_text(cvx + 9 * z, cvy + 4 * z + fpx * 0.22, fpx, 0x10241aff,
                  fl, 0)
  end
  pal.x_ig_clip_pop()

  -- ---- the palette strip: the tileset's frames as tiles ----
  local py0 = ctx.cy + cvh + 2 * z
  local sw = PB - 2 * z
  if tex and ntiles > 0 then
    local x = ctx.cx + 2 * z
    for id = 1, ntiles do
      if x + sw > ctx.cx + ctx.cw - 2 * z then break end
      pal.x_ig_rect_fill(x, py0, sw, sw, COL.well, 2 * z)
      pal.x_ig_image(tex.id, x, py0, sw, sw, (id - 1) * t / tex.w, 0,
                     id * t / tex.w, t / tex.h)
      if (win.tid or 0) == id then
        pal.x_ig_rect(x - 1, py0 - 1, sw + 2, sw + 2, COL.hot, 1, 2 * z)
      end
      local hov = ctx.hot and i.wx >= x and i.wx < x + sw
                  and i.wy >= py0 and i.wy < py0 + sw
      if hov and i.clicked[1] then
        win.tid = id
        if win.tool == "eraser" then win.tool = "pen" end
        ctx.touch()
      end
      x = x + sw + 2 * z
    end
  else
    pal.x_ig_text(ctx.cx + 4 * z, py0 + (PB - px) * 0.4, px * 0.9, COL.dim,
                  "no tiles — bind a tileset (.spr with frames as tiles)", 0)
  end

  -- ---- the fields row: w / h (grow/crop) · tile px · tileset ----
  local iy = py0 + PB + 2 * z
  local function field(id, label, val, x, w)
    pal.x_ig_text(x, iy + (FB - px) * 0.45, px * 0.9, COL.dim, label, 0)
    local lx = x + pal.x_ig_text_size(label, px * 0.9, 0) + 3 * z
    pal.x_ig_rect(lx, iy + 1, w, FB - 2, 0x4a437088, 1, 2 * z)
    if ctx.occluded then
      pal.x_ig_text(lx + 2 * z, iy + (FB - px) * 0.45, px * 0.9, COL.text,
                    val, 1)
      return nil, lx + w + 6 * z
    end
    local text, _, _, st = pal.x_ig_edit {
      id = id .. win.id, x = lx + 1, y = iy + 2, w = w - 2, h = FB - 4,
      text = val, px = px * 0.9, font = 1, enter = true, multiline = false,
    }
    return (st and st.submit) and text or nil, lx + w + 6 * z
  end
  local x = ctx.cx + 2 * z
  local got
  got, x = field("tmw", "w", tostring(doc.w), x, 30 * z)
  if got and tonumber(got) and math.floor(tonumber(got)) >= 1 then
    tmap.resize(doc, math.floor(tonumber(got)), doc.h)
    commit(ed, win.path)
  end
  got, x = field("tmh", "h", tostring(doc.h), x, 30 * z)
  if got and tonumber(got) and math.floor(tonumber(got)) >= 1 then
    tmap.resize(doc, doc.w, math.floor(tonumber(got)))
    commit(ed, win.path)
  end
  got, x = field("tmt", "tile", tostring(t), x, 30 * z)
  if got and tonumber(got) and math.floor(tonumber(got)) >= 1 then
    doc.tile = math.floor(tonumber(got))
    commit(ed, win.path)
  end
  local tw2 = math.max(40 * z, ctx.cx + ctx.cw - x - 8 * z)
  got, x = field("tmts", "tileset", doc.tileset or "", x, tw2)
  if got then
    doc.tileset = got
    p.ts_ep = nil -- re-resolve the strip
    commit(ed, win.path)
  end
end

return M
