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
  console = cm.require("cm.ed.win.console"),
  assets = cm.require("cm.ed.win.assets"),
  image = cm.require("cm.ed.win.image"),
  sprite = cm.require("cm.ed.win.sprite"),
  map = cm.require("cm.ed.win.map"),
}

-- new code windows open at the size you've made your current one
-- (human, UX round 6): the focused text window's size, else the topmost
-- text window's, else the kind default
function M.text_spawn_size()
  local doc = M.doc
  local fw = doc and wm.get(doc, doc.focus)
  if fw and fw.kind == "text" then return fw.w, fw.h end
  if doc then
    for i = #doc.wins, 1, -1 do
      local w = doc.wins[i]
      if w.kind == "text" then return w.w, w.h end
    end
  end
  return M.kinds.text.DEF_W, M.kinds.text.DEF_H
end

-- open the right window kind for a file at a world position (double-click
-- and drag-to-canvas in the asset picker, EDITOR.md §12.5)
function M.open_asset_window(path, wx, wy)
  local kname = M.kinds.assets.kind_for(path)
  if not kname or not M.kinds[kname] then
    pal.log("[ed] no window kind for " .. path)
    return
  end
  local kind = M.kinds[kname]
  local dw, dh = kind.DEF_W or 300, kind.DEF_H or 240
  if kname == "text" then dw, dh = M.text_spawn_size() end
  local win = wm.spawn(M.doc, kname, wx, wy, dw, dh, kind.defaults())
  if kname == "text" then
    M.kinds.text.navigate(win, M, path)
  else
    win.path = path
  end
  M.touch()
  return win
end

