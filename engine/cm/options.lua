-- cm.options — the player options menu (M8.6/D036, grown at A4/D085). Sets
-- window size (display-fitted candidates) / UI scale / fullscreen DIRECTLY,
-- which the resize ladder can't cover: a borderless or fullscreen window
-- can't be drag-resized (human ask 2026-06-28); owns the master/music/sfx
-- volume knobs (device-output gains — the deterministic mix and audio
-- goldens never hear them), the reduced-effects accessibility toggles
-- (D129, stored user-wide in cm.view), and hosts project-declared
-- options (M.add).
-- Toggled by Esc (keyboard) or the pad back/select button (D128) — the
-- whole menu drives without a mouse: cm.ui's nav cursor (arrows / dpad /
-- left stick move, Enter/Space/pad-south activate, left/right adjust
-- sliders, Esc/back/east walk out). The controls page (A4/D084)
-- is the player-facing rebind surface: every action the project defines
-- lists its live bindings as chips; clicking one (or +) arms a capture that
-- binds the next key or pad input, stealing it from any other action that
-- held it; its stick knobs (deadzone / press threshold, D085) tune the live
-- axis policy. Rebinds + stick knobs persist per project + per user in
-- <project>/input.dat through cm.input's binding store; volumes + custom
-- options ride <project>/video.dat through cm.view's contributor hook —
-- all of it live-side policy only, never a sim input.
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
M._dirty = nil -- a knob changed: persist once the drag/click releases

-- ---- the volume knobs (A4/D085) ----
-- Player-facing percents 0..100 (100 = unity), applied to the PAL's device-
-- output gains (0..128) — pure live policy on what the DEVICE hears: the
-- deterministic mix, the PCM hash, and every audio golden are untouched by
-- construction (pal/src/snd.c). music/sfx follow the sim bank's slot
-- categories (music 32..47, sfx 0..31); master scales the whole output.
-- Persisted per project in video.dat through the contributor below.

M.vol = M.vol or { master = 100, music = 100, sfx = 100 }

local function apply_vol()
  if pal.x_snd_gain then
    pal.x_snd_gain(M.vol.master * 128 // 100, M.vol.music * 128 // 100,
                   M.vol.sfx * 128 // 100)
  end
end

local function vol_clamp(v)
  v = math.floor(tonumber(v) or 100)
  if v < 0 then v = 0 elseif v > 100 then v = 100 end
  return v
end

-- set_vol("master"|"music"|"sfx", 0..100): the UI and project code door —
-- applies live and persists (through the video.dat store).
function M.set_vol(kind, v)
  if M.vol[kind] == nil then error("unknown volume: " .. tostring(kind), 2) end
  M.vol[kind] = vol_clamp(v)
  apply_vol()
  view.save_video()
  return M.vol[kind]
end

-- ---- reduced effects (A8 accessibility, D129) ----
-- The player's reduce-shake / reduce-flash choices, stored user-wide in
-- cm.view's accessibility store (a photosensitive player sets them once per
-- machine). The engine's render-only doors — cm.camera.offset, cm.tween.
-- wobble, cm.tween.flash — consume the scales by themselves; these are the
-- game-facing reads for HAND-ROLLED effects: multiply your own flash
-- overlay's alpha by flash_scale() and your own shake offset by
-- shake_scale(), in draw, never in step (live policy, the options.add rule).

function M.shake_scale()
  return view.shake_scale()
end

function M.flash_scale()
  return view.flash_scale()
end

