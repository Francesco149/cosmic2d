-- cm.ed — the editor shell (R3, EDITOR.md / D050): the infinite canvas +
-- floating windows, drawn entirely from Lua on the pal.x_ig_* drawlist.
--
-- State discipline (EDITOR.md §2 — the R6-critical line):
--   * M.doc  = the CAPTURED editor doc — everything a rewound frame must
--     show (camera, windows, selection, focus, asset working state). Plain
--     data, cm.state.canon-clean, persisted to <project>/.ed/session.dat
--     on a 400 ms debounce. The review test for every new field: "would a
--     rewound frame look wrong without it?"
--   * M.g    = EPHEMERAL gesture state — drag anchors, hover, mod keys,
--     ease bookkeeping, the spawn menu. Dies with the frame, never saved.
-- The sim never reads any of this; the shell never writes sim state. In
-- editor mode the game receives NO input (cm.main feeds it an empty event
-- list) — game-window input synthesis is R4.
--
-- Boot: bin/cosmic <project> --edit (live + --win capture; a no-op under
-- --verify/plain headless — x_ig_frame is nil there, D049 absence
-- contract). While the console overlay is open the shell skips its ig
-- frame entirely so the legacy chrome stays visible + usable (the R3
-- interim story; the console re-hosts as a canvas window at R4).

local M = select(2, ...) or {}
local cam = cm.require("cm.ed.cam")
local wm = cm.require("cm.ed.wm")
local session = cm.require("cm.ed.session")
local ease = cm.require("cm.ease")

M.on = M.on or false
M.root = M.root or nil
M.doc = M.doc or nil
M.g = M.g or {}

M.kinds = {
  note = cm.require("cm.ed.win.note"),
  game = cm.require("cm.ed.win.game"),
  text = cm.require("cm.ed.win.text"),
}

