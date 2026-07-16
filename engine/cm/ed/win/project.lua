-- cm.ed.win.project — A3's first in-editor project-settings surface.
--
-- The form does not own a second project model.  Its source is the text
-- window's project.lua working copy, so session recovery, journal undo, atomic
-- Ctrl+S, rewind capture, and simultaneous source editing all share one path.
-- Form strings live on the captured window only while they are temporarily
-- invalid; a successful save merges the editable fields into the latest
-- declarative source and preserves every unedited key.

local M = select(2, ...) or {}
local project = cm.require("cm.project")
local textwin = cm.require("cm.ed.win.text")

M.kind = "project"
M.menu = "project settings"
M.help = "win-project"
M.DEF_W, M.DEF_H = 560, 390

local COL = {
  text = 0xd8d2f2ff, dim = 0x8a84b0ff, hot = 0xE8E4FFff,
  accent = 0x7fd8a8ff, warn = 0xffb46eff, bad = 0xf07a7aff,
  well = 0x141220ff, edge = 0x4a4370ff, button = 0x262238ff,
  button_hot = 0x3a3560ff,
}

local FORM_FIELDS = {
  "name", "author", "version", "description",
  "internal_w", "internal_h", "window_scale", "maximized",
}

local FIELD_ROWS = {
  { "name", "name" },
  { "author", "author" },
  { "version", "version" },
  { "description", "description" },
  { "internal_w", "internal width" },
  { "internal_h", "internal height" },
  { "window_scale", "initial scale" },
}

local function copy_form(form)
  local out = {}
  for _, field in ipairs(FORM_FIELDS) do out[field] = form[field] end
  return out
end

local function same_form(a, b)
  if not a or not b then return false end
  for _, field in ipairs(FORM_FIELDS) do
    if a[field] ~= b[field] then return false end
  end
  return true
end

local function form_dirty(win)
  return win.form ~= nil and not same_form(win.form, win.base)
end

function M.defaults()
  return { path = "project.lua" }
end

function M.title()
  return "project settings"
end

local function set_error(win, ed, message, log)
  message = tostring(message)
  local changed = win.error ~= message or win.status ~= nil
  win.error = message
  win.status = nil
  if log then pal.log("[ed] PROJECT SETTINGS: " .. win.error) end
  if changed and ed and ed.touch then ed.touch() end
  return nil, win.error
end

-- Adopt the current shared project.lua working bytes into the form.  Forced
-- reload is the explicit conflict-resolution door; ordinary draws refresh only
-- when the form itself has no pending edits.
local function load_form(win, ed, force)
  local a = textwin.open_win(win, ed)
  if not a then return set_error(win, ed, "project.lua is unavailable") end
  if win.form and not force then
    if a.text ~= win.source and not form_dirty(win) then
      force = true
    else
      local current, current_err = project.decode(
        a.text, "@" .. ed.root .. "/project.lua")
      if not current then return set_error(win, ed, current_err) end
      return a, current
    end
  end
  local meta, err = project.decode(a.text, "@" .. ed.root .. "/project.lua")
  if not meta then return set_error(win, ed, err) end
  win.form = project.settings(meta)
  win.base = copy_form(win.form)
  win.source = a.text
  win.error, win.conflict = nil, nil
  win.undos, win.redos, win.editing = {}, {}, nil
  if force then win.status = "reloaded from the project.lua working copy" end
  if ed.touch then ed.touch() end
  return a, meta
end

function M.open_win(win, ed)
  return load_form(win, ed, win.form == nil)
end

