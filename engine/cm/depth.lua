-- cm.depth — the layer/depth slice of A5 (D095). Stable draw-order
-- sorting over plain data: the y-sort comparator + rebuilt draw list
-- every top-down game hand-rolls (cellar's PAIN(depth) block was the
-- vote — base y, then x, then kind, ties broken by hand because hash
-- order must never draw). §2's "layers/depth sorting … without forcing
-- a scene graph" line; parallax layers are already cm.gfx.layer + the
-- map's LAYR factors (D092/D093) — this is the within-layer ordering.
--
-- Pure functions over plain tables — no module state, no buffers, no
-- scene graph, no callbacks. Draw-order only: nothing here touches doc,
-- so determinism is the comparator's totality — every ordering below is
-- a TOTAL order (explicit sort key, then push/array order), which makes
-- the sorted result unique regardless of sort algorithm. Hash order can
-- never draw.
--
--   local depth = cm.require("cm.depth")
--   -- in draw: push (sort key, your item), sort, walk back-to-front
--   local dl = depth.list()
--   for _, p in ipairs(room.pillars) do depth.push(dl, p.y + BASE, p) end
--   depth.push(dl, d.y + PH, "player")
--   depth.sort(dl)
--   for _, item in depth.each(dl) do
--     if item == "player" then draw_player(d) else draw_pillar(item) end
--   end
--
-- Semantics, pinned by KATs:
--   * push(l, key, item): key is the explicit sort position (a finite
--     number — typically the feet/base y; NaN refused because it breaks
--     ordering totality). item is YOUR value, passed through untouched —
--     a table, a string tag, anything but nil.
--   * sort(l): ascending by key; EQUAL keys keep their current (push)
--     order — stability is the tiebreak, so "pushed later draws later
--     (on top)" is the rule for ties. Sorting is idempotent.
--   * each(l) -> i, item, key in current order. clear(l) empties the
--     list for reuse (the box.hits `out` pattern); list() is just {}.
--   * ysort(items [, field]): the one-liner for an array you already
--     have — stable in-place ascending sort of plain tables by a numeric
--     field (default "y"). Equal fields keep array order. Refuses a
--     missing/non-number field by index, honestly.
--
-- Deliberately NOT here (absorb the demonstrated pain, no more):
-- scene graphs, z properties on drawables, layer registries, draw
-- callbacks, culling. Later slices earn those from real demo pain.

local M = select(2, ...) or {}

-- list() -> a fresh draw list (a plain array of {key, item} entries)
function M.list()
  return {}
end

-- clear(l): empty a list for reuse
function M.clear(l)
  for i = #l, 1, -1 do l[i] = nil end
end

-- push(l, key, item): append an entry. key = explicit sort position
-- (finite number); item = your value, passed through (not nil).
function M.push(l, key, item)
  if type(key) ~= "number" or key ~= key then
    error("depth.push: key must be a number (and not NaN)", 2)
  end
  if item == nil then
    error("depth.push: item must not be nil", 2)
  end
  l[#l + 1] = { key = key, item = item }
end

-- sort(l): ascending by key, ties keep current order (stable). The seq
-- decoration makes the comparator total, so the result is unique under
-- any sort algorithm.
function M.sort(l)
  for i = 1, #l do l[i].seq = i end
  table.sort(l, function(a, b)
    if a.key ~= b.key then return a.key < b.key end
    return a.seq < b.seq
  end)
end

local function iter(l, i)
  i = i + 1
  local e = l[i]
  if e ~= nil then return i, e.item, e.key end
end

-- each(l) -> iterator over i, item, key in current order
function M.each(l)
  return iter, l, 0
end

-- ysort(items [, field]): stable in-place ascending sort of an array of
-- plain tables by a numeric field (default "y"); equal fields keep
-- array order.
function M.ysort(items, field)
  field = field or "y"
  local seq = {}
  for i = 1, #items do
    local it = items[i]
    local v = it[field]
    if type(v) ~= "number" or v ~= v then
      error("depth.ysort: item " .. i .. " field '" .. tostring(field)
            .. "' must be a number (and not NaN)", 2)
    end
    seq[it] = i
  end
  table.sort(items, function(a, b)
    local ka, kb = a[field], b[field]
    if ka ~= kb then return ka < kb end
    return seq[a] < seq[b]
  end)
  return items
end

return M
