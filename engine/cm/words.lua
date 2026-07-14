-- cm.words — a small friendly word bank + name generator.
--
-- Two jobs: (1) the editor's auto-namer — new assets/projects get a
-- collision-checked 3-word name so there's no naming paralysis (the
-- human's ask); (2) a general engine feature — a quick random word or
-- name for grayboxing and testing text (`cm.words.word()` /
-- `cm.words.name()` from anywhere).
--
-- Determinism: the default RNG is DEV-CLASS (seeded from pal.time_ns,
-- so names differ every run) and must NOT be called from sim code that
-- feeds a trace. Sim/graybox code that wants determinism passes its own
-- `rng` (e.g. cm.rand's stream) as the last argument — then the result
-- is a pure function of that stream. The word list itself is data.

local M = select(2, ...) or {}

-- 272 curated words: nature, creatures, warm adjectives, colors, small
-- objects. All lowercase + kebab-safe, so any join is a legal filename.
M.list = {
  "amber", "amethyst", "anchor", "apple", "arbor", "arch", "arrow", "atlas", "azure", "badger",
  "banner", "basalt", "beacon", "bell", "berry", "birch", "bison", "bloom", "bramble", "brave",
  "bream", "breeze", "bright", "brisk", "bronze", "brook", "calm", "cardinal", "cedar", "chime",
  "cider", "cinder", "clever", "cliff", "clove", "clover", "cobalt", "cobble", "comet", "compass",
  "copper", "coral", "cove", "cozy", "crag", "crane", "crater", "crest", "crimson", "crisp",
  "crow", "dapper", "dawn", "deft", "delta", "dewy", "dolphin", "dove", "drake", "drift",
  "dune", "dusk", "dusty", "eager", "egret", "elk", "ember", "emerald", "fable", "fair",
  "falcon", "fawn", "fern", "ferret", "finch", "fjord", "fleet", "flint", "fog", "fond",
  "fox", "frost", "garnet", "gecko", "gentle", "geode", "gilded", "ginger", "glad", "glade",
  "glint", "gorse", "grand", "grotto", "grove", "harbor", "hardy", "harp", "haze", "hazel",
  "heath", "heron", "hollow", "honey", "ibis", "indigo", "ivory", "ivy", "jade", "jay",
  "jolly", "keen", "kelp", "kind", "kite", "koi", "lagoon", "lantern", "lark", "lattice",
  "ledge", "lichen", "lilac", "lily", "lively", "loam", "locket", "lofty", "loom", "lotus",
  "lucky", "lumen", "lynx", "lyre", "maple", "maroon", "marsh", "marten", "meadow", "mellow",
  "merry", "mesa", "mica", "mild", "mink", "mint", "mist", "moor", "mosaic", "moss",
  "moth", "neat", "nectar", "newt", "nimble", "noble", "nutmeg", "oak", "oasis", "ochre",
  "olive", "onyx", "opal", "orchard", "otter", "owl", "panda", "peach", "pebble", "perch",
  "petal", "pika", "pine", "plover", "plucky", "plum", "pollen", "pond", "prairie", "prime",
  "prism", "quail", "quartz", "quick", "quiet", "quill", "rabbit", "raccoon", "rain", "rapid",
  "raven", "reed", "regal", "ribbon", "ridge", "rill", "ripe", "river", "robin", "rosy",
  "rugged", "russet", "sable", "saffron", "sage", "salmon", "sand", "satchel", "scarlet", "scroll",
  "sepia", "shale", "shoal", "shrew", "sienna", "signal", "silt", "slate", "sleek", "sleet",
  "snipe", "snug", "sod", "sorrel", "sparrow", "spindle", "spire", "spruce", "spry", "stark",
  "steppe", "stoat", "stone", "storm", "stout", "summit", "sundial", "sunny", "swan", "swift",
  "tame", "tapestry", "tapir", "teal", "thicket", "thimble", "thistle", "thrush", "tide", "tidy",
  "token", "trellis", "trout", "trusty", "tundra", "umber", "vale", "vane", "verge", "vine",
  "violet", "vivid", "vole", "walrus", "warm", "weasel", "willow", "wise", "witty", "wren",
  "zephyr", "zesty",
}

-- ---- the dev-class RNG (xorshift64, time-seeded) ----

local state
local function reseed()
  local t = (pal and pal.time_ns and pal.time_ns()) or 88172645463325252
  state = t ~ 0x9e3779b97f4a7c15
  if state == 0 then state = 88172645463325252 end
end

-- next raw integer from the internal stream (Lua 5.4 wraps 64-bit ints;
-- >> is a logical shift — a textbook xorshift64)
local function nxt()
  if not state then reseed() end
  local x = state
  x = x ~ (x << 13)
  x = x ~ (x >> 7)
  x = x ~ (x << 17)
  state = x
  return x
end

-- fix the internal stream (tests / reproducible sessions)
function M.seed(x)
  state = (x or 0) ~ 0x9e3779b97f4a7c15
  if state == 0 then state = 1 end
end

-- one random word. `rng` (optional) is a function returning a
-- non-negative integer — pass cm.rand's stream from sim code for
-- determinism; omit for the dev-class stream.
function M.word(rng)
  local r = rng and rng() or nxt()
  return M.list[(r % #M.list) + 1]
end

-- n distinct words joined by sep (defaults: 3 words, "-"). Distinct so
-- names never read "otter-otter-fox".
function M.name(n, sep, rng)
  n = n or 3
  sep = sep or "-"
  local out, used, guard = {}, {}, 0
  while #out < n and guard < 500 do
    guard = guard + 1
    local w = M.word(rng)
    if not used[w] then used[w] = true; out[#out + 1] = w end
  end
  return table.concat(out, sep)
end

-- a name for which `exists(name)` is falsy (collision check). Tries a
-- few times, then falls back to appending a number so it always returns.
function M.unique(exists, n, sep, rng)
  sep = sep or "-"
  for _ = 1, 64 do
    local nm = M.name(n, sep, rng)
    if not exists or not exists(nm) then return nm end
  end
  return M.name(n, sep, rng) .. sep .. tostring((rng and rng() or nxt()) % 9000 + 1000)
end

return M
