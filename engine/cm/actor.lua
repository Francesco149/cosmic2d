-- cm.actor — the actor/world slice of A5 (D091). Stable ids, spawn/
-- despawn, deterministic iteration, tags, and frame timers over ONE plain
-- doc subtree — the bookkeeping swarm's swap-remove pools and cellar's
-- parallel prop tables hand-rolled (the loudest PAIN(actor) votes).
--
-- A world is plain data: store it in state.doc and every engine door —
-- canon, snapshots, traces, rewind, hot reload — works by construction.
-- No module state, no buffers, no state participant, no callbacks.
--
--   local actor = cm.require("cm.actor")
--   d.world = d.world or actor.world()
--   local e = actor.spawn(d.world, { tag = "enemy", x = 10, y = 20,
--                                    w = 9, h = 9, speed = 0.5 })
--   e.id                          -- assigned, stable for the world's life
--   actor.tick(d.world)           -- ONCE per step: sweep + timers
--   for a in actor.each(d.world, "enemy") do ... end
--   actor.despawn(d.world, a)     -- or by id
--
-- Semantics, pinned by KATs:
--   * ids are integers assigned ascending from 1, never reused within a
--     world. The list stays sorted by id (spawn appends, sweep preserves
--     order), so get() is a binary search — no id map to rebuild, no
--     hash-order anywhere near iteration.
--   * iteration (each/count/first/hit) is ALWAYS ascending id = spawn
--     order. Actors spawned during a pass are visited later in that same
--     pass; despawned actors are skipped by every query immediately.
--   * despawn only MARKS (a.dead = true). The corpse leaves w.list at the
--     next tick(), so despawning inside your own each() loop is safe.
--     Never call tick() from inside an iteration.
--   * tick(w), once per step (top of step is the canonical spot): removes
--     the dead preserving order, then counts down the world's timers and
--     every live actor's. Skipping tick freezes timers and keeps corpses
--     in w.list (still invisible to queries) — that is also how you get
--     "the world pauses" for free: just don't tick it.
--   * timers are integer frame countdowns in o.t (created on demand,
--     removed when empty): timer(o, name, n) arms; running() is true while
--     n > 0; expired() is true exactly on the frame the count hits 0; the
--     next tick forgets it. timer(o, name, 0) expires this frame. The
--     pairs() walk in tick decrements each key independently — order
--     cannot matter — which is why it is hash-order-safe.
--   * reserved actor fields: id, tag, dead, t. Everything else is yours;
--     give actors x/y/w/h and they are cm.box keyed rects (hit() below is
--     exactly box overlap: strict edges).
--
-- Deliberately NOT here (a composable module, not an ECS — ALPHA.md §2):
-- components/systems, multi-tags, parent/child, spatial indexes, per-actor
-- callbacks (not plain data), z/depth, effects. Later slices earn those
-- from real pain.

local M = select(2, ...) or {}
local box = cm.require("cm.box")

-- world() -> a fresh world table. Keep it in state.doc.
function M.world()
  return { next_id = 1, list = {} }
end

-- spawn(w, a) -> a. Your plain table gains a.id and joins the world at the
-- end of iteration order. tag, if present, must be a string.
function M.spawn(w, a)
  if type(a) ~= "table" then error("actor.spawn: actor must be a table", 2) end
  if a.id ~= nil then error("actor.spawn: table already has an id", 2) end
  if a.tag ~= nil and type(a.tag) ~= "string" then
    error("actor.spawn: tag must be a string", 2)
  end
  a.id = w.next_id
  w.next_id = w.next_id + 1
  w.list[#w.list + 1] = a
  return a
end

local function resolve(w, a)
  if type(a) == "table" then return a end
  return M.get(w, a)
end

-- despawn(w, actor_or_id) -> true if a live actor died. Marks only; the
-- list compacts at the next tick(). Double despawn is a no-op.
function M.despawn(w, a)
  a = resolve(w, a)
  if a == nil or a.dead then return false end
  a.dead = true
  return true
end

-- get(w, id) -> actor or nil (dead and unknown ids are both nil).
-- Binary search: the list is sorted by id at all times.
function M.get(w, id)
  local list = w.list
  local lo, hi = 1, #list
  while lo <= hi do
    local mid = (lo + hi) // 2
    local a = list[mid]
    if a.id == id then
      if a.dead then return nil end
      return a
    elseif a.id < id then lo = mid + 1
    else hi = mid - 1 end
  end
  return nil
end

-- each(w [, tag]) -> iterator over live actors in spawn order.
-- Spawning during the pass appends (visited later in the pass);
-- despawning marks (skipped). Do not tick() mid-iteration.
function M.each(w, tag)
  local list, i = w.list, 0
  return function()
    while true do
      i = i + 1
      local a = list[i]
      if a == nil then return nil end
      if not a.dead and (tag == nil or a.tag == tag) then return a end
    end
  end
end

-- count(w [, tag]) -> live actor count
function M.count(w, tag)
  local n = 0
  for _, a in ipairs(w.list) do
    if not a.dead and (tag == nil or a.tag == tag) then n = n + 1 end
  end
  return n
end

-- first(w [, tag]) -> the earliest-spawned live match, or nil
function M.first(w, tag)
  for _, a in ipairs(w.list) do
    if not a.dead and (tag == nil or a.tag == tag) then return a end
  end
  return nil
end

-- hit(w, tag_or_nil, x, y, ww, hh) -> the first live match (spawn order)
-- whose x/y/w/h rect strictly overlaps, or nil — the shots-vs-enemies
-- query. Strict edges, exactly cm.box. Actors without an x are not rects
-- and can never be hit (a world may mix rect actors with timer-only ones).
function M.hit(w, tag, x, y, ww, hh)
  for _, a in ipairs(w.list) do
    if not a.dead and (tag == nil or a.tag == tag) and a.x ~= nil
       and box.overlap_rect(x, y, ww, hh, a) then
      return a
    end
  end
  return nil
end

-- timer(o, name, frames): arm/rearm an integer frame countdown on any
-- plain table — an actor, the world (w.t is ticked too), or your own.
function M.timer(o, name, frames)
  if math.type(frames) ~= "integer" or frames < 0 then
    error("actor.timer: frames must be an integer >= 0", 2)
  end
  local t = o.t
  if t == nil then t = {}; o.t = t end
  t[name] = frames
end

-- time(o, name) -> remaining frames, or nil when no timer is armed
function M.time(o, name)
  local t = o.t
  return t and t[name]
end

-- running(o, name): armed and still counting (> 0)
function M.running(o, name)
  local t = o.t
  local v = t and t[name]
  return (v or 0) > 0
end

-- expired(o, name): true exactly on the frame the countdown reached 0
function M.expired(o, name)
  local t = o.t
  return t ~= nil and t[name] == 0
end

local function tick_timers(o)
  local t = o.t
  if t == nil then return end
  -- each key is decremented independently: pairs order cannot matter
  for k, v in pairs(t) do
    if v > 0 then t[k] = v - 1 else t[k] = nil end
  end
  if next(t) == nil then o.t = nil end
end

-- tick(w): once per step. Sweeps the dead (order-preserving), then ticks
-- the world's timers and every live actor's.
function M.tick(w)
  local list = w.list
  local j = 0
  for i = 1, #list do
    local a = list[i]
    if not a.dead then
      j = j + 1
      list[j] = a
    end
  end
  for i = #list, j + 1, -1 do list[i] = nil end
  tick_timers(w)
  for i = 1, #list do tick_timers(list[i]) end
end

return M
