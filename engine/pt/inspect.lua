-- pt.inspect — the M4 entity/state inspector: a searchable tree over ALL
-- live sim state — the doc tree and every named buffer — with in-place
-- editors. Engine editor chrome, drawn by pt.editor beside its toolbar;
-- dev/render class by the D021 iron rule (expansion state, lens choices
-- and the search string live on this module table, never recorded).
--
-- The D026 discipline, same as map painting: this module READS sim state
-- freely every frame but never writes any directly — every edit is a
-- command string submitted through pt.repl, draining at the next sim
-- frame start and recording as a D022 EVAL chunk:
--
--   doc.knobs.move.run = 142.0                          drag a number
--   doc.demo = 1                                        (integers stay
--   pt.state.buf_poke("sandbox.player","f32",0,920.0)    integers, floats
--   pal.buf_free("husk")                                 stay floats)
--
-- so a live tuning session replays and verifies byte-exact, and the panel
-- works mid-autopsy too (a contained game error pauses the sim and the
-- repl drains immediately).
--
-- Doc values: numbers drag-edit (speed ~1% of magnitude per pixel),
-- booleans toggle, strings are read-only in v0 (the console edits them);
-- tables expand/collapse, root level open by default. Searching shows
-- matching leaves flat, full-path labels, editors live.
--
-- Buffers expand to a typed lens view (u8..f64, per buffer) of every
-- cell, drag-editable the same way. A cell the sim rewrites every frame
-- fights back exactly as you'd expect — the poke lands at frame start,
-- then the sim runs: nudging a position works, pinning a velocity
-- doesn't. That's live editing semantics, not a bug. The free button
-- (hidden for engine pt.* buffers) is the manual cleanup for
-- reload-orphaned buffer husks the PLAN promises; freeing a buffer some
-- module still writes is a contained game error, not a crash.

local M = select(2, ...) or {}

local ui = pt.require("pt.ui")
local repl = pt.require("pt.repl")
local state = pt.require("pt.state")

M.open_doc = M.open_doc or {} -- doc path -> explicit open/closed override
M.open_buf = M.open_buf or {} -- buffer name -> expanded flag
M.lens = M.lens or {} -- buffer name -> view kind (default f32)
M.search = M.search or ""

-- ---- eval-string building (pure helpers; selftested) ----

local LUA_KEYWORD = {}
for w in ([[and break do else elseif end false for function goto if in
local nil not or repeat return then true until while]]):gmatch("%a+") do
  LUA_KEYWORD[w] = true
end

-- append one doc key to an eval path: dotted when it reads clean,
-- bracket form for integers, keywords and non-identifier strings
function M.path_append(eval, k)
  if math.type(k) == "integer" then return eval .. ("[%d]"):format(k) end
  if type(k) == "string" and k:match("^[%a_][%w_]*$")
     and not LUA_KEYWORD[k] then
    return eval .. "." .. k
  end
  return eval .. ("[%q]"):format(tostring(k))
end

-- a number/boolean as an eval literal reproducing value AND type: floats
-- keep a ".0"/dot/exponent so an integral 142.0 never comes back as a Lua
-- integer (the canon serializer tags them differently and integer drag
-- rounding would lock in). 9 significant digits: tuning precision,
-- compact console echoes.
function M.fmt_value(v)
  if type(v) == "boolean" then return tostring(v) end
  if math.type(v) == "integer" then return ("%d"):format(v) end
  if v == math.huge then return "(1/0)" end
  if v == -math.huge then return "(-1/0)" end
  local s = ("%.9g"):format(v)
  if s:match("^%-?%d+$") then s = s .. ".0" end
  return s
end

-- ---- doc tree rows ----

local function drag_speed(v)
  local mag = math.abs(v)
  if math.type(v) == "integer" then return math.max(0.5, mag / 100) end
  return math.max(0.002, mag / 100)
end

