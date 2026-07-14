-- cm.ed.kit — the windowkit (R9a, AUDIO.md §7 / EDITOR.md §13): the
-- generalized asset-window citizen. The §6 working-bytes + journal
-- contract used to be hand-copied across sprite/map/tmap/text; this
-- factory is that machine written ONCE, parameterized by the small
-- per-kind deltas (field name, fresh bytes, decode/encode, save side
-- effects). New kinds (the R9 audio windows) are built on it; a UX
-- change to the contract lands here and reflects everywhere.
--
--   local A = kit.asset {
--     gkey  = "sw",     -- ed.g[gkey][path] = the ephemeral plumbing
--     field = "spr",    -- doc.assets[path][field] = the working bytes
--     jcap  = 512,      -- journal cap (nil = journal.CAP)
--     fresh = function(ed, path) return bytes end, -- unbound/new asset
--                       -- (nil: a new asset adopts the disk bytes, the
--                       --  text model — empty file included)
--     adopt = function(p, bytes) ... end, -- bytes changed under the
--                       -- plumbing (decode + cache resets; text sets
--                       -- force_set so the live widget re-reads)
--     encode = function(doc) return bytes end, -- codec kinds: one
--                       -- finished gesture re-encodes p.doc (raw kinds
--                       -- omit encode and use A.push, the text model)
--     baseline_always = false, -- push the disk baseline even when the
--                       -- file is empty (text: undo can reach "")
--     pre_undo = function(ed, path, a, p) ... end, -- close open
--                       -- gestures before walking the journal
--     write = function(ed, path, a, p) return ok, err end, -- the disk
--                       -- write (default pal.write_file of the bytes;
--                       -- sprite overrides to bake siblings)
--     after_save = function(ed, path, a, p) return msg end, -- side
--                       -- effects (epoch bump, recorded reload) +
--                       -- optional log line (default "[ed] saved ..")
--   }
--
-- A provides: plumb/working, open_asset (= the open_path door),
-- open_win, commit + commit_path (codec kinds) / push (raw kinds),
-- dirty/save/undo/redo/revert — the §6 focused-window commands, wired
-- for the shell's kind_call dispatch. Parked discipline (R6c) is the
-- factory's: parked reopens never write journals, parked commits are
-- ephemeral, saves are walled.

local M = select(2, ...) or {}
local journal = cm.require("cm.ed.journal")

local function now_ms()
  return pal.time_ns() // 1000000
end

-- ---- per-window hotkeys (AUDIO.md §7.2 / EDITOR.md §13) ----
--
-- A kind declares a DECLARATIVE table; the shell dispatches the focused
-- window's table after its own reserved keys (Ctrl+S/F/Z/Y, Esc, grave,
-- Alt+V) and before the shell plain keys, so a kind can never shadow
-- the ladder. Declarative means the hint strip renders itself.
--
--   M.hotkeys = {
--     { key = "p", hint = "pen", when = function(win, ed) ... end,
--       fn = function(win, ed) ... end },
--     { key = "ctrl+shift+d", ... },
--   }
--
-- `when` (optional) gates both dispatch and the hint; a match consumes
-- the key event.

