-- boot.lua — PAL bootstrap: defines the cm module system, then hands off to
-- cm.main (engine/cm/main.lua), which owns flags, project load and the loop.
--
-- Deliberately thin: the C loop loads this file from disk on every VM
-- (re)boot, and it is the one piece of engine code snapshots cannot restore
-- from their code bundle (D012) — the less it does, the less can diverge.
--
-- Module convention: a module file returns a table. On (re)load the chunk is
-- called with (name, prev_table_or_nil); modules that must keep state across
-- their *own* reload start with `local M = select(2, ...) or {}`. For all
-- modules, reload preserves table identity by repopulating the original
-- table in place — but module-local upvalues reset on reload, so sim state
-- belongs in named buffers / the doc tree, never in module locals.
--
-- cm.* names map to engine/cm/ (cm.math -> engine/cm/math.lua) and attach to
-- the cm global on load; anything else maps into the project dir
-- (player.weapons -> <project>/player/weapons.lua).

local registry = {} -- name -> {name,path,source,hash,mtime,table,special,loading,from_bundle}
local project_root
local bundle_mode = false -- restored-snapshot code active: disk reload paused

-- two render-only reload signals on the root table (survive every reload,
-- reset only on VM reboot): code_epoch bumps on each hot reload, asset_epoch
-- on each studio asset save (cm.sprite.save). Consumers read them to drop
-- render caches / re-load baked art — never sim state, so they can't perturb
-- a trace (the bumps fire only live, the reads only in draw).
cm = { code_epoch = 0, asset_epoch = 0 }

-- the hot-reload poll checks file mtimes 4x/s; pal.watch_mtime reads a cache
-- the PAL's watcher thread refreshes off the main thread, so the poll never
-- stats on the main thread (the rhythmic frame spikes over a slow FS, e.g.
-- WSL 9p). Falls back to a direct stat on an older PAL (contract rule 7).
local watch_mtime = pal.watch_mtime or pal.mtime

local function module_path(name)
  -- dotted segments of [%w_%-] only: no slashes, no empty segments, so the
  -- result can never escape its root
  if type(name) ~= "string" or name == "" or name:find("[^%w_%.%-]")
     or name:find("%.%.", 1, true) or name:sub(1, 1) == "."
     or name:sub(-1) == "." then
    error("bad module name: " .. tostring(name), 0)
  end
  local rel = name:gsub("%.", "/") .. ".lua"
  if name:sub(1, 3) == "cm." then return "engine/" .. rel end
  if not project_root then
    error("project module '" .. name .. "' required before project root set", 0)
  end
  return project_root .. "/" .. rel
end

local function run_chunk(name, path, source, prev)
  local chunk, err = load(source, "@" .. path)
  if not chunk then error(err, 0) end
  local result = chunk(name, prev)
  if type(result) ~= "table" then
    error(path .. " did not return a table", 0)
  end
  return result
end

local function attach(name, tbl)
  local key = name:match("^cm%.([%w_%-]+)$")
  if not key then return end
  if cm[key] ~= nil and cm[key] ~= tbl then
    error("module cm." .. key .. " collides with cm infrastructure", 0)
  end
  cm[key] = tbl
end

function cm.require(name)
  local m = registry[name]
  if m and m.table then return m.table end
  if m and m.loading then error("circular require: " .. name, 0) end
  local path = module_path(name)
  local source
  if m and m.from_bundle then
    source = m.source
  else
    local src, err = pal.read_file(path)
    if not src then
      error("can't read module " .. name .. " (" .. path .. "): "
            .. tostring(err), 0)
    end
    source = src
    pal.watch_add(path) -- crash parachute covers every loaded file
  end
  m = m or {}
  m.name, m.path, m.source, m.hash = name, path, source, pal.hash(source)
  m.mtime = m.from_bundle and 0 or pal.mtime(path)
  m.loading = true
  registry[name] = m
  local ok, result = pcall(run_chunk, name, path, source, nil)
  m.loading = false
  if not ok then
    registry[name] = nil
    error(result, 0)
  end
  m.table = result
  attach(name, result)
  return result
end

-- source-only entries (boot.lua, project.lua): bundled for reproducibility,
-- never (re)executed by the module system
function cm.register_special(name, path, source)
  registry[name] = { name = name, path = path, source = source,
                     hash = pal.hash(source), special = true }
  pal.watch_add(path)
end

-- sorted snapshot of every loaded source — the D012 code bundle
function cm.modules()
  local names = {}
  for n, m in pairs(registry) do
    if m.source and (m.special or m.table) then names[#names + 1] = n end
  end
  table.sort(names)
  local out = {}
  for i, n in ipairs(names) do
    local m = registry[n]
    out[i] = { name = n, path = m.path, source = m.source, hash = m.hash }
  end
  return out
end

-- dev hot reload: re-execute changed modules in place. Returns the sorted
-- list of reloaded module names (empty while running bundle code).
function cm.reload(force)
  if bundle_mode then return {} end
  local changed = {}
  local names = {}
  for n, m in pairs(registry) do
    if not m.special and m.table then names[#names + 1] = n end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local m = registry[name]
    local mt = watch_mtime(m.path)
    if force or mt ~= m.mtime then
      m.mtime = mt
      local src = pal.read_file(m.path)
      if src and pal.hash(src) ~= m.hash then
        local ok, err = pcall(function()
          local result = run_chunk(name, m.path, src, m.table)
          if result ~= m.table then
            for k in pairs(m.table) do m.table[k] = nil end
            for k, v in pairs(result) do m.table[k] = v end
          end
        end)
        if ok then
          m.source, m.hash = src, pal.hash(src)
          changed[#changed + 1] = name
          pal.log("[reload] " .. m.path)
        else
          pal.log("[reload] FAILED, keeping old code: " .. tostring(err))
        end
      end
    end
  end
  if #changed > 0 then cm.code_epoch = cm.code_epoch + 1 end
  return changed
end

-- snapshot restore (D012): run code from the bundle, not from disk. Disk
-- reload stays paused until cm.adopt_disk() deliberately switches back.
function cm.restore_bundle(files)
  bundle_mode = true
  for _, f in ipairs(files) do
    if f.name:sub(1, 1) ~= "@" then
      local m = registry[f.name]
      if m and m.table then
        if m.hash ~= pal.hash(f.source) then
          local result = run_chunk(f.name, f.path, f.source, m.table)
          if result ~= m.table then
            for k in pairs(m.table) do m.table[k] = nil end
            for k, v in pairs(result) do m.table[k] = v end
          end
          m.source, m.hash = f.source, pal.hash(f.source)
        end
      else
        registry[f.name] = { name = f.name, path = f.path, source = f.source,
                             hash = pal.hash(f.source), mtime = 0,
                             from_bundle = true }
      end
    end
  end
  cm.code_epoch = cm.code_epoch + 1
end

function cm.adopt_disk()
  if not bundle_mode then return {} end
  bundle_mode = false
  for _, m in pairs(registry) do m.from_bundle = nil end
  return cm.reload(true)
end

function cm.set_project_root(dir)
  project_root = dir
end

do
  local self_src = pal.read_file("engine/boot.lua")
  if self_src then cm.register_special("@boot", "engine/boot.lua", self_src) end
end

local main = cm.require("cm.main")

function cm_tick()
  return main.tick()
end

main.boot()