local function push_undo(win)
  win.undos = win.undos or {}
  win.undos[#win.undos + 1] = copy_form(win.form)
  if #win.undos > 64 then table.remove(win.undos, 1) end
  win.redos = {}
end

local function edit_field(win, ed, field, value)
  if win.form[field] == value then return end
  if win.editing ~= field then
    push_undo(win)
    win.editing = field
  end
  win.form[field] = value
  win.error, win.status = nil, nil
  ed.touch()
end

function M.validate(win, ed)
  local a = load_form(win, ed, false)
  if not a then return nil, win.error end
  return project.validate_settings(win.form)
end

function M.dirty(win, ed)
  local a = load_form(win, ed, false)
  if not a then return form_dirty(win) end
  if a.text ~= win.source and form_dirty(win) then win.conflict = true end
  return form_dirty(win) or textwin.dirty(win, ed)
end

function M.save(win, ed)
  if ed.parked then
    return set_error(win, ed, "parked in the past — writes are walled", true)
  end
  local a = textwin.open_win(win, ed)
  if not a then return set_error(win, ed, "project.lua is unavailable", true) end
  local latest, err = project.decode(a.text, "@" .. ed.root .. "/project.lua")
  if not latest then return set_error(win, ed, err, true) end
  local merged
  merged, err = project.apply_settings(latest, win.form)
  if not merged then return set_error(win, ed, err) end
  local bytes
  bytes, err = project.encode(merged)
  if not bytes then return set_error(win, ed, err, true) end
  local ok
  ok, err = textwin.replace(win, ed, bytes)
  if not ok then return set_error(win, ed, err, true) end
  ok, err = textwin.save(win, ed)
  if not ok then
    -- The complete canonical working bytes remain dirty and journaled; a retry
    -- uses the same ordinary Ctrl+S path after the atomic-write failure.
    win.source = bytes
    return set_error(win, ed, "save failed: " .. tostring(err))
  end
  win.form = project.settings(merged)
  win.base = copy_form(win.form)
  win.source = bytes
  win.error, win.conflict = nil, nil
  win.undos, win.redos, win.editing = {}, {}, nil
  win.status = "saved — resolution and window defaults apply next launch"
  ed.touch()
  return true
end

function M.revert(win, ed)
  textwin.revert(win, ed)
  win.form, win.base, win.source = nil, nil, nil
  local a, err = load_form(win, ed, true)
  if not a then return nil, err end
  win.status = "reset to the saved project.lua"
  ed.touch()
  return true
end

function M.undo(win, ed)
  win.editing = nil
  local stack = win.undos or {}
  local prior = table.remove(stack)
  if prior then
    win.redos = win.redos or {}
    win.redos[#win.redos + 1] = copy_form(win.form)
    win.form = prior
    win.error, win.status = nil, nil
    ed.touch()
    return true
  end
  textwin.undo(win, ed)
  win.form, win.base, win.source = nil, nil, nil
  return load_form(win, ed, true) ~= nil
end

function M.redo(win, ed)
  win.editing = nil
  local stack = win.redos or {}
  local next_form = table.remove(stack)
  if next_form then
    win.undos = win.undos or {}
    win.undos[#win.undos + 1] = copy_form(win.form)
    win.form = next_form
    win.error, win.status = nil, nil
    ed.touch()
    return true
  end
  textwin.redo(win, ed)
  win.form, win.base, win.source = nil, nil, nil
  return load_form(win, ed, true) ~= nil
end

local function button(ctx, x, y, w, h, label, enabled)
  local i = cm.require("cm.ui").inp
  local hot = enabled and not ctx.occluded and ctx.hot
              and i.wx >= x and i.wx < x + w and i.wy >= y and i.wy < y + h
  pal.x_ig_rect_fill(x, y, w, h, hot and COL.button_hot or COL.button, 4 * ctx.z)
  pal.x_ig_rect(x, y, w, h, enabled and COL.edge or 0x3a356080, 1, 4 * ctx.z)
  local px = math.max(4, 11 * ctx.z)
  local tw = pal.x_ig_text_size(label, px, 0)
  pal.x_ig_text(x + (w - tw) * 0.5, y + (h - px) * 0.43, px,
                not enabled and 0x5a5480ff or (hot and COL.hot or COL.text), label, 0)
  return hot and i.clicked[1]
end

local function draw_field(win, ctx, field, label, y, label_w, row_h, px)
  local z = ctx.z
  local x = ctx.cx + 10 * z
  local fx = x + label_w
  local fw = ctx.cw - label_w - 20 * z
  pal.x_ig_text(x, y + (row_h - px) * 0.42, px, COL.dim, label, 0)
  pal.x_ig_rect_fill(fx, y + 2 * z, fw, row_h - 4 * z, COL.well, 3 * z)
  pal.x_ig_rect(fx, y + 2 * z, fw, row_h - 4 * z, COL.edge, 1, 3 * z)
  if ctx.occluded then
    pal.x_ig_clip_push(fx + 5 * z, y, fw - 10 * z, row_h)
    pal.x_ig_text(fx + 5 * z, y + (row_h - px) * 0.42, px, COL.text,
                  win.form[field] or "", field:find("internal_") and 1 or 0)
    pal.x_ig_clip_pop()
    return false
  end
  local value, changed, active = pal.x_ig_edit {
    id = "project_" .. field .. win.id,
    x = fx + 4 * z, y = y + 4 * z, w = fw - 8 * z, h = row_h - 8 * z,
    text = win.form[field] or "", px = px, font = field:find("internal_") and 1 or 0,
    multiline = false,
  }
  if changed then edit_field(win, ctx.ed, field, value) end
  return active or false
end

function M.draw(win, ctx)
  local a, meta = load_form(win, ctx.ed, false)
  if not a or not win.form then
    pal.x_ig_text(ctx.cx + 10 * ctx.z, ctx.cy + 10 * ctx.z,
                  math.max(4, 12 * ctx.z), COL.bad,
                  win.error or "project settings unavailable", 0)
    return
  end
  if a.text ~= win.source and form_dirty(win) then win.conflict = true end

  local z = ctx.z
  local px = math.max(4, 11.5 * z)
  local small = math.max(4, 9.5 * z)
  local row_h = 27 * z
  local label_w = 112 * z
  local y = ctx.cy + 8 * z
  pal.x_ig_text(ctx.cx + 10 * z, y, math.max(4, 13 * z), COL.hot,
                "identity", 0)
  y = y + 20 * z
  local any_active = false
  for index, spec in ipairs(FIELD_ROWS) do
    if index == 5 then
      y = y + 4 * z
      pal.x_ig_text(ctx.cx + 10 * z, y, math.max(4, 13 * z), COL.hot,
                    "game surface", 0)
      y = y + 20 * z
    end
    if draw_field(win, ctx, spec[1], spec[2], y, label_w, row_h, px) then
      any_active = true
    end
    y = y + row_h
  end
  if not any_active then win.editing = nil end

  -- Initial-window policy: editor boots are always maximized; this default is
  -- used by ordinary play launches on the next boot.
  local cbx = ctx.cx + 10 * z + label_w
  local cby = y + 4 * z
  local cs = 15 * z
  local i = cm.require("cm.ui").inp
  local chot = not ctx.occluded and ctx.hot
               and i.wx >= cbx and i.wx < cbx + cs
               and i.wy >= cby and i.wy < cby + cs
  pal.x_ig_text(ctx.cx + 10 * z, y + 5 * z, px, COL.dim, "start maximized", 0)
  pal.x_ig_rect_fill(cbx, cby, cs, cs, COL.well, 3 * z)
  pal.x_ig_rect(cbx, cby, cs, cs, chot and COL.hot or COL.edge, 1, 3 * z)
  if win.form.maximized then
    pal.x_ig_line(cbx + 3 * z, cby + 8 * z, cbx + 6 * z, cby + 12 * z,
                  COL.accent, math.max(1, 2 * z))
    pal.x_ig_line(cbx + 6 * z, cby + 12 * z, cbx + 13 * z, cby + 3 * z,
                  COL.accent, math.max(1, 2 * z))
  end
  if chot and i.clicked[1] then
    push_undo(win)
    win.form.maximized = not win.form.maximized
    win.error, win.status = nil, nil
    ctx.ed.touch()
  end
  y = y + 27 * z

  local _, validation = project.validate_settings(win.form)
  local merged = project.apply_settings(meta, win.form)
  local release_error
  if merged then _, release_error = project.validate_release(merged)
  else release_error = validation end
  local status, color
  if validation then status, color = validation, COL.bad
  elseif win.error then status, color = win.error, COL.bad
  elseif win.conflict then
    status, color = "project.lua also changed; save merges these fields", COL.warn
  elseif win.status then status, color = win.status, COL.accent
  else status, color = "valid draft settings", COL.accent end
  pal.x_ig_clip_push(ctx.cx + 10 * z, y, ctx.cw - 20 * z, 18 * z)
  pal.x_ig_text(ctx.cx + 10 * z, y, small, color, status, 0)
  pal.x_ig_clip_pop()
  y = y + 15 * z
  local release = release_error and ("export check: " .. release_error)
                  or "export metadata complete"
  pal.x_ig_clip_push(ctx.cx + 10 * z, y, ctx.cw - 20 * z, 18 * z)
  pal.x_ig_text(ctx.cx + 10 * z, y, small,
                release_error and COL.warn or COL.dim, release, 0)
  pal.x_ig_clip_pop()

  local bh = 25 * z
  local by = ctx.cy + ctx.ch - bh - 8 * z
  local valid = validation == nil
  if button(ctx, ctx.cx + 10 * z, by, 118 * z, bh, "save settings", valid) then
    M.save(win, ctx.ed)
  end
  if button(ctx, ctx.cx + 136 * z, by, 102 * z, bh, "reload form", true) then
    load_form(win, ctx.ed, true)
  end
  pal.x_ig_text(ctx.cx + 250 * z, by + 7 * z, small, COL.dim,
                "Ctrl+S saves · changes apply next launch", 0)
end

return M