-- SDL scancodes by name (the shell's K table, grown)
local SC = {
  a = 4, b = 5, c = 6, d = 7, e = 8, f = 9, g = 10, h = 11, i = 12,
  j = 13, k = 14, l = 15, m = 16, n = 17, o = 18, p = 19, q = 20,
  r = 21, s = 22, t = 23, u = 24, v = 25, w = 26, x = 27, y = 28,
  z = 29,
  ["1"] = 30, ["2"] = 31, ["3"] = 32, ["4"] = 33, ["5"] = 34,
  ["6"] = 35, ["7"] = 36, ["8"] = 37, ["9"] = 38, ["0"] = 39,
  enter = 40, tab = 43, space = 44, minus = 45, equals = 46,
  ["["] = 47, ["]"] = 48, backslash = 49, [";"] = 51, ["'"] = 52,
  [","] = 54, ["."] = 55, ["/"] = 56, del = 76, home = 74,
  ["end"] = 77, pgup = 75, pgdn = 78,
  right = 79, left = 80, down = 81, up = 82,
}
M.SC = SC

-- "ctrl+shift+p" -> { sc, ctrl, shift, alt } (nil on an unknown name)
function M.keyspec(s)
  local spec = { ctrl = false, shift = false, alt = false }
  for part in s:gmatch("[^+]+") do
    if part == "ctrl" or part == "shift" or part == "alt" then
      spec[part] = true
    else
      spec.sc = SC[part]
    end
  end
  return spec.sc and spec or nil
end

local function compiled(kind)
  local hk = rawget(kind, "_hk")
  if hk then return hk end
  hk = {}
  for _, entry in ipairs(kind.hotkeys or {}) do
    local spec = M.keyspec(entry.key)
    if spec then
      spec.entry = entry
      hk[#hk + 1] = spec
    else
      pal.log("[ed] bad hotkey spec: " .. tostring(entry.key))
    end
  end
  kind._hk = hk
  return hk
end

-- one key event against the focused window's table; true = consumed.
-- mods = the shell's tracked { ctrl, shift, alt } (M.g).
function M.hotkey(kind, win, ed, e, mods)
  if not (kind and kind.hotkeys and e.down and not e.rep) then
    return false
  end
  for _, spec in ipairs(compiled(kind)) do
    if spec.sc == e.scancode
       and spec.ctrl == (mods.ctrl or false)
       and spec.shift == (mods.shift or false)
       and spec.alt == (mods.alt or false) then
      local entry = spec.entry
      if not entry.when or entry.when(win, ed) then
        entry.fn(win, ed)
        return true
      end
    end
  end
  return false
end

-- the hint strip data: "key  hint" for every when-passing entry
function M.hints(kind, win, ed)
  local out = {}
  for _, entry in ipairs(kind and kind.hotkeys or {}) do
    if entry.hint and (not entry.when or entry.when(win, ed)) then
      out[#out + 1] = { key = entry.key, hint = entry.hint }
    end
  end
  return out
end

-- ---- editor-bank audio allocation (R9c) ----
--
-- Audio windows (synth audition, the sound player) share the editor
-- bank's 64 patch slots + 32 voices. One round-robin allocator so kinds
-- never hand-pick indices and collide.

function M.snd_alloc(ed, nvoices)
  local g = ed.g
  g.snd_slot = ((g.snd_slot or -1) + 1) % 64
  local vbase = g.snd_voice or 0
  g.snd_voice = (vbase + (nvoices or 1)) % 32
  return g.snd_slot, vbase
end

-- ---- the view lock (EDITOR.md §12.7, generalized §13) ----
--
-- kit.viewlock(K, opts) installs the focused-view trio — own_view /
-- wheel / takes_middle — on a kind: the window owns wheel + middle-drag
-- only WHILE FOCUSED (focus is the ONE gate); unfocused = inert view;
-- under the lock an off-view wheel anchors at the view center (zoom-at-
-- cursor math would fling the pan). The math lives in cm.ed.winview.
--
--   opts = { gkey = "sw",            -- the plumbing key (kit.asset's)
--            rect = "canvas_rect",   -- p.<rect> = this frame's view px
--            lock = fn(win) -> bool, -- when the view can lock (default:
--                                    --  bound; sprite/tmap add edit)
--            zmin = 0.05, zmax = 32 }

function M.viewlock(K, opts)
  local gkey = opts.gkey
  local rect = opts.rect or "canvas_rect"
  local lock = opts.lock
               or function(win) return (win.path or "") ~= "" end
  local zmin, zmax = opts.zmin or 0.05, opts.zmax or 32

  function K.own_view(win)
    return lock(win)
  end

  function K.wheel(win, ed, dy)
    if not lock(win) or ed.doc.focus ~= win.id then return false end
    local p = ed.g[gkey] and ed.g[gkey][win.path]
    local r = p and p[rect]
    if not (r and p.doc) then return false end
    local i = cm.require("cm.ui").inp
    local ax, ay = i.wx, i.wy
    if ax < r.cx or ax >= r.cx + r.w or ay < r.cy or ay >= r.cy + r.h then
      ax, ay = r.cx + r.w * 0.5, r.cy + r.h * 0.5
    end
    cm.require("cm.ed.winview").wheel_zoom(win, r, ax, ay, dy, zmin, zmax)
    ed.touch()
    return true
  end

  function K.takes_middle(win, ed)
    return lock(win) and ed ~= nil and ed.doc.focus == win.id
  end
end

function M.asset(spec)
  local A = {}
  local gkey, field = spec.gkey, spec.field

  function A.plumb(ed, path)
    local g = ed.g
    g[gkey] = g[gkey] or {}
    local p = g[gkey][path]
    if not p then
      p = {}
      g[gkey][path] = p
    end
    return p
  end

  function A.working(ed, path)
    ed.doc.assets = ed.doc.assets or {}
    return ed.doc.assets[path]
  end

  -- open (or re-adopt after a restart) the working state + journal
  function A.open_asset(ed, path)
    local a = A.working(ed, path)
    local p = A.plumb(ed, path)
    if p.j then return a, p end
    local disk = pal.read_file(ed.root .. "/" .. path)
    p.disk = disk or ""
    if not a then
      local bytes = p.disk
      if #bytes == 0 and spec.fresh then bytes = spec.fresh(ed, path) end
      a = { [field] = bytes, jpos = 0 }
      ed.doc.assets[path] = a
    end
    p.j = journal.open(ed.root, path, a.jpos > 0 and a.jpos or nil,
                       spec.jcap)
    if not ed.parked then -- parked reopens must never write journals (R6c)
      if #p.j.entries == 0 then
        if #p.disk > 0 or spec.baseline_always then
          journal.push(p.j, p.disk, journal.SAVED, now_ms())
        elseif #a[field] > 0 then
          -- a FRESH asset (spec.fresh made the bytes): journal them as
          -- the undo floor — the first edit must be undoable back to
          -- the init state (a gap the synth tape caught; fixes new
          -- sprite/map/tmap assets too)
          journal.push(p.j, a[field], 0, now_ms())
        end
      end
      local tip = journal.at(p.j)
      if tip and a[field] ~= tip.bytes and p.j.pos == #p.j.entries then
        -- session-restored unsaved work the journal hasn't seen: journal
        -- it now so Ctrl+Z works
        journal.push(p.j, a[field], 0, now_ms())
      end
    end
    a.jpos = p.j.pos
    if spec.encode and spec.adopt then spec.adopt(p, a[field]) end
    ed.touch()
    return a, p
  end

  function A.open_win(win, ed) -- spawn-time adoption (proof scripting too)
    if win.path ~= "" then return A.open_asset(ed, win.path) end
  end

  -- one finished gesture (codec kinds): re-encode the doc into the
  -- working bytes + journal. Parked edits are ephemeral (REWIND.md §4):
  -- the parked doc updates, the journal file never moves.
  function A.commit(ed, path, flags)
    local a, p = A.open_asset(ed, path)
    if not p.doc then return end
    a[field] = spec.encode(p.doc)
    if spec.post_encode then spec.post_encode(p) end
    if ed.parked then
      ed.touch()
      return
    end
    if journal.push(p.j, a[field], flags or 0, now_ms()) then
      a.jpos = p.j.pos
    end
    ed.touch()
  end

  -- the raw-kind gesture close (the text model): journal the working
  -- bytes as they are — no doc, no encode. Debounce owners clear their
  -- own p.due here.
  function A.push(ed, path, flags)
    local a = A.working(ed, path)
    local p = A.plumb(ed, path)
    if not (a and p.j) then return end
    p.due = nil
    if ed.parked then return end -- parked edits are ephemeral (REWIND.md §4)
    if journal.push(p.j, a[field], flags or 0, now_ms()) then
      a.jpos = p.j.pos
      ed.touch()
    end
  end

  local close = spec.encode and A.commit or A.push

  -- ---- the focused-window commands (§6 contract) ----

  function A.dirty(win, ed)
    if win.path == "" then return false end
    local a = A.working(ed, win.path)
    local p = ed.g[gkey] and ed.g[gkey][win.path]
    return a and p and p.disk ~= nil and a[field] ~= p.disk or false
  end

  function A.save(win, ed)
    if win.path == "" then return end
    if ed.parked then
      pal.log("[ed] parked in the past — writes are walled (bring-back is the door)")
      return
    end
    local a, p = A.open_asset(ed, win.path)
    if spec.encode then
      if not p.doc then return end
      a[field] = spec.encode(p.doc)
    end
    local dir = win.path:match("^(.*)/[^/]+$")
    if dir then pal.mkdir(ed.root .. "/" .. dir) end
    local ok, err
    if spec.write then
      ok, err = spec.write(ed, win.path, a, p)
    else
      ok = pal.write_file(ed.root .. "/" .. win.path, a[field])
    end
    if ok then
      p.disk = a[field]
      close(ed, win.path, journal.SAVED)
      -- a save may have CREATED the file (the pathfield door) or baked
      -- new siblings: the asset browser's cached list must see it
      -- (human, morning round — a fresh ins/tape.ins never appeared)
      cm.require("cm.ed.win.assets").invalidate(ed)
      local msg = spec.after_save and spec.after_save(ed, win.path, a, p)
      pal.log(msg or ("[ed] saved " .. win.path))
    else
      pal.log("[ed] SAVE FAILED " .. win.path ..
              (err and (": " .. tostring(err)) or ""))
    end
  end

  local function walk(win, ed, dir)
    if win.path == "" then return end
    local a, p = A.open_asset(ed, win.path)
    if dir < 0 and spec.pre_undo then spec.pre_undo(ed, win.path, a, p) end
    local e = dir < 0 and journal.undo(p.j) or journal.redo(p.j)
    if e then
      a[field], a.jpos = e.bytes, p.j.pos
      if spec.adopt then spec.adopt(p, e.bytes) end
      ed.touch()
    end
  end

  function A.undo(win, ed) return walk(win, ed, -1) end
  function A.redo(win, ed) return walk(win, ed, 1) end

  -- revert-to-saved: a NORMAL edit (journaled), so revert itself is
  -- undoable
  function A.revert(win, ed)
    if win.path == "" then return end
    local a, p = A.open_asset(ed, win.path)
    a[field] = p.disk or ""
    if spec.adopt then spec.adopt(p, a[field]) end
    close(ed, win.path)
  end

  -- the unbound-window "new file" prompt (the map window's field,
  -- generalized — human, morning round): label + path field; Enter
  -- submits (single-line by contract — the multiline default ate the
  -- Enter as a newline), the extension is FORCED, and an existing
  -- file (disk or working state) prompts open / overwrite / cancel
  -- instead of silently adopting. Overwrite clears the old file +
  -- working state + plumbing so open_asset takes the fresh path (the
  -- undo-forever journal keeps the old bytes reachable regardless).
  --
  --   opts = { ext = "song", default = "sound/",
  --            label = "new song path:" (optional) }
  function A.pathfield(win, ed, ctx, opts)
    local z = ctx.z
    local px = math.max(4, 10 * z)
    local p0 = A.plumb(ed, "@new" .. win.id)
    local dim, hot2 = 0x8a84b0ff, 0xE8E4FFff

    local function bind(path, overwrite)
      if overwrite then
        if ed.parked then
          pal.log("[ed] parked in the past — writes are walled")
          return
        end
        pal.x_remove(ed.root .. "/" .. path)
        if ed.doc.assets then ed.doc.assets[path] = nil end
        if ed.g[gkey] then ed.g[gkey][path] = nil end
        cm.require("cm.ed.win.assets").invalidate(ed)
      end
      win.path = path
      p0.newpath, p0.confirm = nil, nil
      A.open_asset(ed, path)
      ed.touch()
    end

    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, dim,
                  opts.label or ("new ." .. opts.ext .. " path:"), 0)
    local fy = ctx.cy + 8 * z + px * 1.8
    local fw = math.min(240 * z, ctx.cw - 16 * z)
    pal.x_ig_rect(ctx.cx + 8 * z, fy, fw, px * 1.7, 0x4a437088, 1, 3 * z)
    if ctx.occluded then return end

    if p0.confirm then -- exists: open / overwrite / cancel
      pal.x_ig_text(ctx.cx + 8 * z, fy + 2 * z, px, hot2, p0.confirm, 0)
      local cy2 = fy + px * 2.2
      pal.x_ig_text(ctx.cx + 8 * z, cy2, px, 0xf07a7aff,
                    "already exists:", 0)
      local i = cm.require("cm.ui").inp
      local bx = ctx.cx + 8 * z + pal.x_ig_text_size("already exists:", px, 0)
                 + 10 * z
      for _, item in ipairs({ { "open", false }, { "overwrite", true },
                              { "cancel" } }) do
        local w = pal.x_ig_text_size(item[1], px, 0) + 12 * z
        local hov = ctx.hot and i.wx >= bx and i.wx < bx + w
                    and i.wy >= cy2 - 2 * z and i.wy < cy2 + px * 1.4
        pal.x_ig_rect_fill(bx, cy2 - 2 * z, w, px * 1.5,
                           hov and 0x4a4370ff or 0x262238ff, 3 * z)
        pal.x_ig_text(bx + 6 * z, cy2, px, hov and hot2 or dim, item[1], 0)
        if hov and i.clicked[1] then
          if item[1] == "cancel" then
            p0.confirm = nil
            ed.touch()
          else
            bind(p0.confirm, item[2])
          end
        end
        bx = bx + w + 6 * z
      end
      return
    end

    -- auto-name (human): prefill an unbound field with a unique 3-word
    -- name so Enter creates immediately — no naming paralysis (audit G6).
    -- Only when default is a bare dir ("ins/"); stays fully editable.
    if p0.newpath == nil and opts.default and opts.default:find("/$") then
      local words = cm.require("cm.words")
      local dir = opts.default
      p0.newpath = dir .. words.unique(function(nm)
        local rel = dir .. nm .. "." .. opts.ext
        return pal.read_file(ed.root .. "/" .. rel) ~= nil
               or (ed.doc.assets and ed.doc.assets[rel] ~= nil)
      end) .. "." .. opts.ext
    end

    local text, _, _, st = pal.x_ig_edit {
      id = "pathfield" .. win.id, x = ctx.cx + 10 * z, y = fy + 1,
      w = fw - 4 * z, h = px * 1.7 - 2,
      text = p0.newpath or opts.default or "", px = px, font = 1,
      enter = true, multiline = false,
    }
    p0.newpath = text
    if st and st.submit then
      local path = text:gsub("^%s+", ""):gsub("%s+$", "")
      if path == "" or path == (opts.default or "") or path:find("/$") then
        return
      end
      if not path:lower():find("%." .. opts.ext .. "$") then
        path = path .. "." .. opts.ext
      end
      local exists = pal.read_file(ed.root .. "/" .. path) ~= nil
                     or (ed.doc.assets and ed.doc.assets[path] ~= nil)
      if exists then
        p0.confirm = path
        ed.touch()
      else
        bind(path, false)
      end
    end
  end

  return A
end

return M
