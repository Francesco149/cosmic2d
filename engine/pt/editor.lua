-- pt.editor — editor mode v0 (M4): the F1 mode switch, map painting, the
-- collider overlay and the state inspector (pt.inspect, toolbar toggle).
-- Engine-level chrome, available in every project unless project.lua sets
-- `editor = false` (the play-mode lockdown for shipped zips — it disables
-- F1 here and the ` / F3 toggles in pt.console and pt.perf; see locked()).
--
-- Dev/render class by the D021 iron rule: this module owns no sim state
-- and never mutates any directly. Every edit is SUBMITTED as a console
-- command through pt.repl (the D022 EVAL path) — pt.tilemap.poke per
-- painted cell, the cartridge's reset_eval for the reset button — so an
-- editing session records into a trace exactly like console typing:
-- replay and verify reproduce the edits byte-exact (D026). The editor is
-- a repl client with a mouse.
--
-- Cartridge wiring: game.init calls pt.editor.attach(fn); fn() runs once
-- per editor frame (read-only!) and returns the live editing surface:
--   { tm = pt.tilemap wrapper,      -- the paintable map
--     atlas = { id=, w=, h= },      -- texture the tm tiles reference
--     camx =, camy =,               -- world camera this frame
--     colliders = function()        -- optional, for the overlay
--       return { { x=, y=, w=, h=, kind="player"|"prop"|"held" }, ... }
--     end,
--     save = function() end,        -- optional: persist project state
--                                   --   (sandbox: map.dat + knobs.dat)
--     reset_eval = "game.level.reset()" } -- optional: rebuild command
--
-- While editor mode is on, the mouse belongs to the editor (the game sees
-- only up-events); the keyboard still reaches the game — walk around
-- while you paint. LMB paints the selected tile, RMB erases, drags are
-- cell-line-walked so fast strokes don't skip. F1 returns to play mode.

local M = select(2, ...) or {}

local ui = pt.require("pt.ui")
local repl = pt.require("pt.repl")
local gfx = pt.require("pt.gfx")
local tilemap = pt.require("pt.tilemap")
local inspect = pt.require("pt.inspect")

M.on = M.on or false
M.sel = M.sel or 1 -- selected tile id; 0 = the eraser
M.show_col = M.show_col or false
if M.show_insp == nil then M.show_insp = true end -- the inspector panel

local floor, ceil = math.floor, math.ceil
local KEY_F1 = 58
local TB_H = 43 -- toolbar: pad + status row + gap + 22px swatch strip + pad
local SW = 22 -- swatch cell size
local IW = 186 -- inspector panel width (right edge, under the toolbar)
local KIND_COLOR = {
  player = { 0.30, 0.95, 0.95, 0.95 },
  prop = { 0.95, 0.65, 0.25, 0.95 },
  held = { 0.95, 0.95, 0.35, 0.95 },
}
local KIND_DEFAULT = { 0.55, 0.95, 0.55, 0.95 }

function M.attach(fn)
  M.attach_fn = fn
end

-- project.lua `editor = false` locks every dev surface (shipped zips):
-- F1 here, the ` toggle in pt.console, F3 in pt.perf. Game code can still
-- opt a door back in by flipping the field (the PLAN's "opt-in door").
function M.locked()
  local proj = pt.main and pt.main.proj
  return (proj ~= nil and proj.editor == false) and true or false
end

function M.toggle(on)
  if M.locked() then return end
  if on == nil then
    M.on = not M.on
  else
    M.on = on == true or on == 1
  end
end

-- ---- world-space drawing (camera applied; runs before the panels) ----

local function draw_classes(att)
  local tm = att.tm
  local t = tm.tile
  local vw, vh = pal.gfx_size()
  local c0 = math.max(0, floor(att.camx / t))
  local c1 = math.min(tm.w - 1, ceil((att.camx + vw) / t) - 1)
  local r0 = math.max(0, floor(att.camy / t))
  local r1 = math.min(tm.h - 1, ceil((att.camy + vh) / t) - 1)
  for r = r0, r1 do
    for c = c0, c1 do
      local d = tm.tiles[tm:get(c, r)]
      if d then
        if d.solid then
          pal.quad(c * t, r * t, t, t, 0.95, 0.30, 0.30, 0.26)
        elseif d.oneway then
          pal.quad(c * t, r * t, t, 3, 0.95, 0.80, 0.30, 0.6)
        end
      end
    end
  end
end

local function draw_aabbs(att)
  if not att.colliders then return end
  local ok, list = pcall(att.colliders)
  if not ok or type(list) ~= "table" then return end
  for _, b in ipairs(list) do
    ui.frame_rect(b.x, b.y, b.w, b.h, KIND_COLOR[b.kind] or KIND_DEFAULT)
  end
end

-- ---- painting (every write goes through the repl queue) ----

-- the hovered cell, or nil while the mouse is over chrome / out of the map
local function hover_cell(att)
  if ui.over_panel or ui.active then return nil end
  local tm = att.tm
  local tx = floor((ui.inp.mx + att.camx) / tm.tile)
  local ty = floor((ui.inp.my + att.camy) / tm.tile)
  if tx < 0 or tx >= tm.w or ty < 0 or ty >= tm.h then return nil end
  return tx, ty
end

local function paint(att, tx, ty)
  local inp = ui.inp
  -- a stroke arms only on a press that starts on the world, not on chrome
  if (inp.clicked[1] or inp.clicked[3]) and tx then
    M.stroke = {}
    M.last_cell = nil
  end
  if not (inp.buttons[1] or inp.buttons[3]) then
    M.stroke, M.last_cell = nil, nil
    return
  end
  if not M.stroke or not tx then return end -- chrome press / off the map

  local tm = att.tm
  local id = inp.buttons[3] and 0 or M.sel
  local x0, y0 = tx, ty
  if M.last_cell then x0, y0 = M.last_cell[1], M.last_cell[2] end
  tilemap.cell_line(x0, y0, tx, ty, function(cx, cy)
    if cx < 0 or cx >= tm.w or cy < 0 or cy >= tm.h then return end
    local key = cy * tm.w + cx
    if M.stroke[key] ~= id and tm:get(cx, cy) ~= id then
      M.stroke[key] = id
      repl.submit(("pt.tilemap.poke(%q,%d,%d,%d)")
                  :format(tm.name, cx, cy, id))
    end
  end)
  M.last_cell = { tx, ty }
end

-- ---- the toolbar ----

local function swatch(att, id, x, y)
  local st = ui.style
  local clicked, hot = ui.hit("sw" .. id, x, y, SW, SW)
  ui.rect(x, y, SW, SW, hot and st.widget_hot or st.widget)
  local ix, iy = x + (SW - 16) // 2, y + (SW - 16) // 2
  local d = att.tm.tiles[id]
  if id == 0 then
    ui.text(ix + 6, iy + 4, "x", st.text_dim)
  elseif d and d.u then
    local aw, ah = att.atlas.w, att.atlas.h
    local t = att.tm.tile
    pal.quad(ix, iy, 16, 16, d.r or 1, d.g or 1, d.b or 1, 1, att.atlas.id,
             d.u / aw, d.v / ah, (d.u + t) / aw, (d.v + t) / ah)
  else
    ui.text(ix + 4, iy + 4, "??", st.text_dim)
  end
  if M.sel == id then
    ui.frame_rect(x, y, SW, SW, st.accent)
  end
  if clicked then M.sel = id end
end

local function toolbar(att, tx, ty)
  local W = pal.gfx_size()
  local st = ui.style
  ui.begin_panel("editor", 0, 0, W, TB_H)

  ui.row({ 44, 168, 64, 56, 38, 38 })
  ui.label("EDITOR", { color = st.accent })
  local status
  if att and att.tm then
    status = ("map %s  %dx%d"):format(att.tm.name, att.tm.w, att.tm.h)
    if tx then status = status .. ("  cell %d,%d"):format(tx, ty) end
  else
    status = "nothing to edit - game.init: pt.editor.attach(fn)"
  end
  ui.label(status, { color = st.text_dim })
  M.show_col = ui.checkbox("colliders", M.show_col)
  M.show_insp = ui.checkbox("inspect", M.show_insp)
  if att and att.save then
    if ui.button("save") then
      if att.save() then
        pal.log("[editor] saved")
      else
        pal.log("[editor] save FAILED")
      end
    end
  else
    ui.label("", {})
  end
  if att and att.reset_eval then
    if ui.button("reset") then repl.submit(att.reset_eval) end
  else
    ui.label("", {})
  end

  -- the swatch strip: eraser + every id the tiles table knows, hand-laid
  -- on a canvas so cells stay square (F1 hint rides the leftover space)
  local strip = ui.canvas(SW)
  if att and att.tm then
    local ids = { 0 }
    for id in pairs(att.tm.tiles) do ids[#ids + 1] = id end
    table.sort(ids)
    local x = strip.x
    for _, id in ipairs(ids) do
      swatch(att, id, x, strip.y)
      x = x + SW + 2
    end
    ui.text(x + 6, strip.y + (SW - st.gh) // 2,
            "lmb paint  rmb erase  f1 play", st.text_dim)
  else
    ui.text(strip.x, strip.y + (SW - st.gh) // 2, "f1 play", st.text_dim)
  end

  ui.end_panel()
end

-- ---- the per-tick frame (pt.main: after game draw, before perf) ----

function M.frame()
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep and k.scancode == KEY_F1 then M.toggle() end
  end
  if not M.on then return end

  local att
  if M.attach_fn then
    local ok, a = pcall(M.attach_fn)
    if ok then
      att = a
      M.att_err = nil
    elseif M.att_err ~= tostring(a) then
      M.att_err = tostring(a) -- log once per distinct error, never throw
      pal.log("[editor] attach getter error: " .. M.att_err)
    end
  end

  ui.capture_mouse() -- world clicks are brush strokes, not game input

  local tx, ty
  if att and att.tm then
    tx, ty = hover_cell(att)
    gfx.camera(att.camx or 0, att.camy or 0)
    gfx.layer(1)
    if M.show_col then
      draw_classes(att)
      draw_aabbs(att)
    end
    if tx then
      ui.frame_rect(tx * att.tm.tile, ty * att.tm.tile,
                    att.tm.tile, att.tm.tile, { 1, 1, 1, 0.85 })
    end
    paint(att, tx, ty)
  end

  toolbar(att, tx, ty)
  if M.show_insp then
    local W, H = pal.gfx_size()
    inspect.frame(W - IW - 2, TB_H + 2, IW, H - TB_H - 4)
  end
end

return M
