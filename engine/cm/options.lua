-- cm.options — the video/options menu (M8.6, D036). Sets resolution / UI scale
-- / fullscreen DIRECTLY, which the resize ladder can't cover: a borderless or
-- fullscreen window can't be drag-resized (human ask 2026-06-28). Toggled by
-- Esc; available in play AND editor. The controls page (A4/D084) is the
-- player-facing rebind surface: every action the project defines lists its
-- live bindings as chips; clicking one (or +) arms a capture that binds the
-- next key or pad input, stealing it from any other action that held it.
-- Rebinds persist per project + per user in <project>/input.dat through
-- cm.input's binding store — live-side policy only, never a sim input.
--
-- Dev/render class: it drives only the viewport (cm.view + the PAL window
-- control), never sim state. It draws on whatever target is current — the ui
-- canvas when the editor owns it, else the full-window game — like the other
-- dev panels (cm.console/perf/scrub), and lays out against view.surface_size().
local M = select(2, ...) or {}

local ui = cm.require("cm.ui")
local view = cm.require("cm.view")
local input = cm.require("cm.input")

M.on = M.on or false
M.page = M.page or "main" -- "main" | "controls"
M.arm = nil -- capture armed: { action=, index=1..n to replace, nil appends }
M.note = nil -- transient status line on the controls page

local KEY_ESC, KEY_DEL = 41, 76
-- keys the capture refuses: the menu's own grammar and engine chrome. Del
-- doubles as "remove this binding" while a capture is armed, so it cannot
-- itself be bound.
local RESERVED = {
  [KEY_ESC] = "esc drives this menu",
  [53] = "` is the console key",
  [KEY_DEL] = "del removes a binding",
}
-- windowed presets (window px). Chosen so the ladder FILLS the window with no
-- letterbox — i.e. W,H are whole multiples of a FOV ≤ the 480×270 reference:
-- 720×540→360×270@2, 960×540→480×270@2, 1440×1080→360×270@4, 1920×1080→480×270@4
-- (a 4:3 + a 16:9 at each of the two heights). See cm.view.ladder.
local SIZES = { { 720, 540 }, { 960, 540 }, { 1440, 1080 }, { 1920, 1080 } }
local UI_SCALES = { 1, 2, 3 }

function M.toggle(on)
  if on == nil then
    M.on = not M.on
  else
    M.on = on == true or on == 1
  end
  M.page = "main"
  M.arm, M.note = nil, nil
end

-- persist the rebinds now; a failure names itself on the panel AND summons
-- the console (the A1 save-failure contract), while the live rebind stays
-- applied so the player is never silently on different bindings.
local function save()
  local ok, err = input.save_binds()
  if not ok then
    M.note = "save FAILED: " .. tostring(err)
    cm.require("cm.console").open = true
  end
  return ok
end

