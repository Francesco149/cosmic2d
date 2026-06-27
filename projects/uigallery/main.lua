-- uigallery — living reference for cm.ui, deliberately shaped like the M4
-- entity inspector (PLAN risk list: "could Godot's inspector be built on
-- this?"). Left: searchable, virtualized, selectable entity list. Right:
-- collapsible property sections with drag numbers, sliders, checkboxes,
-- text fields, buttons. ` opens the console, F3 the perf panel, on top.
--
-- Pure UI cartridge: widget values live on the game table (survive hot
-- reload, reset on reboot) — deliberately NOT sim state; nothing here
-- should ever be recorded.

local ui = cm.require("cm.ui")
local state = cm.require("cm.state")

local game = select(2, ...) or {}
local KINDS = { "prop", "crate", "lamp", "spawner", "decal", "trigger" }

local ents = {}
for i = 1, 40 do
  ents[i] = KINDS[(i - 1) % #KINDS + 1] .. "_" .. i
end

function game.init()
  game.props = game.props or {}
  game.sel = game.sel or 1
  game.search = game.search or ""
end

local function props_of(i)
  local p = game.props[i]
  if not p then
    p = { x = 24.0 + i * 3, y = 80.0, angle = (i * 37) % 360, mass = 1.0,
          bounce = 0.4, locked = false, layer = i % 8, tint = 0.8,
          visible = true, tag = "" }
    game.props[i] = p
  end
  return p
end

function game.step() end

local function entity_list()
  ui.begin_panel("ents", 2, 2, 150, 266, { title = "entities" })
  local s, changed = ui.text_input("search", game.search, { hint = "search" })
  if changed then game.search = s end

  local filtered, q = {}, game.search:lower()
  for i, name in ipairs(ents) do
    if q == "" or name:lower():find(q, 1, true) then
      filtered[#filtered + 1] = i
    end
  end

  ui.begin_scroll("list", 266 - (ui.cursor_y() - 2) - 4, { bg = ui.style.track })
  local row_h = ui.style.gh + 3
  ui.list(#filtered, row_h, function(k, x, y, w, h)
    local i = filtered[k]
    local clicked, hot = ui.hit(ents[i], x, y, w, h)
    if clicked then game.sel = i end
    if i == game.sel then
      ui.rect(x, y, w, h, ui.style.widget_active)
    elseif hot then
      ui.rect(x, y, w, h, ui.style.widget_hot)
    end
    ui.text(x + 3, y + 1, ents[i],
            i == game.sel and ui.style.accent or ui.style.text)
  end)
  ui.end_scroll()
  ui.end_panel()
end

local function inspector()
  local p = props_of(game.sel)
  ui.begin_panel("insp", 156, 2, 186, 266, { title = ents[game.sel] })

  if ui.heading("transform") then
    ui.row({ 1, 1 })
    p.x = ui.number("x", p.x, { speed = 0.5, label_w = 8 })
    p.y = ui.number("y", p.y, { speed = 0.5, label_w = 8 })
    p.angle = ui.slider("angle", p.angle, 0, 360, { fmt = "%d" })
    ui.heading_end()
  end

  if ui.heading("physics") then
    p.mass = ui.number("mass", p.mass, { speed = 0.05, min = 0.0 })
    p.bounce = ui.slider("bounce", p.bounce, 0.0, 1.0)
    p.locked = ui.checkbox("locked", p.locked)
    ui.heading_end()
  end

  if ui.heading("render") then
    p.layer = ui.slider("layer", p.layer, 0, 7)
    p.tint = ui.slider("tint", p.tint, 0.0, 1.0)
    p.visible = ui.checkbox("visible", p.visible)
    ui.row({ 1, 2 })
    ui.label("tag", { color = ui.style.text_dim })
    local t, tc = ui.text_input("tag", p.tag, { hint = "free text" })
    if tc then p.tag = t end
    ui.heading_end()
  end

  ui.space(4)
  ui.separator()
  ui.row({ 1, 1 })
  if ui.button("reset") then game.props[game.sel] = nil end
  if ui.button("log") then
    print(ents[game.sel] .. ": x=" .. p.x .. " y=" .. p.y
          .. " mass=" .. p.mass)
  end

  ui.end_panel()
end

function game.draw()
  pal.begin_frame(0.05, 0.055, 0.09, 1)

  -- something alive behind the chrome
  local f = state.frame()
  for i = 1, 12 do
    local t = (f * 0.7 + i * 31) % 480
    pal.quad(t, 230 + (i * 13) % 30, 3, 3, 0.2, 0.3 + i * 0.05, 0.5, 0.6)
  end

  entity_list()
  inspector()

  ui.text(348, 250, "` console   f3 perf", ui.style.text_dim)
end

return game
