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
      if #p.j.entries == 0 and (#p.disk > 0 or spec.baseline_always) then
        journal.push(p.j, p.disk, journal.SAVED, now_ms())
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

  return A
end

return M