-- commit a captured binding to the armed action: steal it from every other
-- action first (a physical input driving two actions is a legal API state
-- but never what a player rebinding wants), then replace/append and save.
local function assign(c)
  local arm = M.arm
  M.arm = nil
  local stole = {}
  for _, name in ipairs(input.actions()) do
    if name ~= arm.action then
      local binds, changed = input.bindings(name), false
      for i = #binds, 1, -1 do
        if binds[i] == c then
          table.remove(binds, i)
          changed = true
        end
      end
      if changed then
        input.rebind(name, binds)
        stole[#stole + 1] = name
      end
    end
  end
  local cur = input.bindings(arm.action)
  if arm.index and arm.index <= #cur then
    cur[arm.index] = c
  else
    cur[#cur + 1] = c
  end
  input.rebind(arm.action, cur)
  M.note = input.bind_label(c) .. " -> " .. arm.action
  if #stole > 0 then
    M.note = M.note .. " (moved from " .. table.concat(stole, ", ") .. ")"
  end
  save()
end

-- one armed-capture tick: the next key down or pad button/deflection binds.
-- Reads the RAW ui streams (ui.inp.keys / ui.inp.pads), which keep flowing
-- while capture_keys/capture_pads hold everything away from the game.
local function do_capture()
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep then
      if k.scancode == KEY_DEL then
        local arm = M.arm
        M.arm = nil
        if arm.index then
          local cur = input.bindings(arm.action)
          table.remove(cur, arm.index)
          input.rebind(arm.action, cur)
          M.note = "binding removed from " .. arm.action
          save()
        else
          M.note = "nothing to remove"
        end
        return
      elseif RESERVED[k.scancode] then
        M.note = "reserved: " .. RESERVED[k.scancode]
      else
        assign("key:" .. k.scancode)
        return
      end
    end
  end
  for _, e in ipairs(ui.inp.pads) do
    local c = input.bind_of_pad_event(e)
    if c then
      assign(c)
      return
    end
  end
end

local function main_page()
  local st = ui.style
  local SW, SH = view.surface_size()
  local w, h = 184, 154
  local x, y = (SW - w) // 2, (SH - h) // 2
  ui.begin_panel("options", x, y, w, h, { title = "options" })

  local fs, fsc = ui.checkbox("fullscreen  (alt+enter)", view.fullscreen)
  if fsc then view.toggle_fullscreen(fs) end

  ui.label("window size", { color = st.text_dim })
  for r = 1, #SIZES, 2 do
    ui.row({ 1, 1 })
    for c = r, math.min(r + 1, #SIZES) do
      local s = SIZES[c]
      if ui.button(s[1] .. "x" .. s[2], { id = "sz" .. c }) then
        view.set_window_size(s[1], s[2]) -- leaves fullscreen + persists
      end
    end
  end

  ui.label("ui scale", { color = st.text_dim })
  ui.row({ 1, 1, 1 })
  for _, s in ipairs(UI_SCALES) do
    local on = view.cfg.ui_scale == s
    if ui.button(s .. "x", { id = "uis" .. s,
                             color = on and st.accent or st.text }) then
      view.set_ui_scale(s) -- persists
    end
  end

  if ui.button("controls...") then
    M.page = "controls"
    M.note = nil
  end
  if ui.button("close") then M.on = false end
  ui.separator() -- set the destructive action apart from "close"
  if ui.button("quit game", { color = st.error }) then
    M.on = false
    cm.main.request_quit() -- the only in-app exit when borderless-fullscreen
  end
  ui.end_panel()
end

local function controls_page()
  local st = ui.style
  local SW, SH = view.surface_size()
  local w = math.min(300, SW - 12)
  local h = math.min(240, SH - 12)
  local x, y = (SW - w) // 2, (SH - h) // 2
  ui.begin_panel("controls", x, y, w, h, { title = "controls" })

  local names = input.actions()
  local conflicted = {}
  for _, cf in ipairs(input.conflicts()) do conflicted[cf.bind] = true end

  if #names == 0 then
    ui.label("this project defines no actions", { color = st.text_dim })
    ui.space(h - 96)
  else
    ui.begin_scroll("acts", h - 92)
    for _, name in ipairs(names) do
      -- a * marks actions running on player overrides instead of defaults
      ui.label(input.overridden(name) and (name .. " *") or name,
               { color = st.text_dim })
      local binds = input.bindings(name)
      local cells = #binds + 1 -- every binding chip plus the trailing +
      for r = 1, cells, 3 do
        ui.row({ 1, 1, 1 })
        for i = r, r + 2 do -- fill ALL three cells: an unfilled row cell
          local c = binds[i] -- would swallow the next widget drawn
          if c then
            local armed = M.arm and M.arm.action == name and M.arm.index == i
            if ui.button(input.bind_label(c), {
                  id = "b:" .. name .. ":" .. i,
                  color = armed and st.accent
                          or (conflicted[c] and st.error or st.text) }) then
              M.arm, M.note = { action = name, index = i }, nil
            end
          elseif i == cells then
            if ui.button("+", { id = "add:" .. name }) then
              M.arm, M.note = { action = name }, nil
            end
          else
            ui.label("")
          end
        end
      end
    end
    ui.end_scroll()
  end

  ui.separator()
  if M.arm then
    ui.label("press a key or pad input for '" .. M.arm.action .. "'",
             { color = st.accent })
    ui.label(M.arm.index and "esc cancels, del removes" or "esc cancels",
             { color = st.text_dim })
  else
    ui.label(M.note or "click a binding to change it, + adds one",
             { color = st.text_dim })
    ui.label(next(conflicted) and "red bindings drive several actions" or "",
             { color = st.error })
  end
  ui.row({ 1, 1 })
  if ui.button("defaults", { id = "defaults" }) then
    for _, name in ipairs(names) do input.rebind(name, nil) end
    M.arm, M.note = nil, "default bindings restored"
    save()
  end
  if ui.button("back", { id = "back" }) then
    M.page = "main"
    M.arm = nil
  end
  ui.end_panel()
end

function M.frame()
  -- Esc walks the grammar one step at a time: open the menu, cancel an
  -- armed capture, leave the controls page, close the menu.
  local esc = false
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep and k.scancode == KEY_ESC then esc = true end
  end
  if esc then
    if not M.on then
      M.toggle(true)
    elseif M.arm then
      M.arm, M.note = nil, "rebind cancelled"
    elseif M.page == "controls" then
      M.page = "main"
    else
      M.toggle(false)
    end
  end
  if not M.on then return end
  ui.capture_mouse() -- clicks land on the menu, not the game/world beneath
  ui.capture_keys() -- ...and held keys don't drive the game behind the menu
                    -- (up-events still pass, so nothing sticks — see cm.ui)
  ui.capture_pads() -- pads follow the key rule while the menu owns input:
                    -- downs swallowed, releases pass, hot-plug passes
  input.pad_neutralize() -- and a held stick stops driving the sim (the
                         -- editor's focus-loss rule, applied to the menu)

  if M.arm then do_capture() end
  if M.page == "controls" then
    controls_page()
  else
    main_page()
  end
end

return M