-- the palette (igcanvas's, promoted)
local C = {
  bg = 0x141220ff, grid = 0x3a3560, -- grid alpha applied per zoom
  win = 0x1e1b2eff, win_edge = 0x4a4370ff, win_edge_hot = 0x6a60a0ff,
  hdr = 0x262238ff, title = 0xcfc8ffff, title_dim = 0x8a84b0ff,
  sel = 0x7fd8a8ff, marquee = 0x7fd8a8aa, focus_edge = 0x8878d0ff,
  hud = 0xE8E4FFff, hud_dim = 0x8a84b0ff, pill = 0x262238ee,
  menu = 0x1e1b2ef2, menu_hot = 0x3a3560ff, unsaved = 0xffb46eff,
}

local HDR = 24 -- header strip height, world units
local K = { escape = 41, lbracket = 47, rbracket = 48, space = 44,
            n1 = 30, n2 = 31, n0 = 39, right = 79, left = 80,
            down = 81, up = 82, s = 22, z = 29, y = 28,
            f1 = 58, f2 = 59, f3 = 60, f4 = 61 }

-- ---- boot ----

local function fresh_doc()
  local doc = wm.init({ v = 1, cam = cam.new() })
  local gw, gh = pal.gfx_size()
  wm.spawn(doc, "game", 40, 40, gw, gh + HDR)
  local n = wm.spawn(doc, "note", gw + 80, 40, 280, 220)
  n.text = "welcome to the editor shell (R3).\n\n" ..
           "wheel  zoom at cursor\ndrag   pan the canvas\n" ..
           "alt+click   select a window\nalt+drag    move it\n" ..
           "alt+rclick  close it (never loses work)\n" ..
           "edges       drag to resize\nrclick      spawn menu"
  doc.sel, doc.focus = {}, 0
  return doc
end

function M.launch(root)
  M.root = root
  M.doc = session.load(root)
  if M.doc then
    wm.init(M.doc)
    M.doc.cam = M.doc.cam or cam.new()
  else
    M.doc = fresh_doc()
  end
  M.on = true
  cm.require("cm.view").mode = "canvas" -- no game blit; we draw the target
  pal.log("[ed] editor shell on (" .. root .. ")")
end

function M.touch() -- a captured-doc mutation: arm the session debounce
  M.g.save_due = pal.time_ns() + session.DEBOUNCE_NS
end

local function save_now()
  if M.doc and M.root then session.save(M.root, M.doc) end
  M.g.save_due = nil
end

-- ---- input ----

local function track_mods(keys)
  local g = M.g
  for _, e in ipairs(keys) do
    local sc = e.scancode
    if sc == 226 or sc == 230 then g.alt = e.down
    elseif sc == 224 or sc == 228 then g.ctrl = e.down
    elseif sc == 225 or sc == 229 then g.shift = e.down
    elseif sc == K.space then g.space = e.down end
  end
end

-- the legacy panel toggles (F1 editor / F2 studio / F3 perf / F4 scrub) and
-- the options-menu Esc would fire invisibly under the canvas — strip them
-- after the shell has had its look. The console grave stays live (§8).
local function consume_legacy_keys(keys)
  for i = #keys, 1, -1 do
    local sc = keys[i].scancode
    if sc == K.f1 or sc == K.f2 or sc == K.f3 or sc == K.f4
       or sc == K.escape then
      table.remove(keys, i)
    end
  end
end

local function anim_to(target)
  M.g.anim = { from = { x = M.doc.cam.x, y = M.doc.cam.y,
                        zoom = M.doc.cam.zoom },
               to = target, t0 = pal.time_ns() }
end

local function step_anim()
  local a = M.g.anim
  if not a then return end
  local t = (pal.time_ns() - a.t0) / (cam.EASE_MS * 1e6)
  local c = cam.lerp(a.from, a.to, ease.quart_inout(t))
  M.doc.cam.x, M.doc.cam.y, M.doc.cam.zoom = c.x, c.y, c.zoom
  if t >= 1.0 then M.g.anim = nil end
  M.touch()
end

-- the focused window's asset commands (EDITOR.md §6): resolve the focused
-- kind and call its hook when it has one
local function kind_call(fn)
  local win = wm.get(M.doc, M.doc.focus)
  local kind = win and M.kinds[win.kind]
  if kind and kind[fn] then kind[fn](win, M) end
end

local function hotkeys(ig, i)
  local doc, g = M.doc, M.g
  if ig.kb then return end -- an edit widget owns the keyboard
  for _, e in ipairs(i.keys) do
    if e.down and not e.rep then
      local sc = e.scancode
      if g.ctrl and sc == K.s then kind_call("save")
      elseif g.ctrl and sc == K.y then kind_call("redo")
      elseif g.ctrl and g.shift and sc == K.z then kind_call("redo")
      elseif g.ctrl and sc == K.z then kind_call("undo")
      elseif sc == K.escape then
        if g.menu then g.menu = nil
        elseif doc.drill ~= 0 then doc.drill = 0
        else doc.sel = {} end
        M.touch()
      elseif sc == K.rbracket then
        for _, id in ipairs(doc.sel) do
          if g.shift then wm.to_front(doc, id) else wm.raise(doc, id) end
        end
        M.touch()
      elseif sc == K.lbracket then
        for _, id in ipairs(doc.sel) do
          if g.shift then wm.to_back(doc, id) else wm.lower(doc, id) end
        end
        M.touch()
      elseif g.shift and (sc == K.n1 or sc == K.n2 or sc == K.n0) then
        local t
        if sc == K.n0 then
          t = cam.at_100(doc.cam, ig.w, ig.h)
        else
          local x, y, w, h
          if sc == K.n1 then x, y, w, h = wm.all_bounds(doc)
          else x, y, w, h = wm.sel_bounds(doc) end
          if x then t = cam.fit(x, y, w, h, ig.w, ig.h) end
        end
        if t then anim_to(t) end
      elseif sc >= K.right and sc <= K.up and #doc.sel > 0 then
        local d = g.shift and 10 or 1
        local dx = (sc == K.right and d) or (sc == K.left and -d) or 0
        local dy = (sc == K.down and d) or (sc == K.up and -d) or 0
        wm.move_sel(doc, dx, dy)
        M.touch()
      end
    end
  end
end

local function interact(ig)
  local i = cm.require("cm.ui").inp
  local doc, g = M.doc, M.g
  track_mods(i.keys)
  hotkeys(ig, i)
  consume_legacy_keys(i.keys)
  step_anim()

  -- wheel zoom at the cursor (unless an edit widget wants the mouse)
  if i.wheel ~= 0 and not ig.mouse then
    g.anim = nil
    cam.zoom_at(doc.cam, i.wx, i.wy, cam.wheel_factor(i.wheel))
    M.touch()
  end

  local wwx, wwy = cam.s2w(doc.cam, i.wx, i.wy)
  g.cursor = { wx = wwx, wy = wwy } -- draw-side hover reuse

  -- the spawn menu owns clicks while open (draw() hit-tests it)
  if g.menu then return end

  -- pan gestures continue regardless of what's under the cursor
  if g.pan then
    if i.buttons[g.pan.b] then
      doc.cam.x = g.pan.cx - (i.wx - g.pan.sx) / doc.cam.zoom
      doc.cam.y = g.pan.cy - (i.wy - g.pan.sy) / doc.cam.zoom
      M.touch()
    else
      -- a right-drag that never left the click threshold = the spawn menu
      if g.pan.b == 3 and not g.pan.moved then
        g.menu = { sx = i.wx, sy = i.wy, wx = wwx, wy = wwy }
      end
      g.pan = nil
    end
    if g.pan and (math.abs(i.wx - g.pan.sx) > wm.DRAG_PX
                  or math.abs(i.wy - g.pan.sy) > wm.DRAG_PX) then
      g.pan.moved = true
    end
    return
  end

  -- the grammar (ALT layer + edge resize); true = wm owns the mouse
  local inp = {
    wx = wwx, wy = wwy, sx = i.wx, sy = i.wy,
    band = wm.EDGE_PX / doc.cam.zoom, alt = g.alt or false,
    down1 = i.buttons[1] or false, down3 = i.buttons[3] or false,
    clicked1 = i.clicked[1] or false, clicked3 = i.clicked[3] or false,
  }
  local owned = wm.update(doc, g, inp)
  if g.changed then
    g.changed = nil
    M.touch()
  end
  if owned or (ig.mouse and not g.alt) then return end

  -- empty canvas (or middle button / space anywhere): pan; right = pan or
  -- the spawn menu on a still-click
  local over = wm.hit(doc, wwx, wwy, inp.band)
  local b = (i.clicked[2] and 2) or (i.clicked[3] and 3)
            or (i.clicked[1] and (g.space or not over) and 1) or nil
  if b and (b ~= 1 or not over) or (b and g.space) then
    g.pan = { b = b, sx = i.wx, sy = i.wy,
              cx = doc.cam.x, cy = doc.cam.y }
    g.anim = nil
  end
end

-- ---- drawing ----

local function grid(ig)
  local doc = M.doc
  local z = doc.cam.zoom
  local step, alpha = cam.grid(z)
  local col = (C.grid << 8) | math.floor(alpha * 255 + 0.5)
  local x0, y0 = cam.s2w(doc.cam, 0, 0)
  local gx, gy = (x0 // step) * step, (y0 // step) * step
  local r = math.min(2, math.max(1, z))
  local nx, ny = ig.w / (step * z) + 1, ig.h / (step * z) + 1
  for ix = 0, nx do
    for iy = 0, ny do
      local sx, sy = cam.w2s(doc.cam, gx + ix * step, gy + iy * step)
      pal.x_ig_circle_fill(sx, sy, r, col)
    end
  end
end

-- imgui widgets (x_ig_edit) always render ABOVE the background drawlist,
-- whatever our canvas z says — so a window overlapped by a higher one must
-- not submit a live widget or its text bleeds through the window on top.
-- Occluded windows draw their text inert instead (they're behind anyway,
-- so inert is also the correct look). The full interleaved-z story is the
-- R4 code-ed design; this rule keeps R3 overlap honest.
local function occluded(doc, i)
  local w = doc.wins[i]
  for j = i + 1, #doc.wins do
    local o = doc.wins[j]
    if o.x < w.x + w.w and o.x + o.w > w.x
       and o.y < w.y + w.h and o.y + o.h > w.y then
      return true
    end
  end
  return false
end

local function draw_win(ig, win, zi)
  local doc, g = M.doc, M.g
  local z = doc.cam.zoom
  local x, y = cam.w2s(doc.cam, win.x, win.y)
  local w, h = win.w * z, win.h * z
  local hdr = HDR * z
  local kind = M.kinds[win.kind]
  local selected = wm.selected(doc, win.id)
  local focused = doc.focus == win.id

  -- hover on the resize band brightens the border (the affordance)
  local hot = false
  if g.cursor and not g.alt and g.state == nil then
    local id, part = wm.hit(doc, g.cursor.wx, g.cursor.wy, wm.EDGE_PX / z)
    hot = id == win.id and part ~= "content"
  end

  pal.x_ig_rect_fill(x, y, w, h, C.win, 6 * z)
  pal.x_ig_rect_fill(x, y, w, math.min(hdr, h), C.hdr, 6 * z)
  local edge = hot and C.win_edge_hot or (focused and C.focus_edge or C.win_edge)
  pal.x_ig_rect(x, y, w, h, edge, math.max(1, z), 6 * z)
  if selected then
    pal.x_ig_rect(x - 2, y - 2, w + 4, h + 4, C.sel, math.max(1, 1.5 * z), 8 * z)
  end

  -- header: title label (never a drag handle — EDITOR.md §4) + unsaved dot
  local tpx = math.max(4, 12 * z)
  local title = kind and kind.title(win) or win.kind
  pal.x_ig_clip_push(x, y, w, math.min(hdr, h))
  pal.x_ig_text(x + 8 * z, y + (hdr - tpx) * 0.45,
                tpx, focused and C.title or C.title_dim, title, 0)
  pal.x_ig_clip_pop()
  if kind and kind.dirty and kind.dirty(win, M) then
    pal.x_ig_circle_fill(x + w - 10 * z, y + hdr * 0.5, 3.5 * z, C.unsaved)
    -- the reset-to-saved button (EDITOR.md §6 — itself an undoable edit)
    if kind.revert and w > 120 * z then
      local rw = pal.x_ig_text_size("reset", tpx * 0.85, 0)
      local rx = x + w - 18 * z - rw
      local i = cm.require("cm.ui").inp
      local hov = not g.alt and i.wx >= rx - 4 * z and i.wx < x + w - 16 * z
                  and i.wy >= y and i.wy < y + hdr
      pal.x_ig_text(rx, y + (hdr - tpx * 0.85) * 0.45, tpx * 0.85,
                    hov and C.hud or C.title_dim, "reset", 0)
      if hov and i.clicked[1] then kind.revert(win, M) end
    end
  end

  -- content
  if kind and h > hdr + 2 then
    local ctx = {
      ig = ig, z = z, alt = g.alt or false, doc = doc, ed = M,
      focused = focused, touch = M.touch, occluded = occluded(doc, zi),
      cx = x + z, cy = y + hdr, cw = w - 2 * z, ch = h - hdr - z,
    }
    pal.x_ig_clip_push(ctx.cx, ctx.cy, ctx.cw, ctx.ch)
    kind.draw(win, ctx)
    pal.x_ig_clip_pop()
  end
end

local MENU_ITEMS = { { "note", "note" }, { "text", "open file…" },
                     { "game", "game window" } }

local function draw_menu(ig, i)
  local g = M.g
  local m = g.menu
  if not m then return end
  local iw, ih, pad = 150, 26, 6
  local mh = #MENU_ITEMS * ih + pad * 2
  local mx = math.min(m.sx, ig.w - iw - 8)
  local my = math.min(m.sy, ig.h - mh - 8)
  pal.x_ig_overlay(true)
  pal.x_ig_rect_fill(mx, my, iw, mh, C.menu, 8)
  pal.x_ig_rect(mx, my, iw, mh, C.win_edge, 1, 8)
  local clicked_inside = false
  for n, item in ipairs(MENU_ITEMS) do
    local y = my + pad + (n - 1) * ih
    local hov = i.wx >= mx and i.wx < mx + iw and i.wy >= y and i.wy < y + ih
    if hov then pal.x_ig_rect_fill(mx + 3, y, iw - 6, ih, C.menu_hot, 5) end
    pal.x_ig_text(mx + 14, y + 5, 14, hov and C.hud or C.title_dim, item[2], 0)
    if hov and i.clicked[1] then
      clicked_inside = true
      local kind = M.kinds[item[1]]
      local extra, dw, dh = kind.defaults()
      dw = dw or kind.DEF_W or 260
      dh = (dh or kind.DEF_H or 180) + (item[1] == "game" and 0 or 0)
      wm.spawn(M.doc, item[1], m.wx, m.wy, dw, dh, extra)
      g.menu = nil
      M.touch()
    end
  end
  pal.x_ig_overlay(false)
  if i.clicked[1] and not clicked_inside then g.menu = nil end
end

local function draw_hud(ig)
  local doc = M.doc
  pal.x_ig_overlay(true)
  -- project pill, top-left
  local label = ("ed — %s"):format(M.root or "?")
  local lw = pal.x_ig_text_size(label, 15, 0)
  pal.x_ig_rect_fill(10, 8, lw + 24, 28, C.pill, 8)
  pal.x_ig_text(22, 13, 15, C.hud, label, 0)
  -- zoom pill, top-right — offset left: the corner is reserved for the R6
  -- rewind pill (EDITOR.md §3)
  local zs = ("%d%%"):format(math.floor(doc.cam.zoom * 100 + 0.5))
  local zw = pal.x_ig_text_size(zs, 15, 1)
  pal.x_ig_rect_fill(ig.w - zw - 24 - 110, 8, zw + 24, 26, C.pill, 8)
  pal.x_ig_text(ig.w - zw - 12 - 110, 12, 15, C.hud, zs, 1)
  -- hint pill, bottom-left
  local hint = "alt+click select · alt+drag move · alt+rclick close · " ..
               "edges resize · rclick menu · ]/[ front/back · shift+1 fit"
  local hw = pal.x_ig_text_size(hint, 11, 0)
  pal.x_ig_rect_fill(10, ig.h - 32, hw + 20, 24, C.pill, 8)
  pal.x_ig_text(20, ig.h - 27, 11, C.hud_dim, hint, 0)
  pal.x_ig_overlay(false)
end

local function draw(ig)
  local doc, g = M.doc, M.g
  local i = cm.require("cm.ui").inp
  pal.x_ig_rect_fill(0, 0, ig.w, ig.h, C.bg)
  grid(ig)
  for zi, win in ipairs(doc.wins) do draw_win(ig, win, zi) end
  if g.state == "marquee" then
    local x0, y0 = cam.w2s(doc.cam, g.mx0, g.my0)
    local x1, y1 = cam.w2s(doc.cam, g.mx1, g.my1)
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    pal.x_ig_rect_fill(x0, y0, x1 - x0, y1 - y0, 0x7fd8a818)
    pal.x_ig_rect(x0, y0, x1 - x0, y1 - y0, C.marquee, 1)
  end
  draw_menu(ig, i)
  draw_hud(ig)
end

-- ---- the frame (called from cm.main after game.draw) ----

function M.frame()
  if not M.on then return end
  if cm.require("cm.console").open then
    -- legacy chrome interim (EDITOR.md §8): console open = no ig frame at
    -- all, so the ui-canvas panels are visible and interactive
    return
  end
  local ig = pal.x_ig_frame()
  if not ig then return end
  interact(ig)
  draw(ig)
  if M.g.save_due and pal.time_ns() >= M.g.save_due then save_now() end
  if pal.quitting() then
    M.kinds.text.flush(M) -- pending edit gestures reach their journals
    save_now()
  end
end

return M
