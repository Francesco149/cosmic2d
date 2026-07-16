-- cm.ed.win.project — A3's canonical in-editor project-settings surface.
--
-- The form does not own a second project model.  Its source is the text
-- window's project.lua working copy, so session recovery, journal undo, atomic
-- Ctrl+S, rewind capture, and simultaneous source editing all share one path.
-- Form strings live on the captured window only while they are temporarily
-- invalid; a successful save merges the editable fields into the latest
-- declarative source and preserves every unedited key.

local M = select(2, ...) or {}
local project = cm.require("cm.project")
local exporter = cm.require("cm.export")
local textwin = cm.require("cm.ed.win.text")
local assets = cm.require("cm.ed.win.assets")

M.kind = "project"
M.menu = "project settings"
M.help = "win-project"
M.DEF_W, M.DEF_H = 610, 440

local COL = {
  text = 0xd8d2f2ff, dim = 0x8a84b0ff, hot = 0xE8E4FFff,
  accent = 0x7fd8a8ff, warn = 0xffb46eff, bad = 0xf07a7aff,
  well = 0x141220ff, edge = 0x4a4370ff, button = 0x262238ff,
  button_hot = 0x3a3560ff,
}

local FORM_FIELDS = {
  "name", "author", "version", "description",
  "internal_w", "internal_h", "window_scale", "maximized",
  "icon", "controls", "credits",
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

local ASSET_PLUMBING = {
  { field = "text", gkey = "tw" }, { field = "spr", gkey = "sw" },
  { field = "map", gkey = "mw" }, { field = "tm", gkey = "tmw" },
  { field = "pal", gkey = "pw" }, { field = "ins", gkey = "iw" },
  { field = "song", gkey = "muw" },
}

local project_reader

local function copy_form(form)
  local out = {}
  for _, field in ipairs(FORM_FIELDS) do out[field] = form[field] end
  out.licenses = {}
  for i, path in ipairs(form.licenses or {}) do out.licenses[i] = path end
  return out
end

local function same_form(a, b)
  if not a or not b then return false end
  for _, field in ipairs(FORM_FIELDS) do
    if a[field] ~= b[field] then return false end
  end
  if #(a.licenses or {}) ~= #(b.licenses or {}) then return false end
  for i, path in ipairs(a.licenses or {}) do
    if path ~= b.licenses[i] then return false end
  end
  return true
end

local function form_dirty(win)
  return win.form ~= nil and not same_form(win.form, win.base)
end

local function export_key(win)
  -- Real canvas windows always have an id. The table fallback keeps the
  -- public preflight helpers useful to focused tests and console tooling.
  return win.id or win
end

local function find_export_state(win, ed)
  return ed.g.project_exports and ed.g.project_exports[export_key(win)]
end

local function default_output_dir()
  local root = pal.user_path()
  if type(root) ~= "string" or root == "" then return "" end
  return root .. (root:match("[\\/]$") and "" or "/") .. "exports"
end

-- Build choices and coroutine progress are machine-local operation state, not
-- captured editor state. Rewind/session serialization must never retain a
-- half-built artifact or a path from another computer.
function M.export_state(win, ed)
  ed.g.project_exports = ed.g.project_exports or {}
  local key = export_key(win)
  local state = ed.g.project_exports[key]
  if not state then
    state = {
      target = pal.platform, output_dir = default_output_dir(), replace = false,
    }
    ed.g.project_exports[key] = state
  end
  return state
end

-- Return the first unsaved path and the total. Every editable project-asset
-- kind uses kit.asset's working bytes + p.disk convention. If plumbing has
-- not been rebuilt after session recovery, compare against disk directly.
function M.export_unsaved(win, ed)
  local first, count, seen
  local function add(path)
    seen = seen or {}
    if seen[path] then return end
    seen[path] = true
    first, count = first or path, (count or 0) + 1
  end
  if form_dirty(win) then add("project.lua") end
  for _, other in ipairs(ed.doc.wins or {}) do
    if other.kind == "project" and form_dirty(other) then add("project.lua") end
  end
  local paths = {}
  for path in pairs(ed.doc.assets or {}) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local a = ed.doc.assets[path]
    for _, spec in ipairs(ASSET_PLUMBING) do
      local working = a[spec.field]
      if type(working) == "string" then
        local table_for_kind = ed.g[spec.gkey]
        local p = table_for_kind and table_for_kind[path]
        local disk = p and p.disk
        if disk == nil then disk = pal.read_file(ed.root .. "/" .. path) or "" end
        if working ~= disk then add(path) end
        break
      end
    end
  end
  return first, count or 0
end

local function runtime_error(target)
  if target ~= pal.platform then
    return (target == "windows" and "Windows" or "Linux")
      .. " export needs the matching cosmic2d editor download"
  end
  local required = target == "windows"
    and { { "bin/cosmic-player.exe", "file" } }
    or { { "lib", "directory" }, { "cosmic2d-editor", "file" } }
  for _, spec in ipairs(required) do
    local info = pal.x_path_info(spec[1])
    if not info or info.type ~= spec[2] or info.link then
      return "portable " .. (target == "windows" and "Windows" or "Linux")
        .. " runtime is missing " .. spec[1]
        .. "; run this from the matching editor archive"
    end
  end
end

-- `summary` is the draw-time cached form/reference result. Without it this is
-- the click-time authority: re-read the saved project and every release file
-- before starting the coroutine. The exporter repeats this at its first yield
-- so console callers receive the same contract.
function M.export_preflight(win, ed, state, summary)
  state = state or M.export_state(win, ed)
  if ed.parked then return nil, "return to the present before exporting" end
  if state.target ~= "linux" and state.target ~= "windows" then
    return nil, "choose Linux or Windows"
  end
  local dirty, dirty_count = M.export_unsaved(win, ed)
  if dirty then
    local more = dirty_count > 1 and (" and " .. (dirty_count - 1) .. " more") or ""
    return nil, "save " .. dirty .. more .. " before exporting"
  end
  if summary then
    if summary.validation then return nil, summary.validation end
    if not summary.configured then
      return nil, "choose icon, controls, credits, and a project license"
    end
    if summary.release_error then return nil, summary.release_error end
  else
    local bytes, err = pal.read_file(ed.root .. "/project.lua")
    if not bytes then return nil, "cannot read saved project.lua: " .. tostring(err) end
    local meta
    meta, err = project.decode(bytes, "@" .. ed.root .. "/project.lua")
    if not meta then return nil, err end
    local checked
    checked, err = project.validate_release_files(meta, project_reader(ed))
    if not checked then return nil, "player metadata: " .. tostring(err) end
  end
  if tostring(state.output_dir or ""):find("[%z\r\n]") then
    return nil, "output folder contains unsafe characters"
  end
  local err = runtime_error(state.target)
  if err then return nil, err end
  return true
end

function M.begin_export(win, ed, state)
  state = state or M.export_state(win, ed)
  if state.job and not state.job.terminal then
    state.notice = "an export is already running"
    return nil, state.notice
  end
  local ok, err = M.export_preflight(win, ed, state)
  if not ok then
    state.job, state.result, state.notice = nil, nil, nil
    state.error = tostring(err)
    return nil, state.error
  end
  state.error, state.result, state.notice, state.logged = nil, nil, nil, nil
  state.job = exporter.start {
    runtime_root = ".", project_root = ed.root,
    output_dir = state.output_dir, target = state.target,
    replace = state.replace,
  }
  pal.log("[ed] EXPORT STARTED: " .. ed.root)
  return state.job
end

local function tick_export(win, ed)
  local state = find_export_state(win, ed)
  local job = state and state.job
  if not job or job.terminal then return end
  exporter.step(job)
  if not job.terminal or state.logged then return end
  state.logged = true
  if job.complete then
    state.result, state.error, state.notice = job.output, nil, nil
    pal.log("[ed] EXPORT COMPLETE: " .. tostring(job.output))
  elseif job.cancelled then
    state.result, state.error, state.notice = nil, nil, "export cancelled; nothing published"
    pal.log("[ed] EXPORT CANCELLED: " .. ed.root)
  else
    state.result, state.error = nil, job.error or job.detail or "export failed"
    pal.log("[ed] EXPORT FAILED: " .. tostring(state.error))
    if ed.summon_console then ed.summon_console() end
  end
end

function M.can_close(win, ed)
  local state = find_export_state(win, ed)
  if state and state.job and not state.job.terminal then
    state.notice = "cancel the export before closing this window"
    return false
  end
  return true
end

function M.guard_export(ed, action)
  for _, state in pairs(ed.g.project_exports or {}) do
    if state.job and not state.job.terminal then
      state.notice = "finish or cancel the export before " .. tostring(action or "continuing")
      pal.log("[ed] " .. state.notice)
      return true
    end
  end
  return false
end

function M.drop_ephemeral(ed)
  for _, state in pairs(ed.g.project_exports or {}) do
    exporter.cleanup(state.job)
  end
  ed.g.project_exports = nil
end

function M.defaults()
  return { path = "project.lua", section = "general" }
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
  win.picking, win.pick_filter = nil, nil
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

local function edit_license(win, ed, index, value)
  local editing = "license:" .. index
  if win.form.licenses[index] == value then return end
  if win.editing ~= editing then
    push_undo(win)
    win.editing = editing
  end
  win.form.licenses[index] = value
  win.error, win.status = nil, nil
  ed.touch()
end

-- The picker and focused tests share one mutation door. A selected path is
-- still validated from disk before save; choosing it is never an assertion
-- that the file has the right content.
function M.select_reference(win, ed, field, path, index)
  if field ~= "icon" and field ~= "controls" and field ~= "credits"
      and field ~= "license" then
    return nil, "unknown project release field: " .. tostring(field)
  end
  push_undo(win)
  if field == "license" then
    index = index or (#win.form.licenses + 1)
    win.form.licenses[index] = path
  else
    win.form[field] = path
  end
  win.editing, win.error, win.status = nil, nil, nil
  win.picking, win.pick_filter = nil, nil
  ed.touch()
  return true
end

function M.remove_license(win, ed, index)
  if not win.form.licenses[index] then return false end
  push_undo(win)
  table.remove(win.form.licenses, index)
  win.license_offset = math.max(1, math.min(win.license_offset or 1,
                                            #win.form.licenses))
  win.editing, win.error, win.status = nil, nil, nil
  ed.touch()
  return true
end

project_reader = function(ed)
  return function(path)
    return pal.read_file(ed.root .. "/" .. path)
  end
end

-- Cache compact live reference probes by field/path/mtime. In particular, do
-- not read an 8 MiB icon sixty times a second or retain every chooser candidate.
local function reference_check(ed, kind, field, path)
  local safe, path_err = project.project_path(field, path)
  if not safe then return nil, path_err end
  ed.g.project_ref_checks = ed.g.project_ref_checks or {}
  local key = kind .. "\0" .. field .. "\0" .. path
  local mtime = pal.mtime(ed.root .. "/" .. path) or false
  local hit = ed.g.project_ref_checks[key]
  if hit and hit.mtime == mtime then return hit.ref, hit.err end
  local ref, err = project.validate_release_reference(
    kind, field, path, project_reader(ed))
  if ref then
    ref = { path = ref.path, w = ref.w, h = ref.h, size = #ref.bytes }
  end
  ed.g.project_ref_checks[key] = { mtime = mtime, ref = ref, err = err }
  return ref, err
end

local function release_check(ed, meta)
  local release, err = project.validate_release(meta)
  if not release then return nil, err end
  local ref
  ref, err = reference_check(ed, "icon", "icon", release.icon)
  if not ref then return nil, err end
  ref, err = reference_check(ed, "text", "controls", release.controls)
  if not ref then return nil, err end
  ref, err = reference_check(ed, "text", "credits", release.credits)
  if not ref then return nil, err end
  for i, path in ipairs(release.licenses) do
    ref, err = reference_check(ed, "text", "licenses[" .. i .. "]", path)
    if not ref then return nil, err end
  end
  return release
end

function M.validate(win, ed)
  local a = load_form(win, ed, false)
  if not a then return nil, win.error end
  local settings, err = project.validate_settings(win.form)
  if not settings then return nil, err end
  if not settings.release then return settings end
  local latest
  latest, err = project.decode(a.text, "@" .. ed.root .. "/project.lua")
  if not latest then return nil, err end
  local merged
  merged, err = project.apply_settings(latest, win.form)
  if not merged then return nil, err end
  local checked
  checked, err = project.validate_release_files(merged, project_reader(ed))
  if not checked then return nil, err end
  return settings, checked
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
  if project.release_configured(merged) then
    local checked
    checked, err = project.validate_release_files(merged, project_reader(ed))
    if not checked then return set_error(win, ed, err) end
  end
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
  win.status = project.release_configured(merged)
    and "saved — player metadata is export-ready"
    or "saved — resolution and window defaults apply next launch"
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

local function section_tabs(win, ctx, y)
  local z = ctx.z
  local h, w = 24 * z, 92 * z
  local x = ctx.cx + 10 * z
  for _, tab in ipairs({ { "general", "general" },
                         { "release", "player files" },
                         { "build", "build/export" } }) do
    if button(ctx, x, y, w, h, tab[2], true) then
      win.section = tab[1]
      win.picking, win.pick_filter, win.editing = nil, nil, nil
      ctx.ed.touch()
    end
    if (win.section or "general") == tab[1] then
      pal.x_ig_line(x + 7 * z, y + h - 2 * z, x + w - 7 * z, y + h - 2 * z,
                    COL.accent, math.max(1, 2 * z))
    end
    x = x + w + 6 * z
  end
  return y + h + 8 * z
end

local function draw_general(win, ctx, y)
  local z = ctx.z
  local px = math.max(4, 11.5 * z)
  local row_h = 27 * z
  local label_w = 112 * z
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
  return y + 27 * z
end

local function begin_picker(win, ctx, field, index)
  win.picking = { field = field, index = index }
  win.pick_filter, win.editing = "", nil
  ctx.ed.touch()
end

local function reference_status(ed, kind, field, path)
  if path == nil or path == "" then return "not selected", COL.dim end
  local ref, err = reference_check(ed, kind, field, path)
  if not ref then return err, COL.bad end
  if kind == "icon" then
    return ("ready · %d×%d PNG"):format(ref.w, ref.h), COL.accent
  end
  return ("ready · %d bytes"):format(ref.size), COL.accent
end

local function draw_reference_status(ctx, y, kind, field, path, x)
  local small = math.max(4, 9 * ctx.z)
  local status, color = reference_status(ctx.ed, kind, field, path)
  x = x or (ctx.cx + 10 * ctx.z)
  pal.x_ig_clip_push(x, y, ctx.cx + ctx.cw - x - 8 * ctx.z, 14 * ctx.z)
  pal.x_ig_text(x, y, small, color, status, 0)
  pal.x_ig_clip_pop()
end

local function draw_path_field(win, ctx, field, label, y, kind)
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local row_h, label_w, choose_w = 27 * z, 86 * z, 64 * z
  local x = ctx.cx + 10 * z
  local fx = x + label_w
  local fw = ctx.cw - 20 * z - label_w - choose_w - 6 * z
  pal.x_ig_text(x, y + (row_h - px) * 0.42, px, COL.dim, label, 0)
  pal.x_ig_rect_fill(fx, y + 2 * z, fw, row_h - 4 * z, COL.well, 3 * z)
  pal.x_ig_rect(fx, y + 2 * z, fw, row_h - 4 * z, COL.edge, 1, 3 * z)
  local active = false
  if ctx.occluded then
    pal.x_ig_clip_push(fx + 5 * z, y, fw - 10 * z, row_h)
    pal.x_ig_text(fx + 5 * z, y + (row_h - px) * 0.42, px, COL.text,
                  win.form[field] or "", 1)
    pal.x_ig_clip_pop()
  else
    local value, changed
    value, changed, active = pal.x_ig_edit {
      id = "project_" .. field .. win.id,
      x = fx + 4 * z, y = y + 4 * z, w = fw - 8 * z, h = row_h - 8 * z,
      text = win.form[field] or "", px = px, font = 1, multiline = false,
    }
    if changed then edit_field(win, ctx.ed, field, value) end
  end
  if button(ctx, fx + fw + 6 * z, y + 2 * z, choose_w, row_h - 4 * z,
            "choose", true) then
    begin_picker(win, ctx, field)
  end
  draw_reference_status(ctx, y + row_h - 1 * z, kind, field,
                        win.form[field], fx)
  return y + row_h + 13 * z, active
end

local function draw_license_row(win, ctx, index, y)
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local row_h, label_w = 25 * z, 86 * z
  local choose_w, remove_w = 52 * z, 55 * z
  local x = ctx.cx + 10 * z
  local fx = x + label_w
  local fw = ctx.cw - 20 * z - label_w - choose_w - remove_w - 10 * z
  pal.x_ig_text(x, y + (row_h - px) * 0.42, px, COL.dim,
                "license " .. index, 0)
  pal.x_ig_rect_fill(fx, y + 1 * z, fw, row_h - 2 * z, COL.well, 3 * z)
  pal.x_ig_rect(fx, y + 1 * z, fw, row_h - 2 * z, COL.edge, 1, 3 * z)
  local active = false
  if ctx.occluded then
    pal.x_ig_clip_push(fx + 5 * z, y, fw - 10 * z, row_h)
    pal.x_ig_text(fx + 5 * z, y + (row_h - px) * 0.42, px, COL.text,
                  win.form.licenses[index] or "", 1)
    pal.x_ig_clip_pop()
  else
    local value, changed
    value, changed, active = pal.x_ig_edit {
      id = "project_license_" .. index .. "_" .. win.id,
      x = fx + 4 * z, y = y + 3 * z, w = fw - 8 * z, h = row_h - 6 * z,
      text = win.form.licenses[index] or "", px = px, font = 1,
      multiline = false,
    }
    if changed then edit_license(win, ctx.ed, index, value) end
  end
  local bx = fx + fw + 5 * z
  if button(ctx, bx, y + 1 * z, choose_w, row_h - 2 * z, "choose", true) then
    begin_picker(win, ctx, "license", index)
  end
  if button(ctx, bx + choose_w + 5 * z, y + 1 * z, remove_w,
            row_h - 2 * z, "remove", true) then
    M.remove_license(win, ctx.ed, index)
  end
  draw_reference_status(ctx, y + row_h - 1 * z, "text",
                        "licenses[" .. index .. "]",
                        win.form.licenses[index], fx)
  return y + row_h + 12 * z, active
end

local function clear_release(win, ed)
  push_undo(win)
  win.form.icon, win.form.controls, win.form.credits = "", "", ""
  win.form.licenses = {}
  win.license_offset = 1
  win.editing, win.error, win.status = nil, nil, nil
  ed.touch()
end

local function draw_release(win, ctx, y)
  local z = ctx.z
  local small = math.max(4, 9.5 * z)
  pal.x_ig_text(ctx.cx + 10 * z, y, math.max(4, 13 * z), COL.hot,
                "player bundle identity", 0)
  pal.x_ig_text(ctx.cx + 180 * z, y + 2 * z, small, COL.dim,
                "all files stay project-local", 0)
  y = y + 21 * z
  local active, a
  y, a = draw_path_field(win, ctx, "icon", "icon", y, "icon")
  active = active or a
  y, a = draw_path_field(win, ctx, "controls", "controls", y, "text")
  active = active or a
  y, a = draw_path_field(win, ctx, "credits", "credits", y, "text")
  active = active or a

  pal.x_ig_text(ctx.cx + 10 * z, y + 4 * z, math.max(4, 12 * z), COL.hot,
                "licenses", 0)
  if button(ctx, ctx.cx + 92 * z, y, 82 * z, 23 * z, "add file", true) then
    begin_picker(win, ctx, "license", #win.form.licenses + 1)
  end
  if project.release_configured(win.form)
      and button(ctx, ctx.cx + 181 * z, y, 100 * z, 23 * z,
                 "clear release", true) then
    clear_release(win, ctx.ed)
  end
  y = y + 29 * z

  local count = #win.form.licenses
  if count == 0 then
    pal.x_ig_text(ctx.cx + 96 * z, y, small, COL.bad,
                  "at least one project license is required", 0)
    y = y + 25 * z
  else
    local footer_top = ctx.cy + ctx.ch - 70 * z
    local max_rows = math.max(1, math.min(4,
      math.floor((footer_top - y) / (37 * z))))
    local max_offset = math.max(1, count - max_rows + 1)
    win.license_offset = math.max(1, math.min(win.license_offset or 1, max_offset))
    for index = win.license_offset,
        math.min(count, win.license_offset + max_rows - 1) do
      y, a = draw_license_row(win, ctx, index, y)
      active = active or a
    end
    if count > max_rows then
      local label = ("showing %d–%d of %d"):format(
        win.license_offset, math.min(count, win.license_offset + max_rows - 1), count)
      pal.x_ig_text(ctx.cx + 96 * z, y + 4 * z, small, COL.dim, label, 0)
      if button(ctx, ctx.cx + ctx.cw - 118 * z, y, 52 * z, 22 * z,
                "prev", win.license_offset > 1) then
        win.license_offset = math.max(1, win.license_offset - max_rows)
        ctx.ed.touch()
      end
      if button(ctx, ctx.cx + ctx.cw - 61 * z, y, 52 * z, 22 * z,
                "next", win.license_offset < max_offset) then
        win.license_offset = math.min(max_offset, win.license_offset + max_rows)
        ctx.ed.touch()
      end
    end
  end
  if not active then win.editing = nil end
end

local function human_bytes(n)
  n = tonumber(n) or 0
  if n >= 1024 * 1024 * 1024 then return ("%.1f GiB"):format(n / (1024 ^ 3)) end
  if n >= 1024 * 1024 then return ("%.1f MiB"):format(n / (1024 ^ 2)) end
  if n >= 1024 then return ("%.1f KiB"):format(n / 1024) end
  return tostring(n) .. " B"
end

local function draw_clipped(ctx, x, y, w, px, color, value, font)
  pal.x_ig_clip_push(x, y, w, px + 5 * ctx.z)
  pal.x_ig_text(x, y, px, color, tostring(value or ""), font or 0)
  pal.x_ig_clip_pop()
end

local function draw_export_checkbox(ctx, state, x, y, enabled)
  local z = ctx.z
  local size = 15 * z
  local i = cm.require("cm.ui").inp
  local hot = enabled and not ctx.occluded and ctx.hot
    and i.wx >= x and i.wx < x + size
    and i.wy >= y and i.wy < y + size
  pal.x_ig_rect_fill(x, y, size, size, COL.well, 3 * z)
  pal.x_ig_rect(x, y, size, size, hot and COL.hot or COL.edge, 1, 3 * z)
  if state.replace then
    pal.x_ig_line(x + 3 * z, y + 8 * z, x + 6 * z, y + 12 * z,
                  COL.accent, math.max(1, 2 * z))
    pal.x_ig_line(x + 6 * z, y + 12 * z, x + 13 * z, y + 3 * z,
                  COL.accent, math.max(1, 2 * z))
  end
  pal.x_ig_text(x + 22 * z, y + 3 * z, math.max(4, 9.5 * z), COL.dim,
                "atomically replace a matching existing export", 0)
  if hot and i.clicked[1] then state.replace = not state.replace end
end


local function draw_build(win, ctx, y, summary)
  local z = ctx.z
  local x = ctx.cx + 10 * z
  local w = ctx.cw - 20 * z
  local px = math.max(4, 10.5 * z)
  local small = math.max(4, 9.2 * z)
  local state = M.export_state(win, ctx.ed)
  local job = state.job
  local editable = not job or job.terminal

  pal.x_ig_text(x, y, math.max(4, 13 * z), COL.hot, "portable player archive", 0)
  y = y + 20 * z
  pal.x_ig_text(x, y, small, COL.dim,
                "Packages the saved project with this editor's matching runtime.", 0)
  y = y + 25 * z

  pal.x_ig_text(x, y + 7 * z, px, COL.dim, "target", 0)
  local bx = x + 86 * z
  local bw, bh = 118 * z, 25 * z
  for _, spec in ipairs({ { "linux", "Linux · .tar.gz" },
                           { "windows", "Windows · .zip" } }) do
    if button(ctx, bx, y, bw, bh, spec[2], editable) then
      state.target, state.error, state.notice = spec[1], nil, nil
    end
    if state.target == spec[1] then
      pal.x_ig_line(bx + 7 * z, y + bh - 2 * z, bx + bw - 7 * z,
                    y + bh - 2 * z, COL.accent, math.max(1, 2 * z))
    end
    bx = bx + bw + 7 * z
  end
  y = y + 31 * z
  local host = pal.platform == "windows" and "Windows" or "Linux"
  pal.x_ig_text(x + 86 * z, y, small, COL.dim,
                "This download carries the " .. host .. " player runtime.", 0)
  y = y + 22 * z

  pal.x_ig_text(x, y + 7 * z, px, COL.dim, "output folder", 0)
  local fx, fh = x + 86 * z, 27 * z
  local fw = w - 86 * z
  pal.x_ig_rect_fill(fx, y, fw, fh, COL.well, 3 * z)
  pal.x_ig_rect(fx, y, fw, fh, COL.edge, 1, 3 * z)
  if ctx.occluded or not editable then
    draw_clipped(ctx, fx + 5 * z, y + 7 * z, fw - 10 * z, small,
                 COL.text, state.output_dir, 1)
  else
    local value, changed = pal.x_ig_edit {
      id = "project_export_output_" .. tostring(win.id),
      x = fx + 4 * z, y = y + 3 * z, w = fw - 8 * z, h = fh - 6 * z,
      text = state.output_dir or "", px = small, font = 1, multiline = false,
    }
    if changed then
      state.output_dir = value:gsub("[\r\n\t]", "")
      state.error, state.notice = nil, nil
    end
  end
  y = y + 34 * z
  draw_export_checkbox(ctx, state, fx, y, editable)
  y = y + 27 * z

  local ready, preflight_error = M.export_preflight(win, ctx.ed, state, summary)
  local state_color = ready and COL.accent or COL.bad
  local state_text = ready and "preflight ready · saved bytes will be checked again"
                     or preflight_error
  pal.x_ig_text(x, y, small, state_color, "preflight", 0)
  draw_clipped(ctx, x + 69 * z, y, w - 69 * z, small, state_color, state_text, 0)
  y = y + 20 * z

  if job then
    local phase_color = job.error and COL.bad
      or job.cancelled and COL.warn or job.complete and COL.accent or COL.text
    pal.x_ig_text(x, y, px, phase_color, job.phase or "export", 0)
    local progress = job.total and job.total > 0 and (job.done or 0) / job.total or 0
    progress = math.max(0, math.min(1, progress))
    local barx, bary, barw, barh = x + 86 * z, y + 1 * z,
                                      w - 86 * z, 11 * z
    pal.x_ig_rect_fill(barx, bary, barw, barh, COL.well, 3 * z)
    pal.x_ig_rect_fill(barx, bary, barw * progress, barh,
                       job.error and COL.bad or COL.accent, 3 * z)
    pal.x_ig_rect(barx, bary, barw, barh, COL.edge, 1, 3 * z)
    y = y + 18 * z
    draw_clipped(ctx, x, y, w, small, phase_color, job.detail, 1)
    y = y + 17 * z
    if job.complete then
      draw_clipped(ctx, x, y, w, small, COL.accent,
                   human_bytes(job.bytes) .. " · " .. tostring(job.output), 1)
      y = y + 16 * z
      draw_clipped(ctx, x, y, w, small, COL.dim,
                   "SHA-256  " .. tostring(job.checksum), 1)
    elseif job.error then
      draw_clipped(ctx, x, y, w, small, COL.bad, job.error, 0)
    elseif job.cancelled then
      pal.x_ig_text(x, y, small, COL.warn, "Nothing was published.", 0)
    end
  elseif state.error then
    draw_clipped(ctx, x, y, w, small, COL.bad, state.error, 0)
  else
    pal.x_ig_text(x, y, small, COL.dim,
                  "The archive and sibling .sha256 appear only after a complete build.", 0)
  end

  local action_y = ctx.cy + ctx.ch - 101 * z
  if job and not job.terminal then
    if button(ctx, x, action_y, 118 * z, 25 * z, "cancel export", true) then
      exporter.cancel(job)
      state.notice = "cancelling after the current file"
    end
  else
    local label = job and job.error and "retry export"
      or job and job.complete and "build again" or "build export"
    if button(ctx, x, action_y, 118 * z, 25 * z, label, ready) then
      M.begin_export(win, ctx.ed, state)
    end
  end
  if state.notice then
    draw_clipped(ctx, x + 128 * z, action_y + 7 * z, w - 128 * z,
                 small, COL.warn, state.notice, 0)
  elseif job and not job.terminal then
    pal.x_ig_text(x + 128 * z, action_y + 7 * z, small, COL.dim,
                  "You can change tabs; close and rewind stay guarded.", 0)
  end
end

local function picker_accepts(field, path)
  local lower = path:lower()
  if field == "icon" then return lower:match("%.png$") ~= nil end
  if field == "controls" or field == "credits" then
    return lower:match("%.md$") ~= nil or lower:match("%.txt$") ~= nil
  end
  local base = lower:match("([^/]*)$") or lower
  local legal = base == "license" or base == "licence"
                or base == "copying" or base == "notice" or base == "copyright"
                or base:match("^licen[cs]e[%._%-]")
                or base:match("^copying[%._%-]") or base:match("^notice[%._%-]")
                or base:match("^copyright[%._%-]")
  return lower:match("%.md$") ~= nil or lower:match("%.txt$") ~= nil
         or lower:match("%.license$") ~= nil or not not legal
end

local function draw_picker(win, ctx)
  local pick = win.picking
  local z = ctx.z
  local px = math.max(4, 10.5 * z)
  local field = pick.field
  local title = field == "license" and "choose a license/notice"
                or "choose " .. field
  local y = ctx.cy + 9 * z
  pal.x_ig_text(ctx.cx + 10 * z, y + 4 * z, math.max(4, 13 * z), COL.hot,
                title, 0)
  if button(ctx, ctx.cx + ctx.cw - 78 * z, y, 68 * z, 24 * z,
            "cancel", true) then
    win.picking, win.pick_filter = nil, nil
    ctx.ed.touch()
    return
  end
  y = y + 32 * z
  local fh = 25 * z
  pal.x_ig_rect_fill(ctx.cx + 10 * z, y, ctx.cw - 20 * z, fh, COL.well, 3 * z)
  pal.x_ig_rect(ctx.cx + 10 * z, y, ctx.cw - 20 * z, fh, COL.edge, 1, 3 * z)
  if (win.pick_filter or "") == "" then
    pal.x_ig_text(ctx.cx + 15 * z, y + 6 * z, px, 0x8a84b066,
                  "fuzzy search project files", 1)
  end
  if not ctx.occluded then
    local filter, changed = pal.x_ig_edit {
      id = "project_release_picker_" .. win.id,
      x = ctx.cx + 15 * z, y = y + 3 * z, w = ctx.cw - 30 * z,
      h = fh - 6 * z, text = win.pick_filter or "", px = px, font = 1,
      multiline = false,
    }
    if changed then
      win.pick_filter = filter:gsub("[\r\n\t]", "")
      ctx.ed.touch()
    end
  else
    pal.x_ig_text(ctx.cx + 15 * z, y + 6 * z, px, COL.text,
                  win.pick_filter or "", 1)
  end
  y = y + fh + 8 * z

  local shown = {}
  for _, path in ipairs(assets.release_files(ctx.ed)) do
    if picker_accepts(field, path) then
      local score = assets.fuzzy(win.pick_filter or "", path)
      if score then shown[#shown + 1] = { path = path, score = score } end
    end
  end
  table.sort(shown, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.path < b.path
  end)

  local row_h = 30 * z
  local room = math.max(1, math.floor((ctx.cy + ctx.ch - y - 28 * z) / row_h))
  local i = cm.require("cm.ui").inp
  local kind = field == "icon" and "icon" or "text"
  local validation_field = field == "license"
    and "licenses[" .. tostring(pick.index or 1) .. "]" or field
  for n = 1, math.min(#shown, room) do
    local path = shown[n].path
    local ref, err = reference_check(ctx.ed, kind, validation_field, path)
    local hot = ref and not ctx.occluded and ctx.hot
                and i.wx >= ctx.cx + 7 * z and i.wx < ctx.cx + ctx.cw - 7 * z
                and i.wy >= y and i.wy < y + row_h
    if hot then
      pal.x_ig_rect_fill(ctx.cx + 6 * z, y, ctx.cw - 12 * z, row_h,
                         COL.button_hot, 4 * z)
    end
    pal.x_ig_text(ctx.cx + 12 * z, y + 7 * z, px,
                  ref and (hot and COL.hot or COL.text) or COL.bad, path, 1)
    local detail = ref and (kind == "icon" and (ref.w .. "×" .. ref.h .. " PNG")
                            or (ref.size .. " bytes"))
                   or err
    local dw = pal.x_ig_text_size(detail, px * 0.85, 0)
    pal.x_ig_clip_push(ctx.cx + ctx.cw * 0.55, y,
                       ctx.cw * 0.45 - 14 * z, row_h)
    pal.x_ig_text(math.max(ctx.cx + ctx.cw * 0.55,
                           ctx.cx + ctx.cw - 12 * z - dw),
                  y + 8 * z, px * 0.85, ref and COL.dim or COL.bad, detail, 0)
    pal.x_ig_clip_pop()
    if hot and i.clicked[1] then
      M.select_reference(win, ctx.ed, field, path, pick.index)
      return
    end
    y = y + row_h
  end
  if #shown == 0 then
    pal.x_ig_text(ctx.cx + 12 * z, y + 5 * z, px, COL.dim,
                  "no matching project files", 0)
  elseif #shown > room then
    pal.x_ig_text(ctx.cx + 12 * z, ctx.cy + ctx.ch - 34 * z,
                  px * 0.9, COL.dim,
                  tostring(#shown - room) .. " more · narrow the search", 0)
  end
  pal.x_ig_text(ctx.cx + 12 * z, ctx.cy + ctx.ch - 18 * z,
                math.max(4, 8.5 * z), COL.dim,
                "Import files by dropping them into the editor; invalid candidates are disabled.",
                0)
end

function M.escape(win, ed)
  if win.picking then
    win.picking, win.pick_filter = nil, nil
    ed.touch()
    return true
  end
  local state = find_export_state(win, ed)
  if state and state.job and not state.job.terminal then
    state.notice = "export is active; use Cancel Export to stop it safely"
    return true
  end
  return false
end

function M.draw(win, ctx)
  tick_export(win, ctx.ed)
  local a, meta = load_form(win, ctx.ed, false)
  if not a or not win.form then
    pal.x_ig_text(ctx.cx + 10 * ctx.z, ctx.cy + 10 * ctx.z,
                  math.max(4, 12 * ctx.z), COL.bad,
                  win.error or "project settings unavailable", 0)
    return
  end
  if a.text ~= win.source and form_dirty(win) then win.conflict = true end
  if win.picking then draw_picker(win, ctx); return end

  local settings, validation = project.validate_settings(win.form)
  local merged
  if settings then merged, validation = project.apply_settings(meta, win.form) end
  local configured = project.release_configured(win.form)
  local release_error
  if configured then
    if merged then _, release_error = release_check(ctx.ed, merged)
    else release_error = validation end
  end
  local summary = {
    validation = validation, configured = configured,
    release_error = release_error,
  }

  local z = ctx.z
  local y = section_tabs(win, ctx, ctx.cy + 8 * z)
  if (win.section or "general") == "release" then
    draw_release(win, ctx, y)
  elseif win.section == "build" then
    draw_build(win, ctx, y, summary)
  else
    draw_general(win, ctx, y)
  end

  local status, color
  if validation then status, color = validation, COL.bad
  elseif win.error then status, color = win.error, COL.bad
  elseif win.conflict then
    status, color = "project.lua also changed; save merges these fields", COL.warn
  elseif win.status then status, color = win.status, COL.accent
  else
    status, color = configured and "valid project settings" or "valid draft settings",
                    COL.accent
  end

  local bh = 25 * z
  local by = ctx.cy + ctx.ch - bh - 8 * z
  local small = math.max(4, 9.5 * z)
  local sy = by - 34 * z
  pal.x_ig_clip_push(ctx.cx + 10 * z, sy, ctx.cw - 20 * z, 16 * z)
  pal.x_ig_text(ctx.cx + 10 * z, sy, small, color, status, 0)
  pal.x_ig_clip_pop()
  local release_status, release_color
  if not configured then
    release_status, release_color =
      "export check: draft — choose icon, controls, credits, and a license", COL.dim
  elseif release_error then
    release_status, release_color = "export check: " .. release_error, COL.bad
  else
    release_status, release_color = "export metadata complete", COL.accent
  end
  pal.x_ig_clip_push(ctx.cx + 10 * z, sy + 15 * z, ctx.cw - 20 * z, 16 * z)
  pal.x_ig_text(ctx.cx + 10 * z, sy + 15 * z, small,
                release_color, release_status, 0)
  pal.x_ig_clip_pop()

  local valid = validation == nil and (not configured or release_error == nil)
  if button(ctx, ctx.cx + 10 * z, by, 118 * z, bh, "save settings", valid) then
    M.save(win, ctx.ed)
  end
  if button(ctx, ctx.cx + 136 * z, by, 102 * z, bh, "reload form", true) then
    load_form(win, ctx.ed, true)
  end
  pal.x_ig_text(ctx.cx + 250 * z, by + 7 * z, small, COL.dim,
                "Ctrl+S saves · referenced files validate live", 0)
end

return M