-- ---- project-declared options (A4/D085) ----
-- cm.options.add{ id=, label=, kind="toggle"|"slider"|"choice", default=,
--   min=, max=, step=, choices={...}, on_change=fn } appends a knob to the
-- Esc menu's main page. Values are LIVE POLICY ONLY (render/dev class, like
-- every knob here): a setting the sim reads belongs in the doc tree where it
-- is recorded — reading these from step() is a determinism bug. Values
-- persist per project + per machine in video.dat's `custom` table; entries
-- for ids no project code declares stay inert in the store (version skew or
-- a hot reload must not eat a player's choices, the input.dat rule).

M.defs = M.defs or {} -- ordered declarations
M._custom = M._custom or {} -- id -> stored value (declared AND inert ids)

local function opt_valid(d, v)
  if d.kind == "toggle" then return type(v) == "boolean" end
  if d.kind == "slider" then
    return type(v) == "number" and v >= d.min and v <= d.max
  end
  for _, c in ipairs(d.choices) do if v == c then return true end end
  return false
end

function M.add(decl)
  assert(type(decl) == "table" and type(decl.id) == "string"
         and decl.id ~= "", "options.add: id required")
  local kind = decl.kind or "toggle"
  local d = { id = decl.id, label = decl.label or decl.id, kind = kind,
              on_change = decl.on_change }
  if kind == "toggle" then
    d.default = decl.default == true
  elseif kind == "slider" then
    d.min = tonumber(decl.min) or 0
    d.max = tonumber(decl.max) or 100
    d.step = tonumber(decl.step)
    assert(d.min < d.max, "options.add: min must be < max")
    d.default = tonumber(decl.default) or d.min
  elseif kind == "choice" then
    assert(type(decl.choices) == "table" and #decl.choices > 0,
           "options.add: choices required")
    d.choices = table.move(decl.choices, 1, #decl.choices, 1, {})
    d.default = decl.default ~= nil and decl.default or d.choices[1]
  else
    error("options.add: unknown kind " .. tostring(kind), 2)
  end
  assert(opt_valid(d, d.default), "options.add: default out of range")
  -- redeclare replaces in place (hot reload); a stored value that no longer
  -- validates falls back to the new default but stays in the store untouched
  -- until the next explicit change
  local at = #M.defs + 1
  for i, e in ipairs(M.defs) do if e.id == d.id then at = i end end
  M.defs[at] = d
  return d
end

-- get(id) -> the live value (stored when valid, else the declared default)
function M.get(id)
  for _, d in ipairs(M.defs) do
    if d.id == id then
      local v = M._custom[id]
      if v ~= nil and opt_valid(d, v) then return v end
      return d.default
    end
  end
  error("unknown option: " .. tostring(id), 2)
end

-- set(id, v): validates, applies (on_change), persists
function M.set(id, v)
  for _, d in ipairs(M.defs) do
    if d.id == id then
      if not opt_valid(d, v) then
        error(("bad value for option %s: %s"):format(id, tostring(v)), 2)
      end
      M._custom[id] = v
      if d.on_change then d.on_change(v) end
      view.save_video()
      return v
    end
  end
  error("unknown option: " .. tostring(id), 2)
end

-- the video.dat fragment: volumes at 100% are omitted (an untouched player
-- never freezes a default), custom carries every stored id — declared or
-- inert — as plain scalars only
view.video_contrib("options", function()
  local custom
  for id, v in pairs(M._custom) do
    local t = type(v)
    if t == "boolean" or t == "number" or t == "string" then
      custom = custom or {}
      custom[id] = v
    end
  end
  return {
    vol_master = M.vol.master ~= 100 and M.vol.master or nil,
    vol_music = M.vol.music ~= 100 and M.vol.music or nil,
    vol_sfx = M.vol.sfx ~= 100 and M.vol.sfx or nil,
    custom = custom,
  }
end, function(t)
  M.vol = { master = 100, music = 100, sfx = 100 }
  M._custom = {}
  if type(t) == "table" then
    for _, k in ipairs({ "master", "music", "sfx" }) do
      local v = t["vol_" .. k]
      if type(v) == "number" then M.vol[k] = vol_clamp(v) end
    end
    if type(t.custom) == "table" then
      for id, v in pairs(t.custom) do
        local tv = type(v)
        if type(id) == "string"
           and (tv == "boolean" or tv == "number" or tv == "string") then
          M._custom[id] = v
        end
      end
    end
  end
  apply_vol()
end)

local KEY_ESC, KEY_DEL = 41, 76
local PAD_MENU, PAD_EAST = 4, 1 -- SDL back/select = the pad Esc; east = B
-- keys the capture refuses: the menu's own grammar and engine chrome. Del
-- doubles as "remove this binding" while a capture is armed, so it cannot
-- itself be bound. (pad back/select needs no entry here: the grammar above
-- cancels the armed capture on that press before the capture ever sees it,
-- the exact Esc path.)
local RESERVED = {
  [KEY_ESC] = "esc drives this menu",
  [53] = "` is the console key",
  [KEY_DEL] = "del removes a binding",
}
local UI_SCALES = { 1, 2, 3 }

function M.toggle(on)
  if on == nil then
    M.on = not M.on
  else
    M.on = on == true or on == 1
  end
  M.page = "main"
  M.arm, M.note = nil, nil
  -- the menu needs the OS cursor: while it is open the capture pump
  -- (cm.main.tick, D126) withholds consent, so a captured mouse releases
  -- on the next tick — and the game's standing capture wish re-engages by
  -- itself once the menu closes. One owner of pal.x_mouse_capture: the
  -- pump; a direct flip here would just fight its reconcile.
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

-- one volume slider row: live-applies while dragging, persists on release
local function vol_slider(kind)
  local v, changed = ui.slider(kind, M.vol[kind], 0, 100,
                               { id = "vol_" .. kind, fmt = "%d%%" })
  if changed then
    M.vol[kind] = vol_clamp(v)
    apply_vol()
    M._dirty = M._dirty or {}
    M._dirty.video = true
  end
end

local function main_page()
  local st = ui.style
  local SW, SH = view.surface_size()
  local w = math.min(220, SW - 12)
  local h = math.min(252, SH - 12)
  local x, y = (SW - w) // 2, (SH - h) // 2
  ui.begin_panel("options", x, y, w, h, { title = "options" })
  ui.begin_scroll("knobs", h - 76) -- the fixed rows below stay reachable

  local fs, fsc = ui.checkbox("fullscreen  (alt+enter)", view.fullscreen)
  if fsc then view.toggle_fullscreen(fs) end

  -- window sizes that FIT the desktop this window is on (A4/D085); the
  -- static classic four when SDL reports no display
  ui.label("window size", { color = st.text_dim })
  local sizes = view.size_candidates(pal.x_display_size())
  for r = 1, #sizes, 2 do
    ui.row({ 1, 1 })
    for c = r, math.min(r + 1, #sizes) do
      local s = sizes[c]
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

  ui.label("volume", { color = st.text_dim })
  vol_slider("master")
  vol_slider("music")
  vol_slider("sfx")

  -- reduced effects (A8 accessibility, D129): user-wide policy in cm.view —
  -- the engine's render-only effect doors (camera.offset / tween.wobble /
  -- tween.flash) consume the scales by themselves
  ui.label("accessibility", { color = st.text_dim })
  local rs, rsc = ui.checkbox("reduce screen shake", view.cfg.reduce_shake,
                              { id = "redshake" })
  if rsc then view.set_reduce_shake(rs) end
  local rf, rfc = ui.checkbox("reduce flashes", view.cfg.reduce_flash,
                              { id = "redflash" })
  if rfc then view.set_reduce_flash(rf) end

  -- knobs the project declared (options.add); values are live render policy
  if #M.defs > 0 then
    ui.label("game options", { color = st.text_dim })
    for _, d in ipairs(M.defs) do
      local v = M.get(d.id)
      local nv, changed
      if d.kind == "toggle" then
        nv, changed = ui.checkbox(d.label, v, { id = "opt:" .. d.id })
      elseif d.kind == "slider" then
        nv, changed = ui.slider(d.label, v, d.min, d.max,
                                { id = "opt:" .. d.id, step = d.step })
      else -- choice: one button cycles
        ui.row({ 1, 1 })
        ui.label(d.label, { color = st.text_dim })
        if ui.button(tostring(v), { id = "opt:" .. d.id }) then
          local at = 1
          for i, c in ipairs(d.choices) do if c == v then at = i end end
          nv, changed = d.choices[at % #d.choices + 1], true
        end
      end
      if changed then
        M._custom[d.id] = nv
        if d.on_change then d.on_change(nv) end
        M._dirty = M._dirty or {}
        M._dirty.video = true
      end
    end
  end

  ui.end_scroll()
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

-- the stick tuning knobs (A4/D085): percent views over the raw values —
-- UI display converts fresh each frame, the store keeps the exact raw int.
-- Deadzone shapes the QUANTIZED values entering new records (D082: recorded
-- values are authoritative, so retuning never invalidates a trace); the
-- press threshold is how far a bound axis must deflect to count as down.
local function stick_knobs()
  local dz, dzc = ui.slider("stick deadzone",
                            input.deadzone * 100 // 32767, 0, 75,
                            { id = "deadzone", fmt = "%d%%" })
  if dzc then
    input.set_deadzone(dz * 32767 // 100)
    M._dirty = M._dirty or {}
    M._dirty.binds = true
  end
  local th, thc = ui.slider("stick press at",
                            math.floor(input.axis_threshold * 100 / 127 + 0.5),
                            1, 100, { id = "axisthr", fmt = "%d%%" })
  if thc then
    input.set_axis_threshold(math.max(1, th * 127 // 100))
    M._dirty = M._dirty or {}
    M._dirty.binds = true
  end
end

local function controls_page()
  local st = ui.style
  local SW, SH = view.surface_size()
  local w = math.min(300, SW - 12)
  local h = math.min(252, SH - 12)
  local x, y = (SW - w) // 2, (SH - h) // 2
  ui.begin_panel("controls", x, y, w, h, { title = "controls" })

  local names = input.actions()
  local conflicted = {}
  for _, cf in ipairs(input.conflicts()) do conflicted[cf.bind] = true end

  local knob_h = 36 -- the two stick sliders under the action list
  if #names == 0 then
    ui.label("this project defines no actions", { color = st.text_dim })
    ui.space(h - 60 - knob_h)
  else
    ui.begin_scroll("acts", h - 56 - knob_h)
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
  stick_knobs()

  ui.separator()
  if M.arm then
    ui.label("press a key or pad input for '" .. M.arm.action .. "'",
             { color = st.accent })
    ui.label(M.arm.index and "esc cancels, del removes" or "esc cancels",
             { color = st.text_dim })
  else
    ui.label(M.note or "pick a binding to change it, + adds one",
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

-- persist knob changes once per gesture: sliders fire every drag frame, so
-- writes wait for the widget release (ui.active clears). Runs even after the
-- menu closes, so an Esc mid-drag still lands the save.
local function flush_dirty()
  if not M._dirty or ui.active then return end
  local d = M._dirty
  M._dirty = nil
  if d.video then view.save_video() end
  if d.binds then save() end
end

function M.frame()
  -- Esc walks the grammar one step at a time: open the menu, cancel an
  -- armed capture, leave the controls page, close the menu. The pad
  -- back/select button IS the pad Esc (D128) — the one pad door into the
  -- menu, so it is reserved from rebinding like Esc itself; east (B) also
  -- walks back but only while the menu is open (games bind east), and
  -- never while a capture is armed (the press must bind, not cancel).
  local esc = false
  for _, k in ipairs(ui.inp.keys) do
    if k.down and not k.rep and k.scancode == KEY_ESC then esc = true end
  end
  for _, e in ipairs(ui.inp.pads) do
    if (e.type == "padbtn" or e.type == "gpadbtn") and e.down then
      if e.button == PAD_MENU then esc = true
      elseif e.button == PAD_EAST and M.on and not M.arm then esc = true end
    end
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
  flush_dirty()
  if not M.on then return end
  ui.capture_mouse() -- clicks land on the menu, not the game/world beneath
  ui.capture_keys() -- ...and held keys don't drive the game behind the menu
                    -- (up-events still pass, so nothing sticks — see cm.ui)
  ui.capture_pads() -- pads follow the key rule while the menu owns input:
                    -- downs swallowed, releases pass, hot-plug passes
  input.pad_neutralize() -- and a held stick stops driving the sim (the
                         -- editor's focus-loss rule, applied to the menu)
  if not M.arm then -- keyboard/pad cursor over the menu widgets (D128);
    ui.nav_scope()  -- suspended while a capture is armed: the next press
  end               -- must BIND, not navigate

  if M.arm then do_capture() end
  if M.page == "controls" then
    controls_page()
  else
    main_page()
  end
end

return M
