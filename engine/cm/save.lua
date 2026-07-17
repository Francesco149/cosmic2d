-- cm.save — namespaced atomic player storage (A4/D086).
--
-- Save data lives OUTSIDE the install and the project folder, under the
-- fixed per-user root:  <pal.user_path()>saves/<save_id>/<profile>/slot<n>.sav
-- so exports, archives, duplicates, and moves can never carry another
-- machine's saves by construction. The namespace key is `save_id`, declared
-- in project.lua (the project NAME is mutable; the id is the stable promise —
-- grammar in cm.project.save_id_error, editable in project settings).
-- A project that declares no save_id has no player storage: every door here
-- returns nil + a named reason instead of inventing a mutable key.
--
-- Session class: input.dat/video.dat rules apply. The store binds only in
-- interactive windowed sessions (cm.main); headless / --frames / --verify
-- runs see a disabled store, so goldens, captures, and trace verifies never
-- depend on one machine's saves. Files are machine state, never sim state.
--
-- What the API owes determinism (the D082..D085 live-policy line, stated for
-- reads): a save WRITE is a pure output — sim code may call it freely; it
-- feeds nothing back. A save READ that feeds the sim must land in state.doc,
-- and there are exactly two sanctioned shapes:
--   * boot loads: read in game.init() under the reload-idempotence contract
--     (only fill doc fields that are absent). The trace SNAP captures the
--     result, so replay and verify never re-read this machine's saves.
--   * mid-session loads: M.load(slot) — reads and migrates NOW, then queues
--     the exact post-migration bytes through the recorded console-eval
--     channel (D022). The payload replays from the record; on verify the
--     re-simmed call finds a disabled store and queues nothing, so the
--     recorded EVAL stays the single source. The registered on_load handler
--     applies the data to doc at the start of the next sim frame.
-- Reading a slot directly inside step() and branching the sim on it is a
-- determinism bug exactly like reading any other local file.
--
-- Envelope (cm.state canon, like every machine-local store):
--   { schema = <declared version at write time>, data = <plain tree> }
-- Reads migrate old schemas stepwise through registered migrations and
-- refuse newer ones honestly; malformed files are a named error, never a
-- crash, and stay on disk untouched until the next explicit write.

local M = select(2, ...) or {}

local function state_mod()
  return cm.require("cm.state")
end

local function project_mod()
  return cm.require("cm.project")
end

M.MAX_SLOT = 1000

-- session identity (bind() below). _root is the selftest seam: when set,
-- paths derive from it instead of pal.user_path().
M._id = M._id or nil
M._why = M._why or "player storage is not bound this session"
M._profile = M._profile or "default"

-- game-code declarations (re-run by the main chunk on every hot reload)
M._schema = M._schema or 1
M._migrations = M._migrations or {}
M._on_load = M._on_load or nil

-- bind the store for this session (cm.main at boot). meta = the validated
-- project table for interactive windowed sessions, nil for every other
-- class. Resets profile and declarations: a project switch or a headless
-- run must never leak the previous binding.
function M.bind(meta)
  M._id, M._profile = nil, "default"
  M._schema, M._migrations, M._on_load = 1, {}, nil
  if type(meta) ~= "table" then
    M._why = "player storage is off this session"
    return
  end
  local id = meta.save_id
  if id == nil then
    M._why = "project declares no save_id"
    return
  end
  local err = project_mod().save_id_error(id)
  if err then
    M._why = err
    return
  end
  M._id = id
  M._why = nil
end

function M.enabled()
  if M._id then return true end
  return false, M._why
end

-- the saves root for the bound id, or nil + reason
local function save_root()
  if not M._id then return nil, M._why end
  if M._root then return M._root .. "/" .. M._id end
  if not pal.user_path then return nil, "PAL lacks per-user path support" end
  local root, err = pal.user_path()
  if not root then return nil, err end
  return root .. "saves/" .. M._id
end