local function sorted_keys(t)
  local ik, sk = {}, {}
  for k in pairs(t) do
    if math.type(k) == "integer" then
      ik[#ik + 1] = k
    elseif type(k) == "string" then
      sk[#sk + 1] = k
    end
  end
  table.sort(ik)
  table.sort(sk)
  for _, k in ipairs(sk) do ik[#ik + 1] = k end
  return ik
end

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- flatten the doc tree into visible rows. Tree mode (q == ""): tables are
-- expandable, children indent. Search mode: matching LEAVES only, flat,
-- full-path labels. seen guards against shared subtables (the doc must be
-- a tree; the serializer would refuse it — don't hang before it can).
local function add_doc_rows(rows, t, dotted, eval, depth, q, seen)
  if seen[t] then
    rows[#rows + 1] = { kind = "note", depth = depth,
                        label = "(shared table - doc must be a tree)" }
    return
  end
  seen[t] = true
  for _, k in ipairs(sorted_keys(t)) do
    local v = t[k]
    local p = dotted == "" and tostring(k) or dotted .. "." .. tostring(k)
    if type(v) == "table" then
      if q ~= "" then
        add_doc_rows(rows, v, p, M.path_append(eval, k), depth + 1, q, seen)
      else
        local open = M.open_doc[p]
        if open == nil then open = depth == 0 end
        rows[#rows + 1] = { kind = "tbl", label = tostring(k), path = p,
                            open = open, n = count_keys(v), depth = depth }
        if open then
          add_doc_rows(rows, v, p, M.path_append(eval, k), depth + 1, q, seen)
        end
      end
    elseif q == "" or p:lower():find(q, 1, true) then
      rows[#rows + 1] = { kind = "val", path = p, val = v,
                          eval = M.path_append(eval, k),
                          label = q == "" and tostring(k) or p,
                          depth = q == "" and depth or 0, flat = q ~= "" }
    end
  end
end

local function draw_doc_row(rows, i, x, y, w, h)
  local r = rows[i]
  local st = ui.style
  local ind = math.min(r.depth * 8, 40)
  local rx, rw = x + ind, w - ind
  local ty = y + (h - st.gh) // 2
  if r.kind == "tbl" then
    local clicked, hot = ui.hit("doc/" .. r.path, rx, y, rw, h)
    if hot then ui.rect(rx, y, rw, h, st.widget_hot) end
    ui.text(rx + 2, ty, (r.open and "v " or "> ") .. r.label
            .. "  {" .. r.n .. "}", st.text)
    if clicked then M.open_doc[r.path] = not r.open end
  elseif r.kind == "note" then
    ui.text(rx + 2, ty, r.label, st.text_dim)
  else
    local v = r.val
    local t = type(v)
    local opts = { id = "doc/" .. r.path, rect = { rx, y, rw, h } }
    if r.flat then opts.label_w = rw * 60 // 100 end -- room for path labels
    if t == "number" then
      opts.speed = drag_speed(v)
      if math.type(v) == "float" then opts.fmt = "%.4g" end
      local nv, changed = ui.number(r.label, v, opts)
      if changed then repl.submit(r.eval .. " = " .. M.fmt_value(nv)) end
    elseif t == "boolean" then
      local nv, changed = ui.checkbox(r.label, v, opts)
      if changed then repl.submit(r.eval .. " = " .. tostring(nv)) end
    elseif t == "string" then
      ui.text(rx + 2, ty, r.label .. " " .. ("%q"):format(v), st.text_dim)
    else
      ui.text(rx + 2, ty, r.label .. " (" .. t .. ")", st.text_dim)
    end
  end
end

-- ---- buffer rows ----

local LENSES = { "u8", "i8", "u16", "i16", "u32", "i32", "i64", "f32", "f64" }
local LENS_SIZE = { u8 = 1, i8 = 1, u16 = 2, i16 = 2, u32 = 4, i32 = 4,
                    i64 = 8, f32 = 4, f64 = 8 }
local LENS_MIN = { u8 = 0, u16 = 0, u32 = 0, i8 = -128, i16 = -32768,
                   i32 = -2147483648 }
local LENS_MAX = { u8 = 255, u16 = 65535, u32 = 4294967295, i8 = 127,
                   i16 = 32767, i32 = 2147483647 }

local function cell_speed(lens, v)
  if lens == "f32" or lens == "f64" then
    return math.max(0.01, math.abs(v) / 100)
  end
  return math.max(0.5, math.abs(v) / 100)
end

local function draw_buffer(name, size)
  local st = ui.style
  local lens = M.lens[name] or "f32"

  -- the lens strip: one cell per view kind
  local r = ui.canvas(st.row_h)
  local cw = (r.w - (#LENSES - 1)) // #LENSES
  for li, l in ipairs(LENSES) do
    local cx = r.x + (li - 1) * (cw + 1)
    local clicked, hot = ui.hit("lens/" .. name .. "/" .. l, cx, r.y, cw, r.h)
    local on = l == lens
    ui.rect(cx, r.y, cw, r.h,
            on and st.widget_active or (hot and st.widget_hot or st.widget))
    ui.text(cx + math.max(1, (cw - #l * st.gw) // 2),
            r.y + (r.h - st.gh) // 2, l, on and st.text or st.text_dim)
    if clicked then M.lens[name] = l end
  end

  -- info row; free = husk cleanup (engine pt.* buffers: no button)
  ui.row({ 3, 2 })
  ui.label(size .. " bytes", { color = st.text_dim })
  if name:sub(1, 3) ~= "pt." then
    if ui.button("free", { id = "free/" .. name }) then
      repl.submit(("pal.buf_free(%q)"):format(name))
    end
  else
    ui.label("", {})
  end

  -- every cell through the lens, virtualized
  local view = pal.buf(name, size)
  local stride = LENS_SIZE[lens]
  local isf = lens == "f32" or lens == "f64"
  ui.list(size // stride, st.row_h, function(i, x, y, w, h)
    local off = (i - 1) * stride
    local v = view[lens](view, off)
    local nv, changed = ui.number("[" .. off .. "]", v, {
      id = "cell/" .. name .. "/" .. off, rect = { x, y, w, h },
      speed = cell_speed(lens, v), min = LENS_MIN[lens], max = LENS_MAX[lens],
      label_w = 42, fmt = isf and "%.4g" or nil })
    if changed then
      repl.submit(("pt.state.buf_poke(%q,%q,%d,%s)")
                  :format(name, lens, off, M.fmt_value(nv)))
    end
  end)
end

local function buffer_section(q)
  local st = ui.style
  local list = pal.buf_list()
  table.sort(list, function(a, b) return a.name < b.name end)
  ui.space(2)
  ui.label("buffers", { color = st.text_dim })
  for _, b in ipairs(list) do
    if q == "" or b.name:lower():find(q, 1, true) then
      local open = M.open_buf[b.name] or false
      local r = ui.canvas(st.row_h)
      local clicked, hot = ui.hit("buf/" .. b.name, r.x, r.y, r.w, r.h)
      if hot then ui.rect(r.x, r.y, r.w, r.h, st.widget_hot) end
      ui.text(r.x + 2, r.y + (r.h - st.gh) // 2,
              (open and "v " or "> ") .. b.name, st.text)
      local sz = tostring(b.size)
      ui.text(r.x + r.w - #sz * st.gw - 2, r.y + (r.h - st.gh) // 2,
              sz, st.text_dim)
      if clicked then M.open_buf[b.name] = not open end
      if open then draw_buffer(b.name, b.size) end
    end
  end
end

-- ---- the panel (pt.editor places it while editor mode is on) ----

function M.frame(x, y, w, h)
  local st = ui.style
  ui.begin_panel("inspect", x, y, w, h, { title = "inspector" })
  local s, changed = ui.text_input("find", M.search, { hint = "search" })
  if changed then M.search = s end
  local q = M.search:lower()

  local rows = {}
  add_doc_rows(rows, state.doc, "", "doc", 0, q, {})

  ui.begin_scroll("tree", h - (ui.cursor_y() - y) - st.pad, { bg = st.track })
  ui.label("doc", { color = st.text_dim })
  if #rows == 0 then
    ui.label(q == "" and "(empty doc tree)" or "(no doc matches)",
             { color = st.text_dim })
  end
  ui.list(#rows, st.row_h, function(i, rx, ry, rw, rh)
    draw_doc_row(rows, i, rx, ry, rw, rh)
  end)
  buffer_section(q)
  ui.end_scroll()
  ui.end_panel()
end

return M