-- the palette (igcanvas's, promoted)
local C = {
  bg = 0x141220ff, grid = 0x3a3560, -- grid alpha applied per zoom
  win = 0x1e1b2eff, win_edge = 0x4a4370ff, win_edge_hot = 0x6a60a0ff,
  hdr = 0x262238ff, hdr_hot = 0x322d48ff,
  title = 0xcfc8ffff, title_dim = 0x8a84b0ff,
  sel = 0x7fd8a8ff, marquee = 0x7fd8a8aa, focus_edge = 0x8878d0ff,
  hud = 0xE8E4FFff, hud_dim = 0x8a84b0ff, pill = 0x262238ee,
  menu = 0x1e1b2ef2, menu_hot = 0x3a3560ff, unsaved = 0xffb46eff,
}

local HDR = 24 -- header strip height, world units
local K = { escape = 41, lbracket = 47, rbracket = 48, space = 44,
            n1 = 30, n2 = 31, n0 = 39, right = 79, left = 80,
            down = 81, up = 82, f = 9, s = 22, v = 25, z = 29, y = 28,
            f1 = 58, f2 = 59, f3 = 60, f4 = 61, grave = 53 }

-- ---- boot ----

local function fresh_doc()
  local doc = wm.init({ v = 1, cam = cam.new() })
  local gkind = cm.require("cm.ed.win.game")
  local extra, gw, gh = gkind.defaults() -- padded so the image sits 1:1
  wm.spawn(doc, "game", 40, 40, gw, gh, extra)
  local n = wm.spawn(doc, "note", 40 + gw + 40, 40, 280, 220)
  n.text = "welcome to the editor shell (R3).\n\n" ..
           "wheel  zoom at cursor\nmiddle-drag / space  pan\n" ..
           "drag a title bar   move a window\n" ..
           "click/drag canvas  select\n" ..
           "alt+drag    move from anywhere\n" ..
           "alt+rclick  close (never loses work)\n" ..
           "alt+v       selection mode\n" ..
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
  -- a saved game window carries its FOV width choice (§12.3): re-apply
  for _, w in ipairs(M.doc.wins) do
    if w.kind == "game" and w.fw then M.kinds.game.apply_fov(w) end
  end
  pal.log("[ed] editor shell on (" .. root .. ")")
end

function M.touch() -- a captured-doc mutation: arm the session debounce
  -- parked in the past (R6c): the debounce must never fire — session.dat
  -- holds the PRESENT. Interactions still redraw (doc_rev moves).
  if not M.parked then
    M.g.save_due = pal.time_ns() + session.DEBOUNCE_NS
  end
  -- the R6 capture gate (REWIND.md §2): the ring re-encodes the ed doc
  -- only when this rev moved — an idle editor costs the history nothing
  M.doc_rev = (M.doc_rev or 0) + 1
end

-- ---- parking (R6c, REWIND.md §4 — interactive but ephemeral) ----

-- adopt a rewound frame's editor doc; the present is stashed once per
-- park episode. The parked copy is fully interactive — every mutation
-- lands in it and evaporates on the next park()/unpark(false). The
-- per-asset ephemeral plumbing drops wholesale (journals, disk caches,
-- decoded sprites — they key by path and would disagree with the past;
-- they rebuild lazily from whatever doc is current).
function M.park(edoc_bytes)
  if not M.on then return end
  if not M.parked then
    M.g.stash = { doc = M.doc, rev = M.doc_rev }
    M.parked = true
    M.g.save_due = nil -- an armed debounce must not fire on the past
  end
  if edoc_bytes then
    local ok, t = pcall(cm.require("cm.state").parse, edoc_bytes)
    if ok and type(t) == "table" then
      M.doc = wm.init(t)
    else
      pal.log("[ed] parked frame's editor doc unreadable; keeping shown")
    end
  end
  M.g.tw, M.g.sw, M.g.wsy, M.g.conw, M.g.grect = nil, nil, nil, nil, nil
  M.g.hdrx, M.g.wpx = nil, nil
  M.doc_rev = (M.doc_rev or 0) + 1
end

-- bring back the focused asset from the past (R6e, REWIND.md §5 — door
-- two): copy the parked frame's working bytes for the focused window's
-- asset into the PRESENT (the stash), journaled there as one undoable
-- step. Overwrites if it still exists, re-adds if it was closed since.
function M.bring_back()
  if not M.parked then return nil end
  local win = wm.get(M.doc, M.doc.focus)
  if not (win and win.path and win.path ~= "") then return nil end
  local path = win.path
  local parked_a = M.doc.assets and M.doc.assets[path]
  if not parked_a then return nil end
  local payload = parked_a.text or parked_a.spr or parked_a.map
  local field = parked_a.text ~= nil and "text"
                or parked_a.spr ~= nil and "spr" or "map"
  if not payload then return nil end
  local journal = cm.require("cm.ed.journal")
  local stash = M.g.stash.doc
  stash.assets = stash.assets or {}
  local pa = stash.assets[path] or { jpos = 0, [field] = "" }
  stash.assets[path] = pa
  pa[field] = payload
  -- the present's journal gets the entry (a deliberate write from the
  -- past — THE door; the parked gates don't apply to it)
  local cap = field == "spr" and M.kinds.sprite.JCAP
              or field == "map" and M.kinds.map.JCAP or nil
  local j = journal.open(M.root, path, pa.jpos > 0 and pa.jpos or nil, cap)
  journal.push(j, payload, 0, pal.time_ns() // 1000000)
  pa.jpos = j.pos
  M.g.stash.rev = (M.g.stash.rev or 0) + 1 -- the present changed under
  -- the stash; unpark's touch() persists it
  pal.log("[ed] brought back " .. path .. " from the past")
  return path
end

-- leave the past. adopt=true (resume-from-frame): the SHOWN doc — pokes
-- included — becomes the present (REWIND.md §4). adopt=false (scrub
-- closed): the stashed present comes back untouched.
function M.unpark(adopt)
  if not M.parked then return end
  if not adopt then
    M.doc = M.g.stash.doc
    M.doc_rev = M.g.stash.rev
  end
  M.g.stash = nil
  M.parked = false
  M.g.tw, M.g.sw, M.g.wsy, M.g.conw, M.g.grect = nil, nil, nil, nil, nil
  M.g.hdrx, M.g.wpx = nil, nil
  M.touch() -- re-arm the session debounce on the (possibly new) present
end

-- the focused window's kind claims the plain keys (game = playing §12.3,
-- map = the select tool's del/arrows §6-R8b): shell plain-key hotkeys
-- suspend either way
local function playing()
  if not M.doc then return nil end
  local win = wm.get(M.doc, M.doc.focus)
  if win and M.kinds[win.kind] and M.kinds[win.kind].wants_keys then
    return win
  end
end

-- ...but only a kind flagged game_input (the game window) feeds the SIM
-- through filter_events; a focused map window never leaks keys to play
local function playing_game()
  local win = playing()
  if win and M.kinds[win.kind].game_input then return win end
end

-- What the game sees in editor mode (cm.main calls this in place of the
-- R3 blanket swallow): nothing — unless a game window is FOCUSED (=
-- playing, §12.3). Then keys pass through, and mouse events over the
-- window's letterboxed image remap wx,wy → FOV px through the rect its
-- draw recorded (1-frame latency). Key/button RELEASES always pass so a
-- key held across a focus change never sticks (the console's old rule).
-- Everything rides cm.input.feed — recorded, replayable input.
function M.filter_events(events)
  if not M.on then return events end
  local win = playing_game()
  local g = M.g
  local live = win and not g.alt and not g.ig_kb
  local rect = win and g.grect and g.grect[win.id]
  local out = {}
  for _, e in ipairs(events) do
    if e.type == "quit" then
      out[#out + 1] = e
    elseif e.type == "key" then
      -- Esc + grave are the shell's (§12.3); releases always pass
      if not e.down then
        out[#out + 1] = e
      elseif live and e.scancode ~= 41 and e.scancode ~= 53 then
        out[#out + 1] = e
      end
    elseif e.type == "motion" or e.type == "button" then
      local pass = e.type == "button" and not e.down -- releases always
      if live and rect and e.wx >= rect.x and e.wx < rect.x + rect.w
         and e.wy >= rect.y and e.wy < rect.y + rect.h then
        pass = true
      end
      if pass then
        if rect and rect.s > 0 then
          e.x = (e.wx - rect.x) / rect.s
          e.y = (e.wy - rect.y) / rect.s
        end
        out[#out + 1] = e
      end
    elseif e.type == "wheel" then
      local i = cm.require("cm.ui").inp
      if live and rect and i.wx >= rect.x and i.wx < rect.x + rect.w
         and i.wy >= rect.y and i.wy < rect.y + rect.h then
        out[#out + 1] = e
        g.wheel_taken = true -- the canvas must not also zoom on it
      end
    elseif e.type == "drop" and M.doc then
      -- an OS file dropped on the window: over an assets window = add to
      -- project (EDITOR.md §12.5); over a map window = add + PLACE at the
      -- drop point (MAPS.md §6); anywhere else is ignored (logged)
      local wwx, wwy = cam.s2w(M.doc.cam, e.wx, e.wy)
      local id = wm.hit(M.doc, wwx, wwy, 0)
      local win = id and wm.get(M.doc, id)
      if win and win.kind == "assets" then
        M.kinds.assets.add_dropped(M, e.path)
      elseif win and M.kinds[win.kind].drop then
        local rel = M.kinds.assets.add_dropped(M, e.path)
        if rel and not M.kinds[win.kind].drop(win, M, rel, e.wx, e.wy) then
          pal.log("[ed] added but not placeable here: " .. rel)
        end
      else
        pal.log("[ed] drop ignored (aim at an assets or map window): "
                .. e.path)
      end
    end
    -- text events never reach the game (it has no text input path)
  end
  return out
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

-- the legacy panel toggles (F1 editor / F3 perf / F4 scrub), the options-
-- menu Esc, and the legacy console grave would fire invisibly under the
-- canvas — strip them after the shell has had its look (the console is a
-- canvas window since R4c; grave is handled in hotkeys()).
local function consume_legacy_keys(keys)
  for i = #keys, 1, -1 do
    local sc = keys[i].scancode
    if sc == K.f1 or sc == K.f2 or sc == K.f3 or sc == K.f4
       or sc == K.escape or sc == K.grave then
      table.remove(keys, i)
    end
  end
end

-- grave: spawn (or focus + front) a console window (EDITOR.md §12.4)
local function summon_console()
  local doc = M.doc
  for _, win in ipairs(doc.wins) do
    if win.kind == "console" then
      doc.focus = win.id
      doc.sel = { win.id }
      wm.to_front(doc, win.id)
      M.touch()
      return
    end
  end
  local ig = M.g.last_ig
  local kind = M.kinds.console
  local w, h = kind.DEF_W, kind.DEF_H
  local cx, cy = doc.cam.x, doc.cam.y
  local sw = ig and ig.w or 1280
  local sh = ig and ig.h or 800
  wm.spawn(doc, "console", cx + (sw / doc.cam.zoom - w) * 0.5,
           cy + (sh / doc.cam.zoom - h) * 0.6, w, h, kind.defaults())
  M.touch()
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

-- Esc offer to the focused kind (find-bar close etc.); true = consumed
local function kind_escape()
  local win = wm.get(M.doc, M.doc.focus)
  local kind = win and M.kinds[win.kind]
  return (kind and kind.escape and kind.escape(win, M)) or false
end

local function hotkeys(ig, i)
  local doc, g = M.doc, M.g
  -- ctrl combos that must fire even while an edit widget owns the
  -- keyboard (UX round 5 — imgui assigns no meaning to these; save and
  -- find are exactly what you reach for mid-typing)
  for _, e in ipairs(i.keys) do
    if e.down and not e.rep and g.ctrl then
      if e.scancode == K.s then kind_call("save")
      elseif e.scancode == K.f then kind_call("find") end
    end
  end
  if ig.kb then return end -- an edit widget owns the keyboard
  local play = playing() -- plain-key hotkeys suspend while a game window
                         -- is focused (§12.3); ALT/Esc/Ctrl stay ours
  for _, e in ipairs(i.keys) do
    if e.down and not e.rep then
      local sc = e.scancode
      if g.ctrl and sc == K.y then kind_call("redo")
      elseif g.ctrl and g.shift and sc == K.z then kind_call("redo")
      elseif g.ctrl and sc == K.z then kind_call("undo")
      elseif sc == K.grave then summon_console()
      elseif g.alt and sc == K.v then
        -- selection mode: the next press can only select, even over a
        -- window; wm disarms it the moment a select lands something
        g.selmode = not g.selmode or nil
      elseif sc == K.escape then
        if g.menu then g.menu = nil
        elseif g.selmode then g.selmode = nil
        elseif kind_escape() then -- the focused kind ate it (find bar)
        elseif cm.require("cm.scrub").paused() then
          cm.require("cm.scrub").close() -- parked: Esc = back to the present
        elseif play then doc.focus = 0 -- the universal "get out" of play
        elseif doc.drill ~= 0 then doc.drill = 0
        else doc.sel = {} end
        M.touch()
      elseif play then -- everything below collides with gameplay keys
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

-- a kind's resize constraint (wm threads it through M.resize): the game
-- window locks aspect + walks the FOV range here (§12.3, live round 3)
local function kind_constrain(win, part, r0, ww, wh, ctrl)
  local kind = M.kinds[win.kind]
  if kind and kind.constrain then
    return kind.constrain(win, part, r0, ww, wh, ctrl)
  end
end

local function interact(ig)
  local i = cm.require("cm.ui").inp
  local doc, g = M.doc, M.g
  track_mods(i.keys)
  -- the ALT layer owns the pointer: gate mouse off imgui in C (widgets
  -- render unchanged — no shimmer — but can never take the A-click).
  -- CTRL gates it too (UX round 4b): ctrl+wheel is the kinds' size dial
  -- and imgui must not also scroll its child on it (bonus: a ctrl+click
  -- link-open no longer moves the widget caret)
  pal.x_ig_mouse(not (g.alt or g.ctrl))
  hotkeys(ig, i)
  consume_legacy_keys(i.keys)
  step_anim()

  g.ig_kb = ig.kb -- filter_events (next tick) must not feed the game while
                  -- an edit widget owns the keyboard
  g.last_ig = ig

  local wwx, wwy = cam.s2w(doc.cam, i.wx, i.wy)
  g.cursor = { wx = wwx, wy = wwy } -- draw-side hover reuse

  -- the wheel (EDITOR.md §12.7): ALT → canvas zoom, always. CTRL → the
  -- hovered kind's size dial (code-ed font, assets preview) when it has
  -- one. Else content that takes it (an edit widget via imgui capture, a
  -- playing game window via filter_events, a kind.wheel hook) — else
  -- canvas zoom.
  if i.wheel ~= 0 and not g.wheel_taken then
    local routed = false
    if g.ctrl and not g.alt then
      local id, part = wm.hit(doc, wwx, wwy, 0)
      local win = id and part == "content" and wm.get(doc, id)
      local kind = win and M.kinds[win.kind]
      if kind and kind.ctrl_wheel then
        kind.ctrl_wheel(win, M, i.wheel)
        routed = true
      end
    elseif not g.alt then
      if ig.mouse then
        routed = true -- an imgui child (code ed scroll) is taking it
      else
        local id, part = wm.hit(doc, wwx, wwy, 0)
        local win = id and part == "content" and wm.get(doc, id)
        local kind = win and M.kinds[win.kind]
        if kind and kind.wheel then
          -- a hook may decline (sprite view mode) — then the canvas zooms
          routed = kind.wheel(win, M, i.wheel) ~= false
        end
      end
    end
    if not routed then
      g.anim = nil
      cam.zoom_at(doc.cam, i.wx, i.wy, cam.wheel_factor(i.wheel))
      M.touch()
    end
  end
  g.wheel_taken = nil

  -- the spawn menu owns clicks while open (draw() hit-tests it)
  if g.menu then return end

  -- the rewind bar owns its rect while shown (draw_rewind hit-tests it)
  if g.rw_bar and i.wx >= g.rw_bar.x and i.wx < g.rw_bar.x + g.rw_bar.w
     and i.wy >= g.rw_bar.y and i.wy < g.rw_bar.y + g.rw_bar.h then
    return
  end

  -- an asset-tile drag in flight (the picker armed it; the shell carries
  -- it, EDITOR.md §12.5): release over an accepting window = rebind, over
  -- empty canvas = open the right kind there
  if g.adrag then
    local d = g.adrag
    if i.buttons[1] then
      if math.abs(i.wx - d.sx) > wm.DRAG_PX
         or math.abs(i.wy - d.sy) > wm.DRAG_PX then
        d.moved = true
      end
    else
      if d.moved then
        local id = wm.hit(doc, wwx, wwy, 0)
        local win = id and wm.get(doc, id)
        local kind = win and M.kinds[win.kind]
        -- kind.drop outranks rebind (MAPS.md §6: place ≠ rebind) — the
        -- map window claims .spr/.png/.tm as placements at the drop point
        if win and kind and kind.drop
           and kind.drop(win, M, d.path, i.wx, i.wy) then
          doc.focus = win.id
          M.touch()
        elseif win and win.id ~= d.from and kind and kind.accepts
           and kind.accepts(win, d.path) then
          kind.rebind(win, M, d.path)
          doc.focus = win.id
          M.touch()
        elseif not win then
          M.open_asset_window(d.path, wwx, wwy)
        end
      end
      g.adrag = nil
    end
    return
  end

  -- pan gestures continue regardless of what's under the cursor
  if g.pan then
    if i.buttons[g.pan.b] then
      doc.cam.x = g.pan.cx - (i.wx - g.pan.sx) / doc.cam.zoom
      doc.cam.y = g.pan.cy - (i.wy - g.pan.sy) / doc.cam.zoom
      M.touch()
    else
      g.pan = nil
    end
    return
  end

  -- a right press in flight: a still-release opens the spawn menu; a
  -- right-drag is nothing (panning is the middle button's, live round 3)
  if g.rpend then
    if math.abs(i.wx - g.rpend.sx) > wm.DRAG_PX
       or math.abs(i.wy - g.rpend.sy) > wm.DRAG_PX then
      g.rpend.moved = true
    end
    if not i.buttons[3] then
      if not g.rpend.moved then
        g.menu = { sx = g.rpend.sx, sy = g.rpend.sy,
                   wx = g.rpend.wx, wy = g.rpend.wy }
      end
      g.rpend = nil
    end
    return
  end

  -- space+drag = the hand tool, from anywhere (teidraw); it outranks the
  -- grammar so a space-press over a window still pans
  if g.space and i.clicked[1] then
    g.pan = { b = 1, sx = i.wx, sy = i.wy, cx = doc.cam.x, cy = doc.cam.y }
    g.anim = nil
    return
  end

  -- a plain press on a title bar moves the window (no modifier, live
  -- round 3): the strip left of the header's button zone (recorded by
  -- draw_win last frame — reset/history/etc. keep their clicks)
  local hdrid
  if i.clicked[1] and not g.alt then
    local hid, hpart = wm.hit(doc, wwx, wwy, 0)
    if hid and hpart == "content" then
      local hw = wm.get(doc, hid)
      if wwy < hw.y + HDR then
        local cut = g.hdrx and g.hdrx[hid]
        if not (cut and i.wx >= cut) then hdrid = hid end
      end
    end
  end

  -- the grammar (ALT layer + edge resize + title move + canvas select);
  -- true = wm owns the mouse
  local inp = {
    wx = wwx, wy = wwy, sx = i.wx, sy = i.wy,
    bo = wm.EDGE_OUT / doc.cam.zoom, bi = wm.EDGE_IN / doc.cam.zoom,
    alt = g.alt or false, ctrl = g.ctrl or false, hdrid = hdrid,
    constrain = kind_constrain,
    down1 = i.buttons[1] or false, down3 = i.buttons[3] or false,
    clicked1 = i.clicked[1] or false, clicked3 = i.clicked[3] or false,
  }
  local owned = wm.update(doc, g, inp)
  if g.changed then
    g.changed = nil
    M.touch()
  end
  if owned then return end

  -- middle button pans EVERYWHERE — even over an imgui-captured code ed
  -- (UX round 5); a kind can still claim it over its content (sprite ed
  -- pans its own view, §12.6). LMB never pans (live round 3 — the naked
  -- canvas selects instead).
  if i.clicked[2] then
    local over, opart = wm.hit(doc, wwx, wwy, 0)
    local mid_taken = false
    if over and opart == "content" and not g.alt then
      local w = wm.get(doc, over)
      local kind = w and M.kinds[w.kind]
      if kind and kind.takes_middle and kind.takes_middle(w) then
        mid_taken = true
      end
    end
    if not mid_taken then
      g.pan = { b = 2, sx = i.wx, sy = i.wy,
                cx = doc.cam.x, cy = doc.cam.y }
      g.anim = nil
    end
    return
  end

  if ig.mouse and not g.alt then return end -- an edit widget owns the rest

  if i.clicked[3] then
    g.rpend = { sx = i.wx, sy = i.wy, wx = wwx, wy = wwy }
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

  -- hover on the resize band: brighten the border + underline the grabbed
  -- edge(s) so the affordance is unmissable (works under ALT too — the
  -- edge wins over the move grammar)
  local hot_part
  if g.cursor and (g.state == nil or g.state == "resize") then
    local id, part = wm.hit(doc, g.cursor.wx, g.cursor.wy,
                            wm.EDGE_OUT / z, wm.EDGE_IN / z)
    if id == win.id and part ~= "content" then hot_part = part end
    if g.state == "resize" and g.target == win.id then hot_part = g.part end
  end

  -- the title strip is a drag handle now (live round 3): cue it on hover
  local hdr_hot = g.state == nil and not hot_part and g.cursor
    and g.cursor.wx >= win.x and g.cursor.wx < win.x + win.w
    and g.cursor.wy >= win.y and g.cursor.wy < win.y + HDR
    and not (g.hdrx and g.hdrx[win.id]
             and cm.require("cm.ui").inp.wx >= g.hdrx[win.id])
  pal.x_ig_rect_fill(x, y, w, h, C.win, 6 * z)
  pal.x_ig_rect_fill(x, y, w, math.min(hdr, h),
                     hdr_hot and C.hdr_hot or C.hdr, 6 * z)
  local edge = hot_part and C.win_edge_hot
               or (focused and C.focus_edge or C.win_edge)
  pal.x_ig_rect(x, y, w, h, edge, math.max(1, z), 6 * z)
  if hot_part then -- accent the exact edge(s) under the cursor
    local t = math.max(2, 2.5 * z)
    if hot_part:find("n") then pal.x_ig_line(x + 4, y, x + w - 4, y, C.sel, t) end
    if hot_part:find("s") then
      pal.x_ig_line(x + 4, y + h, x + w - 4, y + h, C.sel, t)
    end
    if hot_part:find("w") then pal.x_ig_line(x, y + 4, x, y + h - 4, C.sel, t) end
    if hot_part:find("e") then
      pal.x_ig_line(x + w, y + 4, x + w, y + h - 4, C.sel, t)
    end
  end
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
  local hdr_right = x + w - 6 * z -- right edge available to header extras
  if kind and kind.dirty and kind.dirty(win, M) then
    pal.x_ig_circle_fill(x + w - 10 * z, y + hdr * 0.5, 3.5 * z, C.unsaved)
    hdr_right = x + w - 16 * z
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
      hdr_right = rx - 8 * z
    end
  end
  -- kind header extras (history arrows, edit toggles…), right-aligned;
  -- remember where the button zone begins (screen x, read next frame):
  -- a press left of it is the title-bar move handle (live round 3)
  local used = 0
  if kind and kind.header then
    used = kind.header(win, { z = z, alt = g.alt or false, ed = M,
                              hx = hdr_right, hy = y,
                              hh = math.min(hdr, h) }) or 0
  end
  g.hdrx = g.hdrx or {}
  g.hdrx[win.id] = hdr_right - used

  -- content, inset from the panel so nothing sits on the rounded border
  local m = 4 * z
  if kind and h > hdr + 2 * m then
    local ctx = {
      ig = ig, z = z, alt = g.alt or false, doc = doc, ed = M,
      focused = focused, touch = M.touch, occluded = occluded(doc, zi),
      cx = x + m, cy = y + hdr, cw = w - 2 * m, ch = h - hdr - m,
    }
    pal.x_ig_clip_push(ctx.cx, ctx.cy, ctx.cw, ctx.ch)
    kind.draw(win, ctx)
    pal.x_ig_clip_pop()
  end
end

local MENU_ITEMS = { { "note", "note" }, { "text", "open file…" },
                     { "assets", "assets" }, { "map", "map" },
                     { "game", "game window" }, { "console", "console" } }

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
      dh = dh or kind.DEF_H or 180
      if item[1] == "text" then dw, dh = M.text_spawn_size() end
      wm.spawn(M.doc, item[1], m.wx, m.wy, dw, dh, extra)
      g.menu = nil
      M.touch()
    end
  end
  pal.x_ig_overlay(false)
  if i.clicked[1] and not clicked_inside then g.menu = nil end
end

-- the rewind pill + bar (R6d, REWIND.md §6): the reserved top-right
-- corner. The pill shows the retained span; hovering it (or being
-- parked) expands the full-width bar — timeline, step/play, resume
-- here, close. All of it is a FRONT-END over cm.scrub's machinery (its
-- legacy panel keeps running invisibly under the canvas): the bar
-- reads/writes scrub.at/play and calls open/close/rewind_here. Chrome,
-- not editor state — a rewound frame does not show a rewound pill.
local function rw_button(i, x, y, w, h, label, accent)
  local hov = i.wx >= x and i.wx < x + w and i.wy >= y and i.wy < y + h
  pal.x_ig_rect_fill(x, y, w, h, hov and C.menu_hot or 0x262238ff, 5)
  local tw = pal.x_ig_text_size(label, 12, 0)
  pal.x_ig_text(x + (w - tw) * 0.5, y + (h - 12) * 0.45, 12,
                accent and C.sel or (hov and C.hud or C.title_dim), label, 0)
  return hov and i.clicked[1]
end

local function draw_rewind(ig, i)
  local scrub = cm.require("cm.scrub")
  local trace = cm.require("cm.trace")
  local g = M.g
  local lo, hi = trace.ring_range()
  local parked = scrub.paused()
  pal.x_ig_overlay(true)

  -- the pill
  local label
  if parked then
    label = "parked"
  elseif lo then
    local span = (hi - lo) // 60
    if span >= 3600 then -- cross-session streams get long (R6.5)
      label = ("%dh%02dm"):format(span // 3600, span % 3600 // 60)
    elseif span >= 60 then
      label = ("%dm%02ds"):format(span // 60, span % 60)
    else
      label = ("%ds"):format(span)
    end
  else
    label = "·"
  end
  local px = 13
  local lw = pal.x_ig_text_size(label, px, 0)
  local pw = lw + 24
  local x0, y0, h0 = ig.w - pw - 8, 8, 26
  pal.x_ig_rect_fill(x0, y0, pw, h0, parked and 0x3a3560f2 or C.pill, 8)
  pal.x_ig_text(x0 + 12, y0 + 6, px, parked and C.sel or C.hud_dim, label, 0)
  local now = pal.time_ns()
  if i.wx >= x0 and i.wx < x0 + pw and i.wy >= y0 and i.wy < y0 + h0 then
    g.rw_until = now + 2500 * 1e6 -- teidraw's video-pill timeout shape
  end

  local open = lo and (parked or (g.rw_until and now < g.rw_until))
  if not open then
    g.rw_bar = nil
    pal.x_ig_overlay(false)
    return
  end

  -- the bar
  local bx, by, bw, bh = 8, 42, ig.w - 16, 58
  g.rw_bar = { x = bx - 4, y = y0, w = bw + 8, h = by + bh - y0 + 4 }
  if (i.wx >= bx and i.wx < bx + bw and i.wy >= by and i.wy < by + bh) then
    g.rw_until = now + 2500 * 1e6
  end
  pal.x_ig_rect_fill(bx, by, bw, bh, 0x1e1b2ef6, 10)
  pal.x_ig_rect(bx, by, bw, bh, C.win_edge, 1, 10)

  -- the timeline
  local tx, tw2, ty = bx + 14, bw - 28, by + 12
  pal.x_ig_line(tx, ty + 4, tx + tw2, ty + 4, 0x3a3560ff, 3)
  local at = parked and scrub.at or hi
  local t = (at - lo) / math.max(1, hi - lo)
  pal.x_ig_circle_fill(tx + t * tw2, ty + 4, 6,
                       parked and C.sel or 0xb0a8dcff)
  if not g.alt and i.buttons[1] and i.wx >= tx - 8 and i.wx < tx + tw2 + 8
     and i.wy >= ty - 8 and i.wy < ty + 16 then
    if not parked then
      scrub.open()
      parked = scrub.paused()
    end
    if parked then
      local nt = math.max(0, math.min(1, (i.wx - tx) / tw2))
      scrub.at = math.floor(lo + nt * (hi - lo) + 0.5)
      scrub.play = false
    end
  end

  -- transport + doors
  local byy = ty + 22
  local info = parked
    and ("frame %d / %d   t%+.2fs"):format(scrub.at, hi, (scrub.at - hi) / 60)
    or ("frame %d — drag the timeline to browse the past"):format(hi)
  pal.x_ig_text(tx, byy + 4, 12, parked and C.hud or C.hud_dim, info, 0)
  local bxx = bx + bw - 14
  local function place(w)
    bxx = bxx - w - 6
    return bxx
  end
  if parked then
    if rw_button(i, place(52), byy, 52, 22, "close") then scrub.close() end
    if rw_button(i, place(94), byy, 94, 22, "resume here", true) then
      scrub.rewind_here()
    end
    -- door two: the focused asset window's past state → the present
    local fwin = wm.get(M.doc, M.doc.focus)
    if fwin and fwin.path and fwin.path ~= "" and M.doc.assets
       and M.doc.assets[fwin.path] then
      if rw_button(i, place(88), byy, 88, 22, "bring back", true) then
        local got = M.bring_back()
        if got then g.rw_flash = { path = got, t = now } end
      end
    end
    if g.rw_flash and now - g.rw_flash.t < 1.5e9 then
      pal.x_ig_text(tx + 260, byy + 4, 12, C.sel,
                    "brought back: " .. g.rw_flash.path, 0)
    end
    if rw_button(i, place(40), byy, 40, 22, scrub.play and "stop" or "play") then
      if scrub.play then
        scrub.play = false
      else
        if scrub.at >= hi then scrub.at = lo end
        scrub.play = scrub.at < hi
      end
    end
    if rw_button(i, place(28), byy, 28, 22, ">") then
      scrub.play = false
      scrub.at = math.min(hi, scrub.at + 1)
    end
    if rw_button(i, place(28), byy, 28, 22, "<") then
      scrub.play = false
      scrub.at = math.max(lo, scrub.at - 1)
    end
  else
    if rw_button(i, place(52), byy, 52, 22, "park") then scrub.open() end
  end
  pal.x_ig_overlay(false)
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
  local hint = "drag title move · drag canvas select · alt+drag move · " ..
               "alt+rclick close · alt+v select mode · edges resize · " ..
               "mid pan · rclick menu"
  local hw = pal.x_ig_text_size(hint, 11, 0)
  pal.x_ig_rect_fill(10, ig.h - 32, hw + 20, 24, C.pill, 8)
  pal.x_ig_text(20, ig.h - 27, 11, C.hud_dim, hint, 0)
  -- selection mode: unmissable chip, top-center
  if M.g.selmode then
    local s = "SELECT — click or drag selects · esc/alt+v exits"
    local sw = pal.x_ig_text_size(s, 12, 0)
    pal.x_ig_rect_fill((ig.w - sw) * 0.5 - 12, 8, sw + 24, 26, 0x2c4438f0, 8)
    pal.x_ig_rect((ig.w - sw) * 0.5 - 12, 8, sw + 24, 26, C.sel, 1, 8)
    pal.x_ig_text((ig.w - sw) * 0.5, 14, 12, C.sel, s, 0)
  end
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
  -- the asset-drag ghost rides the overlay above everything
  if g.adrag and g.adrag.moved then
    pal.x_ig_overlay(true)
    local label = g.adrag.path:match("([^/]+)$") or g.adrag.path
    local lw = pal.x_ig_text_size(label, 12, 0)
    pal.x_ig_rect_fill(i.wx + 12, i.wy + 8, lw + 16, 22, 0x262238ee, 6)
    pal.x_ig_rect(i.wx + 12, i.wy + 8, lw + 16, 22, C.sel, 1, 6)
    pal.x_ig_text(i.wx + 20, i.wy + 12, 12, C.hud, label, 0)
    pal.x_ig_overlay(false)
  end
  draw_menu(ig, i)
  draw_hud(ig)
  draw_rewind(ig, i)
end

-- ---- the frame (called from cm.main after game.draw) ----

function M.frame()
  if not M.on then return end
  -- the console is a canvas window now (R4c; the D050 §8 gate is gone).
  -- Anything that opens the legacy overlay in editor mode (a contained
  -- game error's notify, mainly) gets adopted into a console window.
  local con = cm.require("cm.console")
  if con.open then
    con.open = false
    con.slide = 0.0
    if M.doc then summon_console() end
  end
  local ig = pal.x_ig_frame()
  if not ig then return end
  interact(ig)
  draw(ig)
  if M.g.save_due and pal.time_ns() >= M.g.save_due then save_now() end
end

-- called from cm.main once the tick that raised the quit finishes — the
-- only path that runs on EVERY quit shape (window close, --frames cap,
-- headless --edit where frame() no-ops). In-frame saves are the debounce;
-- this is the backstop that makes "unsaved persists" a guarantee.
function M.quit_flush()
  if not M.on then return end
  if M.parked then M.unpark(false) end -- quit while parked: save the PRESENT
  M.kinds.text.flush(M) -- pending edit gestures reach their journals
  save_now()
end

return M