local function slot_error(slot)
  if math.type(slot) ~= "integer" or slot < 1 or slot > M.MAX_SLOT then
    return "slot must be an integer from 1 to " .. M.MAX_SLOT
  end
end

local function slot_path(slot)
  local root, err = save_root()
  if not root then return nil, err end
  err = slot_error(slot)
  if err then return nil, err end
  return root .. "/" .. M._profile .. "/slot" .. slot .. ".sav"
end

-- ---- declarations (game code, main chunk) ----

-- declare the CURRENT save schema version (default 1). Bump it when the
-- shape of the saved data changes, and register a migration per step.
function M.schema(n)
  if math.type(n) ~= "integer" or n < 1 then
    error("save schema must be a positive integer", 2)
  end
  M._schema = n
  return n
end

-- register the step that lifts data written at schema `from` to `from + 1`.
-- fn(data) -> data. Reads chain steps until they reach the declared schema.
function M.migrate(from, fn)
  if math.type(from) ~= "integer" or from < 1 then
    error("migrate: from must be a positive integer", 2)
  end
  if type(fn) ~= "function" then error("migrate: fn required", 2) end
  M._migrations[from] = fn
end

-- register the mid-session load handler: fn(data) applies a loaded save to
-- state.doc. Runs at the start of a sim frame through the recorded eval
-- channel, so its effects replay and verify exactly.
function M.on_load(fn)
  if fn ~= nil and type(fn) ~= "function" then
    error("on_load: fn must be a function", 2)
  end
  M._on_load = fn
end

-- ---- profiles ----

-- profile(name) selects the current profile (same grammar as save_id);
-- profile() reads it. Everything below operates on the current profile.
function M.profile(name)
  if name == nil then return M._profile end
  local err = project_mod().save_id_error(name)
  if err then return nil, (err:gsub("^save_id", "profile", 1)) end
  M._profile = name
  return name
end

