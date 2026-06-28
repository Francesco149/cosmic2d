-- cm.editor — editor mode v0 (M4): the F1 mode switch, map painting, the
-- collider overlay and the state inspector (cm.inspect, toolbar toggle).
-- Engine-level chrome, available in every project unless project.lua sets
-- `editor = false` (the play-mode lockdown for shipped zips — it disables
-- F1 here and the ` / F3 toggles in cm.console and cm.perf; see locked()).
--
-- Dev/render class by the D021 iron rule: this module owns no sim state
-- and never mutates any directly. Every edit is SUBMITTED as a console
-- command through cm.repl (the D022 EVAL path) — cm.tilemap.poke per
-- painted cell, the cartridge's reset_eval for the reset button — so an
-- editing session records into a trace exactly like console typing:
-- replay and verify reproduce the edits byte-exact (D026). The editor is
-- a repl client with a mouse.
--
-- Cartridge wiring: game.init calls cm.editor.attach(fn); fn() runs once
-- per editor frame (read-only!) and returns the live editing surface:
--   { tm = cm.tilemap wrapper,      -- the paintable map
--     atlas = { id=, w=, h= },      -- texture the tm tiles reference
--     camx =, camy =,               -- world camera this frame
--     colliders = function()        -- optional, for the overlay
--       return { { x=, y=, w=, h=, kind="player"|"prop"|"held" }, ... }
--     end,
--     save = function() end,        -- optional: persist project state
--                                   --   (sandbox: map.dat + knobs.dat)
--     reset_eval = "game.level.reset()", -- optional: rebuild command
--     props = {                     -- optional spawn palette (D031):
--       { name = "crate",           --   entries join the swatch strip;
--         icon = { u=, v=, w=, h= },--   atlas sub-rect for the swatch
--         spawn = "game.props.spawn(%d,%d)",       -- eval formats, filled
--         erase = "game.props.despawn_at(%d,%d)" } -- with world x,y (ints)
--     } }
--
-- While editor mode is on, the mouse belongs to the editor (the game sees
-- only up-events); the keyboard still reaches the game — walk around
-- while you paint. LMB paints the selected tile, RMB erases, drags are
-- cell-line-walked so fast strokes don't skip. F1 returns to play mode.
-- The `paint` checkbox in the swatch row disarms the brush AND releases
-- the world's mouse back to the game (chrome still owns its panels) —
-- inspect and tune without stray clicks editing the map.

local M = select(2, ...) or {}

local ui = cm.require("cm.ui")
local repl = cm.require("cm.repl")
local gfx = cm.require("cm.gfx")
local tilemap = cm.require("cm.tilemap")
local inspect = cm.require("cm.inspect")
local view = cm.require("cm.view")

M.on = M.on or false
M.sel = M.sel or 1 -- selected tile id; 0 = the eraser
-- M.sel_prop: selected palette entry index, or nil = the tile brush
M.show_col = M.show_col or false
if M.show_insp == nil then M.show_insp = true end -- the inspector panel
if M.paint_on == nil then M.paint_on = true end -- brush armed / mouse to game

local floor, ceil = math.floor, math.ceil
local KEY_F1 = 58
-- exposed on M so cm.view can inset the game viewport by the chrome (D036)
M.TB_H = 43 -- toolbar: pad + status row + gap + 22px swatch strip + pad
M.IW = 186 -- inspector panel width (right edge, under the toolbar)
local TB_H, IW = M.TB_H, M.IW
local SW = 22 -- swatch cell size
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
-- F1 here, the ` toggle in cm.console, F3 in cm.perf. Game code can still
-- opt a door back in by flipping the field (the PLAN's "opt-in door").
function M.locked()
  local proj = cm.main and cm.main.proj
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
  -- gx/gy: game-space mouse (through the viewport), so painting lands on the
  -- world even when the editor chrome lives on a separate ui canvas (D036)
  local tx = floor((ui.inp.gx + att.camx) / tm.tile)
  local ty = floor((ui.inp.gy + att.camy) / tm.tile)
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
      repl.submit(("cm.tilemap.poke(%q,%d,%d,%d)")
                  :format(tm.name, cx, cy, id))
    end
  end)
  M.last_cell = { tx, ty }
end

-- the spawn palette's world interaction: press edges only (a drag must
-- not machine-gun crates) — LMB submits the entry's spawn eval at the
-- world mouse, RMB its erase eval. Cartridge commands through the repl
-- (D031): a spawn records and replays exactly like a painted cell.
local function spawn_click(att, e)
  local inp = ui.inp
  local wx = floor(inp.gx + att.camx) -- game-space mouse (see hover_cell)
  local wy = floor(inp.gy + att.camy)
  if e.icon then -- ghost: where the spawn would sit
    ui.frame_rect(wx - e.icon.w // 2, wy - e.icon.h // 2,
                  e.icon.w, e.icon.h, { 1, 1, 1, 0.85 })
  end
  if inp.clicked[1] and e.spawn then repl.submit(e.spawn:format(wx, wy)) end
  if inp.clicked[3] and e.erase then repl.submit(e.erase:format(wx, wy)) end
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
  if M.sel == id and not M.sel_prop then
    ui.frame_rect(x, y, SW, SW, st.accent)
  end
  if clicked then
    M.sel = id
    M.sel_prop = nil
  end