-- existing profiles = distinct directories under the saves root that hold
-- at least one slot file. Sorted; empty/missing root is an empty list.
function M.profiles()
  local root, err = save_root()
  if not root then return nil, err end
  local seen, out = {}, {}
  for _, rel in ipairs(pal.list_dir(root) or {}) do
    local prof = rel:match("^([^/]+)/slot%d+%.sav$")
    if prof and not seen[prof] then
      seen[prof] = true
      out[#out + 1] = prof
    end
  end
  table.sort(out)
  return out
end

-- existing slot numbers in the current profile, ascending
function M.slots()
  local root, err = save_root()
  if not root then return nil, err end
  local out = {}
  for _, rel in ipairs(pal.list_dir(root .. "/" .. M._profile) or {}) do
    local n = rel:match("^slot(%d+)%.sav$")
    if n then out[#out + 1] = math.tointeger(n) end
  end
  table.sort(out)
  return out
end

-- ---- the doors ----

-- write(slot, data) -> true | nil, err. Atomic replacement: a failure at
-- any boundary preserves the previous save byte-for-byte. data must be a
-- plain tree (the doc rules); it is stamped with the declared schema.
-- `fail` is the injectable seam of pal.write_file_atomic.
function M.write(slot, data, fail)
  local path, err = slot_path(slot)
  if not path then return nil, err end
  if data == nil then return nil, "save data required" end
  local ok, bytes = pcall(state_mod().canon, { schema = M._schema, data = data })
  if not ok then return nil, "save data must be plain: " .. tostring(bytes) end
  local dir = path:match("^(.*)/[^/]+$")
  if not pal.mkdir(dir) then
    err = "create save folder failed: " .. dir
    pal.log("[save] " .. err)
    return nil, err
  end
  ok, err = pal.write_file_atomic(path, bytes, fail)
  if not ok then
    pal.log(("[save] write FAILED %s: %s"):format(path, tostring(err)))
    return nil, tostring(err)
  end
  return true
end

-- decode + migrate one envelope; shared by read() and load()
local function decode(bytes, what)
  local ok, t = pcall(state_mod().parse, bytes)
  if not ok or type(t) ~= "table" or math.type(t.schema) ~= "integer"
     or t.schema < 1 or t.data == nil then
    return nil, what .. " is unreadable"
  end
  local schema, data = t.schema, t.data
  if schema > M._schema then
    return nil, ("%s was written by a newer version (schema %d, this game reads %d)")
      :format(what, schema, M._schema)
  end
  while schema < M._schema do
    local fn = M._migrations[schema]
    if not fn then
      return nil, ("%s: no migration from save schema %d"):format(what, schema)
    end
    local mok, next_data = pcall(fn, data)
    if not mok then
      return nil, ("%s: migration from schema %d failed: %s")
        :format(what, schema, tostring(next_data))
    end
    if next_data == nil then
      return nil, ("%s: migration from schema %d returned no data"):format(what, schema)
    end
    data, schema = next_data, schema + 1
  end
  return data
end

-- read(slot) -> data | nil, err. Post-migration plain data; a missing slot
-- is the named "no save" error (a first run, not a fault). Inspection only:
-- feeding the sim goes through the init pattern or load() — see the header.
function M.read(slot)
  local path, err = slot_path(slot)
  if not path then return nil, err end
  local bytes = pal.read_file(path)
  if not bytes then return nil, "no save in slot " .. slot end
  return decode(bytes, "slot " .. slot)
end

-- erase(slot) -> true | nil, err. Explicit reset of one slot; erasing an
-- absent slot succeeds (the outcome is the same empty slot).
function M.erase(slot)
  local path, err = slot_path(slot)
  if not path then return nil, err end
  if not pal.read_file(path) then return true end
  if not pal.x_remove(path) then
    err = "erase failed: " .. path
    pal.log("[save] " .. err)
    return nil, err
  end
  return true
end

-- wipe() -> true | nil, err. Explicit reset of the CURRENT profile: every
-- slot file goes, then the emptied folder. Missing profile is a no-op.
function M.wipe()
  local root, err = save_root()
  if not root then return nil, err end
  local dir = root .. "/" .. M._profile
  for _, rel in ipairs(pal.list_dir(dir) or {}) do
    if rel:match("^slot%d+%.sav$") and not pal.x_remove(dir .. "/" .. rel) then
      err = "wipe failed: " .. dir .. "/" .. rel
      pal.log("[save] " .. err)
      return nil, err
    end
  end
  pal.x_remove(dir) -- best-effort: non-slot stragglers keep the folder
  return true
end

-- ---- the mid-session load door (recorded) ----

-- _apply(bytes): the eval-channel target. Parses the exact recorded
-- post-migration canon bytes and hands the data to the registered handler.
-- Public only for the recorder; game code calls load().
function M._apply(bytes)
  local ok, data = pcall(state_mod().parse, bytes)
  if not ok then
    pal.log("[save] recorded load payload is unreadable: " .. tostring(data))
    return
  end
  if not M._on_load then
    pal.log("[save] loaded data dropped: no on_load handler is registered")
    return
  end
  M._on_load(data)
end

-- load(slot) -> true | nil, err. Reads and migrates now (live-side), then
-- queues the payload through the recorded eval channel; the on_load handler
-- applies it to doc at the start of the next sim frame. Safe to call from
-- step(): nothing touches sim state this frame, and on verify the disabled
-- store queues nothing while the recorded EVAL replays the exact bytes.
function M.load(slot)
  if not M._on_load then return nil, "no on_load handler is registered" end
  local data, err = M.read(slot)
  if not data then return nil, err end
  local ok, bytes = pcall(state_mod().canon, data)
  if not ok then return nil, "save data must be plain: " .. tostring(bytes) end
  cm.require("cm.repl").enqueue(("cm.require(\"cm.save\")._apply(%q)"):format(bytes))
  return true
end

return M