end

local function prop_swatch(att, k, x, y)
  local st = ui.style
  local e = att.props[k]
  local clicked, hot = ui.hit("pw" .. k, x, y, SW, SW)
  ui.rect(x, y, SW, SW, hot and st.widget_hot or st.widget)
  local ic = e.icon
  if ic then
    local aw, ah = att.atlas.w, att.atlas.h
    pal.quad(x + (SW - ic.w) // 2, y + (SW - ic.h) // 2, ic.w, ic.h,
             1, 1, 1, 1, att.atlas.id,
             ic.u / aw, ic.v / ah, (ic.u + ic.w) / aw, (ic.v + ic.h) / ah)
  else
    ui.text(x + 4, y + (SW - st.gh) // 2, "??", st.text_dim)
  end
  if M.sel_prop == k then
    ui.frame_rect(x, y, SW, SW, st.accent)
  end
  if clicked then M.sel_prop = k end
end

local function toolbar(att, tx, ty)
  local W = view.surface_size() -- the ui canvas when the editor owns it (D036)
  local st = ui.style
  ui.begin_panel("editor", 0, 0, W, TB_H)

  ui.row({ 44, 168, 64, 56, 38, 38 })
  ui.label("EDITOR", { color = st.accent })
  local status
  if att and att.tm then
    status = ("map %s  %dx%d"):format(att.tm.name, att.tm.w, att.tm.h)
    if tx then status = status .. ("  cell %d,%d"):format(tx, ty) end
  else
    status = "nothing to edit - game.init: cm.editor.attach(fn)"
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
    if att.props then -- the spawn palette joins the strip after a gap
      x = x + 4
      for k = 1, #att.props do
        prop_swatch(att, k, x, strip.y)
        x = x + SW + 2
      end
    end
    M.paint_on = ui.checkbox("paint", M.paint_on, {
      rect = { x + 6, strip.y + (SW - st.row_h) // 2, 50, st.row_h } })
    local hint = "lmb paint  rmb erase  f1 play"
    if not M.paint_on then
      hint = "mouse plays the game  f1 play"
    elseif att.props and M.sel_prop and att.props[M.sel_prop] then
      hint = "lmb spawn  rmb delete  f1 play"
    end
    ui.text(x + 62, strip.y + (SW - st.gh) // 2, hint, st.text_dim)
  else
    ui.text(strip.x, strip.y + (SW - st.gh) // 2, "f1 play", st.text_dim)
  end

  ui.end_panel()
end

-- ---- the per-tick frame (cm.main: after game draw, before perf) ----

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

  if M.paint_on then
    ui.capture_mouse() -- world clicks are brush strokes, not game input
  end -- paint off: the world's mouse plays the game; panels still capture

  local tx, ty
  if att and att.tm then
    tx, ty = hover_cell(att)
    gfx.camera(att.camx or 0, att.camy or 0)
    gfx.layer(1)
    if M.show_col then
      draw_classes(att)
      draw_aabbs(att)
    end
    if M.paint_on then
      local pe = att.props and M.sel_prop and att.props[M.sel_prop]
      if pe then -- a palette entry holds the brush: spawn/erase clicks
        if tx then spawn_click(att, pe) end
      else
        if tx then
          ui.frame_rect(tx * att.tm.tile, ty * att.tm.tile,
                        att.tm.tile, att.tm.tile, { 1, 1, 1, 0.85 })
        end
        paint(att, tx, ty)
      end
    end
  end

  -- chrome now draws on the ui canvas (its own scale); the world overlay above
  -- stayed on the game target so it tracks + scales with the world (D036)
  pal.x_target("ui")
  toolbar(att, tx, ty)
  if M.show_insp then
    local W, H = view.surface_size()
    inspect.frame(W - IW - 2, TB_H + 2, IW, H - TB_H - 4)
  end
  -- leave the target on "ui" so the dev panels drawn after us (scrub / perf /
  -- console) compose onto the same canvas while the editor is active
end

return M
