-- selftest cartridge — engine invariants that don't need a recorded trace:
-- PRNG known-answer tests against the reference C implementation, trig
-- accuracy sweeps against the host libm, and (as M1 grows) serializer and
-- snapshot round-trips. Run: bin/cosmic projects/selftest --headless --frames 1
-- (--frames sets exit_on_error, so any failed check exits 1).

local rand = cm.require("cm.rand")
local m = cm.require("cm.math")
local state = cm.require("cm.state")

local game = {}
local checks = 0

local function tmproot()
  return (pal.platform == "windows" and os.getenv("TEMP"))
         or os.getenv("TMPDIR") or "/tmp"
end

local function check(cond, what)
  checks = checks + 1
  if not cond then error("SELFTEST FAIL: " .. what, 0) end
end

-- ---- cm.rand vs reference xoshiro256++/splitmix64 (vectors from the
-- Blackman/Vigna C, generated 2026-06-10) ----

local function t_rand_kat()
  local sim = pal.buf("cm.sim", 64)
  -- raw state {1,2,3,4}
  for i = 0, 3 do sim:i64(8 + 8 * i, i + 1) end
  local raw = { 0x0000000002800001, 0x0000000003800067, 0x000cc00003800067,
                0x000cc201994400b2, 0x8012a2019ac433cd }
  for i, want in ipairs(raw) do
    check(rand.u64() == want, "xoshiro raw1234 output " .. i)
  end
  -- splitmix-seeded from the "cosmic2d" seed
  rand.seed(0x70657474616e3264)
  local state = { 0x1fadf3d892dc22fe, 0x96ad28ac07b30484,
                  0x1e6d0aea8184269d, 0x5984702b6063ef56 }
  for i, want in ipairs(state) do
    check(sim:i64(8 * i) == want, "splitmix64 state word " .. i)
  end
  local seeded = { 0x21a793e1bd18bc30, 0x7314ba3b0883c8ae, 0x8e71266b6363309b,
                   0x5965242c1ef2656c, 0x65189f90d2598893 }
  for i, want in ipairs(seeded) do
    check(rand.u64() == want, "xoshiro seeded output " .. i)
  end
end

local function t_rand_dist()
  rand.seed(42)
  for _ = 1, 10000 do
    local f = rand.float()
    check(f >= 0.0 and f < 1.0, "float() in [0,1)")
    local r = rand.range(-7, 9)
    check(math.tointeger(r) and r >= -7 and r <= 9, "range(-7,9) bounds")
  end
  check(rand.range(1, 1) == 1, "range(1,1) degenerate")
  local seen = {}
  for _ = 1, 200 do seen[rand.range(3)] = true end
  check(seen[1] and seen[2] and seen[3], "range(3) hits all values")
  check(({ "a" })[1] == rand.pick({ "a" }), "pick singleton")
end

-- ---- cm.math vs host libm (accuracy, not bit-equality: libm is the
-- reference for *closeness*; bit-exactness across runs is the goldens' job)

local TOL = 1e-11

local function t_trig_sweep()
  local worst_s, worst_c, worst_t = 0, 0, 0
  local x = -40.0
  while x <= 40.0 do
    local es = math.abs(m.sin(x) - math.sin(x))
    local ec = math.abs(m.cos(x) - math.cos(x))
    if es > worst_s then worst_s = es end
    if ec > worst_c then worst_c = ec end
    x = x + 0.00041
  end
  check(worst_s < TOL, "sin sweep accuracy (worst " .. worst_s .. ")")
  check(worst_c < TOL, "cos sweep accuracy (worst " .. worst_c .. ")")
  -- big-argument reduction, near quadrant boundaries where it's hardest
  local halfpi = math.pi / 2
  for _, k in ipairs({ 100, 12345, 99999, 654321, 667543 }) do
    for _, off in ipairs({ -0.1, -1e-6, 0, 1e-6, 0.1 }) do
      local a = k * halfpi + off
      local es = math.abs(m.sin(a) - math.sin(a))
      local ec = math.abs(m.cos(a) - math.cos(a))
      check(es < TOL and ec < TOL, "reduction near " .. k .. "*pi/2+" .. off)
    end
  end
  x = -1.5
  while x <= 1.5 do
    local et = math.abs(m.tan(x) - math.tan(x))
    if et > worst_t then worst_t = et end
    x = x + 0.00073
  end
  check(worst_t < 1e-9, "tan sweep accuracy (worst " .. worst_t .. ")")
  check(m.sin(0) == 0 and m.cos(0) == 1, "exact at zero")
  check(not pcall(m.sin, 2 ^ 21), "sin domain guard")
  check(not pcall(m.sin, 0 / 0), "sin NaN guard")
end

local function t_atan_sweep()
  local worst = 0
  local x = -50.0
  while x <= 50.0 do
    local e = math.abs(m.atan(x) - math.atan(x))
    if e > worst then worst = e end
    x = x + 0.00097
  end
  check(worst < TOL, "atan sweep accuracy (worst " .. worst .. ")")
  worst = 0
  local y = -3.0
  while y <= 3.0 do
    local x2 = -3.0
    while x2 <= 3.0 do
      local e = math.abs(m.atan2(y, x2) - math.atan(y, x2))
      if e > worst then worst = e end
      x2 = x2 + 0.0131
    end
    y = y + 0.0131
  end
  check(worst < TOL, "atan2 grid accuracy (worst " .. worst .. ")")
  check(m.atan2(0, 1) == 0, "atan2(+0,+x) = +0")
  check(m.atan2(0, -1) > 3.14 and m.atan2(0, -1) < 3.15, "atan2(0,-x) = pi")
  check(m.atan2(1, 0) == m.atan2(2, 0), "atan2(+y,0) = pi/2")
  worst = 0
  x = -1.0
  while x <= 1.0 do
    local ea = math.abs(m.asin(x) - math.asin(x))
    local ec = math.abs(m.acos(x) - math.acos(x))
    if ea > worst then worst = ea end
    if ec > worst then worst = ec end
    x = x + 0.00079
  end
  check(worst < 1e-9, "asin/acos sweep accuracy (worst " .. worst .. ")")
  check(m.asin(1.0000001) == m.asin(1), "asin clamps overdrive")
end

-- ---- cm.state: canonical serializer ----

local function deep_equal(a, b)
  if a == b then
    -- distinguish 1 vs 1.0 (different canonical bytes, both must round-trip)
    return type(a) ~= "number" or math.type(a) == math.type(b)
  end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  local n = 0
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
    n = n + 1
  end
  for _ in pairs(b) do n = n - 1 end
  return n == 0
end

local function t_canon()
  local doc = {
    name = "he\0llo", count = 42, ratio = 0.5, on = true, off = false,
    [1] = "one", [2] = 2.0, [-3] = { nested = { 7, 8, 9 }, neg = -0.0 },
    inf = math.huge, big = 0x7fffffffffffffff,
  }
  local bytes = state.canon(doc)
  check(deep_equal(state.parse(bytes), doc), "canon round-trip")
  check(state.canon(state.parse(bytes)) == bytes, "canon is a fixpoint")
  -- key order independence
  local x1, x2 = {}, {}
  x1.a = 1; x1.b = 2; x1[10] = 3; x1[2] = 4
  x2[2] = 4; x2.b = 2; x2[10] = 3; x2.a = 1
  check(state.canon(x1) == state.canon(x2), "canonical key order")
  -- type distinctions
  check(state.canon(1) ~= state.canon(1.0), "integer vs float bytes")
  check(state.canon(0.0) ~= state.canon(-0.0), "-0.0 bits preserved")
  local nz = state.parse(state.canon(-0.0))
  check(1.0 / nz < 0, "-0.0 round-trips")
  -- rejections
  check(not pcall(state.canon, { bad = 0 / 0 }), "NaN rejected")
  check(not pcall(state.canon, { fn = print }), "function rejected")
  check(not pcall(state.canon, { [1.5] = 1 }), "fractional key rejected")
  check(not pcall(state.canon, { [true] = 1 }), "boolean key rejected")
  local cyc = {}
  cyc.self = cyc
  check(not pcall(state.canon, cyc), "cycle rejected")
  local shared = { x = 1 }
  check(not pcall(state.canon, { a = shared, b = shared }), "alias rejected")
end

-- ---- cm.state: snapshot round-trip ----

local function t_snapshot()
  local sim = pal.buf("cm.sim", 64)
  rand.seed(777)
  sim:i64(0, 1234) -- pretend we're at frame 1234

  local b1 = pal.buf("selftest.b1", 128)
  for i = 0, 127 do b1:u8(i, (i * 7 + 3) % 256) end
  local b1_bytes = b1:str(0, 128)

  state.doc.player = { x = 10, y = 20.5, name = "pet" }
  state.doc.flags = { true, false, true }

  local snap = state.snapshot()
  local epoch_before = cm.code_epoch

  -- Explicit runtime snapshots publish as one atomic generation.
  local snapshot_path = "/tmp/cosmic_selftest_atomic.csnap"
  pal.write_file(snapshot_path, "known-good-snapshot")
  local sok, serr = state.save(snapshot_path, { _fail = "rename" })
  check(not sok and serr:find("write snapshot failed", 1, true)
        and pal.read_file(snapshot_path) == "known-good-snapshot",
        "snapshot: interrupted save preserves previous file")
  check(state.save(snapshot_path)
        and pal.read_file(snapshot_path) == snap,
        "snapshot: retry publishes complete snapshot")

  -- wreck everything the snapshot should put back
  sim:i64(0, 9999)
  rand.seed(1)
  b1:fill(0, 128, 0xee)
  state.doc.player = nil
  state.doc.junk = { 1, 2, 3 }
  local b2 = pal.buf("selftest.b2", 32)
  b2:fill(0, 32, 0xaa)

  state.restore(snap)

  check(state.frame() == 1234, "frame counter restored")
  check(b1:str(0, 128) == b1_bytes, "buffer bytes restored")
  check(state.doc.player and state.doc.player.y == 20.5
        and state.doc.player.name == "pet", "doc tree restored")
  check(state.doc.junk == nil, "post-snapshot doc junk gone")
  local have = {}
  for _, b in ipairs(pal.buf_list()) do have[b.name] = b.size end
  check(have["selftest.b2"] == nil, "post-snapshot buffer freed by restore")
  check(have["selftest.b1"] == 128, "snapshot buffer present")
  -- prng stream position restored: same next draw as right after seed(777)
  rand.seed(777)
  local expect_draw = rand.u64()
  state.restore(snap)
  check(rand.u64() == expect_draw, "prng stream position restored")

  check(cm.code_epoch > epoch_before, "restore bumps code epoch")
  check(#cm.reload() == 0, "disk reload paused while on bundle code")
  cm.adopt_disk()
  pal.buf_free("selftest.b1")
end

-- ---- cm.math.exp2 + cm.ease ----

local function t_exp2()
  check(m.exp2(0) == 1.0 and m.exp2(10) == 1024.0 and m.exp2(-3) == 0.125,
        "exp2 exact at integers")
  local worst = 0
  local x = -20.0
  while x <= 10.0 do
    local rel = math.abs(m.exp2(x) / (2.0 ^ x) - 1.0)
    if rel > worst then worst = rel end
    x = x + 0.00037
  end
  check(worst < 1e-12, "exp2 sweep accuracy (worst rel " .. worst .. ")")
  check(not pcall(m.exp2, 0 / 0), "exp2 NaN guard")
  check(m.exp2(-2000) == 0.0, "exp2 deep underflow is zero")
end

local function t_ease()
  local ease = cm.require("cm.ease")
  local names = ease.names()
  check(#names == 31, "expected curve count (got " .. #names .. ")")
  for _, name in ipairs(names) do
    local f = ease.get(name)
    check(f(0.0) == 0.0 and f(1.0) == 1.0, name .. " endpoints pinned")
    check(f(-1.0) == 0.0 and f(2.0) == 1.0, name .. " clamps outside [0,1]")
  end
  -- monotone families rise monotonically
  for _, fam in ipairs({ "linear", "quad_in", "cubic_out", "quart_inout",
                         "quint_in", "sine_inout", "expo_in", "expo_out",
                         "circ_in" }) do
    local f = ease.get(fam)
    local prev = 0.0
    for i = 1, 200 do
      local v = f(i / 200.0)
      check(v >= prev - 1e-12, fam .. " monotone at " .. i)
      prev = v
    end
  end
  -- inout curves hit ~0.5 at the midpoint
  for _, fam in ipairs({ "quad", "cubic", "sine", "expo", "bounce" }) do
    local v = ease.get(fam .. "_inout")(0.5)
    check(math.abs(v - 0.5) < 1e-9, fam .. "_inout midpoint")
  end
  -- character checks: back overshoots low early, elastic rings over 1
  check(ease.back_in(0.2) < 0.0, "back_in undershoots")
  local rang = false
  for i = 1, 99 do
    if ease.elastic_out(i / 100.0) > 1.0 then rang = true end
  end
  check(rang, "elastic_out overshoots past 1")
  -- bounce stays in range
  for i = 0, 100 do
    local v = ease.bounce_out(i / 100.0)
    check(v >= -1e-12 and v <= 1.0 + 1e-12, "bounce_out in range")
  end
  -- registry: by-name (sim-state friendly) and custom registration
  check(ease.mix(10, 20, 0.5, "linear") == 15.0, "mix by name")
  check(ease.mix(10, 20, 2.0, "linear") == 20.0, "mix clamps t")
  check(not pcall(ease.get, "nope"), "unknown easing errors")
  ease.register("selftest_step", function(t) return t < 0.5 and 0.0 or 1.0 end)
  check(ease.get("selftest_step")(0.7) == 1.0, "custom curve registered")
end

-- ---- cm.box: pure AABB queries + the axis-at-a-time slide (A5/D090) ----

local function t_box()
  local box = cm.require("cm.box")
  -- overlap is strict: sharing an edge is NOT overlapping
  check(box.overlap(0, 0, 10, 10, 5, 5, 10, 10), "box: plain overlap")
  check(not box.overlap(0, 0, 10, 10, 10, 0, 10, 10), "box: right edge touch is out")
  check(not box.overlap(0, 0, 10, 10, 0, 10, 10, 10), "box: bottom edge touch is out")
  check(box.overlap(0, 0, 10, 10, 9, 9, 10, 10), "box: 1px in is in")
  check(not box.overlap(0, 0, 10, 10, -10, 0, 10, 10), "box: left edge touch is out")
  check(box.overlap(0, 0, 10, 10, 2, 2, 4, 4), "box: containment overlaps")
  check(box.overlap_rect(0, 0, 10, 10, { x = 5, y = 5, w = 10, h = 10 }),
        "box: keyed-rect form agrees")
  check(not box.overlap_rect(0, 0, 10, 10, { x = 10, y = 0, w = 5, h = 5 }),
        "box: keyed-rect edge is out")
  -- touch: centered square at a point (the pickup shape)
  check(box.touch(0, 0, 10, 10, { x = 12, y = 5 }, 6), "box: touch reaches")
  check(not box.touch(0, 0, 10, 10, { x = 13, y = 5 }, 6), "box: touch edge is out")
  -- contains: right/bottom exclusive, matching overlap
  check(box.contains(0, 0, 10, 10, 0, 0), "box: contains top-left corner")
  check(not box.contains(0, 0, 10, 10, 10, 5), "box: right edge excluded")
  check(not box.contains(0, 0, 10, 10, 5, 10), "box: bottom edge excluded")
  check(box.contains(0, 0, 10, 10, 9.5, 9.5), "box: interior float point")
  -- expand grows every side; negative shrinks
  local ex, ey, ew, eh = box.expand(10, 20, 30, 40, 3)
  check(ex == 7 and ey == 17 and ew == 36 and eh == 46, "box: expand grows")
  ex, ey, ew, eh = box.expand(10, 20, 30, 40, -5)
  check(ex == 15 and ey == 25 and ew == 20 and eh == 30, "box: expand shrinks")
  -- hit: first match in array order; extra rect fields pass through
  local rects = { { x = 0, y = 0, w = 10, h = 10, tag = "a" },
                  { x = 20, y = 0, w = 10, h = 10, tag = "b" },
                  { x = 22, y = 0, w = 10, h = 10, tag = "c" } }
  local i, r = box.hit(rects, 25, 5, 2, 2)
  check(i == 2 and r.tag == "b", "box: hit returns the first in order")
  check(box.hit(rects, 100, 100, 5, 5) == nil, "box: hit misses honestly")
  check(box.hit({}, 0, 0, 5, 5) == nil, "box: empty list misses")
  local ids = box.hits(rects, 21, 5, 5, 5)
  check(#ids == 2 and ids[1] == 2 and ids[2] == 3, "box: hits lists in order")
  local reuse = { 9, 9, 9, 9 }
  box.hits(rects, 100, 100, 1, 1, reuse)
  check(#reuse == 0, "box: hits clears the reused table")
  -- slide: whole-step axis-at-a-time with cancelled axes reported
  local walls = { { x = 20, y = -100, w = 10, h = 200 } } -- a right wall
  local nx, ny, hx, hy = box.slide(0, 0, 10, 10, 5, 3, walls)
  check(nx == 5 and ny == 3 and not hx and not hy, "box: free slide moves both")
  nx, ny, hx, hy = box.slide(8, 0, 10, 10, 5, 3, walls)
  check(nx == 8 and ny == 3 and hx and not hy, "box: x blocked, y still moves")
  nx, ny, hx, hy = box.slide(10, 0, 10, 10, 0, 7, walls) -- flush against it
  check(nx == 10 and ny == 7 and not hx and not hy,
        "box: flush contact never counts as overlap")
  local floorw = { { x = -100, y = 20, w = 200, h = 10 } }
  nx, ny, hx, hy = box.slide(0, 8, 10, 10, 4, 5, floorw)
  check(nx == 4 and ny == 8 and not hx and hy, "box: y blocked, x still moves")
  local corner = { { x = 20, y = -100, w = 10, h = 200 },
                   { x = -100, y = 20, w = 200, h = 10 } }
  nx, ny, hx, hy = box.slide(12, 12, 10, 10, 5, 5, corner)
  check(nx == 12 and ny == 12 and hx and hy, "box: cornered cancels both")
  nx, ny = box.slide(0, 0, 10, 10, 0, 0, walls)
  check(nx == 0 and ny == 0, "box: zero move is a no-op")
  -- the tunneling caveat is real and documented: a step past a thin wall
  -- lands on the far side (this is the lightweight mover, not the swept one)
  nx = box.slide(0, 0, 10, 10, 40, 0, walls)
  check(nx == 40, "box: whole-step tunneling is the documented tradeoff")
end

-- ---- cm.actor: the actor/world slice (A5/D091) ----

local function t_actor()
  local actor = cm.require("cm.actor")
  local state_m = cm.require("cm.state")

  -- spawn: ascending stable ids, same table back, fields pass through
  local w = actor.world()
  check(w.next_id == 1 and #w.list == 0, "actor: fresh world is empty")
  local a = actor.spawn(w, { tag = "enemy", x = 0, y = 0, w = 10, h = 10 })
  local b = actor.spawn(w, { tag = "shot", x = 40, y = 0, w = 4, h = 4 })
  local c = actor.spawn(w, { tag = "enemy", x = 20, y = 0, w = 10, h = 10 })
  check(a.id == 1 and b.id == 2 and c.id == 3, "actor: ids ascend from 1")
  check(w.list[1] == a and w.list[3] == c, "actor: spawn appends in order")
  check(a.tag == "enemy" and a.speed == nil, "actor: your table passes through")
  check(not pcall(actor.spawn, w, "nope"), "actor: non-table spawn refused")
  check(not pcall(actor.spawn, w, a), "actor: double spawn refused")
  check(not pcall(actor.spawn, w, { tag = 7 }), "actor: non-string tag refused")

  -- get: binary search over the id-sorted list
  check(actor.get(w, 2) == b, "actor: get finds by id")
  check(actor.get(w, 99) == nil, "actor: unknown id is nil")

  -- iteration: spawn order, tag filter
  local seen = {}
  for x in actor.each(w) do seen[#seen + 1] = x.id end
  check(#seen == 3 and seen[1] == 1 and seen[2] == 2 and seen[3] == 3,
        "actor: each walks spawn order")
  seen = {}
  for x in actor.each(w, "enemy") do seen[#seen + 1] = x.id end
  check(#seen == 2 and seen[1] == 1 and seen[2] == 3, "actor: tag filter")
  check(actor.count(w) == 3 and actor.count(w, "enemy") == 2
        and actor.count(w, "ghost") == 0, "actor: count live by tag")
  check(actor.first(w) == a and actor.first(w, "shot") == b
        and actor.first(w, "ghost") == nil, "actor: first in spawn order")

  -- despawn marks: queries skip immediately, corpse stays until tick
  check(actor.despawn(w, a) == true, "actor: despawn live returns true")
  check(actor.despawn(w, a) == false, "actor: double despawn is a no-op")
  check(actor.despawn(w, 99) == false, "actor: despawn unknown id is a no-op")
  check(actor.get(w, 1) == nil, "actor: dead id reads nil")
  check(actor.count(w, "enemy") == 1 and actor.first(w, "enemy") == c,
        "actor: dead skipped by count/first")
  check(#w.list == 3, "actor: corpse remains listed until tick")

  -- despawn inside an each pass is safe; spawns during a pass are visited
  local order = {}
  for x in actor.each(w) do
    order[#order + 1] = x.id
    if x.id == 2 then
      actor.despawn(w, 3)
      actor.spawn(w, { tag = "shot" })
    end
  end
  check(#order == 2 and order[1] == 2 and order[2] == 4,
        "actor: mid-pass despawn skipped, mid-pass spawn visited")

  -- tick sweeps corpses preserving order; ids stay stable
  actor.tick(w)
  check(#w.list == 2 and w.list[1].id == 2 and w.list[2].id == 4,
        "actor: tick sweeps dead, order preserved")
  check(actor.get(w, 2) == b, "actor: get still exact after sweep")
  check(actor.spawn(w, {}).id == 5, "actor: ids never reused after sweep")
  check(actor.despawn(w, b) and select("#", actor.tick(w)) == 0,
        "actor: tick returns nothing")

  -- hit: first live strict-edge overlap in spawn order
  local hw = actor.world()
  local h1 = actor.spawn(hw, { tag = "enemy", x = 0, y = 0, w = 10, h = 10 })
  local h2 = actor.spawn(hw, { tag = "enemy", x = 8, y = 0, w = 10, h = 10 })
  actor.spawn(hw, { tag = "marker" }) -- rect-less: never hittable
  check(actor.hit(hw, "enemy", 9, 5, 4, 4) == h1, "actor: hit first in order")
  actor.despawn(hw, h1)
  check(actor.hit(hw, "enemy", 9, 5, 4, 4) == h2, "actor: hit skips the dead")
  check(actor.hit(hw, "enemy", 30, 0, 5, 5) == nil, "actor: hit misses honestly")
  check(actor.hit(hw, "enemy", 17, 0, 5, 5) == h2
        and actor.hit(hw, "enemy", 18, 0, 5, 5) == nil,
        "actor: hit edges are strict")
  check(actor.hit(hw, nil, 0, 0, 500, 500) == h2,
        "actor: untagged hit sees every rect actor")

  -- timers: integer countdowns; expired exactly on the zero frame
  local tw = actor.world()
  local e = actor.spawn(tw, { tag = "enemy" })
  actor.timer(e, "cool", 2)
  check(actor.time(e, "cool") == 2 and actor.running(e, "cool")
        and not actor.expired(e, "cool"), "actor: armed timer runs")
  actor.tick(tw)
  check(actor.time(e, "cool") == 1 and actor.running(e, "cool"),
        "actor: timer counts down")
  actor.tick(tw)
  check(actor.expired(e, "cool") and not actor.running(e, "cool"),
        "actor: expired exactly on the zero frame")
  actor.tick(tw)
  check(actor.time(e, "cool") == nil and not actor.expired(e, "cool"),
        "actor: the tick after expiry forgets the timer")
  check(e.t == nil, "actor: empty timer table leaves the doc")
  actor.timer(e, "cool", 5)
  actor.tick(tw)
  actor.timer(e, "cool", 5)
  check(actor.time(e, "cool") == 5, "actor: rearm resets the count")
  actor.timer(e, "zap", 0)
  check(actor.expired(e, "zap"), "actor: zero-frame timer expires now")
  actor.timer(tw, "wave", 1)
  actor.tick(tw)
  check(actor.expired(tw, "wave"), "actor: the world itself holds timers")
  actor.despawn(tw, e)
  actor.tick(tw)
  check(actor.time(e, "cool") == 4, "actor: dead actors' timers stop ticking")
  check(not pcall(actor.timer, e, "bad", -1), "actor: negative frames refused")
  check(not pcall(actor.timer, e, "bad", 1.5), "actor: float frames refused")

  -- determinism: identical op sequences canonicalize byte-identically
  local function build()
    local bw = actor.world()
    local p = actor.spawn(bw, { tag = "enemy", x = 3, y = 4, w = 9, h = 9 })
    actor.spawn(bw, { tag = "shot", x = 1, y = 1, w = 4, h = 4 })
    actor.timer(p, "cool", 3)
    actor.timer(bw, "wave", 30)
    actor.tick(bw)
    actor.despawn(bw, 2)
    actor.tick(bw)
    return bw
  end
  check(state_m.canon(build()) == state_m.canon(build()),
        "actor: same ops, same canonical bytes")
end

-- ---- cm.camera: follow/bounds/shake/convert over a plain doc table (A5/D092) ----

local function t_camera()
  local camera = cm.require("cm.camera")
  local state_m = cm.require("cm.state")
  local gw, gh = pal.gfx_size()

  -- new: view-size defaults from the project FOV; explicit fields win
  local c = camera.new()
  check(c.x == 0 and c.y == 0 and c.w == gw and c.h == gh,
        "camera: new defaults to the FOV at 0,0")
  c = camera.new({ x = 5, y = 6, w = 320, h = 180 })
  check(c.x == 5 and c.y == 6 and c.w == 320 and c.h == 180,
        "camera: explicit new fields")

  -- center: the cut. Unbounded is exact; bounds clamp it.
  camera.center(c, 500, 300)
  check(c.x == 500 - 160 and c.y == 300 - 90, "camera: center is exact")
  camera.bounds(c, 0, 0, 1000, 400)
  camera.center(c, 0, 0)
  check(c.x == 0 and c.y == 0, "camera: center clamps to bounds")
  camera.center(c, 2000, 2000)
  check(c.x == 1000 - 320 and c.y == 400 - 180,
        "camera: center clamps to the far edge")

  -- bounds: setting clamps NOW; a small span centers; clearing frees
  c.x, c.y = -50, -50
  camera.bounds(c, 0, 0, 1000, 400)
  check(c.x == 0 and c.y == 0, "camera: bounds clamps immediately")
  camera.bounds(c, 0, 0, 100, 180)
  check(c.x == (100 - 320) / 2 and c.y == 0,
        "camera: a span smaller than the view centers over it")
  camera.bounds(c)
  check(c.bx == nil and c.bw == nil, "camera: bounds clear")
  camera.center(c, -400, -400)
  check(c.x == -400 - 160, "camera: unbounded roams free")

  -- follow: default is snap (lerp 1, dead 0)
  c = camera.new({ w = 320, h = 180 })
  camera.follow(c, 100, 50)
  check(c.x == 100 - 160 and c.y == 50 - 90, "camera: default follow snaps")

  -- follow: the exact demo lerp — err * lerp beyond a zero deadzone
  c = camera.new({ w = 320, h = 180 })
  local tx = 100
  local want = 0 + ((tx - (0 + 160)) * 0.25)
  camera.follow(c, tx, 90, { lerp = 0.25 })
  check(c.x == want, "camera: follow lerp math is exact")
  check(c.y == 0, "camera: centered axis holds still")

  -- deadzone: inside holds, beyond eases by the excess only, both signs
  c = camera.new({ w = 320, h = 180 })
  camera.follow(c, 160, 90 + 26, { lerp = 0.5, dead = 26 })
  check(c.x == 0 and c.y == 0, "camera: error inside the deadzone holds")
  camera.follow(c, 160, 90 + 30, { lerp = 0.5, dead = 26 })
  check(c.y == (30 - 26) * 0.5, "camera: eases by the excess beyond dead")
  camera.follow(c, 160 - 40, 90 + 30 - c.y, { lerp = 0.5, dead = 26 })
  check(c.x == -(40 - 26) * 0.5, "camera: negative side is symmetric")

  -- per-axis knobs + the lookahead offset
  c = camera.new({ w = 320, h = 180 })
  camera.follow(c, 160, 100, { lerp = 0.5, lerp_y = 0.25, dead_y = 4 })
  check(c.x == 0 and c.y == (10 - 4) * 0.25, "camera: per-axis lerp/dead")
  c = camera.new({ w = 320, h = 180 })
  camera.follow(c, 160, 90, { ox = 30 })
  check(c.x == 30, "camera: ox offsets the target (lookahead)")

  -- follow ends clamped
  c = camera.new({ w = 320, h = 180 })
  camera.bounds(c, 0, 0, 1000, 180)
  camera.follow(c, -500, 90)
  check(c.x == 0 and c.y == 0, "camera: follow ends clamped")

  -- shake: refusals, countdown, linear fade, removal at zero
  check(not pcall(camera.shake, c, -1, 10), "camera: negative mag refused")
  check(not pcall(camera.shake, c, "big", 10), "camera: non-number mag refused")
  check(not pcall(camera.shake, c, 3, 1.5), "camera: float frames refused")
  check(not pcall(camera.shake, c, 3, -2), "camera: negative frames refused")
  camera.shake(c, 3, 2)
  check(c.shake == 2 and c.shake_t0 == 2 and c.shake_mag == 3,
        "camera: shake arms the doc counters")
  local ox, oy = camera.offset(c)
  check(ox ~= 0 or oy ~= 0, "camera: armed shake wobbles")
  local full = ox * ox + oy * oy
  camera.tick(c)
  check(c.shake == 1, "camera: tick counts the shake down")
  ox, oy = camera.offset(c)
  check(ox * ox + oy * oy < full, "camera: the wobble fades as it counts")
  camera.tick(c)
  check(c.shake == nil and c.shake_t0 == nil and c.shake_mag == nil,
        "camera: a finished shake leaves the table")
  check(select(1, camera.offset(c)) == 0 and select(2, camera.offset(c)) == 0,
        "camera: idle offset is zero")
  camera.shake(c, 3, 10)
  camera.tick(c)
  camera.shake(c, 1, 4)
  check(c.shake == 4 and c.shake_t0 == 4 and c.shake_mag == 1,
        "camera: rearm replaces a running shake")
  camera.shake(c, 0, 4)
  check(c.shake == nil, "camera: zero mag clears")
  camera.shake(c, 3, 0)
  check(c.shake == nil, "camera: zero frames clears")

  -- offsets are deterministic: same counters, same wobble
  local c1 = camera.shake(camera.new({ w = 320, h = 180 }), 5, 7)
  local c2 = camera.shake(camera.new({ w = 320, h = 180 }), 5, 7)
  local a1, b1 = camera.offset(c1)
  local a2, b2 = camera.offset(c2)
  check(a1 == a2 and b1 == b2, "camera: same counters, same offset")

  -- conversion: exact round trip through the UNSHAKEN camera
  c = camera.new({ x = 12.5, y = -3, w = 320, h = 180 })
  camera.shake(c, 9, 30)
  local sx, sy = camera.to_screen(c, 100, 50)
  check(sx == 87.5 and sy == 53, "camera: to_screen ignores the shake")
  local wx, wy = camera.to_world(c, sx, sy)
  check(wx == 100 and wy == 50, "camera: to_world round-trips exactly")

  -- apply: returns the shaken top-left it handed to gfx
  local ax, ay = camera.apply(c)
  local pox, poy = camera.offset(c)
  check(ax == c.x + pox and ay == c.y + poy,
        "camera: apply returns the shaken top-left")
  camera.shake(c, 0, 0)
  ax, ay = camera.apply(c)
  check(ax == c.x and ay == c.y, "camera: apply without shake is the camera")
  cm.require("cm.gfx").camera(0, 0) -- leave the render camera as found

  -- determinism: identical op sequences canonicalize byte-identically
  local function build()
    local bc = camera.new({ w = 320, h = 180 })
    camera.bounds(bc, 0, 0, 640, 360)
    camera.center(bc, 100, 100)
    camera.follow(bc, 140, 100, { lerp = 0.1, dead_y = 26, ox = 12 })
    camera.shake(bc, 4, 18)
    camera.tick(bc)
    return bc
  end
  check(state_m.canon(build()) == state_m.canon(build()),
        "camera: same ops, same canonical bytes")
end

-- ---- cm.tween: named effect counters + eased presentation (A5/D094) ----

local function t_tween()
  local tween = cm.require("cm.tween")
  local ease = cm.require("cm.ease")
  local m = cm.require("cm.math")
  local state_m = cm.require("cm.state")

  -- play refusals: name/frames/mag validation
  local d = {}
  check(not pcall(tween.play, d, 7, 3), "tween: non-string name refused")
  check(not pcall(tween.play, d, "x", 1.5), "tween: fractional frames refused")
  check(not pcall(tween.play, d, "x", -1), "tween: negative frames refused")
  check(not pcall(tween.play, d, "x", 3, "big"), "tween: non-number mag refused")

  -- arming stores t, t0, and the optional mag on o.tw
  tween.play(d, "flash", 14, 0.55)
  check(d.tw.flash.t == 14 and d.tw.flash.t0 == 14 and d.tw.flash.mag == 0.55,
        "tween: play stores t, t0, mag")
  tween.play(d, "pause", 2)
  check(d.tw.pause.mag == nil, "tween: mag stays optional")
  check(tween.on(d, "flash") and tween.on(d, "pause"), "tween: armed is on")
  check(not tween.on(d, "shake"), "tween: unarmed is off")
  check(tween.k(d, "flash") == 1.0, "tween: k is 1 at the armed frame")
  check(tween.k(d, "shake") == 0.0, "tween: idle k is 0")

  -- re-arming REPLACES (the camera.shake rule): t, t0, and mag all reset
  tween.play(d, "flash", 8)
  check(d.tw.flash.t == 8 and d.tw.flash.t0 == 8 and d.tw.flash.mag == nil,
        "tween: play replaces a running effect wholesale")
  tween.play(d, "flash", 14, 0.55)

  -- tick: each effect decrements independently; k tracks t/t0 exactly
  tween.tick(d)
  check(d.tw.flash.t == 13 and d.tw.pause.t == 1,
        "tween: tick decrements every effect")
  check(tween.k(d, "flash") == 13 / 14, "tween: k is the remaining fraction")

  -- the zero frame exists: present (and gating) for exactly n ticks
  tween.tick(d)
  check(d.tw.pause.t == 0 and tween.on(d, "pause"),
        "tween: the zero frame is still on")
  check(tween.k(d, "pause") == 0.0, "tween: the zero frame's k is 0")
  tween.tick(d)
  check(not tween.on(d, "pause"), "tween: one tick after zero it is gone")
  check(d.tw.pause == nil and d.tw.flash ~= nil,
        "tween: removal is per-effect")

  -- the pause idiom: play(n) freezes a post-tick gate for exactly n steps
  local g = {}
  tween.play(g, "pause", 3)
  local frozen = 0
  for _ = 1, 6 do
    tween.tick(g)
    if tween.on(g, "pause") then frozen = frozen + 1 end
  end
  check(frozen == 3, "tween: play(n) gates exactly n post-tick steps")
  check(g.tw == nil, "tween: the empty tw table leaves the host")

  -- val: mag * curve(k); linear default; named curves resolve via cm.ease
  check(tween.val(d, "flash") == 0.55 * (11 / 14),
        "tween: val is mag * k by default")
  check(tween.val(d, "flash", "cubic_out")
          == 0.55 * ease.cubic_out(11 / 14),
        "tween: val applies a named curve")
  check(tween.val(d, "gone") == 0.0, "tween: idle val is 0")
  check(not pcall(tween.val, d, "flash", "no_such_curve"),
        "tween: unknown curve names error loudly")

  -- mix: from at full, to at rest, eased between; idle returns to
  local e2 = {}
  tween.play(e2, "slide", 10)
  check(tween.mix(e2, "slide", -40, 0) == -40,
        "tween: mix starts at from")
  for _ = 1, 5 do tween.tick(e2) end
  check(tween.mix(e2, "slide", -40, 0) == 0 + (-40 - 0) * 0.5,
        "tween: mix eases on k")
  check(tween.mix(e2, "slide", -40, 0, "quad_in")
          == 0 + (-40 - 0) * ease.quad_in(0.5),
        "tween: mix applies a named curve")
  check(tween.mix(e2, "gone", -40, 7) == 7, "tween: idle mix rests at to")

  -- wobble: the exact camera.offset math off the remaining count
  local w = {}
  tween.play(w, "shake", 6, 2.4)
  tween.tick(w)
  local ox, oy = tween.wobble(w, "shake")
  local a = 2.4 * 5 / 6
  check(ox == m.sin(5 * 2.7) * a and oy == m.sin(5 * 3.1 + 2) * a,
        "tween: wobble is the camera shake idiom")
  local zx, zy = tween.wobble(w, "gone")
  check(zx == 0.0 and zy == 0.0, "tween: idle wobble is 0, 0")

  -- bob: pure looping helper — exact sin over a frame period
  check(tween.bob(0, 90, 2) == 0.0, "tween: bob starts at 0")
  check(tween.bob(30, 90, 2) == 2 * m.sin(30 * (m.tau / 90)),
        "tween: bob is amp * sin over the period")
  check(not pcall(tween.bob, 10, 0, 2), "tween: zero bob period refused")

  -- stop/clear: immediate idle; play(0) is stop
  tween.play(w, "flash", 5, 1)
  tween.stop(w, "shake")
  check(not tween.on(w, "shake") and tween.on(w, "flash"),
        "tween: stop ends one effect")
  tween.play(w, "flash", 0)
  check(w.tw == nil, "tween: play(0) stops and drops the empty table")
  tween.play(w, "a", 3)
  tween.play(w, "b", 4)
  tween.clear(w)
  check(w.tw == nil, "tween: clear ends everything")

  -- determinism: identical op sequences canonicalize byte-identically
  local function build()
    local b = {}
    tween.play(b, "pause", 2)
    tween.play(b, "shake", 6, 2.4)
    tween.play(b, "flash", 14, 0.55)
    tween.tick(b)
    tween.stop(b, "pause")
    tween.tick(b)
    return b
  end
  check(state_m.canon(build()) == state_m.canon(build()),
        "tween: same ops, same canonical bytes")
end

-- ---- reduced effects: the A8 accessibility policy (D129) ----
-- reduce-shake zeroes the engine's render-only shake doors, reduce-flash
-- attenuates the flash door, the pure sim-legal reads never move, and the
-- choices ride the user-wide accessibility store.

local function t_reduce_fx()
  local view = cm.require("cm.view")
  local camera = cm.require("cm.camera")
  local tween = cm.require("cm.tween")
  local ease = cm.require("cm.ease")
  local options = cm.require("cm.options")
  local state_m = cm.require("cm.state")

  -- hermetic: never touch the real user store, leave every knob as found
  local saved_access = view._access_path
  local saved_cfg = { reduce_shake = view.cfg.reduce_shake,
                      reduce_flash = view.cfg.reduce_flash,
                      editor_scale = view.cfg.editor_scale,
                      chrome_scale = view.cfg.chrome_scale,
                      access_auto = view.cfg.access_auto,
                      access_resolved = view.access_resolved }
  local root = tmproot() .. "/cosmic_selftest_reduce"
  pal.x_remove(root .. "/editor.dat")
  pal.x_remove(root)
  pal.mkdir(root)
  view._access_path = root .. "/editor.dat"
  view.cfg.reduce_shake, view.cfg.reduce_flash = false, false

  -- defaults: both scales are unity, on view and the options delegates
  check(view.shake_scale() == 1.0 and view.flash_scale() == 1.0,
        "reduce: default scales are unity")
  check(options.shake_scale() == 1.0 and options.flash_scale() == 1.0,
        "reduce: the options doors delegate to view")

  -- camera.offset: reduce-shake zeroes it; releasing restores EXACT bytes
  local c = camera.shake(camera.new({ w = 320, h = 180 }), 5, 7)
  local ox, oy = camera.offset(c)
  check(ox ~= 0 or oy ~= 0, "reduce: a live shake wobbles at unity")
  view.cfg.reduce_shake = true
  check(view.shake_scale() == 0.0, "reduce: reduce-shake scale is 0")
  local rx, ry = camera.offset(c)
  check(rx == 0 and ry == 0, "reduce: reduce-shake zeroes camera.offset")
  local ax, ay = camera.apply(c)
  check(ax == c.x and ay == c.y,
        "reduce: apply hands gfx the unshaken camera")
  cm.require("cm.gfx").camera(0, 0) -- leave the render camera as found
  view.cfg.reduce_shake = false
  local bx, by = camera.offset(c)
  check(bx == ox and by == oy,
        "reduce: releasing the toggle restores the exact offset")
  check(c.shake == 7 and c.shake_t0 == 7 and c.shake_mag == 5,
        "reduce: the policy never touches the recorded counters")

  -- tween.wobble: the same door rule for table effects
  local w = {}
  tween.play(w, "shake", 6, 2.4)
  local wx, wy = tween.wobble(w, "shake")
  check(wx ~= 0 or wy ~= 0, "reduce: tween.wobble moves at unity")
  view.cfg.reduce_shake = true
  local zx, zy = tween.wobble(w, "shake")
  check(zx == 0.0 and zy == 0.0, "reduce: reduce-shake zeroes tween.wobble")
  view.cfg.reduce_shake = false

  -- tween.flash: val scaled by the flash policy; val itself NEVER moves
  -- (the purity pin: sim-legal reads cannot depend on live policy)
  tween.play(w, "flash", 14, 0.55)
  tween.tick(w)
  local v = tween.val(w, "flash")
  check(tween.flash(w, "flash") == v,
        "reduce: flash is val at unity")
  view.cfg.reduce_flash = true
  check(view.flash_scale() == 0.25, "reduce: reduce-flash scale is 0.25")
  check(tween.flash(w, "flash") == v * 0.25,
        "reduce: reduce-flash attenuates the flash door")
  check(tween.flash(w, "flash", "cubic_out")
          == tween.val(w, "flash", "cubic_out") * 0.25,
        "reduce: the flash door carries the curve")
  check(tween.val(w, "flash") == v
          and tween.k(w, "flash") == 13 / 14,
        "reduce: val and k stay pure under the policy")
  check(tween.flash(w, "gone") == 0.0, "reduce: idle flash is 0")
  view.cfg.reduce_flash = false

  -- persistence: set_* saves user-wide; only set flags enter the store
  view.set_reduce_shake(true)
  local t = state_m.parse(pal.read_file(root .. "/editor.dat"))
  check(t.reduce_shake == true and t.reduce_flash == nil,
        "reduce: only set flags enter the store")
  view.set_reduce_flash(true)
  view.cfg.reduce_shake, view.cfg.reduce_flash = false, false
  view.load_accessibility()
  check(view.cfg.reduce_shake == true and view.cfg.reduce_flash == true,
        "reduce: stored flags adopt on load")
  view.set_reduce_shake(false)
  view.set_reduce_flash(false)
  t = state_m.parse(pal.read_file(root .. "/editor.dat"))
  check(t.reduce_shake == nil and t.reduce_flash == nil,
        "reduce: clearing a flag leaves the store clean")

  -- a crafted store: only literal true engages (malformed values stay off)
  pal.write_file(root .. "/editor.dat", state_m.canon({
    reduce_shake = "yes", reduce_flash = 1,
  }))
  view.load_accessibility()
  check(view.cfg.reduce_shake == false and view.cfg.reduce_flash == false,
        "reduce: malformed store flags stay off")
  pal.x_remove(root .. "/editor.dat")
  view.load_accessibility()
  check(view.cfg.reduce_shake == false and view.cfg.reduce_flash == false,
        "reduce: a store-less load resets both flags")

  -- leave everything as found
  view._access_path = saved_access
  view.cfg.reduce_shake = saved_cfg.reduce_shake
  view.cfg.reduce_flash = saved_cfg.reduce_flash
  view.cfg.editor_scale = saved_cfg.editor_scale
  view.cfg.chrome_scale = saved_cfg.chrome_scale
  view.cfg.access_auto = saved_cfg.access_auto
  view.access_resolved = saved_cfg.access_resolved
  pal.x_remove(root)
end

-- ---- cm.depth: stable draw-order sorting (A5/D095) ----

local function t_depth()
  local depth = cm.require("cm.depth")

  -- push refusals: key must be a real number, item must exist
  local dl = depth.list()
  check(not pcall(depth.push, dl, "ten", "a"), "depth: string key refused")
  check(not pcall(depth.push, dl, nil, "a"), "depth: nil key refused")
  check(not pcall(depth.push, dl, 0 / 0, "a"), "depth: NaN key refused")
  check(not pcall(depth.push, dl, 5, nil), "depth: nil item refused")
  check(#dl == 0, "depth: refused pushes leave the list empty")

  -- sort orders ascending by key; items pass through untouched
  local pa, pb = { name = "a" }, { name = "b" }
  depth.push(dl, 30, pa)
  depth.push(dl, 10, "tag")
  depth.push(dl, 20, pb)
  depth.sort(dl)
  local got, keys = {}, {}
  for i, item, key in depth.each(dl) do
    got[i], keys[i] = item, key
  end
  check(#got == 3 and got[1] == "tag" and got[2] == pb and got[3] == pa,
        "depth: sort ascends by key, any item type passes through")
  check(keys[1] == 10 and keys[2] == 20 and keys[3] == 30,
        "depth: each reports the keys")
  check(pa.name == "a" and pa.key == nil, "depth: items are not mutated")

  -- ties keep push order: pushed later draws later (on top)
  depth.clear(dl)
  check(#dl == 0, "depth: clear empties for reuse")
  depth.push(dl, 5, "first")
  depth.push(dl, 5, "second")
  depth.push(dl, 3, "under")
  depth.push(dl, 5, "third")
  depth.sort(dl)
  got = {}
  for i, item in depth.each(dl) do got[i] = item end
  check(got[1] == "under" and got[2] == "first" and got[3] == "second"
          and got[4] == "third",
        "depth: equal keys keep push order")
  depth.sort(dl)
  local again = {}
  for i, item in depth.each(dl) do again[i] = item end
  check(again[1] == got[1] and again[2] == got[2] and again[3] == got[3]
          and again[4] == got[4], "depth: re-sort is idempotent")

  -- empty and single-entry lists are fine
  local e = depth.list()
  depth.sort(e)
  local n = 0
  for _ in depth.each(e) do n = n + 1 end
  check(n == 0, "depth: empty list sorts and iterates")
  depth.push(e, 1, "only")
  depth.sort(e)
  check(select(2, depth.each(e)(e, 0)) == "only", "depth: single entry holds")

  -- negative/float keys order by plain numeric comparison
  depth.clear(dl)
  depth.push(dl, 0.5, "b")
  depth.push(dl, -2, "a")
  depth.push(dl, 0.75, "c")
  depth.sort(dl)
  got = {}
  for i, item in depth.each(dl) do got[i] = item end
  check(got[1] == "a" and got[2] == "b" and got[3] == "c",
        "depth: negative and float keys compare plainly")

  -- ysort: stable in-place ascending by field, default "y"
  local i1 = { y = 40, id = 1 }
  local i2 = { y = 12, id = 2 }
  local i3 = { y = 40, id = 3 }
  local i4 = { y = 8, id = 4 }
  local arr = { i1, i2, i3, i4 }
  check(depth.ysort(arr) == arr, "depth: ysort returns the same table")
  check(arr[1] == i4 and arr[2] == i2 and arr[3] == i1 and arr[4] == i3,
        "depth: ysort ascends and equal ys keep array order")
  local custom = { { base = 9 }, { base = 2 }, { base = 5 } }
  depth.ysort(custom, "base")
  check(custom[1].base == 2 and custom[2].base == 5 and custom[3].base == 9,
        "depth: ysort sorts a custom field")
  check(not pcall(depth.ysort, { { y = 1 }, { z = 2 } }),
        "depth: ysort refuses a missing field by index")
  check(not pcall(depth.ysort, { { y = 0 / 0 } }),
        "depth: ysort refuses a NaN field")
  depth.ysort({})
  check(true, "depth: ysort accepts an empty array")
end

-- ---- cm.move: stick+key merge, 8-way vectors (A5/D097) ----

local function t_move()
  local move = cm.require("cm.move")
  local input = cm.require("cm.input")
  local DIAG = 0.70710678

  check(move.DIAG == DIAG, "move: DIAG is the demos' exact literal")

  -- pure math first: face8 signs, keep-old, cardinal zeros
  local fx, fy = move.face8(3.2, -0.5, 9, 9)
  check(fx == 1 and fy == -1, "move: face8 takes per-axis signs")
  fx, fy = move.face8(-0.01, 0, 9, 9)
  check(fx == -1 and fy == 0, "move: face8 zero component gives 0 (cardinal)")
  fx, fy = move.face8(0, 0.7, 9, 9)
  check(fx == 0 and fy == 1, "move: face8 cardinal up")
  fx, fy = move.face8(0, 0, -1, 1)
  check(fx == -1 and fy == 1, "move: face8 zero vector keeps the old facing")
  check(select("#", move.face8(0, 0)) == 2 and move.face8(0, 0) == nil,
        "move: face8 passes absent old facing through untouched")

  -- unit8: diagonals scale by DIAG, cardinals and zero pass through
  local ux, uy = move.unit8(1, 1)
  check(ux == DIAG and uy == DIAG, "move: unit8 scales diagonals by DIAG")
  ux, uy = move.unit8(-1, 1)
  check(ux == -DIAG and uy == DIAG, "move: unit8 keeps signs")
  ux, uy = move.unit8(0, -1)
  check(ux == 0 and uy == -1, "move: unit8 passes cardinals through")
  ux, uy = move.unit8(0, 0)
  check(ux == 0 and uy == 0, "move: unit8 zero stays zero")

  -- readers ride the real recorded input path
  input.map({ { "left", input.key.left }, { "right", input.key.right },
              { "up", input.key.up }, { "down", input.key.down },
              { "walk_l", input.key.a }, { "walk_r", input.key.d } })
  input.pad_reset()
  local function key(sc, down)
    return { type = "key", scancode = sc, down = down, rep = false }
  end

  -- keys: ints, cancellation, custom action names
  input.apply(input.collect({ key(input.key.right, true) }))
  local ix, iy = move.keys()
  check(ix == 1 and iy == 0, "move: keys reads right as +x")
  input.apply(input.collect({ key(input.key.left, true),
                              key(input.key.up, true) }))
  ix, iy = move.keys()
  check(ix == 0 and iy == -1, "move: opposite keys cancel, up is -y")
  input.apply(input.collect({ key(input.key.right, false),
                              key(input.key.up, false),
                              key(input.key.d, true) }))
  ix, iy = move.keys("walk_l", "walk_r", "up", "down")
  check(ix == 1 and iy == 0, "move: keys takes custom action names")
  check(not pcall(move.keys, "nosuch"), "move: keys refuses unmapped actions")
  input.apply(input.collect({ key(input.key.left, false),
                              key(input.key.d, false) }))

  -- dir with no pad and no keys: zero
  local mx, my = move.dir(1)
  check(mx == 0 and my == 0, "move: dir idle is (0, 0)")

  -- dir digital: single axis at unit, diagonal at exactly DIAG
  input.apply(input.collect({ key(input.key.right, true) }))
  mx, my = move.dir(1)
  check(mx == 1 and my == 0, "move: dir digital cardinal is unit")
  input.apply(input.collect({ key(input.key.down, true) }))
  mx, my = move.dir(1)
  check(mx == DIAG and my == DIAG, "move: dir digital diagonal is DIAG exact")

  -- stick: the recorded quantized axis over 127, exact
  input.feed({ { type = "pad", pad = 1, connected = true },
               { type = "padaxis", pad = 1, axis = 0, value = 32767 },
               { type = "padaxis", pad = 1, axis = 1, value = -32768 } })
  input.apply(input.sample())
  local sx, sy = move.stick(1)
  check(sx == 1.0 and sy == -1.0, "move: full stick deflection is exactly 1")
  check(input.pad_axis(1, "lx") / 127 == sx,
        "move: stick is pad_axis over 127, nothing else")

  -- dir: the deflected stick wins over held keys, verbatim analog
  mx, my = move.dir(1)
  check(mx == 1.0 and my == -1.0,
        "move: dir prefers the deflected stick over held keys")

  -- partial deflection stays the exact recorded quantized fraction
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = 20000 },
               { type = "padaxis", pad = 1, axis = 1, value = 0 } })
  input.apply(input.sample())
  local q = input.pad_axis(1, "lx")
  check(q > 0 and q < 127, "move: partial deflection quantizes mid-range")
  sx, sy = move.stick(1)
  check(sx == q / 127 and sy == 0, "move: partial stick is the exact fraction")

  -- right stick reads rx/ry; the left-stick zero falls back to keys
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = 0 },
               { type = "padaxis", pad = 1, axis = 2, value = 32767 },
               { type = "padaxis", pad = 1, axis = 3, value = 32767 } })
  input.apply(input.sample())
  local rx, ry = move.stick(1, "r")
  check(rx == 1.0 and ry == 1.0, "move: side 'r' reads the right stick")
  mx, my = move.dir(1)
  check(mx == DIAG and my == DIAG,
        "move: dir ignores the right stick and falls back to keys")
  check(not pcall(move.stick, 1, "x"), "move: stick refuses a bad side")

  -- the aim chain: right stick wins, else move dir, else old facing
  fx, fy = move.face8(rx, ry, move.face8(mx, my, 9, 9))
  check(fx == 1 and fy == 1, "move: aim chain takes the deflected stick")
  fx, fy = move.face8(0, 0, move.face8(mx, my, 9, 9))
  check(fx == 1 and fy == 1, "move: aim chain falls back to the move dir")
  fx, fy = move.face8(0, 0, move.face8(0, 0, -1, 0))
  check(fx == -1 and fy == 0, "move: aim chain keeps the old facing at rest")

  -- teardown: disconnect through the record so the APPLIED pad state
  -- clears too, then drop the latch
  input.feed({ { type = "pad", pad = 1, connected = false } })
  input.apply(input.sample())
  check(not input.pad_connected(1), "move: teardown disconnects the pad")
  input.apply(input.collect({ key(input.key.right, false),
                              key(input.key.down, false) }))
  input.pad_reset()
  check(#input.sample() == 10, "move: the test leaves the pad domain unlatched")
end

-- ---- cm.hud: anchored HUD text + device-flavored labels (A5/D096) ----

local function t_hud()
  local hud = cm.require("cm.hud")
  local text = cm.require("cm.text")
  local input = cm.require("cm.input")

  -- place: the nine anchors over an explicit box (block 10x8 in 100x60)
  local x, y = hud.place("tl", 4, 3, 10, 8, 100, 60)
  check(x == 4 and y == 3, "hud: tl insets from the top-left")
  x, y = hud.place("t", 0, 3, 10, 8, 100, 60)
  check(x == 45 and y == 3, "hud: t centers horizontally")
  x, y = hud.place("tr", 4, 3, 10, 8, 100, 60)
  check(x == 86 and y == 3, "hud: tr insets from the right edge")
  x, y = hud.place("l", 4, 0, 10, 8, 100, 60)
  check(x == 4 and y == 26, "hud: l centers vertically")
  x, y = hud.place("c", 0, 0, 10, 8, 100, 60)
  check(x == 45 and y == 26, "hud: c centers both axes")
  x, y = hud.place("r", 4, 0, 10, 8, 100, 60)
  check(x == 86 and y == 26, "hud: r rides the right edge midline")
  x, y = hud.place("bl", 4, 3, 10, 8, 100, 60)
  check(x == 4 and y == 49, "hud: bl insets from the bottom-left")
  x, y = hud.place("b", 0, 2, 10, 8, 100, 60)
  check(x == 45 and y == 50, "hud: b centers over the bottom edge")
  x, y = hud.place("br", 4, 3, 10, 8, 100, 60)
  check(x == 86 and y == 49, "hud: br insets from both far edges")

  -- centering floors exactly like the demo's (W - measure) // 2
  x = hud.place("t", 0, 0, 9, 8, 100, 60)
  check(x == 45, "hud: odd centering remainders floor")
  -- centered axes take plain signed shifts
  x, y = hud.place("c", -10, 5, 10, 8, 100, 60)
  check(x == 35 and y == 31, "hud: centered axes take signed shifts")

  -- refusals are loud
  check(not pcall(hud.place, "mid", 0, 0, 10, 8, 100, 60),
        "hud: unknown anchor refused")
  check(not pcall(hud.place, "t", "4", 0, 10, 8, 100, 60),
        "hud: non-number inset refused")
  check(not pcall(hud.text, "t", 0, 0, 42), "hud: non-string text refused")

  -- text: anchored draw is cm.text.draw at place() over measure — the
  -- glyph pixels land exactly where the anchor says (spleen 'A' = 14 lit)
  local W, H = pal.gfx_size()
  pal.begin_frame(0, 0, 0, 1)
  local rx, ry = hud.text("br", 2, 2, "A")
  pal.present()
  check(rx == W - 2 - 5 and ry == H - 2 - 8,
        "hud: text returns the resolved top-left")
  local pix = pal.read_pixels()
  local lit_in, lit_out = 0, 0
  for py = 0, H - 1 do
    for px = 0, W - 1 do
      if pix:byte((py * W + px) * 4 + 1) ~= 0 then
        if px >= rx and px < rx + 5 and py >= ry and py < ry + 8 then
          lit_in = lit_in + 1
        else
          lit_out = lit_out + 1
        end
      end
    end
  end
  check(lit_in == 14 and lit_out == 0,
        "hud: br-anchored glyph lands in its cell (in " .. lit_in
        .. " out " .. lit_out .. ")")

  -- multi-line centered blocks align each line to the anchor's side
  pal.begin_frame(0, 0, 0, 1)
  rx, ry = hud.text("t", 0, 0, "A\nAA")
  pal.present()
  check(rx == (W - 10) // 2 and ry == 0, "hud: multi-line block placement")
  pix = pal.read_pixels()
  lit_in, lit_out = 0, 0
  for py = 0, H - 1 do
    for px = 0, W - 1 do
      if pix:byte((py * W + px) * 4 + 1) ~= 0 then
        local l1 = px >= rx + 2 and px < rx + 7 and py >= 0 and py < 8
        local l2 = px >= rx and px < rx + 10 and py >= 8 and py < 16
        if l1 or l2 then lit_in = lit_in + 1 else lit_out = lit_out + 1 end
      end
    end
  end
  check(lit_in == 42 and lit_out == 0,
        "hud: centered lines each align to the block (in " .. lit_in
        .. " out " .. lit_out .. ")")

  -- label: the pad-else-key flavor dance, live against pad 1 connectivity
  input.map({ { "act", input.key.e, "pad:south" } })
  input.pad_reset()
  check(hud.label("act") == input.label("act", "key"),
        "hud: label speaks keys with no pad")
  input.feed({ { type = "pad", pad = 1, connected = true } })
  input.apply(input.sample())
  check(hud.label("act") == input.label("act", "pad"),
        "hud: label speaks pad while pad 1 is connected")
  check(hud.label("act") ~= input.label("act", "key"),
        "hud: the two flavors actually differ for a dual-bound action")
  input.pad_reset()
  check(#input.sample() == 10, "hud: the label test leaves the pad domain unlatched")
end

-- ---- cm.input: records, edges, snapshot consistency ----

local function t_input()
  local input = cm.require("cm.input")
  input.map({ { "jump", input.key.space, input.key.up },
              { "left", input.key.left }, { "right", input.key.right } })
  check(input.bit_of.jump == 0 and input.bit_of.right == 2,
        "action bits follow definition order")
  input.define("left", { input.key.a }) -- rebind keeps the bit
  check(input.bit_of.left == 1, "rebind keeps bit index")
  local names = input.actions()
  check(names[1] == "jump" and names[2] == "left" and names[3] == "right",
        "actions() in bit order")

  local function key(sc, down)
    return { type = "key", scancode = sc, down = down, rep = false }
  end

  -- held key: bit stays across empty collects
  local rec = input.collect({ key(44, true) })
  check(rec == string.pack("<I4i2i2I1i1", 1, 0, 0, 0, 0), "record layout")
  input.apply(rec)
  check(input.down("jump") and input.pressed("jump"), "press edge")
  rec = input.collect({})
  input.apply(rec)
  check(input.down("jump") and not input.pressed("jump"), "hold, no edge")
  input.apply(input.collect({ key(44, false) }))
  check(not input.down("jump") and input.released("jump"), "release edge")

  -- sticky tap: down+up inside one sample window still lands one frame
  input.apply(input.collect({ key(4, true), key(4, false) }))
  check(input.down("left") and input.pressed("left"), "sub-frame tap caught")
  input.apply(input.collect({}))
  check(input.released("left"), "tap releases next frame")

  -- feed/sample split: events ingested on ticks that run NO sim step (render
  -- loop faster than the 60 Hz sim) must not be dropped — the windowed
  -- key-stick regression. feed() updates live state every tick; sample()
  -- builds a record per step.
  input.feed({ key(4, true) })  -- tick A (no step): press
  input.feed({})                 -- tick B (no step): idle
  input.feed({ key(4, false) })  -- tick C (no step): release
  input.apply(input.sample())    -- first step since: the tap is not lost
  check(input.down("left") and input.pressed("left"),
        "tap across zero-step ticks survives to the next sample")
  input.apply(input.sample())
  check(input.released("left"), "that tap releases on the following sample")
  -- a genuinely held key over many fast no-step ticks stays held, releases clean
  input.feed({ key(4, true) })
  input.feed({}); input.feed({}); input.feed({})
  input.apply(input.sample())
  check(input.down("left"), "held key survives fast no-step ticks")
  input.feed({ key(4, false) })
  input.apply(input.sample())
  check(not input.down("left") and input.released("left"), "held key releases")

  -- mouse + buttons + wheel
  input.apply(input.collect({
    { type = "motion", x = 12.7, y = -3.2 },
    { type = "button", button = 1, down = true, x = 12.7, y = -3.2 },
    { type = "wheel", dx = 0, dy = 1.5 },
  }))
  local mx, my = input.mouse()
  check(mx == 12 and my == -4, "mouse floored to ints")
  check(input.button_down(1) and input.button_pressed(1), "button edge")
  check(input.wheel() == 1, "wheel integer step")
  input.apply(input.collect({ { type = "wheel", dx = 0, dy = 0.5 } }))
  check(input.wheel() == 1, "wheel fractional carry completes")
  input.apply(input.collect({}))
  check(input.wheel() == 0, "wheel resets without events")

  -- snapshot must capture the cur/prev pair so edges replay identically
  input.apply(input.collect({ key(79, true) })) -- right: pressed edge NOW
  check(input.pressed("right"), "pre-snapshot press edge")
  local snap = state.snapshot()
  input.apply(input.collect({})) -- edge ages into a hold
  check(not input.pressed("right"), "edge aged")
  state.restore(snap)
  cm.adopt_disk()
  check(input.pressed("right"), "press edge restored from snapshot")
  input.apply(input.collect({ key(79, false) }))
end

-- ---- cm.input record v2 (D082): pad extension codec, quantization ----

local function t_input_pad()
  local input = cm.require("cm.input")
  local v1z = string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0)

  -- axis quantization: integer-exact, deadzone-inclusive, full-range ends
  check(input.quantize_axis(0) == 0 and input.quantize_axis(8000) == 0
        and input.quantize_axis(-8000) == 0 and input.quantize_axis(8001) == 0,
        "pad: deadzone collapses to zero inclusively")
  check(input.quantize_axis(32767) == 127 and input.quantize_axis(-32767) == -127
        and input.quantize_axis(-32768) == -127,
        "pad: extremes reach exactly +-127")
  check(input.quantize_axis(20000) == 61, "pad: quantize interior vector")
  check(input.quantize_axis(16384, 0) == 63 and input.quantize_axis(100, 0) == 0
        and input.quantize_axis(32767, 0) == 127,
        "pad: explicit deadzone override")
  local prev = 0
  local mono = true
  for v = 0, 32767, 37 do
    local q = input.quantize_axis(v)
    if q < prev or q < 0 or q > 127 or input.quantize_axis(-v) ~= -q then
      mono = false
      break
    end
    prev = q
  end
  check(mono, "pad: quantization is monotonic and symmetric")

  -- before any pad activity the sampler is pure v1 (10 bytes exactly)
  check(#input.sample() == 10, "pad: dormant domain samples bare v1 records")

  -- virgin readers are neutral and never error; reading latches the domain
  check(not input.pad_connected(1) and not input.pad_down(1, "south")
        and not input.pad_pressed(2, input.pad_btn.start)
        and input.pad_axis(1, "lx") == 0 and input.pad_axis(4, 5) == 0,
        "pad: virgin readers answer neutral")
  local rec = input.sample()
  check(rec:sub(11) == string.pack("<I1I1I1", 1, 1, 0),
        "pad: latched empty domain emits the n=0 extension")
  input.apply(rec) -- an n=0 chunk applies cleanly

  -- connect pad 1: canonical single-entry record
  input.feed({ { type = "pad", pad = 1, connected = true } })
  rec = input.sample()
  check(rec:sub(11) == string.pack("<I1I1I1I1I4i1i1i1i1i1i1",
                                   1, 12, 1, 0, 0, 0, 0, 0, 0, 0, 0),
        "pad: connected idle pad encodes canonically")
  input.apply(rec)
  check(input.pad_connected(1) and not input.pad_connected(2),
        "pad: entry presence is the connected flag")

  -- button edges through feed/sample/apply
  input.feed({ { type = "padbtn", pad = 1, button = input.pad_btn.south,
                 down = true } })
  input.apply(input.sample())
  check(input.pad_down(1, "south") and input.pad_pressed(1, "south"),
        "pad: press edge")
  input.apply(input.sample())
  check(input.pad_down(1, "south") and not input.pad_pressed(1, "south"),
        "pad: hold has no edge")
  input.feed({ { type = "padbtn", pad = 1, button = 0, down = false } })
  input.apply(input.sample())
  check(not input.pad_down(1, "south") and input.pad_released(1, "south"),
        "pad: release edge")

  -- sticky tap: down+up inside one sample window lands exactly one record
  input.feed({ { type = "padbtn", pad = 1, button = 1, down = true },
               { type = "padbtn", pad = 1, button = 1, down = false } })
  input.apply(input.sample())
  check(input.pad_down(1, "east") and input.pad_pressed(1, "east"),
        "pad: sub-frame tap caught")
  input.apply(input.sample())
  check(input.pad_released(1, "east"), "pad: tap releases next record")

  -- axes: deadzone at sampling, name/number access agree
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = 32767 },
               { type = "padaxis", pad = 1, axis = 1, value = -32768 },
               { type = "padaxis", pad = 1, axis = 4, value = 4000 } })
  input.apply(input.sample())
  check(input.pad_axis(1, "lx") == 127 and input.pad_axis(1, 0) == 127,
        "pad: full deflection reads 127 by name and number")
  check(input.pad_axis(1, "ly") == -127, "pad: negative full deflection")
  check(input.pad_axis(1, "lt") == 0, "pad: sub-deadzone trigger is zero")

  -- second pad: ascending canonical slots, independent state
  input.feed({ { type = "pad", pad = 3, connected = true },
               { type = "padbtn", pad = 3, button = 6, down = true } })
  rec = input.sample()
  check(#rec == 10 + 2 + 1 + 22 and rec:byte(13) == 2
        and rec:byte(14) == 0 and rec:byte(25) == 2,
        "pad: two pads encode ascending by slot")
  input.apply(rec)
  check(input.pad_connected(1) and input.pad_connected(3)
        and not input.pad_connected(2) and input.pad_down(3, "start")
        and not input.pad_down(1, "start"),
        "pad: slots carry independent state")

  -- disconnect with a button held: the vanished entry releases everything
  input.feed({ { type = "padbtn", pad = 1, button = 2, down = true } })
  input.apply(input.sample())
  check(input.pad_down(1, "west"), "pad: held before disconnect")
  input.feed({ { type = "pad", pad = 1, connected = false } })
  input.apply(input.sample())
  check(not input.pad_connected(1) and input.pad_released(1, "west")
        and input.pad_axis(1, "lx") == 0 and input.pad_connected(3),
        "pad: disconnect neutralizes with release edges")

  -- after the last disconnect the extension persists as n=0
  input.feed({ { type = "pad", pad = 3, connected = false } })
  input.apply(input.sample())
  check(not input.pad_connected(3), "pad: last disconnect applies")
  rec = input.sample()
  check(rec:sub(11) == string.pack("<I1I1I1", 1, 1, 0),
        "pad: extension keeps coming after the last disconnect")

  -- v1 record purity: a bare 10-byte record leaves pad state untouched
  input.feed({ { type = "pad", pad = 2, connected = true },
               { type = "padbtn", pad = 2, button = 0, down = true } })
  input.apply(input.sample())
  check(input.pad_pressed(2, "south"), "pad: press before the v1 record")
  input.apply(v1z)
  check(input.pad_pressed(2, "south"),
        "pad: a bare v1 record leaves pad state (and its edges) untouched")

  -- unknown extension tags are skipped without touching pad state
  input.apply(v1z .. string.pack("<I1I1", 7, 3) .. "abc")
  check(input.pad_connected(2) and input.pad_down(2, "south"),
        "pad: unknown-tag record applies and touches no pad state")

  -- malformed records error loudly
  check(not pcall(input.apply, "short"), "pad: short record rejected")
  check(not pcall(input.apply, v1z .. "\1"),
        "pad: truncated extension header rejected")
  check(not pcall(input.apply, v1z .. string.pack("<I1I1", 1, 20) .. "xx"),
        "pad: extension past the record end rejected")
  local n0 = string.pack("<I1I1I1", 1, 1, 0)
  check(not pcall(input.apply, v1z .. n0 .. n0),
        "pad: duplicate pad extension rejected")
  check(not pcall(input.apply, v1z .. string.pack("<I1I1I1", 1, 1, 5)),
        "pad: pad count above four rejected")
  check(not pcall(input.apply, v1z .. string.pack("<I1I1I1", 1, 12, 2)
                  .. string.rep("\0", 11)),
        "pad: count/length mismatch rejected")
  local e_slot0 = string.pack("<I1I4i1i1i1i1i1i1", 0, 0, 0, 0, 0, 0, 0, 0)
  local e_slot2 = string.pack("<I1I4i1i1i1i1i1i1", 2, 0, 0, 0, 0, 0, 0, 0)
  local e_slot4 = string.pack("<I1I4i1i1i1i1i1i1", 4, 0, 0, 0, 0, 0, 0, 0)
  check(not pcall(input.apply, v1z .. string.pack("<I1I1I1", 1, 23, 2)
                  .. e_slot2 .. e_slot0),
        "pad: unsorted slots rejected")
  check(not pcall(input.apply, v1z .. string.pack("<I1I1I1", 1, 23, 2)
                  .. e_slot0 .. e_slot0),
        "pad: duplicate slot rejected")
  check(not pcall(input.apply, v1z .. string.pack("<I1I1I1", 1, 12, 1)
                  .. e_slot4),
        "pad: out-of-range slot rejected")

  -- snapshot consistency: edges replay identically after restore
  input.feed({ { type = "padbtn", pad = 2, button = 10, down = true } })
  input.apply(input.sample())
  check(input.pad_pressed(2, "rshoulder"), "pad: pre-snapshot press edge")
  local snap = state.snapshot()
  input.apply(input.sample())
  check(not input.pad_pressed(2, "rshoulder"), "pad: edge aged")
  state.restore(snap)
  cm.adopt_disk()
  check(input.pad_pressed(2, "rshoulder"),
        "pad: press edge restored from snapshot")

  -- reader argument validation
  check(not pcall(input.pad_down, 0, 0) and not pcall(input.pad_down, 5, 0),
        "pad: pad number out of range rejected")
  check(not pcall(input.pad_down, 1, "warp") and
        not pcall(input.pad_down, 1, 32),
        "pad: unknown button rejected")
  check(not pcall(input.pad_axis, 1, "throttle")
        and not pcall(input.pad_axis, 1, 6),
        "pad: unknown axis rejected")

  -- live reset: the domain unlatches and the sampler is v1-pure again,
  -- leaving later tests (and a fresh project boot) byte-identical to v1
  input.pad_reset()
  check(#input.sample() == 10, "pad: reset returns the sampler to bare v1")
end

-- ---- gamepad discovery (A4/D083): device->slot policy + the SDL path ----

local function t_input_gpad()
  local input = cm.require("cm.input")
  input.pad_reset()

  -- first-connected claims the lowest free slot
  input.feed({ { type = "gpad", id = 101, connected = true },
               { type = "gpad", id = 102, connected = true } })
  input.apply(input.sample())
  check(input.pad_connected(1) and input.pad_connected(2)
        and not input.pad_connected(3),
        "gpad: first-connected devices claim slots 1 then 2")

  -- device events route through the id->slot assignment
  input.feed({ { type = "gpadbtn", id = 102, button = 0, down = true },
               { type = "gpadaxis", id = 101, axis = 0, value = 32767 } })
  input.apply(input.sample())
  check(input.pad_down(2, "south") and not input.pad_down(1, "south"),
        "gpad: buttons route by device id")
  check(input.pad_axis(1, "lx") == 127 and input.pad_axis(2, "lx") == 0,
        "gpad: axes route by device id")

  -- events for a device that never got a slot are dropped
  input.feed({ { type = "gpadbtn", id = 999, button = 1, down = true } })
  input.apply(input.sample())
  check(not input.pad_down(1, "east") and not input.pad_down(2, "east"),
        "gpad: unassigned device events drop")

  -- disconnect frees the slot; the next device claims the lowest free one
  input.feed({ { type = "gpad", id = 101, connected = false } })
  input.apply(input.sample())
  check(not input.pad_connected(1) and input.pad_connected(2),
        "gpad: disconnect frees exactly its slot")
  input.feed({ { type = "gpad", id = 103, connected = true } })
  input.apply(input.sample())
  check(input.pad_connected(1),
        "gpad: a later device claims the lowest free slot")

  -- a fifth device is ignored (all slots taken) and its events leak nowhere
  input.feed({ { type = "gpad", id = 104, connected = true },
               { type = "gpad", id = 105, connected = true },
               { type = "gpad", id = 106, connected = true },
               { type = "gpadbtn", id = 106, button = 3, down = true } })
  input.apply(input.sample())
  check(input.pad_connected(3) and input.pad_connected(4),
        "gpad: four devices fill the four slots")
  check(not (input.pad_down(1, "north") or input.pad_down(2, "north")
             or input.pad_down(3, "north") or input.pad_down(4, "north")),
        "gpad: a fifth device is ignored while slots are full")

  -- reconnect of a still-registered id resets its slot in place
  input.feed({ { type = "gpadbtn", id = 103, button = 2, down = true } })
  input.feed({ { type = "gpad", id = 103, connected = true } })
  input.apply(input.sample())
  check(input.pad_connected(1) and not input.pad_down(1, "west"),
        "gpad: reconnect resets its slot in place")

  -- neutralize (editor focus loss): axes zero, buttons/connectivity stay
  input.feed({ { type = "gpadaxis", id = 103, axis = 1, value = -32768 },
               { type = "gpadbtn", id = 103, button = 9, down = true } })
  input.pad_neutralize()
  input.apply(input.sample())
  check(input.pad_axis(1, "ly") == 0 and input.pad_down(1, "lshoulder")
        and input.pad_connected(1),
        "gpad: neutralize zeroes axes only")

  -- leave the applied pad state neutral for the rest of the suite (the
  -- starter templates poll pad 1 now): disconnect everything, roll two
  -- records through for the release edges, then unlatch
  input.feed({ { type = "gpad", id = 102, connected = false },
               { type = "gpad", id = 103, connected = false },
               { type = "gpad", id = 104, connected = false },
               { type = "gpad", id = 105, connected = false } })
  input.apply(input.sample())
  input.apply(input.sample())
  input.pad_reset()
  check(#input.sample() == 10, "gpad: reset unlatches the domain")

  -- ---- the real SDL path: a virtual pad rides the exact pipeline a
  -- physical controller does (attach -> PAL open -> poll_events -> feed).
  -- Skipped loudly where the host cannot init the SDL gamepad subsystem.
  local vid = pal.x_pad_virtual()
  if not vid then
    pal.log("[selftest] virtual gamepads unavailable; skipping SDL KATs")
    return
  end
  local function pump_feed()
    pal.x_events_pump()
    local evs = pal.poll_events()
    input.feed(evs)
    return evs
  end
  local saw
  for _, e in ipairs(pump_feed()) do
    if e.type == "gpad" and e.id == vid and e.connected then saw = true end
  end
  check(saw, "gpad/sdl: attach arrives as a connected gpad event")
  local listed
  for _, p in ipairs(pal.pad_list()) do
    if p.id == vid then listed = type(p.name) == "string" end
  end
  check(listed, "gpad/sdl: pad_list names the attached pad")
  input.apply(input.sample())
  check(input.pad_connected(1), "gpad/sdl: the attached pad claimed slot 1")

  pal.x_pad_virtual_button(vid, input.pad_btn.south, true)
  pal.x_pad_virtual_axis(vid, input.pad_ax.rt, 32767)
  pump_feed()
  input.apply(input.sample())
  check(input.pad_pressed(1, "south"),
        "gpad/sdl: a virtual button press reads back by SDL number")
  check(input.pad_axis(1, "rt") == 127,
        "gpad/sdl: a virtual axis reads back quantized")

  pal.x_pad_virtual_button(vid, input.pad_btn.south, false)
  pump_feed()
  input.apply(input.sample())
  check(input.pad_released(1, "south"), "gpad/sdl: the release edge lands")

  -- pad_sync (the project-boot path) adopts what is connected right now
  input.pad_reset()
  input.pad_sync()
  input.apply(input.sample())
  check(input.pad_connected(1), "gpad/sdl: pad_sync adopts the live pad")

  check(pal.x_pad_virtual_remove(vid) == true, "gpad/sdl: detach accepted")
  pump_feed()
  input.apply(input.sample())
  check(not input.pad_connected(1), "gpad/sdl: detach lands as a disconnect")

  -- back to byte-identical v1 for the rest of the suite
  input.apply(input.sample())
  input.pad_reset()
  check(#input.sample() == 10, "gpad/sdl: the suite leaves the domain unlatched")
end

-- ---- cm.text: glyph pixels land exactly in their cell ----

local function t_text()
  local text = cm.require("cm.text")
  pal.begin_frame(0, 0, 0, 1)
  text.draw(3, 5, "A")
  pal.present()
  local pix = pal.read_pixels()
  local white_in, white_out = 0, 0
  for y = 0, 63 do
    for x = 0, 63 do
      local r = pix:byte((y * 64 + x) * 4 + 1)
      if r ~= 0 then
        local inbox = x >= 3 and x < 8 and y >= 5 and y < 13
        if inbox then white_in = white_in + 1 else white_out = white_out + 1 end
      end
    end
  end
  -- spleen 'A' = rows 60,90,90,F0,90,90 -> 14 lit pixels
  check(white_in == 14, "glyph pixel count (got " .. white_in .. ")")
  check(white_out == 0, "no pixels outside the glyph cell (got " .. white_out .. ")")
  local w, h = text.measure("ab\ncdef")
  check(w == 20 and h == 16, "measure multi-line")
end

-- ---- cm.repl: exec semantics (the deterministic console path, D022) ----

local function t_repl()
  local repl = cm.require("cm.repl")

  local function tail_after(fn)
    local before = pal.log_lines(0)
    local last = #before > 0 and before[#before].seq or 0
    fn()
    local lines = {}
    for _, l in ipairs(pal.log_lines(last)) do lines[#lines + 1] = l.text end
    return lines
  end

  -- expression: echo + result
  local out = tail_after(function() check(repl.exec("1+1"), "repl: expr ok") end)
  check(out[1] == "> 1+1" and out[2] == "= 2",
        "repl: expr echo ('" .. tostring(out[1]) .. "', '"
        .. tostring(out[2]) .. "')")
  -- multiple returns
  out = tail_after(function() repl.exec("1, 'a'") end)
  check(out[2] == "= 1, a", "repl: multi-return echo")
  -- statement: no result line
  out = tail_after(function()
    check(repl.exec("cm.state.doc.t_repl = 7"), "repl: statement ok")
  end)
  check(#out == 1, "repl: statement has no = line")
  check(state.doc.t_repl == 7, "repl: statement hit the doc tree")
  -- env sugar reads + protected writes
  check(repl.exec("doc.t_repl = doc.t_repl + 1") and state.doc.t_repl == 8,
        "repl: doc sugar")
  repl.exec("state = 5") -- bare assignment lands in env, not _G
  check(_G.state == nil and repl.env.state == 5, "repl: env shields globals")
  repl.env.state = nil
  state.doc.t_repl = nil
  -- errors caught, logged, survivable
  out = tail_after(function()
    check(not repl.exec("error('x')"), "repl: runtime error returns false")
  end)
  check(out[2] and out[2]:find("^! "), "repl: error echoed")
  check(not repl.exec("syntax ]]"), "repl: syntax error returns false")
  -- queue order + drain
  repl.queue = {}
  repl.submit("cm.state.doc.t_q = 'a'")
  repl.submit("cm.state.doc.t_q = cm.state.doc.t_q .. 'b'")
  check(#repl.queue == 2, "repl: submits queue")
  local drained = repl.drain()
  check(#drained == 2 and #repl.queue == 0, "repl: drain empties queue")
  check(state.doc.t_q == "ab", "repl: drain executes in order")
  check(repl.drain() == nil, "repl: idle drain is nil")
  state.doc.t_q = nil
  check(repl.history[#repl.history]:find("t_q"), "repl: history records")
end

-- ---- cm.ui: interaction logic via synthetic events (headless-safe; the
-- 64x64 gfx target is live, so widgets really draw — logic is what we
-- assert, pixels are the glyph test's job) ----

local function t_ui()
  local ui = cm.require("cm.ui")
  ui.s = {} -- isolate from any earlier state
  ui.focus, ui.hot, ui.active = nil, nil, nil
  ui.cap_mouse, ui.cap_keys = false, false

  local function mo(x, y) return { type = "motion", x = x, y = y } end
  local function bd(x, y) return { type = "button", button = 1, down = true, x = x, y = y } end
  local function bu(x, y) return { type = "button", button = 1, down = false, x = x, y = y } end
  local function kd(sc) return { type = "key", scancode = sc, down = true, rep = false } end
  local function ku(sc) return { type = "key", scancode = sc, down = false, rep = false } end
  local function tx(s) return { type = "text", text = s } end

  -- one ui pass: ingest events, run body inside a standard panel, finish.
  -- Returns the events that would have reached the game, plus body results.
  local got
  local function pass(events, body)
    local out = ui.frame(events)
    pal.begin_frame(0, 0, 0, 1)
    got = {}
    ui.begin_panel("t", 2, 2, 60, 58)
    body()
    ui.end_panel()
    ui.frame_end()
    return out
  end

  -- button: hover (frame 1) -> press (2) -> release (3) = one click
  local function button_body()
    got.clicked = ui.button("go")
  end
  pass({ mo(20, 10) }, button_body) -- panel pad 4: button strip y 6..16
  check(not got.clicked, "ui: no click on hover")
  check(ui.capturing_mouse(), "ui: mouse over panel captures")
  local out = pass({ bd(20, 10) }, button_body)
  check(not got.clicked, "ui: no click on press")
  check(#out == 0, "ui: captured press never reaches the game")
  pass({ bu(20, 10) }, button_body)
  check(got.clicked, "ui: click on release while hot")
  pass({}, button_body)
  check(not got.clicked, "ui: click is an edge")

  -- release outside = no click
  pass({ mo(20, 10) }, button_body)
  pass({ bd(20, 10) }, button_body)
  pass({ mo(200, 200), bu(200, 200) }, button_body)
  check(not got.clicked, "ui: release outside cancels")

  -- checkbox toggles on click
  local cb = false
  local function cb_body()
    local changed
    cb, changed = ui.checkbox("opt", cb)
    got.changed = changed
  end
  pass({ mo(20, 10) }, cb_body)
  pass({ bd(20, 10) }, cb_body)
  pass({ bu(20, 10) }, cb_body)
  check(cb == true and got.changed, "ui: checkbox toggled")

  -- slider: press at track left = min, drag to track right = max
  -- (panel content x=6 w=52; label 45% = 23px -> track x=29 w=29)
  local sv = 50
  local function sl_body()
    sv = ui.slider("s", sv, 0, 100)
  end
  pass({ mo(40, 10) }, sl_body)
  pass({ bd(31, 10) }, sl_body)
  check(sv == 0, "ui: slider hits min (got " .. sv .. ")")
  pass({ mo(56, 10) }, sl_body)
  check(sv == 100, "ui: slider drag to max (got " .. sv .. ")")
  pass({ bu(56, 10) }, sl_body)

  -- explicit-rect placement (virtualized rows): drags without a layout
  -- slot and never advances the panel cursor
  local nv, cy0, cy1 = 5
  local function rect_body()
    cy0 = ui.cursor_y()
    nv = ui.number("n", nv, { rect = { 6, 40, 50, 10 }, speed = 1 })
    cy1 = ui.cursor_y()
  end
  pass({ mo(30, 44) }, rect_body) -- label 45% of 50 = 22px -> track x 28..56
  pass({ bd(30, 44) }, rect_body)
  pass({ mo(40, 44) }, rect_body)
  check(nv == 15, "ui: rect-placed number drags (got " .. nv .. ")")
  check(cy0 == cy1, "ui: rect placement leaves the layout cursor alone")
  pass({ bu(40, 44) }, rect_body)

  -- text input: click focuses, text inserts, editing keys work
  local tv, sub = "", false
  local function ti_body()
    local s
    tv, _, s = ui.text_input("in", tv)
    sub = s
  end
  pass({ mo(20, 10) }, ti_body)
  check(not ui.capturing_keys(), "ui: no key capture unfocused")
  pass({ bd(20, 10), bu(20, 10) }, ti_body)
  check(ui.capturing_keys(), "ui: focus captures keys")
  out = pass({ tx("hey") }, ti_body)
  check(tv == "hey", "ui: text inserted (got '" .. tv .. "')")
  check(#out == 0, "ui: text events never reach the game")
  out = pass({ kd(42) }, ti_body) -- backspace
  check(tv == "he", "ui: backspace")
  check(#out == 0, "ui: focused keydown captured")
  out = pass({ ku(42) }, ti_body)
  check(#out == 1, "ui: keyup always passes (no stuck keys)")
  pass({ kd(74) }, ti_body) -- home
  pass({ tx("t") }, ti_body)
  check(tv == "the", "ui: insert at cursor after home")
  pass({ kd(77) }, ti_body) -- end
  pass({ kd(40) }, ti_body) -- return
  check(sub, "ui: enter submits")
  check(not ui.capturing_keys(), "ui: enter blurs without keep_focus")

  -- utf-8: a 2-byte char is one backspace
  pass({ mo(20, 10) }, ti_body)
  pass({ bd(20, 10), bu(20, 10) }, ti_body) -- refocus (cursor from click x)
  pass({ kd(77) }, ti_body) -- end
  pass({ tx("\xc3\xa9") }, ti_body) -- é
  check(tv == "the\xc3\xa9", "ui: utf-8 inserted")
  pass({ kd(42) }, ti_body)
  check(tv == "the", "ui: backspace removes whole utf-8 char")
  pass({ kd(41) }, ti_body) -- escape blurs
  check(not ui.capturing_keys(), "ui: escape blurs")

  -- on_key replacement adoption + sticky take_focus
  local tv2 = ""
  local function ti2_body()
    tv2 = ui.text_input("in2", tv2, {
      take_focus = true,
      on_key = function(sc, cur)
        if sc == 82 then return "swapped:" .. cur end
      end,
    })
  end
  pass({}, ti2_body) -- grabs the free keyboard
  check(ui.capturing_keys(), "ui: take_focus grabs free keyboard")
  pass({ tx("ab") }, ti2_body)
  pass({ kd(82) }, ti2_body)
  check(tv2 == "swapped:ab", "ui: on_key replacement adopted ('" .. tv2 .. "')")
  pass({ bd(20, 40), bu(20, 40) }, ti2_body) -- click far from the field
  check(ui.capturing_keys(), "ui: sticky focus survives outside click")
  ui.blur()

  -- scroll region + virtualized list
  local calls, first_row
  local function sc_body()
    ui.begin_scroll("log", 22)
    calls, first_row = 0, nil
    ui.list(10, 8, function(i) calls = calls + 1; first_row = first_row or i end)
    ui.end_scroll()
    got.scroll = ui.scroll_get("log")
    got.at_bottom = ui.scroll_at_bottom("log", 22)
  end
  pass({}, sc_body)
  check(calls == 3 and first_row == 1, "ui: list draws visible rows only ("
        .. calls .. " from " .. tostring(first_row) .. ")")
  check(got.at_bottom == false, "ui: not at bottom at scroll 0")
  pass({ mo(20, 12) }, sc_body) -- mouse into region (y 6..28)
  pass({ { type = "wheel", dy = -1 } }, sc_body)
  check(got.scroll > 0 and got.scroll < 33,
        "ui: wheel glides, not jumps (got " .. got.scroll .. ")")
  for _ = 1, 60 do pass({}, sc_body) end -- let the inertia run out
  check(got.scroll == 33, "ui: one notch settles at 3 rows (got "
        .. got.scroll .. ")")
  check(first_row == 5, "ui: list window follows scroll (first "
        .. tostring(first_row) .. ")")

  -- wheel up at the top rubber-bands: overshoots negative, returns to 0
  pass({}, function()
    ui.scroll_set("log", 0)
    sc_body()
  end)
  pass({ { type = "wheel", dy = 1 } }, sc_body)
  pass({}, sc_body)
  check(got.scroll < 0, "ui: edge overshoot goes out of bounds (got "
        .. got.scroll .. ")")
  for _ = 1, 60 do pass({}, sc_body) end
  check(got.scroll == 0, "ui: rubber band returns to the edge (got "
        .. got.scroll .. ")")

  -- the style.scroll feel knobs: inertia off = classic instant jump,
  -- elastic off = hard edges (no overshoot)
  ui.style.scroll.inertia = false
  pass({ { type = "wheel", dy = -1 } }, sc_body)
  check(got.scroll == 33, "ui: inertia off jumps 3 rows (got "
        .. got.scroll .. ")")
  ui.style.scroll.elastic = false
  pass({ { type = "wheel", dy = 1 } }, sc_body) -- back to the top...
  pass({ { type = "wheel", dy = 1 } }, sc_body) -- ...and into the edge
  check(got.scroll == 0, "ui: elastic off clamps dead at the edge (got "
        .. got.scroll .. ")")
  ui.style.scroll.inertia, ui.style.scroll.elastic = true, true

  -- orphaned focus: chrome closes around a focused field — the keyboard
  -- must go back to the game (the editor-swap stuck-keys bug)
  local function ti3_body()
    ui.text_input("in3", "abc")
  end
  pass({ mo(20, 10) }, ti3_body)
  pass({ bd(20, 10), bu(20, 10) }, ti3_body)
  check(ui.capturing_keys(), "ui: field focused before its chrome closes")
  pass({}, function() end) -- field not drawn; this frame is still captured
  out = pass({ kd(4) }, function() end)
  check(not ui.capturing_keys(), "ui: orphaned focus released")
  check(#out == 1, "ui: key-down reaches the game after the release")
  local function sc_bottom()
    ui.scroll_to_bottom("log")
    sc_body()
  end
  pass({}, sc_bottom)
  pass({}, sc_body)
  check(got.scroll == 58, "ui: scroll_to_bottom clamps to max (got "
        .. got.scroll .. ")")
  check(got.at_bottom == true, "ui: at_bottom after scroll_to_bottom")

  -- row layout: two columns side by side, full width consumed
  local r1, r2
  pass({}, function()
    ui.row({ 1, 1 })
    r1 = ui.label("a")
    r2 = ui.label("b")
  end)
  check(r1.y == r2.y, "ui: row columns share a baseline")
  check(r2.x > r1.x and r1.x + r1.w <= r2.x, "ui: columns don't overlap")
  check(r2.x + r2.w == 6 + 52, "ui: last column reaches the edge")

  -- heading: collapsible + persistent + id-scoped
  local open_a, x_in, x_out
  pass({}, function()
    ui.push_id("A")
    open_a = ui.heading("sec")
    x_in = ui.label("c").x
    if open_a then ui.heading_end() end
    x_out = ui.label("d").x
    ui.pop_id()
  end)
  check(open_a == true, "ui: heading open by default")
  check(x_in == 6 + 8 and x_out == 6, "ui: heading indents its content")
  -- click it shut (heading strip is the first row: y 6..17)
  local function hb()
    ui.push_id("A")
    open_a = ui.heading("sec")
    if open_a then ui.heading_end() end
    ui.pop_id()
    ui.push_id("B")
    got.open_b = ui.heading("sec")
    if got.open_b then ui.heading_end() end
    ui.pop_id()
  end
  pass({ mo(20, 10) }, hb)
  pass({ bd(20, 10) }, hb)
  pass({ bu(20, 10) }, hb)
  check(open_a == false, "ui: heading toggles closed")
  check(got.open_b == true, "ui: same label, different id scope")

  -- blur leftover focus state for later tests
  ui.blur()
  pass({}, function() end)
  check(not ui.capturing_keys(), "ui: no key capture after blur")
  check(ui.active == nil, "ui: nothing active at rest")
end

-- ---- cm.console: toggle/error logic (drawing exercised, not asserted) ----

local function t_console()
  local ui = cm.require("cm.ui")
  local con = cm.require("cm.console")
  local function kd(sc) return { type = "key", scancode = sc, down = true, rep = false } end
  local function pass(events)
    ui.frame(events)
    pal.begin_frame(0, 0, 0, 1)
    con.frame()
    ui.frame_end()
  end

  con.toggle(false)
  con.clear_error()
  pass({})
  local was_open = con.open
  check(was_open == false, "console: starts closed")
  pass({ kd(53) }) -- grave
  check(con.open == true, "console: grave opens")
  for _ = 1, 15 do pass({}) end -- let it slide fully open
  check(con.slide == 1.0, "console: slide reaches 1")
  check(ui.capturing_keys(), "console: open console owns the keyboard")
  pass({ kd(41) }) -- escape
  check(con.open == false, "console: escape closes")

  con.notify_error("boom at line 3")
  check(con.open and con.paused, "console: error opens + pauses")
  pass({ kd(41) })
  check(con.open == true, "console: escape can't dismiss an error")
  con.clear_error()
  check(not con.paused, "console: clear_error unpauses")

  -- history: up/up/down/down ends back on the live line (regression:
  -- human-found — the console used to clobber on_key's replacement text)
  local repl = cm.require("cm.repl")
  con.toggle(true)
  for _ = 1, 15 do pass({}) end -- open + focused via take_focus
  repl.submit("cmd_one()")
  repl.submit("cmd_two()")
  repl.queue = {} -- history fodder only; nothing should execute
  pass({ kd(82) }) -- up
  check(con.input_text == "cmd_two()",
        "console: up recalls last ('" .. con.input_text .. "')")
  pass({ kd(82) })
  check(con.input_text == "cmd_one()", "console: up walks older")
  pass({ kd(81) }) -- down
  check(con.input_text == "cmd_two()", "console: down walks newer")
  pass({ kd(81) })
  check(con.input_text == "", "console: down past end restores live line")

  -- autoscroll: new lines land with the view pinned at the bottom
  -- (regression: human-found — want-bottom used to hit a phantom id when
  -- requested inside the region's own scope)
  for i = 1, 40 do pal.log("spamline " .. i) end
  pass({})
  local s = ui.s["console/log"]
  check(s and s.content_h and s.view_h and s.content_h > s.view_h,
        "console: scrollback overflows the region")
  check(s.scroll == s.content_h - s.view_h and s.scroll > 0,
        "console: autoscrolled to newest (scroll=" .. tostring(s.scroll)
        .. " content=" .. tostring(s.content_h) .. ")")

  con.toggle(false)
  for _ = 1, 15 do pass({}) end -- slide shut; release the keyboard
  ui.blur()
end

-- ---- cm.collide (R8a): the mover contract, slopes, queries ----

local function t_collide()
  local collide = cm.require("cm.collide")

  -- A) the old t_tilemap room as chains; the mover contract assertions
  -- (TM:move's, kept verbatim when the tilemap mover died at R8e).
  local wd = collide.build{ name = "selftest.col", w = 192, h = 128,
    colliders = {
      { kind = "chain", verts = { 0, 112, 192, 112 } },  -- floor line
      { kind = "chain", closed = true,                   -- wall column
        verts = { 96, 64, 112, 64, 112, 112, 96, 112 } },
      { kind = "chain", oneway = true, verts = { 32, 80, 80, 80 } },
      { kind = "chain", closed = true,                   -- ceiling block
        verts = { 144, 32, 160, 32, 160, 48, 144, 48 } },
    } }
  local body_w, body_h = 10, 14
  local stand = 112 - body_h

  local nx, ny, hit = wd:move(60, stand, body_w, body_h, 40, 0)
  check(nx == 96 - body_w and ny == stand and hit.right and not hit.left,
        "collide: clamp right at wall (" .. nx .. ")")
  nx, ny, hit = wd:move(130, stand, body_w, body_h, -40, 0)
  check(nx == 112 and hit.left, "collide: clamp left at wall")
  nx, ny, hit = wd:move(60, 30, body_w, body_h, 40, 0)
  check(nx == 100 and not hit.right, "collide: free run above wall")
  nx, ny, hit = wd:move(60, 58, body_w, body_h, 40, 0)
  check(nx == 96 - body_w and hit.right, "collide: partial band blocks")
  nx, ny, hit = wd:move(0, stand, body_w, body_h, 1000, 0)
  check(nx == 96 - body_w and hit.right, "collide: no x tunneling")

  nx, ny, hit = wd:move(20, 60, body_w, body_h, 0, 200)
  check(ny == stand and hit.down and not hit.oneway,
        "collide: land on floor, no y tunneling")
  nx, ny, hit = wd:move(20, stand, body_w, body_h, 0, 0.25)
  check(ny == stand and hit.down, "collide: standing is stable")
  nx, ny, hit = wd:move(146, 60, body_w, body_h, 0, -30)
  check(ny == 48 and hit.up, "collide: head bonk clamps (" .. ny .. ")")

  nx, ny, hit = wd:move(40, 50, body_w, body_h, 0, 60)
  check(ny == 80 - body_h and hit.down and hit.oneway,
        "collide: land on one-way")
  nx, ny, hit = wd:move(40, 90, body_w, body_h, 0, -40)
  check(ny == 50 and not hit.up, "collide: rise through one-way")
  nx, ny, hit = wd:move(20, 80 - body_h, body_w, body_h, 30, 0)
  check(nx == 50 and not hit.right, "collide: one-way never blocks x")
  nx, ny, hit = wd:move(40, 80 - body_h, body_w, body_h, 0, 10,
                        { drop = true })
  check(ny == 80 - body_h + 10 and not hit.down, "collide: drop-through")
  nx, ny, hit = wd:move(40, 82, body_w, body_h, 0, 10)
  check(ny == 92 and not hit.down, "collide: below plank top, no snag")

  nx, ny, hit = wd:move(8, 80 - body_h, body_w, body_h, 0, 0.25)
  check(not hit.down and ny > 80 - body_h, "collide: ledge gives no support")
  check(wd:grounded(40, 80 - body_h, body_w, body_h),
        "collide: grounded probe on plank")
  check(not wd:grounded(40, 60, body_w, body_h), "collide: airborne probe")

  nx, ny, hit = wd:move(4, 20, body_w, body_h, -30, 0)
  check(nx == 0 and hit.left, "collide: left border wall")
  nx, ny, hit = wd:move(170, 20, body_w, body_h, 30, 0)
  check(nx == 192 - body_w and hit.right, "collide: right border wall")
  nx, ny, hit = wd:move(20, 4, body_w, body_h, 0, -40)
  check(ny == -36 and not hit.up, "collide: open sky above")

  nx, ny, hit = wd:move(60, 90, body_w, body_h, 60, 30)
  check(nx == 96 - body_w and ny == 112 - body_h and hit.right and hit.down,
        "collide: axis-separated diagonal")

  -- solid_at: closed-chain interiors + the OOB rules
  check(wd:solid_at(100, 100) and not wd:solid_at(90, 100),
        "collide: solid_at closed interior")
  check(wd:solid_at(-1, 0) and wd:solid_at(193, 0) and wd:solid_at(0, 129)
        and not wd:solid_at(0, -50), "collide: oob walls + open sky")

  -- deterministic encode: same colliders -> identical bytes
  local wd2 = collide.build{ name = "selftest.col.b", w = 192, h = 128,
    colliders = {
      { kind = "chain", verts = { 0, 112, 192, 112 } },
      { kind = "chain", closed = true,
        verts = { 96, 64, 112, 64, 112, 112, 96, 112 } },
      { kind = "chain", oneway = true, verts = { 32, 80, 80, 80 } },
      { kind = "chain", closed = true,
        verts = { 144, 32, 160, 32, 160, 48, 144, 48 } },
    } }
  check(wd.buf:str(0, wd.buf:size()) == wd2.buf:str(0, wd2.buf:size()),
        "collide: canonical bytes")
  check(collide.open("selftest.col").segs and #collide.open("selftest.col").segs
        == #wd.segs, "collide: open adopts by header")

  -- B) slopes: walk up 45°, plateau, stick down, one-way slope, steep wall
  local ws = collide.build{ name = "selftest.col.s", w = 400, h = 200,
    colliders = {
      { kind = "chain", verts = { 0, 160, 400, 160 } },      -- ground
      { kind = "chain", verts = { 100, 160, 180, 80 } },     -- 45° up-right
      { kind = "chain", verts = { 180, 80, 340, 80 } },      -- plateau
      { kind = "chain", oneway = true, verts = { 20, 140, 60, 120 } },
      { kind = "chain", verts = { 350, 160, 360, 60 } },     -- steep = wall
      { kind = "chain", oneway = true, verts = { 240, 60, 250, 20 } },
      { kind = "circle", cx = 300, cy = 150, r = 12 },
    } }
  local bw, bh = 10, 14
  -- walk up the ramp from flat ground; grounded every step by snap-up
  local px, py = 80, 160 - bh
  for _ = 1, 30 do
    local hitw
    px, py, hitw = ws:move(px, py, bw, bh, 4, 1, { ground = true })
    check(hitw.down, "collide: slope walk-up stays grounded (x=" .. px .. ")")
  end
  check(px == 200 and py == 80 - bh,
        "collide: ramp led onto the plateau (" .. px .. "," .. py .. ")")
  -- walk back down: the stick keeps contact through the descent
  for _ = 1, 30 do
    local hitw
    px, py, hitw = ws:move(px, py, bw, bh, -4, 1, { ground = true })
    check(hitw.down, "collide: slope walk-down sticks (x=" .. px .. ")")
  end
  check(px == 80 and py == 160 - bh, "collide: back on the flat ground")
  -- without ground, a downhill step micro-falls (documents the stick)
  local _, my, mh = ws:move(150, 160 - (150 + bw - 100) - bh, bw, bh, -4, 1)
  check(not mh.down, "collide: no stick without opts.ground")
  -- one-way slope: land from above / rise through / drop through
  nx, ny, hit = ws:move(40, 80, bw, bh, 0, 60)
  check(ny == 125 - bh and hit.down and hit.oneway,
        "collide: land on one-way slope (" .. ny .. ")")
  nx, ny, hit = ws:move(40, 130, bw, bh, 0, -40)
  check(ny == 90 and not hit.up, "collide: rise through one-way slope")
  nx, ny, hit = ws:move(40, 125 - bh, bw, bh, 0, 6, { drop = true })
  check(not hit.down, "collide: drop through one-way slope")
  -- steep solid is a wall; steep one-way was dropped at build
  nx, ny, hit = ws:move(320, 160 - bh, bw, bh, 40, 0)
  check(nx == 350 - bw and hit.right,
        "collide: steep segment blocks as wall (" .. nx .. ")")
  local steep_ow = 0
  for _, s in ipairs(ws.segs) do
    if s.oneway and s.x0 == 240 then steep_ow = steep_ow + 1 end
  end
  check(steep_ow == 0, "collide: steep one-way ignored at build")
  -- stand_ray: sorted standables down the column
  local ray = ws:stand_ray(125, 0, 200)
  check(#ray == 2 and ray[1].y == 135 and ray[2].y == 160,
        "collide: stand_ray ramp+ground sorted")
  ray = ws:stand_ray(40, 0, 200)
  check(#ray == 2 and ray[1].oneway and ray[1].y == 130
        and ray[2].y == 160, "collide: stand_ray sees the one-way")
  -- circles: clamp-distance overlap, stored order
  check(#ws:circles(285, 140, 10, 10) == 1 and #ws:circles(10, 10, 5, 5) == 0,
        "collide: circle overlap query")
  pal.buf_free("selftest.col")
  pal.buf_free("selftest.col.b")
  pal.buf_free("selftest.col.s")
end

-- ---- cm.map / cm.tmap (R8a): the CMAP/CTLM codecs + map instancing ----

local function t_map()
  local map = cm.require("cm.map")
  local tmap = cm.require("cm.tmap")
  local chunklib = cm.require("cm.chunk")

  local doc = {
    name = "t", w = 320, h = 200, grid = 8, bg = { 0.5, 0.25, 1 },
    layers = {
      { name = "bg", vis = true, on = true, par_x = 0.5, par_y = 0.25 },
      { name = "props", vis = false, on = true },
      { name = "overlay", vis = true, on = false },
    },
    colliders = {
      { kind = "chain", verts = { 0, 180, 320, 180 } },
      { kind = "quad", x = 100, y = 140, w = 40, h = 40 },
      { kind = "circle", cx = 30, cy = 30, r = 9 },
    },
    places = {
      { path = "art/sign.png", x = 20, y = 160, layer = 1, vis = false,
        gid = 7 },
      { path = "art/awning.spr", x = 200, y = 120, name = "awn",
        flip = true, layer = 2, anim = "wave",
        cols = { { kind = "chain", oneway = true,
                   verts = { 0, 0, 48, 0 } } } },
      { path = "sound/bgm.song", x = 8, y = 8, name = "bgm", layer = 3,
        gid = 7 },
    },
    markers = {
      { x = 10, y = 150, w = 30, h = 30, kind = "spawn", label = "start",
        note = "", gid = 7, extras = { { k = "name", v = "start" } } },
      { x = 300, y = 150, w = 16, h = 30, kind = "portal", label = "out",
        note = "n", extras = { { k = "to", v = "b" }, { k = "at", v = "x" } } },
    },
  }
  local raw = map.encode(doc)
  local d = map.decode(raw)
  check(d.name == "t" and d.w == 320 and d.h == 200 and d.grid == 8,
        "map: HEAD round trip")
  check(d.bg[1] == 0.5 and d.bg[2] == 0.25 and d.bg[3] == 1,
        "map: bg tint round trip")
  check(#d.layers == 3 and d.layers[1].name == "bg" and d.layers[2].name
        == "props" and d.layers[2].vis == false and d.layers[3].on == false
        and d.layers[1].vis == true and d.layers[1].on == true,
        "map: LAYR round trip (names + vis/on flags)")
  check(d.layers[1].par_x == 0.5 and d.layers[1].par_y == 0.25
        and d.layers[2].par_x == nil and d.layers[2].par_y == nil
        and d.layers[3].par_x == nil,
        "map: LAYR v2 parallax pair round trips (1 stays nil)")
  check(#d.colliders == 3 and d.colliders[1].kind == "chain"
        and d.colliders[1].verts[4] == 180 and d.colliders[2].kind == "quad"
        and d.colliders[2].w == 40 and d.colliders[3].kind == "circle"
        and d.colliders[3].r == 9, "map: colliders round trip")
  check(#d.places == 3 and d.places[1].name == nil
        and d.places[1].path == "art/sign.png" and d.places[2].name == "awn"
        and d.places[2].flip == true and d.places[2].layer == 2
        and d.places[2].anim == "wave" and d.places[2].cols[1].oneway
        and d.places[2].cols[1].verts[3] == 48, "map: places round trip")
  check(d.places[1].vis == false and d.places[2].vis == true
        and d.places[3].name == "bgm" and d.places[3].anim == nil,
        "map: the vis flag rides PLCE bit1; anim + non-visual ref carry")
  check(d.places[1].gid == 7 and d.places[3].gid == 7
        and d.places[2].gid == nil and d.markers[1].gid == 7
        and d.markers[2].gid == nil,
        "map: the group gid rides PLCE v3 / MRKR v2 (0 = ungrouped)")
  check(#d.markers == 2 and d.markers[1].kind == "spawn"
        and d.markers[2].extras[2].v == "x"
        and map.extras(d.markers[2]).to == "b", "map: markers round trip")
  check(map.encode(d) == raw, "map: canonical bytes (encode∘decode = id)")
  -- layer gating: place_on reflects layer.on; z_order sorts by layer
  check(map.place_on(d, d.places[1]) and not map.place_on(d, d.places[3]),
        "map: place_on gates on layer.on (overlay off = doesn't exist)")
  local zo = map.z_order(d)
  check(#zo == 3 and zo[1] == 1 and zo[3] == 3,
        "map: z_order sorts placements by layer (bg < props < overlay)")

  -- backward compat: real legacy bytes — a PLCE v1 (no anim field, bit1 =
  -- hidden) with NO LAYR chunk decode through the migration path
  local w1 = chunklib.writer("CMAP")
  w1.chunk("HEAD", 1, string.pack("<i4i4I4fffs4", 32, 32, 8, 1, 1, 1, "v1"))
  w1.chunk("PLCE", 1, -- layer 0, flags bit1 hidden, at 5,6, no cols
           string.pack("<I1I4i4i4s4s4I2", 0, 2, 5, 6, "old.png", "", 0))
  w1.chunk("TAIL", 1, "")
  local v1d = map.decode(w1.result())
  check(#v1d.layers == 1 and v1d.layers[1].name == "main"
        and v1d.places[1].layer == 1 and v1d.places[1].vis == false
        and v1d.places[1].x == 5 and v1d.places[1].anim == nil,
        "map: legacy PLCE v1 + no LAYR migrates (hidden->vis=false, layer 1)")

  -- legacy LAYR v1 bytes (no parallax pair) read as par = 1 (nil)
  local wl = chunklib.writer("CMAP")
  wl.chunk("HEAD", 1, string.pack("<i4i4I4fffs4", 32, 32, 8, 1, 1, 1, "l1"))
  wl.chunk("LAYR", 1, string.pack("<I2I1s4I1s4", 2, 3, "back", 3, "front"))
  wl.chunk("TAIL", 1, "")
  local l1d = map.decode(wl.result())
  check(#l1d.layers == 2 and l1d.layers[1].name == "back"
        and l1d.layers[1].par_x == nil and l1d.layers[2].par_y == nil
        and l1d.layers[1].vis == true and l1d.layers[1].on == true,
        "map: legacy LAYR v1 reads (parallax defaults to 1)")

  -- the canonical-version rule (the FLGS idiom): all-world-speed maps
  -- write LAYR v1 (historical bytes untouched); any parallax → v2
  local function layr_version(bytes)
    for _, c in ipairs(chunklib.read(bytes, "CMAP")) do
      if c.tag == "LAYR" then return c.version end
    end
  end
  local pd = { name = "p", w = 16, h = 16, grid = 8, colliders = {},
               places = {}, markers = {},
               layers = { { name = "a", vis = true, on = true } } }
  check(layr_version(map.encode(pd)) == 1,
        "map: all-world-speed LAYR stays canonical v1")
  pd.layers[1].par_x = 0.5
  check(layr_version(map.encode(pd)) == 2,
        "map: any parallax factor promotes LAYR to v2")
  pd.layers[1].par_x = nil
  pd.layers[1].par_y = 2
  check(layr_version(map.encode(pd)) == 2,
        "map: par_y alone promotes LAYR to v2")

  -- FLGS (§5 per-map fill switch): written only when set, round-trips
  local fd = { name = "f", w = 32, h = 32, grid = 8,
               colliders = {}, places = {}, markers = {} }
  check(map.decode(map.encode(fd)).nofill == nil, "map: no FLGS = fill on")
  fd.nofill = true
  local fraw = map.encode(fd)
  local fdec = map.decode(fraw)
  check(fdec.nofill == true, "map: FLGS nofill round trip")
  check(map.encode(fdec) == fraw, "map: FLGS canonical")

  -- the graybox generator (§5 end state): ground row + block + one-way
  local gd = { w = 64, h = 48, colliders = {
    { kind = "quad", x = 0, y = 32, w = 64, h = 16 },
    { kind = "quad", x = 16, y = 16, w = 16, h = 16 },
    { kind = "chain", oneway = true, verts = { 32, 16, 64, 16 } },
  }, places = {} }
  local td = tmap.graybox(gd)
  check(td.w == 4 and td.h == 3 and td.tile == 16
        and td.tileset == "art/tiles.spr", "tmap: graybox doc shape")
  local got_grid = {}
  for r = 0, 2 do
    for c = 0, 3 do got_grid[#got_grid + 1] = tmap.get(td, c, r) end
  end
  local want = { 0, 0, 0, 0, -- sky
                 0, 6, 5, 5, -- block = pillar-on-ground; one-way slabs
                 1, 2, 1, 1 } -- ground: tops, interior under the block
  local same = true
  for i = 1, 12 do same = same and got_grid[i] == want[i] end
  check(same, "tmap: graybox autotiles (got " ..
        table.concat(got_grid, ",") .. ")")

  -- skip-tolerance: an unknown future chunk decodes right past
  local w2 = chunklib.writer("CMAP")
  for _, c in ipairs(chunklib.read(raw, "CMAP")) do
    if c.tag == "TAIL" then w2.chunk("XTRA", 9, "future bytes") end
    w2.chunk(c.tag, c.version, c.payload)
  end
  local d2 = map.decode(w2.result())
  check(d2.w == 320 and #d2.places == 3, "map: unknown chunk skipped")

  -- refusals
  check(not pcall(map.decode, raw:sub(1, #raw - 12)), "map: no TAIL refused")
  check(not pcall(map.decode, "CMAP"), "map: no HEAD refused")
  check(not pcall(map.decode, "XXXXjunk"), "map: bad magic refused")

  -- Map source publication is atomic. An interrupted replacement leaves the
  -- previous valid generation byte-for-byte intact; a retry publishes the
  -- complete newer document.
  local savepath = (os.getenv("TMPDIR") or "/tmp")
                   .. "/cosmic_selftest_atomic.map"
  check(map.save(d, savepath) == true, "map save: seed generation")
  local saved = pal.read_file(savepath)
  local newer = map.decode(raw)
  newer.name = "new generation"
  local sok, serr = map.save(newer, savepath, { _fail = "rename" })
  check(not sok and serr:find("write map failed")
        and pal.read_file(savepath) == saved,
        "map save: failed replacement preserves previous source")
  check(map.save(newer, savepath) == true
        and map.decode(pal.read_file(savepath)).name == "new generation",
        "map save: retry publishes complete source")

  -- instancing: file -> collider buffer + tables (the level.lua successor)
  local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/cosmic_selftest.map"
  check(pal.write_file(tmp, raw) == true, "map: tmp write")
  local inst = map.use{ path = tmp, name = "selftest.mapw" }
  check(inst.doc.w == 320 and inst.world.w == 320 and inst.world.h == 200,
        "map: use builds the world at map bounds")
  -- the free quad blocks as a wall (its left face at 100)
  local nx, ny, hit = inst.world:move(40, 150, 10, 14, 200, 0)
  check(nx == 90 and hit.right, "map: quad collider blocks (" .. nx .. ")")
  -- the attached one-way rides its placement offset (200,120)
  nx, ny, hit = inst.world:move(210, 80, 10, 14, 0, 100)
  check(ny == 120 - 14 and hit.down and hit.oneway,
        "map: attached collider offset by placement (" .. ny .. ")")
  -- the free ground line
  nx, ny, hit = inst.world:move(60, 100, 10, 14, 0, 200)
  check(ny == 180 - 14 and hit.down and not hit.oneway, "map: ground line")
  -- circle instanced
  check(#inst.world:circles(25, 25, 10, 10) == 1, "map: circle instanced")
  -- named placement handle (render-only mutations)
  local awn = map.get("awn")
  check(awn and awn.x == 200 and map.get("nope") == nil,
        "map: get(name) placement handle")

  -- named-ref resolution + graceful fallback (cm.map.ref). awning.spr is a
  -- synthetic path (no file), so ref falls back to the checkerboard sprite.
  local rp, rk, rok = map.ref("awn")
  check(rok == false and rk == "spr" and rp == map.FALLBACK.spr,
        "map.ref: a dangling visual falls back to the checkerboard")
  -- bgm sits on the OFF overlay layer -> it acts as if it doesn't exist
  check(map.ref("bgm") == nil and select(3, map.ref("bgm")) == false,
        "map.ref: a name on a disabled layer is absent")
  check(select(3, map.ref("nope")) == false,
        "map.ref: an unknown name returns nil, false")

  -- reload in place (R8b, MAPS.md §9): the held world wrapper + instance
  -- adopt the saved file's new geometry without re-plumbing
  local held_world = inst.world
  local d3 = map.decode(raw)
  d3.colliders[1].verts = { 0, 100, 320, 100 } -- ground rises to y=100
  d3.places[2].name = "awn2"
  check(pal.write_file(tmp, map.encode(d3)) == true, "map: reload tmp write")
  check(map.reload("/nope/other.map") == false, "map: reload wrong path no-ops")
  check(map.reload(tmp) == true, "map: reload accepts the live path")
  check(inst.world == held_world, "map: reload keeps the wrapper identity")
  local rx, ry, rhit = held_world:move(60, 20, 10, 14, 0, 200)
  check(ry == 100 - 14 and rhit.down, "map: reload rebuilt the segments ("
        .. ry .. ")")
  check(map.get("awn2") ~= nil and map.get("awn") == nil,
        "map: reload rebuilt the name lookup")

  -- Rewind integration: a stable map slot changes A -> B, then a named
  -- placement is mutated through its Lua handle. The generic state capture
  -- boundary must put all three generations in the ring; restore_tables must
  -- atomically rebuild the SAME instance/world wrappers from each frame.
  local trace = cm.require("cm.trace")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  trace.ring_start({ project = "" })
  local irec = ("\0"):rep(10)
  state.advance_frame()
  trace.record_frame(irec, nil)
  local fa = state.frame()

  local tmp2 = (os.getenv("TMPDIR") or "/tmp") .. "/cosmic_selftest_b.map"
  local db = {
    name = "other", w = 400, h = 240, grid = 8, bg = { 0.1, 0.2, 0.3 },
    layers = map.default_layers(),
    colliders = { { kind = "chain", verts = { 0, 220, 400, 220 } } },
    places = { { path = "art/other.png", x = 24, y = 32, layer = 1,
                 name = "other" } },
    markers = { { x = 9, y = 10, w = 11, h = 12, kind = "spawn",
                  label = "b", note = "" } },
  }
  check(pal.write_file(tmp2, map.encode(db)) == true, "map rewind: B tmp write")
  local inst2 = map.use{ path = tmp2, name = "selftest.mapw" }
  check(inst2 == inst and inst2.world == held_world,
        "map rewind: switching maps retains slot + world identity")
  state.advance_frame()
  trace.record_frame(irec, nil)
  local fb = state.frame()

  map.get("other").x = 77 -- no setter/dirty call: capture must see the handle
  state.advance_frame()
  trace.record_frame(irec, nil)
  local fm = state.frame()

  local function park_at(f)
    local st = trace.ring_state_at(f)
    state.restore_tables(st.bufs, st.doct)
  end
  park_at(fa)
  check(inst.path == tmp and inst.doc.name == "t" and map.current() == inst
        and map.get("awn2") ~= nil,
        "map rewind: frame A restores active path, doc, current slot + names")
  rx, ry, rhit = held_world:move(60, 20, 10, 14, 0, 200)
  check(ry == 100 - 14 and rhit.down,
        "map rewind: frame A rebuilds held collision wrapper")

  park_at(fb)
  check(inst.path == tmp2 and inst.doc.name == "other"
        and inst.doc.markers[1].label == "b" and map.get("other").x == 24,
        "map rewind: frame B restores render doc + markers")
  rx, ry, rhit = held_world:move(60, 20, 10, 14, 0, 240)
  check(ry == 220 - 14 and rhit.down,
        "map rewind: frame B restores matching collision")

  park_at(fm)
  check(map.get("other").x == 77,
        "map rewind: direct placement-handle mutation is captured")

  -- State restore is sufficient on its own: simulate a fresh Lua facade and
  -- prove the CMRT signature + current selector discover/rebuild the slot.
  map._slots[inst.name], map.cur = nil, nil
  park_at(fb)
  local discovered = map.current()
  local dx, dy, dhit
  if discovered then
    dx, dy, dhit = discovered.world:move(60, 20, 10, 14, 0, 240)
  end
  check(discovered and discovered ~= inst and discovered.path == tmp2
        and discovered.doc.markers[1].label == "b"
        and dx == 60 and dy == 220 - 14 and dhit.down,
        "map rewind: restore discovers a captured slot without game.init")

  -- Leave later selftests exactly where this focused ring started.
  map.release(discovered)
  sim:i64(0, f0)
  trace._R, trace._rec = nil, nil

  -- fill geometry (pure): loops/slabs/lines classified, attached offset
  local geom = map.geom(d)
  check(#geom.loops == 1 and #geom.lines == 1 and #geom.slabs == 1,
        "map: geom classifies loops/lines/slabs")
  check(geom.slabs[1][1] == 200 and geom.slabs[1][3] == 248,
        "map: geom offsets attached colliders")
  local ivs = map.column_ivs(geom.loops, 120.5, {})
  check(#ivs == 2 and ivs[1] == 140 and ivs[2] == 180,
        "map: column_ivs crosses the quad loop")
  check(#map.column_ivs(geom.loops, 60.5, {}) == 0,
        "map: column_ivs empty off the loop")

  -- ---- cm.tmap ----
  local td = tmap.blank(4, 3, 16, "art/tiles.spr")
  check(tmap.get(td, 1, 2) == 0 and tmap.get(td, -1, 0) == 0
        and tmap.get(td, 4, 0) == 0, "tmap: blank + oob get")
  tmap.set(td, 1, 2, 7)
  tmap.set(td, -1, 0, 9) -- oob inert
  tmap.set(td, 0, 3, 9)
  check(tmap.get(td, 1, 2) == 7 and tmap.get(td, 0, 0) == 0,
        "tmap: set/get, oob inert")
  local traw = tmap.encode(td)
  local td2 = tmap.decode(traw)
  check(td2.w == 4 and td2.h == 3 and td2.tile == 16
        and td2.tileset == "art/tiles.spr" and tmap.get(td2, 1, 2) == 7,
        "tmap: round trip")
  check(tmap.encode(td2) == traw, "tmap: canonical bytes")

  -- Tilemap source publication is atomic. An interrupted replacement leaves
  -- the previous valid generation byte-for-byte intact; a retry publishes the
  -- complete newer document.
  local tsavepath = (os.getenv("TMPDIR") or "/tmp")
                    .. "/cosmic_selftest_atomic.tm"
  check(tmap.save(td2, tsavepath) == true, "tmap save: seed generation")
  local tsaved = pal.read_file(tsavepath)
  local tnewer = tmap.decode(traw)
  tmap.set(tnewer, 0, 0, 11)
  local tsok, tserr = tmap.save(tnewer, tsavepath, { _fail = "rename" })
  check(not tsok and tserr:find("write tilemap failed")
        and pal.read_file(tsavepath) == tsaved,
        "tmap save: failed replacement preserves previous source")
  check(tmap.save(tnewer, tsavepath) == true
        and tmap.get(tmap.decode(pal.read_file(tsavepath)), 0, 0) == 11,
        "tmap save: retry publishes complete source")

  local bad = chunklib.writer("CTLM")
  bad.chunk("HEAD", 1, string.pack("<i4i4I4s4", 4, 3, 16, ""))
  bad.chunk("GRID", 1, "\0\0") -- wrong size for 4x3
  bad.chunk("TAIL", 1, "")
  check(not pcall(tmap.decode, bad.result()), "tmap: grid mismatch refused")

  -- ---- the R8d grid ops: resize (grow/crop) + fill_rect ----
  local rd = tmap.blank(3, 2, 16, "")
  tmap.set(rd, 2, 1, 5)
  tmap.set(rd, 0, 0, 3)
  tmap.resize(rd, 5, 4) -- grow: overlap survives, growth empty
  check(rd.w == 5 and rd.h == 4 and #rd.cells == 5 * 4 * 2
        and tmap.get(rd, 2, 1) == 5 and tmap.get(rd, 0, 0) == 3
        and tmap.get(rd, 4, 3) == 0, "tmap: resize grow keeps overlap")
  tmap.resize(rd, 2, 2) -- crop: (2,1) falls off, (0,0) survives
  check(rd.w == 2 and rd.h == 2 and #rd.cells == 2 * 2 * 2
        and tmap.get(rd, 0, 0) == 3 and tmap.get(rd, 1, 1) == 0,
        "tmap: resize crop drops the cut cells")
  local fd = tmap.blank(4, 4, 16, "")
  tmap.fill_rect(fd, 3, 2, 1, 1, 9) -- either corner order + fill
  check(tmap.get(fd, 1, 1) == 9 and tmap.get(fd, 3, 2) == 9
        and tmap.get(fd, 2, 2) == 9 and tmap.get(fd, 0, 1) == 0
        and tmap.get(fd, 1, 3) == 0, "tmap: fill_rect corner-order + bounds")
  tmap.fill_rect(fd, -2, 3, 9, 3, 4) -- clamps to the grid
  check(tmap.get(fd, 0, 3) == 4 and tmap.get(fd, 3, 3) == 4,
        "tmap: fill_rect clamps oob")

  -- ---- the §7 edge-run walk (R8d) ----
  -- 8x3 @16px: the bottom row solid across, a lone block at (3,1),
  -- and an overhang at (6,0) (its underside is a ceiling face)
  local ed_ = tmap.blank(8, 3, 16, "")
  tmap.fill_rect(ed_, 0, 2, 7, 2, 1)
  tmap.set(ed_, 3, 1, 1)
  tmap.set(ed_, 6, 0, 1)
  local x0, y0, x1, y1 = tmap.edge_run(ed_, 20, 33, 4) -- floor at col 1
  check(x0 == 0 and y0 == 32 and x1 == 48 and y1 == 32,
        "tmap: edge_run floor stops at the block column")
  x0, y0, x1, y1 = tmap.edge_run(ed_, 70, 30, 4) -- right of the block
  check(x0 == 64 and y0 == 32 and x1 == 128 and y1 == 32,
        "tmap: edge_run floor resumes past the block")
  x0, y0, x1, y1 = tmap.edge_run(ed_, 56, 17, 4) -- the block's own top
  check(x0 == 48 and y0 == 16 and x1 == 64 and y1 == 16,
        "tmap: edge_run block top is a one-cell run")
  x0, y0, x1, y1 = tmap.edge_run(ed_, 47, 24, 4) -- the block's left face
  check(x0 == 48 and y0 == 16 and x1 == 48 and y1 == 32,
        "tmap: edge_run vertical left face")
  x0, y0, x1, y1 = tmap.edge_run(ed_, 100, 15, 4) -- the overhang underside
  check(x0 == 96 and y0 == 16 and x1 == 112 and y1 == 16,
        "tmap: edge_run ceiling face qualifies")
  check(tmap.edge_run(ed_, 40, 8, 3) == nil,
        "tmap: edge_run open air proposes nothing")
  check(tmap.edge_run(ed_, 20, 42, 3) == nil,
        "tmap: edge_run interior (no exposed face) proposes nothing")
end

-- ---- cm.state.buf_poke/buf_peek (the inspector's buffer eval unit) ----

local function t_buf_poke()
  local repl = cm.require("cm.repl")
  pal.buf("selftest.poke", 32)

  state.buf_poke("selftest.poke", "u8", 0, 200)
  check(state.buf_peek("selftest.poke", "u8", 0) == 200, "buf_poke: u8")
  state.buf_poke("selftest.poke", "i8", 1, -7)
  check(state.buf_peek("selftest.poke", "i8", 1) == -7, "buf_poke: i8")
  state.buf_poke("selftest.poke", "u16", 2, 60000)
  check(state.buf_peek("selftest.poke", "u16", 2) == 60000, "buf_poke: u16")
  state.buf_poke("selftest.poke", "i16", 4, -1234)
  check(state.buf_peek("selftest.poke", "i16", 4) == -1234, "buf_poke: i16")
  state.buf_poke("selftest.poke", "u32", 8, 4000000000)
  check(state.buf_peek("selftest.poke", "u32", 8) == 4000000000,
        "buf_poke: u32")
  state.buf_poke("selftest.poke", "i32", 12, -77)
  check(state.buf_peek("selftest.poke", "i32", 12) == -77, "buf_poke: i32")
  state.buf_poke("selftest.poke", "i64", 16, -3 << 40)
  check(state.buf_peek("selftest.poke", "i64", 16) == -3 << 40,
        "buf_poke: i64")
  state.buf_poke("selftest.poke", "f32", 24, 1.5)
  check(state.buf_peek("selftest.poke", "f32", 24) == 1.5, "buf_poke: f32")
  state.buf_poke("selftest.poke", "f64", 24, 0.1)
  check(state.buf_peek("selftest.poke", "f64", 24) == 0.1, "buf_poke: f64")

  check(not pcall(state.buf_poke, "selftest.poke", "x32", 0, 1),
        "buf_poke: bad kind errors")
  check(not pcall(state.buf_poke, "selftest.poke", "u8", 32, 1),
        "buf_poke: oob errors")
  check(not pcall(state.buf_peek, "selftest.nosuch", "u8", 0),
        "buf_peek: unknown buffer errors")

  -- the actual eval form: a self-contained command string through cm.repl
  check(repl.exec('cm.state.buf_poke("selftest.poke","f32",28,2.25)') == true,
        "buf_poke: exec as an eval string")
  check(state.buf_peek("selftest.poke", "f32", 28) == 2.25,
        "buf_poke: eval landed")
  check(repl.exec('cm.state.buf_poke("selftest.poke","u8",999,1)') == false,
        "buf_poke: erroring eval is contained")

  pal.buf_free("selftest.poke")
end

-- ---- cm.inspect (the M4 inspector panel: eval building + render) ----

local function t_inspect()
  local inspect = cm.require("cm.inspect")
  local repl = cm.require("cm.repl")
  local ui = cm.require("cm.ui")

  -- eval path building: dotted when clean, bracketed otherwise
  check(inspect.path_append("doc", "knobs") == "doc.knobs",
        "inspect: dotted path")
  check(inspect.path_append("doc", "end") == 'doc["end"]',
        "inspect: keyword key bracketed")
  check(inspect.path_append("doc", "a b") == 'doc["a b"]',
        "inspect: non-identifier key bracketed")
  check(inspect.path_append("doc", 3) == "doc[3]", "inspect: integer key")

  -- value literals reproduce value AND numeric subtype
  check(inspect.fmt_value(142) == "142", "inspect: integer literal")
  check(inspect.fmt_value(142.0) == "142.0", "inspect: float keeps .0")
  check(inspect.fmt_value(0.55) == "0.55", "inspect: fraction literal")
  check(inspect.fmt_value(-3.25) == "-3.25", "inspect: negative float")
  check(inspect.fmt_value(true) == "true", "inspect: boolean literal")
  check(inspect.fmt_value(1 / 0) == "(1/0)", "inspect: inf is eval-safe")
  check(inspect.fmt_value(2.5e300) == "2.5e+300", "inspect: exponent form")

  -- a built command runs through the real eval path
  state.doc.itest = { ["end"] = 1.0, flag = false }
  local cmd = inspect.path_append(inspect.path_append("doc", "itest"), "end")
              .. " = " .. inspect.fmt_value(2.5)
  check(cmd == 'doc.itest["end"] = 2.5', "inspect: assembled command")
  check(repl.exec(cmd) == true, "inspect: built eval runs")
  check(state.doc.itest["end"] == 2.5, "inspect: built eval landed")

  -- the panel renders over a populated doc + an expanded buffer without
  -- touching sim state or submitting anything (one headless ui pass)
  state.doc.itest.sub = { x = 1, y = 2.5, tag = "hi" }
  pal.buf("selftest.insp", 16):f32(0, 3.5)
  inspect.open_buf["selftest.insp"] = true
  inspect.open_doc["itest"] = true
  inspect.search = ""
  local before = state.canon(state.doc)
  local function render()
    ui.frame({})
    pal.begin_frame(0, 0, 0, 1)
    inspect.frame(2, 2, 186, 250)
    ui.frame_end()
  end
  render()
  check(state.canon(state.doc) == before, "inspect: render is read-only")
  check(#repl.queue == 0, "inspect: render submits nothing")
  inspect.search = "itest" -- search mode: flat leaf rows
  render()
  inspect.search = ""

  state.doc.itest = nil
  inspect.open_doc["itest"] = nil
  inspect.open_buf["selftest.insp"] = nil
  pal.buf_free("selftest.insp")
end

-- ---- code bundle restore (D012): bundle source replaces running code ----

local function t_bundle()
  local knob = cm.require("knob")
  check(knob.value == 1, "knob module baseline")
  cm.restore_bundle({
    { name = "knob", path = "projects/selftest/knob.lua",
      source = "return { value = 2 }" },
  })
  check(knob.value == 2, "bundle code re-executed into the same table")
  check(cm.require("knob") == knob, "module identity preserved")
  local changed = cm.adopt_disk()
  check(knob.value == 1, "adopt_disk returns to disk code")
  check(#changed == 1 and changed[1] == "knob", "adopt reports the reload")

  -- D118: a re-run bundle module may require a SIBLING seeded by the same
  -- bundle (the cross-project clip drop: bigworld's main requiring its
  -- world inside a demo session). Seeding must complete before ANY re-run
  -- — a single interleaved pass resolved the sibling against the live
  -- project's disk, which does not have it. The sibling is deliberately
  -- listed AFTER the module that requires it.
  cm.restore_bundle({
    { name = "knob", path = "projects/selftest/knob.lua",
      source = "local dep = cm.require('st_bdep')\n"
               .. "return { value = 10 + dep.v }" },
    { name = "st_bdep", path = "projects/selftest/st_bdep.lua",
      source = "return { v = 5 }" },
  })
  check(knob.value == 15,
        "bundle: a re-run resolves its bundle-seeded sibling, never disk")
  cm.adopt_disk()
  check(knob.value == 1, "bundle: back on disk code after the sibling round")
end

-- ---- cm.trace segment ring (D032) ----
-- runs before main.boot() starts the live ring, so the module is ours to
-- drive: synthetic frames = mutate buffers, advance the counter by hand,
-- call record_frame. Leaves state exactly as found.

local function t_ring_edoc()
  -- R6a (REWIND.md §2/D053): the editor stream rides the ring as EDOC
  -- chunks — rev-gated, keyframe-carried, invisible to old readers
  local trace = cm.require("cm.trace")
  local chunklib = cm.require("cm.chunk")
  local ed = cm.require("cm.ed")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local was_on, was_doc, was_rev = ed.on, ed.doc, ed.doc_rev
  trace.ring.kf = 4
  trace.ring.seconds = 10
  ed.on = true
  ed.doc = { v = 1, wins = {}, mark = 0 }
  ed.doc_rev = 100
  local b = pal.buf("st.redoc", 8)
  b:i32(0, 0)
  trace.ring_start({ project = "selftest" })
  local irec = ("\0"):rep(10)
  local canon_at = {}
  for i = 1, 10 do
    b:i32(0, i)
    if i == 3 then
      ed.doc.mark = 3
      ed.doc_rev = ed.doc_rev + 1
    elseif i == 5 then
      ed.doc.mark = 5 -- NO rev bump: the gate must skip this mutation
    elseif i == 7 then
      ed.doc.mark = 7
      ed.doc_rev = ed.doc_rev + 1
    end
    sim:i64(0, f0 + i)
    canon_at[i] = state.canon(ed.doc)
    trace.record_frame(irec, nil)
  end
  check(trace.ring_state_at(f0 + 2).edoc == canon_at[2],
        "ring edoc: keyframe baseline")
  check(trace.ring_state_at(f0 + 3).edoc == canon_at[3],
        "ring edoc: a change lands on its own frame")
  check(trace.ring_state_at(f0 + 4).edoc == canon_at[3],
        "ring edoc: carried forward")
  check(trace.ring_state_at(f0 + 6).edoc == canon_at[3]
        and trace.ring_state_at(f0 + 6).edoc ~= canon_at[5],
        "ring edoc: rev gate skips silent mutations")
  check(trace.ring_state_at(f0 + 7).edoc == canon_at[7],
        "ring edoc: second change")
  -- frames 9/10 live in a segment opened AFTER the last change: their
  -- reconstruction walks no EDOC chunk — the keyframe must carry it
  check(trace.ring_state_at(f0 + 10).edoc == canon_at[7],
        "ring edoc: keyframe carries the ed canon standalone")
  -- exports carry EDOC (skip-tolerant readers ignore it)
  local ok = trace.ring_export("/tmp/st_edoc.ctrace")
  check(ok ~= nil, "ring edoc: export ok")
  local saw = false
  for _, c in ipairs(chunklib.read(
      pal.read_file("/tmp/st_edoc.ctrace"), "CTRC")) do
    if c.tag == "EDOC" then saw = true end
  end
  check(saw, "ring edoc: export carries the stream")

  ed.on, ed.doc, ed.doc_rev = was_on, was_doc, was_rev
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  pal.buf_free("st.redoc")
  trace.ring_start({ project = "selftest" }) -- leave a clean ring behind
end

local function t_ring()
  local trace = cm.require("cm.trace")
  local chunklib = cm.require("cm.chunk")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_seconds, save_kf = trace.ring.seconds, trace.ring.kf
  local irec = ("\0"):rep(10)

  trace.ring.kf = 4
  trace.ring.seconds = 0.2 -- 12-frame window
  local b = pal.buf("st.ring", 16)
  b:i32(0, 0); b:i32(4, 0)
  trace.ring_start({ project = "selftest" })

  -- 20 synthetic frames; doc changes at 9, reverts at 15; eval at 18
  local snaps = {}
  for i = 1, 20 do
    b:i32(0, i * 7)
    b:i32(4, i)
    if i == 9 then state.doc.ringtest = 9 end
    if i == 15 then state.doc.ringtest = nil end
    sim:i64(0, f0 + i)
    snaps[i] = b:str(0, 16)
    trace.record_frame(irec, i == 18 and { "-- ring eval marker" } or nil)
  end

  local lo, hi = trace.ring_range()
  check(hi == f0 + 20, "ring: newest frame")
  check(lo == f0 + 8, "ring: eviction kept exactly the window")
  for f = lo, hi do
    local st = trace.ring_state_at(f)
    check(st.bufs["st.ring"] == snaps[f - f0],
          "ring: state_at frame +" .. (f - f0))
    check(string.unpack("<i8", st.bufs["cm.sim"]) == f,
          "ring: state_at counter +" .. (f - f0))
    local doc = state.parse(st.doct)
    local want = (f - f0 >= 9 and f - f0 <= 14) and 9 or nil
    check(doc.ringtest == want, "ring: state_at doc +" .. (f - f0))
  end
  check(trace.ring_state_at(hi).input == irec, "ring: state_at input record")
  local stats = trace.ring_stats()
  check(stats.segs == 4 and stats.frames == 12 and not stats.pinned,
        "ring: stats")

  -- export the retained window: a normal CTRC with KEYF at the boundaries
  local ok, frames = trace.ring_export("/tmp/st_ring.ctrace")
  check(ok and frames == 12, "ring: export frame count")
  local trace_good = pal.read_file("/tmp/st_ring.ctrace")
  trace._write_fail = { trace = { _fail = "rename" } }
  ok = trace.ring_export("/tmp/st_ring.ctrace")
  check(not ok and pal.read_file("/tmp/st_ring.ctrace") == trace_good,
        "ring: interrupted trace export preserves previous trace")
  trace._write_fail = nil
  local tags = {}
  for _, c in ipairs(chunklib.read(pal.read_file("/tmp/st_ring.ctrace"),
                                   "CTRC")) do
    tags[#tags + 1] = c.tag
    if c.tag == "TAIL" then
      check(string.unpack("<I4", c.payload) == 12, "ring: export TAIL")
    end
  end
  check(table.concat(tags, " ") ==
        "HEAD SNAP FRAM FRAM FRAM FRAM KEYF FRAM FRAM FRAM FRAM KEYF " ..
        "FRAM EVAL FRAM FRAM FRAM KEYF TAIL",
        "ring: export chunk order (got " .. table.concat(tags, " ") .. ")")

  -- rewind to hi-3 (= +17, first frame of the last full segment)
  trace.rewind(f0 + 17)
  check(b:str(0, 16) == snaps[17], "rewind: buffer restored")
  check(sim:i64(0) == f0 + 17, "rewind: frame counter restored")
  local lo2, hi2 = trace.ring_range()
  check(lo2 == lo and hi2 == f0 + 17, "rewind: ring truncated")
  check(state.doc.ringtest == nil, "rewind: doc restored")

  -- resume recording on the truncated timeline
  for i = 18, 19 do
    b:i32(0, i * 1000)
    sim:i64(0, f0 + i)
    trace.record_frame(irec, nil)
  end
  local _, hi3 = trace.ring_range()
  check(hi3 == f0 + 19, "rewind: ring resumed")
  check(string.unpack("<i4", trace.ring_state_at(f0 + 18).bufs["st.ring"])
        == 18000, "rewind: post-rewind state_at")

  -- a non-monotonic counter step = out-of-band restore: ring resets
  sim:i64(0, f0 + 100)
  trace.record_frame(irec, nil)
  local lo4, hi4 = trace.ring_range()
  check(lo4 == f0 + 100 and hi4 == f0 + 100, "ring: discontinuity reset")

  -- code epochs land in the ring and travel through exports
  trace.on_code_change({ "cm.chunk" })
  sim:i64(0, f0 + 101)
  trace.record_frame(irec, nil)
  ok = trace.ring_export("/tmp/st_ring2.ctrace")
  check(ok, "ring: epoch export")
  tags = {}
  for _, c in ipairs(chunklib.read(pal.read_file("/tmp/st_ring2.ctrace"),
                                   "CTRC")) do
    tags[#tags + 1] = c.tag
  end
  check(table.concat(tags, " ") == "HEAD SNAP EPOC FRAM TAIL",
        "ring: epoch chunk order (got " .. table.concat(tags, " ") .. ")")

  -- record_start pins the ring; the synthesized SNAP == a live snapshot
  trace.record_start("/tmp/st_pin.ctrace", { project = "selftest" })
  local live_snap = state.snapshot()
  check(trace.recording(), "pin: recording()")
  for i = 102, 106 do
    b:i32(0, i * 3)
    sim:i64(0, f0 + i)
    trace.record_frame(irec, nil)
  end
  trace.record_stop()
  check(not trace.recording(), "pin: stopped")
  tags = {}
  local pin_snap
  for _, c in ipairs(chunklib.read(pal.read_file("/tmp/st_pin.ctrace"),
                                   "CTRC")) do
    tags[#tags + 1] = c.tag
    if c.tag == "SNAP" then pin_snap = c.payload end
  end
  check(table.concat(tags, " ") == "HEAD SNAP FRAM FRAM FRAM FRAM KEYF " ..
        "FRAM TAIL",
        "pin: chunk order (got " .. table.concat(tags, " ") .. ")")
  check(pin_snap == live_snap, "pin: SNAP byte-identical to a live snapshot")

  -- leave no trace (of the trace)
  pal.buf_free("st.ring")
  sim:i64(0, f0)
  trace.ring.seconds, trace.ring.kf = save_seconds, save_kf
  trace._R, trace._rec = nil, nil
end

-- ---- pal.x_fov / x_window_size (M8.1): the variable game target ----
-- The internal target is resizable (the FOV); gfx_size + read_pixels follow it,
-- and growing past the init size must grow the readback buffer. Headless, so
-- x_window_size reports the created size (w*scale). Restores 64x64 for the rest.
local function t_viewport()
  local w0, h0 = pal.gfx_size()
  check(w0 == 64 and h0 == 64, "fov: starts at the project internal size")
  local ww, wh = pal.x_window_size()
  check(ww == 128 and wh == 128, "window_size: headless = w*scale (got "
        .. ww .. "x" .. wh .. ")")

  local function fill_and_read(fw, fh)
    pal.x_fov(fw, fh)
    local gw, gh = pal.gfx_size()
    check(gw == fw and gh == fh, "fov: gfx_size follows resize " .. fw .. "x" .. fh)
    pal.begin_frame(0, 0, 0, 1)
    pal.quad(0, 0, fw, fh, 1, 0, 0, 1) -- fill red
    pal.present()
    local pix = pal.read_pixels()
    check(#pix == fw * fh * 4, "fov: read_pixels is fw*fh*4 (" .. fw .. "x" .. fh .. ")")
    check(pix:byte(1) == 255, "fov: top-left pixel is the drawn red")
    check(pix:byte(#pix - 3) == 255, "fov: bottom-right pixel is the drawn red")
  end

  fill_and_read(40, 30)        -- crop below init
  fill_and_read(80, 80)        -- grow past init: exercises the readback realloc
  fill_and_read(480, 270)      -- the D036 reference cap size
  local nw, nh = pal.x_fov(480, 270) -- no-op returns current size
  check(nw == 480 and nh == 270, "fov: no-op resize returns current size")

  -- two-target routing (M8.2): quads sent to the ui canvas must not bleed into
  -- the game target that read_pixels samples (headless runs both scene passes)
  pal.x_fov(64, 64)
  local uw, uh = pal.x_ui_target(32, 32)
  check(uw == 32 and uh == 32, "ui_target: created at 32x32")
  pal.begin_frame(0, 0, 1, 1)          -- game clears blue
  pal.quad(0, 0, 64, 64, 1, 0, 0, 1)   -- game: fill red
  pal.x_target("ui")
  pal.quad(0, 0, 32, 32, 0, 1, 0, 1)   -- ui: fill green (must stay off the game)
  pal.x_target("game")
  pal.present()
  local gpix = pal.read_pixels()
  check(#gpix == 64 * 64 * 4, "routing: read_pixels reads the game target")
  local saw_green = false
  for i = 1, #gpix, 4 do
    if gpix:byte(i) == 0 and gpix:byte(i + 1) == 255 and gpix:byte(i + 2) == 0 then
      saw_green = true
      break
    end
  end
  check(not saw_green, "routing: ui-target quads stay off the game target")
  check(gpix:byte(1) == 255 and gpix:byte(2) == 0, "routing: game kept its red")
  check(not pcall(pal.x_target, "bogus"), "x_target rejects an unknown target")
  pal.x_ui_target(0, 0)                -- free the ui canvas
  check(select(2, pal.x_ui_target(0, 0)) == 0, "ui_target freed (size 0)")

  pal.x_fov(64, 64)            -- restore for the remaining pixel tests
  check(select(1, pal.gfx_size()) == 64, "fov: restored to 64x64")

  -- Machine-local video/options state is atomic and reports failure while
  -- retaining the last valid settings generation.
  local view = cm.require("cm.view")
  check(view.accessibility_default(1, 1920, 1080) == 1
        and view.accessibility_default(1, 3840, 2160) == 2,
        "display scale: 1080p stays 1x and unscaled 4K defaults to 2x")
  check(view.accessibility_default(1.5, 1920, 1080) == 1.5,
        "display scale: SDL DPI is authoritative when larger")
  local old_project = cm.main.args.project
  local old_editor_scale, old_chrome_scale, old_access_auto, old_access_resolved =
    view.cfg.editor_scale, view.cfg.chrome_scale, view.cfg.access_auto,
    view.access_resolved
  local old_access_path, old_access_save_fail =
    view._access_path, view._access_save_fail
  local root = "/tmp/cosmic_selftest_video"
  pal.mkdir(root)
  cm.main.args.project = root
  local path = root .. "/video.dat"
  local access_path = root .. "/editor.dat"
  view._access_path = access_path
  view.cfg.editor_scale, view.cfg.chrome_scale, view.cfg.access_auto = 1.5, 2, false
  pal.write_file(path, "known-good-video")
  view._save_fail = { _fail = "rename" }
  local vok, verr = view.save_video()
  check(not vok and type(verr) == "string"
        and pal.read_file(path) == "known-good-video",
        "video: interrupted options save preserves previous file")
  view._save_fail = nil
  check(view.save_video() and pal.read_file(path) ~= "known-good-video",
        "video: retry publishes complete options")
  pal.write_file(access_path, "known-good-display")
  view._access_save_fail = { _fail = "rename" }
  local aok, aerr = view.save_accessibility()
  check(not aok and type(aerr) == "string"
        and pal.read_file(access_path) == "known-good-display",
        "display: interrupted accessibility save preserves previous file")
  view._access_save_fail = nil
  check(view.save_accessibility()
        and pal.read_file(access_path) ~= "known-good-display",
        "display: retry publishes complete accessibility options")
  local access = cm.require("cm.state").parse(pal.read_file(access_path))
  check(access.editor_scale == 1.5 and access.chrome_scale == 2
        and access.access_auto == false,
        "display: accessibility scales persist as per-user options")
  local bad_scale = view.set_editor_scale(99)
  check(bad_scale == nil and view.cfg.editor_scale == 1.5,
        "display: invalid accessibility scale cannot poison saved settings")
  view.cfg.editor_scale, view.cfg.chrome_scale, view.cfg.access_auto =
    old_editor_scale, old_chrome_scale, old_access_auto
  view.access_resolved, view._access_path, view._access_save_fail =
    old_access_resolved, old_access_path, old_access_save_fail
  cm.main.args.project = old_project
end

-- ---- cm.ui: the two mouse spaces (M8.4) ----
-- gx/gy is always game-space (the editor's world placement); mx/my is the
-- panel hit-test space — ui-canvas px when the editor owns the chrome
-- (M.ui_space), else game px (dev panels overlay the full-window game).
local function t_uispace()
  local ui = cm.require("cm.ui")
  local was = ui.ui_space
  ui.ui_space = true
  ui.frame({ { type = "motion", x = 10, y = 20, ui_x = 5, ui_y = 8 } })
  check(ui.inp.mx == 5 and ui.inp.my == 8, "ui_space: mx/my take ui_x/ui_y")
  check(ui.inp.gx == 10 and ui.inp.gy == 20, "ui_space: gx/gy stay game x/y")
  ui.ui_space = false
  ui.frame({ { type = "motion", x = 11, y = 22, ui_x = 5, ui_y = 8 } })
  check(ui.inp.mx == 11 and ui.inp.my == 22, "no ui layer: mx/my = game x/y")
  check(ui.inp.gx == 11 and ui.inp.gy == 22, "no ui layer: gx/gy = game x/y")
  ui.ui_space = was
end

-- ---- the ig surface absence contract (R2/D049) ----
-- Plain headless sessions must never initialize imgui: x_ig_frame returns
-- nil, every other x_ig_* call is a safe no-op, and pal.x_clipboard never
-- errors. (This runs BEFORE t_capture: once a capture target exists ig
-- *could* initialize, and the unavailability latch is per-process.)
local function t_ig_absence()
  check(pal.x_ig_frame() == nil, "ig: x_ig_frame is nil in plain headless")
  local ok = pcall(function()
    pal.x_ig_text(0, 0, 16, 0xffffffff, "nope")
    pal.x_ig_rect(0, 0, 10, 10, 0xffffffff)
    pal.x_ig_rect_fill(0, 0, 10, 10, 0xffffffff)
    pal.x_ig_line(0, 0, 5, 5, 0xffffffff)
    pal.x_ig_circle(3, 3, 2, 0xffffffff)
    pal.x_ig_poly({ 0, 0, 4, 0, 4, 4 }, 0xffffffff)
    pal.x_ig_image(0, 0, 0, 8, 8)
    pal.x_ig_clip_push(0, 0, 4, 4)
    pal.x_ig_clip_pop()
    pal.x_ig_mouse(false)
    pal.x_ig_mouse(true)
    pal.x_ig_overlay(true)
    pal.x_ig_overlay(false)
  end)
  check(ok, "ig: drawlist calls outside a frame are safe no-ops")
  check(pal.x_ig_edit { id = "t", x = 0, y = 0, w = 10, h = 10, text = "x" }
        == nil, "ig: x_ig_edit outside a frame returns nil")
  check(pal.x_ig_text_size("abc", 16) == nil,
        "ig: text_size is nil while ig is unavailable")
  check(type(pal.x_clipboard()) == "string", "x_clipboard reads a string")

  -- raw window-px mouse (v7): cm.ui keeps wx/wy from events, falling back to
  -- game x/y when a synthetic event omits them
  local ui = cm.require("cm.ui")
  ui.frame({ { type = "motion", x = 3, y = 4, wx = 30, wy = 40 } })
  check(ui.inp.wx == 30 and ui.inp.wy == 40, "ui: wx/wy taken from the event")
  ui.frame({ { type = "motion", x = 7, y = 8 } })
  check(ui.inp.wx == 7 and ui.inp.wy == 8, "ui: wx/wy fall back to game x/y")
end

-- ---- cm.view: the D036 resize ladder (M8.3) ----
-- Pure window->FOV math; locks every rung the human specified. Render-only
-- policy, so it is safe to compute headless (it just doesn't get applied).
local function t_ladder()
  local view = cm.require("cm.view")
  -- the rungs below are the human-specified 480x270@2x model; boot seeds
  -- cfg from the PROJECT design res now (D054/R7 — selftest is 64x64), so
  -- pin the classic cfg for the formula check and restore after
  local keep = { view.cfg.ref_w, view.cfg.ref_h, view.cfg.base_scale }
  view.cfg.ref_w, view.cfg.ref_h, view.cfg.base_scale = 480, 270, 2
  check(keep[1] == 64 and keep[2] == 64,
        "view: boot adopted the project design res as the ladder ref")
  local function rung(W, H, ew, eh, es, label)
    local fw, fh, s = view.ladder(W, H)
    check(fw == ew and fh == eh and s == es,
      ("ladder %dx%d -> %dx%d@%d (got %dx%d@%d) [%s]")
      :format(W, H, ew, eh, es, fw, fh, s, label))
  end
  -- max-of-fits + hard-cap at the reference: fills the common cases, never
  -- exceeds 480x270 (so the render never bleeds past the level's edges)
  rung(960, 540, 480, 270, 2, "reference 2x")
  rung(1920, 1080, 480, 270, 4, "full FOV at 4x, fills")
  rung(1920, 1040, 480, 260, 4, "maximized 16:9: fills, a few less px of FOV")
  rung(1280, 720, 480, 270, 2, "capped at the reference (no bleed; letterboxed)")
  rung(720, 540, 360, 270, 2, "4:3 cropped width, fills")
  rung(640, 360, 320, 180, 2, "smallest, cropped both ways")
  rung(480, 360, 240, 180, 2, "narrow, cropped both ways")
  rung(1548, 994, 480, 270, 3, "editor avail @1080p: capped, centered")
  rung(588, 514, 294, 257, 2, "editor avail @960x600: cropped below the ref")
  view.cfg.ref_w, view.cfg.ref_h, view.cfg.base_scale =
    keep[1], keep[2], keep[3]
end

-- ---- pal.x_capture: headless composite readback (M8.4) ----
-- The composite (game viewport + ui canvas) only lives in the swapchain;
-- x_capture renders it into an offscreen target so a headless --shot (and this
-- test) can see the editor-around-game layering. Also guards the headless blit
-- pipeline (the bug where pipe_blit was only built for a window).
local function t_capture()
  pal.x_fov(100, 100)
  pal.x_ui_target(200, 200)
  pal.x_capture(200, 200)
  pal.x_compose({ x = 50, y = 50, scale = 1, ui_scale = 1 }) -- game at (50,50)
  pal.begin_frame(0, 0, 0, 1)
  pal.quad(0, 0, 100, 100, 1, 0, 0, 1)  -- game target: fill red
  pal.x_target("ui")
  pal.quad(0, 0, 200, 20, 0, 1, 0, 1)   -- ui canvas: a green bar across the top
  pal.x_target("game")
  pal.present()
  local s, w, h = pal.x_capture_read()
  check(w == 200 and h == 200 and #s == 200 * 200 * 4, "capture: 200x200 RGBA")
  local function px(x, y)
    local i = (y * 200 + x) * 4
    return s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
  end
  local r, g = px(100, 100)        -- inside the game viewport (50,50..150,150)
  check(r == 255 and g == 0, "capture: game shows red in the viewport rect")
  local r2, g2 = px(5, 5)          -- outside the game, under the green ui bar
  check(r2 == 0 and g2 == 255, "capture: ui bar composites over the top")
  local r3, g3, b3 = px(5, 100)    -- left edge below the bar: transparent -> black
  check(r3 == 0 and g3 == 0 and b3 == 0, "capture: transparent ui shows through")

  -- x_compose{scale=0} (v7/D049): the game layer is NOT blitted (the ig-canvas
  -- editor draws the game target itself); the ui layer still composites
  pal.x_compose({ x = 50, y = 50, scale = 0, ui_scale = 1 })
  pal.begin_frame(0, 0, 0, 1)
  pal.quad(0, 0, 100, 100, 1, 0, 0, 1)  -- game target: red (must not appear)
  pal.x_target("ui")
  pal.quad(0, 0, 200, 20, 0, 1, 0, 1)   -- ui bar: still composites
  pal.x_target("game")
  pal.present()
  s = pal.x_capture_read()
  local rh, gh = px(100, 100)      -- where the game viewport WOULD be
  check(rh == 0 and gh == 0, "compose scale=0: game layer not blitted")
  local rb, gb = px(5, 5)
  check(rb == 0 and gb == 255, "compose scale=0: ui layer still composites")

  pal.x_capture(0, 0)
  pal.x_ui_target(0, 0)
  pal.x_compose()
  pal.x_fov(64, 64)

  -- tex_update (api6): in-place re-upload. true when the size matches the slot,
  -- false when it differs or the id is free (caller then recreates).
  local px4 = string.rep("\0", 4 * 4 * 4)
  local tid = pal.tex_create(4, 4, px4)
  local b = pal.buf(nil, 8 * 8 * 4) -- big enough for both probes below
  check(pal.tex_update(tid, b, 4, 4) == true, "tex_update: same size updates in place")
  check(pal.tex_update(tid, b, 8, 8) == false, "tex_update: size change refuses (recreate)")
  pal.tex_free(tid)
  check(pal.tex_update(tid, b, 4, 4) == false, "tex_update: freed slot refuses")
end

-- ---- cm.paint: the studio's pure no-AA rasterizers (M10, D040) ----
-- Dev/render class (never sim state), but pure functions of their inputs, so
-- KATs pin them: a line is a line, a fill is a fill. Pixels are packed RGBA8
-- u32 (R the low byte).
local function t_paint()
  local paint = cm.require("cm.paint")
  local RED, GRN = paint.pack(255, 0, 0), paint.pack(0, 255, 0)

  -- packing: R is the low byte (matches tex_create's RGBA order)
  check(RED == 0xFF0000FF, "paint: pack RGBA byte order (R low)")
  local r, g, b, a = paint.unpack(paint.pack(0, 0, 255, 128))
  check(r == 0 and g == 0 and b == 255 and a == 128, "paint: unpack")

  local function count(im, c)
    local n = 0
    for y = 0, im.h - 1 do
      for x = 0, im.w - 1 do if paint.get(im, x, y) == c then n = n + 1 end end
    end
    return n
  end

  local img = paint.image(8, 8)
  check(paint.get(img, 0, 0) == 0, "paint: new image is transparent")
  paint.set(img, 3, 4, RED)
  check(paint.get(img, 3, 4) == RED, "paint: set/get")
  paint.set(img, -1, 0, RED); paint.set(img, 99, 0, RED) -- OOB no-op
  check(paint.get(img, -1, 0) == 0 and paint.get(img, 99, 0) == 0,
        "paint: set/get clip OOB")
  paint.fill(img, GRN)
  check(count(img, GRN) == 64, "paint: fill")
  paint.fill(img, 0)

  -- lines: endpoints inclusive, expected lengths
  paint.line(img, 1, 2, 5, 2, RED)
  check(count(img, RED) == 5 and paint.get(img, 1, 2) == RED
        and paint.get(img, 5, 2) == RED, "paint: horizontal line")
  paint.fill(img, 0)
  paint.line(img, 0, 0, 7, 7, RED)
  check(count(img, RED) == 8 and paint.get(img, 3, 3) == RED,
        "paint: diagonal line")
  paint.fill(img, 0)

  -- rect: hollow perimeter vs solid area
  paint.rect(img, 1, 1, 5, 4, RED, false)
  check(count(img, RED) == 14 and paint.get(img, 3, 2) == 0,
        "paint: rect outline (perimeter, hollow)")
  paint.fill(img, 0)
  paint.rect(img, 1, 1, 5, 4, RED, true)
  check(count(img, RED) == 20, "paint: rect filled area")

  -- ellipse: center set, bbox corners missed, horizontally symmetric
  local big = paint.image(16, 16)
  paint.ellipse(big, 1, 1, 14, 14, RED, true)
  check(paint.get(big, 7, 7) == RED and paint.get(big, 2, 7) == RED,
        "paint: ellipse center + left extent filled")
  check(paint.get(big, 1, 1) == 0 and paint.get(big, 14, 14) == 0,
        "paint: ellipse misses bbox corners")
  local sym = true
  for y = 0, 15 do
    for x = 0, 15 do
      if (paint.get(big, x, y) ~= 0) ~= (paint.get(big, 15 - x, y) ~= 0) then
        sym = false
      end
    end
  end
  check(sym, "paint: ellipse horizontally symmetric")

  -- flood: exact-match, bounded by a wall, same-color no-op
  local fl = paint.image(8, 8)
  paint.rect(fl, 1, 1, 6, 6, RED, false) -- hollow box; interior 4x4
  paint.flood(fl, 3, 3, GRN)
  check(paint.get(fl, 3, 3) == GRN and count(fl, GRN) == 16,
        "paint: flood fills the bounded interior")
  check(paint.get(fl, 0, 0) == 0 and paint.get(fl, 1, 1) == RED,
        "paint: flood stops at the wall, no leak")
  paint.flood(fl, 3, 3, GRN) -- same color: must not loop
  check(count(fl, GRN) == 16, "paint: flood same-color no-op")

  -- over: 50% red over opaque green blends; a=0 no-ops
  local ov = paint.image(2, 1)
  paint.set(ov, 0, 0, GRN)
  paint.over(ov, 0, 0, paint.pack(255, 0, 0, 128))
  local rr, gg, _, aa = paint.unpack(paint.get(ov, 0, 0))
  check(aa == 255 and rr > 120 and rr < 135 and gg > 120 and gg < 135,
        "paint: over blends 50% (" .. rr .. "," .. gg .. "," .. aa .. ")")
  paint.over(ov, 1, 0, 0)
  check(paint.get(ov, 1, 0) == 0, "paint: over a=0 no-op")

  -- flips on an asymmetric mark
  local fp = paint.image(4, 4)
  paint.set(fp, 0, 0, RED)
  paint.flip_h(fp)
  check(paint.get(fp, 3, 0) == RED and paint.get(fp, 0, 0) == 0, "paint: flip_h")
  paint.flip_v(fp)
  check(paint.get(fp, 3, 3) == RED, "paint: flip_v")

  -- rotate90: dims swap, corner maps right (CW (0,0)->(h-1,0); CCW ->(0,w-1))
  local ra = paint.image(4, 2)
  paint.set(ra, 0, 0, RED)
  local cw = paint.rotate90(ra, 1)
  check(cw.w == 2 and cw.h == 4 and paint.get(cw, 1, 0) == RED,
        "paint: rotate90 CW")
  check(paint.get(paint.rotate90(ra, -1), 0, 3) == RED, "paint: rotate90 CCW")

  -- scale: nearest-neighbour, blocks replicate up / decimate down (no AA)
  local su = paint.image(2, 2)
  paint.set(su, 0, 0, RED); paint.set(su, 1, 1, GRN)
  local up = paint.scale(su, 4, 4)
  check(up.w == 4 and up.h == 4 and paint.get(up, 0, 0) == RED
        and paint.get(up, 1, 1) == RED and paint.get(up, 3, 3) == GRN,
        "paint: scale 2x replicates blocks")
  local dn = paint.scale(up, 2, 2)
  check(dn.w == 2 and paint.get(dn, 0, 0) == RED and paint.get(dn, 1, 1) == GRN,
        "paint: scale down decimates")

  -- blit stamp respects transparency
  local src = paint.image(2, 2)
  paint.set(src, 0, 0, RED) -- one opaque texel
  local dst = paint.image(4, 4)
  paint.fill(dst, GRN)
  paint.blit(dst, 1, 1, src, 0, 0, 2, 2, "stamp")
  check(paint.get(dst, 1, 1) == RED and paint.get(dst, 2, 2) == GRN,
        "paint: blit stamp copies opaque, skips transparent")

  -- copy_region lifts a rectangle into a fresh image, OOB reads transparent
  local cr = paint.image(4, 4)
  paint.set(cr, 1, 1, RED); paint.set(cr, 2, 1, GRN)
  local reg = paint.copy_region(cr, 1, 1, 2, 2)
  check(reg.w == 2 and reg.h == 2 and paint.get(reg, 0, 0) == RED
        and paint.get(reg, 1, 0) == GRN and paint.get(reg, 0, 1) == 0,
        "paint: copy_region grabs the rect")
  local oob = paint.copy_region(cr, 3, 3, 2, 2) -- partly outside
  check(oob.w == 2 and paint.get(oob, 1, 1) == 0, "paint: copy_region OOB is clear")

  -- HSV <-> RGB (the color picker's math)
  check(paint.hsv(0, 1, 1) == RED and paint.hsv(1 / 3, 1, 1) == GRN
        and paint.hsv(2 / 3, 1, 1) == paint.pack(0, 0, 255), "paint: hsv primaries")
  check(paint.hsv(0, 0, 1) == paint.pack(255, 255, 255), "paint: hsv white")
  local hh, ss, vv = paint.to_hsv(RED)
  check(hh == 0 and ss == 1 and vv == 1, "paint: to_hsv red")
  local c = paint.pack(200, 120, 40)
  local rh, rs, rv = paint.to_hsv(c)
  check(paint.hsv(rh, rs, rv) == c, "paint: hsv round-trip")

  -- write-clip (the studio's "selection restricts editing"): set/over/flood only
  -- touch the clip rect; clip_off restores; composite-class ops are off by default
  local cl = paint.image(6, 6)
  paint.set_clip(2, 2, 5, 5) -- half-open [2,5)×[2,5)
  paint.set(cl, 0, 0, RED)   -- outside → ignored
  paint.set(cl, 3, 3, RED)   -- inside → written
  check(paint.get(cl, 0, 0) == 0 and paint.get(cl, 3, 3) == RED,
        "paint: set respects the write-clip")
  paint.rect(cl, 0, 0, 6, 6, GRN, true) -- a full-rect fill, clipped to [2,5)²
  local n = 0
  for yy = 0, 5 do for xx = 0, 5 do if paint.get(cl, xx, yy) == GRN then n = n + 1 end end end
  check(n == 9, "paint: rect/line writes clip to the rect (3x3)")
  paint.clip_off()
  paint.set(cl, 0, 0, RED)
  check(paint.get(cl, 0, 0) == RED, "paint: clip_off restores full writes")
  -- flood stays inside the clip (a clipped-out pixel bounds the fill)
  local fl = paint.image(6, 6) -- all transparent (one connected region)
  paint.set_clip(0, 0, 3, 6)   -- left half only
  paint.flood(fl, 1, 1, RED)
  paint.clip_off()
  check(paint.get(fl, 1, 1) == RED and paint.get(fl, 4, 1) == 0,
        "paint: flood stays inside the write-clip")

  -- the C primitives (api6): buf:fill32 + pal.blit32. paint.fill/blit route here,
  -- so the rasterizer KATs above already exercise them — these pin the contract
  -- directly: 32-bit fill, the three modes, opacity, edge clipping, and that the
  -- src-over math is byte-identical to the Lua paint.over (the bake must not shift).
  local f32 = paint.image(4, 4)
  f32.buf:fill32(0, 16, RED)
  check(count(f32, RED) == 16, "paint: buf:fill32 writes u32s")
  -- blit32 copy / stamp / over via paint.blit (clip off → C path)
  local src = paint.image(2, 2)
  paint.set(src, 0, 0, RED); paint.set(src, 1, 1, GRN) -- two opaque, two clear
  local dc = paint.image(4, 4); paint.blit(dc, 1, 1, src, 0, 0, 2, 2, "set")
  check(paint.get(dc, 1, 1) == RED and paint.get(dc, 2, 1) == 0
        and paint.get(dc, 2, 2) == GRN, "paint: blit32 copy places + clears")
  local ds = paint.image(4, 4); paint.fill(ds, RED)
  paint.blit(ds, 0, 0, src, 0, 0, 2, 2, "stamp") -- only the opaque src pixels land
  check(paint.get(ds, 0, 0) == RED and paint.get(ds, 1, 0) == RED
        and paint.get(ds, 1, 1) == GRN, "paint: blit32 stamp skips transparent src")
  -- over math parity: half-alpha white over opaque red == cm.paint.over's result
  local half = paint.pack(255, 255, 255, 128)
  local ref = paint.image(1, 1); paint.set(ref, 0, 0, RED); paint.over(ref, 0, 0, half)
  local hb = paint.image(1, 1); paint.set(hb, 0, 0, RED)
  local hs = paint.image(1, 1); paint.set(hs, 0, 0, half)
  pal.blit32(hb.buf, 1, 1, 0, 0, hs.buf, 1, 1, 0, 0, 1, 1, 1, 255) -- mode 1 = over
  check(paint.get(hb, 0, 0) == paint.get(ref, 0, 0), "paint: blit32 over == paint.over")
  -- opacity scales source alpha (op=128 over transparent dst → alpha 128)
  local ob = paint.image(1, 1); local os = paint.image(1, 1); paint.set(os, 0, 0, RED)
  pal.blit32(ob.buf, 1, 1, 0, 0, os.buf, 1, 1, 0, 0, 1, 1, 1, 128)
  check(((paint.get(ob, 0, 0) >> 24) & 255) == 128, "paint: blit32 opacity scales src alpha")
  -- negative destination offset clips at the edge (no OOB write/crash): only
  -- src(1,1)=GRN lands at dst(0,0); the other three fall off the top-left.
  local ec = paint.image(4, 4); paint.blit(ec, -1, -1, src, 0, 0, 2, 2, "set")
  check(paint.get(ec, 0, 0) == GRN and paint.get(ec, 1, 1) == 0,
        "paint: blit32 clips a negative dst offset")

  -- curve (cubic Bézier, the MS-Paint tool): controls at the chord's thirds make
  -- it the exact straight line; a pulled control bows the path off the chord;
  -- the endpoints are always plotted. A 45° curve is a CLEAN 1px diagonal — one
  -- pixel per step, no staircase (corner-removal drops the L-corners).
  local cvl = paint.image(10, 10)
  paint.curve(cvl, 0, 0, 3, 3, 6, 6, 9, 9, RED) -- collinear thirds == diagonal
  local don, doff = 0, 0
  for d = 0, 9 do if paint.get(cvl, d, d) == RED then don = don + 1 end end
  for y = 0, 9 do for x = 0, 9 do
    if x ~= y and paint.get(cvl, x, y) == RED then doff = doff + 1 end
  end end
  check(don == 10 and doff == 0, "paint: curve is a clean 1px diagonal (no staircase)")
  local cvb = paint.image(16, 16)
  paint.curve(cvb, 0, 15, 5, 0, 10, 0, 15, 15, RED) -- pull the middle up
  check(paint.get(cvb, 0, 15) == RED and paint.get(cvb, 15, 15) == RED,
        "paint: curve plots both endpoints")
  local bowed = false
  for x = 0, 15 do if paint.get(cvb, x, 4) == RED then bowed = true end end
  check(bowed, "paint: curve bows toward its control points")
end

-- ---- cm.paint.brush: the sprite ed's size/shape/opacity pen — classic
-- pixel-disc footprints, opacity once per gesture via the seen set,
-- rgba==0 erases (op<1 fades the existing alpha) ----
local function t_brush()
  local paint = cm.require("cm.paint")
  local RED = paint.pack(255, 0, 0)
  local function count(im)
    local n = 0
    for y = 0, im.h - 1 do
      for x = 0, im.w - 1 do
        if paint.get(im, x, y) ~= 0 then n = n + 1 end
      end
    end
    return n
  end
  local function stamp(size, shape)
    local im = paint.image(9, 9)
    paint.brush(size, shape, 1, {})(im, 4, 4, RED)
    return im
  end
  -- footprints: 1 = the pixel, 2 = the 2x2 block, 3 = the plus,
  -- 4 = the 12px disc; square 3 = the full block
  local s1 = stamp(1, "circle")
  check(count(s1) == 1 and paint.get(s1, 4, 4) == RED,
        "brush: size 1 = one pixel")
  check(count(stamp(2, "circle")) == 4, "brush: size 2 = the 2x2 block")
  local p3 = stamp(3, "circle")
  check(count(p3) == 5 and paint.get(p3, 3, 3) == 0
        and paint.get(p3, 4, 3) == RED, "brush: size 3 circle is the plus")
  check(count(stamp(4, "circle")) == 12,
        "brush: size 4 circle is the 12px disc")
  check(count(stamp(3, "square")) == 9, "brush: size 3 square is the block")
  -- through M.line: a size-3 square drag sweeps the 3-tall band
  local ln = paint.image(9, 9)
  paint.line(ln, 2, 4, 6, 4, RED, paint.brush(3, "square", 1, {}))
  check(paint.get(ln, 1, 3) == RED and paint.get(ln, 7, 5) == RED
        and count(ln) == 21, "brush: line sweeps the footprint")
  -- opacity applies ONCE per gesture: re-crossing under one seen set is
  -- a no-op; a fresh gesture composites again
  local seen = {}
  local op1 = paint.image(3, 3)
  local plot = paint.brush(1, "circle", 0.5, seen)
  plot(op1, 1, 1, RED)
  local a1 = (paint.get(op1, 1, 1) >> 24) & 255
  plot(op1, 1, 1, RED)
  local a2 = (paint.get(op1, 1, 1) >> 24) & 255
  check(a1 == 128 and a2 == 128, "brush: opacity once per gesture")
  paint.brush(1, "circle", 0.5, {})(op1, 1, 1, RED)
  check(((paint.get(op1, 1, 1) >> 24) & 255) > 128,
        "brush: a new gesture blends again")
  -- the eraser: rgba==0 clears at op 1, fades alpha at op < 1
  local er = paint.image(3, 3)
  paint.set(er, 1, 1, RED)
  paint.brush(1, "circle", 0.5, {})(er, 1, 1, 0)
  check(((paint.get(er, 1, 1) >> 24) & 255) == 128,
        "brush: erase at op .5 fades the alpha")
  check((paint.get(er, 1, 1) & 0xffffff) == (RED & 0xffffff),
        "brush: a faded pixel keeps its color")
  paint.brush(1, "circle", 1, {})(er, 1, 1, 0)
  check(paint.get(er, 1, 1) == 0, "brush: erase at op 1 clears")
end

-- ---- cm.paint gradients: eval + ordered dither (M10 Phase 3, STUDIO.md §6) ----
local function t_grad()
  local paint = cm.require("cm.paint")
  local BLK, WHT = paint.pack(0, 0, 0), paint.pack(255, 255, 255)
  local RED, GRN, BLU = paint.pack(255, 0, 0), paint.pack(0, 255, 0), paint.pack(0, 0, 255)

  -- lerp_rgba: midpoint + alpha lerp
  check(paint.lerp_rgba(BLK, WHT, 0.5) == paint.pack(128, 128, 128),
        "grad: lerp_rgba midpoint")
  check(paint.lerp_rgba(BLK, WHT, 0) == BLK and paint.lerp_rgba(BLK, WHT, 1) == WHT,
        "grad: lerp_rgba endpoints")
  check(paint.lerp_rgba(paint.pack(0, 0, 0, 0), paint.pack(0, 0, 0, 255), 0.5)
        == paint.pack(0, 0, 0, 128), "grad: lerp_rgba alpha")

  -- ramp: multi-stop sampling, clamped past the ends
  local two = { { pos = 0, rgba = BLK }, { pos = 1, rgba = WHT } }
  check(paint.ramp(two, 0) == BLK and paint.ramp(two, 1) == WHT
        and paint.ramp(two, 0.5) == paint.pack(128, 128, 128), "grad: ramp 2-stop")
  check(paint.ramp(two, -1) == BLK and paint.ramp(two, 2) == WHT, "grad: ramp clamps ends")
  local tri = { { pos = 0, rgba = RED }, { pos = 0.5, rgba = GRN }, { pos = 1, rgba = BLU } }
  check(paint.ramp(tri, 0.5) == GRN and paint.ramp(tri, 0.25) == paint.pack(128, 128, 0),
        "grad: ramp 3-stop interpolates within a segment")

  -- bayer: known thresholds + the cell tiles (period = size)
  check(paint.bayer(2, 0, 0) == 0.5 / 4 and paint.bayer(2, 1, 0) == 2.5 / 4,
        "grad: bayer 2x2 entries")
  check(paint.bayer(4, 0, 0) == 0.5 / 16, "grad: bayer 4x4 origin")
  check(paint.bayer(4, 4, 4) == paint.bayer(4, 0, 0)
        and paint.bayer(8, 8, 3) == paint.bayer(8, 0, 3), "grad: bayer tiles by size")

  -- grad_t: linear projection, radial distance ratio, angular quarter-turns
  check(paint.grad_t("linear", 0, 0, 0, 0, 10, 0) == 0
        and paint.grad_t("linear", 10, 0, 0, 0, 10, 0) == 1
        and paint.grad_t("linear", 5, 0, 0, 0, 10, 0) == 0.5
        and paint.grad_t("linear", -5, 0, 0, 0, 10, 0) == -0.5, "grad: grad_t linear")
  check(paint.grad_t("radial", 0, 0, 0, 0, 0, 10) == 0
        and paint.grad_t("radial", 6, 8, 0, 0, 0, 10) == 1
        and paint.grad_t("radial", 0, 5, 0, 0, 0, 10) == 0.5, "grad: grad_t radial")
  local function near(a, b) return math.abs(a - b) < 1e-6 end
  check(near(paint.grad_t("angular", 10, 0, 0, 0, 10, 0), 0)
        and near(paint.grad_t("angular", 0, 10, 0, 0, 10, 0), 0.25)
        and near(paint.grad_t("angular", 0, -10, 0, 0, 10, 0), 0.75), "grad: grad_t angular")

  -- dither_t: strength 0 snaps to nearest band; strength 1 dithers by threshold
  check(paint.dither_t(0, 2, 0, 0.5) == 0 and paint.dither_t(1, 2, 0, 0.5) == 1,
        "grad: dither_t band endpoints")
  check(paint.dither_t(0.3, 2, 0, 0.1) == 0 and paint.dither_t(0.7, 2, 0, 0.9) == 1,
        "grad: dither_t strength 0 = hard band (threshold-independent)")
  check(paint.dither_t(0.3, 2, 1, 0.125) == 1 and paint.dither_t(0.3, 2, 1, 0.625) == 0,
        "grad: dither_t strength 1 dithers around the threshold")
  check(paint.dither_t(0.5, 5, 0, 0.5) == 0.5, "grad: dither_t lands on a mid band")

  -- grad_shade: a 5-wide BLACK→WHITE linear, 2 bands, no dither — a clean split
  local lin = { type = "linear", p0 = { x = 0, y = 0 }, p1 = { x = 4, y = 0 },
                stops = two, levels = 2, dither = 0, bayer = 2, phase = 0 }
  check(paint.grad_shade(lin, 0, 0) == BLK and paint.grad_shade(lin, 4, 0) == WHT
        and paint.grad_shade(lin, 1, 0) == BLK and paint.grad_shade(lin, 3, 0) == WHT,
        "grad: grad_shade hard 2-band split")
  -- phase slides the ramp along the axis (here +0.5 pushes the split earlier)
  lin.phase = 0.5
  check(paint.grad_shade(lin, 0, 0) == WHT, "grad: phase slides the ramp")
  lin.phase = 0

  -- grad_fill masks to the source alpha, preserving each pixel's coverage
  local mask = paint.image(4, 1)
  paint.set(mask, 0, 0, RED); paint.set(mask, 3, 0, paint.pack(0, 255, 0, 128))
  local fill3 = { type = "linear", p0 = { x = 0, y = 0 }, p1 = { x = 3, y = 0 },
                  stops = two, levels = 2, dither = 0, bayer = 2, phase = 0 }
  local outg = paint.image(4, 1)
  paint.grad_fill(outg, fill3, mask)
  check(paint.get(outg, 0, 0) == paint.pack(0, 0, 0, 255), "grad: grad_fill recolors masked px (opaque)")
  check(paint.get(outg, 1, 0) == 0 and paint.get(outg, 2, 0) == 0, "grad: grad_fill skips unmasked px")
  check(paint.get(outg, 3, 0) == paint.pack(255, 255, 255, 128), "grad: grad_fill keeps the mask alpha")
end

-- ---- cm.paint: procedural value fields (fills that generate; D141) ----
local function t_procfill()
  local paint = cm.require("cm.paint")
  local BLK, WHT = paint.pack(0, 0, 0), paint.pack(255, 255, 255)
  local two = { { pos = 0, rgba = BLK }, { pos = 1, rgba = WHT } }
  local TYPES = { "noise", "fbm", "ridged", "cells", "shards", "facets" }

  check(paint.is_proc("fbm") and paint.is_proc("facets")
        and not paint.is_proc("linear") and not paint.is_proc("radial"),
        "proc: is_proc routes the six fields, not the gradients")

  -- every field: in range, deterministic (same call = same value), and
  -- seed-sensitive (a reseed actually moves the field)
  for _, ty in ipairs(TYPES) do
    local f = { type = ty, p0 = { x = 0, y = 0 }, p1 = { x = 8, y = 0 },
                seed = 1, scale = 4, oct = 3 }
    local ok_range, moved = true, false
    for y = 0, 7 do
      for x = 0, 7 do
        local t = paint.proc_t(f, x, y)
        if t < 0 or t > 1 then ok_range = false end
        if t ~= paint.proc_t(f, x, y) then ok_range = false end
        local t2 = paint.proc_t({ type = ty, p0 = f.p0, p1 = f.p1,
                                  seed = 99, scale = 4, oct = 3 }, x, y)
        if t2 ~= t then moved = true end
      end
    end
    check(ok_range, "proc: " .. ty .. " in [0,1] + repeatable")
    check(moved, "proc: " .. ty .. " reseed moves the field")
  end

  -- p0 is a pure translation of the field
  local fa = { type = "fbm", p0 = { x = 0, y = 0 }, seed = 5, scale = 4, oct = 4 }
  local fb = { type = "fbm", p0 = { x = 3, y = 2 }, seed = 5, scale = 4, oct = 4 }
  check(paint.proc_t(fa, 1, 1) == paint.proc_t(fb, 4, 3),
        "proc: p0 translates the field exactly")

  -- facets is FLAT inside a cell: at a huge scale every canvas px shares one
  -- Worley cell, so the tone is constant (the crystal-facet read)
  local ff = { type = "facets", p0 = { x = 0, y = 0 }, seed = 2, scale = 1000 }
  check(paint.proc_t(ff, 0, 0) == paint.proc_t(ff, 7, 5),
        "proc: facets flat per cell")

  -- a proc fill shades through the same band/ramp pipe: 2 hard bands can only
  -- ever emit exact ramp endpoint colors
  local pf = { type = "noise", p0 = { x = 0, y = 0 }, p1 = { x = 8, y = 0 },
               stops = two, levels = 2, dither = 0, bayer = 2, phase = 0,
               seed = 3, scale = 3 }
  local okc = true
  for y = 0, 5 do
    for x = 0, 5 do
      local c = paint.grad_shade(pf, x, y)
      if c ~= BLK and c ~= WHT then okc = false end
    end
  end
  check(okc, "proc: shades to exact ramp band colors")

  -- solid render: grad_fill with a nil mask writes EVERY pixel (ramp alpha)
  local img = paint.image(4, 2)
  paint.grad_fill(img, pf, nil)
  local all = true
  for y = 0, 1 do
    for x = 0, 3 do
      local c = paint.get(img, x, y)
      if c ~= BLK and c ~= WHT then all = false end
    end
  end
  check(all, "proc: solid grad_fill covers the whole canvas")
end

-- ---- cm.paint: layer blend modes (composite-time; D141) ----
local function t_blend()
  local paint = cm.require("cm.paint")
  local function img1(c)
    local i = paint.image(1, 1)
    paint.set(i, 0, 0, c)
    return i
  end
  local function bl(dstc, srcc, mode, op)
    local d = img1(dstc)
    paint.blend_blit(d, img1(srcc), mode, op or 255)
    return paint.get(d, 0, 0)
  end
  local RED = paint.pack(255, 0, 0)
  local WHT = paint.pack(255, 255, 255)
  local BLK = paint.pack(0, 0, 0)
  local GRY = paint.pack(128, 128, 128)

  check(bl(RED, WHT, "mul") == RED, "blend: mul by white is identity")
  check(bl(RED, BLK, "mul") == BLK, "blend: mul by black is black")
  check(bl(RED, GRY, "mul") == paint.pack(128, 0, 0), "blend: mul halves")
  check(bl(paint.pack(200, 0, 0), paint.pack(100, 0, 50), "add")
        == paint.pack(255, 0, 50), "blend: add clamps per channel")
  check(bl(GRY, GRY, "screen") == paint.pack(192, 192, 192), "blend: screen brightens")
  check(bl(paint.pack(64, 200, 0), GRY, "overlay")
        == paint.pack(64, 200, 0), "blend: overlay muls dark / screens light")

  -- a blend layer over TRANSPARENT backdrop degrades to normal (paints, not
  -- blackens) — the W3C backdrop-weighted source color
  check(bl(0, GRY, "mul") == GRY, "blend: over transparent = plain paint")
  -- transparent source pixels leave the backdrop untouched
  check(bl(RED, 0, "mul") == RED, "blend: transparent src skipped")
  -- layer opacity scales the source alpha before compositing: half-op white
  -- mul over opaque red keeps full coverage, color halfway red→red = red;
  -- over black it lands halfway black→black... use add for a visible mid
  check(bl(BLK, paint.pack(255, 255, 255, 255), "add", 128)
        == paint.pack(128, 128, 128), "blend: opacity scales the source")
  -- semi-alpha source composites with correct coverage: 50% white mul over
  -- opaque red → blend color red, half-covered → (191,0,0)-ish exact math:
  -- sa=128, blended src = red; out = (255*128 + 255*127+127)//255-weighted
  local out = bl(RED, paint.pack(255, 255, 255, 128), "mul")
  local r, g, b, a = paint.unpack(out)
  check(r == 255 and g == 0 and b == 0 and a == 255,
        "blend: semi-alpha mul keeps the backdrop channel math")
end

-- ---- cm.sprite: the studio document — model, .spr codec, bake, undo (M10) ----
local function t_sprite()
  local sprite = cm.require("cm.sprite")
  local paint = cm.require("cm.paint")
  local RED, GRN = paint.pack(255, 0, 0), paint.pack(0, 255, 0)

  local doc = sprite.new(8, 6)
  check(doc.w == 8 and doc.h == 6 and doc.frames == 1 and #doc.layers == 1,
        "sprite: new doc shape")
  check(#doc.palette >= 8, "sprite: default palette seeded")

  local cell = sprite.cell(doc)
  paint.set(cell, 2, 3, RED)
  paint.set(cell, 0, 0, GRN)
  local out = paint.image(8, 6)
  sprite.composite_into(doc, 1, out)
  check(paint.get(out, 2, 3) == RED and paint.get(out, 0, 0) == GRN,
        "sprite: composite one layer == the cell")

  -- a 2nd opaque layer draws over; hiding it falls back to the layer below
  local l2 = sprite.add_layer(doc, "top")
  paint.set(l2.cells[1], 2, 3, GRN)
  sprite.composite_into(doc, 1, out)
  check(paint.get(out, 2, 3) == GRN, "sprite: top layer composites over")
  l2.hidden = true
  sprite.composite_into(doc, 1, out)
  check(paint.get(out, 2, 3) == RED, "sprite: hidden layer skipped")
  l2.hidden = false

  -- .spr encode/decode round-trip preserves pixels + layers + palette
  local doc2 = sprite.decode(sprite.encode(doc))
  check(doc2.w == 8 and doc2.h == 6 and #doc2.layers == 2, "sprite: decode shape")
  check(paint.get(sprite.cell(doc2, 1, 1), 2, 3) == RED, "sprite: decode layer 1 px")
  check(paint.get(sprite.cell(doc2, 2, 1), 2, 3) == GRN, "sprite: decode layer 2 px")
  check(doc2.palette[12] == doc.palette[12], "sprite: decode palette")

  -- blend modes composite + round-trip (BLND chunk, D141)
  local WHT = paint.pack(255, 255, 255)
  paint.set(l2.cells[1], 2, 3, paint.pack(128, 128, 128))
  l2.blend = "mul"
  sprite.composite_into(doc, 1, out)
  check(paint.get(out, 2, 3) == paint.pack(128, 0, 0),
        "sprite: mul layer multiplies the backdrop")
  local docb = sprite.decode(sprite.encode(doc))
  check(docb.layers[2].blend == "mul" and docb.layers[1].blend == "normal",
        "sprite: BLND round-trips (normal stays implicit)")
  l2.blend = "normal"
  paint.set(l2.cells[1], 2, 3, GRN)

  -- procedural fill v2 round-trip (seed/scale/oct/solid ride the FILL chunk)
  local pfill = { type = "fbm", p0 = { x = 1, y = 2 }, p1 = { x = 5, y = 2 },
                  stops = { { pos = 0, rgba = RED }, { pos = 1, rgba = WHT } },
                  levels = 3, dither = 0.5, bayer = 4, phase = 0,
                  seed = 42, scale = 5, oct = 3, solid = true }
  doc.layers[1].fill = pfill
  local docf = sprite.decode(sprite.encode(doc))
  local rf = docf.layers[1].fill
  check(rf and rf.type == "fbm" and rf.seed == 42 and rf.oct == 3
        and rf.solid == true and rf.scale == 5 and #rf.stops == 2
        and rf.levels == 3, "sprite: FILL v2 round-trips the procedural fields")
  -- a solid fill composites over the whole canvas (the generated layer);
  -- both docs shade identically (the codec carried everything the shade reads)
  local o1, o2 = paint.image(8, 6), paint.image(8, 6)
  sprite.composite_into(doc, 1, o1)
  sprite.composite_into(docf, 1, o2)
  local samec = true
  for yy = 0, 5 do
    for xx = 0, 7 do
      if paint.get(o1, xx, yy) ~= paint.get(o2, xx, yy) then samec = false end
      if (paint.get(o1, xx, yy) >> 24) & 255 == 0 then samec = false end
    end
  end
  check(samec, "sprite: solid fill covers the canvas + decoded doc shades byte-identically")
  doc.layers[1].fill = nil

  -- FILL v1 (a pre-D141 file) still decodes, procedural fields defaulted
  local ch = cm.require("cm.chunk")
  local wv1 = ch.writer("CSPR")
  wv1.chunk("HEAD", 1, string.pack("<I4I4I4I4I4i4i4s2", 4, 4, 1, 1, 0, 0, 0, "v1"))
  wv1.chunk("PALT", 1, string.pack("<I4", 0))
  wv1.chunk("LAYR", 1, string.pack("<s2I1I1", "l", 255, 0)
            .. string.rep("\0", 4 * 4 * 4))
  wv1.chunk("FILL", 1, string.pack("<I4", 1)
            .. string.pack("<I4 I1 ffff ff I2 I1 I1", 1, 2, 0, 0, 3, 3,
                           0.5, 0, 3, 4, 1)
            .. string.pack("<fI4", 0, RED))
  wv1.chunk("TAIL", 1, string.pack("<I4I4", 1, 1))
  local dv1 = sprite.decode(wv1.result())
  local fv1 = dv1.layers[1].fill
  check(fv1 and fv1.type == "radial" and fv1.levels == 3 and fv1.solid == false
        and fv1.scale == 8 and fv1.oct == 4 and fv1.seed == 0,
        "sprite: FILL v1 decodes with procedural defaults")

  -- bake: flattened strip (1 frame here), top layer wins at (2,3)
  local strip = sprite.bake_image(doc)
  check(strip.w == 8 and strip.h == 6, "sprite: bake strip dims")
  check(paint.get(strip, 2, 3) == GRN, "sprite: bake flattens layers")

  -- disk round-trip + the baked PNG landing beside the .spr
  local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/cosmic_selftest_sprite.spr"
  check(sprite.save(doc, tmp) == true, "sprite: save writes")
  local doc3, err = sprite.load(tmp)
  check(doc3 and paint.get(sprite.cell(doc3, 1, 1), 2, 3) == RED,
        "sprite: load round-trip (" .. tostring(err) .. ")")
  check(pal.read_file((tmp:gsub("%.spr$", ".png"))) ~= nil, "sprite: bake png written")

  -- A save publishes one recoverable .spr/.png/.anim/.meta generation.  Every
  -- output boundary reports failure, retains the manifest, and load completes
  -- that exact generation before exposing the source.  A manifest-write
  -- failure touches no member at all.
  local tx = (os.getenv("TMPDIR") or "/tmp") .. "/cosmic_selftest_sprite_tx.spr"
  local old = sprite.new(3, 2)
  paint.set(sprite.cell(old), 0, 0, RED)
  old.clips = { { name = "old", loop = "loop",
                  frames = { { frame = 0, dur = 3 } } } }
  old.pivot = { x = 0, y = 1 }
  check(sprite.save(old, tx) == true, "sprite txn: seed generation")
  local exts = { "spr", "png", "anim", "meta" }
  local function generation(path)
    local t = {}
    for _, ext in ipairs(exts) do
      t[ext] = pal.read_file(path:gsub("%.spr$", "." .. ext))
    end
    return t
  end
  local before = generation(tx)
  local newer = sprite.new(4, 2)
  paint.set(sprite.cell(newer), 3, 1, GRN)
  newer.clips = {} -- also proves an empty .anim replaces a stale clip table
  newer.pivot = { x = 3, y = 0 }
  local ok, terr = sprite.save(newer, tx, { manifest = { _fail = "rename" } })
  check(not ok and terr:find("manifest") and pal.read_file(tx .. ".txn") == nil,
        "sprite txn: manifest failure is reported without recovery claim")
  local untouched = generation(tx)
  for _, ext in ipairs(exts) do
    check(untouched[ext] == before[ext],
          "sprite txn: manifest failure preserves ." .. ext)
  end
  for _, boundary in ipairs { "png", "anim", "meta", "spr", "cleanup" } do
    check(sprite.save(old, tx) == true, "sprite txn: reset before " .. boundary)
    local inject = {}
    inject[boundary] = boundary == "cleanup" and true or { _fail = "rename" }
    ok, terr = sprite.save(newer, tx, inject)
    local label = boundary == "cleanup" and "manifest" or boundary
    check(not ok and terr:find(label) and pal.read_file(tx .. ".txn") ~= nil,
          "sprite txn: " .. boundary .. " failure is reported + recoverable")
    local recovered, rerr = sprite.load(tx)
    check(recovered and recovered.w == 4 and recovered.pivot.x == 3,
          "sprite txn: load recovers " .. boundary .. " (" .. tostring(rerr) .. ")")
    check(pal.read_file(tx .. ".txn") == nil,
          "sprite txn: recovery clears manifest after " .. boundary)
    local clips = cm.require("cm.anim").load(tx:gsub("%.spr$", ".anim"))
    local meta = sprite.load_meta(tx:gsub("%.spr$", ".meta"))
    check(clips and #clips == 0 and meta and meta.pivot.x == 3,
          "sprite txn: recovered sidecars agree after " .. boundary)
  end

  -- pivot (Phase 5): default feet-center, round-trips the .spr HEAD + the .meta
  -- sidecar, set_pivot is one clamped undo step, and save bakes the .meta.
  local pv = sprite.new(8, 6)
  check(pv.pivot.x == 4 and pv.pivot.y == 5, "sprite: default pivot is feet-center")
  pv.pivot = { x = 3, y = 1 }
  local pv2 = sprite.decode(sprite.encode(pv))
  check(pv2.pivot.x == 3 and pv2.pivot.y == 1, "sprite: pivot round-trips the .spr HEAD")
  local mt = sprite.decode_meta(sprite.encode_meta(pv))
  check(mt and mt.pivot.x == 3 and mt.pivot.y == 1, "sprite: pivot round-trips the .meta")
  sprite.set_pivot(pv, 99, -4) -- clamps to the cell bounds
  check(pv.pivot.x == 7 and pv.pivot.y == 0, "sprite: set_pivot clamps to bounds")
  check(sprite.can_undo(pv), "sprite: set_pivot is undoable")
  sprite.undo(pv)
  check(pv.pivot.x == 3 and pv.pivot.y == 1, "sprite: undo restores the pivot")
  local n0 = #pv._undo
  sprite.set_pivot(pv, 3, 1) -- unchanged → no step
  check(#pv._undo == n0, "sprite: set_pivot no-op pushes nothing")
  check(sprite.save(pv, tmp) == true, "sprite: save (pivot) ok")
  local lm = sprite.load_meta((tmp:gsub("%.spr$", ".meta")))
  check(lm and lm.pivot.x == 3 and lm.pivot.y == 1, "sprite: save bakes the .meta sidecar")
  check(sprite.decode_meta("garbage!!") == nil, "sprite: decode_meta rejects garbage")

  -- slices (Phase 5b): add (default rect) / delete are undoable; the rect clamps;
  -- they round-trip the .spr SLCE chunk + the .meta; find_slice looks up by name.
  local sl = sprite.new(16, 10)
  local s1 = sprite.add_slice(sl, "hand")
  check(#sl.slices == 1 and s1.name == "hand", "sprite: add_slice appends")
  check(s1.w >= 1 and s1.x + s1.w <= sl.w and s1.y + s1.h <= sl.h,
        "sprite: default slice rect in bounds")
  check(sprite.can_undo(sl), "sprite: add_slice is undoable")
  sprite.set_slice_rect(sl, 1, 99, -3, 999, 4) -- clamps to the cell
  check(s1.x == 15 and s1.y == 0 and s1.x + s1.w <= 16 and s1.h == 4,
        "sprite: set_slice_rect clamps to bounds")
  sprite.undo(sl)
  check(sl.slices[1].x ~= 15, "sprite: undo restores the slice rect")
  sprite.set_slice_rect(sl, 1, 2, 3, 5, 4)
  local sl2 = sprite.decode(sprite.encode(sl))
  local g = sprite.find_slice(sl2, "hand")
  check(g and g.x == 2 and g.y == 3 and g.w == 5 and g.h == 4,
        "sprite: slice round-trips the .spr SLCE chunk")
  local mm = sprite.decode_meta(sprite.encode_meta(sl))
  local gm = sprite.find_slice(mm, "hand")
  check(gm and gm.x == 2 and gm.w == 5, "sprite: slice round-trips the .meta")
  check(sprite.find_slice(mm, "nope") == nil, "sprite: find_slice misses cleanly")
  sprite.delete_slice(sl, 1)
  check(#sl.slices == 0, "sprite: delete_slice removes")
  sprite.undo(sl)
  check(#sl.slices == 1, "sprite: undo restores the deleted slice")

  -- set_size (whole-doc resize): canvas crop/pad (anchored) or scale-resample,
  -- one undo step; the struct snapshot now carries w/h so undo restores the size.
  local rz = sprite.new(4, 4)
  paint.set(sprite.cell(rz), 0, 0, RED)   -- top-left marker
  paint.set(sprite.cell(rz), 3, 3, GRN)   -- bottom-right marker
  rz.pivot = { x = 2, y = 3 }
  sprite.add_slice(rz, "box"); sprite.set_slice_rect(rz, 1, 1, 1, 2, 2)
  local und0 = #rz._undo
  check(sprite.set_size(rz, 8, 6, { mode = "canvas", anchor = "nw" }) == true,
        "sprite: set_size returns true on a real change")
  check(rz.w == 8 and rz.h == 6, "sprite: set_size grew the doc")
  check(paint.get(sprite.cell(rz), 0, 0) == RED, "sprite: nw-anchored pixel stays put")
  check(paint.get(sprite.cell(rz), 3, 3) == GRN, "sprite: nw-anchored interior kept")
  check(paint.get(sprite.cell(rz), 7, 5) == 0, "sprite: grown margin is transparent")
  check(rz.pivot.x == 2 and rz.pivot.y == 3, "sprite: nw resize keeps pivot coords")
  check(rz.slices[1].x == 1 and rz.slices[1].w == 2, "sprite: nw resize keeps slice rect")
  check(#rz._undo == und0 + 1, "sprite: set_size is one undo step")
  -- undo restores BOTH the old size and the old pixels (the w/h-in-snapshot fix)
  sprite.undo(rz)
  check(rz.w == 4 and rz.h == 4, "sprite: undo restores the old size")
  check(paint.get(sprite.cell(rz), 3, 3) == GRN, "sprite: undo restores the old pixels")
  sprite.redo(rz)
  check(rz.w == 8 and paint.get(sprite.cell(rz), 0, 0) == RED, "sprite: redo re-applies the resize")
  local und1 = #rz._undo
  check(sprite.set_size(rz, 8, 6) == false, "sprite: set_size no-op returns false")
  check(#rz._undo == und1, "sprite: set_size no-op pushes nothing")
  -- center anchor offsets the content; the near edge is padded transparent
  local rc = sprite.new(2, 2)
  paint.set(sprite.cell(rc), 0, 0, RED)
  sprite.set_size(rc, 6, 6, { mode = "canvas", anchor = "c" }) -- offset (2,2)
  check(paint.get(sprite.cell(rc), 2, 2) == RED, "sprite: center anchor offsets content")
  check(paint.get(sprite.cell(rc), 0, 0) == 0, "sprite: center anchor pads the near edge")
  -- shrink crops a pixel outside the new bounds (nw anchor)
  local rk = sprite.new(4, 4)
  paint.set(sprite.cell(rk), 3, 3, RED)
  sprite.set_size(rk, 2, 2, { mode = "canvas", anchor = "nw" })
  check(rk.w == 2 and paint.get(sprite.cell(rk), 1, 1) == 0, "sprite: shrink crops overflow")
  -- scale mode resamples + remaps the pivot: a solid 2x2 stays solid at 4x4
  local rsz = sprite.new(2, 2)
  paint.fill(sprite.cell(rsz), RED); rsz.pivot = { x = 1, y = 1 }
  sprite.set_size(rsz, 4, 4, { mode = "scale" })
  check(rsz.w == 4 and paint.get(sprite.cell(rsz), 3, 3) == RED, "sprite: scale resamples content")
  check(rsz.pivot.x == 2 and rsz.pivot.y == 2, "sprite: scale remaps the pivot")

  -- undo / redo a stroke (the delta1 codec), and a no-op pushes nothing
  local d = sprite.new(4, 4)
  local c = sprite.cell(d)
  sprite.begin_edit(d)
  paint.set(c, 1, 1, RED); paint.set(c, 2, 2, RED)
  sprite.end_edit(d)
  check(sprite.can_undo(d) and paint.get(c, 1, 1) == RED, "sprite: stroke recorded")
  sprite.undo(d)
  check(paint.get(c, 1, 1) == 0 and paint.get(c, 2, 2) == 0, "sprite: undo reverts")
  check(sprite.can_redo(d), "sprite: redo available")
  sprite.redo(d)
  check(paint.get(c, 1, 1) == RED and paint.get(c, 2, 2) == RED, "sprite: redo reapplies")
  local n = #d._undo
  sprite.begin_edit(d); sprite.end_edit(d)
  check(#d._undo == n, "sprite: empty edit pushes no undo step")

  -- structural ops + the coarse-snapshot undo (Phase 2): add / dup / move /
  -- delete, each one undoable, snapshots carrying the pixels too.
  local s = sprite.new(4, 4)
  paint.set(sprite.cell(s, 1, 1), 0, 0, RED)
  sprite.add_layer(s)
  check(#s.layers == 2 and s.cur_layer == 2, "sprite: add_layer appends + selects")
  check(sprite.can_undo(s), "sprite: structural op is undoable")
  sprite.undo(s)
  check(#s.layers == 1, "sprite: undo add_layer")
  sprite.redo(s)
  check(#s.layers == 2, "sprite: redo add_layer")
  s.cur_layer = 1
  sprite.dup_layer(s, 1)
  check(#s.layers == 3 and s.cur_layer == 2, "sprite: dup inserts above + selects")
  check(paint.get(sprite.cell(s, 2, 1), 0, 0) == RED, "sprite: dup copies pixels")
  paint.set(sprite.cell(s, 2, 1), 0, 0, GRN)
  check(paint.get(sprite.cell(s, 1, 1), 0, 0) == RED, "sprite: dup is an independent copy")
  local top = s.layers[3]
  sprite.move_layer(s, 3, -1)
  check(s.layers[2] == top and s.cur_layer == 2, "sprite: move_layer reorders + selects")
  local before_n = #s.layers
  sprite.delete_layer(s, 1)
  check(#s.layers == before_n - 1, "sprite: delete removes a layer")
  sprite.undo(s)
  check(#s.layers == before_n and paint.get(sprite.cell(s, 1, 1), 0, 0) == RED,
        "sprite: undo delete restores the layer + its pixels")
  local one = sprite.new(2, 2)
  sprite.delete_layer(one)
  check(#one.layers == 1, "sprite: delete keeps at least one layer")
  local cap = sprite.new(2, 2)
  for _ = 1, 80 do sprite.add_layer(cap) end
  check(#cap._undo <= 64, "sprite: undo stack is capped")

  -- gradient fills (Phase 3): bound to a layer, applied at composite masked by
  -- the layer's alpha, non-destructive; set/clear/stamp undoable; .spr round-trips.
  local fd = sprite.new(4, 1)
  local fc = sprite.cell(fd)
  for px = 0, 3 do paint.set(fc, px, 0, RED) end -- a 4px opaque row (the mask)
  local two = { { pos = 0, rgba = paint.pack(0, 0, 0) },
                { pos = 1, rgba = paint.pack(255, 255, 255) } }
  sprite.set_fill(fd, 1, { type = "linear", p0 = { x = 0, y = 0 }, p1 = { x = 3, y = 0 },
                           stops = two, levels = 2, dither = 0, bayer = 2, phase = 0 })
  check(fd.layers[1].fill ~= nil and sprite.can_undo(fd), "sprite: set_fill is undoable")
  local fo = paint.image(4, 1)
  sprite.composite_into(fd, 1, fo)
  check(paint.get(fo, 0, 0) == paint.pack(0, 0, 0, 255)
        and paint.get(fo, 3, 0) == paint.pack(255, 255, 255, 255),
        "sprite: composite applies the gradient fill (band split, masked)")
  check(paint.get(fc, 0, 0) == RED, "sprite: fill leaves the layer pixels untouched")

  local fd2 = sprite.decode(sprite.encode(fd))
  local f2 = fd2.layers[1].fill
  check(f2 and f2.type == "linear" and f2.p1.x == 3 and #f2.stops == 2
        and f2.stops[2].rgba == paint.pack(255, 255, 255),
        "sprite: .spr round-trips the FILL chunk")

  sprite.stamp_fill(fd, 1)
  check(fd.layers[1].fill == nil and paint.get(fc, 3, 0) == paint.pack(255, 255, 255, 255),
        "sprite: stamp_fill bakes pixels + clears the fill")
  sprite.undo(fd) -- a structural undo swaps in snapshot cells (fc is now stale)
  check(fd.layers[1].fill ~= nil and paint.get(sprite.cell(fd), 3, 0) == RED,
        "sprite: undo stamp_fill restores pixels + the fill")

  sprite.dup_layer(fd, 1)
  check(fd.layers[2].fill ~= nil and fd.layers[2].fill ~= fd.layers[1].fill,
        "sprite: dup_layer deep-copies the fill")
  sprite.clear_fill(fd, 2)
  check(fd.layers[2].fill == nil and fd.layers[1].fill ~= nil,
        "sprite: clear_fill removes only that layer's fill")

  -- frames (Phase 4): add / dup / delete / move, each one undo step; every
  -- layer carries a cell per frame, the clip frame index is 0-based (strip col).
  local frd = sprite.new(3, 3)
  paint.set(sprite.cell(frd, 1, 1), 0, 0, RED) -- mark frame 1
  sprite.add_frame(frd)
  check(frd.frames == 2 and frd.cur_frame == 2 and #frd.layers[1].cells == 2,
        "sprite: add_frame appends a blank frame + selects it")
  check(paint.get(sprite.cell(frd, 1, 2), 0, 0) == 0, "sprite: new frame is blank")
  paint.set(sprite.cell(frd, 1, 2), 1, 1, GRN)
  sprite.dup_frame(frd, 2)
  check(frd.frames == 3 and paint.get(sprite.cell(frd, 1, 3), 1, 1) == GRN,
        "sprite: dup_frame copies pixels")
  paint.set(sprite.cell(frd, 1, 3), 1, 1, RED)
  check(paint.get(sprite.cell(frd, 1, 2), 1, 1) == GRN, "sprite: dup_frame is independent")

  -- a clip spanning the strip, then deleting a middle frame fixes its refs
  local clip = sprite.add_clip(frd, "all")
  check(#clip.frames == 3 and clip.frames[1].frame == 0 and clip.frames[3].frame == 2,
        "sprite: add_clip spans the whole strip")
  sprite.delete_frame(frd, 2) -- removes 0-based frame 1
  check(frd.frames == 2, "sprite: delete_frame removes a frame")
  check(#clip.frames == 2 and clip.frames[2].frame == 1,
        "sprite: delete_frame drops the ref + slides higher refs down")
  sprite.undo(frd) -- struct-undo restores frames AND clips
  check(frd.frames == 3 and #frd.clips[1].frames == 3 and frd.clips[1].frames[3].frame == 2,
        "sprite: undo delete_frame restores the frame and its clip refs")
  local mv = frd.layers[1].cells[1]
  sprite.move_frame(frd, 1, 1) -- frame 1 <-> 2
  check(frd.layers[1].cells[2] == mv and frd.cur_frame == 2,
        "sprite: move_frame reorders + selects")

  -- CLIP chunk .spr round-trip + the .anim sidecar from save
  local cd = sprite.new(2, 2)
  sprite.add_frame(cd)
  cd.clips = { { name = "idle", loop = "pingpong",
                 frames = { { frame = 0, dur = 7 }, { frame = 1, dur = 9 } } } }
  local c2 = sprite.decode(sprite.encode(cd)).clips[1]
  check(c2 and c2.name == "idle" and c2.loop == "pingpong" and #c2.frames == 2
        and c2.frames[2].frame == 1 and c2.frames[2].dur == 9,
        "sprite: .spr round-trips the CLIP chunk")
  local atmp = (os.getenv("TMPDIR") or "/tmp") .. "/cosmic_selftest_anim.spr"
  sprite.add_clip(cd, "extra")
  check(sprite.save(cd, atmp) == true, "sprite: save with clips ok")
  local sidecar = cm.require("cm.anim").load((atmp:gsub("%.spr$", ".anim")))
  check(sidecar and #sidecar == 2 and sidecar[1].name == "idle",
        "sprite: save writes a loadable .anim sidecar")
  sprite.delete_clip(cd, 1)
  check(#cd.clips == 1 and cd.clips[1].name == "extra", "sprite: delete_clip removes it")

  -- merge_down: flatten a layer onto the one below, then drop it (one undo step)
  local md = sprite.new(2, 2)
  paint.set(sprite.cell(md, 1, 1), 0, 0, RED) -- bottom layer
  local mtop = sprite.add_layer(md)
  paint.set(mtop.cells[1], 1, 1, GRN) -- top layer, a different pixel
  sprite.merge_down(md, 2)
  check(#md.layers == 1 and md.cur_layer == 1, "sprite: merge_down drops the top layer")
  check(paint.get(sprite.cell(md, 1, 1), 0, 0) == RED
        and paint.get(sprite.cell(md, 1, 1), 1, 1) == GRN,
        "sprite: merge_down flattens both layers")
  sprite.undo(md)
  check(#md.layers == 2 and paint.get(md.layers[2].cells[1], 1, 1) == GRN,
        "sprite: undo merge_down restores the layer")
  sprite.merge_down(md, 1) -- nothing below the bottom layer
  check(#md.layers == 2, "sprite: merge_down is a no-op for the bottom layer")
end

-- cm.anim: the pure clip evaluator (loop/once/pingpong at boundaries),
-- duration, the .anim canonical-bytes round-trip, normalization + find.
local function t_anim()
  local anim = cm.require("cm.anim")

  -- a 2-frame loop: frame 0 for 2 ticks, frame 5 for 3 ticks; total 5
  local loop = { name = "a", loop = "loop",
                 frames = { { frame = 0, dur = 2 }, { frame = 5, dur = 3 } } }
  check(anim.duration(loop) == 5, "anim: duration sums durs")
  check(anim.frame_at(loop, 0) == 0 and anim.frame_at(loop, 1) == 0,
        "anim: loop frame 0 window")
  check(anim.frame_at(loop, 2) == 5 and anim.frame_at(loop, 4) == 5,
        "anim: loop frame 1 window")
  check(anim.frame_at(loop, 5) == 0 and anim.frame_at(loop, 7) == 5,
        "anim: loop wraps at total")
  check(anim.frame_at(loop, -3) == 0, "anim: negative elapsed clamps to 0")

  -- once: play through then HOLD the final frame forever
  local once = { name = "b", loop = "once",
                 frames = { { frame = 0, dur = 2 }, { frame = 5, dur = 3 } } }
  check(anim.frame_at(once, 1) == 0 and anim.frame_at(once, 2) == 5,
        "anim: once plays through")
  check(anim.frame_at(once, 4) == 5 and anim.frame_at(once, 999) == 5,
        "anim: once holds the last frame")

  -- pingpong: A,B,C bounces as A,B,C,B (interior reversed, endpoints once)
  local pp = { name = "c", loop = "pingpong", frames = {
    { frame = 0, dur = 1 }, { frame = 1, dur = 1 }, { frame = 2, dur = 1 } } }
  local seen = {}
  for e = 0, 7 do seen[e] = anim.frame_at(pp, e) end
  check(seen[0] == 0 and seen[1] == 1 and seen[2] == 2 and seen[3] == 1
        and seen[4] == 0 and seen[5] == 1 and seen[6] == 2 and seen[7] == 1,
        "anim: pingpong bounces A,B,C,B")
  local pp2 = { loop = "pingpong",
                frames = { { frame = 0, dur = 1 }, { frame = 1, dur = 1 } } }
  check(anim.frame_at(pp2, 0) == 0 and anim.frame_at(pp2, 1) == 1
        and anim.frame_at(pp2, 2) == 0, "anim: 2-frame pingpong is a plain loop")

  -- degenerate clips
  check(anim.frame_at({ frames = {} }, 4) == 0, "anim: empty clip → 0")
  check(anim.frame_at({ frames = { { frame = 7, dur = 3 } } }, 9) == 7,
        "anim: single frame ignores elapsed")

  -- normalization: dur floored to ≥1, bad loop → loop, negative frame → 0
  local norm = anim.decode(anim.encode({
    { name = "z", loop = "bogus",
      frames = { { frame = -4, dur = 0 }, { frame = 2, dur = 3 } } } }))
  check(norm[1].loop == "loop" and norm[1].frames[1].dur == 1
        and norm[1].frames[1].frame == 0, "anim: normalize clamps loop/dur/frame")

  -- .anim canonical-bytes round-trip: decode∘encode preserves, encode is a fixpoint
  local clips = {
    { name = "idle", loop = "loop", frames = { { frame = 0, dur = 48 },
                                               { frame = 11, dur = 48 } } },
    { name = "walk", loop = "pingpong", frames = { { frame = 1, dur = 6 },
                                                   { frame = 2, dur = 6 } } } }
  local bytes = anim.encode(clips)
  local rt = anim.decode(bytes)
  check(#rt == 2 and rt[1].name == "idle" and rt[2].loop == "pingpong"
        and rt[1].frames[2].frame == 11 and rt[1].frames[2].dur == 48,
        "anim: .anim round-trip preserves clips")
  check(anim.encode(rt) == bytes, "anim: encode is a fixpoint")
  check(anim.find(rt, "walk") == rt[2] and anim.find(rt, "nope") == nil,
        "anim: find by name")
end

-- live asset hot-reload (M10 Phase 5): cm.sprite.save bumps the render-only
-- cm.asset_epoch (a running game watches it to re-load baked art), and
-- cm.gfx.texture(path, true) re-reads + refreshes the memoized texture in place,
-- keeping the old one if the re-read fails. Render-only — no determinism surface.
local function t_asset_reload()
  local sprite = cm.require("cm.sprite")
  local gfx = cm.require("cm.gfx")
  local paint = cm.require("cm.paint")
  local RED = paint.pack(255, 32, 64)
  local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/cosmic_selftest_reload.spr"
  local png = (tmp:gsub("%.spr$", ".png"))

  -- a successful save advances the epoch
  local d = sprite.new(8, 6)
  paint.set(sprite.cell(d), 0, 0, RED)
  local e0 = cm.asset_epoch or 0
  check(sprite.save(d, tmp) == true, "asset: save ok")
  check((cm.asset_epoch or 0) == e0 + 1, "asset: save bumps cm.asset_epoch")

  -- the baked strip loads; reload refreshes the SAME table after the strip grows
  local t = gfx.texture(png)
  check(t and t.id and t.w == 8 and t.h == 6, "asset: texture loads the baked strip")
  sprite.add_frame(d) -- two frames now → the strip doubles to 16 wide
  check(sprite.save(d, tmp) == true, "asset: re-save (grown strip) ok")
  local t2 = gfx.texture(png, true)
  check(t2 == t, "asset: reload refreshes the same memoized table in place")
  check(t.w == 16 and t.h == 6, "asset: reload re-reads the grown strip")

  -- a failed re-read keeps the current texture (truncate so png_read fails)
  check(pal.write_file(png, "") == true, "asset: truncate the png")
  local t3 = gfx.texture(png, true)
  check(t3 == t and t.w == 16, "asset: a failed reload keeps the old texture")
end

-- ---- cm.ed.* — the R3 editor shell's pure cores (EDITOR.md/D050) ----

-- the platform temp root: windows has no /tmp (SDL can't create dirs under
-- a unix-absolute path there — found running this selftest on the win exe);
-- engine code never hits this (project paths are engine-root-relative)
local function t_atomic_write()
  local path = tmproot() .. "/cosmic_selftest_atomic.bin"
  local prefix = "cosmic_selftest_atomic.bin.tmp."
  local function no_temp()
    for _, name in ipairs(pal.list_dir(tmproot()) or {}) do
      if name:match("([^/\\]+)$"):sub(1, #prefix) == prefix then return false end
    end
    return true
  end
  check(pal.write_file(path, "known-good") == true,
        "atomic: seed destination")

  -- Every injectable pre-rename failure must preserve the valid destination
  -- and clean its non-authoritative same-directory temporary file.
  for _, stage in ipairs({ "open", "write", "flush", "sync", "close", "rename" }) do
    local ok, err = pal.write_file_atomic(path, "replacement", { _fail = stage })
    check(ok == nil and type(err) == "string" and err:find(stage, 1, true),
          "atomic: " .. stage .. " reports its seam")
    check(pal.read_file(path) == "known-good",
          "atomic: " .. stage .. " preserves destination")
    check(no_temp(),
          "atomic: " .. stage .. " cleans temporary")
  end

  check(pal.write_file_atomic(path, "replacement") == true,
        "atomic: successful replace")
  check(pal.read_file(path) == "replacement" and no_temp(),
        "atomic: replacement is complete and temp is gone")
  check(pal.write_file_atomic(path, "") == true and pal.read_file(path) == "",
        "atomic: empty file replace")

  -- API 14 carries the integrity and one-rename publication seams needed by
  -- the self-contained in-editor exporter. Hash vectors are the standard
  -- SHA-256/CRC-32 known answers, independent of the archive layer above.
  check(pal.version.api >= 14 and type(pal.sha256) == "function"
        and type(pal.sha256_file) == "function"
        and type(pal.crc32) == "function"
        and type(pal.x_path_info) == "function"
        and type(pal.x_file_publish) == "function"
        and type(pal.x_windows_exe_identity) == "function",
        "export io: PAL api14 exposes hash/info/publication primitives")
  check(pal.version.api >= 15 and type(pal.x_folder_dialog) == "function"
        and type(pal.x_folder_dialog_poll) == "function",
        "project lifecycle: PAL api15 exposes native folder chooser")
  local fok, ferr = pal.x_folder_dialog()
  check(fok == nil and type(ferr) == "string"
        and ferr:find("live window", 1, true)
        and pal.x_folder_dialog_poll() == "idle",
        "project lifecycle: folder chooser refuses headless use cleanly")
  check(pal.version.api >= 16 and type(pal.x_path_move) == "function"
        and type(pal.x_path_reveal) == "function",
        "project location: PAL api16 exposes safe move and native reveal")

  -- The native location seam is no-replace at the authoritative operation,
  -- not merely at a racy Lua preflight. Exercise real directory renames with
  -- spaces + UTF-8 on both supported hosts; reveal uses its injected seam so
  -- headless CI never launches a desktop file manager.
  local move_source = tmproot() .. "/cosmic_selftest_path_source"
  local move_dest = tmproot() .. "/cosmic selftest π moved"
  local move_collision = tmproot() .. "/cosmic_selftest_path_collision"
  for _, dir in ipairs({ move_source, move_dest, move_collision }) do
    pal.x_remove(dir .. "/marker")
    pal.x_remove(dir)
  end
  pal.mkdir(move_source)
  pal.write_file(move_source .. "/marker", "source")
  pal.mkdir(move_collision)
  pal.write_file(move_collision .. "/marker", "collision")
  local mok, merr = pal.x_path_move(move_source, move_collision)
  check(not mok and merr:find("already exists", 1, true)
        and pal.read_file(move_source .. "/marker") == "source"
        and pal.read_file(move_collision .. "/marker") == "collision",
        "project location: collision cannot replace source or destination")
  mok, merr = pal.x_path_move(move_source, move_dest, { _fail = "rename" })
  check(not mok and merr:find("injected", 1, true)
        and pal.read_file(move_source .. "/marker") == "source"
        and not pal.read_file(move_dest .. "/marker"),
        "project location: native rename failure preserves discoverable source")
  check(pal.x_path_move(move_source, move_dest) == true
        and not pal.read_file(move_source .. "/marker")
        and pal.read_file(move_dest .. "/marker") == "source",
        "project location: directory moves intact into spaced UTF-8 path")
  local rok, rerr = pal.x_path_reveal(move_dest, { _fail = "open" })
  check(not rok and rerr:find("injected open failure", 1, true)
        and pal.read_file(move_dest .. "/marker") == "source",
        "project location: reveal failure is actionable and non-mutating")
  pal.x_remove(move_dest .. "/marker")
  pal.x_remove(move_dest)
  pal.x_remove(move_collision .. "/marker")
  pal.x_remove(move_collision)
  check(pal.sha256("") ==
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        and pal.sha256("abc") ==
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "export io: SHA-256 string known answers")
  check(pal.crc32("123456789") == 0xcbf43926
        and pal.crc32("789", pal.crc32("123456")) == 0xcbf43926,
        "export io: CRC-32 one-shot and rolling known answer")
  pal.write_file(path, "abc")
  local info = pal.x_path_info(path)
  check(info and info.type == "file" and info.size == 3 and not info.link
        and pal.sha256_file(path) == pal.sha256("abc"),
        "export io: path info and streaming file hash")
  local identity_png = pal.png_encode(
    string.rep("\x34\x78\xbc\xff", 32 * 32), 32, 32)
  if pal.platform == "windows" then
    local source = pal.read_file("bin/cosmic-player.exe")
    local branded = tmproot() .. "/cosmic_selftest_branded.exe"
    pal.write_file(branded, source)
    local iok, ierr = pal.x_windows_exe_identity(
      branded, identity_png, 32, 32, "Selftest Game", "7.8.9-alpha",
      "Test Author", "selftest-game")
    check(iok and not ierr and pal.read_file(branded) ~= source
          and pal.read_file("bin/cosmic-player.exe") == source,
          "export io: Windows launcher copy gains project resources only")
    pal.x_remove(branded)
  else
    local iok, ierr = pal.x_windows_exe_identity(
      path, identity_png, 32, 32, "Selftest Game", "1.0", "", "selftest")
    check(not iok and ierr:find("unavailable on Linux", 1, true),
          "export io: Linux names the unavailable Windows identity seam")
  end

  local pubtmp = tmproot() .. "/cosmic_selftest_publish.tmp"
  local pubdst = tmproot() .. "/cosmic_selftest_publish.zip"
  pal.x_remove(pubtmp); pal.x_remove(pubdst)
  pal.write_file(pubtmp, "complete archive")
  local pok, perr = pal.x_file_publish(pubtmp, pubdst, { _fail = "sync" })
  check(not pok and perr:find("sync", 1, true) and pal.read_file(pubtmp)
        and not pal.read_file(pubdst),
        "export io: sync failure leaves only the non-authoritative temp")
  pok, perr = pal.x_file_publish(pubtmp, pubdst, { _fail = "rename" })
  check(not pok and perr:find("publish", 1, true) and pal.read_file(pubtmp)
        and not pal.read_file(pubdst),
        "export io: rename failure cannot publish a partial artifact")
  check(pal.x_file_publish(pubtmp, pubdst) == true
        and not pal.read_file(pubtmp)
        and pal.read_file(pubdst) == "complete archive",
        "export io: one rename publishes the complete artifact")
  pal.write_file(pubtmp, "new archive")
  pok, perr = pal.x_file_publish(pubtmp, pubdst)
  check(not pok and perr:find("already exists", 1, true)
        and pal.read_file(pubtmp) == "new archive"
        and pal.read_file(pubdst) == "complete archive",
        "export io: an existing artifact is never overwritten implicitly")
  pok, perr = pal.x_file_publish(pubtmp, pubdst,
                                 { _replace = true, _fail = "rename" })
  check(not pok and pal.read_file(pubtmp) == "new archive"
        and pal.read_file(pubdst) == "complete archive",
        "export io: failed explicit replacement preserves the last good artifact")
  check(pal.x_file_publish(pubtmp, pubdst, { _replace = true }) == true
        and pal.read_file(pubdst) == "new archive" and not pal.read_file(pubtmp),
        "export io: explicit replacement atomically advances the artifact")
  pal.x_remove(pubtmp); pal.x_remove(pubdst)

  -- API 13's background pair preserves the same authority ordering without
  -- making the caller wait: payload first, cumulative manifest second. The
  -- explicit drain is the quit/crash test boundary, not the live frame path.
  check(pal.version.api >= 13
        and type(pal.x_write_file_pair_atomic_async) == "function"
        and type(pal.x_write_file_atomic_poll) == "function"
        and type(pal.x_write_file_atomic_drain) == "function",
        "async atomic: PAL api13 exposes queue, poll, and drain")
  local pair1 = tmproot() .. "/cosmic_selftest_async_segment"
  local pair2 = tmproot() .. "/cosmic_selftest_async_index"
  pal.x_remove(pair1)
  pal.write_file(pair2, "old-index")
  local job = pal.x_write_file_pair_atomic_async(
    pair1, "segment", pair2, "new-index")
  check(type(job) == "number", "async atomic: pair queues without waiting")
  pal.x_write_file_atomic_drain()
  local done, aok, aerr = pal.x_write_file_atomic_poll()
  check(done == job and aok == true and aerr == nil
        and pal.read_file(pair1) == "segment"
        and pal.read_file(pair2) == "new-index",
        "async atomic: ordered pair becomes completely durable")

  pal.x_remove(pair1)
  pal.write_file(pair2, "known-index")
  job = pal.x_write_file_pair_atomic_async(
    pair1, "orphan", pair2, "bad-index", nil, { _fail = "rename" })
  pal.x_write_file_atomic_drain()
  done, aok, aerr = pal.x_write_file_atomic_poll()
  check(done == job and aok == nil and type(aerr) == "string"
        and aerr:find("second file", 1, true)
        and not pal.read_file(pair1) and pal.read_file(pair2) == "known-index",
        "async atomic: manifest failure removes orphan + preserves authority")
  pal.x_remove(pair1)
  pal.x_remove(pair2)

  local ok, err = pal.write_file_atomic(
    tmproot() .. "/cosmic_selftest_missing/child.bin", "x")
  check(ok == nil and type(err) == "string" and err:find("open", 1, true),
        "atomic: natural open failure is actionable")
  pal.x_remove(path)

  -- Standalone compatibility sidecar helpers use the same replacement seam.
  local anim = cm.require("cm.anim")
  local ap = tmproot() .. "/cosmic_selftest_sidecar.anim"
  pal.write_file(ap, "known-good-animation")
  ok, err = anim.save(ap, {}, { _fail = "rename" })
  check(not ok and err:find(ap, 1, true) and pal.read_file(ap) == "known-good-animation",
        "anim sidecar: failed replacement preserves prior bytes and names path")
  check(anim.save(ap, {}) == true and anim.load(ap) ~= nil,
        "anim sidecar: retry publishes decodable bytes")
  pal.x_remove(ap)

  local sprite = cm.require("cm.sprite")
  local mp = tmproot() .. "/cosmic_selftest_sidecar.meta"
  pal.write_file(mp, "known-good-metadata")
  local sd = sprite.new(2, 2)
  ok, err = sprite.save_meta(mp, sd, { _fail = "rename" })
  check(not ok and err:find(mp, 1, true) and pal.read_file(mp) == "known-good-metadata",
        "sprite metadata: failed replacement preserves prior bytes and names path")
  check(sprite.save_meta(mp, sd) == true and sprite.load_meta(mp) ~= nil,
        "sprite metadata: retry publishes decodable bytes")
  pal.x_remove(mp)

  -- A scaffold publishes project.lua last and rolls back all earlier files.
  local project = cm.require("cm.project")
  local dir = tmproot() .. "/cosmic_selftest_scaffold"
  pal.x_remove(dir .. "/project.lua")
  pal.x_remove(dir .. "/main.lua")
  pal.x_remove(dir)
  ok, err = project.scaffold(dir, "test-project", { main = { _fail = "rename" } })
  check(not ok and err:find("main.lua", 1, true)
        and not pal.read_file(dir .. "/main.lua") and not pal.read_file(dir .. "/project.lua"),
        "project scaffold: source failure leaves no partial project")
  ok, err = project.scaffold(dir, "test-project", { meta = { _fail = "rename" } })
  check(not ok and err:find("project.lua", 1, true)
        and not pal.read_file(dir .. "/main.lua") and not pal.read_file(dir .. "/project.lua"),
        "project scaffold: authority failure rolls back source")
  check(project.scaffold(dir, "test-project") == true
        and pal.read_file(dir .. "/main.lua")
        and pal.read_file(dir .. "/project.lua"):find('name = "test%-project"'),
        "project scaffold: success publishes a complete discoverable project")
  pal.x_remove(dir .. "/project.lua")
  pal.x_remove(dir .. "/main.lua")
  pal.x_remove(dir)

  local recent = cm.require("cm.recent")
  local old_recent = recent.path
  recent.path = tmproot() .. "/cosmic_selftest_remove_recent.dat"
  pal.write_file(recent.path, "keep\nremove\nalso-keep")
  ok, err = recent.remove("remove", { _fail = "rename" })
  check(not ok and pal.read_file(recent.path) == "keep\nremove\nalso-keep",
        "recent prune: failed replacement preserves prior list")
  check(recent.remove("remove") == true
        and pal.read_file(recent.path) == "keep\nalso-keep",
        "recent prune: retry publishes filtered list")
  pal.write_file(recent.path, "old/path\nkeep\nnew/path")
  ok, err = recent.replace("old/path", "new/path", { _fail = "rename" })
  check(not ok and pal.read_file(recent.path) == "old/path\nkeep\nnew/path",
        "recent repair: failed replacement preserves stale discoverability")
  check(recent.replace("old/path", "new/path") == true
        and pal.read_file(recent.path) == "new/path\nkeep",
        "recent repair: atomically replaces, promotes, and deduplicates")
  pal.write_file(recent.path, "C:\\Games\\one\\\nC:/Games/one/\nkeep")
  check(recent.note("C:\\Games\\two\\") == true
        and pal.read_file(recent.path) == "C:/Games/two\nC:/Games/one\nkeep",
        "recent lifecycle: host separators normalize and legacy aliases collapse")
  check(not recent.note("bad\npath") and not recent.remove(""),
        "recent lifecycle: line-breaking and empty paths are rejected")
  pal.x_remove(recent.path)
  recent.path = old_recent
end

-- ---- rebindable actions (A4/D084): descriptors, sampling, store, UI seams ----

local function t_input_bind()
  local input = cm.require("cm.input")
  input.pad_reset()
  input.load_binds(nil) -- no store, no overrides: a clean live session

  -- one map exercising every descriptor kind; earlier suites' actions get
  -- rebound to non-overlapping keys so conflict checks start clean
  input.map({ { "jump", input.key.q },
              { "left", input.key.left, "pad:dpleft", "pad:lx-" },
              { "right", input.key.e },
              { "fire", input.key.space, "pad:south" },
              { "boost", "pad:lt+", "pad2:east", "key:7" } })
  local L = 1 << input.bit_of.left
  local F = 1 << input.bit_of.fire
  local B = 1 << input.bit_of.boost

  local c = input.bindings("left")
  check(#c == 3 and c[1] == "key:80" and c[2] == "pad:dpleft"
        and c[3] == "pad:lx-",
        "bind: scancode numbers and pad descriptors canonicalize")
  c = input.bindings("boost")
  check(c[1] == "pad:lt+" and c[2] == "pad2:east" and c[3] == "key:7",
        "bind: trigger directions and pinned pads keep their spelling")
  check(not pcall(input.define, "bad", { "pad:warp" })
        and not pcall(input.define, "bad2", { "pads:south" })
        and not pcall(input.define, "bad3", { true })
        and input.bit_of.bad == nil and input.bit_of.bad2 == nil,
        "bind: invalid descriptors refuse without half-defining an action")
  check(not pcall(input.bindings, "nope") and not pcall(input.rebind, "nope"),
        "bind: unknown actions are loud")

  local function bits()
    return (string.unpack("<I4", input.sample()))
  end

  -- a pad button drives its action's v1 bit, with the key sticky-tap rule
  input.feed({ { type = "pad", pad = 1, connected = true },
               { type = "padbtn", pad = 1, button = input.pad_btn.dpleft,
                 down = true } })
  check(bits() & L ~= 0, "bind: a pad button drives the action bit")
  input.feed({ { type = "padbtn", pad = 1, button = input.pad_btn.dpleft,
                 down = false } })
  check(bits() & L == 0, "bind: the pad release clears the bit")
  input.feed({ { type = "padbtn", pad = 1, button = input.pad_btn.dpleft,
                 down = true },
               { type = "padbtn", pad = 1, button = input.pad_btn.dpleft,
                 down = false } })
  check(bits() & L ~= 0, "bind: a sub-frame pad tap lands one record")
  check(bits() & L == 0, "bind: the pad tap clears on the next record")

  -- an axis binding fires at the quantized threshold, direction-aware
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = -15801 } })
  check(bits() & L ~= 0, "bind: stick deflection at the threshold fires")
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = -15750 } })
  check(bits() & L == 0, "bind: deflection inside the threshold does not")
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = 32767 } })
  check(bits() & L == 0, "bind: the opposite direction never fires")
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = 0 },
               { type = "padaxis", pad = 1, axis = 4, value = 32767 } })
  check(bits() & B ~= 0, "bind: a trigger direction drives its bit")
  input.feed({ { type = "padaxis", pad = 1, axis = 4, value = 0 } })

  -- a binding pinned to pad 2 ignores pad 1
  input.feed({ { type = "padbtn", pad = 1, button = input.pad_btn.east,
                 down = true } })
  check(bits() & B == 0, "bind: a pad2-pinned binding ignores pad 1")
  input.feed({ { type = "padbtn", pad = 1, button = input.pad_btn.east,
                 down = false },
               { type = "pad", pad = 2, connected = true },
               { type = "padbtn", pad = 2, button = input.pad_btn.east,
                 down = true } })
  check(bits() & B ~= 0, "bind: the pinned pad drives it")
  input.feed({ { type = "padbtn", pad = 2, button = input.pad_btn.east,
                 down = false } })

  -- keys keep working beside pads on the same action
  input.feed({ { type = "key", scancode = 44, down = true, rep = false } })
  check(bits() & F ~= 0, "bind: keyboard bindings still drive the bit")
  input.feed({ { type = "key", scancode = 44, down = false } })

  -- conflicts: an input on two actions is legal API state and reported
  check(#input.conflicts() == 0, "bind: the clean map reports no conflicts")
  input.rebind("fire", { "key:44", "key:80" })
  local cf = input.conflicts()
  check(#cf == 1 and cf[1].bind == "key:80"
        and cf[1].actions[1] == "left" and cf[1].actions[2] == "fire",
        "bind: a shared input reports both actions in bit order")
  input.rebind("fire", nil)
  check(#input.conflicts() == 0 and not input.overridden("fire"),
        "bind: dropping the override clears the conflict")

  -- labels: honest names for keys (through the host), pads, and axes
  check(input.bind_label("key:44") == "Space"
        and input.bind_label("key:80") == "Left",
        "bind: key labels come from the host scancode name")
  check(input.bind_label("pad:south") == "south"
        and input.bind_label("pad:dpleft") == "dpad left"
        and input.bind_label("pad:lx-") == "stick left"
        and input.bind_label("pad:rt+") == "rtrigger"
        and input.bind_label("pad2:east") == "p2 east",
        "bind: pad labels use the positional vocabulary")
  check(input.label("left") == "Left/dpad left/stick left",
        "bind: the full label joins every binding")
  check(input.label("left", "key") == "Left"
        and input.label("left", "pad") == "dpad left"
        and input.label("jump", "pad") == "Q",
        "bind: kind labels pick the first match with a fallback")
  input.rebind("jump", {})
  check(input.label("jump") == "unbound", "bind: no bindings reads unbound")
  input.rebind("jump", nil)

  -- capture normalization (the rebind UI's seam): button downs and strong
  -- deflections bind, releases and noise do not, any pad captures as pad 1
  check(input.bind_of_pad_event({ type = "gpadbtn", button = 0, down = true })
          == "pad:south"
        and input.bind_of_pad_event({ type = "padbtn", pad = 3, button = 6,
                                      down = true }) == "pad:start",
        "bind: button capture normalizes to pad 1")
  check(input.bind_of_pad_event({ type = "gpadbtn", button = 0, down = false })
          == nil,
        "bind: a release never captures")
  check(input.bind_of_pad_event({ type = "gpadaxis", axis = 0,
                                  value = -32767 }) == "pad:lx-"
        and input.bind_of_pad_event({ type = "gpadaxis", axis = 1,
                                      value = 20482 }) == "pad:ly+",
        "bind: strong deflections capture with their direction")
  check(input.bind_of_pad_event({ type = "gpadaxis", axis = 1,
                                  value = 20481 }) == nil
        and input.bind_of_pad_event({ type = "gpad", id = 9,
                                      connected = true }) == nil,
        "bind: weak deflections and hot-plug never capture")

  -- the store: overrides load, win, wait for their action, and round-trip
  local root = tmproot() .. "/cosmic_selftest_binds"
  pal.x_remove(root .. "/input.dat")
  pal.x_remove(root)
  pal.mkdir(root)
  pal.write_file(root .. "/input.dat", state.canon({
    schema = 1,
    actions = { fire = { "key:9", "pad:warp", "pad:north" },
                phantom = { "key:30" } },
  }))
  input.load_binds(root)
  c = input.bindings("fire")
  check(#c == 2 and c[1] == "key:9" and c[2] == "pad:north"
        and input.overridden("fire"),
        "bind: a stored override wins and drops only its bad entries")
  check(input.default_bindings("fire")[1] == "key:44"
        and not input.overridden("left"),
        "bind: defaults stay intact beside the override")
  input.define("phantom", { input.key.z })
  check(input.bindings("phantom")[1] == "key:30"
        and input.overridden("phantom")
        and input.default_bindings("phantom")[1] == "key:29",
        "bind: a stored override adopts its action defined later")

  input.rebind("left", { "key:4", "pad:dpleft" })
  check(input.save_binds() == true, "bind: save publishes the store")
  input.load_binds(root)
  c = input.bindings("left")
  check(#c == 2 and c[1] == "key:4" and input.overridden("left")
        and input.bindings("fire")[1] == "key:9"
        and input.bindings("phantom")[1] == "key:30",
        "bind: rebinds survive the store round trip")

  -- a failed save preserves the previous store byte-for-byte while the
  -- live rebind stays applied (the A1 atomic-write contract)
  local before = pal.read_file(root .. "/input.dat")
  input.rebind("left", { "key:5" })
  local ok, err = input.save_binds({ _fail = "rename" })
  check(ok == nil and type(err) == "string"
        and pal.read_file(root .. "/input.dat") == before,
        "bind: a failed save preserves the previous store byte-for-byte")
  check(input.bindings("left")[1] == "key:5",
        "bind: the live rebind stays applied after a failed save")
  check(input.save_binds() == true, "bind: the retry publishes")

  input.rebind("left", nil)
  check(input.bindings("left")[1] == "key:80",
        "bind: dropping the override returns to the defaults")

  -- a malformed store falls back to defaults and never crashes the boot
  pal.write_file(root .. "/input.dat", "not a store")
  input.load_binds(root)
  check(not input.overridden("fire")
        and input.bindings("fire")[1] == "key:44",
        "bind: a malformed store falls back to the defaults")

  input.load_binds(nil)
  check(input.save_binds() == nil,
        "bind: no store exists outside a project session")
  pal.x_remove(root .. "/input.dat")
  pal.x_remove(root)

  -- cm.ui's pad capture (the menu rule): captured downs and axes never
  -- reach the game, releases and hot-plug always pass, and the raw events
  -- stay readable for the rebind capture
  local ui = cm.require("cm.ui")
  ui.frame({})
  ui.capture_pads()
  ui.frame_end() -- latches cap_pads for the next tick, like keys/mouse
  local out = ui.frame({
    { type = "gpad", id = 7, connected = true },
    { type = "gpadbtn", id = 7, button = 0, down = true },
    { type = "gpadbtn", id = 7, button = 1, down = false },
    { type = "gpadaxis", id = 7, axis = 0, value = 32767 },
    { type = "key", scancode = 4, down = true, rep = false },
  })
  check(#out == 3 and out[1].type == "gpad"
        and out[2].type == "gpadbtn" and out[2].down == false
        and out[3].type == "key",
        "bind: captured pads pass only hot-plug and releases to the game")
  check(#ui.inp.pads == 4,
        "bind: the raw pad stream stays readable while captured")
  ui.frame_end()
  out = ui.frame({ { type = "gpadbtn", id = 7, button = 0, down = true } })
  check(#out == 1 and #ui.inp.pads == 1,
        "bind: without capture pad downs pass to the game")
  ui.frame_end()

  -- leave the suite the way we found it: no live pads, unlatched domain
  input.feed({ { type = "pad", pad = 1, connected = false },
               { type = "pad", pad = 2, connected = false } })
  input.pad_reset()
  check(#input.sample() == 10, "bind: the suite leaves the domain unlatched")
end

-- ---- the options packet (A4/D085): knobs, size candidates, stores ----

local function t_options()
  local input = cm.require("cm.input")
  local view = cm.require("cm.view")
  local options = cm.require("cm.options")

  -- the stick knob setters clamp and floor
  check(input.set_deadzone(-100) == 0 and input.set_deadzone(50000) == 32000
        and input.set_deadzone(9000.9) == 9000,
        "options: set_deadzone clamps to 0..32000")
  check(input.set_axis_threshold(0) == 1
        and input.set_axis_threshold(500) == 127
        and input.set_axis_threshold(64) == 64,
        "options: set_axis_threshold clamps to 1..127")

  -- a retuned deadzone shapes quantization through the module knob
  input.set_deadzone(0)
  check(input.quantize_axis(32767) == 127 and input.quantize_axis(1) == 0,
        "options: a zero deadzone maps the full range")
  input.set_deadzone(8000)

  -- a retuned threshold moves the live axis->bit boundary exactly
  input.pad_reset()
  input.load_binds(nil)
  input.map({ { "left", input.key.left, "pad:lx-" } })
  local L = 1 << input.bit_of.left
  local function bits()
    return (string.unpack("<I4", input.sample()))
  end
  input.set_axis_threshold(80)
  input.feed({ { type = "pad", pad = 1, connected = true },
               { type = "padaxis", pad = 1, axis = 0, value = -15801 } })
  check(bits() & L == 0,
        "options: the old threshold deflection no longer fires at 80")
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = -23602 } })
  check(bits() & L ~= 0, "options: quantized -80 fires threshold 80 exactly")
  input.feed({ { type = "padaxis", pad = 1, axis = 0, value = -23601 } })
  check(bits() & L == 0, "options: quantized -79 stays under threshold 80")
  input.feed({ { type = "pad", pad = 1, connected = false } })
  input.pad_reset()

  -- the knobs ride input.dat additively: non-defaults persist, defaults
  -- are omitted (an untouched player never freezes today's defaults),
  -- malformed values are ignored, and every load resets first
  local root = tmproot() .. "/cosmic_selftest_options"
  pal.x_remove(root .. "/input.dat")
  pal.x_remove(root)
  pal.mkdir(root)
  pal.write_file(root .. "/input.dat", state.canon({
    schema = 1, actions = {}, deadzone = 12000, axis_threshold = 60,
  }))
  input.load_binds(root)
  check(input.deadzone == 12000 and input.axis_threshold == 60,
        "options: stored stick knobs adopt on load")
  input.set_deadzone(input.DEF_DEADZONE)
  input.set_axis_threshold(70)
  check(input.save_binds() == true, "options: the knob save publishes")
  local t = state.parse(pal.read_file(root .. "/input.dat"))
  check(t.axis_threshold == 70 and t.deadzone == nil,
        "options: only off-default knobs enter the store")
  pal.write_file(root .. "/input.dat", state.canon({
    schema = 1, actions = {}, deadzone = "wide", axis_threshold = 9000,
  }))
  input.load_binds(root)
  check(input.deadzone == input.DEF_DEADZONE and input.axis_threshold == 127,
        "options: malformed knobs are ignored, numeric ones clamp")
  input.load_binds(nil)
  check(input.deadzone == input.DEF_DEADZONE
        and input.axis_threshold == input.DEF_AXIS_THRESHOLD,
        "options: a store-less load resets the knobs")
  pal.x_remove(root .. "/input.dat")

  -- size candidates: ladder-filling sizes that FIT the given desktop
  local saved_ref = { view.cfg.ref_w, view.cfg.ref_h }
  view.cfg.ref_w, view.cfg.ref_h = 480, 270
  local function has(list, w, h)
    for _, s in ipairs(list) do if s[1] == w and s[2] == h then return true end end
    return false
  end
  local c = view.size_candidates(nil)
  check(#c == 4 and has(c, 720, 540) and has(c, 960, 540)
        and has(c, 1440, 1080) and has(c, 1920, 1080),
        "options: no display -> the classic static four")
  c = view.size_candidates(1920, 1080)
  check(has(c, 720, 540) and has(c, 960, 540) and has(c, 1440, 1080)
        and has(c, 1920, 1080),
        "options: a 1080p desktop keeps the classic four")
  for i = 2, #c do
    check(c[i - 1][1] * c[i - 1][2] <= c[i][1] * c[i][2],
          "options: candidates sort ascending by area")
  end
  c = view.size_candidates(1366, 768)
  check(#c == 2 and has(c, 720, 540) and has(c, 960, 540),
        "options: a small laptop drops every size that cannot fit")
  c = view.size_candidates(3840, 2160)
  check(#c == 8 and c[#c][1] == 3840 and c[#c][2] == 2160,
        "options: a 4K desktop caps at the largest eight")
  for _, s in ipairs(c) do
    check(s[1] <= 3840 and s[2] <= 2160, "options: every candidate fits")
  end
  c = view.size_candidates(500, 400)
  check(#c == 2 and has(c, 360, 270) and has(c, 480, 270),
        "options: a tiny display falls back to 1x sizes")
  c = view.size_candidates(200, 150)
  check(#c == 1 and c[1][1] == 360 and c[1][2] == 270,
        "options: the smallest FOV at 1x is the unconditional floor")
  view.cfg.ref_w, view.cfg.ref_h = 960, 540
  c = view.size_candidates(1920, 1080)
  check(#c == 2 and has(c, 1440, 1080) and has(c, 1920, 1080),
        "options: a 960x540-family project derives ITS multiples")
  view.cfg.ref_w, view.cfg.ref_h = saved_ref[1], saved_ref[2]

  -- the headless display query keeps its contract: nil, or a real size
  local dw, dh = pal.x_display_size()
  check(dw == nil or (math.type(dw) == "integer" and dw >= 1
        and math.type(dh) == "integer" and dh >= 1),
        "options: x_display_size is nil or a positive size")

  -- project-declared options: declaration validation
  local saved_defs, saved_custom = options.defs, options._custom
  options.defs, options._custom = {}, {}
  check(not pcall(options.add, { id = "x", kind = "warp" })
        and not pcall(options.add, { id = "", kind = "toggle" })
        and not pcall(options.add, { id = "x", kind = "choice" })
        and not pcall(options.add,
                      { id = "x", kind = "slider", min = 5, max = 1 })
        and not pcall(options.add, { id = "x", kind = "slider", min = 0,
                                     max = 10, default = 99 }),
        "options: invalid declarations refuse loudly")
  check(#options.defs == 0, "options: refusals leave no half declaration")
  local fired
  options.add({ id = "shake", kind = "toggle", default = true })
  options.add({ id = "zoom", kind = "slider", min = 1, max = 8, default = 2,
                on_change = function(v) fired = v end })
  options.add({ id = "style", kind = "choice",
                choices = { "clean", "crt" } })
  check(options.get("shake") == true and options.get("zoom") == 2
        and options.get("style") == "clean",
        "options: declared defaults answer get()")
  check(not pcall(options.get, "nope") and not pcall(options.set, "nope", 1),
        "options: unknown ids are loud")
  check(not pcall(options.set, "zoom", 99)
        and not pcall(options.set, "style", "neon"),
        "options: set refuses out-of-range values")

  -- volumes + custom values round-trip the REAL video.dat save/load
  local vroot = tmproot() .. "/cosmic_selftest_optvideo"
  pal.x_remove(vroot .. "/video.dat")
  pal.x_remove(vroot .. "/editor.dat")
  pal.x_remove(vroot)
  pal.mkdir(vroot)
  view._video_path = vroot .. "/video.dat"
  local saved_access = view._access_path
  view._access_path = vroot .. "/editor.dat" -- hermetic accessibility
  -- load_video adopts view knobs too: keep the suite's live view intact
  local saved_view = { ui_scale = view.cfg.ui_scale,
                       editor_scale = view.cfg.editor_scale,
                       chrome_scale = view.cfg.chrome_scale,
                       access_auto = view.cfg.access_auto,
                       access_resolved = view.access_resolved,
                       win_w = view.win_w, win_h = view.win_h,
                       fullscreen = view.fullscreen }
  local saved_vol = options.vol
  options.vol = { master = 100, music = 100, sfx = 100 }

  check(options.set_vol("music", 40) == 40
        and options.set_vol("master", 250) == 100
        and options.set_vol("sfx", -3) == 0,
        "options: set_vol clamps to 0..100")
  check(not pcall(options.set_vol, "voice", 5),
        "options: unknown volumes are loud")
  options.set("zoom", 5)
  check(fired == 5, "options: set fires on_change")
  t = state.parse(pal.read_file(vroot .. "/video.dat"))
  check(t.vol_music == 40 and t.vol_sfx == 0 and t.vol_master == nil,
        "options: only off-default volumes enter video.dat")
  check(t.custom.zoom == 5 and t.custom.shake == nil,
        "options: only touched custom values enter video.dat")

  -- a crafted store: foreign ids stay inert through load AND resave,
  -- malformed volumes fall back, numeric ones clamp
  pal.write_file(vroot .. "/video.dat", state.canon({
    ui_scale = 2, win_w = 960, win_h = 540,
    vol_music = 900, vol_sfx = "loud",
    custom = { zoom = 3, zebra = 5, style = "neon", bad = { 1 } },
  }))
  options.vol = { master = 1, music = 2, sfx = 3 } -- junk: load must reset
  view.load_video()
  check(options.vol.master == 100 and options.vol.music == 100
        and options.vol.sfx == 100,
        "options: volumes clamp and reset through a crafted load")
  check(options.get("zoom") == 3,
        "options: a stored custom value answers get()")
  check(options.get("style") == "clean",
        "options: a stored value failing validation yields the default")
  view.save_video()
  t = state.parse(pal.read_file(vroot .. "/video.dat"))
  check(t.custom.zebra == 5 and t.custom.style == "neon",
        "options: undeclared/invalid custom ids stay inert in the store")
  check(t.custom.bad == nil, "options: non-scalar custom values drop")

  -- redeclare (hot reload): value kept when valid, defaulted when not
  options.add({ id = "zoom", kind = "slider", min = 4, max = 8, default = 4 })
  check(options.get("zoom") == 4,
        "options: a redeclared range falls back to its new default")

  -- on_change attaches behavior to a data-declared knob (D133): the
  -- project.lua half declares shape+default, this is the code half
  local attached
  options.on_change("zoom", function(v) attached = v end)
  options.set("zoom", 6)
  check(attached == 6, "options: on_change attaches to a declared knob")
  check(not pcall(options.on_change, "nope", function() end),
        "options: on_change is loud on unknown ids")

  -- the defaults publish's live half (D136): the declaration follows the
  -- published value, a now-equal stored value leaves the store (this
  -- machine tracks the default again), unknown ids and off-shape values
  -- are ignored, and inert foreign ids survive the persist untouched
  local zoomdef, styledef
  for _, d in ipairs(options.defs) do
    if d.id == "zoom" then zoomdef = d end
    if d.id == "style" then styledef = d end
  end
  options.rebase_defaults({ zoom = 6, nope = true, style = 99 })
  check(zoomdef.default == 6 and options._custom.zoom == nil
        and options.get("zoom") == 6,
        "options: rebase_defaults moves the declaration and prunes the store")
  check(styledef.default == "clean",
        "options: rebase_defaults ignores values off the declared shape")
  t = state.parse(pal.read_file(vroot .. "/video.dat"))
  check(t.custom.zoom == nil and t.custom.zebra == 5,
        "options: the pruned value left video.dat, inert ids survive")

  -- restore the suite's state
  view._video_path, view._access_path = nil, saved_access
  view.cfg.ui_scale = saved_view.ui_scale
  view.cfg.editor_scale = saved_view.editor_scale
  view.cfg.chrome_scale = saved_view.chrome_scale
  view.cfg.access_auto = saved_view.access_auto
  view.access_resolved = saved_view.access_resolved
  view.win_w, view.win_h = saved_view.win_w, saved_view.win_h
  view.fullscreen = saved_view.fullscreen
  options.defs, options._custom, options.vol =
    saved_defs, saved_custom, saved_vol
  if pal.x_snd_gain then pal.x_snd_gain(128, 128, 128) end
  pal.x_remove(vroot .. "/video.dat")
  pal.x_remove(vroot .. "/editor.dat")
  pal.x_remove(vroot)
  pal.x_remove(root)
end

-- ---- cm.save: namespaced atomic player storage (A4/D086) ----

local function t_save()
  local save = cm.require("cm.save")
  local project = cm.require("cm.project")
  local repl = cm.require("cm.repl")

  -- the save_id grammar: the stable namespace key under the user root
  check(project.save_id_error("my-game_2") == nil
        and project.save_id_error("x") == nil
        and project.save_id_error(("a"):rep(64)) == nil,
        "save: valid save_ids pass the grammar")
  check(project.save_id_error(nil) ~= nil
        and project.save_id_error("") ~= nil
        and project.save_id_error("My-Game") ~= nil
        and project.save_id_error("-lead") ~= nil
        and project.save_id_error("sp ace") ~= nil
        and project.save_id_error("p/ath") ~= nil
        and project.save_id_error("..") ~= nil
        and project.save_id_error(("a"):rep(65)) ~= nil,
        "save: unsafe save_ids are refused")
  check(project.save_slug("My Game! vol.2") == "my-game-vol-2"
        and project.save_slug("π") == "game"
        and project.save_slug("--x--") == "x",
        "save: slugs fold names into the grammar with an honest fallback")
  check(project.validate_runtime({ name = "g", save_id = "ok-id" }) == true
        and not project.validate_runtime({ name = "g", save_id = "Bad Id" }),
        "save: boot validation admits only grammar-clean save_ids")

  -- project-declared option defaults (D133): data-only, mirrored on
  -- options.add's rules so a schema-valid list never refuses at boot
  check(project.options_error({
          { id = "shake", label = "screen shake", default = true },
          { id = "zoom", kind = "slider", min = 1, max = 8, default = 2 },
          { id = "filter", kind = "choice", choices = { "clean", "crt" },
            default = "crt" },
        }) == nil, "project: a well-formed options list validates")
  check(project.options_error("nope") ~= nil
        and project.options_error({ "x" }) ~= nil
        and project.options_error({ { id = "" } }) ~= nil
        and project.options_error({ { id = "a" }, { id = "a" } }) ~= nil
        and project.options_error({ { id = "s", kind = "slider",
                                      min = 5, max = 1 } }) ~= nil
        and project.options_error({ { id = "s", kind = "slider",
                                      default = 99, max = 10 } }) ~= nil
        and project.options_error({ { id = "c", kind = "choice",
                                      choices = {} } }) ~= nil
        and project.options_error({ { id = "c", kind = "choice",
                                      choices = { "a" }, default = "b" } })
            ~= nil
        and project.options_error({ { id = "w", kind = "warp" } }) ~= nil
        and project.options_error({ { id = "t", default = 1 } }) ~= nil,
        "project: malformed options entries refuse, naming the entry")
  check(project.options_error({ { id = "x",
          on_change = function() end } }) ~= nil,
        "project: on_change is code and stays out of project.lua")
  check(project.validate_runtime({ options = { { id = "ok" } } }) == true
        and not project.validate_runtime({ options = { { id = "" } } }),
        "project: boot validation covers the options list")

  -- the defaults publish merge (D136): live values become the data
  -- defaults of MATCHING entries, in list order, on a clone; entries the
  -- values table does not name stand; live options absent from the list
  -- (code-declared) are skipped and named in the applied list's absence
  local dbase = { name = "g", options = {
    { id = "crt", kind = "toggle", default = true },
    { id = "glow", kind = "slider", min = 1, max = 8, default = 2 },
    { id = "look", kind = "choice", choices = { "clean", "neon" } },
  }, custom = { keep = 7 } }
  local dmerged, dapplied = project.apply_option_defaults(
    dbase, { crt = false, glow = 5, codeknob = true })
  check(dmerged ~= nil and dmerged.options[1].default == false
        and dmerged.options[2].default == 5
        and dmerged.options[3].default == nil
        and #dapplied == 2 and dapplied[1] == "crt" and dapplied[2] == "glow"
        and dmerged.custom.keep == 7
        and dbase.options[1].default == true,
        "project: apply_option_defaults merges live values into a clone")
  local drt = project.decode(project.encode(dmerged), "@defaults-roundtrip")
  check(drt and drt.options[2].default == 5 and drt.options[2].max == 8
        and drt.options[1].id == "crt",
        "project: published defaults survive the canonical codec")
  local _, derr = project.apply_option_defaults({ name = "g" }, { crt = true })
  check(derr and derr:find("declares no options", 1, true),
        "project: publish refuses without a data options list")
  _, derr = project.apply_option_defaults(dbase, { codeknob = true })
  check(derr and derr:find("code-declared", 1, true),
        "project: publish with only code-declared options refuses honestly")
  _, derr = project.apply_option_defaults(dbase, { glow = 99 })
  check(derr and derr:find("options[2]", 1, true),
        "project: an out-of-shape published default refuses naming the entry")

  -- settings: empty is a legal draft, invalid never crosses, valid persists
  local meta = { name = "g" }
  local form = project.settings(meta)
  check(form.save_id == "", "save: an undeclared save_id edits as empty")
  local ok = project.validate_settings(form)
  check(ok and ok.save_id == nil, "save: an empty save id stays a draft")
  form.save_id = "Bad Id"
  local _, serr = project.validate_settings(form)
  check(serr and serr:find("save_id", 1, true),
        "save: settings refuse a save id off the grammar")
  form.save_id = "  good-id  "
  meta = project.apply_settings(meta, form)
  check(meta and meta.save_id == "good-id",
        "save: apply_settings writes the trimmed id")
  form.save_id = ""
  meta = project.apply_settings(meta, form)
  check(meta and meta.save_id == nil,
        "save: clearing the settings field removes the key")

  -- bind: the store exists only for a validly declared id
  save.bind(nil)
  local on, why = save.enabled()
  check(not on and why:find("off this session", 1, true),
        "save: an unbound session names itself")
  save.bind({ name = "g" })
  on, why = save.enabled()
  check(not on and why:find("no save_id", 1, true),
        "save: a project without save_id has no store")
  save.bind({ name = "g", save_id = "Bad Id" })
  check(not save.enabled(), "save: an invalid save_id never binds")
  check(select(2, save.write(1, { x = 1 })) ~= nil
        and select(2, save.read(1)) ~= nil
        and select(2, save.slots()) ~= nil
        and select(2, save.profiles()) ~= nil
        and select(2, save.erase(1)) ~= nil
        and select(2, save.wipe()) ~= nil,
        "save: every door answers a disabled store with the reason")

  -- the real store under a fixture root (the selftest seam)
  local root = tmproot() .. "/cosmic_selftest_save"
  local function rmtree()
    for _, rel in ipairs(pal.x_list_dir_all(root) or {}) do
      pal.x_remove(root .. "/" .. rel)
    end
    for _, rel in ipairs({ "fixture-game/default", "fixture-game/alt",
                           "fixture-game" }) do
      pal.x_remove(root .. "/" .. rel)
    end
    pal.x_remove(root)
  end
  rmtree()
  save.bind({ name = "g", save_id = "fixture-game" })
  save._root = root
  check(save.enabled() == true, "save: a declared id binds the store")

  -- slot grammar
  check(select(2, save.write(0, {})) ~= nil
        and select(2, save.write(1.5, {})) ~= nil
        and select(2, save.read(save.MAX_SLOT + 1)) ~= nil,
        "save: slots are integers 1.." .. save.MAX_SLOT)

  -- write/read round-trip: exact plain tree, envelope stamps the schema
  local data = { hp = 3, name = "α\nβ\0γ\"]]", items = { "sword", n = 2 },
                 pos = { x = 1.5, y = -2 } }
  check(save.write(1, data) == true, "save: write publishes")
  local got = save.read(1)
  check(got.hp == 3 and got.name == "α\nβ\0γ\"]]" and got.items[1] == "sword"
        and got.items.n == 2 and got.pos.x == 1.5 and got.pos.y == -2,
        "save: read returns the exact plain tree")
  local env = state.parse(pal.read_file(root .. "/fixture-game/default/slot1.sav"))
  check(env.schema == 1 and env.data.hp == 3,
        "save: the envelope stamps the declared schema")
  check(select(2, save.read(2)):find("no save in slot 2", 1, true),
        "save: a missing slot is the named first-run answer")

  -- refusals before any write: nil data, non-plain data
  check(select(2, save.write(1)) == "save data required",
        "save: nil data is refused")
  check(tostring(select(2, save.write(1, { f = print }))):find("plain", 1, true),
        "save: non-plain data is refused before any write")

  -- a failed atomic replacement preserves the previous save byte-for-byte
  local before = pal.read_file(root .. "/fixture-game/default/slot1.sav")
  local wok, werr = save.write(1, { hp = 99 }, { _fail = "rename" })
  check(not wok and werr ~= nil, "save: an injected write failure is named")
  check(pal.read_file(root .. "/fixture-game/default/slot1.sav") == before,
        "save: a failed write preserves the previous save byte-for-byte")
  check(save.read(1).hp == 3, "save: the preserved save still decodes")

  -- malformed bytes are a named error, never a crash, and stay on disk
  pal.write_file(root .. "/fixture-game/default/slot3.sav", "not a save")
  check(select(2, save.read(3)):find("unreadable", 1, true),
        "save: malformed bytes answer as unreadable")
  check(pal.read_file(root .. "/fixture-game/default/slot3.sav") == "not a save",
        "save: reads never touch a malformed file")

  -- schema: newer refusal, stepwise migration, missing/failing steps
  save.write(4, { coins = 7 }) -- schema 1
  check(save.schema(3) == 3, "save: schema declares")
  check(not pcall(save.schema, 0) and not pcall(save.schema, 1.5),
        "save: schema versions are positive integers")
  local nerr = select(2, save.read(4))
  check(nerr and nerr:find("no migration from save schema 1", 1, true),
        "save: a missing migration step is named")
  save.migrate(1, function(d) return { coins = d.coins, gems = 0 } end)
  nerr = select(2, save.read(4))
  check(nerr and nerr:find("no migration from save schema 2", 1, true),
        "save: migration stops at the exact missing step")
  save.migrate(2, function(d) d.bank = d.coins * 10 return d end)
  got = save.read(4)
  check(got.coins == 7 and got.gems == 0 and got.bank == 70,
        "save: reads migrate stepwise to the declared schema")
  save.migrate(2, function() error("boom") end)
  nerr = select(2, save.read(4))
  check(nerr and nerr:find("migration from schema 2 failed", 1, true),
        "save: a raising migration is a named error")
  save.migrate(2, function() return nil end)
  nerr = select(2, save.read(4))
  check(nerr and nerr:find("returned no data", 1, true),
        "save: a migration returning nothing is refused")
  pal.write_file(root .. "/fixture-game/default/slot5.sav",
                 state.canon({ schema = 9, data = { future = true } }))
  nerr = select(2, save.read(5))
  check(nerr and nerr:find("newer version", 1, true),
        "save: a newer-schema save is refused honestly")
  save.write(5, { fresh = true })
  check(state.parse(pal.read_file(
          root .. "/fixture-game/default/slot5.sav")).schema == 3,
        "save: writes stamp the current declared schema")

  -- profiles + slot listing
  check(save.profile() == "default", "save: the default profile is default")
  check(select(2, save.profile("Bad Name")) ~= nil
        and save.profile() == "default",
        "save: profile names follow the save_id grammar")
  check(save.profile("alt") == "alt", "save: profile selects")
  check(#save.slots() == 0, "save: a fresh profile has no slots")
  save.write(2, { alt = true })
  local slots = save.slots()
  check(#slots == 1 and slots[1] == 2, "save: slots list the profile's saves")
  save.profile("default")
  slots = save.slots() -- the malformed slot 3 fixture is still a slot
  check(#slots == 4 and slots[1] == 1 and slots[2] == 3 and slots[3] == 4
        and slots[4] == 5,
        "save: slots list ascending in the current profile")
  local profs = save.profiles()
  check(#profs == 2 and profs[1] == "alt" and profs[2] == "default",
        "save: profiles list every namespace holding saves")

  -- erase: explicit, idempotent
  check(save.erase(4) == true and select(2, save.read(4)) ~= nil,
        "save: erase removes one slot")
  check(save.erase(4) == true, "save: erasing an absent slot succeeds")

  -- wipe: the current profile only
  check(save.wipe() == true and #save.slots() == 0,
        "save: wipe empties the current profile")
  save.profile("alt")
  check(#save.slots() == 1, "save: wipe leaves other profiles alone")
  check(save.wipe() == true and save.wipe() == true,
        "save: wiping an empty profile is a no-op")
  save.profile("default")

  -- the mid-session load door: read+migrate now, apply through the
  -- recorded eval channel at the next frame start
  check(#repl.queue == 0, "save: the repl queue starts idle")
  check(select(2, save.load(1)) == "no on_load handler is registered",
        "save: load without a handler is refused")
  save.schema(1)
  save.write(1, data)
  local applied
  save.on_load(function(d) applied = d end)
  check(select(2, save.load(2)) ~= nil, "save: loading an empty slot is named")
  check(save.load(1) == true, "save: load queues the recorded apply")
  check(#repl.queue == 1 and repl.queue[1]:find("_apply", 1, true),
        "save: the queued command rides the eval channel")
  local drained = repl.drain()
  check(applied and applied.hp == 3 and applied.name == "α\nβ\0γ\"]]"
        and applied.items.n == 2,
        "save: the handler receives the exact bytes the record carries")
  check(drained and #drained == 1,
        "save: the drained command is what a recording would carry as EVAL")
  applied = nil
  repl.exec(drained[1]) -- verify's replay path: the same exec, same command
  check(applied and applied.hp == 3 and applied.pos.y == -2,
        "save: replaying the recorded command re-applies the same data")
  save._apply("garbage bytes") -- a corrupt record logs, never crashes
  save.on_load(nil)
  save._apply(state.canon({ ok = true })) -- handler-less apply logs, never crashes

  -- a rebind resets declarations and profile: nothing leaks across projects
  save.profile("alt")
  save.schema(5)
  save.bind({ name = "g", save_id = "fixture-game" })
  check(save.profile() == "default" and save._schema == 1,
        "save: bind resets profile and declarations")

  save._root = nil
  save.bind(nil)
  rmtree()
end

local function t_project_settings()
  local project = cm.require("cm.project")
  local src = [==[
return {
  name = "old name", author = "author", version = "1.2",
  description = "old description",
  internal_w = 320, internal_h = 180, window_scale = 3,
  entry = "main.lua", seed = 77,
  icon = "icon.png", controls = "CONTROLS.md", credits = "CREDITS.md",
  licenses = { "LICENSE.md", "NOTICE.txt" },
  custom = { mode = "kept", values = { 3, 5, 8 }, ["end"] = "keyword key" },
}
]==]
  local meta, err = project.decode(src, "@project-fixture")
  check(meta and meta.custom.values[3] == 8,
        "project: declarative source decodes plain nested data")
  local root, inspected = project.inspect_root("C:\\Games\\my game\\", function(path)
    if path == "C:/Games/my game/project.lua" then return src end
  end)
  check(root == "C:/Games/my game" and inspected
        and inspected.name == "old name",
        "project lifecycle: native folder path normalizes and validates")
  local missing, merr = project.inspect_root("/missing", function() return nil, "gone" end)
  check(not missing and merr:find("not a cosmic2d project", 1, true)
        and merr:find("/missing/project.lua", 1, true),
        "project lifecycle: a non-project folder is actionable")
  local invalid, ierr = project.inspect_root("/broken", function()
    return "return { internal_w = 0 }"
  end)
  check(not invalid and ierr:find("internal_w", 1, true),
        "project lifecycle: selected metadata must pass boot validation")
  check(not project.normalize_root("bad\npath")
        and project.normalize_root("/") == "/"
        and project.normalize_root("C:\\") == "C:/"
        and project.normalize_root("./projects/demo/") == "projects/demo",
        "project lifecycle: persistent root grammar preserves filesystem roots")
  local blocked, berr = project.decode("return { name = os.getenv('X') }", "@bad")
  check(not blocked and berr:find("project metadata failed", 1, true),
        "project: empty environment rejects ambient configuration code")
  blocked, berr = project.decode("return { name='x', callback=function() end }", "@bad")
  check(not blocked and berr:find("function", 1, true),
        "project: declarative model rejects non-data values")

  local form = project.settings(meta)
  form.name, form.author, form.version = "  new name  ", "", "2.0-alpha"
  form.description = "a changed description"
  form.internal_w, form.internal_h, form.window_scale = "640", "360", "2"
  form.maximized = true
  local merged
  merged, err = project.apply_settings(meta, form)
  check(merged and merged.name == "new name" and merged.author == ""
        and merged.internal_w == 640 and merged.internal_h == 360
        and merged.window_scale == 2 and merged.maximized == true,
        "project: settings validate, trim, and type editable fields")
  check(merged.custom.mode == "kept" and merged.custom.values[2] == 5
        and merged.entry == "main.lua" and merged.seed == 77,
        "project: applying settings preserves unedited and extension fields")
  local bytes
  bytes, err = project.encode(merged)
  local round = bytes and project.decode(bytes, "@project-roundtrip")
  check(round and round.custom.values[3] == 8
        and round.custom["end"] == "keyword key" and round.licenses[2] == "NOTICE.txt",
        "project: canonical inspectable Lua round-trips nested metadata")
  check(project.encode(round) == bytes, "project: canonical encoding is a fixpoint")
  local release
  release, err = project.validate_release(round)
  check(release and release.name == "new name" and #release.licenses == 2,
        "project: settings and player export share the D070 validator")
  local escaping = {}
  for key, value in pairs(round) do escaping[key] = value end
  escaping.icon = "../icon.png"
  release, err = project.validate_release(escaping)
  check(not release and err:find("unsafe path segment", 1, true),
        "project: shared release validator rejects escaping paths")
  form.internal_w = "wide"
  check(not project.validate_settings(form),
        "project: invalid temporary numeric settings are rejected")
  form.internal_w = "640"
  local draft = project.settings(meta)
  draft.icon, draft.controls, draft.credits, draft.licenses = "", "", "", {}
  local draft_meta = project.apply_settings(meta, draft)
  check(draft_meta and not project.release_configured(draft_meta)
        and draft_meta.icon == nil and draft_meta.licenses == nil,
        "project: an entirely unconfigured release packet remains a saveable draft")
  draft.icon = "icon.png"
  local partial, partial_err = project.validate_settings(draft)
  check(not partial and partial_err:find("controls", 1, true),
        "project: a started release packet is all-or-nothing")

  -- The canonical model's direct persistence seam is atomic too.
  local root = tmproot() .. "/cosmic_selftest_project_settings"
  pal.mkdir(root)
  local path = root .. "/project.lua"
  local icon = pal.png_encode(string.rep("\x46\x82\xb4\xff", 32 * 32), 32, 32)
  pal.write_file(root .. "/icon.png", icon)
  pal.write_file(root .. "/CONTROLS.md", "\239\187\191jump\r\nmove\r\n")
  pal.write_file(root .. "/CREDITS.md", "made by the selftest\n")
  pal.write_file(root .. "/LICENSE.md", "fixture license\n")
  pal.write_file(root .. "/NOTICE.txt", "fixture notice\n")
  pal.write_file(path, src)
  local function read_ref(rel) return pal.read_file(root .. "/" .. rel) end
  local checked
  checked, err = project.validate_release_files(merged, read_ref)
  check(checked and checked.icon.w == 32 and checked.icon.h == 32
        and checked.controls.text == "jump\nmove\n"
        and #checked.licenses == 2,
        "project: D070 schema and referenced bytes validate through one contract")
  local bad_content = project.decode(project.encode(merged), "@bad-content")
  bad_content.controls = "MISSING.md"
  checked, err = project.validate_release_files(bad_content, read_ref)
  check(not checked and err:find("controls MISSING.md", 1, true),
        "project: missing player text is actionable")
  checked, err = project.validate_release_files(merged, function(rel)
    if rel == "CONTROLS.md" then return icon end
    return read_ref(rel)
  end)
  check(not checked and err:find("controls must be a text file", 1, true),
        "project: a binary controls selection is rejected")
  checked, err = project.validate_release_files(merged, function(rel)
    if rel == "icon.png" then return "not a png" end
    return read_ref(rel)
  end)
  check(not checked and err:find("icon must be a PNG", 1, true),
        "project: a wrong-type icon selection is rejected")
  local wide_icon = pal.png_encode(
    string.rep("\x46\x82\xb4\xff", 64 * 32), 64, 32)
  checked, err = project.validate_release_files(merged, function(rel)
    if rel == "icon.png" then return wide_icon end
    return read_ref(rel)
  end)
  check(not checked and err:find("square", 1, true),
        "project: a non-square PNG cannot claim release readiness")
  local ok
  ok, err = project.save(root, merged, { _fail = "rename" })
  check(not ok and err:find(path, 1, true) and pal.read_file(path) == src,
        "project: failed canonical save preserves previous source")
  ok, bytes = project.save(root, merged)
  check(ok and project.decode(pal.read_file(path), "@saved").name == "new name",
        "project: canonical save atomically publishes decodable source")

  -- The settings window edits the exact same working bytes/journal as a code
  -- window. A source-side extension change and form-side identity change merge;
  -- an injected write failure leaves complete dirty bytes for Ctrl+S retry.
  local W = cm.require("cm.ed.win.project")
  local T = cm.require("cm.ed.win.text")
  local summoned = false
  local ed = { root = root, g = {}, doc = { assets = {} }, parked = false,
               touch = function() end,
               summon_console = function() summoned = true end }
  local win = W.defaults()
  W.open_win(win, ed)
  check(win.form.name == "new name" and win.form.internal_w == "640",
        "project window: form adopts the shared project.lua working copy")
  local a, p = T.open_win(win, ed)
  local source_meta = project.decode(a.text, "@working")
  source_meta.extension_after_open = { enabled = true }
  local source_bytes = project.encode(source_meta)
  T.replace(win, ed, source_bytes)
  win.form.name = "window name"
  p._save_fail = { _fail = "rename" }
  local before = pal.read_file(path)
  ok, err = W.save(win, ed)
  check(not ok and summoned and pal.read_file(path) == before,
        "project window: atomic failure preserves disk and summons console")
  check(W.dirty(win, ed) and a.text:find('name = "window name"', 1, true),
        "project window: failed save retains complete dirty working settings")
  p._save_fail = nil
  ok, err = W.save(win, ed)
  local saved = project.decode(pal.read_file(path), "@window-saved")
  check(ok and saved.name == "window name" and saved.extension_after_open.enabled,
        "project window: retry merges form edits without losing source extensions")
  check(not W.dirty(win, ed),
        "project window: successful save clears form and source dirty state")
  W.select_reference(win, ed, "controls", "icon.png")
  before = pal.read_file(path)
  ok, err = W.save(win, ed)
  check(not ok and win.error:find("controls must be a text file", 1, true)
        and pal.read_file(path) == before,
        "project window: a wrong-type picked file cannot reach project.lua")
  W.select_reference(win, ed, "controls", "CONTROLS.md")
  check(W.validate(win, ed) ~= nil,
        "project window: selecting valid project files completes live validation")

  ed.doc.assets["unsaved.lua"] = { text = "working generation" }
  ed.g.tw["unsaved.lua"] = { disk = "saved generation" }
  local dirty_path, dirty_count = W.export_unsaved(win, ed)
  check(dirty_path == "unsaved.lua" and dirty_count == 1,
        "project export UI: preflight finds unsaved working assets")
  ed.doc.assets["unsaved.lua"], ed.g.tw["unsaved.lua"] = nil, nil
  local export_state = W.export_state(win, ed)
  export_state.job = { phase = "building", terminal = false }
  check(not W.can_close(win, ed)
        and export_state.notice:find("cancel", 1, true),
        "project export UI: active jobs guard window dismissal")
  check(W.guard_export(ed, "opening rewind")
        and export_state.notice:find("rewind", 1, true),
        "project export UI: active jobs guard rewind entry")
  check(W.escape(win, ed)
        and export_state.notice:find("Cancel Export", 1, true),
        "project export UI: Esc explains the safe cancellation door")
  export_state.job.terminal = true
  check(W.can_close(win, ed),
        "project export UI: terminal jobs release the close guard")
  W.drop_ephemeral(ed)

  win.form.internal_h = "nope"
  before = pal.read_file(path)
  ok, err = W.save(win, ed)
  check(not ok and win.error:find("internal_h", 1, true)
        and pal.read_file(path) == before,
        "project window: invalid form stays visible and never reaches disk")

  -- the settings window's defaults publish (D136): the door writes the
  -- live option values into project.lua's options list through the SAME
  -- shared working copy (journaled replace + atomic save), refusing
  -- honestly when nothing is data-declared and walled while parked
  local S = cm.require("cm.ed.win.settings")
  local options = cm.require("cm.options")
  local view = cm.require("cm.view")
  local saved_defs, saved_custom = options.defs, options._custom
  local saved_vpath = view._video_path
  options.defs, options._custom = {}, {}
  view._video_path = root .. "/video.dat" -- rebase prunes persist here
  options.add({ id = "crt", kind = "toggle", default = true })
  options.add({ id = "codeknob", kind = "toggle", default = false })
  options._custom.crt = false -- the dev toggled it in the window
  local swin = {}
  local sok, snote = S.save_defaults(swin, ed)
  check(not sok and snote:find("declares no options", 1, true)
        and swin.dnote == snote,
        "settings publish: refuses without a project.lua options list")

  local pstub = { path = "project.lua" }
  local wmeta = project.decode(T.open_win(pstub, ed).text, "@working")
  wmeta.options = { { id = "crt", kind = "toggle", default = true } }
  T.replace(pstub, ed, project.encode(wmeta))

  ed.parked = true
  local pbefore = pal.read_file(path)
  sok, snote = S.save_defaults(swin, ed)
  check(not sok and snote:find("parked", 1, true)
        and pal.read_file(path) == pbefore,
        "settings publish: parked in the past is walled")
  ed.parked = false

  sok, snote = S.save_defaults(swin, ed)
  local sdisk = project.decode(pal.read_file(path), "@published")
  check(sok == true and sdisk.options[1].default == false
        and sdisk.extension_after_open.enabled == true
        and sdisk.name == "window name",
        "settings publish: the live value lands as the data default")
  check(swin.dnote:find("1 code-declared", 1, true) ~= nil,
        "settings publish: code-declared options are counted out honestly")
  local crtdef
  for _, d in ipairs(options.defs) do if d.id == "crt" then crtdef = d end end
  check(crtdef.default == false and options._custom.crt == nil,
        "settings publish: the live declaration rebases and the store prunes")

  options._custom.crt = true -- a fresh diff for the failure path
  local sp = ed.g.tw["project.lua"]
  sp._save_fail = { _fail = "rename" }
  pbefore = pal.read_file(path)
  sok, snote = S.save_defaults(swin, ed)
  local dirtymeta = project.decode(T.open_win(pstub, ed).text, "@dirty")
  check(not sok and snote:find("save failed", 1, true)
        and pal.read_file(path) == pbefore
        and dirtymeta.options[1].default == true
        and options._custom.crt == true and crtdef.default == false,
        "settings publish: atomic failure keeps merged bytes for the ctrl+s retry")
  sp._save_fail = nil

  options.defs, options._custom = saved_defs, saved_custom
  view._video_path = saved_vpath
  pal.x_remove(root .. "/video.dat")
end

local function t_project_location()
  local location = cm.require("cm.project_location")
  local project = cm.require("cm.project")
  local source, parent = "/projects/source", "/else"
  local destination = parent .. "/renamed π project"
  local bytes = project.PROJECT_TMPL:gsub("__NAME__", "location test")
                          :gsub("__SAVEID__", "location-test")

  check(location.destination(parent, "renamed π project", { platform = "linux" })
          == destination
        and not location.destination(parent, "bad/name", { platform = "linux" })
        and not location.destination(parent, "CON", { platform = "windows" }),
        "project location: folder-name grammar allows spaces/UTF-8 and rejects unsafe hosts")
  local pp, pn = location.parts("C:\\Games\\old project\\")
  check(pp == "C:/Games" and pn == "old project",
        "project location: parent/name split follows persistent path spelling")

  local dirs, files, recent_root, replace_calls, probe_fail, move_fail
  local function reset()
    dirs = {
      ["/projects"] = { type = "directory", link = false },
      [source] = { type = "directory", link = false },
      [parent] = { type = "directory", link = false },
    }
    files = { [source .. "/project.lua"] = bytes }
    recent_root, replace_calls, probe_fail, move_fail = source, 0, nil, nil
  end
  reset()
  local fs = {}
  function fs.info(path)
    return dirs[path]
  end
  function fs.read(path)
    local value = files[path]
    if value then return value end
    return nil, "not found"
  end
  function fs.probe(path)
    if path == probe_fail then return nil, "injected permission failure" end
    return true
  end
  function fs.move(from, to)
    if move_fail then return nil, "injected native move failure" end
    if not dirs[from] or dirs[to] then return nil, "collision" end
    dirs[to], dirs[from] = dirs[from], nil
    files[to .. "/project.lua"] = files[from .. "/project.lua"]
    files[from .. "/project.lua"] = nil
    return true
  end
  function fs.reveal(path)
    return dirs[path] and true or nil, "missing"
  end
  local rec = {}
  function rec.contains(path) return path == recent_root end
  function rec.replace(from, to, fail)
    replace_calls = replace_calls + 1
    if fail then return nil, "injected recent publication failure" end
    if recent_root ~= from then return nil, "old recent missing" end
    recent_root = to
    return true
  end
  local base_opts = { fs = fs, recent = rec, active_root = false,
                      platform = "linux", nonce = 7 }

  local ready, err = location.preflight(source, destination, {
    fs = fs, recent = rec, active_root = source, platform = "linux", nonce = 7,
  })
  check(not ready and err:find("return to the project picker", 1, true),
        "project location: the currently open editor owns and pins its root")
  recent_root = "/someone/else"
  ready, err = location.preflight(source, destination, base_opts)
  check(not ready and err:find("recent tile", 1, true),
        "project location: relocation requires a durable recovery pointer")
  recent_root = source
  dirs[destination] = { type = "directory", link = false }
  ready, err = location.preflight(source, destination, base_opts)
  check(not ready and err:find("destination already exists", 1, true),
        "project location: destination collision fails before permissions or move")
  dirs[destination] = nil
  probe_fail = parent
  ready, err = location.preflight(source, destination, base_opts)
  check(not ready and err:find("destination parent is not writable", 1, true),
        "project location: destination permission failure is actionable")
  probe_fail = nil

  move_fail = true
  local ok, detail, outcome = location.relocate(source, destination, base_opts)
  check(not ok and not outcome.moved and dirs[source] and not dirs[destination]
        and recent_root == source and replace_calls == 0
        and detail:find("was not moved", 1, true),
        "project location: native move failure leaves source and recents untouched")

  move_fail = false
  ok, detail, outcome = location.relocate(source, destination, {
    fs = fs, recent = rec, active_root = false, platform = "linux", nonce = 8,
    fail = { recent = { _fail = "rename" } },
  })
  check(not ok and outcome.moved and not dirs[source] and dirs[destination]
        and recent_root == source and replace_calls == 1
        and detail:find("old tile was kept for repair", 1, true),
        "project location: recent failure keeps the stale source tile as repair handle")

  reset()
  local renamed = "/projects/renamed π project"
  ok, detail, outcome = location.rename(source, "renamed π project", base_opts)
  check(ok and detail == renamed and outcome.moved
        and dirs[renamed] and not dirs[source] and recent_root == renamed,
        "project location: rename stays in place and atomically advances recents")
  reset()
  ok, detail, outcome = location.move_to(source, parent, base_opts)
  local moved = parent .. "/source"
  check(ok and detail == moved and outcome.moved
        and dirs[moved] and not dirs[source] and recent_root == moved,
        "project location: move keeps the folder name and advances recents")
  check(location.reveal(moved, { fs = fs }) == true,
        "project location: reveal validates the ready root before host handoff")

  -- Integrate the policy with the real PAL + atomic .recent.dat seam. This
  -- covers the transient parent-permission probes that the fake boundary
  -- above intentionally reduces to booleans.
  local real_base = project.normalize_root(
    tmproot() .. "/cosmic_selftest_location_real")
  local real_source = real_base .. "/source"
  local real_parent = real_base .. "/destination parent"
  local real_moved = real_parent .. "/source"
  local real_renamed = real_parent .. "/renamed π project"
  for _, path in ipairs({ real_source, real_moved, real_renamed }) do
    pal.x_remove(path .. "/project.lua")
    pal.x_remove(path)
  end
  pal.x_remove(real_parent)
  pal.x_remove(real_base .. "/recent.dat")
  pal.x_remove(real_base)
  pal.mkdir(real_base)
  pal.mkdir(real_source)
  pal.mkdir(real_parent)
  pal.write_file(real_source .. "/project.lua", bytes)
  local real_recent = cm.require("cm.recent")
  local old_recent = real_recent.path
  real_recent.path = real_base .. "/recent.dat"
  real_recent.note(real_source)
  ok, detail = location.move_to(real_source, real_parent,
    { active_root = false, nonce = 91 })
  check(ok and detail == real_moved and pal.read_file(real_moved .. "/project.lua")
        and real_recent.contains(real_moved) and not real_recent.contains(real_source),
        "project location: real move probes parents then advances atomic recents")
  ok, detail = location.rename(real_moved, "renamed π project",
    { active_root = false, nonce = 92 })
  check(ok and detail == real_renamed
        and pal.read_file(real_renamed .. "/project.lua")
        and real_recent.contains(real_renamed),
        "project location: real rename preserves a valid UTF-8 project root")
  real_recent.path = old_recent
  pal.x_remove(real_renamed .. "/project.lua")
  pal.x_remove(real_renamed)
  pal.x_remove(real_parent)
  pal.x_remove(real_base .. "/recent.dat")
  pal.x_remove(real_base)
end

local function t_project_duplicate()
  local location = cm.require("cm.project_location")
  local project = cm.require("cm.project")
  local source, parent = "/projects/original π", "/dest parent"
  local bytes = project.PROJECT_TMPL:gsub("__NAME__", "duplicate test")
                          :gsub("__SAVEID__", "duplicate-test")

  local dirs, files, notes, note_calls
  local probe_fail, read_fail
  local function reset()
    dirs = {
      ["/projects"] = { type = "directory", link = false },
      [source] = { type = "directory", link = false },
      [source .. "/assets"] = { type = "directory", link = false },
      [source .. "/.ed"] = { type = "directory", link = false },
      [parent] = { type = "directory", link = false },
    }
    files = {
      [source .. "/project.lua"] = bytes,
      [source .. "/main.lua"] = "return {}",
      [source .. "/assets/hero π.spr"] = "SPRDATA",
      [source .. "/video.dat"] = "machine-local viewport",
      [source .. "/.ed/session.dat"] = "editor state",
    }
    notes, note_calls, probe_fail, read_fail = {}, 0, nil, nil
  end
  reset()
  local source_keys = {}
  for path in pairs(dirs) do source_keys[#source_keys + 1] = path end
  for path in pairs(files) do source_keys[#source_keys + 1] = path end
  local function source_intact()
    for _, path in ipairs(source_keys) do
      if path:sub(1, #source) == source and not (dirs[path] or files[path]) then
        return false
      end
    end
    return files[source .. "/project.lua"] == bytes
  end
  local function staging_leftover()
    for path in pairs(dirs) do
      if path:find(".cosmic-duplicate", 1, true) then return path end
    end
    for path in pairs(files) do
      if path:find(".cosmic-duplicate", 1, true) then return path end
    end
    return nil
  end

  local fs = {}
  function fs.info(path)
    if dirs[path] then return dirs[path] end
    local body = files[path]
    if body then return { type = "file", link = false, size = #body } end
    return nil, "not found"
  end
  function fs.read(path)
    if read_fail == path then return nil, "injected read failure" end
    local body = files[path]
    if body then return body end
    return nil, "not found"
  end
  function fs.probe(path)
    if path == probe_fail then return nil, "injected permission failure" end
    return true
  end
  -- Mirror pal.list_dir: recursive relative paths that prune dot-DIRECTORIES
  -- (dot files still appear).
  function fs.list(root)
    if not dirs[root] then return nil, "not a directory" end
    local prefix = root .. "/"
    local function pruned(rel)
      local acc = root
      for part in (rel .. "/"):gmatch("([^/]+)/") do
        acc = acc .. "/" .. part
        if part:sub(1, 1) == "." and dirs[acc] then return true end
      end
      return false
    end
    local out = {}
    for path in pairs(dirs) do
      if path:sub(1, #prefix) == prefix and not pruned(path:sub(#prefix + 1)) then
        out[#out + 1] = path:sub(#prefix + 1)
      end
    end
    for path in pairs(files) do
      if path:sub(1, #prefix) == prefix and not pruned(path:sub(#prefix + 1)) then
        out[#out + 1] = path:sub(#prefix + 1)
      end
    end
    return out
  end
  function fs.mkdir(path)
    if files[path] then return false end
    dirs[path] = dirs[path] or { type = "directory", link = false }
    return true
  end
  function fs.remove(path)
    if files[path] then files[path] = nil; return true end
    if dirs[path] then
      local prefix = path .. "/"
      for other in pairs(dirs) do
        if other:sub(1, #prefix) == prefix then return nil, "not empty" end
      end
      for other in pairs(files) do
        if other:sub(1, #prefix) == prefix then return nil, "not empty" end
      end
      dirs[path] = nil
      return true
    end
    return nil, "not found"
  end
  function fs.write_atomic(path, body, fail)
    if fail then return nil, "injected write failure" end
    local dir = path:match("^(.*)/[^/]+$")
    if not dirs[dir] then return nil, "no parent directory" end
    files[path] = body
    return true
  end
  function fs.move(from, to, fail)
    if fail then return nil, "injected publish failure" end
    if not dirs[from] or dirs[to] or files[to] then return nil, "collision" end
    local moved_dirs, moved_files, prefix = {}, {}, from .. "/"
    for path, value in pairs(dirs) do
      if path == from or path:sub(1, #prefix) == prefix then
        moved_dirs[to .. path:sub(#from + 1)] = value
        dirs[path] = nil
      end
    end
    for path, value in pairs(files) do
      if path:sub(1, #prefix) == prefix then
        moved_files[to .. path:sub(#from + 1)] = value
        files[path] = nil
      end
    end
    for path, value in pairs(moved_dirs) do dirs[path] = value end
    for path, value in pairs(moved_files) do files[path] = value end
    return true
  end
  local rec = {}
  function rec.note(path, fail)
    note_calls = note_calls + 1
    if fail then return nil, "injected recents failure" end
    table.insert(notes, 1, path)
    return true
  end

  local function run(name, opts)
    opts = opts or {}
    -- fs/recent default to the fakes; an explicit false selects the real PAL.
    if opts.fs == nil then opts.fs = fs elseif opts.fs == false then opts.fs = nil end
    if opts.recent == nil then opts.recent = rec
    elseif opts.recent == false then opts.recent = nil end
    if opts.active_root == nil then opts.active_root = false end
    opts.platform = opts.platform or (opts.fs and "linux") or nil
    opts.nonce = opts.nonce or 5
    local job = location.duplicate_start(opts.source or source,
                                         opts.parent or parent, name, opts)
    local steps = 0
    while not job.terminal and steps < 1000 do
      steps = steps + 1
      if opts.cancel_at and steps == opts.cancel_at then
        location.duplicate_cancel(job)
      end
      location.duplicate_step(job)
    end
    return job
  end

  local dest = parent .. "/original π copy"
  local job = run("original π copy")
  check(job.complete and job.published == dest and dirs[dest]
        and files[dest .. "/project.lua"] == bytes
        and files[dest .. "/main.lua"] == "return {}"
        and files[dest .. "/assets/hero π.spr"] == "SPRDATA"
        and job.name == "duplicate test",
        "project duplicate: staged copy publishes a complete valid project")
  check(not files[dest .. "/video.dat"] and not dirs[dest .. "/.ed"]
        and not files[dest .. "/.ed/session.dat"],
        "project duplicate: machine/editor state (.ed, video.dat) is omitted")
  check(source_intact() and not staging_leftover() and notes[1] == dest,
        "project duplicate: source is untouched, staging is gone, recents advanced")

  reset()
  job = run("original π copy", { active_root = source })
  check(job.error and job.error:find("return to the project picker", 1, true)
        and source_intact() and not staging_leftover(),
        "project duplicate: the currently open editor pins its root")

  reset()
  dirs[dest] = { type = "directory", link = false }
  job = run("original π copy")
  check(job.error and job.error:find("destination already exists", 1, true)
        and note_calls == 0 and not staging_leftover(),
        "project duplicate: destination collision fails before any copy")
  reset()
  job = run("nested copy", { parent = source })
  check(job.error and job.error:find("duplicated into itself", 1, true),
        "project duplicate: a project cannot be duplicated into itself")
  reset()
  probe_fail = parent
  job = run("original π copy")
  check(job.error and job.error:find("destination parent is not writable", 1, true),
        "project duplicate: destination permission failure is actionable")
  reset()
  dirs[source .. "/assets"].link = true
  job = run("original π copy")
  check(job.error and job.error:find("contains a link", 1, true)
        and not staging_leftover() and not dirs[dest],
        "project duplicate: links are refused instead of followed or flattened")

  reset()
  read_fail = source .. "/assets/hero π.spr"
  job = run("original π copy")
  check(job.error and job.error:find("cannot read", 1, true)
        and not staging_leftover() and not dirs[dest] and source_intact(),
        "project duplicate: read failure cleans staging and publishes nothing")
  reset()
  job = run("original π copy", { fail = { write = true } })
  check(job.error and job.error:find("cannot write", 1, true)
        and not staging_leftover() and not dirs[dest] and source_intact(),
        "project duplicate: write failure cleans staging and publishes nothing")
  reset()
  job = run("original π copy", { fail = { publish = true } })
  check(job.error and job.error:find("was not published", 1, true)
        and not staging_leftover() and not dirs[dest] and source_intact(),
        "project duplicate: publish failure cleans staging and publishes nothing")
  reset()
  job = run("original π copy", { fail = { recent = true } })
  check(job.error and job.error:find("recents could not update", 1, true)
        and job.error:find(dest, 1, true) and job.published == dest
        and dirs[dest] and #notes == 0 and not staging_leftover(),
        "project duplicate: recents failure names the finished new root")
  reset()
  job = run("original π copy", { cancel_at = 4 })
  check(job.cancelled and not job.complete and not dirs[dest]
        and not staging_leftover() and note_calls == 0 and source_intact(),
        "project duplicate: cancel mid-copy cleans staging and publishes nothing")

  -- Integrate with the real PAL primitives and atomic .recent.dat seam,
  -- including spaced/non-ASCII paths and injected native failures.
  local real_base = project.normalize_root(
    tmproot() .. "/cosmic_selftest_duplicate")
  local real_source = real_base .. "/source π project"
  local real_parent = real_base .. "/dest parent"
  local real_dest = real_parent .. "/copie π"
  local real_staging = real_parent .. "/.cosmic-duplicate.77.0"
  local function real_cleanup()
    for _, root in ipairs({ real_source, real_dest, real_staging }) do
      pal.x_remove(root .. "/.ed/session.dat")
      pal.x_remove(root .. "/.ed")
      pal.x_remove(root .. "/assets/hero π.spr")
      pal.x_remove(root .. "/assets")
      pal.x_remove(root .. "/project.lua")
      pal.x_remove(root .. "/main.lua")
      pal.x_remove(root .. "/video.dat")
      pal.x_remove(root)
    end
    pal.x_remove(real_parent)
    pal.x_remove(real_base .. "/recent.dat")
    pal.x_remove(real_base)
  end
  real_cleanup()
  pal.mkdir(real_base)
  pal.mkdir(real_source)
  pal.mkdir(real_source .. "/assets")
  pal.mkdir(real_source .. "/.ed")
  pal.mkdir(real_parent)
  pal.write_file(real_source .. "/project.lua", bytes)
  pal.write_file(real_source .. "/main.lua", "return {}")
  pal.write_file(real_source .. "/assets/hero π.spr", "SPRDATA")
  pal.write_file(real_source .. "/video.dat", "machine-local")
  pal.write_file(real_source .. "/.ed/session.dat", "editor state")
  local real_recent = cm.require("cm.recent")
  local old_recent = real_recent.path
  real_recent.path = real_base .. "/recent.dat"

  job = run("copie π", { fs = false, recent = false, source = real_source,
                         parent = real_parent, nonce = 77,
                         fail = { write = { _fail = "rename" } } })
  check(job.error and job.error:find("cannot write", 1, true)
        and not pal.x_path_info(real_staging)
        and not pal.x_path_info(real_dest)
        and pal.read_file(real_source .. "/project.lua") == bytes,
        "project duplicate: real atomic-write failure cleans staged files")
  job = run("copie π", { fs = false, recent = false, source = real_source,
                         parent = real_parent, nonce = 77,
                         fail = { publish = { _fail = "rename" } } })
  check(job.error and job.error:find("was not published", 1, true)
        and not pal.x_path_info(real_staging)
        and not pal.x_path_info(real_dest),
        "project duplicate: real publish failure cleans complete staging")
  job = run("copie π", { fs = false, recent = false, source = real_source,
                         parent = real_parent, nonce = 77 })
  check(job.complete and job.published == real_dest
        and pal.read_file(real_dest .. "/project.lua") == bytes
        and pal.read_file(real_dest .. "/assets/hero π.spr") == "SPRDATA"
        and not pal.x_path_info(real_dest .. "/video.dat")
        and not pal.x_path_info(real_dest .. "/.ed")
        and not pal.x_path_info(real_staging)
        and real_recent.contains(real_dest)
        and pal.read_file(real_source .. "/video.dat") == "machine-local",
        "project duplicate: real spaced/UTF-8 duplicate publishes and registers")
  real_recent.path = old_recent
  real_cleanup()
end

-- Decode the stored-block (uncompressed-deflate) archives cm.archive writes,
-- so tests verify exact member bytes rather than substrings.
local function read_archive(bytes, format)
  local out = {}
  if format == "zip" then
    local at = 1
    while at + 3 <= #bytes
          and string.unpack("<I4", bytes, at) == 0x04034b50 do
      local size = string.unpack("<I4", bytes, at + 18)
      local nlen, elen = string.unpack("<I2I2", bytes, at + 26)
      local name = bytes:sub(at + 30, at + 29 + nlen)
      at = at + 30 + nlen + elen
      out[name] = bytes:sub(at, at + size - 1)
      at = at + size
    end
    return out
  end
  -- gzip with stored deflate blocks: 10-byte header, then (final, len, ~len).
  local at, chunks = 11, {}
  while at <= #bytes - 8 do
    local head = bytes:byte(at)
    local len = string.unpack("<I2", bytes, at + 1)
    chunks[#chunks + 1] = bytes:sub(at + 5, at + 4 + len)
    at = at + 5 + len
    if head & 1 == 1 then break end
  end
  local tar = table.concat(chunks)
  at = 1
  while at + 511 <= #tar do
    local block = tar:sub(at, at + 511)
    if block:byte(1) == 0 then break end
    local name = block:sub(1, 100):gsub("%z.*", "")
    local prefix = block:sub(346, 500):gsub("%z.*", "")
    local size = tonumber(block:sub(125, 135), 8) or 0
    local typeflag = block:sub(157, 157)
    local full = prefix ~= "" and (prefix .. "/" .. name) or name
    at = at + 512
    if typeflag == "5" then
      out[full] = ""
    else
      out[full] = tar:sub(at, at + size - 1)
      at = at + size + ((-size) % 512)
    end
  end
  return out
end

local function t_project_archive()
  local location = cm.require("cm.project_location")
  local project = cm.require("cm.project")
  local source, parent = "/projects/original π", "/dest parent"
  local bytes = project.PROJECT_TMPL:gsub("__NAME__", "archive test")
                          :gsub("__SAVEID__", "archive-test")

  -- cm.export re-declares these so the host packager can dofile() it without
  -- the cm global; the values must stay the shared writer's exact limits.
  check(cm.require("cm.export").MAX_FILE == cm.require("cm.archive").MAX_FILE
        and cm.require("cm.export").MAX_ZIP_ENTRIES
            == cm.require("cm.archive").MAX_ZIP_ENTRIES,
        "project archive: export mirrors the shared ZIP32 limits exactly")

  local dirs, files, probe_fail
  local function reset()
    dirs = {
      ["/projects"] = { type = "directory", link = false },
      [source] = { type = "directory", link = false },
      [source .. "/assets"] = { type = "directory", link = false },
      [source .. "/.ed"] = { type = "directory", link = false },
      [parent] = { type = "directory", link = false },
    }
    files = {
      [source .. "/project.lua"] = bytes,
      [source .. "/main.lua"] = "return {}",
      [source .. "/assets/hero π.spr"] = "SPRDATA",
      [source .. "/video.dat"] = "machine-local viewport",
      [source .. "/.ed/session.dat"] = "editor state",
    }
    probe_fail = nil
  end
  reset()
  local source_keys = {}
  for path in pairs(dirs) do source_keys[#source_keys + 1] = path end
  for path in pairs(files) do source_keys[#source_keys + 1] = path end
  local function source_intact()
    for _, path in ipairs(source_keys) do
      if path:sub(1, #source) == source and not (dirs[path] or files[path]) then
        return false
      end
    end
    return files[source .. "/project.lua"] == bytes
  end
  local function temp_leftover()
    for path in pairs(files) do
      if path:find(".tmp.", 1, true) then return path end
    end
    return nil
  end

  local fs = {}
  function fs.info(path)
    if dirs[path] then return dirs[path] end
    local body = files[path]
    if body then return { type = "file", link = false, size = #body } end
    return nil, "not found"
  end
  function fs.read(path)
    local body = files[path]
    if body then return body end
    return nil, "not found"
  end
  function fs.probe(path)
    if path == probe_fail then return nil, "injected permission failure" end
    return true
  end
  function fs.list(root)
    if not dirs[root] then return nil, "not a directory" end
    local prefix = root .. "/"
    local function pruned(rel)
      local acc = root
      for part in (rel .. "/"):gmatch("([^/]+)/") do
        acc = acc .. "/" .. part
        if part:sub(1, 1) == "." and dirs[acc] then return true end
      end
      return false
    end
    local out = {}
    for path in pairs(dirs) do
      if path:sub(1, #prefix) == prefix and not pruned(path:sub(#prefix + 1)) then
        out[#out + 1] = path:sub(#prefix + 1)
      end
    end
    for path in pairs(files) do
      if path:sub(1, #prefix) == prefix and not pruned(path:sub(#prefix + 1)) then
        out[#out + 1] = path:sub(#prefix + 1)
      end
    end
    return out
  end
  function fs.remove(path)
    if files[path] then files[path] = nil; return true end
    if dirs[path] then dirs[path] = nil; return true end
    return nil, "not found"
  end
  function fs.append(path, chunk)
    files[path] = (files[path] or "") .. chunk
    return true
  end
  function fs.publish(temp, final, opts)
    if opts and opts._fail then return nil, "injected publish failure" end
    if not files[temp] then return nil, "missing temporary archive" end
    if not (opts and opts._replace) and (files[final] or dirs[final]) then
      return nil, "destination already exists: " .. final
    end
    files[final], files[temp] = files[temp], nil
    return true
  end
  fs.crc = pal.crc32

  local function run(opts)
    opts = opts or {}
    if opts.fs == nil then opts.fs = fs elseif opts.fs == false then opts.fs = nil end
    if opts.active_root == nil then opts.active_root = false end
    opts.platform = opts.platform or (opts.fs and "linux") or nil
    opts.nonce = opts.nonce or 5
    opts.stamp = opts.stamp or "2026-07-16"
    local job = location.archive_start(opts.source or source,
                                       opts.parent or parent, opts)
    local steps = 0
    while not job.terminal and steps < 1000 do
      steps = steps + 1
      if opts.cancel_at and steps == opts.cancel_at then
        location.archive_cancel(job)
      end
      location.archive_step(job)
    end
    return job
  end

  local dest = parent .. "/original π 2026-07-16.tar.gz"
  local job = run()
  local members = job.complete and read_archive(files[dest] or "", "tar.gz")
  check(job.complete and job.published == dest and members
        and members["original π/project.lua"] == bytes
        and members["original π/main.lua"] == "return {}"
        and members["original π/assets/hero π.spr"] == "SPRDATA"
        and members["original π/assets/"] == ""
        and job.name == "archive test",
        "project archive: dated tar.gz carries exact saved project bytes")
  check(members and not members["original π/video.dat"]
        and not members["original π/.ed/session.dat"]
        and not (files[dest] or ""):find("machine-local", 1, true)
        and not (files[dest] or ""):find("editor state", 1, true),
        "project archive: machine/editor state (.ed, video.dat) is omitted")
  check(source_intact() and not temp_leftover(),
        "project archive: source is untouched and no temp remains")

  local second = run()
  check(second.complete
        and second.published == parent .. "/original π 2026-07-16 (2).tar.gz"
        and files[dest] and files[second.published],
        "project archive: a same-day collision picks the next free name")
  files[second.published] = nil

  local zjob = run { platform = "windows" }
  local zdest = parent .. "/original π 2026-07-16.zip"
  local zmembers = zjob.complete and read_archive(files[zdest] or "", "zip")
  check(zjob.complete and zjob.published == zdest and zmembers
        and zmembers["original π/project.lua"] == bytes
        and zmembers["original π/assets/"] == ""
        and not zmembers["original π/video.dat"],
        "project archive: the Windows host emits the same tree as a ZIP")
  files[zdest] = nil
  files[dest] = nil

  reset()
  job = run { active_root = source }
  check(job.error and job.error:find("return to the project picker", 1, true)
        and source_intact() and not temp_leftover(),
        "project archive: the currently open editor pins its root")
  reset()
  job = run { parent = source .. "/assets" }
  check(job.error and job.error:find("archived into itself", 1, true),
        "project archive: a project cannot be archived into itself")
  reset()
  dirs[source].link = true
  job = run()
  check(job.error and job.error:find("alias cannot archive", 1, true),
        "project archive: an alias source is refused before any write")
  reset()
  probe_fail = parent
  job = run()
  check(job.error and job.error:find("destination is not writable", 1, true),
        "project archive: destination permission failure is actionable")
  reset()
  dirs[source .. "/assets"].link = true
  job = run()
  check(job.error and job.error:find("contains a link", 1, true)
        and not temp_leftover() and not files[dest],
        "project archive: links are refused instead of followed or flattened")

  reset()
  job = run { fail = { append = true } }
  check(job.error and job.error:find("cannot write", 1, true)
        and not temp_leftover() and not files[dest] and source_intact(),
        "project archive: append failure cleans the temp and publishes nothing")
  reset()
  job = run { fail = { publish = true } }
  check(job.error and job.error:find("was not published", 1, true)
        and not temp_leftover() and not files[dest] and source_intact(),
        "project archive: publish failure cleans the temp and publishes nothing")
  reset()
  job = run { cancel_at = 4 }
  check(job.cancelled and not job.complete and not files[dest]
        and not temp_leftover() and source_intact(),
        "project archive: cancel mid-stream cleans the temp and publishes nothing")

  -- Integrate with the real PAL primitives over spaced/non-ASCII paths.
  local real_base = project.normalize_root(
    tmproot() .. "/cosmic_selftest_archive")
  local real_source = real_base .. "/source π project"
  local real_parent = real_base .. "/dest parent"
  local real_ext = pal.platform == "windows" and ".zip" or ".tar.gz"
  local real_dest = real_parent .. "/source π project 2026-07-16" .. real_ext
  local function real_cleanup()
    for _, rel in ipairs({ "/.ed/session.dat", "/.ed", "/assets/hero π.spr",
                           "/assets", "/project.lua", "/main.lua",
                           "/video.dat" }) do
      pal.x_remove(real_source .. rel)
    end
    pal.x_remove(real_source)
    for _, rel in ipairs(pal.x_list_dir_all(real_parent) or {}) do
      pal.x_remove(real_parent .. "/" .. rel)
    end
    pal.x_remove(real_parent)
    pal.x_remove(real_base)
  end
  real_cleanup()
  pal.mkdir(real_base)
  pal.mkdir(real_source)
  pal.mkdir(real_source .. "/assets")
  pal.mkdir(real_source .. "/.ed")
  pal.mkdir(real_parent)
  pal.write_file(real_source .. "/project.lua", bytes)
  pal.write_file(real_source .. "/main.lua", "return {}")
  pal.write_file(real_source .. "/assets/hero π.spr", "SPRDATA")
  pal.write_file(real_source .. "/video.dat", "machine-local")
  pal.write_file(real_source .. "/.ed/session.dat", "editor state")

  check(pal.version.api >= 17 and type(pal.x_list_dir_all) == "function",
        "project archive: PAL api17 exposes the unpruned listing")
  local pruned = pal.list_dir(real_source) or {}
  local everything = pal.x_list_dir_all(real_source) or {}
  local seen = {}
  for _, rel in ipairs(everything) do seen[rel] = true end
  local pruned_hit = false
  for _, rel in ipairs(pruned) do
    if rel:find("^%.ed") then pruned_hit = true end
  end
  check(not pruned_hit and seen[".ed"] and seen[".ed/session.dat"]
        and seen["project.lua"] and seen["assets/hero π.spr"],
        "pal.x_list_dir_all: dot tool state is listed only by the unpruned walk")

  job = run { fs = false, source = real_source, parent = real_parent,
              nonce = 88, fail = { publish = { _fail = "rename" } } }
  check(job.error and job.error:find("was not published", 1, true)
        and not pal.x_path_info(real_dest)
        and #(pal.x_list_dir_all(real_parent) or {}) == 0,
        "project archive: real publish failure cleans the staged temp")
  job = run { fs = false, source = real_source, parent = real_parent,
              nonce = 88 }
  local real_bytes = job.complete and pal.read_file(job.published or "")
  local real_members = real_bytes
    and read_archive(real_bytes, pal.platform == "windows" and "zip" or "tar.gz")
  check(job.complete and job.published == real_dest and real_members
        and real_members["source π project/project.lua"] == bytes
        and real_members["source π project/assets/hero π.spr"] == "SPRDATA"
        and not real_members["source π project/video.dat"]
        and not real_members["source π project/.ed/session.dat"]
        and pal.read_file(real_source .. "/project.lua") == bytes,
        "project archive: real spaced/UTF-8 archive publishes exact bytes")
  real_cleanup()
end

local function t_project_delete()
  local location = cm.require("cm.project_location")
  local project = cm.require("cm.project")
  local source = "/projects/original π"
  local bytes = project.PROJECT_TMPL:gsub("__NAME__", "delete test")
                          :gsub("__SAVEID__", "delete-test")

  local dirs, files, rec
  local function reset()
    dirs = {
      ["/projects"] = { type = "directory", link = false },
      [source] = { type = "directory", link = false },
      [source .. "/assets"] = { type = "directory", link = false },
      [source .. "/.ed"] = { type = "directory", link = false },
    }
    files = {
      [source .. "/project.lua"] = bytes,
      [source .. "/main.lua"] = "return {}",
      [source .. "/assets/hero π.spr"] = "SPRDATA",
      [source .. "/video.dat"] = "machine-local viewport",
      [source .. "/.ed/session.dat"] = "editor state",
    }
    rec = { has = true }
    function rec.contains(path) return rec.has and path == source end
    function rec.remove(path, fail)
      if fail then return nil, "injected recents failure" end
      if path ~= source then return nil, "unexpected recents removal" end
      rec.has = false
      return true
    end
  end
  reset()
  local source_keys = {}
  for path in pairs(dirs) do source_keys[#source_keys + 1] = path end
  for path in pairs(files) do source_keys[#source_keys + 1] = path end
  local function source_intact()
    for _, path in ipairs(source_keys) do
      if path:sub(1, #source) == source and not (dirs[path] or files[path]) then
        return false
      end
    end
    return files[source .. "/project.lua"] == bytes
  end
  local function anything_left()
    if dirs[source] then return true end
    local prefix = source .. "/"
    for path in pairs(dirs) do
      if path:sub(1, #prefix) == prefix then return true end
    end
    for path in pairs(files) do
      if path:sub(1, #prefix) == prefix then return true end
    end
    return false
  end

  local fs = {}
  function fs.info(path)
    if dirs[path] then return dirs[path] end
    local body = files[path]
    if body then return { type = "file", link = false, size = #body } end
    return nil, "not found"
  end
  function fs.read(path)
    local body = files[path]
    if body then return body end
    return nil, "not found"
  end
  function fs.probe() return true end
  function fs.list_all(root)
    if not dirs[root] then return nil, "not a directory" end
    local prefix = root .. "/"
    local out = {}
    for path in pairs(dirs) do
      if path:sub(1, #prefix) == prefix then out[#out + 1] = path:sub(#prefix + 1) end
    end
    for path in pairs(files) do
      if path:sub(1, #prefix) == prefix then out[#out + 1] = path:sub(#prefix + 1) end
    end
    return out
  end
  function fs.remove(path)
    if files[path] then files[path] = nil; return true end
    if dirs[path] then
      local prefix = path .. "/"
      for other in pairs(dirs) do
        if other:sub(1, #prefix) == prefix then return nil, "not empty" end
      end
      for other in pairs(files) do
        if other:sub(1, #prefix) == prefix then return nil, "not empty" end
      end
      dirs[path] = nil
      return true
    end
    return nil, "not found"
  end

  local function run(opts)
    opts = opts or {}
    if opts.fs == nil then opts.fs = fs elseif opts.fs == false then opts.fs = nil end
    if opts.recent == nil then opts.recent = rec
    elseif opts.recent == false then opts.recent = nil end
    if opts.active_root == nil then opts.active_root = false end
    opts.platform = opts.platform or (opts.fs and "linux") or nil
    opts.nonce = opts.nonce or 5
    if opts.confirm == nil then opts.confirm = "original π" end
    local job = location.delete_start(opts.source or source, opts)
    local steps = 0
    while not job.terminal and steps < 1000 do
      steps = steps + 1
      if opts.cancel_at and steps == opts.cancel_at then
        location.delete_cancel(job)
      end
      location.delete_step(job)
    end
    return job
  end

  local job = run { confirm = "original" }
  check(job.error and job.error:find("exact folder name", 1, true)
        and source_intact() and rec.has,
        "project delete: a wrong confirmation deletes nothing")
  job = run { active_root = source }
  check(job.error and job.error:find("return to the project picker", 1, true)
        and source_intact(),
        "project delete: the currently open editor pins its root")
  rec.has = false
  job = run()
  check(job.error and job.error:find("recent tile", 1, true) and source_intact(),
        "project delete: deletion requires the recent tile as recovery handle")
  reset()
  dirs[source].link = true
  job = run()
  check(job.error and job.error:find("alias cannot be deleted", 1, true)
        and rec.has,
        "project delete: an alias source is refused")
  reset()
  dirs[source .. "/assets"].link = true
  job = run()
  check(job.error and job.error:find("contains a link", 1, true)
        and source_intact() and rec.has,
        "project delete: links are refused before the first removal")

  reset()
  job = run()
  check(job.complete and not anything_left() and not rec.has
        and job.deleted and job.name == "delete test",
        "project delete: confirmed delete removes the whole tree then the tile")

  reset()
  job = run { fail = { remove = ".ed/session.dat" } }
  check(job.error and job.error:find("remaining project files were kept", 1, true)
        and not files[source .. "/project.lua"]
        and files[source .. "/main.lua"] == "return {}"
        and rec.has and dirs[source],
        "project delete: project.lua goes first and a failure keeps the tile")
  job = run()
  check(job.complete and not anything_left() and not rec.has,
        "project delete: a half-deleted tree stays deletable on retry")

  reset()
  job = run { cancel_at = 6 }
  check(job.cancelled and not job.complete and rec.has and anything_left()
        and (job.removed or 0) > 0,
        "project delete: cancel keeps the tile and reports partial removal")

  reset()
  job = run { fail = { root = true } }
  check(job.error and job.error:find("cannot remove " .. source, 1, true)
        and rec.has and dirs[source]
        and not files[source .. "/project.lua"],
        "project delete: a root failure keeps the tile pointing at the shell")

  reset()
  job = run { fail = { recent = true } }
  check(job.error
        and job.error:find("recent tile could not be removed", 1, true)
        and job.deleted and not anything_left() and rec.has,
        "project delete: a recents failure names the honest missing tile")

  -- Integrate with the real PAL + atomic .recent.dat seam over spaced/UTF-8
  -- paths, including dot tool state that only x_list_dir_all can see.
  local real_base = project.normalize_root(
    tmproot() .. "/cosmic_selftest_delete")
  local real_source = real_base .. "/source π project"
  local function real_fixture()
    pal.mkdir(real_base)
    pal.mkdir(real_source)
    pal.mkdir(real_source .. "/assets")
    pal.mkdir(real_source .. "/.ed")
    pal.write_file(real_source .. "/project.lua", bytes)
    pal.write_file(real_source .. "/main.lua", "return {}")
    pal.write_file(real_source .. "/assets/hero π.spr", "SPRDATA")
    pal.write_file(real_source .. "/video.dat", "machine-local")
    pal.write_file(real_source .. "/.ed/session.dat", "editor state")
  end
  local function real_teardown()
    for _, rel in ipairs(pal.x_list_dir_all(real_source) or {}) do
      pal.x_remove(real_source .. "/" .. rel)
    end
    pal.x_remove(real_source)
    pal.x_remove(real_base .. "/recent.dat")
    pal.x_remove(real_base)
  end
  real_teardown()
  real_fixture()
  local real_recent = cm.require("cm.recent")
  local old_recent = real_recent.path
  real_recent.path = real_base .. "/recent.dat"
  real_recent.note(real_source)

  job = run { fs = false, recent = false, source = real_source,
              confirm = "source π project", nonce = 99,
              fail = { remove = "main.lua" } }
  check(job.error and job.error:find("remaining project files were kept", 1, true)
        and not pal.x_path_info(real_source .. "/project.lua")
        and pal.read_file(real_source .. "/main.lua") == "return {}"
        and real_recent.contains(real_source),
        "project delete: a real partial failure keeps a repairable tile")
  job = run { fs = false, recent = false, source = real_source,
              confirm = "source π project", nonce = 99 }
  check(job.complete and job.deleted
        and not pal.x_path_info(real_source)
        and not real_recent.contains(real_source),
        "project delete: real retry finishes the half-deleted tree and tile")
  -- A fresh fixture proves the one-shot real delete, including .ed.
  real_fixture()
  real_recent.note(real_source)
  job = run { fs = false, recent = false, source = real_source,
              confirm = "source π project", nonce = 99 }
  check(job.complete and job.deleted
        and not pal.x_path_info(real_source)
        and not real_recent.contains(real_source),
        "project delete: real spaced/UTF-8 delete removes tree, .ed, and tile")
  real_recent.path = old_recent
  real_teardown()
end

local function t_project_export()
  local export = cm.require("cm.export")
  local project = cm.require("cm.project")
  local base = tmproot() .. "/cosmic_selftest_export"
  local runtime, root, output = base .. "/runtime", base .. "/fixture-project",
                                base .. "/out"
  local function rm_tree(path)
    local names = pal.list_dir(path) or {}
    table.sort(names, function(a, b) return #a > #b end)
    for _, name in ipairs(names) do pal.x_remove(path .. "/" .. name) end
    pal.x_remove(path)
  end
  rm_tree(base)
  local function put(path, bytes)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then pal.mkdir(dir) end
    check(pal.write_file(path, bytes or path) == true,
          "export fixture: write " .. path)
  end

  -- A deliberately tiny portable-runtime shape. The exporter cares about
  -- carried paths and exact bytes, not whether this fixture's fake engine can
  -- execute; clean-machine tests own the real runtime proof.
  put(runtime .. "/engine/boot.lua", "return true\n")
  put(runtime .. "/projects/picker/main.lua", "return {}\n")
  put(runtime .. "/LICENSE", "engine license\n")
  put(runtime .. "/THIRD_PARTY_NOTICES.md", "notices\n")
  put(runtime .. "/LICENSES/README.md", "license index\n")
  put(runtime .. "/LICENSES/common/README.txt", "common notices\n")
  put(runtime .. "/LICENSES/" .. pal.platform .. "-runtime/README.txt",
      "runtime notices\n")
  put(runtime .. "/pal/shaders/quad.spv", "shader")
  put(runtime .. "/pal/vendor/fonts/font.ttf", "font")
  put(runtime .. "/pal/res/cosmic2d.png", "engine icon")
  if pal.platform == "linux" then
    put(runtime .. "/bin/cosmic", "fake linux engine")
    put(runtime .. "/cosmic2d-editor", "fake root engine")
    put(runtime .. "/lib/libSDL3.so.0", "fake shared object")
  else
    put(runtime .. "/bin/cosmic.exe", "fake windows engine")
    put(runtime .. "/bin/cosmic-console.exe", "fake console engine")
    put(runtime .. "/bin/cosmic-player.exe", "fake player launcher")
    put(runtime .. "/bin/SDL3.dll", "fake runtime dll")
    put(runtime .. "/cosmic2d-editor.exe", "fake root engine")
  end

  local icon = pal.png_encode(string.rep("\x46\x82\xb4\xff", 32 * 32), 32, 32)
  put(root .. "/icon.png", icon)
  put(root .. "/CONTROLS.md", "jump\n")
  put(root .. "/CREDITS.md", "selftest\n")
  put(root .. "/LICENSE.md", "fixture license\n")
  put(root .. "/main.lua", "return { init=function() end }\n")
  put(root .. "/video.dat", "machine local -- must not ship")
  put(root .. "/.ed/secret.dat", "recovery cache -- must not ship")
  local meta = {
    name = "Fixture Game", author = "cosmic selftest", version = "1.2",
    description = "A release fixture.", internal_w = 64, internal_h = 64,
    window_scale = 2, entry = "main.lua", icon = "icon.png",
    controls = "CONTROLS.md", credits = "CREDITS.md",
    licenses = { "LICENSE.md" },
  }
  put(root .. "/project.lua", assert(project.encode(meta)))
  pal.mkdir(output)

  local function finish(job)
    local guard = 0
    while not job.terminal and guard < 1000 do
      export.step(job)
      guard = guard + 1
    end
    check(guard < 1000, "export: bounded fixture job finishes")
    return job
  end
  local opts = { runtime_root = runtime, project_root = root,
                 output_dir = output, target = pal.platform, nonce = 101,
                 skip_windows_identity = true }
  local job = finish(export.start(opts))
  check(job.complete and not job.error and pal.read_file(job.output),
        "export: matching-host fixture publishes an archive")
  local archive = pal.read_file(job.output)
  check((pal.platform == "linux" and archive:sub(1, 3) == "\31\139\8")
        or (pal.platform == "windows" and archive:sub(1, 4) == "PK\3\4"),
        "export: host archive has the promised gzip/ZIP container")
  check(archive:find("projects/fixture%-project/main.lua")
        and archive:find("SHA256SUMS", 1, true)
        and archive:find("RUNTIME%-LIBRARIES.txt")
        and not archive:find("machine local", 1, true)
        and not archive:find("recovery cache", 1, true),
        "export: archive carries source + integrity metadata, not machine cache")
  local sibling = pal.read_file(job.output .. ".sha256")
  check(sibling == pal.sha256_file(job.output) .. "  "
        .. job.output:match("([^/\\]+)$") .. "\n",
        "export: sibling checksum names and hashes exact published bytes")

  -- Cancellation occurs only at a yielded file boundary. It removes the
  -- sibling temp and never creates either authoritative output.
  pal.x_remove(job.output .. ".sha256"); pal.x_remove(job.output)
  local cancel = export.start {
    runtime_root = runtime, project_root = root, output_dir = output,
    target = pal.platform, nonce = 102, skip_windows_identity = true,
  }
  for _ = 1, 5 do export.step(cancel) end
  check(export.cancel(cancel), "export: active job accepts cancel")
  finish(cancel)
  check(cancel.cancelled and not pal.read_file(cancel.output)
        and (not cancel.temp or not pal.read_file(cancel.temp)),
        "export: cancel removes temp and publishes nothing")

  -- A final-rename fault has the same authority shape and remains retryable.
  local failed = finish(export.start {
    runtime_root = runtime, project_root = root, output_dir = output,
    target = pal.platform, nonce = 103, skip_windows_identity = true,
    fail = { publish = { _fail = "rename" } },
  })
  check(failed.error and failed.error:find("publish", 1, true)
        and not pal.read_file(failed.output)
        and (not failed.temp or not pal.read_file(failed.temp)),
        "export: publication failure is actionable and non-authoritative")

  local other = pal.platform == "linux" and "windows" or "linux"
  local wrong = finish(export.start {
    runtime_root = runtime, project_root = root, output_dir = output,
    target = other, nonce = 104,
  })
  check(wrong.error and wrong.error:find("matching cosmic2d editor", 1, true),
        "export: unsupported cross-target explains the matching download")
  rm_tree(base)
end

-- ---- D081 starter templates: registry, substitution, boot smokes ----

local function t_project_templates()
  local project = cm.require("cm.project")
  local input = cm.require("cm.input")

  -- the registry: five starters, blank first (the no-template default)
  check(#project.TEMPLATES == 5 and project.TEMPLATES[1].key == "blank",
        "templates: registry offers five starters, blank first")
  local seen = {}
  for _, t in ipairs(project.TEMPLATES) do
    check(type(t.key) == "string" and type(t.label) == "string"
          and type(t.note) == "string" and not seen[t.key],
          "templates: entry " .. tostring(t.key) .. " is complete and unique")
    seen[t.key] = true
  end
  check(project.template() == project.TEMPLATES[1],
        "templates: nil resolves to the blank default")
  local unknown, uerr = project.template("roguelike")
  check(not unknown and uerr:find("roguelike", 1, true),
        "templates: an unknown key is an explicit error")

  -- template sources: blank is embedded; the others are real stock files
  check(project.template_main("blank") == project.MAIN_TMPL,
        "templates: blank main is the embedded scaffold source")
  for _, t in ipairs(project.TEMPLATES) do
    local src = project.template_main(t.key)
    check(type(src) == "string" and src:find("__NAME__", 1, true) ~= nil
          and src:find("return game", 1, true) ~= nil,
          "templates: " .. t.key .. " source is a substitutable game")
  end
  local missing, merr = project.template_main("arcade", function()
    return nil, "io injected"
  end)
  check(not missing
        and merr:find("engine/stock/templates/arcade.lua", 1, true)
        and merr:find("io injected", 1, true),
        "templates: an unreadable template names its stock path")

  -- an unreadable template fails scaffold before any filesystem effect
  local dir = tmproot() .. "/cosmic_selftest_template"
  local function rm_dir()
    pal.x_remove(dir .. "/main.lua")
    pal.x_remove(dir .. "/project.lua")
    -- the explore3d starter generates assets on first boot; without
    -- these the dir survives rm and the NEXT selftest run (the shared
    -- tmp) fails the no-partial-project check on stale debris
    pal.x_remove(dir .. "/world.terr")
    pal.x_remove(dir .. "/art/mascot.fig")
    pal.x_remove(dir .. "/art")
    pal.x_remove(dir)
  end
  rm_dir()
  local ok, err = project.scaffold(dir, "tpl", { read = function()
    return nil, "io injected"
  end }, "topdown")
  check(not ok and err:find("topdown", 1, true)
        and not pal.x_path_info(dir),
        "templates: a template read failure leaves no partial project")

  -- a hostile-but-legal folder name survives embedding into generated Lua
  -- (windows filenames cannot hold quotes/backslashes; percent is enough)
  local tricky = pal.platform == "windows" and "100% new name"
                 or '100% "new"\\name'
  ok, err = project.scaffold(dir, tricky)
  check(ok == true,
        "templates: tricky-name scaffold succeeds (" .. tostring(err) .. ")")
  local meta = project.decode(pal.read_file(dir .. "/project.lua"), "@tpl")
  check(meta ~= nil and meta.name == tricky and meta.description == ""
        and project.validate_runtime(meta) == true,
        "templates: tricky name round-trips exactly; blank stays a draft")
  check(load(pal.read_file(dir .. "/main.lua"), "@tpl", "t", {}) ~= nil,
        "templates: generated source with a tricky name still parses")
  rm_dir()

  -- boot smoke: every starter scaffolds, loads, inits, and simulates 120
  -- frames in a scratch doc with no input. Action defs and the doc are
  -- restored afterwards so this stays invisible to the rest of the suite.
  local saved_doc = state.doc
  local saved_bits = {}
  for k, v in pairs(input.bit_of) do saved_bits[k] = v end
  local saved_defs = {}
  for di, d in ipairs(input.defs) do
    local defaults = {}
    for j, c in ipairs(d.defaults) do defaults[j] = c end
    saved_defs[di] = { name = d.name, defaults = defaults }
  end
  for _, t in ipairs(project.TEMPLATES) do
    rm_dir()
    check(project.scaffold(dir, "smoke-" .. t.key, nil, t.key) == true,
          "templates: " .. t.key .. " scaffolds")
    local bytes = pal.read_file(dir .. "/main.lua")
    check(bytes ~= nil and not bytes:find("__NAME__", 1, true)
          and bytes:find("smoke-" .. t.key, 1, true) ~= nil,
          "templates: " .. t.key .. " substitutes every placeholder")
    local pmeta = project.decode(pal.read_file(dir .. "/project.lua"), "@tpl")
    check(pmeta ~= nil and project.validate_runtime(pmeta) == true
          and (t.key == "blank") == (pmeta.description == "")
          and (t.key == "blank"
               or pmeta.description:find(t.label, 1, true) ~= nil),
          "templates: " .. t.key .. " metadata boots and names provenance")
    check(pmeta ~= nil and pmeta.template == t.key,
          "templates: " .. t.key .. " records its starter key (D145)")
    local chunk, cerr = load(bytes, "@" .. dir .. "/main.lua")
    check(chunk ~= nil,
          "templates: " .. t.key .. " loads (" .. tostring(cerr) .. ")")
    -- boot with the scratch dir AS the project (explore3d captures
    -- cm.main.args.project at LOAD time and writes its world.terr /
    -- mascot.fig beside main.lua — the real boot semantics), so the
    -- override must wrap chunk(), not just init
    local saved_proj = cm.main.args.project
    cm.main.args.project = dir
    local game2 = chunk()
    check(type(game2) == "table" and type(game2.init) == "function"
          and type(game2.step) == "function"
          and type(game2.draw) == "function",
          "templates: " .. t.key .. " returns an init/step/draw game")
    state.doc = {}
    game2.init()
    -- neutral input: earlier input KATs may have left bits held in the
    -- applied record; two zero records clear both levels and edges
    local zero = string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0)
    input.apply(zero)
    input.apply(zero)
    for _ = 1, 120 do game2.step() end
    cm.main.args.project = saved_proj
    state.doc.canary = 7
    game2.init() -- the hot-reload contract: init must not reset a live run
    local d = state.doc
    check(d.canary == 7, "templates: " .. t.key .. " init is reload-safe")
    if t.key == "arcade" then
      -- the spawn clock puts exactly two rocks in play by frame 120; at
      -- the selftest cartridge's tiny resolution a rock may already have
      -- slipped past, so the invariant is the accounting, not the count:
      -- with no shots fired, every spawn is still falling or cost a life
      check(d.t == 120 and d.score == 0
            and (#d.rocks + (3 - d.lives)) == 2,
            "templates: arcade rock accounting holds on its spawn clock")
    elseif t.key == "platformer" then
      check(d.grounded == true and d.won == false,
            "templates: platformer settles on the ground")
    elseif t.key == "topdown" then
      check(d.count == 0 and #d.got == 6,
            "templates: topdown tracks its gems")
    elseif t.key == "explore3d" then
      -- the vale booted from its own generated .terr: the player stands
      -- at the file's spawn, the npc walked some of its route
      check(type(d.x) == "number" and type(d.z) == "number"
            and type(d.nx) == "number" and d.nphase > 0,
            "templates: explore3d walks its generated vale")
      -- drop the terr3 slot the boot published (suite hygiene: the
      -- captured buffers must not leak into later tests)
      local terr3 = cm.require("cm.terr3")
      terr3._slots["world"] = nil
      terr3.cur = nil
      pal.buf_free("world.t3state")
      pal.buf_free("cm.terr3.current")
    else
      check(type(d.x) == "number" and type(d.y) == "number",
            "templates: blank owns a movable dot")
    end
  end
  state.doc = saved_doc
  -- rebuild the map through define() so the restored defs are functional
  -- (parsed binds, not just the saved canonical strings)
  input.defs, input.bit_of = {}, {}
  for _, d in ipairs(saved_defs) do input.define(d.name, d.defaults) end
  check(#input.defs == #saved_defs, "templates: action map restored")
  for k, v in pairs(saved_bits) do
    check(input.bit_of[k] == v, "templates: bit preserved for " .. k)
  end
  input.pad_reset() -- the templates poll pad 1 (A4), which latches the
                    -- live pad domain; later suites expect bare v1
  rm_dir()
end

-- ---- D080 picker list model + navigation math ----

local function t_picker_nav()
  local pick = cm.require("cm.pick")
  local tiles = {
    { name = "Zelda Clone", path = "projects/zc", author = "ana" },
    { name = "asteroids", path = "/games/Asteroids", author = "Bo" },
    { name = "asteroids", path = "/else/asteroids2" },
    { name = "projet π", path = "/ailleurs/projet π original" },
  }

  check(pick.match(tiles[1], nil) and pick.match(tiles[1], ""),
        "pick: an empty query matches every tile")
  check(pick.match(tiles[1], "ZELDA") and pick.match(tiles[1], "zc")
        and pick.match(tiles[2], "ANA") == false and pick.match(tiles[1], "ana"),
        "pick: matching is case-insensitive over name, path, and author")
  check(pick.match(tiles[4], "π") and not pick.match(tiles[4], "omega"),
        "pick: non-ASCII query bytes compare exactly")
  check(not pick.match(tiles[3], "a-s"),
        "pick: queries are plain text, never Lua patterns")

  local all = pick.view(tiles, nil, "recent")
  check(#all == 4 and all[1] == tiles[1] and all[4] == tiles[4],
        "pick: recent mode preserves the incoming order")
  local hit = pick.view(tiles, "asteroids", "recent")
  check(#hit == 2 and hit[1] == tiles[2] and hit[2] == tiles[3],
        "pick: filtering keeps relative order")
  check(#pick.view(tiles, "no such project", "recent") == 0,
        "pick: an unmatched query yields an empty view")
  local named = pick.view(tiles, nil, "name")
  check(named[1] == tiles[3] and named[2] == tiles[2]
        and named[3] == tiles[4] and named[4] == tiles[1]
        and tiles[1].name == "Zelda Clone",
        "pick: name mode sorts case-insensitively with a path tiebreak"
        .. " and never mutates the input")

  -- an 8-cell grid in 3 columns:  1 2 3 / 4 5 6 / 7 8
  check(pick.nav(1, "left", 8, 3) == 1 and pick.nav(8, "right", 8, 3) == 8,
        "pick: the cursor clamps at the row ends without wrapping")
  check(pick.nav(2, "down", 8, 3) == 5 and pick.nav(5, "up", 8, 3) == 2,
        "pick: vertical moves keep the column")
  check(pick.nav(2, "up", 8, 3) == 2 and pick.nav(3, "up", 8, 3) == 3,
        "pick: up from the first row keeps the column in place")
  check(pick.nav(6, "down", 8, 3) == 8 and pick.nav(7, "down", 8, 3) == 7,
        "pick: down off a full bottom row lands on the last cell; the"
        .. " bottom row itself stays put")
  check(pick.nav(5, "home", 8, 3) == 1 and pick.nav(5, "end", 8, 3) == 8,
        "pick: home/end reach the first and last cell")
  check(pick.nav(1, "pgdn", 20, 3, 2) == 7 and pick.nav(7, "pgup", 20, 3, 2) == 1
        and pick.nav(19, "pgdn", 20, 3, 2) == 20,
        "pick: page moves jump page_rows rows and clamp")
  check(pick.nav(5, "down", 0, 0) == 1 and pick.nav(nil, "right", 3, 3) == 2,
        "pick: degenerate grids and a missing cursor stay in range")

  check(pick.clamp(-10, 400, 300) == 0 and pick.clamp(500, 400, 300) == 100
        and pick.clamp(50, 200, 300) == 0,
        "pick: scroll clamps to the scrollable range")
  check(pick.ensure_visible(0, 350, 100, 600, 300) == 150
        and pick.ensure_visible(300, 0, 100, 600, 300) == 0
        and pick.ensure_visible(100, 150, 100, 600, 300) == 100,
        "pick: ensure_visible makes the smallest clamped scroll change")
  check(pick.ensure_visible(0, 0, 500, 400, 300) == 100,
        "pick: a cell taller than the view keeps its bottom edge reachable")
end

-- ---- A2 diagnostics + D065 crash locator envelope ----

local function t_crash()
  check(pal.version.api >= 12 and type(pal.user_path) == "function"
        and type(pal.x_window_icon) == "function",
        "release identity: PAL api12 exposes user path + project window icon")
  local icon_png = pal.png_encode(string.rep("\x43\x65\x87\xff", 32 * 32), 32, 32)
  local icon_ok, icon_err = pal.x_window_icon(icon_png)
  check(icon_ok == true and icon_err == nil,
        "release identity: project PNG icon decodes headlessly")
  icon_ok, icon_err = pal.x_window_icon("not a png")
  check(icon_ok == nil and type(icon_err) == "string"
        and icon_err:find("PNG decode failed", 1, true),
        "release identity: malformed project icon reports a named error")
  local user, uerr = pal.user_path()
  local absolute = type(user) == "string" and
    ((pal.platform == "windows" and user:match("^%a:[/\\]"))
      or (pal.platform ~= "windows" and user:sub(1, 1) == "/"))
  check(absolute and uerr == nil,
        "diagnostics: per-user path is absolute + available")
  check(pal.diagnostics_dir == nil and pal.log_path == nil,
        "diagnostics: capped selftests do not create process logs")

  local crash = cm.require("cm.crash")
  local sample = {
    report_id = "cr1-kat", project_path = "projects/space é",
    project_name = "Display Name",
    history_stream = "hs1-0123456789abcdef0123456789abcdef",
    committed_frame = 123, attempted_frame = 124, code_epoch = 7,
    error_kind = "sim.step", log_path = "/logs/process.log",
    utc = "20260716T120000Z", engine_version = "0.1-alpha",
    platform = "linux", pal_major = 0, pal_api = 11, exe = "cosmic",
    traceback = "boom\nstack", input_record = "\0\1binary",
    evals = { "doc.x = 1", "error('oops')" }, logs = "line one\nline two",
  }
  local blob = crash.encode(sample)
  -- Additive readers ignore future chunks/versions instead of rejecting the
  -- whole report (same compatibility rule as snapshots/traces).
  blob = blob .. "FUTR" .. string.pack("<I4I4", 99, 3) .. "new"
  local got = crash.decode(blob)
  check(got.report_id == sample.report_id
        and got.project_path == sample.project_path
        and got.project_name == sample.project_name
        and got.history_stream == sample.history_stream,
        "crash: project/history identity round-trips")
  check(got.committed_frame == 123 and got.attempted_frame == 124
        and got.code_epoch == 7 and got.error_kind == "sim.step",
        "crash: committed/attempted boundary round-trips")
  check(got.input_record == sample.input_record and #got.evals == 2
        and got.evals[2] == sample.evals[2]
        and got.traceback == sample.traceback and got.logs == sample.logs
        and got.pal_api == 11,
        "crash: attempted work + diagnostics round-trip")

  local dir = tmproot() .. "/cosmic_selftest_diagnostics"
  for _, n in ipairs(pal.list_dir(dir) or {}) do pal.x_remove(dir .. "/" .. n) end
  pal.x_remove(dir)
  local path, err = crash.publish(sample, {
    _dir = dir, _stamp = "20260716T120000Z", _fail = { _fail = "rename" },
  })
  check(path == nil and err:find("rename", 1, true),
        "crash: interrupted publication reports its atomic boundary")
  check(#(pal.list_dir(dir) or {}) == 0,
        "crash: interrupted publication leaves no report/temp")
  path = crash.publish(sample, { _dir = dir, _stamp = "20260716T120000Z" })
  local path2 = crash.publish(sample, {
    _dir = dir, _stamp = "20260716T120000Z",
  })
  local disk = path and crash.read(path)
  check(path and path2 and path ~= path2 and disk
        and disk.history_stream == sample.history_stream
        and disk.committed_frame == 123,
        "crash: atomic reports are unique + independently decodable")
  for _, n in ipairs(pal.list_dir(dir) or {}) do pal.x_remove(dir .. "/" .. n) end
  pal.x_remove(dir)
end

local function t_ring_spill()
  -- R6b (REWIND.md §3/D053): closed segments spill to .ed/history, the
  -- seconds window becomes RAM residency (demotion), the budget evicts
  -- files, and rewind cleans stale files up
  local trace = cm.require("cm.trace")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local root = tmproot() .. "/cosmic_selftest_hist"
  pal.mkdir(root)
  -- a dev-iteration rerun may find a half-tested dir: start clean
  for _, n in ipairs(pal.list_dir(root .. "/.ed/history") or {}) do
    pal.x_remove(root .. "/.ed/history/" .. n)
  end
  trace.ring.kf = 4
  trace.ring.seconds = 8 / 60 -- RAM window = 8 frames = 2 segments
  trace.ring.spill = true
  trace.ring.budget_mb = 64 -- roomy: nothing budget-evicts yet
  local b = pal.buf("st.spill", 8)
  b:i32(0, 0)
  trace.ring_start({ project = root })
  local first_loc = trace.ring_locator()
  check(first_loc and first_loc.project == root and first_loc.frame == f0
        and #first_loc.stream == 36
        and first_loc.stream:match("^hs1%-%x+$"),
        "ring stream: fresh history gets an exact identity")
  local irec = ("\0"):rep(10)
  local snaps = {}
  local function drive(from, to)
    for i = from, to do
      b:i32(0, i * 3)
      sim:i64(0, f0 + i)
      snaps[i] = b:str(0, 8)
      trace.record_frame(irec, nil)
    end
  end
  local sync_atomic, sync_calls = pal.write_file_atomic, 0
  pal.write_file_atomic = function(...)
    sync_calls = sync_calls + 1
    return sync_atomic(...)
  end
  drive(1, 20) -- segs 1..5 closed+spilled, seg 6 open; window demotes 1..3
  pal.write_file_atomic = sync_atomic
  check(sync_calls == 0,
        "ring spill: segment close performs no synchronous file write")
  check(trace.history_drain(),
        "ring spill: background transactions drain successfully")

  local files = pal.list_dir(root .. "/.ed/history")
  check(files and #files >= 4,
        "ring spill: files exist (" .. tostring(files and #files) .. ")")
  -- pal.list_dir PRUNES dot-directories at the source: the .ed undo
  -- journal is thousands of history files, and walking it on every
  -- project-root glob froze the editor on a native FS (the first preset
  -- drop's asset invalidate re-globbed the tree). The subtree stays
  -- reachable when .ed/history is the explicit root (checked above); a
  -- listing of the project root skips it but keeps real files.
  pal.write_file(root .. "/list_probe.txt", "x")
  local rootls = pal.list_dir(root) or {}
  local saw_ed, saw_asset = false, false
  for _, n in ipairs(rootls) do
    if n:find("^%.ed") then saw_ed = true end
    if n == "list_probe.txt" then saw_asset = true end
  end
  check(saw_asset and not saw_ed,
        "list_dir: prunes .ed subtree, keeps real files")
  pal.x_remove(root .. "/list_probe.txt")
  local st = trace.ring_stats()
  check(st.spilled >= 4 and st.disk_bytes > 0, "ring spill: stats see disk")
  local lo, hi = trace.ring_range()
  check(hi == f0 + 20 and lo < f0 + 8,
        "ring spill: span outlives the RAM window")
  check(trace.ring_state_at(f0 + 2).bufs["st.spill"] == snaps[2],
        "ring spill: demoted segment round-trips from disk")
  check(trace.ring_state_at(f0 + 19).bufs["st.spill"] == snaps[19],
        "ring spill: RAM tier intact")

  -- rewind INTO a spilled segment: state restores, stale files go
  trace.rewind(f0 + 6)
  check(b:str(0, 8) == snaps[6], "ring spill: rewind from disk restores")
  local _, hi2 = trace.ring_range()
  check(hi2 == f0 + 6, "ring spill: rewind truncated")
  drive(7, 24) -- resume + close a few more segments

  -- a tiny budget drops the oldest files
  trace.ring.budget_mb = 0.00001
  drive(25, 28) -- one more close triggers evict
  trace.history_drain()
  local lo3 = trace.ring_range()
  check(lo3 > lo, "ring spill: budget evicted the oldest")

  -- ---- R6.5 (D055): the continuous cross-session stream ----
  trace.ring.budget_mb = save_mb -- roomy again
  drive(29, 40) -- fresh spilled history: 29..32, 33..36, 37..40 closed
  trace.history_drain()

  -- "reboot": hist_peek finds the retained tail; ring_start at the same
  -- counter adopts the chain — the stream spans the old session
  check(trace.hist_peek(root) == f0 + 40,
        "ring adopt: hist_peek finds the tail")
  local disk_loc = trace.hist_locator(root)
  check(disk_loc and disk_loc.project == root
        and disk_loc.stream == first_loc.stream
        and disk_loc.frame == f0 + 40,
        "ring stream: durable locator names stream + committed tail")
  trace.ring_start({ project = root })
  check(trace.ring_locator().stream == first_loc.stream,
        "ring stream: normal adoption preserves identity")
  local lo5, hi5 = trace.ring_range()
  check(hi5 == f0 + 40 and lo5 == f0 + 28,
        "ring adopt: the stream spans the old session")
  check(trace.ring_state_at(f0 + 30).bufs["st.spill"] == snaps[30],
        "ring adopt: an adopted frame decodes from disk")

  -- recording continues the same timeline on top of the adopted past
  drive(41, 44)
  local lo6, hi6 = trace.ring_range()
  check(hi6 == f0 + 44 and lo6 == f0 + 28,
        "ring adopt: recording continues the stream")

  -- resume (rewind) INTO the adopted past: state + counter restore
  -- (code stays current — adopted segments carry no bundle)
  trace.rewind(f0 + 30)
  check(b:str(0, 8) == snaps[30],
        "ring adopt: resume into the past session restores")
  check(sim:i64(0) == f0 + 30, "ring adopt: the counter rides the restore")

  -- the quit flush spills the open tail so it joins the stream
  drive(31, 33) -- 31..32 close the truncated segment; 33 sits open
  check(trace.ring_flush() and trace.hist_peek(root) == f0 + 33,
        "ring flush: the open tail joins the stream")

  -- resume onto a FULL segment's last frame: it re-spills — no chain
  -- gap for the next boot (found designing D056's boot-resume)
  trace.rewind(f0 + 32)
  check(trace.hist_peek(root) == f0 + 32,
        "ring rewind: a full segment re-spills (no chain gap)")

  -- a forked timeline can't rejoin: a mismatched counter wipes clean
  sim:i64(0, f0 + 999)
  trace.ring_start({ project = root })
  local left = pal.list_dir(root .. "/.ed/history")
  local fork_loc = trace.ring_locator()
  -- segments and the old stream marker are gone; the content-addressed blob
  -- store (§14, D103) survives as its own gc_blobs-managed subtree.
  local segs_left, has_stream = 0, false
  for _, n in ipairs(left or {}) do
    if n:find("^seg_") then segs_left = segs_left + 1 end
    if n == "stream" then has_stream = true end
  end
  check(left and segs_left == 0 and has_stream
        and fork_loc.stream ~= first_loc.stream,
        "ring adopt: a fork wipes segments and rotates stream identity")

  -- History without a durable generation ID would make crash lookup guess.
  -- Fail closed before any segment can spill.
  trace._write_fail = { stream = { _fail = "rename" } }
  trace.ring.spill = true
  trace.ring_start({ project = root })
  check(trace.ring_locator().stream == "" and not trace.ring.spill
        and not pal.read_file(root .. "/.ed/history/stream"),
        "ring stream: identity publication failure disables spill")

  -- Segment and manifest publication fail closed. A segment never becomes
  -- authoritative before both its container and index entry are durable.
  trace.ring.spill = true
  trace._write_fail = { segment = { _fail = "rename" } }
  for i = 1000, 1007 do -- two ready segments: the failed head cancels its tail
    sim:i64(0, f0 + i)
    trace.record_frame(irec, nil)
  end
  trace.history_drain()
  check(not pal.read_file(root .. "/.ed/history/seg_000001")
        and not pal.read_file(root .. "/.ed/history/seg_000002")
        and trace.ring_stats().pending == 0
        and not trace.ring.spill and not trace.ring_flush(),
        "ring spill: interrupted head publishes no partial/backlogged history")

  for _, n in ipairs(pal.list_dir(root .. "/.ed/history") or {}) do
    pal.x_remove(root .. "/.ed/history/" .. n)
  end
  trace._write_fail = nil
  trace.ring.spill = true
  sim:i64(0, f0 + 1999)
  trace.ring_start({ project = root })
  local index_path = root .. "/.ed/history/index"
  pal.write_file(index_path, "known-good-index\n")
  trace._write_fail = { index = { _fail = "rename" } }
  for i = 2000, 2007 do -- exercise the dependent-manifest backlog too
    sim:i64(0, f0 + i)
    trace.record_frame(irec, nil)
  end
  trace.history_drain()
  check(pal.read_file(index_path) == "known-good-index\n"
        and not pal.read_file(root .. "/.ed/history/seg_000001")
        and not pal.read_file(root .. "/.ed/history/seg_000002")
        and trace.ring_stats().pending == 0
        and not trace.ring.spill,
        "ring spill: index failure preserves manifest and cancels backlog")

  -- A corrupt indexed tail is rejected and removed rather than adopted.
  trace._write_fail = nil
  pal.write_file(index_path, "7 1 4 12\n")
  local corrupt = root .. "/.ed/history/seg_000007"
  pal.write_file(corrupt, "CSEGtruncated")
  check(trace.hist_peek(root) == nil and not pal.read_file(corrupt),
        "ring adopt: corrupt history tail is discarded")

  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill = save_spill
  trace._write_fail = nil
  sim:i64(0, f0)
  pal.buf_free("st.spill")
  trace.ring_start({ project = "selftest" }) -- leave a clean ring behind
end

local function t_ed_cam()
  local cam = cm.require("cm.ed.cam")
  local old_display_scale = cam.display_scale
  cam.set_display_scale(1)
  local c = cam.new()
  c.x, c.y, c.zoom = 13.5, -7.25, 2.5

  -- w2s/s2w round-trip
  local sx, sy = cam.w2s(c, 100.0, -40.0)
  local wx, wy = cam.s2w(c, sx, sy)
  check(math.abs(wx - 100.0) < 1e-9 and math.abs(wy + 40.0) < 1e-9,
        "ed.cam: w2s/s2w round-trip")

  -- zoom-at-cursor keeps the world point under the cursor fixed
  local px, py = 333.0, 121.0
  local bx, by = cam.s2w(c, px, py)
  cam.zoom_at(c, px, py, cam.wheel_factor(3))
  local ax, ay = cam.s2w(c, px, py)
  check(math.abs(ax - bx) < 1e-9 and math.abs(ay - by) < 1e-9,
        "ed.cam: zoom anchors the cursor's world point")
  check(math.abs(c.zoom - 2.5 * 1.16 ^ 3) < 1e-9, "ed.cam: 1.16 per notch")

  -- clamps
  cam.zoom_at(c, 0, 0, 1e9)
  check(c.zoom == cam.ZMAX, "ed.cam: zoom clamps high")
  cam.zoom_at(c, 0, 0, 1e-12)
  check(c.zoom == cam.ZMIN, "ed.cam: zoom clamps low")

  -- fit centers the rect at the fitting zoom
  local f = cam.fit(100, 200, 400, 200, 1280, 800, 40)
  check(math.abs(f.zoom - 3.0) < 1e-9, "ed.cam: fit picks min-axis zoom")
  local cx, cy = cam.s2w(f, 640, 400)
  check(math.abs(cx - 300) < 1e-9 and math.abs(cy - 300) < 1e-9,
        "ed.cam: fit centers the rect")

  -- the adaptive grid keeps the screen pitch in the comfy band
  for _, z in ipairs({ 0.02, 0.11, 0.5, 1.0, 3.7, 24.0, 64.0 }) do
    local step, alpha = cam.grid(z)
    local pitch = step * z
    check(pitch >= cam.GRID_LO * 0.5 and pitch <= cam.GRID_HI,
          "ed.cam: grid pitch sane at zoom " .. z)
    check(alpha >= 0.35 and alpha <= 1.0, "ed.cam: grid alpha in range")
  end

  -- lerp endpoints
  local l0 = cam.lerp({ x = 1, y = 2, zoom = 1 }, { x = 5, y = 6, zoom = 3 }, 0)
  local l1 = cam.lerp({ x = 1, y = 2, zoom = 1 }, { x = 5, y = 6, zoom = 3 }, 1)
  check(l0.x == 1 and l0.zoom == 1 and l1.x == 5 and l1.zoom == 3,
        "ed.cam: lerp endpoints")

  -- contains: the focus-cycle reveal gate (D134) — fully-inside only
  local vc = { x = 100, y = 100, zoom = 2 } -- viewport 100..740 x 100..500
  check(cam.contains(vc, 1280, 800, 200, 200, 100, 100),
        "ed.cam: contains inside")
  check(not cam.contains(vc, 1280, 800, 50, 200, 100, 100),
        "ed.cam: contains rejects left overhang")
  check(not cam.contains(vc, 1280, 800, 700, 200, 100, 100),
        "ed.cam: contains rejects right overhang")
  check(cam.contains(vc, 1280, 800, 100, 100, 640, 400)
        and not cam.contains(vc, 1280, 800, 100, 100, 641, 400),
        "ed.cam: contains is edge-exact")

  -- Machine-local editor scaling composes with captured logical zoom without
  -- entering the camera doc, and all pointer/world math stays invertible.
  cam.set_display_scale(2)
  local ac = { x = 10, y = 20, zoom = 1.5 }
  local asx, asy = cam.w2s(ac, 30, 50)
  local awx, awy = cam.s2w(ac, asx, asy)
  check(asx == 60 and asy == 90 and cam.screen_zoom(ac) == 3,
        "ed.cam: accessibility multiplier scales canvas content")
  check(awx == 30 and awy == 50,
        "ed.cam: scaled pointer/world transform round-trips")
  local af = cam.fit(100, 200, 400, 200, 1280, 800, 40)
  local afx, afy = cam.s2w(af, 640, 400)
  check(math.abs(af.zoom - 1.5) < 1e-9
        and math.abs(afx - 300) < 1e-9 and math.abs(afy - 300) < 1e-9,
        "ed.cam: fit accounts for machine-local content scaling")
  cam.set_display_scale(old_display_scale)

  local chrome = cm.require("cm.ed.chrome")
  local old_chrome = chrome.scale()
  local vig, vin = chrome.frame({ w = 3840, h = 2160, dpi = 2 },
                                  { wx = 600, wy = 300 }, 2)
  check(vig.w == 1920 and vig.h == 1080 and vig.dpi == 2
        and vin.wx == 300 and vin.wy == 150,
        "ed.chrome: fixed UI uses matching virtual draw/input coordinates")
  chrome.set_scale(old_chrome)
end

local function t_ed_wm()
  local wm = cm.require("cm.ed.wm")
  local doc = wm.init({ cam = { x = 0, y = 0, zoom = 1 } })

  -- spawn: ids advance, spawned window is selected + focused + topmost
  local a = wm.spawn(doc, "note", 0, 0, 200, 100)
  local b = wm.spawn(doc, "note", 150, 50, 200, 100)
  check(a.id == 1 and b.id == 2 and doc.next_id == 3, "ed.wm: spawn ids")
  check(doc.sel[1] == b.id and doc.focus == b.id, "ed.wm: spawn selects")
  check(doc.wins[2].id == b.id, "ed.wm: spawn lands on top")

  -- hit: topmost first in the overlap; edge parts around the border
  local id, part = wm.hit(doc, 160, 60, 6)
  check(id == b.id and part == "content", "ed.wm: hit topmost content")
  id, part = wm.hit(doc, 10, 10, 6)
  check(id == a.id and part == "content", "ed.wm: hit the lower window")
  id, part = wm.hit(doc, 150, 60, 6) -- b's west band (y past the n band)
  check(id == b.id and part == "w", "ed.wm: west edge band")
  id, part = wm.hit(doc, 350, 150, 6) -- b's far corner
  check(id == b.id and part == "se", "ed.wm: se corner band")
  id = wm.hit(doc, 1000, 1000, 6)
  check(id == nil, "ed.wm: miss is nil")

  -- the asymmetric outward band (bo=10, bi=4): 8px outside the east
  -- border grabs the edge, 5px inside is already content (b's e border
  -- is at x=350 here)
  id, part = wm.hit(doc, 358, 100, 10, 4)
  check(id == b.id and part == "e", "ed.wm: outward band grabs outside")
  id, part = wm.hit(doc, 345, 100, 10, 4)
  check(id == b.id and part == "content", "ed.wm: 5px inside is content")

  -- explicit z only
  wm.to_front(doc, a.id)
  check(doc.wins[2].id == a.id, "ed.wm: to_front")
  wm.lower(doc, a.id)
  check(doc.wins[1].id == a.id, "ed.wm: lower")
  wm.raise(doc, a.id)
  check(doc.wins[2].id == a.id, "ed.wm: raise")

  -- resize from a gesture-start rect: east grows, west anchors the right
  -- edge, min clamps
  local r0 = { x = b.x, y = b.y, w = b.w, h = b.h }
  wm.resize(doc, b.id, "e", r0, 40, 0)
  check(b.w == 240, "ed.wm: e-resize grows")
  wm.resize(doc, b.id, "w", r0, 60, 0)
  check(b.w == 140 and b.x == 210 and b.x + b.w == 350,
        "ed.wm: w-resize anchors the right edge")
  wm.resize(doc, b.id, "nw", r0, 500, 500)
  check(b.w == wm.MIN_W and b.h == wm.MIN_H, "ed.wm: min size clamps")
  check(b.x + b.w == 350 and b.y + b.h == 150, "ed.wm: clamp keeps anchor")
  wm.resize(doc, b.id, "se", r0, -500, -500)
  check(b.x == 150 and b.y == 50, "ed.wm: se clamp keeps origin")

  -- marquee geometry
  local ids = wm.intersecting(doc, -10, -10, 20, 20)
  check(#ids == 1 and ids[1] == a.id, "ed.wm: intersecting finds a only")
  ids = wm.intersecting(doc, 500, 500, 80, 80) -- reversed corners
  check(#ids == 2, "ed.wm: intersecting normalizes + finds both")

  -- ---- the grammar state machine (synthetic frames) ----
  local function inp(t)
    t.bo = t.bo or 6 -- symmetric band in the grammar KATs
    t.bi = t.bi or 6
    t.alt = t.alt or false
    t.down1 = t.down1 or false
    t.down3 = t.down3 or false
    t.clicked1 = t.clicked1 or false
    t.clicked3 = t.clicked3 or false
    return t
  end

  -- deterministic stage for the grammar: b on top, overlapping a; b's se
  -- quadrant (x > 200) is the only spot where b alone is hit
  wm.to_front(doc, b.id)
  -- A-click on a window = select the topmost hit
  doc.sel, doc.focus = {}, 0
  local g = {}
  local own = wm.update(doc, g, inp({ wx = 160, wy = 60, sx = 160, sy = 60,
                                      alt = true, down1 = true,
                                      clicked1 = true }))
  check(own and g.state == "alt_pend", "ed.wm: A-press arms")
  own = wm.update(doc, g, inp({ wx = 161, wy = 61, sx = 161, sy = 61,
                                alt = true }))
  check(own and g.state == nil, "ed.wm: still-release completes the click")
  check(doc.sel[1] == b.id and doc.focus == b.id, "ed.wm: A-click selects")

  -- A-drag = move, in world units; an unselected target selects on cross
  -- (press at 205,60: past a's right edge, so only b is under the cursor)
  doc.sel = { a.id }
  g = {}
  wm.update(doc, g, inp({ wx = 205, wy = 60, sx = 205, sy = 60,
                          alt = true, down1 = true, clicked1 = true }))
  wm.update(doc, g, inp({ wx = 215, wy = 60, sx = 215, sy = 60,
                          alt = true, down1 = true }))
  check(g.state == "alt_move", "ed.wm: crossing 4px starts the move")
  check(doc.sel[1] == b.id, "ed.wm: dragging an unselected window selects it")
  local bx0 = b.x
  wm.update(doc, g, inp({ wx = 245, wy = 90, sx = 245, sy = 90,
                          alt = true, down1 = true }))
  check(b.x == bx0 + 30, "ed.wm: move follows the world delta")
  wm.update(doc, g, inp({ wx = 245, wy = 90, sx = 245, sy = 90, alt = true }))
  check(g.state == nil, "ed.wm: release ends the move")

  -- selected-first priority when overlapping: select a (the bottom one),
  -- press where both overlap — the drag targets a, not topmost b
  b.x, b.y = 150, 50 -- restore the overlap
  doc.sel = { a.id }
  g = {}
  wm.update(doc, g, inp({ wx = 160, wy = 60, sx = 160, sy = 60,
                          alt = true, down1 = true, clicked1 = true }))
  local ax0 = a.x
  wm.update(doc, g, inp({ wx = 180, wy = 60, sx = 180, sy = 60,
                          alt = true, down1 = true })) -- crossing frame
  wm.update(doc, g, inp({ wx = 200, wy = 60, sx = 200, sy = 60,
                          alt = true, down1 = true })) -- +20 from the cross
  check(g.target == a.id and a.x == ax0 + 20,
        "ed.wm: selected-first move priority")
  wm.update(doc, g, inp({ wx = 200, wy = 60, sx = 200, sy = 60, alt = true }))

  -- A-rightclick normally closes; an external-operation kind may hold the
  -- window until its explicit safe cancel door completes.
  g = {}
  wm.update(doc, g, inp({ wx = 160, wy = 60, sx = 160, sy = 60, alt = true,
                          down3 = true, clicked3 = true,
                          can_close = function() return false end }))
  wm.update(doc, g, inp({ wx = 160, wy = 60, sx = 160, sy = 60, alt = true,
                          can_close = function() return false end }))
  check(wm.get(doc, b.id) ~= nil and g.state == nil,
        "ed.wm: a kind can guard A-rightclick dismissal")

  -- Without a guard, asset state survives the fearless close by design (§6).
  g = {}
  wm.update(doc, g, inp({ wx = 160, wy = 60, sx = 160, sy = 60, alt = true,
                          down3 = true, clicked3 = true }))
  check(g.state == "alt_rpend", "ed.wm: A-rpress arms")
  wm.update(doc, g, inp({ wx = 160, wy = 60, sx = 160, sy = 60, alt = true }))
  check(wm.get(doc, b.id) == nil, "ed.wm: A-rightclick closes")
  check(#doc.wins == 1, "ed.wm: one window left")

  -- marquee: A-drag on empty selects the intersecting set
  g = {}
  wm.update(doc, g, inp({ wx = 500, wy = 500, sx = 500, sy = 500,
                          alt = true, down1 = true, clicked1 = true }))
  check(g.state == "marquee", "ed.wm: A-press on empty starts a marquee")
  wm.update(doc, g, inp({ wx = -20, wy = -20, sx = -20, sy = -20,
                          alt = true, down1 = true }))
  wm.update(doc, g, inp({ wx = -20, wy = -20, sx = -20, sy = -20,
                          alt = true }))
  check(#doc.sel == 1 and doc.sel[1] == a.id, "ed.wm: marquee selects")

  -- edge resize on plain drag (no alt)
  g = {}
  wm.update(doc, g, inp({ wx = a.x + a.w, wy = a.y + 50,
                          sx = a.x + a.w, sy = a.y + 50,
                          down1 = true, clicked1 = true }))
  check(g.state == "resize" and g.part == "e", "ed.wm: edge press resizes")
  wm.update(doc, g, inp({ wx = a.x + a.w + 25, wy = a.y + 50,
                          sx = a.x + a.w + 25, sy = a.y + 50, down1 = true }))
  check(a.w == 225, "ed.wm: resize follows the drag")
  wm.update(doc, g, inp({ wx = 0, wy = 0, sx = 0, sy = 0 }))

  -- the edge wins under ALT too (human feedback, live round 2): an
  -- ALT-press 3px OUTSIDE the border resizes — never a move or marquee
  g = {}
  wm.update(doc, g, inp({ wx = a.x + a.w + 3, wy = a.y + 50,
                          sx = a.x + a.w + 3, sy = a.y + 50, alt = true,
                          down1 = true, clicked1 = true }))
  check(g.state == "resize" and g.part == "e",
        "ed.wm: ALT+edge press resizes, not moves")
  wm.update(doc, g, inp({ wx = 0, wy = 0, sx = 0, sy = 0 }))

  -- content click (no alt): not owned, focuses, never raises
  local c = wm.spawn(doc, "note", 400, 400, 100, 100)
  wm.to_back(doc, c.id)
  doc.focus = 0
  g = {}
  own = wm.update(doc, g, inp({ wx = 450, wy = 450, sx = 450, sy = 450,
                                down1 = true, clicked1 = true }))
  check(own == false and doc.focus == c.id, "ed.wm: content click focuses")
  check(doc.wins[1].id == c.id, "ed.wm: content click never raises")

  -- close cleans selection/focus references
  doc.sel = { c.id }
  doc.focus = c.id
  wm.close(doc, c.id)
  check(#doc.sel == 0 and doc.focus == 0, "ed.wm: close cleans refs")

  -- ---- live round 3 (D054): the no-modifier grammar ----
  -- plain press on EMPTY canvas = marquee: a drag selects, a still-click
  -- clears (panning left the left button — it's the middle one's now)
  doc = wm.init({ cam = { x = 0, y = 0, zoom = 1 } })
  local d = wm.spawn(doc, "note", 0, 0, 100, 100)
  local e = wm.spawn(doc, "note", 300, 0, 100, 100)
  doc.sel, doc.focus = { d.id }, d.id
  g = {}
  own = wm.update(doc, g, inp({ wx = 500, wy = 300, sx = 500, sy = 300,
                                down1 = true, clicked1 = true }))
  check(own and g.state == "marquee",
        "ed.wm: plain press on empty starts a marquee")
  wm.update(doc, g, inp({ wx = 250, wy = -10, sx = 250, sy = -10,
                          down1 = true }))
  wm.update(doc, g, inp({ wx = 250, wy = -10, sx = 250, sy = -10 }))
  check(#doc.sel == 1 and doc.sel[1] == e.id, "ed.wm: plain marquee selects")
  g = {}
  wm.update(doc, g, inp({ wx = 500, wy = 300, sx = 500, sy = 300,
                          down1 = true, clicked1 = true }))
  wm.update(doc, g, inp({ wx = 501, wy = 301, sx = 501, sy = 301 }))
  check(#doc.sel == 0 and doc.focus == 0,
        "ed.wm: still-click on empty clears the selection")

  -- title-bar move (inp.hdrid, no modifier): a drag moves, a still-click
  -- selects — the same pend as the ALT grammar
  g = {}
  wm.update(doc, g, inp({ wx = 20, wy = 10, sx = 20, sy = 10, hdrid = d.id,
                          down1 = true, clicked1 = true }))
  check(g.state == "alt_pend" and g.target == d.id,
        "ed.wm: title press arms the move")
  wm.update(doc, g, inp({ wx = 50, wy = 10, sx = 50, sy = 10,
                          down1 = true }))
  check(g.state == "alt_move" and doc.sel[1] == d.id,
        "ed.wm: title drag moves with no modifier + selects the target")
  wm.update(doc, g, inp({ wx = 60, wy = 30, sx = 60, sy = 30,
                          down1 = true }))
  check(d.x == 10 and d.y == 20, "ed.wm: title move follows the delta")
  wm.update(doc, g, inp({ wx = 60, wy = 30, sx = 60, sy = 30 }))
  doc.sel, doc.focus = {}, 0
  g = {}
  wm.update(doc, g, inp({ wx = 40, wy = 32, sx = 40, sy = 32, hdrid = d.id,
                          down1 = true, clicked1 = true }))
  wm.update(doc, g, inp({ wx = 40, wy = 32, sx = 40, sy = 32 }))
  check(doc.sel[1] == d.id and doc.focus == d.id,
        "ed.wm: title still-click selects")

  -- selection mode (alt+V, g.selmode): the press can only select — it
  -- marquees even over a window and outranks the edge band; it disarms
  -- itself when a select lands, stays armed when one doesn't
  doc.sel, doc.focus = {}, 0
  g = { selmode = true }
  own = wm.update(doc, g, inp({ wx = 350, wy = 50, sx = 350, sy = 50,
                                down1 = true, clicked1 = true }))
  check(own and g.state == "marquee" and g.sel_click == true,
        "ed.wm: selection mode marquees even over a window")
  wm.update(doc, g, inp({ wx = 351, wy = 51, sx = 351, sy = 51 }))
  check(doc.sel[1] == e.id, "ed.wm: selection-mode click selects the window")
  check(g.selmode == nil, "ed.wm: a landed select disarms the mode")
  g = { selmode = true }
  wm.update(doc, g, inp({ wx = 400, wy = 50, sx = 400, sy = 50,
                          down1 = true, clicked1 = true }))
  check(g.state == "marquee", "ed.wm: selection mode outranks the edge band")
  wm.update(doc, g, inp({ wx = 800, wy = 800, sx = 800, sy = 800,
                          down1 = true }))
  wm.update(doc, g, inp({ wx = 800, wy = 800, sx = 800, sy = 800 }))
  check(#doc.sel == 0 and g.selmode == true,
        "ed.wm: an empty select keeps the mode armed")

  -- resize threads a kind constraint (opt.constrain) + re-anchors w/n
  local r02 = { x = e.x, y = e.y, w = e.w, h = e.h }
  wm.resize(doc, e.id, "w", r02, -40, 0, {
    constrain = function(_, _, _, ww2) return ww2, ww2 * 0.5 end,
  })
  check(e.w == 140 and e.h == 70 and e.x + e.w == 400,
        "ed.wm: constrain replaces the size and keeps the w anchor")

  -- ---- keyboard focus-cycle order (D134): reading order, wraps, seeds ----
  doc = wm.init({ cam = { x = 0, y = 0, zoom = 1 } })
  check(wm.cycle(doc, 0, 1) == nil, "ed.wm: cycle on empty is nil")
  local ca = wm.spawn(doc, "note", 0, 0, 100, 80)     -- row 0, first
  check(wm.cycle(doc, ca.id, 1) == ca.id and wm.cycle(doc, ca.id, -1) == ca.id,
        "ed.wm: a single window cycles to itself")
  local cb = wm.spawn(doc, "note", 200, 0, 100, 80)   -- row 0, second (x)
  local cc = wm.spawn(doc, "note", 0, 150, 100, 80)   -- row 1
  wm.to_front(doc, ca.id) -- z is scrambled; reading order must not care
  check(wm.cycle(doc, 0, 1) == ca.id, "ed.wm: cycle seeds at the first")
  check(wm.cycle(doc, 0, -1) == cc.id, "ed.wm: cycle -1 seeds at the last")
  check(wm.cycle(doc, ca.id, 1) == cb.id
        and wm.cycle(doc, cb.id, 1) == cc.id,
        "ed.wm: reading order walks rows then columns")
  check(wm.cycle(doc, cc.id, 1) == ca.id, "ed.wm: cycle wraps forward")
  check(wm.cycle(doc, ca.id, -1) == cc.id
        and wm.cycle(doc, cc.id, -1) == cb.id,
        "ed.wm: cycle walks and wraps backward")
  check(wm.cycle(doc, 999, 1) == ca.id,
        "ed.wm: a stale from-id reseeds at the first")
  local cd = wm.spawn(doc, "note", 200, 0, 100, 80) -- exact tie with cb
  check(wm.cycle(doc, cb.id, 1) == cd.id and wm.cycle(doc, cd.id, 1) == cc.id,
        "ed.wm: an exact-position tie breaks by id")

  -- ---- keyboard resize (D134): se-anchored, min clamp, constraint ----
  wm.close(doc, cd.id)
  doc.sel = { ca.id, cb.id }
  wm.resize_sel(doc, doc.sel, 10, 5)
  check(ca.w == 110 and ca.h == 85 and cb.w == 110 and cb.h == 85
        and ca.x == 0 and ca.y == 0 and cb.x == 200 and cb.y == 0,
        "ed.wm: resize_sel grows every selected window, origin held")
  wm.resize_sel(doc, { ca.id }, -1000, -1000)
  check(ca.w == wm.MIN_W and ca.h == wm.MIN_H and ca.x == 0 and ca.y == 0,
        "ed.wm: resize_sel clamps at min from the origin")
  wm.resize_sel(doc, { cb.id }, 10, 0, {
    constrain = function(_, part) if part == "se" then return 300, 150 end end,
  })
  check(cb.w == 300 and cb.h == 150,
        "ed.wm: resize_sel threads the kind constraint")
end

local function t_ed_game()
  local game = cm.require("cm.ed.win.game")
  local view = cm.require("cm.view")
  -- selftest's design res is 64x64 (1:1): the supported FOV range widens
  -- to include it — lo = 64 (own width), hi = floor(64*16/9) = 113
  local PW, PH = game.PAD_W, game.PAD_H
  check(PW == 14 and PH == 34, "ed.game: chrome pads")

  -- vertical drag = pure scale at the current width (aspect locked)
  local win = { kind = "game" }
  local r0 = { x = 0, y = 0, w = 64 + PW, h = 64 + PH } -- image 1:1
  local w, h = game.constrain(win, "s", r0, 64 + PW, 128 + PH, false)
  check(w == 64 * 2 + PW and h == 64 * 2 + PH,
        "ed.game: vertical resize scales aspect-locked")
  check(win.fw == 64, "ed.game: width pins to the design res")
  check(view.canvas_fov and view.canvas_fov.w == 64 and
        view.canvas_fov.h == 64, "ed.game: fov request follows")

  -- horizontal drag walks the width through the range at constant scale
  w, h = game.constrain(win, "e", r0, 94 + PW, 64 + PH, false)
  check(w == 94 + PW and h == 64 + PH and win.fw == 94,
        "ed.game: horizontal resize widens the fov, same scale")
  check(view.canvas_fov.w == 94, "ed.game: fov request tracks the width")

  -- past 16:9 the width caps and the drag becomes a scale
  win.fw = 64
  w, h = game.constrain(win, "e", r0, 150 + PW, 64 + PH, false)
  local s = 150 / 113
  check(win.fw == 113, "ed.game: width caps at 16:9")
  check(math.abs(w - (113 * s + PW)) < 1e-9 and
        math.abs(h - (64 * s + PH)) < 1e-9,
        "ed.game: past 16:9 the drag scales")

  -- under the low end the width floors and the drag becomes a scale
  win.fw = 64
  w, h = game.constrain(win, "e", r0, 32 + PW, 64 + PH, false)
  check(win.fw == 64 and math.abs(w - (32 + PW)) < 1e-9 and
        math.abs(h - (32 + PH)) < 1e-9,
        "ed.game: under the low end the drag scales down")

  -- CTRL snaps the scale to integers (multiples of the res)
  win.fw = 64
  w, h = game.constrain(win, "s", r0, 64 + PW, 100 + PH, true) -- s 1.56 -> 2
  check(w == 64 * 2 + PW and h == 64 * 2 + PH,
        "ed.game: ctrl snaps to a res multiple")
  w, h = game.constrain(win, "s", r0, 64 + PW, 70 + PH, true) -- s 1.09 -> 1
  check(w == 64 + PW and h == 64 + PH, "ed.game: ctrl snap floors at 1x")

  -- corner drag follows the axis that moved more, at the current width
  win.fw = 64
  w, h = game.constrain(win, "se", r0, 70 + PW, 192 + PH, false)
  check(w == 64 * 3 + PW and h == 64 * 3 + PH,
        "ed.game: corner scales on the dominant axis")

  view.canvas_fov = nil -- selftest hygiene: never applied (view disabled)

  -- ctrl+wheel size dials (UX round 4b): per-window captured overrides,
  -- clamped to each kind's range
  local text = cm.require("cm.ed.win.text")
  local assets = cm.require("cm.ed.win.assets")
  local ed_stub = { touch = function() end }
  local twin = {}
  text.ctrl_wheel(twin, ed_stub, 1)
  check(twin.px == text.PX + 2, "ed.text: ctrl+wheel steps the font")
  text.ctrl_wheel(twin, ed_stub, -40)
  check(twin.px == 8, "ed.text: font clamps low")
  local awin = {}
  assets.ctrl_wheel(awin, ed_stub, 2)
  check(awin.tile == 100, "ed.assets: ctrl+wheel steps the preview size")
  assets.ctrl_wheel(awin, ed_stub, 40)
  check(awin.tile == 160, "ed.assets: preview size clamps high")

  -- find/replace core (UX round 5): plain literal, per line
  local fr = { q = "na", r = "" }
  local lines2 = { "banana", "cab", "nano" }
  local mm = text.fr_matches(fr, lines2, "banana\ncab\nnano")
  check(#mm == 3 and mm[1][1] == 1 and mm[1][2] == 3 and mm[2][2] == 5
        and mm[3][1] == 3 and mm[3][2] == 1,
        "ed.text: find matches lines/cols")
  check(fr.at == 1, "ed.text: the first match is current")
  local fed = { g = {}, touch = function() end, doc = { assets = {} } }
  local a2, p2 = { text = "banana\ncab\nnano" }, {}
  fr.r = "XY"
  text.fr_apply({ id = 1, path = "t.txt" }, fed, a2, p2, fr, lines2, false)
  check(a2.text == "baXYna\ncab\nnano", "ed.text: replace current")
  check(p2.force_set == true, "ed.text: replace forces the widget set")
  local fr2 = { q = "na", r = "_" }
  local a3 = { text = "banana\ncab\nnano" }
  text.fr_matches(fr2, lines2, a3.text)
  text.fr_apply({ id = 1, path = "t.txt" }, fed, a3, {}, fr2, lines2, true)
  check(a3.text == "ba__\ncab\n_no", "ed.text: replace all")

  -- new code windows inherit the current one's size (UX round 6)
  local ed = cm.require("cm.ed")
  local wm2 = cm.require("cm.ed.wm")
  local keep_doc = ed.doc
  ed.doc = wm2.init({ cam = { x = 0, y = 0, zoom = 1 } })
  local t1 = wm2.spawn(ed.doc, "text", 0, 0, 555, 444)
  ed.doc.focus = t1.id
  local w2, h2 = ed.text_spawn_size()
  check(w2 == 555 and h2 == 444, "ed: text spawn inherits the focused size")
  ed.doc.focus = 0
  check(ed.text_spawn_size() == 555,
        "ed: text spawn falls back to the topmost text window")
  wm2.close(ed.doc, t1.id)
  check(ed.text_spawn_size() == text.DEF_W,
        "ed: text spawn uses the default when none exist")
  ed.doc = keep_doc
end

local function t_ed_text_save()
  local W = cm.require("cm.ed.win.text")
  local root = tmproot() .. "/cosmic_selftest_ed_text_save"
  pal.mkdir(root)

  -- Every format routed to the code/text window shares this source-save
  -- contract. Pin each extension so prose, data, and shaders cannot drift
  -- back to the old truncating path independently.
  for _, ext in ipairs({ "lua", "md", "txt", "json", "glsl" }) do
    local path = "atomic." .. ext
    local diskbytes = "known-good " .. ext .. "\n"
    local workingbytes = "unsaved replacement " .. ext .. "\n"
    pal.write_file(root .. "/" .. path, diskbytes)
    local summoned = false
    local ed = { root = root, g = {}, doc = { assets = {} }, parked = false,
                 touch = function() end,
                 summon_console = function() summoned = true end }
    local win = { path = path }
    local a, p = W.open_win(win, ed)
    a.text = workingbytes
    p._save_fail = { _fail = "rename" }
    W.save(win, ed)
    check(pal.read_file(root .. "/" .. path) == diskbytes,
          "ed.text save: ." .. ext .. " failure preserves previous source")
    check(W.dirty(win, ed) and a.text == workingbytes,
          "ed.text save: ." .. ext .. " failure retains dirty working bytes")
    check(summoned,
          "ed.text save: ." .. ext .. " failure summons the console")
    p._save_fail = nil
    W.save(win, ed)
    check(not W.dirty(win, ed)
          and pal.read_file(root .. "/" .. path) == workingbytes,
          "ed.text save: ." .. ext .. " retry publishes complete source")
  end
end

local function t_ed_session()
  local session = cm.require("cm.ed.session")
  local wm = cm.require("cm.ed.wm")
  local state = cm.require("cm.state")

  -- the editor doc is canon-clean and survives encode/decode byte-exactly
  local doc = wm.init({ v = 1, cam = { x = -80.5, y = 12.25, zoom = 1.16 } })
  wm.spawn(doc, "note", 10, 20, 260, 180).text = "unsaved text\nsurvives"
  wm.spawn(doc, "game", 300, 20, 480, 294)
  doc.assets = { ["main.lua"] = { text = "-- working copy", jpos = 3 } }
  local blob = session.encode(doc)
  local back = session.decode(blob)
  check(state.canon(back) == state.canon(doc),
        "ed.session: encode/decode round-trips canon bytes")
  check(back.wins[1].text == "unsaved text\nsurvives",
        "ed.session: window fields survive")
  check(back.assets["main.lua"].jpos == 3, "ed.session: asset state survives")

  -- save/load through the real file path shape
  local root = tmproot() .. "/cosmic_selftest_ed"
  check(session.save(root, doc) == true, "ed.session: save writes")
  check(pal.read_file(session.good_path(root)) == blob,
        "ed.session: save maintains last-known-good copy")
  local loaded = session.load(root)
  check(loaded and state.canon(loaded) == state.canon(doc),
        "ed.session: load round-trips")
  check(session.load(root .. "_nope") == nil, "ed.session: missing = nil")

  -- A corrupt live file recovers the independently valid copy and reports it.
  pal.write_file(session.path(root), "CEDSgarbage")
  local recovered, notice = session.load(root)
  check(recovered and state.canon(recovered) == state.canon(doc),
        "ed.session: corrupt live recovers last-known-good")
  check(notice and notice:find("restored", 1, true),
        "ed.session: recovery is surfaced")

  -- Failures at either atomic replacement keep the prior valid pair intact.
  check(session.save(root, doc) == true,
        "ed.session: restore valid pair before failure injection")
  local newer = wm.init({ v = 1, cam = { x = 999, y = 0, zoom = 1 } })
  local before_live = pal.read_file(session.path(root))
  local before_good = pal.read_file(session.good_path(root))
  local ok, err = session.save(root, newer, { good = { _fail = "rename" } })
  check(not ok and err:find("last%-known%-good"),
        "ed.session: backup write failure is reported")
  check(pal.read_file(session.path(root)) == before_live and
        pal.read_file(session.good_path(root)) == before_good,
        "ed.session: backup failure preserves valid pair")
  ok, err = session.save(root, newer, { live = { _fail = "rename" } })
  check(not ok and err:find("live session", 1, true),
        "ed.session: live write failure is reported")
  check(pal.read_file(session.path(root)) == before_live and
        session.decode(pal.read_file(session.good_path(root))).cam.x == 999,
        "ed.session: live failure preserves old live and new recovery copy")

  -- With both copies damaged, boot fresh but return an actionable notice.
  pal.write_file(session.path(root), "bad live")
  pal.write_file(session.good_path(root), "bad good")
  local fresh, damaged = session.load(root)
  check(fresh == nil and damaged and damaged:find("starting fresh", 1, true),
        "ed.session: double corruption is surfaced")

  -- Recents use the same atomic seam: a failed update cannot truncate them.
  local recent = cm.require("cm.recent")
  local old_path = recent.path
  recent.path = tmproot() .. "/cosmic_selftest_recent.dat"
  pal.write_file(recent.path, "old/project")
  ok, err = recent.note("new/project", { _fail = "write" })
  check(not ok and err and pal.read_file(recent.path) == "old/project",
        "recent: injected failure preserves prior list")
  check(recent.note("new/project") == true and
        pal.read_file(recent.path) == "new/project\nold/project",
        "recent: atomic update orders and preserves entries")
  recent.path = old_path
end

local function t_ed_cache()
  local cache = cm.require("cm.ed.cache")
  local root = tmproot() .. "/cosmic_selftest_cache"
  local dir = root .. "/.ed"
  pal.mkdir(root)
  pal.mkdir(dir)
  pal.mkdir(dir .. "/journal")
  pal.mkdir(dir .. "/history")
  for _, n in ipairs(pal.list_dir(dir .. "/history") or {}) do
    pal.x_remove(dir .. "/history/" .. n)
  end
  pal.x_remove(cache.path(root))

  -- A pre-marker directory is schema 1: adopt it without discarding either
  -- working recovery or valid derived history.
  pal.write_file(dir .. "/session.dat", "working")
  pal.write_file(dir .. "/journal/a.jrn", "undo")
  pal.write_file(dir .. "/history/seg_000001", "legacy history")
  local ok, notice = cache.prepare(root)
  check(ok and notice == nil and cache.decode(pal.read_file(cache.path(root))) == 1,
        "ed.cache: missing marker adopts legacy schema")
  check(pal.read_file(dir .. "/session.dat") == "working" and
        pal.read_file(dir .. "/journal/a.jrn") == "undo" and
        pal.read_file(dir .. "/history/seg_000001") == "legacy history",
        "ed.cache: legacy adoption preserves every data class")

  -- Unknown newer metadata is refused without touching anything: an older
  -- editor cannot infer which parts a future schema made disposable.
  pal.write_file_atomic(cache.path(root), cache.encode(cache.SCHEMA + 1))
  ok, notice = cache.prepare(root)
  check(not ok and notice and notice:find("IS NEWER", 1, true),
        "ed.cache: newer schema is visibly refused")
  check(pal.read_file(dir .. "/history/seg_000001") == "legacy history" and
        pal.read_file(dir .. "/session.dat") == "working" and
        pal.read_file(dir .. "/journal/a.jrn") == "undo",
        "ed.cache: newer schema preserves the whole directory")
  ok, notice = cache.clear(root)
  check(ok and notice == 1 and
        pal.read_file(dir .. "/history/seg_000001") == nil,
        "ed.cache: explicit rebuild opts into current schema")

  -- Corrupt ownership takes the same safe path and an explicit clear is
  -- idempotent. Marker publication failure is actionable.
  pal.write_file(dir .. "/history/seg_000002", "cache")
  pal.write_file(cache.path(root), "not a CEDO")
  ok, notice = cache.prepare(root)
  check(ok and notice and notice:find("unreadable", 1, true) and
        pal.read_file(dir .. "/history/seg_000002") == nil,
        "ed.cache: corrupt marker safely rebuilds and reports")
  ok, notice = cache.clear(root)
  check(ok and notice == 0, "ed.cache: explicit rebuild is idempotent")
  ok, notice = cache.clear(root, { _fail = "rename" })
  check(not ok and notice:find("owner marker", 1, true),
        "ed.cache: marker publication failure is actionable")
  check(pal.read_file(dir .. "/session.dat") == "working" and
        pal.read_file(dir .. "/journal/a.jrn") == "undo",
        "ed.cache: failed rebuild never touches working recovery")
end

local function t_ed_journal()
  local journal = cm.require("cm.ed.journal")
  local root = tmproot() .. "/cosmic_selftest_ed"
  local jf = journal.file(root, "sub/dir/file.lua")
  check(jf == root .. "/.ed/journal/sub__dir__file.lua.jrn",
        "ed.journal: path -> key mapping")

  -- pal.x_file_append: creates, then appends
  local ap = root .. "/append.bin"
  pal.write_file(ap, "") -- reset across runs
  check(pal.x_file_append(ap, "abc") == true, "x_file_append creates/writes")
  check(pal.x_file_append(ap, "def") == true, "x_file_append appends")
  check(pal.read_file(ap) == "abcdef", "x_file_append bytes land in order")

  -- fresh journal: baseline + pushes + dedupe (reset any prior run's file)
  pal.x_remove(journal.file(root, "a.txt"))
  pal.x_remove(journal.good_file(root, "a.txt"))
  local j = journal.open(root, "a.txt")
  check(#j.entries == 0 and j.pos == 0, "ed.journal: fresh is empty")
  check(journal.push(j, "one", journal.SAVED, 1) == true, "ed.journal: push 1")
  check(journal.push(j, "two", 0, 2) == true, "ed.journal: push 2")
  check(journal.push(j, "two", 0, 3) == false, "ed.journal: dedupe vs tip")
  check(#j.entries == 2 and j.pos == 2, "ed.journal: two entries")

  -- a save re-flags the identical tip (no new entry)
  check(journal.push(j, "two", journal.SAVED, 4) == false,
        "ed.journal: same-bytes save adds no entry")
  check(j.entries[2].flags == journal.SAVED, "ed.journal: save re-flags tip")

  -- undo/redo move the cursor over full snapshots
  check(journal.undo(j).bytes == "one", "ed.journal: undo")
  check(journal.undo(j) == nil, "ed.journal: undo stops at the baseline")
  check(journal.redo(j).bytes == "two", "ed.journal: redo")
  check(journal.redo(j) == nil, "ed.journal: redo stops at the tip")

  -- persistence: the appended stream re-opens identically
  local j2 = journal.open(root, "a.txt")
  check(#j2.entries == 2 and j2.pos == 2 and j2.entries[1].bytes == "one"
        and j2.entries[2].flags == journal.SAVED,
        "ed.journal: reopen round-trips the appended stream")
  local j3 = journal.open(root, "a.txt", 1) -- session-restored cursor
  check(j3.pos == 1, "ed.journal: reopen re-parks a saved cursor")

  -- branch: edit while rewound truncates the tail (and rewrites the file)
  journal.undo(j2)
  check(journal.push(j2, "fork", 0, 5) == true, "ed.journal: branch push")
  check(#j2.entries == 2 and j2.entries[2].bytes == "fork",
        "ed.journal: branch truncated the tail")
  local j4 = journal.open(root, "a.txt")
  check(#j4.entries == 2 and j4.entries[2].bytes == "fork",
        "ed.journal: branch rewrite persisted")
  check(pal.read_file(journal.good_file(root, "a.txt")) ==
        pal.read_file(journal.file(root, "a.txt")),
        "ed.journal: rewrite atomically maintains checkpoint")

  -- A damaged live append stream restores the last full rewrite checkpoint.
  pal.write_file(journal.file(root, "a.txt"), "CJRNtruncated")
  local jr = journal.open(root, "a.txt")
  check(#jr.entries == 2 and jr.entries[2].bytes == "fork",
        "ed.journal: corrupt live restores checkpoint")
  check(pal.read_file(journal.file(root, "a.txt")) ==
        pal.read_file(journal.good_file(root, "a.txt")),
        "ed.journal: recovery repairs the live file")

  -- Injected checkpoint/live/restore failures preserve authoritative files.
  local failpath = "fail.txt"
  pal.x_remove(journal.file(root, failpath))
  pal.x_remove(journal.good_file(root, failpath))
  local jfg = journal.open(root, failpath, nil, nil,
                           { good = { _fail = "rename" } })
  journal.push(jfg, "one", 0, 1)
  check(pal.read_file(jfg.path) ~= nil and pal.read_file(jfg.good_path) == nil,
        "ed.journal: checkpoint failure leaves complete live authoritative")
  pal.x_remove(jfg.path)
  local jfl = journal.open(root, failpath, nil, nil,
                           { live = { _fail = "rename" } })
  journal.push(jfl, "two", 0, 2)
  check(pal.read_file(jfl.path) == nil and pal.read_file(jfl.good_path) == nil,
        "ed.journal: live failure publishes neither file")
  local seed = journal.open(root, failpath)
  journal.push(seed, "recoverable", 0, 3)
  pal.write_file(jfl.path, "bad live")
  local jfr = journal.open(root, failpath, nil, nil,
                           { restore = { _fail = "rename" } })
  check(#jfr.entries == 1 and jfr.entries[1].bytes == "recoverable" and
        pal.read_file(jfl.path) == "bad live",
        "ed.journal: failed repair still adopts valid checkpoint")

  -- the cap drops the oldest (per-open cap — R4d/§12.6 sprite journals)
  local j4c = journal.open(root, "a.txt", nil, 3)
  journal.push(j4c, "x1", 0, 6)
  journal.push(j4c, "x2", 0, 7) -- 4th entry against cap 3
  check(#j4c.entries == 3 and j4c.entries[1].bytes == "fork",
        "ed.journal: cap drops the oldest")
  check(j4c.pos == 3 and journal.at(j4c).bytes == "x2",
        "ed.journal: cap keeps the tip current")
  local j5 = journal.open(root, "a.txt", nil, 3)
  check(#j5.entries == 3, "ed.journal: capped file persisted")
  local j5b = journal.open(root, "a.txt", nil, 2) -- tighter cap on reopen
  check(#j5b.entries == 2 and j5b.entries[2].bytes == "x2",
        "ed.journal: reopen trims to a smaller cap")

  -- With no valid checkpoint, corruption degrades to fresh with an alert.
  pal.write_file(journal.file(root, "bad.txt"), "CJRNnotachunk")
  pal.write_file(journal.good_file(root, "bad.txt"), "bad checkpoint")
  local jb = journal.open(root, "bad.txt")
  check(#jb.entries == 0, "ed.journal: double corrupt = fresh")
end

local function t_snd()
  -- R9b (AUDIO.md §2/§5): the audio core — the pure packer, the kernel's
  -- determinism contract (PCM = fn(bank bytes)), deterministic stealing,
  -- the sampler voice, and the committed PCM golden hash.
  local snd = cm.require("cm.snd")

  -- pack/unpack round-trip (pure)
  local t = { type = "fm", alg = 4, fb = 3, pan = -20, gain = 200,
              ops = { { wave = "square", coarse = 2, fine = -10,
                        level = 180, a = 12, d = 340, r = 90, s = 100,
                        detune = 5 },
                      { wave = "noise2", coarse = 0, level = 90,
                        fixed = 440 } } }
  local bytes = snd.pack(t)
  check(#bytes == 80, "snd: packed patch is 80 bytes")
  local u = snd.unpack(bytes)
  check(u.alg == 4 and u.fb == 3 and u.pan == -20 and u.gain == 200,
        "snd: header round-trips")
  check(u.ops[1].wave == "square" and u.ops[1].fine == -10
        and u.ops[1].d == 340 and u.ops[1].detune == 5,
        "snd: op fields round-trip")
  check(u.ops[2].wave == "noise2" and u.ops[2].fixed == 440
        and u.ops[4].level == 0, "snd: fixed flag + defaults round-trip")
  -- R9f: the voice-wide fx trailer (filter + pitch sweep)
  check(u.filter == "off" and u.cutoff == 0 and u.sweep == 0
        and u.sweep_ms == 0, "snd: fx default to bypass (all-zero tail)")
  local fx = snd.unpack(snd.pack({ type = "fm", filter = "hp", cutoff = 200,
    sweep = -12, sweep_ms = 250, ops = { { wave = "noise", level = 100 } } }))
  check(fx.filter == "hp" and fx.cutoff == 200 and fx.sweep == -12
        and fx.sweep_ms == 250, "snd: fx fields round-trip")
  local st = { type = "sample", pcm = "snd.pcm/kat", root = 62,
               loop = true, loop0 = 100, loop1 = 400, a = 1, r = 20 }
  local su = snd.unpack(snd.pack(st))
  check(su.type == "sample" and su.pcm == "snd.pcm/kat" and su.root == 62
        and su.loop and su.loop0 == 100 and su.loop1 == 400,
        "snd: sample patch round-trips")

  -- the kernel: PCM is a pure function of the bank bytes (the rewind
  -- contract) — snapshot the bank mid-note, render on, restore, render
  -- again: byte-identical PCM
  snd.patch(0, { type = "fm", alg = 7, fb = 2,
                 ops = { { wave = "sine", level = 255, a = 4, d = 200,
                           s = 180, r = 60 } } })
  local v = snd.on(0, 69, 110)
  check(v >= 0 and v < 32, "snd: note-on returns a voice id")
  for _ = 1, 5 do pal.snd_render() end
  local bank = pal.buf("snd.bank", 8208)
  local saved = bank:str(0, 8208)
  pal.snd_render()
  local tap_a = pal.x_snd_tap()
  bank:setstr(0, saved)
  pal.snd_render()
  check(pal.x_snd_tap() == tap_a,
        "snd: restore + render = byte-identical PCM (pure kernel)")
  check(tap_a:find("[^%z]") ~= nil, "snd: the note is audible in the tap")

  -- deterministic stealing: fill the bank, the 33rd on steals the
  -- oldest held voice (index 0 — all equal ages tie to lowest index)
  for i = 1, 32 - 1 do snd.on(0, 40 + i, 80) end -- v already holds one
  local steal = snd.on(0, 100, 80)
  check(steal == 0, "snd: full bank steals deterministically (oldest)")
  for i = 0, 31 do snd.off(i) end
  for _ = 1, 20 do pal.snd_render() end -- release tails out

  -- the sampler voice: a ramp PCM buffer, root-note playback
  local pcm = pal.buf("snd.pcm/kat", 2048 * 2)
  for i = 0, 2047 do pcm:i16(i * 2, (i * 13) % 8000) end
  snd.patch(1, st)
  local sv = snd.on(1, 62, 127) -- at root: 1:1 stepping
  pal.snd_render()
  check(pal.x_snd_tap():find("[^%z]") ~= nil, "snd: sampler is audible")
  snd.off(sv)
  for _ = 1, 10 do pal.snd_render() end

  -- the PCM golden: a fixed command ladder must hash to the committed
  -- value on EVERY platform (the §5 audio golden; kernel or table
  -- changes re-cut it deliberately, like pixel goldens)
  local h0, n0 = pal.snd_hash()
  snd.patch(2, { type = "fm", alg = 0, fb = 4,
                 ops = { { wave = "sine", coarse = 2, level = 140,
                           a = 2, d = 80, s = 120, r = 40 },
                         { wave = "sine", coarse = 1, level = 255,
                           a = 6, d = 300, s = 160, r = 120 } } })
  snd.patch(3, { type = "fm", alg = 7,
                 ops = { { wave = "noise", level = 200, a = 1, d = 60,
                           s = 0, r = 30 } } })
  local va = snd.on(2, 57, 120)
  pal.snd_render()
  local vb = snd.on(3, 60, 90)
  for _ = 1, 8 do pal.snd_render() end
  snd.off(va)
  local vc = snd.on(2, 64, 70)
  for _ = 1, 8 do pal.snd_render() end
  snd.off(vb)
  snd.off(vc)
  for _ = 1, 13 do pal.snd_render() end
  local h1, n1 = pal.snd_hash()
  check(n1 - n0 == 30 and n1 == 68, "snd golden: 68 frames accumulated")
  -- every render in this test is deterministic and t_snd is the only
  -- renderer before this line, so the accumulator itself is the golden
  pal.log(("snd golden: %016x"):format(h1))
  check(h1 == 0x9df7dc572822ef01, -- re-cut 2026-07-15: the LFSR-noise
        -- freq-clock fix (snd.c) — the ladder renders a noise op (slot 3),
        -- which was frozen (DC) before and is broadband now. Deliberate
        -- re-cut, not an unexpected break (was 0xc8826fe3771e33d9, R9b).
        "snd golden: the committed PCM hash")

  -- R9f: the filter + sweep must CHANGE the PCM (the golden above proves
  -- bypass is byte-identical; these prove the new paths actually work).
  -- Same slot/note/seed → the pre-fx noise stream is identical, so any
  -- difference is the effect itself. Rendered AFTER the golden capture.
  local function render_note(patch, note, frames)
    snd.patch(10, patch)
    local vv = snd.on(10, note, 120)
    local acc = {}
    for f = 1, frames do pal.snd_render(); acc[f] = pal.x_snd_tap() end
    snd.off(vv)
    for _ = 1, 6 do pal.snd_render() end
    return table.concat(acc)
  end
  local nz = { type = "fm", alg = 7, ops = { { wave = "noise", level = 220,
              a = 1, d = 400, s = 200, r = 40, fixed = 3000 } } }
  local plain = render_note(nz, 60, 3)
  nz.filter, nz.cutoff = "hp", 210
  local hip = render_note(nz, 60, 3)
  check(plain ~= hip, "snd filter: a highpass alters the PCM")
  check(hip:find("[^%z]") ~= nil, "snd filter: the highpass output is audible")
  local sg = { type = "fm", alg = 7, ops = { { wave = "sine", level = 220,
              a = 1, d = 400, s = 200, r = 40 } } }
  local flat = render_note(sg, 69, 6)
  sg.sweep, sg.sweep_ms = -24, 80 -- drop two octaves over 80 ms
  local dropd = render_note(sg, 69, 6)
  check(flat ~= dropd, "snd sweep: a pitch sweep alters the PCM")

  -- A4/D085: device-output gains are pure output policy — the hashed mix
  -- (and with it every audio golden and trace) never hears them; only the
  -- device copy does, in exact integer math. x_snd_dev_tap is the seam.
  for _ = 1, 40 do pal.snd_render() end -- every earlier release tails out
  check(pal.x_snd_tap():find("[^%z]") == nil, "snd gain: bank starts silent")
  local gp = { type = "fm", alg = 7, ops = { { wave = "sine", level = 90,
              a = 1, d = 400, s = 220, r = 20 } } }
  snd.patch(5, gp)  -- sfx category (slots 0..31)
  snd.patch(40, gp) -- music category (slots 32..47)
  snd.patch(60, gp) -- uncategorized (48..63): rides master only

  -- neutral policy: the device copy IS the mix
  local gv = snd.on(5, 60, 100)
  pal.snd_render()
  check(pal.x_snd_dev_tap() == pal.x_snd_tap(),
        "snd gain: a neutral policy pushes the mix itself")

  -- the full mix is untouched by ANY gain: snapshot the bank, render
  -- neutral, restore, render gained — byte-identical tap, gained device
  local gbank = pal.buf("snd.bank", 8208)
  local snap = gbank:str(0, 8208)
  pal.snd_render()
  local ref_tap = pal.x_snd_tap()
  gbank:setstr(0, snap)
  pal.x_snd_gain(128, 128, 64)
  pal.snd_render()
  check(pal.x_snd_tap() == ref_tap,
        "snd gain: the hashed mix is byte-identical under a gain")
  local dev = pal.x_snd_dev_tap()
  check(dev ~= ref_tap, "snd gain: the device copy is gained")
  local half_exact = true
  for i = 1, #ref_tap - 1, 2 do
    local s = string.unpack("<i2", ref_tap, i)
    local d = string.unpack("<i2", dev, i)
    -- gain 64 of 128 composes with the mix shift into acc>>3: exactly
    -- floor division by two of the unclamped tap, both signs
    if d ~= s // 2 then half_exact = false; break end
  end
  check(half_exact, "snd gain: half gain is exactly one arithmetic shift")
  snd.off(gv)
  for _ = 1, 30 do pal.snd_render() end

  -- category selection: music gain 0 silences ONLY music, device-side only
  pal.x_snd_gain(128, 0, 128)
  local mv = snd.on(40, 64, 100)
  pal.snd_render()
  check(pal.x_snd_tap():find("[^%z]") ~= nil
        and pal.x_snd_dev_tap():find("[^%z]") == nil,
        "snd gain: music gain 0 silences music on the device only")
  snd.off(mv)
  for _ = 1, 30 do pal.snd_render() end

  -- uncategorized slots ride master only: category gains never touch them
  pal.x_snd_gain(128, 0, 0)
  local uv = snd.on(60, 64, 100)
  pal.snd_render()
  check(pal.x_snd_dev_tap() == pal.x_snd_tap()
        and pal.x_snd_tap():find("[^%z]") ~= nil,
        "snd gain: uncategorized slots pass category gains at unity")
  snd.off(uv)
  for _ = 1, 30 do pal.snd_render() end

  -- out-of-range gains clamp (0..128), never error
  pal.x_snd_gain(-5, 999, 300)
  local cv = snd.on(40, 60, 100)
  pal.snd_render()
  check(pal.x_snd_dev_tap() == pal.x_snd_tap(),
        "snd gain: out-of-range gains clamp (999 = unity)")
  snd.off(cv)
  for _ = 1, 30 do pal.snd_render() end
  pal.x_snd_gain(128, 128, 128)
end

local function t_ins()
  -- R9c (AUDIO.md §4.1): the CINS instrument codec — round-trip,
  -- canonical bytes, embedded PCM, the upload door. Runs AFTER t_snd:
  -- it renders frames, and the PCM golden counts only t_snd's.
  local ins = cm.require("cm.ins")
  local doc = ins.fresh("bell")
  doc.patch.alg = 4
  doc.patch.ops[2].level = 200
  doc.patch.ops[2].coarse = 7
  local bytes = ins.encode(doc)
  check(bytes:sub(1, 4) == "CINS", "ins: container magic")
  local d2 = ins.decode(bytes)
  check(d2.name == "bell" and d2.patch.alg == 4
        and d2.patch.ops[2].coarse == 7 and d2.pcm == nil,
        "ins: fm doc round-trips")
  check(ins.encode(d2) == bytes, "ins: canonical encode")

  -- Instrument source publication is atomic. An interrupted replacement
  -- leaves the previous valid generation intact; retry publishes all CINS
  -- bytes, including embedded sample data.
  local savepath = (os.getenv("TMPDIR") or "/tmp")
                   .. "/cosmic_selftest_atomic.ins"
  check(ins.save(d2, savepath) == true, "ins save: seed generation")
  local saved = pal.read_file(savepath)
  local newer = ins.decode(bytes)
  newer.name = "newer"
  newer.patch.ops[2].coarse = 9
  local sok, serr = ins.save(newer, savepath, { _fail = "rename" })
  check(not sok and serr:find("write instrument failed")
        and pal.read_file(savepath) == saved,
        "ins save: failed replacement preserves previous source")
  check(ins.save(newer, savepath) == true
        and ins.decode(pal.read_file(savepath)).patch.ops[2].coarse == 9,
        "ins save: retry publishes complete source")
  pal.x_remove(savepath)

  local sdoc = { name = "crunch", pcm = string.pack("<i2i2i2", 5, -9, 7),
                 patch = { type = "sample", root = 60, loop = false,
                           a = 1, r = 10, s = 255 } }
  local sb = ins.encode(sdoc)
  local s2 = ins.decode(sb)
  check(s2.patch.type == "sample" and s2.pcm == sdoc.pcm
        and s2.patch.root == 60, "ins: sample doc embeds PCM")
  check(s2.patch.pcm == "", "ins: files never carry buffer names")

  -- upload: sample PCM lands in a named buffer, the patch points at it
  ins.upload(s2, 9, "sim", "kat")
  check(s2.patch.pcm == "snd.pcm/kat", "ins: upload names the PCM buffer")
  local found
  for _, b in ipairs(pal.buf_list()) do
    if b.name == s2.patch.pcm then found = b end
  end
  check(found ~= nil, "ins: the PCM buffer exists")
  local v = cm.require("cm.snd").on(9, 60, 127)
  pal.snd_render()
  check(pal.x_snd_tap():find("[^%z]") ~= nil, "ins: uploaded voice sounds")
  cm.require("cm.snd").off(v)
  for _ = 1, 6 do pal.snd_render() end
end

local function t_stock_ins()
  -- D147: the stock instrument roster — every shipped .ins decodes,
  -- encodes canonically (byte-identical re-encode), and SOUNDS through
  -- the real sim bank. The vibe-coverage expansion is pinned by name so
  -- a lost file fails loud, not silent.
  local ins = cm.require("cm.ins")
  local snd = cm.require("cm.snd")
  local names = {}
  for _, n in ipairs(pal.list_dir("engine/stock/ins") or {}) do
    if n:find("%.ins$") then names[#names + 1] = n end
  end
  table.sort(names)
  check(#names >= 52, "stock ins: the D147 roster ships (" .. #names .. ")")
  local have = {}
  for _, n in ipairs(names) do have[n] = true end
  for _, n in ipairs({ -- one pin per D147 vibe family
    "fm-strings.ins", "fm-choir.ins", "fm-harp.ins", "fm-flute.ins",
    "fm-reed.ins", "fm-timpani.ins", "fm-orchhit.ins", "fm-harpsi.ins",
    "fm-musicbox.ins", "fm-nylon.ins", "fm-upright.ins", "fm-vibes.ins",
    "fm-muted.ins", "fm-clav.ins", "fm-slap.ins", "fm-cowbell.ins",
    "fm-sub.ins", "fm-reese.ins", "fm-ride.ins", "fm-shaker.ins",
    "fm-rim.ins", "fm-conga.ins", "fm-drone.ins", "fm-glass.ins",
    "fm-xylo.ins" }) do
    check(have[n], "stock ins: " .. n .. " ships")
  end
  local all_ok, canon_ok, audible = true, true, true
  for _, n in ipairs(names) do
    local bytes = pal.read_file("engine/stock/ins/" .. n)
    local ok, doc = pcall(ins.decode, bytes)
    if not ok then
      all_ok = false
      pal.log("stock ins: " .. n .. " failed decode: " .. tostring(doc))
    else
      if ins.encode(doc) ~= bytes then
        canon_ok = false
        pal.log("stock ins: " .. n .. " is not canonical bytes")
      end
      -- the audibility sweep: a slow-attack pad needs a few frames
      -- before the tap carries signal; render up to 30 (500 ms)
      ins.upload(doc, 10, "sim", "stock")
      local v = snd.on(10, doc.patch.type == "fm" and 57 or 60, 110)
      local heard = false
      for _ = 1, 30 do
        pal.snd_render()
        if pal.x_snd_tap():find("[^%z]") then
          heard = true
          break
        end
      end
      if not heard then
        audible = false
        pal.log("stock ins: " .. n .. " rendered silence")
      end
      snd.off(v)
      for _ = 1, 10 do pal.snd_render() end
    end
  end
  for _ = 1, 120 do pal.snd_render() end -- long releases tail out
  check(all_ok, "stock ins: every preset decodes")
  check(canon_ok, "stock ins: every preset is canonical encode bytes")
  check(audible, "stock ins: every preset is audible in the sim bank")
end

local function t_words()
  -- cm.words: the auto-namer / graybox word bank. Data + a pure-over-
  -- the-seeded-stream name generator (dev RNG by default; seed for tests).
  local w = cm.require("cm.words")
  check(#w.list > 100, "words: a decent bank")
  local kebab = true
  for _, x in ipairs(w.list) do if x:find("[^a-z]") then kebab = false end end
  check(kebab, "words: every word is lowercase/kebab-safe")
  w.seed(1234)
  local a = w.name()
  w.seed(1234)
  check(w.name() == a, "words: a seeded name is reproducible")
  local parts = {}
  for pp in a:gmatch("[^%-]+") do parts[#parts + 1] = pp end
  check(#parts == 3 and parts[1] ~= parts[2] and parts[2] ~= parts[3]
        and parts[1] ~= parts[3], "words: name = 3 distinct words joined by -")
  local taken = { [a] = true }
  w.seed(1234) -- the stream would yield `a` first; unique must dodge it
  local u = w.unique(function(nm) return taken[nm] end)
  check(u ~= a and not taken[u], "words: unique() avoids a taken name")
  local seq, k = { 0, 5, 9 }, 0
  local pick = w.word(function() k = k + 1; return seq[k] end)
  check(pick == w.list[1], "words: a caller rng selects the word (sim-safe)")
end

local function t_palette()
  -- cm.palette: the .pal codec, hex import/export, the ramp generator,
  -- and the code-facing load door.
  local pl = cm.require("cm.palette")
  local paint = cm.require("cm.paint")
  local doc = { name = "test", colors = { 0x33221100, 0xaabbccff, 0x00ff00ff } }
  local bytes = pl.encode(doc)
  check(bytes:sub(1, 4) == "CPAL", "palette: container magic")
  local d2 = pl.decode(bytes)
  check(d2.name == "test" and #d2.colors == 3 and d2.colors[2] == 0xaabbccff,
        "palette: doc round-trips")
  check(pl.encode(d2) == bytes, "palette: canonical encode")
  -- Palette source publication is atomic. An interrupted replacement leaves
  -- the previous valid generation byte-for-byte intact; a retry publishes the
  -- complete newer document.
  local savepath = (os.getenv("TMPDIR") or "/tmp")
                   .. "/cosmic_selftest_atomic.pal"
  check(pl.save(d2, savepath) == true, "palette save: seed generation")
  local saved = pal.read_file(savepath)
  local newer = pl.decode(bytes)
  newer.name = "newer"
  newer.colors[1] = 0x010203ff
  local sok, serr = pl.save(newer, savepath, { _fail = "rename" })
  check(not sok and serr:find("write palette failed")
        and pal.read_file(savepath) == saved,
        "palette save: failed replacement preserves previous source")
  check(pl.save(newer, savepath) == true
        and pl.decode(pal.read_file(savepath)).colors[1] == 0x010203ff,
        "palette save: retry publishes complete source")
  pal.x_remove(savepath)
  -- hex import/export (Lospec .hex; R low byte, alpha forced opaque)
  local cols = pl.parse_hex("#ff0000\n00ff00\n0000ff")
  local r, g, b = paint.unpack(cols[1])
  check(#cols == 3 and r == 255 and g == 0 and b == 0,
        "palette: parse_hex reads RGB with R in the low byte")
  check(pl.to_hex({ cols[3] }) == "0000ff", "palette: to_hex")
  -- the ramp generator: n colors, monotone dark->light value
  local ramp = pl.ramp(0x804020ff, 5, { hue_shift = 12 })
  local _, _, v1 = paint.to_hsv(ramp[1])
  local _, _, v5 = paint.to_hsv(ramp[5])
  check(#ramp == 5 and v5 > v1, "palette: ramp is n colors, dark -> light")
  check(#pl.ramp(0x804020ff, 32) == 32, "palette: ramp at the 32-shade cap")
  -- fresh starter colors are cm.paint-packed OPAQUE (the D141
  -- display-packed-constant class: a 0xRRGGBBAA literal here reads as
  -- near-transparent + channel-swapped; the palette tape caught it via
  -- the working-color adopt comparing exact bytes)
  local fr = pl.fresh("x")
  local allop = true
  for _, fc in ipairs(fr.colors) do
    if (fc >> 24) & 255 ~= 255 then allop = false end
  end
  check(allop and #fr.colors >= 4,
        "palette: fresh colors opaque in paint packing")
  local _, _, fv1 = paint.to_hsv(fr.colors[1])
  local _, _, fvn = paint.to_hsv(fr.colors[#fr.colors])
  check(fvn > fv1, "palette: fresh ramp runs dark -> light")
  -- the load() door (file-backed, cached)
  pal.write_file("/tmp/cosmic_selftest.pal", bytes)
  local ld = pl.load("/tmp/cosmic_selftest.pal")
  check(ld and #ld.colors == 3, "palette: load() reads a .pal")
  check(pl.color("/tmp/cosmic_selftest.pal", 2) == 0xaabbccff,
        "palette: color() indexes a loaded palette")
  pal.x_remove("/tmp/cosmic_selftest.pal")
end

local function t_song()
  -- R9d (AUDIO.md §4.2/§6): the CSNG codec, the flatten, tick math,
  -- and the sequencer end to end. Runs AFTER t_snd (renders frames).
  local song = cm.require("cm.song")
  local snd = cm.require("cm.snd")
  local st = cm.require("cm.state")

  -- tick math: at 120 bpm, 1 beat = 96 ticks = 24000 samples = 30 frames
  check(snd.seq.samples_at(96, 120) == 24000
        and snd.seq.ticks_at(24000, 120) == 96
        and snd.seq.ticks_at(23999, 120) == 95, "song: tick math exact")

  -- the clip-arrangement model (round 7): clips place patterns on
  -- tracks; each clip owns its own pattern. fresh gives one of each.
  local doc = song.fresh()
  check(#doc.tracks == 1 and #doc.clips == 1 and doc.clips[1].pattern == 1
        and doc.patterns[1] ~= nil, "song: fresh = 1 track/clip/pattern")
  doc.bpm = 140
  doc.tracks[1].ins = "x.ins"
  doc.patterns[1].len = 96 * 4
  doc.patterns[1].notes = { { tick = 96, dur = 48, pitch = 64, vel = 90 },
                            { tick = 0, dur = 96, pitch = 60, vel = 100 } }
  doc.clips[1].len = 96 * 8 -- the clip is 8 beats over a 4-beat pattern
  local bytes = song.encode(doc)
  check(bytes:sub(1, 4) == "CSNG", "song: container magic")
  local d2 = song.decode(bytes)
  check(d2.bpm == 140 and #d2.tracks == 1 and d2.tracks[1].ins == "x.ins"
        and #d2.clips == 1 and d2.clips[1].len == 96 * 8,
        "song: tracks + clips round-trip")
  check(#d2.patterns[1].notes == 2 and d2.patterns[1].notes[1].tick == 0,
        "song: pattern round-trips, canonical note order")
  check(song.encode(d2) == bytes, "song: canonical encode")

  -- Song source publication is atomic. An interrupted replacement leaves the
  -- previous arrangement intact; retry publishes the complete newer CSNG.
  local savepath = (os.getenv("TMPDIR") or "/tmp")
                   .. "/cosmic_selftest_atomic.song"
  check(song.save(d2, savepath) == true, "song save: seed generation")
  local saved = pal.read_file(savepath)
  local newer = song.decode(bytes)
  newer.bpm = 173
  newer.tracks[1].name = "newer"
  local sok, serr = song.save(newer, savepath, { _fail = "rename" })
  check(not sok and serr:find("write song failed")
        and pal.read_file(savepath) == saved,
        "song save: failed replacement preserves previous source")
  check(song.save(newer, savepath) == true
        and song.decode(pal.read_file(savepath)).bpm == 173,
        "song save: retry publishes complete source")
  pal.x_remove(savepath)

  -- The real music-window path keeps both the disk generation and dirty
  -- working arrangement trustworthy across a failed atomic replacement.
  local MW = cm.require("cm.ed.win.music")
  local root = tmproot() .. "/cosmic_selftest_ed_song_save"
  pal.mkdir(root)
  local path = "atomic.song"
  pal.write_file(root .. "/" .. path, bytes)
  local summoned = false
  local ed = { root = root, g = {}, doc = { assets = {} }, parked = false,
               touch = function() end,
               summon_console = function() summoned = true end }
  local win = { path = path }
  local _, p = MW.open_win(win, ed)
  p.doc.bpm = 199
  p.doc.tracks[1].name = "unsaved"
  p._save_fail = { _fail = "rename" }
  MW.save(win, ed)
  check(pal.read_file(root .. "/" .. path) == bytes,
        "ed.music save: failure preserves previous song")
  check(MW.dirty(win, ed) and p.doc.bpm == 199
        and p.doc.tracks[1].name == "unsaved",
        "ed.music save: failure retains dirty working bytes")
  check(summoned, "ed.music save: failure summons the console")
  p._save_fail = nil
  MW.save(win, ed)
  local published = song.decode(pal.read_file(root .. "/" .. path))
  check(not MW.dirty(win, ed) and published.bpm == 199
        and published.tracks[1].name == "unsaved",
        "ed.music save: retry publishes complete source")

  -- the flatten: the clip LOOPS its 4-beat pattern to fill 8 beats
  local flat = song.flatten(d2)
  check(#flat == 1 and #flat[1] == 4, "song: clip loops the pattern")
  check(flat[1][1].tick == 0 and flat[1][2].tick == 96
        and flat[1][3].tick == 96 * 4 and flat[1][4].tick == 96 * 5,
        "song: looped ticks")

  -- fit_pattern GROWS to whole bars but never shrinks (round 6)
  song.fit_pattern(d2, d2.patterns[1])
  check(d2.patterns[1].len == 96 * 4, "song: fit keeps a fitting length")
  d2.patterns[1].notes[#d2.patterns[1].notes + 1] =
    { tick = 96 * 5, dur = 48, pitch = 72, vel = 100 } -- into bar 2
  song.fit_pattern(d2, d2.patterns[1])
  check(d2.patterns[1].len == 96 * 8, "song: fit grows to whole bars")
  d2.patterns[1].notes = {}
  song.fit_pattern(d2, d2.patterns[1])
  check(d2.patterns[1].len == 96 * 8, "song: fit never shrinks")

  -- deliberate SHARING (round 8, the human): two clips on the SAME
  -- pattern id stay linked through normalize (edit once, both follow) —
  -- normalize no longer splits them; it only heals MISSING patterns
  local shared = song.fresh()
  shared.tracks[2] = { name = "t2", ins = "", gain = 128, pan = 0, mute = false }
  shared.clips[2] = { track = 1, tick = 0, len = 96 * 4, pattern = 1 } -- shares!
  song.normalize(shared)
  check(shared.clips[1].pattern == shared.clips[2].pattern
        and shared.clips[1].pattern == 1,
        "song: normalize keeps deliberately shared patterns linked")
  -- and the link SURVIVES a save/load round-trip (one pattern, two clips)
  shared.patterns[1].notes = { { tick = 0, dur = 48, pitch = 60, vel = 100 } }
  local sd = song.decode(song.encode(shared))
  check(sd.clips[1].pattern == sd.clips[2].pattern, "song: sharing round-trips")
  check(#song.flatten(sd)[1] == 1 and #song.flatten(sd)[2] == 1,
        "song: both linked clips play the shared pattern's notes")
  local orphan = song.fresh()
  orphan.clips[1].pattern = 999 -- points at a missing pattern
  song.normalize(orphan)
  check(orphan.patterns[orphan.clips[1].pattern] ~= nil,
        "song: normalize heals a clip pointing at a missing pattern")

  -- round-6 migration: a doc with track.pat + no clips becomes clips
  local r6 = { bpm = 120, beats_per_bar = 4, grid = 8, loop0 = 0,
               loop1 = 96 * 4,
               tracks = { { name = "a", ins = "", gain = 128, pan = 0,
                            mute = false, pat = 5 } },
               patterns = { [5] = { id = 5, len = 96 * 4,
                 notes = { { tick = 0, dur = 96, pitch = 55, vel = 100 } } } },
               clips = {} }
  song.normalize(r6)
  check(#r6.clips == 1 and r6.clips[1].pattern == 5
        and r6.tracks[1].pat == nil, "song: round-6 track.pat -> a clip")
  check(#song.flatten(r6)[1] == 1, "song: migrated notes survive")

  -- the sequencer end to end: a real song + ins on disk, doc.snd
  -- transport, frames stepped (start rewound per step — the sim frame
  -- counter itself stays untouched for the tests after us)
  local root = tmproot()
  local ins = cm.require("cm.ins")
  pal.write_file(root .. "/cosmic_seq.ins", ins.encode(ins.fresh("seq")))
  local sdoc = song.fresh()
  sdoc.tracks[1].ins = root .. "/cosmic_seq.ins"
  sdoc.patterns[1].len = 96 * 4
  sdoc.patterns[1].notes = { { tick = 0, dur = 96, pitch = 60, vel = 110 } }
  sdoc.clips[1].len = 96 * 4
  sdoc.loop1 = 96 * 4
  pal.write_file(root .. "/cosmic_seq.song", song.encode(sdoc))
  snd.music(root .. "/cosmic_seq.song")
  check(st.doc.snd and st.doc.snd.song == root .. "/cosmic_seq.song",
        "song: music() sets the doc-tree transport")
  local function stepf()
    snd.step()
    pal.snd_render()
    st.doc.snd.start = st.doc.snd.start - 1 -- simulate the next frame
  end
  stepf()
  check(next(st.doc.snd.held) ~= nil, "song: frame 0 rings the note")
  check(pal.x_snd_tap():find("[^%z]") ~= nil, "song: audible")
  for _ = 1, 32 do stepf() end -- past 30 frames: the off landed
  check(next(st.doc.snd.held) == nil, "song: the off releases on time")
  -- the loop wraps: by frame 480 (4 beats) the note re-rings
  for _ = 1, 448 do stepf() end
  check(next(st.doc.snd.held) ~= nil, "song: the loop re-rings")
  snd.music_stop()
  check(st.doc.snd == nil, "song: music_stop clears the transport")
  for _ = 1, 10 do pal.snd_render() end

  -- group velocity/length math (human round 8): CTRL snaps all to the
  -- target; else OFFSET each base by the grabbed note's delta, clamped.
  local mus = cm.require("cm.ed.win.music")
  check(mus.group_val(50, 80, 110, false, 1, 127) == 80,
        "music.group_val: offset (+30) keeps relative spread")
  check(mus.group_val(120, 80, 110, false, 1, 127) == 127,
        "music.group_val: offset clamps to hi")
  check(mus.group_val(50, 80, 110, true, 1, 127) == 110,
        "music.group_val: CTRL snaps to the same target")
  check(mus.group_val(10, 5, 3, false, 1, 1 << 30) == 8,
        "music.group_val: length offset (-2) clamps to >=1")
end

local function t_stock_songs()
  -- D147: the stock demo tracks — every shipped .song decodes to
  -- canonical bytes, flattens to real notes, resolves every track
  -- instrument (engine-relative stock refs), and SOUNDS through the
  -- sim bank. One pin per queued vibe family.
  local songm = cm.require("cm.song")
  local insm = cm.require("cm.ins")
  local snd = cm.require("cm.snd")
  local names = {}
  for _, n in ipairs(pal.list_dir("engine/stock/songs") or {}) do
    if n:find("%.song$") then names[#names + 1] = n end
  end
  table.sort(names)
  check(#names >= 14, "stock songs: the D147 set ships (" .. #names .. ")")
  local have = {}
  for _, n in ipairs(names) do have[n] = true end
  for _, n in ipairs({ "desert-dunes.song", "water-caverns.song",
    "noble-court.song", "prelude-soft.song", "battle-charge.song",
    "boss-gate.song", "dnb-rush.song", "breaks-alley.song",
    "bossa-breeze.song", "bossa-fiesta.song", "funk-strut.song",
    "noir-sleuth.song", "horror-hollow.song", "ambient-drift.song" }) do
    check(have[n], "stock songs: " .. n .. " ships")
  end
  local decode_ok, canon_ok, notes_ok, ins_ok, audible = true, true, true,
                                                         true, true
  for _, n in ipairs(names) do
    local bytes = pal.read_file("engine/stock/songs/" .. n)
    local ok, doc = pcall(songm.decode, bytes)
    if not ok then
      decode_ok = false
      pal.log("stock songs: " .. n .. " failed decode: " .. tostring(doc))
    else
      if songm.encode(doc) ~= bytes then
        canon_ok = false
        pal.log("stock songs: " .. n .. " is not canonical bytes")
      end
      local flat = songm.flatten(doc)
      local total = 0
      for _, lane in ipairs(flat) do total = total + #lane end
      if total == 0 or songm.length(doc) <= 0 then
        notes_ok = false
        pal.log("stock songs: " .. n .. " flattens empty")
      end
      local first_slot
      for ti, tr in ipairs(doc.tracks) do
        local ib = pal.read_file(tr.ins)
        local iok, idoc = false, nil
        if ib then iok, idoc = pcall(insm.decode, ib) end
        if not iok then
          ins_ok = false
          pal.log("stock songs: " .. n .. " track " .. ti
                  .. " ins unresolvable: " .. tostring(tr.ins))
        elseif not first_slot and #(flat[ti] or {}) > 0 then
          insm.upload(idoc, 11, "sim", "ss")
          first_slot = ti
        end
      end
      if first_slot then -- the song's own first note, audibly
        local note = flat[first_slot][1]
        local v = snd.on(11, note.pitch, note.vel)
        local heard = false
        for _ = 1, 30 do
          pal.snd_render()
          if pal.x_snd_tap():find("[^%z]") then
            heard = true
            break
          end
        end
        if not heard then
          audible = false
          pal.log("stock songs: " .. n .. " first note rendered silence")
        end
        snd.off(v)
        for _ = 1, 10 do pal.snd_render() end
      end
    end
  end
  for _ = 1, 120 do pal.snd_render() end
  check(decode_ok, "stock songs: every song decodes")
  check(canon_ok, "stock songs: every song is canonical encode bytes")
  check(notes_ok, "stock songs: every song flattens to real notes")
  check(ins_ok, "stock songs: every track instrument resolves")
  check(audible, "stock songs: every song's opening note is audible")
end

local function t_snd_claim()
  -- D147 addendum: editor-bank slot ownership. snd_alloc round-robins
  -- 64 slots and never frees, so a long session WRAPS and two live
  -- audio windows share a slot — the later upload silently replaced
  -- the earlier window's patch ("two breaks-alley windows play
  -- differently"). snd_claim is the stamp: owners re-send their patch
  -- whenever the stamp isn't theirs.
  local kit = cm.require("cm.ed.kit")
  local ed = { g = {} }
  check(kit.snd_claim(ed, 5, "a") == false,
        "snd_claim: the first claim stamps (caller uploads)")
  check(kit.snd_claim(ed, 5, "a") == true,
        "snd_claim: a held stamp needs no re-upload")
  check(kit.snd_claim(ed, 5, "b") == false,
        "snd_claim: a foreign stamp flips ownership (b uploads)")
  check(kit.snd_claim(ed, 5, "a") == false,
        "snd_claim: the original owner re-claims after the steal")
  check(kit.snd_claim(ed, 6, "a") == false
        and kit.snd_claim(ed, 5, "a") == true,
        "snd_claim: slots stamp independently")
end

local function t_preview_voice()
  -- D147 addendum 2: the music preview's voice picker. The old blind
  -- round-robin OVERWROTE still-held voices (x_snd_ed_on with an
  -- explicit index) — a chord dragged across bars died after ~24
  -- percussion events ("the long chords stop after ~1 bar", dunes).
  local pv = cm.require("cm.ed.win.music").preview_voice
  local v, nxt = pv({}, {}, nil)
  check(v == 8 and nxt == 9, "preview_voice: fresh state starts at 8")
  v = pv({ a = 8, b = 9 }, {}, 8)
  check(v == 10, "preview_voice: held voices are skipped, never stomped")
  v = pv({ x = 31 }, {}, 31)
  check(v == 8, "preview_voice: the scan wraps 31 -> 8")
  v = pv({}, { [10] = 5 }, 10)
  check(v == 11, "preview_voice: ringing blips are skipped too")
  local all = {}
  for i = 8, 31 do all["h" .. i] = i end
  v = pv(all, {}, 14)
  check(v == 14, "preview_voice: every voice held steals in order")
end

local function t_stock_window()
  -- D147: the read-only stock-assets window — the list spans the five
  -- shipped families, dest mapping + auto-name uniquifying, the copy
  -- door, and the kit seed door (open-a-copy = unsaved working state
  -- on a fresh name, dirty, journaled to the seed floor, disk untouched
  -- until the user's own save).
  local S = cm.require("cm.ed.win.stock")
  local W = cm.require("cm.ed.win.synth")
  local root = tmproot() .. "/cosmic_selftest_stock"
  pal.mkdir(root)
  local journal = cm.require("cm.ed.journal")
  for _, leftover in ipairs({ "ins/fm-harp.ins", "ins/fm-vibes.ins",
      "ins/fm-glass.ins", "ins/fm-glass-2.ins",
      "sound/ambient-drift.song" }) do
    pal.x_remove(root .. "/" .. leftover) -- prior-run artifacts
    pal.x_remove(journal.file(root, leftover))
    pal.x_remove(journal.good_file(root, leftover))
  end
  local ed = { root = root, g = {}, doc = { assets = {} }, parked = false,
               touch = function() end, kinds = cm.require("cm.ed").kinds }

  local list = S.stock_list(ed)
  local fams, have = {}, {}
  for _, e in ipairs(list) do
    fams[e.family] = (fams[e.family] or 0) + 1
    have[e.rel] = true
  end
  check(fams.ins and fams.ins >= 52 and fams.songs and fams.songs >= 14
        and fams.art and fams.fig and fams.pal,
        "stock win: the list spans all five families")
  check(have["engine/stock/ins/fm-strings.ins"]
        and have["engine/stock/songs/desert-dunes.song"]
        and have["engine/stock/spr/tiles.spr"]
        and have["engine/stock/fig/mascot.fig"]
        and have["engine/stock/pal/db16.pal"],
        "stock win: one known entry per family")
  local pruned = true
  for _, e in ipairs(list) do
    if e.rel:find("tiles%.png") or e.rel:find("tiles%.meta") then
      pruned = false
    end
  end
  check(pruned, "stock win: baked sprite siblings are pruned")

  check(S.dest_for("engine/stock/ins/fm-harp.ins") == "ins/fm-harp.ins"
        and S.dest_for("engine/stock/songs/dnb-rush.song")
            == "sound/dnb-rush.song"
        and S.dest_for("engine/stock/spr/tiles.spr") == "art/tiles.spr"
        and S.dest_for("engine/stock/pal/db16.pal") == "pal/db16.pal",
        "stock win: dest mapping per family")

  -- unique naming dodges disk files AND unsaved working states
  check(S.unique_dest(ed, "engine/stock/ins/fm-harp.ins")
        == "ins/fm-harp.ins", "stock win: a free name stays itself")
  pal.mkdir(root .. "/ins")
  pal.write_file(root .. "/ins/fm-harp.ins", "taken")
  check(S.unique_dest(ed, "engine/stock/ins/fm-harp.ins")
        == "ins/fm-harp-2.ins", "stock win: a disk collision counts up")
  ed.doc.assets["ins/fm-harp-2.ins"] = { ins = "working" }
  check(S.unique_dest(ed, "engine/stock/ins/fm-harp.ins")
        == "ins/fm-harp-3.ins", "stock win: a working-state collision too")
  ed.doc.assets["ins/fm-harp-2.ins"] = nil

  -- the copy door writes byte-identical and flashes the browser
  local dest = S.copy_in(ed, "engine/stock/ins/fm-vibes.ins")
  check(dest == "ins/fm-vibes.ins"
        and pal.read_file(root .. "/" .. dest)
            == pal.read_file("engine/stock/ins/fm-vibes.ins"),
        "stock win: copy_in lands byte-identical at the dest")
  check(ed.g.aflash and ed.g.aflash.path == dest,
        "stock win: copy_in flashes the new asset")

  -- the seed door: open-a-copy is unsaved work, not a disk write
  local sbytes = pal.read_file("engine/stock/ins/fm-glass.ins")
  local sdest = S.unique_dest(ed, "engine/stock/ins/fm-glass.ins")
  check(W.seed(ed, sdest, sbytes) == true, "stock win: seed takes a free path")
  check(W.seed(ed, sdest, sbytes) == nil,
        "stock win: seed declines a seeded path")
  check(W.seed(ed, "ins/fm-harp.ins", sbytes) == nil,
        "stock win: seed declines an existing file")
  check(pal.read_file(root .. "/" .. sdest) == nil,
        "stock win: seeding writes nothing to disk")
  local win = { path = sdest }
  local a, p = W.open_win(win, ed)
  check(a ~= nil and a.ins == sbytes, "stock win: the open adopts the seed")
  check(W.dirty(win, ed) == true, "stock win: the opened copy is unsaved")
  check(p.doc ~= nil and p.doc.patch ~= nil,
        "stock win: the seed decodes as a real instrument")
  check(#p.j.entries == 1 and p.j.entries[1].bytes == sbytes,
        "stock win: the seed bytes are the journal undo floor")
  check(W.save(win, ed) == true
        and pal.read_file(root .. "/" .. sdest) ~= nil
        and W.dirty(win, ed) == false,
        "stock win: the user's own save publishes the copy")

  -- open_copy end to end (no shell: the window-spawn half is tape-proven)
  local odest = S.open_copy(ed, "engine/stock/songs/ambient-drift.song")
  check(odest == "sound/ambient-drift.song"
        and ed.doc.assets[odest] ~= nil
        and ed.doc.assets[odest].song
            == pal.read_file("engine/stock/songs/ambient-drift.song")
        and pal.read_file(root .. "/" .. odest) == nil,
        "stock win: open_copy seeds the song unsaved on its auto name")

  -- parked = the write wall
  ed.parked = true
  check(S.copy_in(ed, "engine/stock/ins/fm-sub.ins") == nil,
        "stock win: parked copies are walled")
  ed.parked = false
end

local function t_ed_kit()
  -- cm.ed.kit (R9a, AUDIO.md §7): the generalized §6 asset citizen —
  -- the factory's semantics pinned on a dummy codec, independent of the
  -- four migrated kinds (whose own tests pin behavior-identity)
  local kit = cm.require("cm.ed.kit")
  local journal = cm.require("cm.ed.journal")
  local root = tmproot() .. "/cosmic_selftest_kit"
  pal.mkdir(root)
  local adopts, saves = 0, 0
  -- dummy codec: doc = { v = <string> }, bytes = "K:" .. v
  local A = kit.asset {
    gkey = "kw", field = "k", jcap = 8,
    fresh = function() return "K:fresh" end,
    adopt = function(p, bytes)
      p.doc = { v = bytes:match("^K:(.*)$") }
      adopts = adopts + 1
    end,
    encode = function(doc) return "K:" .. doc.v end,
    after_save = function() saves = saves + 1 end,
  }
  local function mked()
    return { root = root, g = {}, doc = { assets = {} },
             touch = function() end, parked = false }
  end

  -- fresh open: no disk file -> fresh bytes, no baseline entry
  -- (reset both the journal AND the asset across runs — a prior run's
  -- save leaves a.k on disk, which would take the adopt-disk path)
  pal.x_remove(journal.file(root, "a.k"))
  pal.x_remove(journal.good_file(root, "a.k"))
  pal.x_remove(root .. "/a.k")
  local ed = mked()
  local win = { path = "a.k" }
  local a, p = A.open_asset(ed, "a.k")
  check(a.k == "K:fresh" and p.doc.v == "fresh",
        "ed.kit: fresh open adopts fresh bytes")
  check(#p.j.entries == 1 and p.j.entries[1].bytes == "K:fresh",
        "ed.kit: fresh bytes journal as the undo floor")
  check(A.dirty(win, ed) == true, "ed.kit: fresh bytes ≠ empty disk = dirty")

  -- commit: encode + journal + jpos; dedupe leaves the journal alone
  p.doc.v = "one"
  A.commit(ed, "a.k")
  check(a.k == "K:one" and #p.j.entries == 2 and a.jpos == 2,
        "ed.kit: commit encodes + journals")
  A.commit(ed, "a.k")
  check(#p.j.entries == 2, "ed.kit: identical commit dedupes")
  -- the first edit walks back to the fresh floor
  A.undo(win, ed)
  check(a.k == "K:fresh", "ed.kit: undo reaches the fresh floor")
  A.redo(win, ed)
  check(a.k == "K:one", "ed.kit: redo returns")

  -- save: disk write + SAVED flag + after_save; then clean
  A.save(win, ed)
  check(pal.read_file(root .. "/a.k") == "K:one" and saves == 1,
        "ed.kit: save writes disk + side effects")
  check(p.j.entries[#p.j.entries].flags == journal.SAVED,
        "ed.kit: save flags the tip")
  check(A.dirty(win, ed) == false, "ed.kit: saved = clean")

  -- undo/redo walk + adopt; revert is a journaled (undoable) edit
  p.doc.v = "two"
  A.commit(ed, "a.k")
  local n0 = adopts
  A.undo(win, ed)
  check(a.k == "K:one" and p.doc.v == "one" and adopts == n0 + 1,
        "ed.kit: undo re-adopts")
  A.redo(win, ed)
  check(a.k == "K:two", "ed.kit: redo returns to the tip")
  A.revert(win, ed)
  check(a.k == "K:one" and A.dirty(win, ed) == false,
        "ed.kit: revert adopts disk")
  A.undo(win, ed)
  check(a.k == "K:two", "ed.kit: revert was one undoable step")

  -- restart adoption: a second ed re-opens; session-restored unsaved
  -- work the journal hasn't seen lands as an entry (Ctrl+Z works)
  local ed2 = mked()
  ed2.doc.assets["a.k"] = { k = "K:poked", jpos = 0 }
  local a2, p2 = A.open_asset(ed2, "a.k")
  check(p2.j.entries[#p2.j.entries].bytes == "K:poked",
        "ed.kit: restart journals restored unsaved work")

  -- parked discipline (R6c): reopen writes nothing, commit is
  -- ephemeral, save is walled
  local ed3 = mked()
  ed3.parked = true
  local a3, p3 = A.open_asset(ed3, "a.k")
  local nent = #p3.j.entries
  a3.k = "K:parked"
  p3.doc.v = "parked"
  A.commit(ed3, "a.k")
  check(#p3.j.entries == nent and a3.k == "K:parked",
        "ed.kit: parked commit updates bytes, never the journal")
  A.save(win, ed3)
  check(pal.read_file(root .. "/a.k") == "K:one",
        "ed.kit: parked save is walled")

  -- the raw kind (no encode, the text model): baseline_always +
  -- push semantics + pre_undo closes the open gesture
  local closed = 0
  local R
  R = kit.asset {
    gkey = "rw", field = "r", baseline_always = true,
    adopt = function(p) p.readopt = true end,
    pre_undo = function(ed, path, a, p)
      if p.due then R.push(ed, path); closed = closed + 1 end
    end,
  }
  pal.x_remove(journal.file(root, "b.r"))
  pal.x_remove(journal.good_file(root, "b.r"))
  pal.write_file(root .. "/b.r", "")
  local edr = mked()
  local winr = { path = "b.r" }
  local ar, pr = R.open_asset(edr, "b.r")
  check(ar.r == "" and #pr.j.entries == 1,
        "ed.kit raw: empty disk still baselines (text model)")
  ar.r = "hello"
  pr.due = true
  R.undo(winr, edr) -- pre_undo pushes the due gesture, then walks back
  check(closed == 1 and ar.r == "" and pr.readopt,
        "ed.kit raw: pre_undo closes the gesture, undo re-adopts")
  R.redo(winr, edr)
  check(ar.r == "hello", "ed.kit raw: redo returns the pushed gesture")

  -- per-window hotkeys (§13): spec parse, exact-mod dispatch, when
  -- gating, hints
  local ks = kit.keyspec("ctrl+shift+p")
  check(ks.sc == 19 and ks.ctrl and ks.shift and not ks.alt,
        "ed.kit: keyspec parses mods + name")
  check(kit.keyspec("bogus") == nil, "ed.kit: unknown key -> nil")
  local fired = {}
  local kind = { hotkeys = {
    { key = "p", hint = "pen", fn = function() fired.p = true end },
    { key = "shift+1", fn = function() fired.fit = true end },
    { key = "g", hint = "grid", when = function(w) return w.armed end,
      fn = function() fired.g = true end },
  } }
  local kwin = { armed = false }
  local none = {}
  local function ev(sc) return { down = true, rep = false, scancode = sc } end
  check(kit.hotkey(kind, kwin, ed, ev(19), none) == true and fired.p,
        "ed.kit: plain key dispatches")
  check(kit.hotkey(kind, kwin, ed, ev(19), { ctrl = true }) == false,
        "ed.kit: extra mod never matches (exact mods)")
  check(kit.hotkey(kind, kwin, ed, ev(30), { shift = true }) == true
        and fired.fit, "ed.kit: shift+1 dispatches")
  check(kit.hotkey(kind, kwin, ed, ev(10), none) == false and not fired.g,
        "ed.kit: failing when() falls through")
  kwin.armed = true
  check(kit.hotkey(kind, kwin, ed, ev(10), none) == true and fired.g,
        "ed.kit: passing when() dispatches")
  -- D135: a repeat of a matched edge-only entry is CONSUMED without
  -- firing (held keys stay the entry's); rep = true entries step —
  -- the full contract is pinned in t_kit_rep
  fired.p = false
  check(kit.hotkey(kind, kwin, ed,
                   { down = true, rep = true, scancode = 19 }, none)
        == true and fired.p == false,
        "ed.kit: a repeat of an edge-only entry consumes, never fires")
  local hints = kit.hints(kind, kwin, ed)
  check(#hints == 2 and hints[1].hint == "pen" and hints[2].key == "g",
        "ed.kit: hints = when-passing entries with hint text")
end

local function t_ed_lex()
  -- cm.ed.lex — the code-ed tokenizers (R4, EDITOR.md §12.2). Pure KATs.
  local lex = cm.require("cm.ed.lex")
  check(lex.lang_of("a/b.lua") == "lua" and lex.lang_of("X.MD") == "md"
        and lex.lang_of("noext") == "txt", "ed.lex: lang_of")

  local function kinds(lang, s, carry)
    local toks, out = lex.line(lang, s, carry)
    local ks = {}
    for _, t in ipairs(toks) do ks[#ks + 1] = t.k .. ":" .. s:sub(t.a, t.b) end
    return table.concat(ks, "|"), out
  end

  local ks = kinds("lua", 'local x = "hi" -- note')
  check(ks == 'kw:local|str:"hi"|com:-- note', "ed.lex: lua basics (" .. ks .. ")")
  ks = kinds("lua", "if n == 0x1F or n == 42.5 then return end")
  check(ks == "kw:if|num:0x1F|kw:or|num:42.5|kw:then|kw:return|kw:end",
        "ed.lex: lua numbers + keywords (" .. ks .. ")")
  ks = kinds("lua", [[s = 'it\'s' .. x]])
  check(ks == [[str:'it\'s']], "ed.lex: escaped quote (" .. ks .. ")")

  -- long comment across lines: carry threads
  local ks1, c1 = kinds("lua", "x = 1 --[[ start")
  check(ks1 == "num:1|com:--[[ start" and c1 == "c0",
        "ed.lex: long comment opens (" .. ks1 .. " " .. tostring(c1) .. ")")
  local ks2, c2 = kinds("lua", "still comment ]] print(1)", c1)
  check(ks2 == "com:still comment ]]|num:1" and c2 == "",
        "ed.lex: long comment closes (" .. ks2 .. ")")
  local _, c3 = kinds("lua", "b = [==[ raw")
  check(c3 == "s2", "ed.lex: long string carry level")
  local ks4, c4 = kinds("lua", "body ]=] not yet ]==] x", c3)
  check(c4 == "" and ks4:find("^str:body %]=%] not yet %]==%]"),
        "ed.lex: level-matched close only (" .. ks4 .. ")")
  -- carry_line agrees with line() on the carry it returns
  local _, cl = lex.line("lua", "x = 1 --[[ start")
  check(lex.carry_line("lua", "x = 1 --[[ start") == cl,
        "ed.lex: carry_line agrees with line()")

  -- md faces
  ks = kinds("md", "## heading here")
  check(ks == "h:## heading here", "ed.lex: md heading")
  local toks = lex.line("md", "see [the doc](docs/EDITOR.md) and `code`")
  check(toks[1].k == "link" and toks[1].t == "docs/EDITOR.md"
        and toks[2].k == "code", "ed.lex: md link target + code span")
  local _, f1 = kinds("md", "```lua")
  check(f1 == "f", "ed.lex: md fence opens")
  local ksf, f2 = kinds("md", "local inside = 1", f1)
  check(ksf == "code:local inside = 1" and f2 == "f",
        "ed.lex: fenced line is code")
  local _, f3 = kinds("md", "```", f2)
  check(f3 == "", "ed.lex: md fence closes")

  -- link_at
  local s = "see [x](a/b.md) or require('cm.ed.wm') or docs/PLAN.md ok"
  local _, _, t1 = lex.link_at(s, 8)
  check(t1 == "a/b.md", "ed.lex: link_at md (" .. tostring(t1) .. ")")
  local _, _, t2 = lex.link_at(s, s:find("cm%.ed"))
  check(t2 == "cm.ed.wm", "ed.lex: link_at quoted (" .. tostring(t2) .. ")")
  local _, _, t3 = lex.link_at(s, s:find("PLAN"))
  check(t3 == "docs/PLAN.md", "ed.lex: link_at bare path (" .. tostring(t3) .. ")")
  check(lex.link_at("plain words only", 4) == nil, "ed.lex: no false link")
end

local function t_ed_assets()
  -- cm.ed.win.assets — the pure bits: fuzzy scorer + type classes (R4d)
  local A = cm.require("cm.ed.win.assets")
  check(A.fuzzy("", "anything") == 0, "ed.assets: empty needle matches all")
  check(A.fuzzy("xyz", "player.lua") == nil, "ed.assets: no match = nil")
  check(A.fuzzy("plr", "player.lua") ~= nil, "ed.assets: subsequence hits")
  local exact = A.fuzzy("player", "player.lua")
  local spread = A.fuzzy("player", "p_l_a_y_e_r_x.lua")
  check(exact and spread and exact > spread,
        "ed.assets: consecutive beats spread")
  local short = A.fuzzy("main", "main.lua")
  local long = A.fuzzy("main", "domain_chain_main.lua")
  check(short and long and short > long, "ed.assets: shorter path wins")

  check(A.class_of("a/b.PNG") == "image" and A.class_of("x.lua") == "code"
        and A.class_of("s.ogg") == "sound" and A.class_of("d.dat") == "other",
        "ed.assets: class_of")
  check(A.class_of("r.bmp") == "image" and A.class_of("r.tga") == "image"
        and A.class_of("r.psd") == "image" and A.class_of("r.ppm") == "image",
        "ed.assets: every stb format classes as image")
  check(A.kind_for("art/girl.spr") == "sprite"
        and A.kind_for("art/x.png") == "image"
        and A.kind_for("art/ref.jpg") == "image"
        and A.kind_for("main.lua") == "text"
        and A.kind_for("maps/rim.map") == "map"
        and A.kind_for("deco/d.tm") == "tmap"
        and A.kind_for("s.ogg") == "sound" -- the player (R9c — M9 paid)
        and A.kind_for("s.xyz") == nil, "ed.assets: kind_for")

  -- the drop conversion (the human's ask): a non-png image converts to
  -- .png on the way in — stb decodes it, the project stores canon png
  local function bmp2x1() -- 24-bit BMP, red then green
    local row = string.char(0, 0, 255, 0, 255, 0, 0, 0) -- BGR BGR pad
    local dib = string.pack("<I4i4i4I2I2I4I4i4i4I4I4",
                            40, 2, 1, 1, 24, 0, #row, 2835, 2835, 0, 0)
    return "BM" .. string.pack("<I4I2I2I4", 54 + #row, 0, 0, 54) .. dib .. row
  end
  local root = tmproot() .. "/cosmic_selftest_drop"
  pal.mkdir(root)
  local src = root .. "_src.bmp"
  pal.write_file(src, bmp2x1())
  local ed = { root = root, g = {} }
  local rel = A.add_dropped(ed, src)
  check(rel == "art/cosmic_selftest_drop_src.png",
        "ed.assets: dropped bmp lands as art/*.png")
  local pix, w, h = pal.png_read(pal.read_file(root .. "/" .. rel) or "")
  check(w == 2 and h == 1 and pix and pix:byte(1) == 255 and pix:byte(2) == 0
        and pix:byte(4) == 255 and pix:byte(5) == 0 and pix:byte(6) == 255,
        "ed.assets: converted png round-trips the pixels")
  local rel2 = A.add_dropped(ed, src)
  check(rel2 == "art/cosmic_selftest_drop_src_2.png",
        "ed.assets: the collision suffix speaks the converted name")
  local drop_summoned = false
  ed.summon_console = function() drop_summoned = true end
  ed.g._drop_fail = { _fail = "rename" }
  local rel3 = A.add_dropped(ed, src)
  check(rel3 == nil and not pal.read_file(root .. "/art/cosmic_selftest_drop_src_3.png"),
        "ed.assets: interrupted converted drop publishes no partial asset")
  check(drop_summoned, "ed.assets: failed drop summons the console")
  ed.g._drop_fail = nil
  pal.write_file(root .. "/LICENSE", "fixture terms\n")
  pal.write_file(root .. "/CONTROLS.md", "fixture controls\n")
  A.invalidate(ed)
  local release_files = A.release_files(ed)
  local release_set = {}
  for _, path in ipairs(release_files) do release_set[path] = true end
  check(release_set.LICENSE and release_set["CONTROLS.md"]
        and release_set[rel],
        "ed.assets: release chooser includes PNG/text and extensionless legal files")
  pal.x_remove(root .. "/" .. rel)
  pal.x_remove(root .. "/" .. rel2)
  pal.x_remove(root .. "/LICENSE")
  pal.x_remove(root .. "/CONTROLS.md")
  pal.x_remove(src)

  -- a .spr's baked build products hide under their source (R8d round 2)
  local pruned = A.prune_baked({
    "art/girl.spr", "art/girl.png", "art/girl.anim", "art/girl.meta",
    "art/plank.png", "art/girl.lua", "sound/girl.ogg" })
  check(#pruned == 4 and pruned[1] == "art/girl.spr"
        and pruned[2] == "art/plank.png" and pruned[3] == "art/girl.lua"
        and pruned[4] == "sound/girl.ogg",
        "ed.assets: prune_baked hides the .spr bakes, keeps the rest")
end

local function t_ed_map()
  -- cm.ed.win.map — the pure select-tool core + the §7 snap (R8b).
  -- dims stub: every placement is 20x10.
  local W = cm.require("cm.ed.win.map")
  local map = cm.require("cm.map")
  local tmap = cm.require("cm.tmap")
  local palette = cm.require("cm.palette")
  local dims = function() return 20, 10 end
  local doc = {
    name = "t", w = 320, h = 200, grid = 8,
    colliders = {
      { kind = "chain", verts = { 0, 180, 320, 180 } },          -- ground
      { kind = "quad", x = 100, y = 140, w = 40, h = 40 },       -- block
    },
    places = {
      { path = "a.png", x = 30, y = 170, layer = 0 },
      { path = "b.png", x = 40, y = 175, layer = 0 },            -- topmost
      { path = "c.png", x = 200, y = 100, layer = 0 },
    },
    markers = {
      { x = 60, y = 160, w = 16, h = 16, kind = "spawn", label = "",
        note = "" },
    },
  }

  -- The real map-window save path retains unsaved working bytes and reports
  -- an atomic replacement failure through the editor console.
  local root = tmproot() .. "/cosmic_selftest_ed_map_save"
  pal.mkdir(root)
  local path = "atomic.map"
  local diskdoc = { name = "disk", w = 64, h = 64, grid = 8,
                    colliders = {}, places = {}, markers = {} }
  local diskbytes = map.encode(diskdoc)
  pal.write_file(root .. "/" .. path, diskbytes)
  local summoned = false
  local sed = { root = root, g = {}, doc = { assets = {} }, parked = false,
                touch = function() end,
                summon_console = function() summoned = true end }
  local swin = { path = path }
  local _, sp = W.open_win(swin, sed)
  sp.doc.name = "unsaved"
  sp._save_fail = { _fail = "rename" }
  W.save(swin, sed)
  check(pal.read_file(root .. "/" .. path) == diskbytes,
        "ed.map save: failure preserves previous map")
  check(W.dirty(swin, sed) and sp.doc.name == "unsaved",
        "ed.map save: failure retains dirty working bytes")
  check(summoned, "ed.map save: failure summons the console")
  sp._save_fail = nil

  -- Graybox-created tilemaps atomically replace their previous generation;
  -- editor/map state changes only after publication succeeds.
  local gbpath = "atomic_gb.tm"
  local gbbytes = tmap.encode(tmap.blank(1, 1, 16, "old.spr"))
  pal.write_file(root .. "/" .. gbpath, gbbytes)
  sp._create_fail = { _fail = "rename" }
  summoned = false
  check(not W.graybox_apply(swin, sed)
        and pal.read_file(root .. "/" .. gbpath) == gbbytes,
        "ed.map graybox: failure preserves previous tilemap")
  check(not sp.doc.nofill and #sp.doc.places == 0 and summoned,
        "ed.map graybox: failure leaves map unchanged and summons console")
  sp._create_fail = nil

  -- The real tilemap-window path has the same durability/error contract.
  local TW = cm.require("cm.ed.win.tmap")
  local tmpath = "atomic.tm"
  local tmdisk = tmap.blank(2, 2, 16, "disk.spr")
  local tmdiskbytes = tmap.encode(tmdisk)
  pal.write_file(root .. "/" .. tmpath, tmdiskbytes)
  local tmsummoned = false
  local tmed = { root = root, g = {}, doc = { assets = {} }, parked = false,
                 touch = function() end,
                 summon_console = function() tmsummoned = true end }
  local tmwin = { path = tmpath }
  local _, tmp = TW.open_win(tmwin, tmed)
  tmap.set(tmp.doc, 0, 0, 9)
  tmp._save_fail = { _fail = "rename" }
  TW.save(tmwin, tmed)
  check(pal.read_file(root .. "/" .. tmpath) == tmdiskbytes,
        "ed.tmap save: failure preserves previous tilemap")
  check(TW.dirty(tmwin, tmed) and tmap.get(tmp.doc, 0, 0) == 9,
        "ed.tmap save: failure retains dirty working bytes")
  check(tmsummoned, "ed.tmap save: failure summons the console")
  tmp._save_fail = nil
  TW.save(tmwin, tmed)
  check(not TW.dirty(tmwin, tmed)
        and tmap.get(tmap.decode(pal.read_file(root .. "/" .. tmpath)),
                     0, 0) == 9,
        "ed.tmap save: retry publishes complete source")

  -- The real palette-window path has the same durability/error contract.
  local PW = cm.require("cm.ed.win.palette")
  local ppath = "atomic.pal"
  local pdisk = palette.fresh("disk")
  local pdiskbytes = palette.encode(pdisk)
  pal.write_file(root .. "/" .. ppath, pdiskbytes)
  local psummoned = false
  local ped = { root = root, g = {}, doc = { assets = {} }, parked = false,
                touch = function() end,
                summon_console = function() psummoned = true end }
  local pwin = { path = ppath }
  local _, pp = PW.open_win(pwin, ped)
  pp.doc.name = "unsaved"
  pp.doc.colors[1] = 0x112233ff
  pp._save_fail = { _fail = "rename" }
  PW.save(pwin, ped)
  check(pal.read_file(root .. "/" .. ppath) == pdiskbytes,
        "ed.palette save: failure preserves previous palette")
  check(PW.dirty(pwin, ped) and pp.doc.name == "unsaved"
        and pp.doc.colors[1] == 0x112233ff,
        "ed.palette save: failure retains dirty working bytes")
  check(psummoned, "ed.palette save: failure summons the console")
  pp._save_fail = nil
  PW.save(pwin, ped)
  local psaved = palette.decode(pal.read_file(root .. "/" .. ppath))
  check(not PW.dirty(pwin, ped) and psaved.name == "unsaved"
        and psaved.colors[1] == 0x112233ff,
        "ed.palette save: retry publishes complete source")

  -- pick: topmost placement wins; markers overlay when shown
  local it = W.pick(doc, 45, 176, dims, false) -- inside a AND b -> b (z)
  check(it and it.t == "place" and it.i == 2, "ed.map: pick topmost place")
  it = W.pick(doc, 32, 171, dims, false) -- inside a only
  check(it and it.i == 1, "ed.map: pick the only hit")
  it = W.pick(doc, 65, 165, dims, true)
  check(it and it.t == "marker", "ed.map: markers pick when shown")
  check(W.pick(doc, 65, 165, dims, false) == nil,
        "ed.map: markers skip when hidden")
  check(W.pick(doc, 300, 20, dims, true) == nil, "ed.map: empty pick")

  -- hit_stack: the drill order (collider handles > markers > placements)
  local st = W.hit_stack(doc, 120, 140, dims, { thr = 4 })
  check(#st == 1 and st[1].t == "cedge" and st[1].c == 2,
        "ed.map: hit_stack a bare quad edge")
  st = W.hit_stack(doc, 100, 140, dims, { thr = 4 })
  check(st[1].t == "cvert" and st[1].c == 2 and st[1].v == 1,
        "ed.map: hit_stack vertex outranks edge")
  st = W.hit_stack(doc, 45, 181, dims, { thr = 4, with_markers = true })
  check(#st == 2 and st[1].t == "cedge" and st[1].c == 1
        and st[2].t == "place" and st[2].i == 2,
        "ed.map: hit_stack drills a collider edge -> the sprite beneath")
  -- drill_pick: repeated clicks at the ~same screen point step down + wrap
  local dk, dr = W.drill_pick(st, nil, 200, 100, 5)
  check(dk == 1, "ed.map: drill first click = top of stack")
  dk, dr = W.drill_pick(st, dr, 202, 101, 5)
  check(dk == 2, "ed.map: drill re-click steps down")
  dk, dr = W.drill_pick(st, dr, 202, 101, 5)
  check(dk == 1, "ed.map: drill wraps at the bottom")
  dk = W.drill_pick(st, dr, 260, 101, 5)
  check(dk == 1, "ed.map: drill resets when the point moves")
  check(W.drill_pick({}, nil, 0, 0, 5) == nil, "ed.map: drill empty stack nil")

  -- groups (D061): gid tags, membership, drill chain, ungroup, paste-regroup
  local gdoc = {
    name = "g", w = 100, h = 100, grid = 8, colliders = {},
    places = { { path = "a.png", x = 0, y = 0 }, { path = "b.png", x = 10, y = 0 },
               { path = "c.png", x = 50, y = 50 } },
    markers = { { x = 20, y = 20, w = 8, h = 8, kind = "spawn", label = "",
                  note = "" } },
  }
  local ggid = W.group_sel(gdoc, { { t = "place", i = 1 }, { t = "place", i = 2 },
                                   { t = "marker", i = 1 } })
  check(ggid == 1 and gdoc.places[1].gid == 1 and gdoc.places[2].gid == 1
        and gdoc.markers[1].gid == 1 and gdoc.places[3].gid == nil,
        "ed.map: group_sel tags the selection")
  check(W.group_sel(gdoc, { { t = "place", i = 3 } }) == nil,
        "ed.map: group_sel needs >= 2 items")
  check(#W.group_members(gdoc, 1) == 3, "ed.map: group_members finds all")
  check(W.next_gid(gdoc) == 2, "ed.map: next_gid past the max")
  check(W.item_gid(gdoc, { t = "place", i = 1 }) == 1
        and W.item_gid(gdoc, { t = "place", i = 3 }) == nil,
        "ed.map: item_gid reads the tag")
  local ch = W.drill_chain(gdoc, { { t = "place", i = 1 }, { t = "place", i = 3 } })
  check(#ch == 3 and ch[1].t == "group" and ch[1].gid == 1
        and ch[2].t == "place" and ch[2].i == 1
        and ch[3].t == "place" and ch[3].i == 3,
        "ed.map: drill_chain inserts the group level once, before its member")
  local gclip = W.copy_sel(gdoc, { { t = "place", i = 1 }, { t = "place", i = 2 } })
  local gns = W.paste(gdoc, gclip, 100, 100)
  check(gdoc.places[gns[1].i].gid and gdoc.places[gns[1].i].gid ~= 1
        and gdoc.places[gns[1].i].gid == gdoc.places[gns[2].i].gid,
        "ed.map: paste keeps a copied group grouped under a fresh gid")
  check(W.ungroup_sel(gdoc, { { t = "place", i = 1 } })
        and gdoc.places[1].gid == nil and gdoc.markers[1].gid == nil,
        "ed.map: ungroup clears the whole group")

  -- marquee
  local got = W.pick_rect(doc, 25, 165, 65, 190, dims, true)
  check(#got == 3, "ed.map: marquee places + marker")
  got = W.pick_rect(doc, 25, 165, 65, 190, dims, false)
  check(#got == 2, "ed.map: marquee respects marker toggle")

  -- nudge + z + del
  local sel = { { t = "place", i = 3 } }
  W.nudge(doc, sel, 5, -3)
  check(doc.places[3].x == 205 and doc.places[3].y == 97, "ed.map: nudge")
  sel = { { t = "place", i = 1 } }
  check(W.zmove(doc, sel, 1) == 2 and doc.places[2].path == "a.png",
        "ed.map: ] moves forward in file order")
  check(W.zmove(doc, sel, -1) == 1 and doc.places[1].path == "a.png",
        "ed.map: [ moves back")
  check(W.zmove(doc, sel, -1) == 1, "ed.map: z clamps at the ends")
  W.del(doc, { { t = "place", i = 2 }, { t = "marker", i = 1 } })
  check(#doc.places == 2 and #doc.markers == 0
        and doc.places[2].path == "c.png", "ed.map: del removes high-to-low")

  local function gapfill_tests()
  -- multi z-order (the gap-fill): the block moves one slot, order kept
  doc.places[3] = { path = "d.png", x = 0, y = 0, layer = 0 }
  sel = { { t = "place", i = 1 }, { t = "place", i = 2 } }
  check(W.zmove(doc, sel, 1) == true and doc.places[1].path == "d.png"
        and doc.places[2].path == "a.png" and doc.places[3].path == "c.png"
        and sel[1].i == 2 and sel[2].i == 3,
        "ed.map: multi z moves the block, order kept")
  check(W.zmove(doc, sel, 1) == nil, "ed.map: multi z clamps as a block")

  -- the clipboard (ctrl+c/v/d): deep copies, offsets, names drop
  doc.places[3].name = "boss"
  doc.markers[1] = { x = 10, y = 20, w = 8, h = 6, kind = "spawn",
                     label = "", note = "",
                     extras = { { k = "to", v = "rim" } } }
  local clip = W.copy_sel(doc, { { t = "place", i = 3 },
                                 { t = "marker", i = 1 } })
  doc.places[3].x = 999 -- the clip must not alias the doc
  doc.markers[1].extras[1].v = "mutated"
  local ns = W.paste(doc, clip, 5, 7)
  check(#ns == 2 and ns[1].t == "place" and ns[1].i == 4
        and ns[2].t == "marker" and ns[2].i == 2,
        "ed.map: paste returns the pasted set on top")
  check(doc.places[4].x == 205 + 5 and doc.places[4].y == 97 + 7
        and doc.places[4].name == nil,
        "ed.map: pasted place offsets, deep-copies, drops the name")
  check(doc.markers[2].x == 15 and doc.markers[2].extras[1].v == "rim",
        "ed.map: pasted marker deep-copies its extras")
  local bx, by, bw, bh = W.clip_bounds(clip, dims)
  check(bx == 10 and by == 20 and bx + bw == 225 and by + bh == 107,
        "ed.map: clip bounds span places + markers")
  check(W.copy_sel(doc, {}) == nil, "ed.map: an empty copy is nil")

  -- select-all + selection bounds (shift+2 fit rides these)
  local all = W.all_items(doc)
  check(#all == #doc.places + #doc.markers, "ed.map: all_items covers both")
  bx, by, bw, bh = W.sel_bounds(doc, all, dims)
  check(bx == 0 and bw > 0 and bh > 0, "ed.map: sel_bounds resolves")
  check(W.sel_bounds(doc, {}, dims) == nil, "ed.map: empty bounds are nil")

  -- free-collider bounds (shift+2 with the collider tool)
  local cbx, cby, cbw, cbh = W.col_bounds({ kind = "circle", cx = 300,
                                            cy = 50, r = 10 })
  check(cbx == 290 and cby == 40 and cbw == 20 and cbh == 20,
        "ed.map: circle bounds")
  cbx, cby, cbw, cbh = W.col_bounds({ kind = "chain",
                                      verts = { 0, 180, 100, 180, 200, 130 } })
  check(cbx == 0 and cby == 130 and cbw == 200 and cbh == 50,
        "ed.map: chain bounds")
  end -- gapfill_tests (runs after the snap block — it mutates the doc)

  -- snap (§7): vertex > edge/center > grid
  -- vertex: the quad's corner (100,140) catches a dragged corner
  local dx, dy, guides = W.snap_rect(doc, { x = 97, y = 138, w = 20, h = 10 },
                                     { dims = dims, thr = 6, grid = 8 })
  check(dx == 3 and dy == 2 and guides[1].t == "dot"
        and guides[1].x == 100 and guides[1].y == 140,
        "ed.map: vertex snap wins (" .. dx .. "," .. dy .. ")")
  -- edge: the ground line y=180 catches the rect bottom (no vertex near);
  -- x falls to the grid
  dx, dy, guides = W.snap_rect(doc, { x = 115, y = 173, w = 20, h = 10 },
                               { dims = dims, thr = 4, grid = 8 })
  check(dy == -3, "ed.map: edge snap y to the ground (" .. dy .. ")")
  check(115 + dx == 112, "ed.map: free axis falls to grid (" .. dx .. ")")
  local has_h = false
  for _, gl in ipairs(guides) do has_h = has_h or gl.t == "h" end
  check(has_h, "ed.map: edge snap draws its guide")
  -- placement corner as vertex target: c.png at (205,97) after the nudge
  dx, dy = W.snap_rect(doc, { x = 222, y = 99, w = 20, h = 10 },
                       { dims = dims, thr = 6, grid = 8 })
  check(dx == 3 and dy == -2, "ed.map: neighbor corner snap (butting)")
  -- the dragged placement itself is excluded via skip
  dx, dy = W.snap_rect(doc, { x = 222, y = 99, w = 20, h = 10 },
                       { dims = dims, thr = 6, grid = 8,
                         skip = function(n) return n == 2 end })
  check(not (dx == 3 and dy == -2), "ed.map: skip excludes the dragged")
  -- grid only (far from everything): origin rounds to the step
  dx, dy = W.snap_rect(doc, { x = 261, y = 61, w = 20, h = 10 },
                       { dims = dims, thr = 6, grid = 8,
                         skip = function() return true end })
  check(261 + dx == 264 and 61 + dy == 64, "ed.map: grid fallback")

  -- accepts/placeable split: .map rebinds, images place
  check(W.accepts(nil, "maps/x.map") ~= nil and not W.accepts(nil, "a.png"),
        "ed.map: accepts only .map")

  gapfill_tests() -- clipboard/z/bounds (mutates doc; snap is done with it)

  -- ---- the §7 point snap (R8c): snap_targets + snap_pt ----
  -- rebuild a clean doc (the ops above mutated it)
  doc = {
    name = "t", w = 320, h = 200, grid = 8,
    colliders = {
      { kind = "chain", verts = { 0, 180, 100, 180, 200, 130 } }, -- slope
      { kind = "quad", x = 240, y = 100, w = 30, h = 30 },
      { kind = "circle", cx = 300, cy = 50, r = 10 },             -- no targets
    },
    places = { { path = "a.png", x = 30, y = 100, layer = 0,
                 cols = { { kind = "chain", oneway = true,
                            verts = { 0, 0, 20, 0 } } } } },
    markers = {},
  }
  local tg = W.snap_targets(doc, { dims = dims })
  -- chain 3 + quad 4 + attached 2 + place corners 4 = 13 verts;
  -- chain 2 + quad 4 (closed) + attached 1 + place edges 4 = 11 segs
  check(#tg.verts == 13 and #tg.segs == 11,
        "ed.map: snap_targets counts (" .. #tg.verts .. "," .. #tg.segs .. ")")
  -- skipv drops the dragged vertex + its adjacent segments only
  tg = W.snap_targets(doc, { dims = dims, skipv = { o = 0, c = 1, v = 2 } })
  check(#tg.verts == 12 and #tg.segs == 9,
        "ed.map: skipv drops vertex + adjacent segs")
  -- skipv with v=nil drops the whole collider (edge-drag moves all of it)
  tg = W.snap_targets(doc, { dims = dims, skipv = { o = 0, c = 2 } })
  check(#tg.verts == 9 and #tg.segs == 7, "ed.map: skipv whole collider")
  -- attached colliders ride their placement offset
  tg = W.snap_targets(doc, { dims = dims })
  local found = false
  for _, v in ipairs(tg.verts) do
    found = found or (v[1] == 50 and v[2] == 100) -- 30+20, 100+0
  end
  check(found, "ed.map: attached verts at world coords")

  -- vert snap wins
  local sx, sy, guides, how = W.snap_pt(tg, 98, 178, { thr = 6 })
  check(sx == 100 and sy == 180 and how == "vert" and guides[1].t == "dot",
        "ed.map: snap_pt vertex wins")
  -- edge snap: nearest point ON the slope segment (100,180)-(200,130)
  sx, sy, guides, how = W.snap_pt(tg, 150, 153, { thr = 6 })
  check(how == "edge", "ed.map: snap_pt edge on a slope (" .. tostring(how) .. ")")
  check(sx == 151 and sy == 155, -- the projection, rounded
        "ed.map: snap_pt edge projects (" .. sx .. "," .. sy .. ")")
  check(guides[1].t == "seg" and guides[2].t == "dot",
        "ed.map: edge snap draws the segment guide")
  -- the 45 lock (anchor set, nothing stronger near): horizontal sector
  sx, sy, guides, how = W.snap_pt(tg, 60, 13, { thr = 6, ax = 20, ay = 10 })
  check(sx == 60 and sy == 10 and how == "45", "ed.map: 45 lock horizontal")
  -- vertical sector
  sx, sy = W.snap_pt(tg, 22, 60, { thr = 6, ax = 20, ay = 10 })
  check(sx == 20 and sy == 60, "ed.map: 45 lock vertical")
  -- diagonal: dx=30 dy=34 -> t=32 both axes
  sx, sy, guides, how = W.snap_pt(tg, 50, 44, { thr = 6, ax = 20, ay = 10 })
  check(sx == 52 and sy == 42 and how == "45" and guides[1].t == "ray",
        "ed.map: 45 lock diagonal (" .. sx .. "," .. sy .. ")")
  -- the anchor itself is never a vertex target (no zero-length segments):
  -- anchor ON the chain vertex (100,180), cursor right next to it
  sx, sy, guides, how = W.snap_pt(tg, 103, 179, { thr = 6, ax = 100, ay = 180 })
  check(how ~= "vert" or sx ~= 100 or sy ~= 180,
        "ed.map: anchor excluded from vertex targets")
  -- grid fallback (no anchor, far from everything)
  sx, sy, guides, how = W.snap_pt({ verts = {}, segs = {} }, 61, 27,
                                  { thr = 6, grid = 8 })
  check(sx == 64 and sy == 24 and how == "grid", "ed.map: snap_pt grid")
end

local function t_ed_map_tmsnap()
  local W = cm.require("cm.ed.win.map")
  -- ---- placed .tm tile edges join the targets (§7-R8d) ----
  local tmap = cm.require("cm.tmap")
  local tmd = tmap.blank(4, 2, 16, "") -- 64x32 px grid
  local tmdoc = {
    w = 480, h = 270, grid = 8,
    colliders = {},
    places = { { path = "deco/a.tm", x = 100, y = 200, layer = 0 } },
    markers = {},
  }
  local tdims = function() return 64, 32 end
  local tmfn = function(path)
    return path == "deco/a.tm" and tmd or nil
  end
  local tg = W.snap_targets(tmdoc, { dims = tdims, tm = tmfn })
  -- place bounds 4 segs + interior tile lines: 3 vertical + 1 horizontal
  check(#tg.segs == 8, "ed.map: tm tile-edge segs (" .. #tg.segs .. ")")
  -- a point near the interior line x = 100+32 snaps onto it
  local sx, sy, guides, how = W.snap_pt(tg, 130, 210, { thr = 6 })
  check(sx == 132 and sy == 210 and how == "edge",
        "ed.map: snap_pt clicks onto a tile boundary ("
        .. sx .. "," .. sy .. "," .. tostring(how) .. ")")
  -- without opts.tm the grid contributes nothing (R8b callers unchanged)
  tg = W.snap_targets(tmdoc, { dims = tdims })
  check(#tg.segs == 4, "ed.map: no tm fn, no tile segs")
end

local function t_ed_maptool()
  -- the R8c pure collider-op core (cm.ed.win.map): pick / insert / drag /
  -- offset / nudge / del semantics
  local W = cm.require("cm.ed.win.map")
  local cols = {
    { kind = "chain", verts = { 0, 100, 50, 100, 120, 60 } },
    { kind = "quad", x = 200, y = 50, w = 40, h = 30 },
    { kind = "circle", cx = 300, cy = 150, r = 20 },
  }
  local hit = W.col_pick(cols, 51, 102, 4)
  check(hit and hit.c == 1 and hit.v == 2 and hit.x == 50 and hit.y == 100,
        "ed.maptool: vertex pick outranks its edge")
  hit = W.col_pick(cols, 25, 103, 4)
  check(hit and hit.c == 1 and hit.e == 1 and hit.x == 25 and hit.y == 100,
        "ed.maptool: edge pick carries the projection point")
  hit = W.col_pick(cols, 239, 79, 4)
  check(hit and hit.c == 2 and hit.v == 3, "ed.maptool: quad corner (br)")
  hit = W.col_pick(cols, 220, 51, 4)
  check(hit and hit.c == 2 and hit.e == 1, "ed.maptool: quad top edge")
  hit = W.col_pick(cols, 321, 150, 4)
  check(hit and hit.c == 3 and hit.v == 1, "ed.maptool: circle ring handle")
  hit = W.col_pick(cols, 305, 150, 4)
  check(hit and hit.c == 3 and hit.e == 1, "ed.maptool: circle interior")
  check(W.col_pick(cols, 400, 400, 4) == nil, "ed.maptool: empty pick")

  local nv = W.col_insert(cols[1], 2, 80, 80)
  check(nv == 3 and #cols[1].verts == 8 and cols[1].verts[5] == 80
        and cols[1].verts[6] == 80, "ed.maptool: edge insert")

  local q = { kind = "quad", x = 200, y = 50, w = 40, h = 30 }
  W.quad_drag(q, { x = 200, y = 50, w = 40, h = 30 }, 1, 190, 40)
  check(q.x == 190 and q.y == 40 and q.w == 50 and q.h == 40,
        "ed.maptool: quad corner drag anchors opposite")
  W.quad_drag(q, { x = 190, y = 40, w = 50, h = 40 }, 1, 250, 90)
  check(q.x == 240 and q.y == 80 and q.w == 10 and q.h == 10,
        "ed.maptool: quad drag normalizes on cross-over")

  W.col_offset(cols[1], { verts = { 0, 100, 50, 100, 80, 80, 120, 60 } },
               5, -10)
  check(cols[1].verts[1] == 5 and cols[1].verts[2] == 90
        and cols[1].verts[7] == 125 and cols[1].verts[8] == 50,
        "ed.maptool: whole-chain offset")
  W.col_offset(cols[3], { cx = 300, cy = 150 }, -10, 10)
  check(cols[3].cx == 290 and cols[3].cy == 160, "ed.maptool: circle offset")

  W.col_nudge(cols, { c = 1, v = 2 }, 1, 2)
  check(cols[1].verts[3] == 56 and cols[1].verts[4] == 92,
        "ed.maptool: vertex nudge")
  W.col_nudge(cols, { c = 2 }, -5, 5)
  check(cols[2].x == 195 and cols[2].y == 55, "ed.maptool: whole quad nudge")

  check(W.col_del(cols, { c = 1, v = 3 }) == "vert" and #cols[1].verts == 6,
        "ed.maptool: del removes the vertex")
  check(W.col_del(cols, { c = 1, v = 2 }) == "vert" and #cols[1].verts == 4,
        "ed.maptool: del to the 2-vert floor")
  check(W.col_del(cols, { c = 1, v = 1 }) == "col" and #cols == 2,
        "ed.maptool: del below the floor removes the chain")
  check(W.col_del(cols, { c = 2 }) == "col" and #cols == 1
        and cols[1].kind == "quad", "ed.maptool: del whole collider")

  -- +col auto-fit (relative coords; §6/D057a)
  local af = W.col_autofit("owline", 48, 16)
  check(af.kind == "chain" and af.oneway and af.verts[1] == 0
        and af.verts[2] == 0 and af.verts[3] == 48 and af.verts[4] == 0,
        "ed.maptool: owline auto-fit spans the sprite top")
  af = W.col_autofit("line", 48, 16)
  check(af.kind == "chain" and not af.oneway, "ed.maptool: solid line fit")
  af = W.col_autofit("quad", 48, 16)
  check(af.kind == "quad" and af.x == 0 and af.y == 0 and af.w == 48
        and af.h == 16, "ed.maptool: quad fits the bounds")
  af = W.col_autofit("circle", 48, 16)
  check(af.kind == "circle" and af.cx == 24 and af.cy == 8 and af.r == 8,
        "ed.maptool: circle inscribes")

  -- attached picks ride the placement offset (world coords in, rel out)
  local acols = { { kind = "chain", oneway = true, verts = { 0, 0, 20, 0 } } }
  hit = W.col_pick(acols, 41, 102, 4, 30, 100)
  check(hit and hit.e == 1 and hit.x == 41 and hit.y == 100,
        "ed.maptool: attached edge pick at world coords")
  hit = W.col_pick(acols, 31, 99, 4, 30, 100)
  check(hit and hit.v == 1, "ed.maptool: attached vertex pick")

  -- marker extras <-> the one-line k=v form
  local ex = W.extras_parse("door=rim_hub  dir=left junk noeq")
  check(ex and #ex == 2 and ex[1].k == "door" and ex[1].v == "rim_hub"
        and ex[2].k == "dir" and ex[2].v == "left",
        "ed.maptool: extras_parse keeps k=v, drops junk")
  check(W.extras_fmt(ex) == "door=rim_hub dir=left",
        "ed.maptool: extras_fmt round-trips")
  check(W.extras_parse("") == nil and W.extras_fmt(nil) == "",
        "ed.maptool: empty extras stay nil")

  -- the map bg tint <-> "r g b" one-line form (the map fields, R8e)
  local bg = W.bg_parse(" 1.04 0.92 0.78 ")
  check(bg and bg[1] == 1.04 and bg[2] == 0.92 and bg[3] == 0.78,
        "ed.maptool: bg_parse reads three floats")
  check(W.bg_fmt(bg) == "1.04 0.92 0.78",
        "ed.maptool: bg_fmt round-trips")
  check(W.bg_parse("1 1") == nil and W.bg_parse("a b c") == nil,
        "ed.maptool: bg_parse rejects junk")
  check(W.bg_fmt(nil) == "1 1 1", "ed.maptool: bg_fmt defaults white")
end

local function t_ed_synth()
  -- the R9c synth ADSR log time axis (human ask): equal pixels = equal
  -- RATIOS, so short-end feels (pluck/soft/pad) spread across the whole
  -- axis; fx=0 pins to 0 (instant); and the DRAW (ms->fx) and DRAG
  -- (fx->ms) are exact inverses so a handle never jumps on grab.
  local W = cm.require("cm.ed.win.synth")
  local ins = cm.require("cm.ins")

  -- The real synth-window save path preserves the last valid source and the
  -- newer working instrument when atomic publication fails.
  local root = tmproot() .. "/cosmic_selftest_ed_ins_save"
  pal.mkdir(root)
  local path = "atomic.ins"
  local diskbytes = ins.encode(ins.fresh("disk"))
  pal.write_file(root .. "/" .. path, diskbytes)
  local summoned = false
  local ed = { root = root, g = {}, doc = { assets = {} }, parked = false,
               touch = function() end,
               summon_console = function() summoned = true end }
  local win = { path = path }
  local _, p = W.open_win(win, ed)
  p.doc.name = "unsaved"
  p.doc.patch.gain = 207
  p._save_fail = { _fail = "rename" }
  W.save(win, ed)
  check(pal.read_file(root .. "/" .. path) == diskbytes,
        "ed.synth save: failure preserves previous instrument")
  check(W.dirty(win, ed) and p.doc.name == "unsaved"
        and p.doc.patch.gain == 207,
        "ed.synth save: failure retains dirty working bytes")
  check(summoned, "ed.synth save: failure summons the console")
  p._save_fail = nil
  W.save(win, ed)
  local published = ins.decode(pal.read_file(root .. "/" .. path))
  check(not W.dirty(win, ed) and published.name == "unsaved"
        and published.patch.gain == 207,
        "ed.synth save: retry publishes complete source")

  -- Project-local copies of stock instruments are atomic too.
  local MW = cm.require("cm.ed.win.music")
  local preset = root .. "/external.ins"
  pal.write_file(preset, ins.encode(ins.fresh("preset")))
  local import_summoned = false
  local ied = { root = root, g = { _ins_import_fail = { _fail = "rename" } },
                summon_console = function() import_summoned = true end }
  check(MW.resolve_ins(ied, preset) == nil
        and not pal.read_file(root .. "/ins/external.ins"),
        "ed.music import: interrupted preset copy publishes no partial asset")
  check(import_summoned, "ed.music import: failure summons the console")

  -- Sound-to-sampler creation preserves an existing valid instrument.
  local SW = cm.require("cm.ed.win.sound")
  pal.mkdir(root .. "/ins")
  local sample_path = root .. "/ins/found.ins"
  local sample_old = ins.encode(ins.fresh("old"))
  pal.write_file(sample_path, sample_old)
  local sound_summoned = false
  local sed = { root = root, parked = false,
                g = { sndw = { [7] = {
                  pcm = string.pack("<i2i2", 100, -100),
                  _create_fail = { _fail = "rename" },
                } } },
                summon_console = function() sound_summoned = true end,
                touch = function() end }
  SW.to_ins({ id = 7, path = "sound/found.wav" }, sed)
  check(pal.read_file(sample_path) == sample_old,
        "ed.sound instrument: failure preserves previous instrument")
  check(sound_summoned, "ed.sound instrument: failure summons the console")

  check(W.env_fx_to_ms(0, 2000) == 0, "ed.synth: fx 0 = 0 ms (instant)")
  check(W.env_fx_to_ms(1, 2000) == 2000, "ed.synth: fx 1 = max ms")
  -- log front-loading: the axis midpoint is FAR below the linear 1000 ms
  check(W.env_fx_to_ms(0.5, 2000) < 100,
        "ed.synth: fx 0.5 -> " .. W.env_fx_to_ms(0.5, 2000) .. " ms (log spread)")
  local mono, last = true, -1
  for k = 0, 40 do
    local v = W.env_fx_to_ms(k / 40, 2000)
    if v < last then mono = false end
    last = v
  end
  check(mono, "ed.synth: time axis is monotonic")
  local rt_ok = true
  for _, ms in ipairs({ 5, 30, 200, 1000 }) do
    local rt = W.env_fx_to_ms(W.env_ms_to_fx(ms, 2000), 2000)
    if math.abs(rt - ms) > math.max(1, ms * 0.02) then rt_ok = false end
  end
  check(rt_ok, "ed.synth: ms->fx->ms round-trips (draw==drag)")
end

local function t_ed_filter()
  -- cm.ed.filter_events — the playable-game-window input gate (R4b,
  -- EDITOR.md §12.3). Synthetic events against a faked shell state.
  local ed = cm.require("cm.ed")
  local wm = cm.require("cm.ed.wm")
  local was_on, was_doc, was_root, was_g = ed.on, ed.doc, ed.root, ed.g

  ed.on = false
  local passthru = { { type = "key", scancode = 4, down = true } }
  check(ed.filter_events(passthru) == passthru,
        "ed.filter: shell off = events untouched")

  ed.g = {}
  ed.doc = wm.init({ v = 1 })
  ed.on = true
  local gw = wm.spawn(ed.doc, "game", 0, 0, 480, 300)

  ed.doc.focus = 0 -- unfocused: swallowed, but releases pass (no stuck keys)
  local ev = ed.filter_events({
    { type = "key", scancode = 4, down = true },
    { type = "key", scancode = 4, down = false },
    { type = "motion", wx = 100, wy = 100, x = 0, y = 0 },
    { type = "wheel", dy = 1 },
  })
  check(#ev == 1 and ev[1].type == "key" and ev[1].down == false,
        "ed.filter: unfocused swallows all but releases")

  ed.doc.focus = gw.id -- focused = playing
  ed.g.grect = { [gw.id] = { x = 10, y = 20, s = 2, w = 960, h = 540 } }
  ev = ed.filter_events({
    { type = "key", scancode = 4, down = true },
    { type = "key", scancode = 41, down = true }, -- Esc: the shell's
    { type = "key", scancode = 53, down = true }, -- grave: the shell's
    { type = "button", button = 1, down = true, wx = 110, wy = 120 },
    { type = "motion", wx = 9, wy = 19 }, -- outside the image rect
    { type = "quit" },
  })
  check(#ev == 3 and ev[1].scancode == 4 and ev[2].type == "button"
        and ev[3].type == "quit",
        "ed.filter: playing passes keys/buttons, steals esc+grave, gates rect")
  check(ev[2].x == 50 and ev[2].y == 50, "ed.filter: wx,wy -> FOV remap")

  local ui = cm.require("cm.ui")
  local ux, uy = ui.inp.wx, ui.inp.wy
  ui.inp.wx, ui.inp.wy = 200, 200 -- cursor over the image rect
  ev = ed.filter_events({ { type = "wheel", dy = -1 } })
  check(#ev == 1 and ed.g.wheel_taken, "ed.filter: wheel over playing = sim's")
  ui.inp.wx, ui.inp.wy = ux, uy

  ed.g.alt = true -- the ALT layer suspends play input (releases still pass)
  ev = ed.filter_events({
    { type = "key", scancode = 4, down = true },
    { type = "button", button = 1, down = false, wx = 110, wy = 120 },
  })
  check(#ev == 1 and ev[1].type == "button",
        "ed.filter: ALT suspends downs, releases pass")
  ed.g.alt = false

  -- the R8b wants_keys/game_input split: a focused MAP window claims the
  -- shell's plain keys for its tool but must never feed the sim
  local mw = wm.spawn(ed.doc, "map", 600, 0, 400, 300)
  ed.doc.focus = mw.id
  ev = ed.filter_events({
    { type = "key", scancode = 79, down = true }, -- an arrow nudge
    { type = "key", scancode = 79, down = false },
  })
  check(#ev == 1 and ev[1].down == false,
        "ed.filter: focused map window never feeds the game")

  ed.on, ed.doc, ed.root, ed.g = was_on, was_doc, was_root, was_g
end

local function t_ed_viewlock()
  -- the focus view lock (MAPS.md §6, the human's ask): a focused map
  -- window owns wheel + middle-drag from anywhere on the canvas; unbound
  -- windows and other kinds never lock; a wheel arriving from outside
  -- the view rect anchors its zoom at the view center.
  local ed = cm.require("cm.ed")
  local wm = cm.require("cm.ed.wm")
  local was_doc, was_g, was_rev = ed.doc, ed.g, ed.doc_rev
  ed.g = {}
  ed.doc = wm.init({ v = 1 })
  local mw = wm.spawn(ed.doc, "map", 0, 0, 400, 300, { path = "" })
  ed.doc.focus = mw.id
  check(ed.view_locked() == nil, "ed.viewlock: unbound map never locks")
  mw.path = "maps/t.map"
  check(ed.view_locked() == mw, "ed.viewlock: focused bound map locks")
  local gw = wm.spawn(ed.doc, "game", 500, 0, 480, 300)
  ed.doc.focus = gw.id
  check(ed.view_locked() == nil, "ed.viewlock: game window never locks")
  ed.doc.focus = 0
  check(ed.view_locked() == nil, "ed.viewlock: no focus, no lock")

  ed.doc.focus = mw.id
  ed.g.mw = { ["maps/t.map"] = { doc = { w = 320, h = 200 },
    view = { cx = 100, cy = 100, w = 200, h = 150,
             ox = 100, oy = 100, zoom = 1, fit = 1, wz = 1 } } }
  local ui = cm.require("cm.ui")
  local W = cm.require("cm.ed.win.map")
  local ux, uy = ui.inp.wx, ui.inp.wy
  ui.inp.wx, ui.inp.wy = 900, 900 -- far off the view rect
  check(W.wheel(mw, ed, 1) == true, "ed.viewlock: wheel lands on the view")
  ui.inp.wx, ui.inp.wy = ux, uy
  -- anchor = the view center (200,175): the map point under it stays put
  check(mw.zoom == 1.25 and mw.px == -25 and mw.py == -18.75,
        "ed.viewlock: off-view wheel anchors at the view center")

  -- focus is the ONE gate (the human's Esc report): an unfocused map
  -- window's view is inert — hover wheel/ctrl+wheel/MMB all decline
  ed.doc.focus = 0
  check(W.wheel(mw, ed, 1) == false,
        "ed.viewlock: unfocused wheel declines (canvas zooms)")
  check(W.ctrl_wheel(mw, ed, 1) == false,
        "ed.viewlock: unfocused grid dial declines")
  check(not W.takes_middle(mw, ed),
        "ed.viewlock: unfocused MMB goes to the canvas")
  ed.doc.focus = mw.id
  check(W.takes_middle(mw, ed) == true,
        "ed.viewlock: focused MMB stays the map's")

  -- the sprite + tilemap windows adopt the same contract (the human's
  -- ask, 2026-07-13): edit mode locks only WHILE FOCUSED; view mode
  -- and unfocused views are inert (the canvas pans/zooms)
  local SP = cm.require("cm.ed.win.sprite")
  local sw = wm.spawn(ed.doc, "sprite", 0, 400, 300, 200,
                      { path = "art/g.spr", edit = true })
  check(SP.own_view(sw) == true, "ed.viewlock: edit sprite locks")
  sw.edit = false
  check(not SP.own_view(sw), "ed.viewlock: view-mode sprite never locks")
  sw.edit = true
  check(not SP.own_view({ path = "", edit = true }),
        "ed.viewlock: unbound sprite never locks")
  ed.doc.focus = 0
  check(SP.wheel(sw, ed, 1) == false,
        "ed.viewlock: unfocused sprite wheel declines")
  check(not SP.takes_middle(sw, ed),
        "ed.viewlock: unfocused sprite MMB goes to the canvas")
  ed.doc.focus = sw.id
  check(SP.takes_middle(sw, ed) == true,
        "ed.viewlock: focused sprite MMB stays")
  local TM = cm.require("cm.ed.win.tmap")
  local tw = wm.spawn(ed.doc, "tmap", 0, 700, 300, 200,
                      { path = "deco.tm", edit = true })
  check(TM.own_view(tw) == true, "ed.viewlock: edit tmap locks")
  ed.doc.focus = 0
  check(TM.wheel(tw, ed, 1) == false
        and not TM.takes_middle(tw, ed),
        "ed.viewlock: unfocused tmap view is inert")
  ed.doc.focus = tw.id
  check(TM.takes_middle(tw, ed) == true,
        "ed.viewlock: focused tmap MMB stays")

  ed.doc, ed.g, ed.doc_rev = was_doc, was_g, was_rev
end

local function t_ed_hot()
  -- the ONE pointer gate (overlap hygiene): at most one window per frame
  -- may react to the pointer — the topmost banded content hit, and only
  -- while no shell layer/gesture owns the mouse. Kinds gate every hover/
  -- click affordance on ctx.hot, so a title-bar drag over an overlapped
  -- window can never also press the lower window's chips/tools.
  local ed = cm.require("cm.ed")
  local wm = cm.require("cm.ed.wm")
  local ui = cm.require("cm.ui")
  local was_doc, was_g = ed.doc, ed.g
  local ux, uy = ui.inp.wx, ui.inp.wy
  ed.g = {}
  ed.doc = wm.init({ cam = { x = 0, y = 0, zoom = 1 } })
  local a = wm.spawn(ed.doc, "note", 0, 0, 200, 100)
  local b = wm.spawn(ed.doc, "note", 150, 50, 200, 100) -- topmost, overlaps
  local function at(x, y)
    ui.inp.wx, ui.inp.wy = x, y
    ed.g.cursor = { wx = x, wy = y } -- zoom 1, cam 0: world == screen
    return ed.hot_id()
  end
  check(at(160, 60) == b.id, "ed.hot: overlap goes to the topmost only")
  check(at(10, 10) == a.id, "ed.hot: the lower window is hot when alone")
  check(at(152, 60) == nil, "ed.hot: the resize band is never hot")
  check(at(900, 900) == nil, "ed.hot: empty canvas is nobody's")
  -- any shell layer/gesture owning the mouse blanks the gate
  for _, k in ipairs({ "alt", "space", "selmode", "pan", "adrag",
                       "menu", "rpend" }) do
    ed.g[k] = true
    check(at(160, 60) == nil, "ed.hot: " .. k .. " blanks the gate")
    ed.g[k] = nil
  end
  ed.g.state = "alt_move" -- a wm gesture in flight (the title-bar drag)
  check(at(160, 60) == nil, "ed.hot: a wm gesture blanks the gate")
  ed.g.state = nil
  ed.g.rw = { rect = { x = 150, y = 50, w = 100, h = 40 } }
  check(at(160, 60) == nil, "ed.hot: the rewind tray owns its rect")
  ed.g.rw = nil
  ed.doc, ed.g = was_doc, was_g
  ui.inp.wx, ui.inp.wy = ux, uy
end

local function t_ed_rewind()
  -- A7 tray camera: ten minutes ending at live, zoom anchored under the
  -- cursor, hand-style middle pan, and frame mapping at both edges.
  local rw = cm.require("cm.ed.rewind")
  local v = rw.default_view(0, 72000)
  check(v.start == 36000 and v.span == 36000 and v.follow,
        "rewind tray: default is ten minutes ending live")
  local short = rw.default_view(100, 400)
  check(short.start == 100 and short.span == 300,
        "rewind tray: short history fits in full")

  local anchor = v.start + v.span * 0.25
  rw.zoom_view(v, 0.25, 2, 0, 72000)
  check(math.abs((v.start + v.span * 0.25) - anchor) < 1e-9
        and v.span < 36000 and not v.follow,
        "rewind tray: wheel zoom keeps cursor frame fixed")
  local p = { start = 30000, span = 10000, follow = false }
  rw.pan_view(p, 100, 1000, 0, 72000)
  check(p.start == 29000 and not p.follow,
        "rewind tray: middle pan moves the time camera")
  check(rw.frame_at(p, 10, 10, 1000, 0, 72000) == 29000
        and rw.frame_at(p, 1010, 10, 1000, 0, 72000) == 39000,
        "rewind tray: axis endpoints map to exact frames")

  local tiny = { start = 0, span = 100, follow = false }
  rw.zoom_view(tiny, 0.5, 100, 0, 100)
  check(tiny.span == rw.MIN_SPAN,
        "rewind tray: near zoom clamps at frame-readable span")
end

local function t_ed_pick()
  -- the global eyedropper: arming gates + the hot filter + a REAL pick
  -- through the capture target (headless capture = the present path, so
  -- pick_screen samples exactly what a live mirror would hold)
  local ed = cm.require("cm.ed")
  local wm = cm.require("cm.ed.wm")
  local ui = cm.require("cm.ui")
  local paint = cm.require("cm.paint")
  local was_doc, was_g = ed.doc, ed.g
  local ux, uy = ui.inp.wx, ui.inp.wy
  ed.g = {}
  ed.doc = wm.init({ cam = { x = 0, y = 0, zoom = 1 } })
  local sw = wm.spawn(ed.doc, "sprite", 0, 0, 200, 150,
                      { path = "art/x.spr", edit = true, tool = "pick" })
  local nw = wm.spawn(ed.doc, "note", 300, 0, 150, 100)
  ed.doc.focus = sw.id
  check(ed.pick_armed() == sw, "ed.pick: focused edit+pick sprite arms")
  sw.tool = "pen"
  check(ed.pick_armed() == nil, "ed.pick: the pen disarms")
  sw.tool = "pick"
  sw.edit = nil
  check(ed.pick_armed() == nil, "ed.pick: view mode never arms")
  sw.edit = true
  ed.doc.focus = nw.id
  check(ed.pick_armed() == nil, "ed.pick: focus elsewhere disarms")
  ed.doc.focus = sw.id

  local function at(x, y)
    ui.inp.wx, ui.inp.wy = x, y
    ed.g.cursor = { wx = x, wy = y }
    return ed.hot_id()
  end
  check(at(320, 50) == nil, "ed.pick: other windows go cold while armed")
  check(at(50, 50) == sw.id, "ed.pick: the armed window stays hot")
  sw.tool = "pen"
  check(at(320, 50) == nw.id, "ed.pick: disarming re-heats the others")
  sw.tool = "pick"

  pal.x_capture(64, 64)
  pal.x_compose({ x = 0, y = 0, scale = 1 })
  pal.begin_frame(0, 0, 0, 1)
  pal.quad(10, 10, 20, 20, 1, 0.5, 0, 1) -- an orange patch at 10..30
  pal.present()
  local r, g, b = paint.unpack(ed.pick_screen(15, 15))
  check(r == 255 and g > 100 and g < 150 and b == 0,
        "ed.pick: pick_screen samples the presented composite")
  check(ed.pick_screen(9999, -5) ~= nil, "ed.pick: off-screen clamps")
  pal.x_capture(0, 0)
  pal.x_compose()

  ed.doc, ed.g = was_doc, was_g
  ui.inp.wx, ui.inp.wy = ux, uy
end

local function t_ed_winview()
  -- cm.ed.winview — THE INVARIANT: captured view fields live in WORLD
  -- units, so canvas zoom cancels out (the generalized fix for the
  -- assets/map/sprite screen-px drift family).
  local wv = cm.require("cm.ed.winview")
  local win = { zoom = 2, px = 8, py = 6 }
  local function world_of(z) -- world coords of content point (30,20)
    local v = wv.view(win, z, 100 * z, 50 * z, 400 * z, 300 * z, 64, 64)
    return (v.ox + 30 * v.zoom) / z, (v.oy + 20 * v.zoom) / z
  end
  local x1, y1 = world_of(1)
  local x2, y2 = world_of(2)
  local x3, y3 = world_of(0.5)
  check(x1 == x2 and y1 == y2 and x1 == x3 and y1 == y3,
        "winview: content glued to the frame at any canvas zoom")
  check(x1 == 100 + 8 + 60 and y1 == 50 + 6 + 40, "winview: transform math")

  -- wheel anchor: the content point under the cursor stays put at z=2
  -- (the sprite ed's old math drifted exactly here)
  local v = wv.view(win, 2, 200, 100, 800, 600, 64, 64)
  local ax, ay = v.ox + 30 * v.zoom, v.oy + 20 * v.zoom
  wv.wheel_zoom(win, v, ax, ay, 1, 0.05, 32)
  check(win.zoom == 2.5, "winview: wheel steps the world scale")
  local v2 = wv.view(win, 2, 200, 100, 800, 600, 64, 64)
  check(math.abs(v2.ox + 30 * v2.zoom - ax) < 1e-9
        and math.abs(v2.oy + 20 * v2.zoom - ay) < 1e-9,
        "winview: zoom anchors at the cursor under canvas zoom")

  -- pan applies a screen delta; world storage
  wv.pan(win, v2, v2.ox, v2.oy, 10, -6)
  local v3 = wv.view(win, 2, 200, 100, 800, 600, 64, 64)
  check(math.abs(v3.ox - (v2.ox + 10)) < 1e-9
        and math.abs(v3.oy - (v2.oy - 6)) < 1e-9,
        "winview: screen-delta pan")

  wv.reset(win)
  local vf = wv.view(win, 2, 0, 0, 812, 612, 64, 64, 3)
  check(win.zoom == nil and math.abs(vf.fit - 9.375) < 1e-9,
        "winview: reset returns to fit")

  -- scroll: the visible top row is canvas-zoom invariant
  local aw = {}
  wv.scroll_by(aw, "sy", 1, 120) -- 120 screen px at z=1
  check(aw.sy == 120, "winview: scroll stores world units")
  check(wv.scroll_px(aw, "sy", 1) / (40 * 1) == 3
        and wv.scroll_px(aw, "sy", 2) / (40 * 2) == 3,
        "winview: top row stable under canvas zoom")
  wv.scroll_by(aw, "sy", 2, -1000)
  check(aw.sy == nil, "winview: scroll clamps at 0 (and re-nils)")
end

local function t_ed_orbit()
  -- cm.ed.orbit (E0, D137) — the 3D viewport view helper: captured
  -- fields in world units, pure basis/ray/project math the editor
  -- windows' gizmos and picking stand on.
  local ob = cm.require("cm.ed.orbit")
  local mm = cm.require("cm.math")
  local win = ob.defaults(40, 10, 0, -6)
  check(win.odist == 40 and win.ofx == 10 and win.ofz == -6,
        "orbit: defaults carry dist + focus")

  -- basis: unit fwd, orthogonal frame, world-up-ish up while pitched down
  local fx, fy, fz, rx, ry, rz, ux, uy, uz = ob.basis(win)
  local function dot(ax, ay, az, bx, by, bz) return ax*bx + ay*by + az*bz end
  check(math.abs(dot(fx,fy,fz, fx,fy,fz) - 1) < 1e-12, "orbit: |fwd| = 1")
  check(math.abs(dot(fx,fy,fz, rx,ry,rz)) < 1e-12
        and math.abs(dot(fx,fy,fz, ux,uy,uz)) < 1e-12
        and math.abs(dot(rx,ry,rz, ux,uy,uz)) < 1e-12,
        "orbit: orthogonal basis")
  check(uy > 0 and ry == 0, "orbit: up is up, right stays level")

  -- eye sits odist behind the focus along fwd
  local ex, ey, ez = ob.eye(win)
  local dl = mm.sqrt((win.ofx-ex)^2 + (win.ofy-ey)^2 + (win.ofz-ez)^2)
  check(math.abs(dl - win.odist) < 1e-9, "orbit: eye at dist from focus")

  -- the focus projects to the viewport center; behind-camera returns nil
  local vpm = ob.vp(win, 320/240)
  local px, py = ob.project(vpm, 320, 240, win.ofx, win.ofy, win.ofz)
  check(math.abs(px - 160) < 1e-6 and math.abs(py - 120) < 1e-6,
        "orbit: focus projects to center")
  check(ob.project(vpm, 320, 240, ex - fx, ey - fy, ez - fz) == nil,
        "orbit: behind-camera projects nil")

  -- ray through the center is fwd; project->ray round-trips a world point
  local r0 = ob.ray(win, 320, 240, 160, 120)
  check(math.abs(r0.dx - fx) < 1e-9 and math.abs(r0.dy - fy) < 1e-9
        and math.abs(r0.dz - fz) < 1e-9, "orbit: center ray = fwd")
  local wx, wy, wz = win.ofx + 3.7, win.ofy + 1.2, win.ofz - 2.9
  local qx, qy = ob.project(vpm, 320, 240, wx, wy, wz)
  local rr = ob.ray(win, 320, 240, qx, qy)
  local tx, ty, tz = wx - rr.ox, wy - rr.oy, wz - rr.oz
  local t = dot(tx,ty,tz, rr.dx,rr.dy,rr.dz)
  local mx = rr.ox + rr.dx*t - wx
  local my = rr.oy + rr.dy*t - wy
  local mz = rr.oz + rr.dz*t - wz
  check(mm.sqrt(mx*mx + my*my + mz*mz) < 1e-6,
        "orbit: project->ray round trip hits the point")

  -- gestures: pitch clamps both ways, dolly ladder clamps, fit frames
  local w2 = ob.defaults(40)
  ob.orbit(w2, 0, -10000)
  check(w2.opitch == ob.PITCH_MAX, "orbit: pitch clamps high")
  ob.orbit(w2, 0, 10000)
  check(w2.opitch == ob.PITCH_MIN, "orbit: pitch clamps low")
  local d0 = w2.odist
  ob.dolly(w2, 1)
  check(math.abs(w2.odist - d0 / ob.STEP) < 1e-9, "orbit: dolly steps down")
  for _ = 1, 60 do ob.dolly(w2, 1) end
  check(w2.odist == ob.DIST_MIN, "orbit: dolly clamps near")
  for _ = 1, 120 do ob.dolly(w2, -1) end
  check(w2.odist == ob.DIST_MAX, "orbit: dolly clamps far")
  ob.fit(w2, 5, 1, 7, 20)
  check(w2.ofx == 5 and w2.ofy == 1 and w2.ofz == 7, "orbit: fit adopts focus")
  local half = ob.FOV * (mm.pi / 180) * 0.5
  check(math.abs(w2.odist - 20 / (mm.tan(half) * 0.8)) < 1e-9,
        "orbit: fit dist from the fov")

  -- pan: dys moves the focus along flattened-forward, y never moves
  local w3 = ob.defaults(30)
  local pfy = w3.ofy
  local bfx, _, bfz = ob.basis(w3)
  local bl = mm.sqrt(bfx*bfx + bfz*bfz)
  ob.pan(w3, 0, 100, 200)
  check(w3.ofy == pfy, "orbit: pan stays on the ground plane")
  local want = 2 * 30 / 200 * 100
  local moved = mm.sqrt(w3.ofx^2 + w3.ofz^2)
  check(math.abs(moved - want) < 1e-9
        and math.abs(w3.ofx * (bfz/bl) - w3.ofz * (bfx/bl)) < 1e-9,
        "orbit: pan tracks flattened forward, dist-scaled")
end

local function t_ed_park()
  -- R6c (REWIND.md §4): parking is interactive-but-ephemeral; close
  -- restores the stashed present; resume adopts the shown doc
  local trace = cm.require("cm.trace")
  local scrub = cm.require("cm.scrub")
  local ed = cm.require("cm.ed")
  local wm = cm.require("cm.ed.wm")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local was_on, was_doc, was_rev, was_g = ed.on, ed.doc, ed.doc_rev, ed.g
  local was_root = ed.root
  local main = cm.main
  local saved_ar = main and main.after_restore
  if main then main.after_restore = nil end -- game.init here = the suite!
  trace.ring.kf = 4
  trace.ring.seconds = 10
  ed.on = true
  ed.g = {}
  ed.doc = wm.init({ v = 1, mark = "A" })
  ed.doc_rev = 1
  trace.ring_start({ project = "selftest" })
  local irec = ("\0"):rep(10)
  local pressed = string.pack("<I4i2i2I1i1", 1, 0, 0, 0, 0)
  for i = 1, 6 do
    if i == 4 then
      ed.doc.mark = "B"
      ed.touch()
    end
    sim:i64(0, f0 + i)
    trace.record_frame(i == 5 and pressed or irec, nil)
  end
  local present = ed.doc

  local tl = trace.ring_timeline(f0, f0 + 6, 6)
  local sim_activity, ed_activity, input_event = false, false, false
  for _, b in ipairs(tl.data) do
    sim_activity = sim_activity or b.sim > 0
    ed_activity = ed_activity or b.editor > 0
    input_event = input_event
      or ((b.events & trace.timeline_event.INPUT) ~= 0)
  end
  check(sim_activity and ed_activity,
        "rewind tray: summary splits sim and editor activity")
  check(input_event, "rewind tray: summary marks input transitions")

  -- The disk-use meter's threshold rule (D130): one pure function feeds the
  -- fill color AND the non-color cues (notch + "!" label), so they agree.
  local rewind = cm.require("cm.ed.rewind")
  check(rewind.meter_zone(0) == "ok" and rewind.meter_zone(0.7) == "ok",
        "rewind meter: ok through the warm threshold inclusive")
  check(rewind.meter_zone(0.71) == "warm" and rewind.meter_zone(0.9) == "warm",
        "rewind meter: warm past 0.7 through 0.9 inclusive")
  check(rewind.meter_zone(0.91) == "near" and rewind.meter_zone(1.0) == "near",
        "rewind meter: near past 0.9")
  check(rewind.meter_zone(nil) == "ok" and rewind.meter_zone(0 / 0) == "ok"
          and rewind.meter_zone("full") == "ok",
        "rewind meter: garbage reads ok")

  -- Inclusive loop playback shows A, then every frame through B, then wraps.
  rewind.open(ed)
  scrub.open()
  local clock = 0
  scrub._clock_ns = function() return clock end
  scrub.set_loop(f0 + 2, f0 + 4)
  check(not rewind.toggle(ed) and rewind.opened(ed) and scrub.has_loop(),
        "rewind loop: F4 cannot dismiss active clip mode")
  scrub.frame()
  check(scrub.at == f0 + 2, "rewind loop: A gets a complete first tick")
  scrub.frame()
  check(scrub.at == f0 + 2,
        "rewind clock: render ticks cannot run 1x playback too fast")
  clock = clock + math.ceil(scrub.FRAME_NS)
  scrub.frame()
  check(scrub.at == f0 + 3, "rewind loop: advances inside range")
  clock = clock + math.ceil(scrub.FRAME_NS)
  scrub.frame()
  check(scrub.at == f0 + 4, "rewind loop: inclusive B is shown")
  clock = clock + math.ceil(scrub.FRAME_NS)
  scrub.frame()
  check(scrub.at == f0 + 2, "rewind loop: wraps B to A")
  check(scrub.set_speed(2) == 2, "rewind clock: transport selects 2x")
  clock = clock + math.ceil(scrub.FRAME_NS)
  scrub.frame()
  check(scrub.at == f0 + 4,
        "rewind clock: faster transport may drop intermediate frames")
  check(rewind.escape(ed) and scrub.paused() and not scrub.play
        and not scrub.has_loop() and rewind.opened(ed),
        "rewind loop: first Esc clears clip but stays parked")
  check(rewind.escape(ed) and not scrub.paused() and not rewind.opened(ed),
        "rewind loop: second Esc closes and restores live")
  scrub._clock_ns = nil

  ed.g.mw = { stale = true } -- the map window's decoded-doc plumbing
  ed.g.tmw = { stale = true } -- the tilemap window's too (R8d)
  local sprite_pipe, anim_pipe = { tex = 901 }, { tex = 902 }
  ed.g.sw = { ["art/test.spr"] = sprite_pipe }
  ed.g.aw = { ["art/test.spr"] = anim_pipe }
  local freed = {}
  local real_tex_free = pal.tex_free
  pal.tex_free = function(id) freed[#freed + 1] = id; return true end
  scrub.open()
  check(scrub.paused(), "ed park: scrub open")
  scrub.at = f0 + 2
  scrub.frame()
  check(ed.parked and ed.doc ~= present and ed.doc.mark == "A",
        "ed park: the past is shown")
  check(ed.g.mw == nil, "ed park: map plumbing drops (rebuilds from the past)")
  check(ed.g.tmw == nil, "ed park: tilemap plumbing drops too")
  check(#freed == 2 and freed[1] == 902 and freed[2] == 901
        and sprite_pipe.tex == nil and anim_pipe.tex == nil
        and ed.g.sw == nil and ed.g.aw == nil,
        "ed park: sprite + animation GPU handles release before cache drop")
  pal.tex_free = real_tex_free
  ed.doc.poke = 1 -- interactive: poke the parked doc
  ed.touch()
  check(ed.g.save_due == nil, "ed park: autosave suspended")
  scrub.at = f0 + 5
  scrub.frame()
  check(ed.doc.poke == nil and ed.doc.mark == "B",
        "ed park: pokes evaporate on seek")
  ed.g.mw = { stale = true }
  ed.g.tmw = { stale = true }
  sprite_pipe, anim_pipe = { tex = 903 }, { tex = 904 }
  ed.g.sw = { ["art/test.spr"] = sprite_pipe }
  ed.g.aw = { ["art/test.spr"] = anim_pipe }
  freed = {}
  pal.tex_free = function(id) freed[#freed + 1] = id; return true end
  scrub.close()
  pal.tex_free = real_tex_free
  check(not ed.parked and ed.doc == present,
        "ed park: close restores the present")
  check(ed.g.mw == nil, "ed park: map plumbing drops on unpark too")
  check(ed.g.tmw == nil, "ed park: tilemap plumbing drops on unpark too")
  check(#freed == 2 and sprite_pipe.tex == nil and anim_pipe.tex == nil,
        "ed park: unpark releases rebuilt GPU handles too")
  check(ed.g.save_due ~= nil, "ed park: autosave re-armed")

  scrub.open()
  scrub.at = f0 + 2
  scrub.frame()
  ed.doc.poke = 42
  scrub.rewind_here()
  check(not ed.parked and ed.doc.poke == 42 and ed.doc.mark == "A",
        "ed park: resume adopts the shown doc, pokes included")
  local _, hi = trace.ring_range()
  check(hi == f0 + 2 and sim:i64(0) == f0 + 2,
        "ed park: resume truncated + rewound the sim")

  -- bring-back (R6e, REWIND.md §5): a parked asset's working bytes copy
  -- into the present, journaled there as one undoable step
  local journal = cm.require("cm.ed.journal")
  local root = tmproot() .. "/cosmic_selftest_bb"
  pal.mkdir(root)
  local jf = journal.file(root, "f.txt")
  pal.x_remove(jf)
  ed.g = {}
  ed.on = true
  ed.root = root
  ed.doc = wm.init({ v = 1, assets = { ["f.txt"] = { text = "OLD", jpos = 0 } } })
  local tw = wm.spawn(ed.doc, "text", 0, 0, 100, 100, { path = "f.txt" })
  ed.doc_rev = 1
  sim:i64(0, f0 + 2) -- continue on the truncated timeline
  trace.ring_start({ project = "selftest" })
  for i = 3, 5 do
    if i == 4 then
      ed.doc.assets["f.txt"].text = "NEW"
      ed.touch()
    end
    sim:i64(0, f0 + i)
    trace.record_frame(irec, nil)
  end
  local present2 = ed.doc
  scrub.open()
  scrub.at = f0 + 3 -- park where the text was OLD
  scrub.frame()
  check(ed.parked and ed.doc.assets["f.txt"].text == "OLD",
        "ed bring-back: the past shows OLD")
  check(ed.doc.focus == tw.id, "ed bring-back: focus captured in history")
  local got = ed.bring_back()
  check(got == "f.txt", "ed bring-back: returns the path")
  check(present2.assets["f.txt"].text == "OLD",
        "ed bring-back: the present adopted the past bytes")
  local j2 = journal.open(root, "f.txt")
  check(journal.at(j2) and journal.at(j2).bytes == "OLD"
        and present2.assets["f.txt"].jpos == j2.pos,
        "ed bring-back: journaled in the present")
  scrub.close()
  check(ed.doc == present2 and ed.doc.assets["f.txt"].text == "OLD",
        "ed bring-back: survives the unpark")

  ed.on, ed.doc, ed.doc_rev, ed.g = was_on, was_doc, was_rev, was_g
  ed.root = was_root
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  if main then main.after_restore = saved_ar end
  scrub.shown = nil
  trace.ring_start({ project = "selftest" })
end

local function t_timeline_summary()
  -- A7 §12: the persisted per-segment activity/event digest lets the tray draw
  -- demoted, spilled, and adopted cross-session history without decoding a
  -- single frame of state. It is observer-only — no golden or committed trace
  -- byte moves (proven by the suite staying green) — so this just pins the
  -- summary round-trip and the four lanes.
  local trace = cm.require("cm.trace")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local root = tmproot() .. "/cosmic_selftest_tlsum"
  pal.mkdir(root)
  for _, n in ipairs(pal.list_dir(root .. "/.ed/history") or {}) do
    pal.x_remove(root .. "/.ed/history/" .. n)
  end
  trace.ring.kf = 4
  trace.ring.seconds = 8 / 60 -- RAM window = 2 segments; older ones demote
  trace.ring.spill = true
  trace.ring.budget_mb = 64
  local E = trace.timeline_event
  local b = pal.buf("st.tlsum", 8)
  b:i32(0, 0)
  trace.ring_start({ project = root })
  local irec = ("\0"):rep(10)
  -- 20 frames = segments 1..5 closed+spilled, 6 open empty. Segment 1 carries a
  -- save; segment 2 an error; a late frame in the resident tail carries both a
  -- save (the exact-path files lane) and a restart.
  for i = 1, 20 do
    b:i32(0, i * 7)          -- sim state moves every frame
    sim:i64(0, f0 + i)
    trace.record_frame(irec, nil)
    if i == 3 then trace.note_save("art/hero.spr", 100) end
    if i == 4 then trace.note_import("ins/kick.ins", 300) end
    if i == 6 then trace.note_event(E.ERROR) end
    if i == 18 then
      trace.note_save("maps/room.map", 250)
      trace.note_event(E.RESTART)
    end
  end
  check(trace.history_drain(), "timeline summary: spill drains")

  -- The resident tail still renders exactly, including the late save/restart.
  local tail = trace.ring_timeline(f0 + 17, f0 + 20, 4)
  local tail_files, tail_restart = false, false
  for _, d in ipairs(tail.data) do
    tail_files = tail_files or d.files > 0
    tail_restart = tail_restart or (d.events & E.RESTART) ~= 0
  end
  check(not tail.missing and tail_files and tail_restart,
        "timeline summary: resident tail draws files + restart from chunks")

  -- Reboot at the same counter: the chain adopts as skeletons with NO chunks,
  -- so every lane below comes from the persisted manifest digest alone.
  trace.ring_start({ project = root })
  local alo, ahi = trace.ring_range()
  check(ahi == f0 + 20, "timeline summary: adopted the spilled tail")
  local tl = trace.ring_timeline(alo, ahi, 20)
  local sim_hit, files_hit, save_hit, err_hit = false, false, false, false
  local import_hit = false
  for _, d in ipairs(tl.data) do
    sim_hit = sim_hit or d.sim > 0
    files_hit = files_hit or d.files > 0
    save_hit = save_hit or (d.events & E.SAVE) ~= 0
    err_hit = err_hit or (d.events & E.ERROR) ~= 0
    import_hit = import_hit or (d.events & E.IMPORT) ~= 0
  end
  check(not tl.missing, "timeline summary: adopted history has no missing gap")
  check(sim_hit and files_hit and save_hit and err_hit,
        "timeline summary: adopted digest carries sim/files/save/error")
  check(import_hit,
        "timeline summary: the asset-import marker survives adoption (A7)")

  -- Legacy (pre-A7) manifest lines carry only the first four fields; those
  -- segments adopt with no digest and honestly read back as a missing gap.
  local ipath = root .. "/.ed/history/index"
  local raw = pal.read_file(ipath) or ""
  local legacy = {}
  for line in raw:gmatch("[^\n]+") do
    legacy[#legacy + 1] = line:match("^(%d+ %d+ %d+ %d+)") or line
  end
  pal.write_file(ipath, table.concat(legacy, "\n") .. "\n")
  trace.ring_start({ project = root })
  local llo, lhi = trace.ring_range()
  local ltl = trace.ring_timeline(llo, lhi, 20)
  check(ltl.missing, "timeline summary: legacy 4-field lines report the gap")

  -- leave a clean ring behind
  for _, n in ipairs(pal.list_dir(root .. "/.ed/history") or {}) do
    pal.x_remove(root .. "/.ed/history/" .. n)
  end
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  sim:i64(0, f0)
  pal.buf_free("st.tlsum")
  trace.ring_start({ project = "selftest" })
end

local function t_timeline_thumbs()
  -- A7 §11: the presented-frame previews (THMB). Observer-only like the digest
  -- — captured only in live windowed sessions (gated on spill), never verified,
  -- stripped from exported clips — so the green suite proves no golden byte
  -- moved. This pins capture/query, decimation, demotion survival, the export
  -- strip, and the headless capture gate.
  local trace = cm.require("cm.trace")
  local chunk = cm.require("cm.chunk")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local save_period = trace.thumb_period
  local root = tmproot() .. "/cosmic_selftest_tlthumb"
  pal.mkdir(root)
  for _, n in ipairs(pal.list_dir(root .. "/.ed/history") or {}) do
    pal.x_remove(root .. "/.ed/history/" .. n)
  end
  trace.ring.kf = 4
  trace.ring.seconds = 8 / 60 -- RAM window = 2 segments; older ones demote
  trace.ring.spill = true
  trace.ring.budget_mb = 64
  trace.thumb_period = 6
  local b = pal.buf("st.tlthumb", 8)
  b:i32(0, 0)
  trace.ring_start({ project = root })
  local irec = ("\0"):rep(10)

  -- a synthetic flat 160x92 FOV; thumb_dims height-normalizes it to 46 and the
  -- aspect gives width 80. Captured directly (no GPU) at two frames.
  local sw, sh, dw, dh = 160, 92, 80, 46
  local fov = ("\xAB\xCD\xEF\xFF"):rep(sw * sh)
  for i = 1, 12 do
    b:i32(0, i * 7)
    sim:i64(0, f0 + i)
    trace.record_frame(irec, nil)
    if i == 2 or i == 11 then trace.thumb_capture(fov, sw, sh) end
  end

  local lo, hi = trace.ring_range()
  local all = trace.ring_thumbs(lo, hi, 16)
  check(#all == 2, "previews: both captured previews are queryable")
  check(all[1].frame == f0 + 2 and all[2].frame == f0 + 11,
        "previews: entries carry their exact capture frame, frame-sorted")
  check(all[1].w == dw and all[1].h == dh,
        "previews: thumb_dims height-normalizes 160x92 to 80x46")
  local pix, pw, ph = pal.png_read(all[1].png)
  check(pix and pw == dw and ph == dh and #pix == dw * dh * 4,
        "previews: the stored PNG decodes to the preview dimensions")
  check(#trace.ring_thumbs(lo, hi, 1) == 1,
        "previews: ring_thumbs decimates to the requested max")

  -- Demotion drops a segment's resident chunks but seg.thumb is a RAM index
  -- that survives, so previews still draw across the whole retained window.
  check(trace.history_drain(), "previews: spill drains")
  check(#trace.ring_thumbs(lo, hi, 16) == 2,
        "previews: previews survive demotion of their segment")

  -- Exported clips strip THMB (history chrome, not replay state).
  local clip = root .. "/clip.ctrace"
  check(trace.ring_export(clip), "previews: ring exports")
  local has_thmb = false
  for _, c in ipairs(chunk.read(pal.read_file(clip), "CTRC")) do
    if c.tag == "THMB" then has_thmb = true end
  end
  check(not has_thmb, "previews: THMB is stripped from an exported clip")

  -- The headless/CI gate: thumb_pump reads a pixel only when ring.thumbs is set
  -- (the live-window condition) — this is why goldens and traces never carry one.
  local read_called = false
  local real_read, real_size = pal.read_pixels, pal.gfx_size
  local save_thumbs = trace.ring.thumbs
  pal.read_pixels = function() read_called = true; return fov end
  pal.gfx_size = function() return sw, sh end
  trace.ring.thumbs = false
  trace.thumb_pump()
  check(not read_called, "previews: thumb_pump is a no-op when ring.thumbs is off")
  trace.ring.thumbs = true
  trace.thumb_pump()
  check(read_called, "previews: thumb_pump captures in a live (thumbs-on) session")
  pal.read_pixels, pal.gfx_size = real_read, real_size
  trace.ring.thumbs = save_thumbs

  for _, n in ipairs(pal.list_dir(root .. "/.ed/history") or {}) do
    pal.x_remove(root .. "/.ed/history/" .. n)
  end
  pal.x_remove(clip)
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  trace.thumb_period = save_period
  sim:i64(0, f0)
  pal.buf_free("st.tlthumb")
  trace.ring_start({ project = "selftest" })
end

local function t_timeline_retention()
  -- A7 retention surface: the recorder-pause gate (the game runs while history
  -- stops growing; resume reseeds a fresh stream), the exact retained-bytes the
  -- disk budget bounds, the immediate re-eviction door, and the machine-local
  -- budget persisted in editor.dat. All observer/chrome policy — never sim
  -- state, never verified — so the green suite proves no golden byte moved.
  local trace = cm.require("cm.trace")
  local view = cm.require("cm.view")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local root = tmproot() .. "/cosmic_selftest_tlret"
  pal.mkdir(root)
  for _, n in ipairs(pal.list_dir(root .. "/.ed/history") or {}) do
    pal.x_remove(root .. "/.ed/history/" .. n)
  end
  trace.ring.kf = 4
  local b = pal.buf("st.tlret", 8)
  b:i32(0, 0)
  local irec = ("\0"):rep(10)
  local function drive(a, z)
    for i = a, z do
      b:i32(0, i * 7)
      sim:i64(0, f0 + i)
      trace.record_frame(irec, nil)
    end
  end

  -- ---- Phase A: recorder pause freezes the live edge; the game frame advances
  trace.ring.spill = false
  trace.ring.seconds = 30           -- roomy: nothing evicts during this phase
  sim:i64(0, f0)
  trace.ring_start({ project = root })
  drive(1, 8)
  local _, hiA = trace.ring_range()
  check(hiA == f0 + 8, "retention: recorded up to the live edge")
  check(trace.set_rec_paused(true) == true and trace.rec_paused(),
        "retention: pause arms the recorder gate")
  for i = 9, 14 do                  -- the game keeps running, un-recorded
    sim:i64(0, f0 + i)
    trace.record_frame(irec, nil)   -- a no-op while paused
  end
  local _, hiP = trace.ring_range()
  check(hiP == f0 + 8, "retention: paused recorder freezes the live edge")
  check(trace.ring_stats().frames == 8,
        "retention: no frames captured while paused")
  check(trace.set_rec_paused(false) == false and not trace.rec_paused(),
        "retention: resume clears the gate")
  drive(15, 18)                     -- a fresh contiguous stream from the present
  local loR, hiR = trace.ring_range()
  check(hiR == f0 + 18, "retention: resumed recording advances the live edge")
  check(loR >= f0 + 14,
        "retention: resume starts fresh (pre-pause history released)")

  -- ---- Phase B: retained_bytes + the immediate re-eviction door ----
  trace.ring.spill = true
  trace.ring.seconds = 8 / 60       -- RAM window = 2 segments; older ones demote
  trace.ring.budget_mb = 64
  sim:i64(0, f0)
  trace.ring_start({ project = root })
  drive(1, 24)                      -- kf=4 → six closed segments spill
  check(trace.history_drain(), "retention: spill drains")
  local st = trace.ring_stats()
  check(st.retained_bytes and st.retained_bytes > 0,
        "retention: ring_stats reports the budget-bounded retained bytes")
  local lo_before = trace.ring_range()
  trace.ring.budget_mb = 0.00001    -- tiny: all but the newest exceed the bound
  trace.reevict()
  trace.history_drain()
  local lo_after = trace.ring_range()
  check(lo_after > lo_before,
        "retention: reevict drops the oldest disk segment immediately")
  check(trace.ring_stats().retained_bytes < st.retained_bytes,
        "retention: retained bytes shrink after eviction")

  -- ---- Phase C: the machine-local budget round-trips editor.dat ----
  local save_path = view._access_path
  local save_budget = view.cfg.history_budget_mb
  view._access_path = root .. "/editor.dat"
  pal.x_remove(view._access_path)
  check(view.budget_mb_ok(2048) == 2048, "retention: budget_mb_ok passes a rung")
  check(view.budget_mb_ok(1) == 16 and view.budget_mb_ok(1e9) == 65536,
        "retention: budget_mb_ok clamps to [16, 65536] MB")
  check(view.budget_mb_ok(1024.7) == 1024 and view.budget_mb_ok("x") == nil
        and view.budget_mb_ok(0 / 0) == nil,
        "retention: budget_mb_ok floors numbers and rejects non-numbers/NaN")
  check(view.set_history_budget(2048) == 2048 and view.cfg.history_budget_mb == 2048,
        "retention: set_history_budget updates cfg")
  view.cfg.history_budget_mb = nil
  view.load_accessibility()
  check(view.cfg.history_budget_mb == 2048,
        "retention: budget round-trips through editor.dat")
  pal.write_file(view._access_path,
    cm.require("cm.state").canon({ history_budget_mb = "nope" }))
  view.cfg.history_budget_mb = nil
  view.load_accessibility()
  check(view.cfg.history_budget_mb == nil,
        "retention: a non-number persisted budget is ignored")
  view._access_path, view.cfg.history_budget_mb = save_path, save_budget

  -- leave a clean ring behind
  for _, n in ipairs(pal.list_dir(root .. "/.ed/history") or {}) do
    pal.x_remove(root .. "/.ed/history/" .. n)
  end
  pal.x_remove(root .. "/editor.dat")
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  sim:i64(0, f0)
  pal.buf_free("st.tlret")
  trace.ring_start({ project = "selftest" })
end

local function t_project_blobs()
  -- A7 §14 (D103): the content-addressed project-blob store + per-segment
  -- project manifest — the foundation that lets a retained range (including an
  -- adopted cross-session one) name a COMPLETE project tree without copying an
  -- unchanged file into every segment. Observer-only like the rest of the disk
  -- tier: it rides ring.spill, so the green suite proves no golden byte moved.
  local trace = cm.require("cm.trace")
  local chunk = cm.require("cm.chunk")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local root = tmproot() .. "/cosmic_selftest_blobs"
  local blobdir = root .. "/.ed/history/blobs"
  pal.mkdir(root)
  local function wipe_hist() -- recursive: the blob store is a subtree
    local ns = pal.list_dir(root .. "/.ed/history") or {}
    for i = #ns, 1, -1 do pal.x_remove(root .. "/.ed/history/" .. ns[i]) end
    pal.x_remove(blobdir)
    pal.x_remove(root .. "/.ed/history")
  end
  wipe_hist()
  -- a real project tree: two files with IDENTICAL content (proves dedup), a
  -- nested asset, project source, and two machine files that must be excluded.
  local hero = ("HERO"):rep(9)
  pal.write_file(root .. "/main.lua", "return {}\n")
  pal.mkdir(root .. "/art")
  pal.write_file(root .. "/art/hero.spr", hero)
  pal.write_file(root .. "/dup.txt", hero)         -- same bytes as hero.spr
  pal.write_file(root .. "/video.dat", "MACHINE")  -- per-machine, excluded
  pal.write_file(root .. "/input.dat", "MACHINE")  -- rebind store, excluded

  trace.ring.kf = 4
  trace.ring.seconds = 30
  trace.ring.spill = true
  trace.ring.budget_mb = 64
  local b = pal.buf("st.blobs", 8)
  b:i32(0, 0)
  local irec = ("\0"):rep(10)
  local function drive(a, z)
    for i = a, z do
      b:i32(0, i * 5); sim:i64(0, f0 + i); trace.record_frame(irec, nil)
    end
  end
  local function count_blob(hash)
    local n = 0
    for _, e in ipairs(pal.list_dir(blobdir) or {}) do
      if e == hash then n = n + 1 end
    end
    return n
  end

  sim:i64(0, f0)
  trace.ring_start({ project = root })

  -- ---- baseline manifest: the complete tree, machine files excluded ----
  check(trace.ring_stats().manifest == true,
        "blobs: a live spill session captures a project manifest")
  local man = trace.ring_manifest()
  check(man and man["main.lua"] and man["art/hero.spr"] and man["dup.txt"],
        "blobs: the manifest names project source + nested assets")
  check(not man["video.dat"] and not man["input.dat"],
        "blobs: machine files (video.dat/input.dat) are excluded")
  check(man["art/hero.spr"] == pal.sha256(hero),
        "blobs: a manifest entry is the file's content hash")
  check(trace.blob_get(man["art/hero.spr"]) == hero,
        "blobs: the referenced blob round-trips its exact bytes")

  -- ---- dedup: identical content shares exactly one blob ----
  check(man["dup.txt"] == man["art/hero.spr"],
        "blobs: identical file content shares one content-addressed blob")
  check(count_blob(man["dup.txt"]) == 1,
        "blobs: the shared blob exists once on disk")

  -- ---- a save advances the manifest to the new content hash ----
  drive(1, 4) -- frame f0+1.. rides the baseline-manifest segment
  local base_mh = trace.manifest_at(f0 + 1)
  check(base_mh and trace.manifest_files(base_mh)["main.lua"],
        "blobs: a segment's manifest decodes to the project tree")
  local hero2 = ("EDIT"):rep(9)
  pal.write_file(root .. "/art/hero.spr", hero2) -- an editor save to disk
  trace.note_save("art/hero.spr", #hero2)        -- marks the manifest dirty
  trace.manifest_pump()                          -- render-phase fold
  local man2 = trace.ring_manifest()
  check(man2["art/hero.spr"] == pal.sha256(hero2)
        and man2["art/hero.spr"] ~= man["art/hero.spr"],
        "blobs: a save re-hashes the file into the manifest")
  check(trace.ring_stats().manifest and trace.manifest_at(f0 + 1) == base_mh,
        "blobs: the already-closed keyframe keeps its own manifest")
  drive(5, 12) -- newer segments snapshot the advanced manifest
  local new_mh = trace.manifest_at(f0 + 12)
  check(new_mh and new_mh ~= base_mh
        and trace.manifest_files(new_mh)["art/hero.spr"] == pal.sha256(hero2),
        "blobs: later segments carry the advanced project manifest")

  -- ---- spill + cross-session adoption recovers the manifest ----
  drive(13, 24)
  check(trace.history_drain(), "blobs: spill drains")
  local mid = f0 + 6
  local mh_pre = trace.manifest_at(mid)
  check(mh_pre, "blobs: a spilled segment carries a manifest hash")
  -- "reboot": the counter already sits at the tail, so ring_start adopts the
  -- chain ending at the present exactly as a fresh process would.
  trace.ring_start({ project = root })
  local mh_post = trace.manifest_at(mid)
  check(mh_post == mh_pre,
        "blobs: adoption recovers each segment's manifest hash from the index")
  check(trace.manifest_files(mh_post) and trace.manifest_files(mh_post)["main.lua"],
        "blobs: adopted cross-session history is materialization-ready (§14)")

  -- ---- gc_blobs sweeps orphans; referenced blobs survive ----
  local orphan = ("0"):rep(64) -- a valid-looking hash no manifest references
  pal.write_file(blobdir .. "/" .. orphan, "junk")
  local live = trace.manifest_at(mid)
  local live_file = trace.manifest_files(live)["main.lua"]
  check(count_blob(orphan) == 1 and count_blob(live_file) == 1,
        "blobs: the orphan and a referenced blob both exist before gc")
  trace.ring_start({ project = root }) -- reboot re-runs gc_blobs
  check(count_blob(orphan) == 0,
        "blobs: gc_blobs sweeps a blob no retained segment references")
  check(count_blob(live_file) == 1,
        "blobs: gc_blobs keeps a blob a retained segment still names")
  check((trace.ring_stats().blob_bytes or 0) > 0,
        "blobs: the disk meter counts the retained blob store")

  -- ---- an exported clip carries no manifest chrome (goldens hold) ----
  drive(25, 28) -- live segments (with a code bundle) past the adopted tail
  local clip = root .. "/clip.ctrace"
  trace.ring_export(clip)
  local saw_pman, saw_fram = false, false
  for _, c in ipairs(chunk.read(pal.read_file(clip) or "", "CTRC")) do
    if c.tag == "PMAN" then saw_pman = true end
    if c.tag == "FRAM" then saw_fram = true end
  end
  check(saw_fram and not saw_pman,
        "blobs: an exported .ctrace has frames but no PMAN (stripped)")

  -- ---- clear_cache removes the populated history incl. the blob subtree ----
  check(trace.blob_get(live_file) == pal.read_file(root .. "/main.lua"),
        "blobs: the referenced blob still holds main.lua before clear")
  local cache = cm.require("cm.ed.cache")
  local ok_clear, n_removed = cache.clear(root)
  check(ok_clear and n_removed > 0,
        "blobs: cache.clear removes the whole history subtree (depth-first)")
  check(not pal.mtime(blobdir),
        "blobs: the content-addressed blob store is gone after clear")

  -- ---- observer-only: no spill ⇒ no walk, no manifest, no blobs ----
  trace.ring.spill = false
  trace.ring_start({ project = root })
  check(trace.ring_stats().manifest == false and trace.ring_manifest() == nil
        and (trace.ring_stats().blob_bytes or 0) == 0,
        "blobs: a spill-off (headless/verify) session captures no manifest")

  -- leave a clean tree + ring behind
  wipe_hist()
  for _, n in ipairs({ "main.lua", "art/hero.spr", "art", "dup.txt",
                       "video.dat", "input.dat", "clip.ctrace" }) do
    pal.x_remove(root .. "/" .. n)
  end
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  sim:i64(0, f0)
  pal.buf_free("st.blobs")
  trace.ring_start({ project = "selftest" })
end

local function t_standalone_clip()
  -- A7 §14: the standalone .ctrace clip. export_clip packs an inclusive A..B
  -- range as a SELF-CONTAINED replay — exact state through B plus the complete
  -- project tree at A (MFST + one BLOB per referenced file version) — and
  -- materialize_clip writes that tree into an isolated ephemeral workspace with
  -- no dependency on this session's blob store. Legacy/plain exports stay
  -- byte-identical (goldens hold); the whole surface rides ring.spill.
  local trace = cm.require("cm.trace")
  local chunk = cm.require("cm.chunk")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local save_ws = trace._workspace_root
  local root = tmproot() .. "/cosmic_selftest_clip"
  local wsroot = tmproot() .. "/cosmic_selftest_clipws"
  pal.mkdir(root)
  local function wipe_hist()
    local ns = pal.list_dir(root .. "/.ed/history") or {}
    for i = #ns, 1, -1 do pal.x_remove(root .. "/.ed/history/" .. ns[i]) end
    pal.x_remove(root .. "/.ed/history/blobs")
    pal.x_remove(root .. "/.ed/history")
  end
  local function wipe_ws()
    local ns = pal.x_list_dir_all and pal.x_list_dir_all(wsroot) or {}
    for i = #ns, 1, -1 do pal.x_remove(wsroot .. "/" .. ns[i]) end
    pal.x_remove(wsroot)
  end
  wipe_hist(); wipe_ws()

  -- a real project tree; hero.spr gets a second version mid-recording so the
  -- clip's range spans two manifests (proves it carries every needed version).
  local main_src, readme = "return {}\n", "read me\n"
  local hero1, hero2 = ("HERO"):rep(9), ("EDIT"):rep(9)
  pal.write_file(root .. "/main.lua", main_src)
  pal.mkdir(root .. "/art")
  pal.write_file(root .. "/art/hero.spr", hero1)
  pal.write_file(root .. "/readme.txt", readme)
  pal.write_file(root .. "/video.dat", "MACHINE") -- excluded from the manifest
  pal.write_file(root .. "/input.dat", "MACHINE") -- excluded from the manifest

  trace.ring.kf, trace.ring.seconds = 4, 30
  trace.ring.spill, trace.ring.budget_mb = true, 64
  local b = pal.buf("st.clip", 8)
  b:i32(0, 0)
  local irec = ("\0"):rep(10)
  local function drive(a, z)
    for i = a, z do
      b:i32(0, i * 7); sim:i64(0, f0 + i); trace.record_frame(irec, nil)
    end
  end

  sim:i64(0, f0)
  trace.ring_start({ project = root })
  drive(1, 8) -- frames on the baseline (hero v1) manifest
  local hero1_hash = trace.ring_manifest()["art/hero.spr"]
  pal.write_file(root .. "/art/hero.spr", hero2) -- an editor save mid-recording
  trace.note_save("art/hero.spr", #hero2)
  trace.manifest_pump()
  drive(9, 16) -- newer segments snapshot the hero v2 manifest
  local hero2_hash = trace.ring_manifest()["art/hero.spr"]
  check(hero1_hash ~= hero2_hash, "clip: the save advanced the manifest")

  -- ---- export the inclusive A..B range as a standalone clip ----
  local A, B = f0 + 2, f0 + 14 -- A in the v1 range, B in the v2 range
  local clip = root .. "/range.ctrace"
  local ok = trace.export_clip(A, B, clip)
  check(ok, "clip: export_clip writes a standalone .ctrace over A..B")

  local mfst_n, loop, fram_n = 0, nil, 0
  local blob_hashes, dup = {}, false
  for _, c in ipairs(chunk.read(pal.read_file(clip) or "", "CTRC")) do
    if c.tag == "MFST" then mfst_n = mfst_n + 1 end
    if c.tag == "FRAM" then fram_n = fram_n + 1 end
    if c.tag == "PMAN" then check(false, "clip: standalone clip must not carry PMAN") end
    if c.tag == "BLOB" then
      local h = string.unpack("<s4s4", c.payload)
      if blob_hashes[h] then dup = true end
      blob_hashes[h] = true
    end
    if c.tag == "LOOP" then local a, z = string.unpack("<I4I4", c.payload)
      loop = { a = a, b = z } end
  end
  check(mfst_n == 1 and fram_n > 0,
        "clip: the clip embeds exactly one project manifest plus its frames")
  check(loop and loop.a == A and loop.b == B,
        "clip: LOOP records the exact A/B bounds for reopening")

  -- dedup: one BLOB per DISTINCT content hash across the range's manifests
  -- (main.lua + readme.txt shared, hero has two versions) = 4.
  local want = {}
  for _, mh in ipairs({ trace.manifest_at(A), trace.manifest_at(B) }) do
    for _, h in pairs(trace.manifest_files(mh)) do want[h] = true end
  end
  local nwant, nhave = 0, 0
  for h in pairs(want) do nwant = nwant + 1; check(blob_hashes[h],
    "clip: every referenced file version ships as a blob") end
  for _ in pairs(blob_hashes) do nhave = nhave + 1 end
  check(not dup and nhave == nwant and nwant == 4,
        "clip: exactly one content-addressed blob per distinct version (dedup)")
  check(blob_hashes[hero1_hash] and blob_hashes[hero2_hash],
        "clip: both hero versions ride the range (A's tree + B's tree)")

  -- ---- materialize the clip's tree into an isolated workspace ----
  trace._workspace_root = wsroot
  local ws, mloop = trace.materialize_clip(clip)
  check(ws and ws:find(wsroot, 1, true) == 1,
        "clip: materialize_clip writes under the ephemeral workspace root")
  check(mloop and mloop.a == A and mloop.b == B,
        "clip: materialize_clip recovers the A/B loop bounds")
  check(pal.read_file(ws .. "/main.lua") == main_src
        and pal.read_file(ws .. "/readme.txt") == readme,
        "clip: the workspace holds the project source byte-for-byte")
  check(pal.read_file(ws .. "/art/hero.spr") == hero1,
        "clip: a nested asset materializes at its A-frame version (v1)")
  check(not pal.mtime(ws .. "/video.dat") and not pal.mtime(ws .. "/input.dat"),
        "clip: machine files never enter the materialized tree")

  -- a second clip of the same tree reuses/replaces cleanly; the workspace root
  -- keeps at most one materialized tree (ephemeral).
  local ws2 = trace.materialize_clip(clip)
  check(ws2 == ws, "clip: an identical clip maps to the same content-named workspace")
  local tops = {}
  for _, n in ipairs(pal.list_dir(wsroot) or {}) do
    tops[(n:match("^[^/]+"))] = true
  end
  local ntop = 0; for _ in pairs(tops) do ntop = ntop + 1 end
  check(ntop == 1, "clip: the workspace root retains a single ephemeral tree")

  -- ---- a plain export carries no standalone chunks (goldens hold) ----
  local plain = root .. "/plain.ctrace"
  trace.ring_export(plain)
  local std = false
  for _, c in ipairs(chunk.read(pal.read_file(plain) or "", "CTRC")) do
    if c.tag == "MFST" or c.tag == "BLOB" or c.tag == "LOOP" then std = true end
  end
  check(not std, "clip: a plain ring_export embeds no MFST/BLOB/LOOP")

  -- ---- adopted cross-session range: reconstruct its code bundle (§14) ----
  -- Its opening segment carries NO live bundle (the adopted session's code was
  -- never spilled), but the manifest froze every project .lua at the keyframe.
  -- export_clip rebuilds the SNAP code from that captured tree + the host engine,
  -- so a cross-session range is now a standalone clip too.
  drive(17, 24); trace.history_drain()
  -- edit main.lua on disk AFTER the keyframe: the reconstruction must use the
  -- manifest's captured source, never the mutated disk.
  pal.write_file(root .. "/main.lua", "return { edited = true }\n")
  trace.ring_start({ project = root }) -- reboot: the retained chain adopts
  local alo = trace.ring_range()
  check(not trace._R.segs[1].bundle,
        "clip: the adopted opening segment truly carries no live code bundle")
  local adclip = root .. "/adopted.ctrace"
  local ok_ad = trace.export_clip(alo, alo + 3, adclip)
  check(ok_ad, "clip: an adopted cross-session range now exports (bundle reconstructed)")
  -- inspect the reconstructed SNAP bundle: project 'main' at its CAPTURED source,
  -- the host engine modules, and the standalone tree/loop chunks.
  local ad_code, ad_mfst, ad_loop = nil, false, false
  for _, c in ipairs(chunk.read(pal.read_file(adclip) or "", "CTRC")) do
    if c.tag == "SNAP" then ad_code = cm.require("cm.state").parse_snapshot(c.payload).code end
    if c.tag == "MFST" then ad_mfst = true end
    if c.tag == "LOOP" then ad_loop = true end
  end
  local by = {}
  for _, m in ipairs(ad_code or {}) do by[m.name] = m.source end
  check(by.main == main_src,
        "clip: the reconstruction carries the captured project source, not disk")
  check(by["@boot"] and by["cm.trace"],
        "clip: the reconstruction carries the host engine modules (@boot + cm.*)")
  check(ad_mfst and ad_loop,
        "clip: the adopted clip is standalone (project tree + loop bounds)")
  -- round-trip: the adopted clip materializes its captured tree like any
  -- standalone clip — the reconstructed code + the frozen project, self-contained.
  local adws = trace.materialize_clip(adclip)
  check(adws and pal.read_file(adws .. "/main.lua") == main_src,
        "clip: the adopted clip materializes its captured project tree on load")
  -- the reconstructed SNAP is a valid, hashable code identity (D107) — proof the
  -- bundle is well-formed and loadable, not merely present; and a same-session
  -- self-export auto-trusts, so dragging this cross-session clip back never prompts.
  local ad_hash = trace.clip_code_hash(adclip)
  check(ad_hash and trace.clip_trusted(ad_hash),
        "clip: the reconstructed adopted clip has a trusted code identity (self-export)")

  -- spill-off (legacy / headless) history has no project manifest.
  trace.ring.spill = false
  sim:i64(0, f0); trace.ring_start({ project = root })
  for i = 1, 8 do b:i32(0, i); sim:i64(0, f0 + i); trace.record_frame(irec, nil) end
  local lo2, hi2 = trace.ring_range()
  local ok_lg, why_lg = trace.export_clip(lo2, hi2, root .. "/y.ctrace")
  check(not ok_lg and why_lg and why_lg:find("manifest"),
        "clip: export of manifest-less history names the legacy limit")

  -- leave a clean tree + ring behind
  wipe_hist(); wipe_ws()
  for _, n in ipairs({ "main.lua", "art/hero.spr", "art", "readme.txt",
      "video.dat", "input.dat", "range.ctrace", "plain.ctrace",
      "adopted.ctrace" }) do
    pal.x_remove(root .. "/" .. n)
  end
  trace._workspace_root = save_ws
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  sim:i64(0, f0)
  pal.buf_free("st.clip")
  trace.ring_start({ project = "selftest" })
end

local function t_clip_nondestructive()
  -- A7 §13: the drag-in replay opens a clip WITHOUT adopting its timeline. The
  -- ring layer proves the untouched-live promise: stash_live parks the live ring
  -- aside, ring_load lands the clip in a fresh ring (its own range + workspace),
  -- and restore_live puts the live ring back byte-for-byte, dropping the
  -- ephemeral workspace. (The present-state / editor-root halves are cm.scrub /
  -- cm.ed unit-checked below and exercised end-to-end by the windowed fixture.)
  local trace = cm.require("cm.trace")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local save_ws = trace._workspace_root
  local root = tmproot() .. "/cosmic_selftest_clipnd"
  local wsroot = tmproot() .. "/cosmic_selftest_clipndws"
  pal.mkdir(root)
  local function wipe_hist()
    local ns = pal.list_dir(root .. "/.ed/history") or {}
    for i = #ns, 1, -1 do pal.x_remove(root .. "/.ed/history/" .. ns[i]) end
    pal.x_remove(root .. "/.ed/history/blobs")
    pal.x_remove(root .. "/.ed/history")
  end
  local function wipe_ws()
    local ns = pal.x_list_dir_all and pal.x_list_dir_all(wsroot) or {}
    for i = #ns, 1, -1 do pal.x_remove(wsroot .. "/" .. ns[i]) end
    pal.x_remove(wsroot)
  end
  wipe_hist(); wipe_ws()

  pal.write_file(root .. "/main.lua", "return {}\n")
  pal.mkdir(root .. "/art")
  pal.write_file(root .. "/art/hero.spr", ("HERO"):rep(9))

  trace.ring.kf, trace.ring.seconds = 4, 30
  trace.ring.spill, trace.ring.budget_mb = true, 64
  trace._workspace_root = wsroot
  local b = pal.buf("st.clipnd", 8)
  local irec = ("\0"):rep(10)
  sim:i64(0, f0)
  trace.ring_start({ project = root })
  for i = 1, 16 do
    b:i32(0, i * 7); sim:i64(0, f0 + i); trace.record_frame(irec, nil)
  end
  trace.history_drain()

  -- a standalone clip of a sub-range, then capture the LIVE ring's identity
  local A, B = f0 + 3, f0 + 12
  local clip = root .. "/range.ctrace"
  check(trace.export_clip(A, B, clip), "clip-nd: export a standalone sub-range")
  local live_lo, live_hi = trace.ring_range()
  local live_mfst = trace.ring_manifest() and trace.ring_manifest()["main.lua"]
  local live_export = root .. "/before.ctrace"
  trace.ring_export(live_export)
  local before_bytes = pal.read_file(live_export)
  check(before_bytes and #before_bytes > 0, "clip-nd: captured the live ring bytes")

  -- ---- stash the live ring; load the clip into a fresh one ----
  check(trace.stash_live(), "clip-nd: stash_live parks the live ring")
  check(trace.has_stash(), "clip-nd: has_stash reports the parked live ring")
  check(trace.ring_range() == nil, "clip-nd: no live ring visible while stashed")
  local ok2, why2 = trace.stash_live()
  check(not ok2 and why2 and why2:find("already"),
        "clip-nd: a second stash is refused, not silently clobbering")

  trace.ring_load(clip)
  local rlo, rhi = trace.ring_range()
  check(rhi == B and rlo <= A,
        "clip-nd: the replay ring covers the clip's frames through B")
  local ws = trace.replay_workspace()
  check(ws and pal.read_file(ws .. "/main.lua") == "return {}\n",
        "clip-nd: the clip's project tree materialized into a workspace")
  check(trace.replay_loop() and trace.replay_loop().a == A
        and trace.replay_loop().b == B,
        "clip-nd: the clip's A/B loop bounds ride alongside")

  -- ---- restore the live ring: byte-identical, workspace swept ----
  check(trace.restore_live(), "clip-nd: restore_live swaps the live ring back")
  check(not trace.has_stash(), "clip-nd: the stash is consumed on restore")
  local rlo2, rhi2 = trace.ring_range()
  check(rlo2 == live_lo and rhi2 == live_hi,
        "clip-nd: the live range is exactly what it was before the clip")
  check((trace.ring_manifest() and trace.ring_manifest()["main.lua"]) == live_mfst,
        "clip-nd: the live project manifest is unchanged")
  local after_export = root .. "/after.ctrace"
  trace.ring_export(after_export)
  check(pal.read_file(after_export) == before_bytes,
        "clip-nd: the live ring exports byte-for-byte identically (untouched)")
  check(not pal.mtime(ws .. "/main.lua"),
        "clip-nd: the ephemeral replay workspace is swept on restore")
  local ok3, why3 = trace.restore_live()
  check(not ok3 and why3, "clip-nd: restore with nothing stashed is refused")

  -- ---- cm.ed root mount is a scoped, reversible swap ----
  local ed = cm.require("cm.ed")
  local was_root, was_stash, was_stashed =
    ed.root, ed.g.root_stash, ed.g.root_stashed
  ed.root, ed.g.root_stash, ed.g.root_stashed = "/live/project", nil, nil
  ed.mount_replay("/some/ws")
  check(ed.root == "/some/ws" and ed.g.root_stashed,
        "clip-nd: mount_replay swaps ed.root to the workspace")
  ed.mount_replay("/other/ws")
  check(ed.root == "/some/ws",
        "clip-nd: mount_replay is idempotent (no double-stash of the real root)")
  ed.unmount_replay()
  check(ed.root == "/live/project" and not ed.g.root_stashed,
        "clip-nd: unmount_replay restores the real project root")
  ed.unmount_replay()
  check(ed.root == "/live/project",
        "clip-nd: unmount with nothing mounted is a no-op")
  ed.root, ed.g.root_stash, ed.g.root_stashed = was_root, was_stash, was_stashed

  -- leave a clean tree + ring behind
  wipe_hist(); wipe_ws()
  for _, n in ipairs({ "main.lua", "art/hero.spr", "art", "range.ctrace",
      "before.ctrace", "after.ctrace" }) do
    pal.x_remove(root .. "/" .. n)
  end
  trace._workspace_root = save_ws
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  sim:i64(0, f0)
  pal.buf_free("st.clipnd")
  trace.ring_start({ project = "selftest" })
end

local function t_clip_lifecycle()
  -- A7 §13 integration: drive the REAL editor drag-in lifecycle headlessly.
  -- scrub.open_clip -> (chrome phase) do_load stashes the live ring, snapshots
  -- the present, ring_loads the clip and mounts its workspace; apply parks the
  -- editor onto the clip; scrub.close (is_clip -> close_clip) restores the
  -- present state, live ring, editor doc, and real project root WITHOUT adopting
  -- the replay. The imgui tray is chrome (verified windowed); this pins the
  -- state machine that must never let a replay become project state.
  local trace = cm.require("cm.trace")
  local scrub = cm.require("cm.scrub")
  local ed = cm.require("cm.ed")
  local state = cm.require("cm.state")
  local view = cm.require("cm.view")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)

  -- isolate: after_restore normally re-runs the game's init — here that IS this
  -- selftest, so stub it. Remember everything we perturb.
  local save_after = cm.main.after_restore
  local save_on, save_doc, save_root = ed.on, ed.doc, ed.root
  local save_mode = view.mode
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local save_ws = trace._workspace_root
  cm.main.after_restore = function() end

  local root = tmproot() .. "/cosmic_selftest_cliplife"
  local wsroot = tmproot() .. "/cosmic_selftest_cliplifews"
  pal.mkdir(root)
  local function wipe_hist()
    local ns = pal.list_dir(root .. "/.ed/history") or {}
    for i = #ns, 1, -1 do pal.x_remove(root .. "/.ed/history/" .. ns[i]) end
    pal.x_remove(root .. "/.ed/history/blobs")
    pal.x_remove(root .. "/.ed/history")
  end
  local function wipe_ws()
    local ns = pal.x_list_dir_all and pal.x_list_dir_all(wsroot) or {}
    for i = #ns, 1, -1 do pal.x_remove(wsroot .. "/" .. ns[i]) end
    pal.x_remove(wsroot)
  end
  wipe_hist(); wipe_ws()
  pal.write_file(root .. "/main.lua", "return {}\n")

  ed.launch(root) -- ed.on, ed.doc, ed.root = root
  check(ed.on and ed.root == root, "clip-life: editor launched on the project")

  trace.ring.kf, trace.ring.seconds = 4, 30
  trace.ring.spill, trace.ring.budget_mb = true, 64
  trace._workspace_root = wsroot
  local b = pal.buf("st.cliplife", 8)
  local irec = ("\0"):rep(10)
  sim:i64(0, f0)
  trace.ring_start({ project = root })
  for i = 1, 16 do
    b:i32(0, i * 7); sim:i64(0, f0 + i); trace.record_frame(irec, nil)
  end
  trace.history_drain()
  local A, B = f0 + 3, f0 + 12
  local clip = root .. "/range.ctrace"
  check(trace.export_clip(A, B, clip), "clip-life: exported an A..B clip")
  local live_lo, live_hi = trace.ring_range()

  -- a distinct live PRESENT: the buffer advanced past the last recorded frame.
  -- close must restore exactly this, not the replay's frame.
  local LIVE = 0x51192026
  b:i32(0, LIVE)

  -- ---- drop-in: open_clip queues; scrub.frame (chrome phase) loads it ----
  scrub.open_clip(clip)
  scrub.frame() -- do_load + apply(loop A) + ed.park; returns before the tray
  check(scrub.is_clip() and scrub.paused(),
        "clip-life: the clip opens as a paused, non-destructive replay")
  check(trace.has_stash(), "clip-life: the live ring is stashed, not replaced")
  check(ed.root == trace.replay_workspace() and ed.root ~= root,
        "clip-life: ed.root mounts the clip's materialized workspace")
  check(ed.parked, "clip-life: the editor is parked (edits stay ephemeral)")
  check(b:i32(0) ~= LIVE,
        "clip-life: the live buffers now show the replay frame, not the present")

  -- ---- dismiss: scrub.close routes to close_clip; live comes back intact ----
  local ws = trace.replay_workspace()
  scrub.close()
  check(not scrub.is_clip() and not scrub.paused() and not scrub.on,
        "clip-life: dismiss leaves no replay state")
  check(not trace.has_stash(), "clip-life: the stash is consumed on dismiss")
  check(ed.root == root, "clip-life: the real project root is restored")
  check(not ed.parked, "clip-life: the editor is unparked")
  local rlo, rhi = trace.ring_range()
  check(rlo == live_lo and rhi == live_hi,
        "clip-life: the live ring range is exactly what it was")
  check(b:i32(0) == LIVE,
        "clip-life: the live PRESENT buffer is restored, not the replay's")
  check(ws and not pal.mtime(ws .. "/main.lua"),
        "clip-life: the ephemeral replay workspace is swept on dismiss")

  -- restore the world for the tests that follow
  wipe_hist(); wipe_ws()
  pal.x_remove(root .. "/main.lua")
  pal.x_remove(root .. "/range.ctrace")
  ed.on, ed.doc, ed.root = save_on, save_doc, save_root
  ed.parked, ed.g.stash = false, nil
  ed.g.root_stash, ed.g.root_stashed = nil, nil
  view.mode = save_mode
  cm.main.after_restore = save_after
  trace._workspace_root = save_ws
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  scrub.live_snap = nil
  sim:i64(0, f0)
  pal.buf_free("st.cliplife")
  trace.ring_start({ project = "selftest" })
end

local function t_crash_resolve()
  -- A7 §16: crash_resolve matches a dropped report to the live ring by EXACT
  -- identity (history stream + last-committed frame) and returns the safe
  -- pre-roll bounds ending at that frame plus the failed next-frame boundary.
  -- It never guesses by wall time: a foreign stream / evicted frame / stream-
  -- less report is refused with an honest reason.
  local trace = cm.require("cm.trace")
  local sim = pal.buf("cm.sim", 64)
  local realf0 = sim:i64(0)
  -- a high base so "a frame below the retained range" is a valid, non-negative
  -- frame (the eviction case must not collide with the stream-less <0 case)
  local base = realf0 + 100000
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local root = tmproot() .. "/cosmic_selftest_crashres"
  pal.mkdir(root)
  local function wipe_hist()
    local ns = pal.list_dir(root .. "/.ed/history") or {}
    for i = #ns, 1, -1 do pal.x_remove(root .. "/.ed/history/" .. ns[i]) end
    pal.x_remove(root .. "/.ed/history/blobs")
    pal.x_remove(root .. "/.ed/history")
  end
  wipe_hist()
  pal.write_file(root .. "/main.lua", "return {}\n")

  trace.ring.kf, trace.ring.seconds = 4, 30
  trace.ring.spill, trace.ring.budget_mb = true, 64
  local b = pal.buf("st.crashres", 8)
  local irec = ("\0"):rep(10)
  sim:i64(0, base)
  trace.ring_start({ project = root })
  for i = 1, 40 do
    b:i32(0, i * 5); sim:i64(0, base + i); trace.record_frame(irec, nil)
  end
  trace.history_drain()
  local lo, hi = trace.ring_range()
  local stream = trace.ring_locator().stream
  check(stream ~= "" and lo == base and hi == base + 40,
        "crash-res: the live ring has a durable stream over base..base+40")

  -- an exact match: committed mid-stream, a short pre-roll
  local committed = base + 30
  local plan = trace.crash_resolve(
    { history_stream = stream, committed_frame = committed,
      attempted_frame = committed + 1, error_kind = "sim.step" }, 10)
  check(plan and plan.b == committed and plan.a == committed - 9,
        "crash-res: the pre-roll is [committed-preroll+1 .. committed]")
  check(plan.attempted == committed + 1,
        "crash-res: the failed next-frame boundary is committed+1")
  check(plan.kind == "sim.step", "crash-res: the plan carries the error kind")

  -- the pre-roll clamps to the retained low edge, never before frame lo
  local plan2 = trace.crash_resolve(
    { history_stream = stream, committed_frame = lo + 2 }, 60 * 60)
  check(plan2 and plan2.a == lo and plan2.b == lo + 2,
        "crash-res: the pre-roll clamps to the retained low edge")
  check(plan2.attempted == lo + 3,
        "crash-res: attempted defaults to committed+1 when the report omits it")

  -- a foreign stream: refused with an honest reason, never guessed by time
  local bad, why = trace.crash_resolve(
    { history_stream = "hs1-0000dead0000beef0000dead0000beef",
      committed_frame = committed })
  check(not bad and why and why:find("another recording"),
        "crash-res: a foreign stream is refused, not guessed by time")

  -- a frame below the retained range: refused as evicted, honestly
  local ev, evwhy = trace.crash_resolve(
    { history_stream = stream, committed_frame = lo - 5 })
  check(not ev and evwhy and evwhy:find("evicted"),
        "crash-res: a frame below the retained range reports eviction")

  -- no durable history named in the report (headless / boot failure): refused
  local nd, ndwhy = trace.crash_resolve(
    { history_stream = "", committed_frame = -1 })
  check(not nd and ndwhy and ndwhy:find("no durable history"),
        "crash-res: an empty stream / -1 frame is unresolvable")

  -- a committed frame past the live edge clamps to it (a stale over-count can
  -- never push the focus past the present)
  local plan3 = trace.crash_resolve(
    { history_stream = stream, committed_frame = hi + 100 }, 10)
  check(plan3 and plan3.b == hi and plan3.committed == hi
        and plan3.attempted == hi + 1,
        "crash-res: a committed frame past the live edge clamps to it")

  wipe_hist()
  pal.x_remove(root .. "/main.lua")
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  sim:i64(0, realf0)
  pal.buf_free("st.crashres")
  trace.ring_start({ project = "selftest" })
end

local function t_crash_focus()
  -- A7 §16 integration: drive the REAL crash-report drop lifecycle headlessly.
  -- rewind.drop_crash reads a .ccrash, resolves it against the LIVE ring by
  -- identity, parks + loops the safe pre-roll, and marks the failed boundary --
  -- WITHOUT stashing the live ring (unlike a clip). Esc layering clears the loop
  -- first, then returns to live. A foreign report never parks. This pins the
  -- state machine; the imgui tray is chrome (verified windowed).
  local trace = cm.require("cm.trace")
  local scrub = cm.require("cm.scrub")
  local ed = cm.require("cm.ed")
  local view = cm.require("cm.view")
  local crash = cm.require("cm.crash")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)

  local save_after = cm.main.after_restore
  local save_on, save_doc, save_root = ed.on, ed.doc, ed.root
  local save_mode = view.mode
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  cm.main.after_restore = function() end

  local root = tmproot() .. "/cosmic_selftest_crashfocus"
  pal.mkdir(root)
  local function wipe_hist()
    local ns = pal.list_dir(root .. "/.ed/history") or {}
    for i = #ns, 1, -1 do pal.x_remove(root .. "/.ed/history/" .. ns[i]) end
    pal.x_remove(root .. "/.ed/history/blobs")
    pal.x_remove(root .. "/.ed/history")
  end
  wipe_hist()
  pal.write_file(root .. "/main.lua", "return {}\n")

  ed.launch(root)
  check(ed.on and ed.root == root, "crash-focus: editor launched on the project")

  trace.ring.kf, trace.ring.seconds = 4, 30
  trace.ring.spill, trace.ring.budget_mb = true, 64
  local b = pal.buf("st.crashfocus", 8)
  local irec = ("\0"):rep(10)
  sim:i64(0, f0)
  trace.ring_start({ project = root })
  for i = 1, 40 do
    b:i32(0, i * 5); sim:i64(0, f0 + i); trace.record_frame(irec, nil)
  end
  trace.history_drain()
  local lo, hi = trace.ring_range()
  local stream = trace.ring_locator().stream
  local r = ed.g.rw or {} -- the tray's chrome state (drop_crash creates it)

  local function write_ccrash(name, o)
    local path = root .. "/" .. name
    pal.write_file(path, crash.encode(o))
    return path
  end

  -- ---- a foreign report never parks the live session ----
  local foreign = write_ccrash("foreign.ccrash", {
    report_id = "cr1-foreign", project_path = root, project_name = "cf",
    history_stream = "hs1-1111face1111face1111face1111face",
    committed_frame = hi - 3, attempted_frame = hi - 2, error_kind = "sim.step" })
  check(not cm.require("cm.ed.rewind").drop_crash(ed, foreign),
        "crash-focus: a foreign-stream report is refused")
  check(not scrub.paused() and not (ed.g.rw and ed.g.rw.crash),
        "crash-focus: a refused crash never parks and sets no focus")

  -- ---- a matching report opens the crashed minute as an A/B loop ----
  local committed = hi - 4
  local report = write_ccrash("boom.ccrash", {
    report_id = "cr1-boom", project_path = root, project_name = "cf",
    history_stream = stream, committed_frame = committed,
    attempted_frame = committed + 1, code_epoch = 0, error_kind = "sim.step",
    traceback = "attempt to index a nil value", log_path = "" })
  check(cm.require("cm.ed.rewind").drop_crash(ed, report),
        "crash-focus: a matching report opens the crash focus")
  r = ed.g.rw
  check(scrub.paused() and not scrub.is_clip(),
        "crash-focus: the live source is parked in place, NOT opened as a clip")
  check(not trace.has_stash(),
        "crash-focus: the live ring is resolved in place, never stashed")
  local la, lb = scrub.loop_range()
  check(la == lo and lb == committed,
        "crash-focus: the pre-roll loops [retained-lo .. last committed frame]")
  check(r.crash and r.crash.committed == committed
        and r.crash.attempted == committed + 1 and r.crash.kind == "sim.step",
        "crash-focus: the tray marks the failed next-frame boundary")

  -- ---- Esc #1 clears the loop but keeps the crash view ----
  cm.require("cm.ed.rewind").escape(ed)
  check(not scrub.has_loop() and scrub.paused() and r.crash,
        "crash-focus: Esc clears the loop but stays in the crash view")

  -- ---- Esc #2 returns to live, focus dismissed, ring intact ----
  cm.require("cm.ed.rewind").escape(ed)
  check(not scrub.paused() and not scrub.on,
        "crash-focus: a second Esc returns to the live session")
  check(not (ed.g.rw and ed.g.rw.crash),
        "crash-focus: the crash focus is dismissed on close")
  local rlo, rhi = trace.ring_range()
  check(rlo == lo and rhi == hi,
        "crash-focus: the live ring range is exactly what it was")

  wipe_hist()
  pal.x_remove(root .. "/main.lua")
  for _, n in ipairs({ "foreign.ccrash", "boom.ccrash" }) do
    pal.x_remove(root .. "/" .. n)
  end
  ed.on, ed.doc, ed.root = save_on, save_doc, save_root
  ed.parked, ed.g.stash = false, nil
  ed.g.root_stash, ed.g.root_stashed = nil, nil
  if ed.g.rw then ed.g.rw.crash, ed.g.rw.open = nil, nil end
  view.mode = save_mode
  cm.main.after_restore = save_after
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  sim:i64(0, f0)
  pal.buf_free("st.crashfocus")
  trace.ring_start({ project = "selftest" })
end

local function t_clip_trust()
  -- A7 §13 trust: opening a dragged-in clip RUNS its bundled code with the
  -- open-a-project boundary, so the drop door identifies that code WITHOUT
  -- executing it and asks before the first run. Identity = the SNAP bundle +
  -- every EPOC revision (module name + source; recorded paths are machine-
  -- local noise). write_trace pre-trusts everything this session wrote (a
  -- self-export never prompts); an explicit confirm trusts a foreign identity
  -- for the rest of the session; cancel runs nothing. The imgui prompt panel
  -- is chrome (verified windowed); this pins the identity math + state machine.
  local trace = cm.require("cm.trace")
  local scrub = cm.require("cm.scrub")
  local ed = cm.require("cm.ed")
  local view = cm.require("cm.view")
  local rewind = cm.require("cm.ed.rewind")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)

  local save_after = cm.main.after_restore
  local save_on, save_doc, save_root = ed.on, ed.doc, ed.root
  local save_mode = view.mode
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local save_ws = trace._workspace_root
  cm.main.after_restore = function() end

  local root = tmproot() .. "/cosmic_selftest_cliptrust"
  local wsroot = tmproot() .. "/cosmic_selftest_cliptrustws"
  pal.mkdir(root)
  local function wipe_hist()
    local ns = pal.list_dir(root .. "/.ed/history") or {}
    for i = #ns, 1, -1 do pal.x_remove(root .. "/.ed/history/" .. ns[i]) end
    pal.x_remove(root .. "/.ed/history/blobs")
    pal.x_remove(root .. "/.ed/history")
  end
  local function wipe_ws()
    local ns = pal.x_list_dir_all and pal.x_list_dir_all(wsroot) or {}
    for i = #ns, 1, -1 do pal.x_remove(wsroot .. "/" .. ns[i]) end
    pal.x_remove(wsroot)
  end
  wipe_hist(); wipe_ws()
  pal.write_file(root .. "/main.lua", "return {}\n")

  ed.launch(root)
  trace.ring.kf, trace.ring.seconds = 4, 30
  trace.ring.spill, trace.ring.budget_mb = true, 64
  trace._workspace_root = wsroot
  local b = pal.buf("st.cliptrust", 8)
  local irec = ("\0"):rep(10)
  sim:i64(0, f0)
  trace.ring_start({ project = root })
  for i = 1, 16 do
    b:i32(0, i * 3); sim:i64(0, f0 + i); trace.record_frame(irec, nil)
  end
  trace.history_drain()
  local clip = root .. "/trust.ctrace"
  check(trace.export_clip(f0 + 3, f0 + 12, clip), "clip-trust: exported a clip")
  local live_lo, live_hi = trace.ring_range()

  -- ---- identity: computed without executing, stable, EPOC-sensitive ----
  local h1 = trace.clip_code_hash(clip)
  check(type(h1) == "string" and #h1 == 64 and h1:match("^%x+$") ~= nil,
        "clip-trust: the code identity is a sha256 hex digest")
  check(trace.clip_code_hash(clip) == h1,
        "clip-trust: the identity is deterministic")
  -- an appended EPOC is code a replay would ALSO run: it must change identity
  local blob = pal.read_file(clip)
  local function epoc_chunk(fpath)
    local p = string.pack("<I4", 1)
              .. string.pack("<s4s4s4", "cm.evil", fpath, "return {}")
    return "EPOC" .. string.pack("<I4I4", 1, #p) .. p
  end
  local tampered = root .. "/tampered.ctrace"
  pal.write_file(tampered, blob .. epoc_chunk("/x"))
  local h2 = trace.clip_code_hash(tampered)
  check(h2 ~= nil and h2 ~= h1,
        "clip-trust: an appended EPOC revision changes the identity")
  local tampered2 = root .. "/tampered2.ctrace"
  pal.write_file(tampered2, blob .. epoc_chunk("/elsewhere"))
  check(trace.clip_code_hash(tampered2) == h2,
        "clip-trust: the recorded file path never enters the identity")

  -- ---- refusals: bytes that can't be a replay name the reason ----
  local none, nwhy = trace.clip_code_hash(root .. "/absent.ctrace")
  check(none == nil and nwhy ~= nil and nwhy:find("read") ~= nil,
        "clip-trust: a missing file refuses with the reason")
  pal.write_file(root .. "/junk.ctrace", "not a container")
  local j, jwhy = trace.clip_code_hash(root .. "/junk.ctrace")
  check(j == nil and jwhy ~= nil,
        "clip-trust: junk bytes refuse (bad container)")
  local w = cm.require("cm.chunk").writer("CTRC")
  w.chunk("HEAD", 1, "")
  pal.write_file(root .. "/nosnap.ctrace", w.result())
  local s, swhy = trace.clip_code_hash(root .. "/nosnap.ctrace")
  check(s == nil and swhy ~= nil and swhy:find("SNAP") ~= nil,
        "clip-trust: a SNAP-less container refuses honestly")

  -- ---- the session trust set ----
  check(trace.clip_trusted(h1),
        "clip-trust: this session's own export is pre-trusted (write_trace)")
  trace._trust_reset()
  check(not trace.clip_trusted(h1),
        "clip-trust: a fresh session trusts nothing")
  check(not trace.clip_trusted(nil),
        "clip-trust: a nil identity is never trusted")
  trace.trust_clip(h1)
  check(trace.clip_trusted(h1), "clip-trust: an explicit confirm trusts")

  -- ---- the drop door: untrusted parks a prompt; nothing runs ----
  trace._trust_reset()
  check(not rewind.drop_clip(ed, clip),
        "clip-trust: an untrusted drop does NOT open the clip")
  local r = ed.g.rw
  check(r ~= nil and r.trust ~= nil and r.trust.hash == h1
        and r.trust.path == clip,
        "clip-trust: the drop parks a pending prompt naming the clip")
  check(not scrub.on and not trace.has_stash(),
        "clip-trust: nothing was stashed, mounted, or run")
  check(rewind.escape(ed) and r.trust == nil,
        "clip-trust: Esc cancels the prompt first")
  check(not scrub.on and not trace.has_stash(),
        "clip-trust: cancel runs nothing")
  rewind.drop_clip(ed, clip)
  check(r.trust ~= nil,
        "clip-trust: a later drop asks again (cancel is not distrust-forever)")

  -- ---- confirm: trust_run opens through the same door ----
  check(rewind.trust_run(ed), "clip-trust: run confirms and opens the clip")
  check(r.trust == nil, "clip-trust: the prompt is consumed by run")
  scrub.frame() -- chrome phase: do_load stashes the live ring + mounts
  check(scrub.is_clip() and trace.has_stash(),
        "clip-trust: the confirmed clip opens as the normal editor clip")
  scrub.close()
  local rlo, rhi = trace.ring_range()
  check(not scrub.is_clip() and not trace.has_stash()
        and rlo == live_lo and rhi == live_hi,
        "clip-trust: dismissal restores the untouched live ring")

  -- ---- the confirmed identity stays trusted for the session ----
  check(rewind.drop_clip(ed, clip) and r.trust == nil,
        "clip-trust: a re-drop of the confirmed identity opens directly")
  scrub.frame()
  check(scrub.is_clip(), "clip-trust: ...as a mounted clip")
  scrub.close()

  -- restore the world for the tests that follow
  trace._trust_reset()
  wipe_hist(); wipe_ws()
  for _, n in ipairs({ "main.lua", "trust.ctrace", "tampered.ctrace",
      "tampered2.ctrace", "junk.ctrace", "nosnap.ctrace" }) do
    pal.x_remove(root .. "/" .. n)
  end
  ed.on, ed.doc, ed.root = save_on, save_doc, save_root
  ed.parked, ed.g.stash = false, nil
  ed.g.root_stash, ed.g.root_stashed = nil, nil
  if ed.g.rw then
    ed.g.rw.trust, ed.g.rw.trust_rect = nil, nil
    ed.g.rw.crash, ed.g.rw.open = nil, nil
  end
  view.mode = save_mode
  cm.main.after_restore = save_after
  trace._workspace_root = save_ws
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  scrub.live_snap = nil
  sim:i64(0, f0)
  pal.buf_free("st.cliptrust")
  trace.ring_start({ project = "selftest" })
end

local function t_crash_tail()
  -- A7 §16: a .ccrash may EMBED its one-minute history tail as a self-contained
  -- standalone clip, so a report opened on ANOTHER machine (or after the local
  -- tail is evicted) still carries its timeline. crash_tail_bytes packs the safe
  -- pre-roll like export_clip (in memory); the drop stages it and opens it
  -- through the SAME trust-gated clip door, flavored CRASH. This pins the byte
  -- production + the drop/trust/Esc state machine; the imgui tray is chrome.
  local trace = cm.require("cm.trace")
  local scrub = cm.require("cm.scrub")
  local ed = cm.require("cm.ed")
  local view = cm.require("cm.view")
  local rewind = cm.require("cm.ed.rewind")
  local crash = cm.require("cm.crash")
  local chunk = cm.require("cm.chunk")
  local sim = pal.buf("cm.sim", 64)
  local f0 = sim:i64(0)

  local save_after = cm.main.after_restore
  local save_on, save_doc, save_root = ed.on, ed.doc, ed.root
  local save_mode = view.mode
  local save_kf, save_sec = trace.ring.kf, trace.ring.seconds
  local save_spill, save_mb = trace.ring.spill, trace.ring.budget_mb
  local save_ws, save_ct = trace._workspace_root, trace._crash_tail_root
  cm.main.after_restore = function() end

  local root = tmproot() .. "/cosmic_selftest_crashtail"
  local wsroot = tmproot() .. "/cosmic_selftest_crashtailws"
  local ctroot = tmproot() .. "/cosmic_selftest_crashtailct"
  pal.mkdir(root)
  local function wipe_hist()
    local ns = pal.list_dir(root .. "/.ed/history") or {}
    for i = #ns, 1, -1 do pal.x_remove(root .. "/.ed/history/" .. ns[i]) end
    pal.x_remove(root .. "/.ed/history/blobs")
    pal.x_remove(root .. "/.ed/history")
  end
  local function wipe_dir(d)
    local ns = pal.x_list_dir_all and pal.x_list_dir_all(d) or {}
    for i = #ns, 1, -1 do pal.x_remove(d .. "/" .. ns[i]) end
    pal.x_remove(d)
  end
  wipe_hist(); wipe_dir(wsroot); wipe_dir(ctroot)
  pal.write_file(root .. "/main.lua", "return {}\n")

  ed.launch(root)
  trace.ring.kf, trace.ring.seconds = 4, 30
  trace.ring.spill, trace.ring.budget_mb = true, 64
  trace._workspace_root, trace._crash_tail_root = wsroot, ctroot
  local b = pal.buf("st.crashtail", 8)
  local irec = ("\0"):rep(10)
  sim:i64(0, f0)
  trace.ring_start({ project = root })
  for i = 1, 24 do
    b:i32(0, i * 5); sim:i64(0, f0 + i); trace.record_frame(irec, nil)
  end
  trace.history_drain()
  local live_lo, live_hi = trace.ring_range()
  local stream = trace.ring_locator().stream

  -- ---- crash_tail_bytes: a self-contained standalone clip over the pre-roll ----
  local committed = live_hi - 2
  local blob, frames = trace.crash_tail_bytes(committed, 8) -- an 8-frame pre-roll
  check(type(blob) == "string" and frames and frames > 0,
        "crash-tail: crash_tail_bytes packs the pre-roll as clip bytes")
  local has_snap, has_mfst, loopa, loopb = false, false, nil, nil
  for _, c in ipairs(chunk.read(blob, "CTRC")) do
    if c.tag == "SNAP" then has_snap = true end
    if c.tag == "MFST" then has_mfst = true end
    if c.tag == "LOOP" then loopa, loopb = string.unpack("<I4I4", c.payload) end
  end
  check(has_snap and has_mfst and loopa ~= nil,
        "crash-tail: the tail is a standalone clip (SNAP + project tree + LOOP)")
  check(loopb == committed and loopa == committed - 7,
        "crash-tail: LOOP is the safe pre-roll ending at the last committed frame")

  -- ---- write_crash_tail stages it where the trust-gated clip door reads it ----
  local staged = trace.write_crash_tail(blob)
  check(staged and staged:find(ctroot, 1, true) == 1
        and staged:match("%.ctrace$"),
        "crash-tail: write_crash_tail stages the tail under the per-user root")
  local hash = trace.clip_code_hash(staged)
  check(hash and trace.clip_trusted(hash),
        "crash-tail: this session's own crash tail is pre-trusted (self-export)")

  -- ---- the CLIP chunk round-trips through the .ccrash container ----
  local report_o = {
    report_id = "cr1-tail", project_path = root, project_name = "ct",
    history_stream = stream, committed_frame = committed,
    attempted_frame = committed + 1, error_kind = "sim.step",
    traceback = "boom", tail = blob }
  check(crash.decode(crash.encode(report_o)).tail == blob,
        "crash-tail: the additive CLIP chunk round-trips the embedded tail")
  local ccrash = root .. "/boom.ccrash"
  pal.write_file(ccrash, crash.encode(report_o))

  -- ---- drop it (self-trusted): opens directly as a CRASH-flavored clip ----
  check(rewind.drop_crash(ed, ccrash),
        "crash-tail: a report with an embedded tail opens directly (self-trusted)")
  local r = ed.g.rw
  check(r.crash and r.crash.committed == committed
        and r.crash.attempted == committed + 1 and r.crash.kind == "sim.step",
        "crash-tail: the drop flavors the clip CRASH (failed boundary marked)")
  scrub.frame() -- chrome phase: do_load stashes live + mounts the tail clip
  check(scrub.is_clip() and trace.has_stash(),
        "crash-tail: the embedded tail opens as an ephemeral clip (live stashed)")
  local la, lb = scrub.loop_range()
  check(la == loopa and lb == loopb,
        "crash-tail: the crash clip loops the embedded pre-roll bounds")
  local ws = trace.replay_workspace()
  check(ws and pal.read_file(ws .. "/main.lua") == "return {}\n",
        "crash-tail: the crash clip mounts its bundled project ephemerally")

  -- ---- Esc layering: clear the loop, then eject back to the untouched live ----
  rewind.escape(ed)
  check(not scrub.has_loop() and scrub.is_clip() and r.crash,
        "crash-tail: Esc clears the loop but keeps the crash clip")
  -- the A7 dismissal guard covers the MOUNTED CLIP itself, not only the
  -- loop: F4 (toggle -> close without force) must refuse to eject it
  check(not rewind.toggle(ed) and scrub.is_clip() and rewind.opened(ed),
        "crash-tail: F4 cannot eject a mounted clip after the loop clears")
  rewind.escape(ed)
  check(not scrub.is_clip() and not trace.has_stash()
        and not (ed.g.rw and ed.g.rw.crash),
        "crash-tail: a second Esc ejects to live; the crash focus is dismissed")
  local rlo, rhi = trace.ring_range()
  check(rlo == live_lo and rhi == live_hi,
        "crash-tail: the live ring is byte-untouched after the crash clip")

  -- ---- an UNTRUSTED (foreign-session) tail parks the CRASH trust prompt ----
  trace._trust_reset()
  check(not rewind.drop_crash(ed, ccrash),
        "crash-tail: an untrusted embedded tail does NOT open the clip")
  check(r.trust and r.trust.hash == hash and r.trust.crash
        and r.trust.crash.kind == "sim.step",
        "crash-tail: it parks a CRASH-flavored trust prompt naming the tail")
  check(not scrub.is_clip() and not trace.has_stash(),
        "crash-tail: nothing was stashed, mounted, or run before the confirm")
  check(rewind.trust_run(ed) and r.trust == nil and r.crash
        and r.crash.kind == "sim.step",
        "crash-tail: trust_run confirms and re-opens still flavored CRASH")
  scrub.frame()
  check(scrub.is_clip() and trace.has_stash(),
        "crash-tail: the confirmed crash tail opens as an ephemeral clip")
  scrub.close()
  check(not scrub.is_clip() and not trace.has_stash(),
        "crash-tail: dismissal restores the live ring")

  -- ---- a locator-only report still resolves the local stream IN PLACE (D106) --
  local plain = root .. "/plain.ccrash"
  pal.write_file(plain, crash.encode({
    report_id = "cr1-plain", project_path = root, project_name = "ct",
    history_stream = stream, committed_frame = committed,
    attempted_frame = committed + 1, error_kind = "sim.step" }))
  check(rewind.drop_crash(ed, plain) and scrub.paused()
        and not scrub.is_clip() and not trace.has_stash(),
        "crash-tail: a locator-only report resolves the local stream in place")
  rewind.escape(ed); rewind.escape(ed)

  -- ---- refusal: spill-off history embeds no tail (legacy limit, named) ----
  trace.ring.spill = false
  sim:i64(0, f0); trace.ring_start({ project = root })
  for i = 1, 8 do b:i32(0, i); sim:i64(0, f0 + i); trace.record_frame(irec, nil) end
  local no, nowhy = trace.crash_tail_bytes(select(2, trace.ring_range()))
  check(not no and nowhy and nowhy:find("manifest"),
        "crash-tail: spill-off history embeds no tail (names the legacy limit)")

  -- restore the world for the tests that follow
  trace._trust_reset()
  wipe_hist(); wipe_dir(wsroot); wipe_dir(ctroot)
  for _, n in ipairs({ "main.lua", "boom.ccrash", "plain.ccrash" }) do
    pal.x_remove(root .. "/" .. n)
  end
  ed.on, ed.doc, ed.root = save_on, save_doc, save_root
  ed.parked, ed.g.stash = false, nil
  ed.g.root_stash, ed.g.root_stashed = nil, nil
  if ed.g.rw then
    ed.g.rw.trust, ed.g.rw.trust_rect = nil, nil
    ed.g.rw.crash, ed.g.rw.open, ed.g.rw.fit_crash = nil, nil, nil
  end
  view.mode = save_mode
  cm.main.after_restore = save_after
  trace._workspace_root, trace._crash_tail_root = save_ws, save_ct
  trace.ring.kf, trace.ring.seconds = save_kf, save_sec
  trace.ring.spill, trace.ring.budget_mb = save_spill, save_mb
  scrub.live_snap = nil
  sim:i64(0, f0)
  pal.buf_free("st.crashtail")
  trace.ring_start({ project = "selftest" })
end

local function t_ed_domain()
  -- the ed.* buffer domain is invisible to sim snapshots + traces (D050)
  local state = cm.require("cm.state")
  check(state.sim_buffer("cm.sim") and state.sim_buffer("smoke.player"),
        "ed domain: sim names pass")
  check(not state.sim_buffer("ed.text") and not state.sim_buffer("ed."),
        "ed domain: ed.* names excluded")
  check(state.sim_buffer("edit.thing") and state.sim_buffer("ed"),
        "ed domain: only the exact ed. prefix excludes")
  -- the render-class domain (D3D-012, merged with the 3d fork): rc.* holds
  -- PAL resource ids + draw scratch — session-dependent bytes that must
  -- never enter a snapshot, trace or golden
  check(not state.sim_buffer("rc.mesh") and not state.sim_buffer("rc."),
        "rc domain: rc.* names excluded")
  check(state.sim_buffer("rcx.thing") and state.sim_buffer("rc"),
        "rc domain: only the exact rc. prefix excludes")

  local v = pal.buf("ed.selftest", 16)
  v:u32(0, 0xdeadbeef)
  local rcv = pal.buf("rc.selftest", 16)
  rcv:u32(0, 0xfeedface)
  local snap = state.parse_snapshot(state.snapshot())
  for _, b in ipairs(snap.bufs) do
    check(b.name ~= "ed.selftest", "ed domain: snapshot excludes ed.*")
    check(b.name ~= "rc.selftest", "rc domain: snapshot excludes rc.*")
  end
  pal.buf_free("rc.selftest")
  -- restore of a snapshot without the ed buffer must not free it
  state.restore_tables((function()
    local m = {}
    for _, b in ipairs(snap.bufs) do m[b.name] = b.bytes end
    return m
  end)(), snap.doct)
  local still = false
  for _, b in ipairs(pal.buf_list()) do
    if b.name == "ed.selftest" then still = true end
  end
  check(still and pal.buf("ed.selftest", 16):u32(0) == 0xdeadbeef,
        "ed domain: restore leaves ed.* alone")
  pal.buf_free("ed.selftest")

  -- headless absence: the shell frame is a no-op without an ig surface
  local ed = cm.require("cm.ed")
  local was_on, was_doc, was_root = ed.on, ed.doc, ed.root
  local view = cm.require("cm.view")
  local was_mode = view.mode
  ed.launch(tmproot() .. "/cosmic_selftest_ed")
  ed.frame() -- x_ig_frame() is nil headless -> must return quietly
  check(ed.on and ed.doc ~= nil, "ed: launch loads a doc headless")
  ed.g.project_exports = { lifecycle = {
    job = { phase = "building", terminal = false }
  } }
  local switched, switch_err = ed.prepare_switch("returning to projects")
  check(not switched and ed.on and switch_err:find("cancel", 1, true),
        "ed lifecycle: active export guards return to picker")
  ed.g.project_exports.lifecycle.job.terminal = true

  -- the launcher's settings command (D132): the entry is listed and
  -- activating it summons the settings window — the editor's keyboard
  -- door to the knobs players reach in the Esc menu
  local L = cm.require("cm.ed.launcher")
  local cmd
  for _, e in ipairs(L.entries(ed)) do
    if e.cat == "cmd" and e.cmd == "options" then cmd = e end
  end
  check(cmd ~= nil, "launcher: the settings command is listed")
  L.activate(ed, cmd)
  local sw
  for _, w in ipairs(ed.doc.wins) do
    if w.kind == "settings" then sw = w end
  end
  check(sw ~= nil and ed.doc.focus == sw.id,
        "launcher: the settings command summons a focused settings window")
  L.activate(ed, cmd) -- summon again: focuses the SAME window, no twin
  local n = 0
  for _, w in ipairs(ed.doc.wins) do
    if w.kind == "settings" then n = n + 1 end
  end
  check(n == 1, "launcher: summon reuses the existing settings window")

  -- the overlay menu never opens under the editor shell (D132): the ui
  -- canvas composites beneath the imgui layer, so an "open" there would
  -- be invisible AND double-handle input — frame() forces it shut
  local options = cm.require("cm.options")
  options.on = true
  options.frame()
  check(options.on == false,
        "options: the overlay menu never opens under the editor shell")

  ed.kinds.project.drop_ephemeral(ed)
  ed.on, ed.doc, ed.root = was_on, was_doc, was_root
  view.mode = was_mode
end

-- ---- cm.docs: the A8 documentation search index (pure over supplied
-- markdown; only list() touches the filesystem, smoke-tested at the end) ----
local function t_docs()
  local docs = cm.require("cm.docs")

  -- a synthetic corpus (line numbers matter — they are the goto targets)
  local corpus = {
    { name = "alpha.md", title = "Alpha guide", src =
      "# Alpha guide\n" ..                                         -- 1
      "Intro line about widgets.\n" ..                             -- 2
      "\n" ..                                                      -- 3
      "## Camera (cm.camera)\n" ..                                 -- 4
      "The camera follows with a deadzone and shake.\n" ..         -- 5
      "Use camera.shake for screen shake.\n" ..                    -- 6
      "\n" ..                                                      -- 7
      "## Actors (cm.actor)\n" ..                                  -- 8
      "Actor worlds keep stable ids.\n" },                         -- 9
    { name = "beta.md", title = "Beta notes", src =
      "# Beta notes\n" ..                                          -- 1
      "```\n" ..                                                   -- 2
      "# this is a code comment, not a heading\n" ..               -- 3
      "```\n" ..                                                   -- 4
      "## Storage\n" ..                                            -- 5
      "Saves live outside the project. The camera is not here.\n" }, -- 6
    { name = "gamma.md", title = "Gamma", src =
      "Preamble before any heading mentions turtles.\n" ..         -- 1
      "# Gamma\n" ..                                               -- 2
      "Body about turtles and rockets.\n" },                       -- 3
  }
  local function find_src(name)
    for _, d in ipairs(corpus) do if d.name == name then return d.src end end
  end

  -- sections(): headings become numbered ranges; the lead is dropped when the
  -- doc opens on a heading, kept when there is real preamble
  local sa = docs.sections(find_src("alpha.md"))
  check(#sa == 3, "docs.sections: alpha has 3 heading sections (lead dropped)")
  check(sa[1].level == 1 and sa[1].title == "Alpha guide" and sa[1].line == 1
        and sa[1].lo == 1 and sa[1].hi == 3, "docs.sections: H1 range 1..3")
  check(sa[2].level == 2 and sa[2].title == "Camera (cm.camera)"
        and sa[2].line == 4 and sa[2].hi == 7, "docs.sections: Camera H2 4..7")
  check(sa[3].level == 2 and sa[3].line == 8 and sa[3].hi == 9,
        "docs.sections: Actors H2 8..9")
  -- a '#' inside a ``` fence is code, never a heading
  local sb = docs.sections(find_src("beta.md"))
  check(#sb == 2 and sb[2].title == "Storage",
        "docs.sections: fenced '# comment' does not split the doc")
  for _, s in ipairs(sb) do
    check(not s.title:find("code comment", 1, true),
          "docs.sections: the fenced comment is not a section title")
  end
  -- real preamble keeps the lead section (level 0)
  local sg = docs.sections(find_src("gamma.md"))
  check(sg[1].level == 0 and sg[1].lo == 1 and sg[1].hi == 1,
        "docs.sections: preamble keeps a level-0 lead")
  check(sg[2].level == 1 and sg[2].title == "Gamma" and sg[2].lo == 2,
        "docs.sections: heading after preamble")

  -- line_kinds(): the code/prose boundary the reader draws by. A 4-space
  -- indented block is code through EVERY line — nested-deeper lines and
  -- interior blanks — not just its first (the multi-line-code-block bug);
  -- ``` markers are drawn as nothing and a fenced body is code verbatim.
  local km = "# Title\n" ..                    -- 1  text (heading)
             "Intro paragraph.\n" ..           -- 2  text
             "\n" ..                           -- 3  text (gap before the block)
             "    local a = 1\n" ..            -- 4  code (4-space indent)
             "      nested = deeper\n" ..      -- 5  code (6-space — the bug)
             "\n" ..                           -- 6  code (interior blank)
             "    return a\n" ..               -- 7  code (block resumes at 4)
             "\n" ..                           -- 8  text (block ended -> gap)
             "- a bullet\n" ..                 -- 9  text (bullet)
             "```\n" ..                        -- 10 fence marker
             "# not a heading\n" ..            -- 11 code (fenced body)
             "\n" ..                           -- 12 code (fenced interior blank)
             "still fenced\n" ..               -- 13 code (fenced body)
             "```\n" ..                        -- 14 fence marker
             "Closing text.\n"                 -- 15 text
  local k = docs.line_kinds(km)
  check(k[1] == "text" and k[2] == "text" and k[3] == "text",
        "docs.line_kinds: heading/paragraph/leading gap are prose")
  check(k[4] == "code" and k[5] == "code" and k[7] == "code",
        "docs.line_kinds: an indented block is code through nested-deeper lines")
  check(k[6] == "code",
        "docs.line_kinds: a blank interior to an indented block stays code")
  check(k[8] == "text",
        "docs.line_kinds: the blank after the block ends is a prose gap")
  check(k[9] == "text", "docs.line_kinds: a bullet is prose")
  check(k[10] == "fence" and k[14] == "fence",
        "docs.line_kinds: ``` markers are fence lines (drawn as nothing)")
  check(k[11] == "code" and k[12] == "code" and k[13] == "code",
        "docs.line_kinds: fenced body — comment, blank, and text — is all code")
  check(k[15] == "text", "docs.line_kinds: text after the closing fence is prose")

  -- code_blocks(): the contiguous code runs the reader syntax-highlights and
  -- offers "copy" on, built ON line_kinds so the ranges agree with what's drawn.
  -- Over km: block 1 = the indented lua at 4..7, block 2 = the fenced body at
  -- 11..13 (the ``` markers are "fence", excluded from either run).
  local cb = docs.code_blocks(km)
  check(#cb == 2, "docs.code_blocks: two blocks (indented + fenced)")
  check(cb[1].lo == 4 and cb[1].hi == 7 and cb[1].lang == "lua",
        "docs.code_blocks: indented lua block spans 4..7")
  check(cb[1].text == "local a = 1\n  nested = deeper\n\nreturn a",
        "docs.code_blocks: dedented text keeps nested indent + interior blank")
  check(cb[2].lo == 11 and cb[2].hi == 13,
        "docs.code_blocks: fenced body is 11..13 (``` markers excluded)")
  check(cb[2].text == "# not a heading\n\nstill fenced",
        "docs.code_blocks: fenced body is copied verbatim")
  -- lang guess: a command sample (a path-command first token) is "text" so the
  -- lua lexer never mis-colors it; a real lua sample is "lua"
  local cshell = docs.code_blocks("Run it:\n\n    bin/cosmic projects/demo --edit\n")
  check(#cshell == 1 and cshell[1].lang == "text",
        "docs.code_blocks: a bin/… command block is text, not lua")
  local cpure = docs.code_blocks("    local x = cm.require('m')\n    return x\n")
  check(#cpure == 1 and cpure[1].lang == "lua" and cpure[1].hi == 2,
        "docs.code_blocks: a plain lua block is lua")

  -- section_at(): the heading owning a line
  check(docs.section_at(sa, 5).title == "Camera (cm.camera)",
        "docs.section_at: line 5 belongs to Camera")
  check(docs.section_at(sa, 1).title == "Alpha guide",
        "docs.section_at: line 1 belongs to the H1")
  check(docs.section_at(sa, 9).title == "Actors (cm.actor)",
        "docs.section_at: line 9 belongs to Actors")

  -- heading_slug(): the same slug both sides of an in-doc #anchor
  check(docs.heading_slug("Camera (cm.camera)") == "camera-cmcamera",
        "docs.heading_slug: punctuation dropped, spaces hyphenated")
  check(docs.heading_slug("Actors (cm.actor)") == "actors-cmactor",
        "docs.heading_slug: actors slug")

  -- search(): single term hitting a heading is a full section hit, ranked
  -- ahead of a body-only hit in another doc. The term is IN the Camera
  -- heading (line 4), so the hit lands on the heading itself.
  local r = docs.search("camera", corpus)
  check(#r == 2, "docs.search: 'camera' hits Camera + Storage sections")
  check(r[1].name == "alpha.md" and r[1].section == "Camera (cm.camera)"
        and r[1].line == 4, "docs.search: heading hit ranks first, lands on line 4")
  check(r[1].snippet:lower():find("camera", 1, true),
        "docs.search: the snippet carries the term")
  check(r[2].name == "beta.md" and r[2].section == "Storage" and r[2].line == 6,
        "docs.search: body-only hit ranks second")
  check(r[1].score > r[2].score, "docs.search: scores descend")

  -- multi-term AND: both terms co-occur in Camera; beta lacks 'shake' so the
  -- whole doc drops out (doc-level AND)
  local r2 = docs.search("camera shake", corpus)
  check(#r2 == 1 and r2[1].name == "alpha.md"
        and r2[1].section == "Camera (cm.camera)" and r2[1].line == 5,
        "docs.search: 'camera shake' -> only the section with both, line 5")
  check(r2[1].snippet:lower():find("shake", 1, true),
        "docs.search: multi-term snippet carries a term")

  -- scattered terms: alpha has 'widgets' (H1 body) and 'actors' (Actors head)
  -- in DIFFERENT sections; no section covers both, so the doc emits its single
  -- best-covering section (Actors, headed) once
  local r3 = docs.search("widgets actors", corpus)
  check(#r3 == 1 and r3[1].name == "alpha.md"
        and r3[1].section == "Actors (cm.actor)" and r3[1].line == 8,
        "docs.search: scattered terms fall back to one best section")

  -- a term only one doc has excludes the others entirely
  local r4 = docs.search("rockets", corpus)
  check(#r4 == 1 and r4[1].name == "gamma.md" and r4[1].section == "Gamma"
        and r4[1].line == 3, "docs.search: 'rockets' isolates gamma")

  -- literal matching: a query with pattern metacharacters is matched plainly,
  -- not as a Lua pattern (would error or mis-match otherwise)
  check(docs.search("cm.actor", corpus)[1].section == "Actors (cm.actor)",
        "docs.search: 'cm.actor' matches literally")
  local rp = docs.search("(cm.camera)", corpus)
  check(#rp >= 1 and rp[1].name == "alpha.md",
        "docs.search: parenthesised query does not error and matches literally")

  -- empty / whitespace / absent -> no results
  check(#docs.search("", corpus) == 0, "docs.search: empty query is empty")
  check(#docs.search("   ", corpus) == 0, "docs.search: whitespace query is empty")
  check(#docs.search("zznope", corpus) == 0, "docs.search: absent term is empty")

  -- smoke over the REAL shipped docs (stable API anchors, tolerant asserts)
  local live = docs.list()
  check(#live > 0 and live[1].name and live[1].title and live[1].src,
        "docs.list: the shipped corpus loads with name/title/src")
  local la = docs.search("cm.actor")
  local saw_scripting = false
  for _, h in ipairs(la) do
    if h.name == "scripting.md" then saw_scripting = true end
  end
  check(saw_scripting, "docs.search: 'cm.actor' finds the shipped scripting guide")
  -- the A8 reference topics we documented are findable (the D110 loop: what is
  -- written must be searchable) — tolerant, term appears in scripting.md
  local function shipped_finds(term, doc)
    for _, h in ipairs(docs.search(term)) do
      if h.name == doc then return true end
    end
    return false
  end
  check(shipped_finds("compatibility", "scripting.md"),
        "docs.search: 'compatibility' finds the compatibility policy")
  check(shipped_finds("diverges", "scripting.md"),
        "docs.search: 'diverges' finds the common-failures section")
  -- the D127 A8 walkthrough: getting-started must carry the guided path and
  -- stay findable by its own promises (create/play/rewind/draw/build)
  check(shipped_finds("first game", "getting-started.md"),
        "docs.search: 'first game' finds the getting-started walkthrough")
  check(shipped_finds("walkthrough", "getting-started.md"),
        "docs.search: 'walkthrough' finds getting-started")
  check(shipped_finds("build a player", "getting-started.md"),
        "docs.search: 'build a player' finds the export step")
  local gs
  for _, d in ipairs(live) do if d.name == "getting-started.md" then gs = d end end
  check(gs ~= nil, "docs.list: getting-started.md ships")
  if gs then
    for _, want in ipairs({ "Create a project", "Play it", "Rewind",
        "Change the code", "Draw your hero", "Lay out a room",
        "Give it a sound", "Name it and build a player" }) do
      local found = false
      for _, s in ipairs(docs.sections(gs.src)) do
        if s.title:find(want, 1, true) then found = true break end
      end
      check(found, "getting-started: the '" .. want .. "' step is a section")
    end
  end
  -- the A8 searchable-reference bar: every supported cm.* lands a scripting.md
  -- hit whose SECTION heading names the module (tolerant of retitles that keep
  -- the module name in the heading — the D110 loop: what is written must be
  -- searchable)
  for _, mod in ipairs({ "cm.state", "cm.input", "cm.gfx", "cm.text", "cm.map",
      "cm.collide", "cm.box", "cm.actor", "cm.camera", "cm.tween", "cm.depth",
      "cm.hud", "cm.move", "cm.tmap", "cm.anim", "cm.sprite", "cm.snd",
      "cm.ins", "cm.options", "cm.save", "cm.palette", "cm.grade", "cm.rand",
      "cm.math", "cm.ease", "cm.m4", "cm.gb", "cm.terr", "cm.terr3",
      "cm.atlas", "cm.mesh", "cm.song", "cm.fig", "cm.mascot", "cm.spr",
      "cm.rig", "cm.kin", "cm.walk" }) do
    local named = false
    for _, h in ipairs(docs.search(mod)) do
      if h.name == "scripting.md" and h.section
         and h.section:find(mod, 1, true) then named = true break end
    end
    check(named, "docs.search: '" .. mod .. "' lands its own scripting.md section")
  end
  check(#docs.search("zzq_not_a_real_token_xyz") == 0,
        "docs.search: an absent token finds nothing in the shipped docs")
  -- the reader has NO markdown-table renderer (human report, D127: pipe
  -- rows render as wrapped prose, unaligned). The one shipped table was
  -- reformatted as an aligned indented block. Until a real table layout
  -- exists, no shipped doc may carry '|'-row tables — use a 4-space
  -- indented block (mono, aligned, copyable) instead.
  for _, d in ipairs(live) do
    local has_table = false
    local k2, l2, n2 = docs.line_kinds(d.src)
    for j = 1, n2 do
      if k2[j] == "text" and l2[j]:match("^%s*|.+|%s*$") then
        has_table = true
        break
      end
    end
    check(not has_table, "docs: " .. d.name .. " carries no markdown table "
          .. "rows (the reader cannot render them; use an indented block)")
    -- the reader's inline parser is PER SOURCE LINE (help.parse_inline):
    -- a **bold** or `code` span crossing a line break renders its markers
    -- literally (human report, D127 — asterisks visible in the reader).
    -- Pin the authoring contract: every prose line balances its markers.
    local bad
    for j = 1, n2 do
      if k2[j] == "text" then
        local _, stars = l2[j]:gsub("%*%*", "")
        local _, ticks = l2[j]:gsub("`", "")
        if stars % 2 == 1 or ticks % 2 == 1 then
          bad = j
          break
        end
      end
    end
    check(bad == nil, "docs: " .. d.name .. " line " .. tostring(bad)
          .. " has an unbalanced **/` span (the reader parses inline "
          .. "markup per line; rewrap so spans do not cross lines)")
  end
end

-- the help reader's drag-selection row model (D112): pure pick/x/extract math
-- over recorded text runs, with an injected measure (fake monospace here; the
-- reader passes pal.x_ig_text_size) — the text.fr_matches precedent
local function t_help_sel()
  local help = cm.require("cm.ed.win.help")
  local function meas(s, px, font) return #s * 6 end
  -- a synthetic rendered doc: a wrapped prose line, prose after a blank, a
  -- code block with an interior blank line, a utf8 run, adjacent runs
  local rows = {
    { y = 0,  h = 12, ln = 1,  runs = {
        { x = 0,  w = 30, s = "Hello", font = 0, px = 8 },
        { x = 36, w = 30, s = "world", font = 0, px = 8 } } },
    { y = 12, h = 12, ln = 1,  runs = {                -- ln 1 wrapped on
        { x = 0, w = 42, s = "wrapped", font = 0, px = 8 } } },
    { y = 24, h = 12, ln = 3,  runs = {                -- blank line crossed
        { x = 0, w = 24, s = "next", font = 0, px = 8 } } },
    { y = 36, h = 12, ln = 6,  runs = {                -- a bigger gap
        { x = 0, w = 30, s = "later", font = 0, px = 8 } } },
    { y = 48, h = 12, ln = 10, runs = {                -- a code block…
        { x = 4, w = 18, s = "a=1", font = 1, px = 8 } } },
    { y = 60, h = 12, ln = 11, runs = {} },            -- …with a blank line
    { y = 72, h = 12, ln = 12, runs = {
        { x = 4, w = 18, s = "b=2", font = 1, px = 8 } } },
    { y = 84, h = 12, ln = 20, runs = {                -- ◀ is 3 bytes
        { x = 0, w = 30, s = "a\226\151\128b", font = 0, px = 8 } } },
    { y = 96, h = 12, ln = 30, runs = {                -- touching runs
        { x = 0,  w = 18, s = "foo", font = 0, px = 8 },
        { x = 18, w = 18, s = "bar", font = 0, px = 8 } } },
  }
  help.rows_finalize(rows)

  -- the joined text: a gap becomes one space, touching runs none, empty rows ""
  check(rows[1].text == "Hello world" and rows[1].runs[2].j0 == 6,
        "help.sel: gap joins as one space; j0 counts it")
  check(rows[9].text == "foobar" and rows[9].runs[2].j0 == 3,
        "help.sel: touching runs join with no space")
  check(rows[6].text == "", "help.sel: a blank code line is an empty row")

  -- row_pick: x -> byte offset, snapped to the nearest glyph boundary
  check(help.row_pick(rows[1], -5, meas) == 0,
        "help.row_pick: left of the row is offset 0")
  check(help.row_pick(rows[1], 2, meas) == 0
        and help.row_pick(rows[1], 4, meas) == 1,
        "help.row_pick: the glyph midpoint splits the pick")
  check(help.row_pick(rows[1], 33, meas) == 6,
        "help.row_pick: a click in the word gap lands the boundary")
  check(help.row_pick(rows[1], 999, meas) == 11,
        "help.row_pick: past the end is the row end")
  check(help.row_pick(rows[8], 10, meas) == 1
        and help.row_pick(rows[8], 20, meas) == 4,
        "help.row_pick: utf8 picks never split a codepoint")

  -- row_x: offset -> x (the inverse edge)
  check(help.row_x(rows[1], 0, meas) == 0
        and help.row_x(rows[1], 5, meas) == 30
        and help.row_x(rows[1], 6, meas) == 36
        and help.row_x(rows[1], 8, meas) == 48
        and help.row_x(rows[1], 11, meas) == 66,
        "help.row_x: run starts, interiors, the gap edge, the row end")

  -- rows_pick: point -> {ri, ci}, clamped; the next row's y is the boundary
  local p = help.rows_pick(rows, 0, -5, meas)
  check(p.ri == 1 and p.ci == 0, "help.rows_pick: above clamps to the start")
  p = help.rows_pick(rows, 2, 13, meas)
  check(p.ri == 2 and p.ci == 0, "help.rows_pick: y lands by row band")
  p = help.rows_pick(rows, 999, 9999, meas)
  check(p.ri == 9 and p.ci == 6, "help.rows_pick: below clamps to the end")

  -- sel_text: slices, wrap rejoin, newlines, paragraph gaps, normalization
  check(help.sel_text(rows, { ri = 1, ci = 0 }, { ri = 1, ci = 5 }) == "Hello",
        "help.sel_text: a same-row slice")
  check(help.sel_text(rows, { ri = 1, ci = 6 }, { ri = 2, ci = 7 })
        == "world wrapped",
        "help.sel_text: a wrap rejoins with the space it consumed")
  check(help.sel_text(rows, { ri = 2, ci = 0 }, { ri = 3, ci = 4 })
        == "wrapped\n\nnext",
        "help.sel_text: a crossed blank line is a paragraph break")
  check(help.sel_text(rows, { ri = 3, ci = 0 }, { ri = 4, ci = 5 })
        == "next\n\nlater",
        "help.sel_text: any 2+ line jump is a paragraph break")
  check(help.sel_text(rows, { ri = 5, ci = 0 }, { ri = 7, ci = 3 })
        == "a=1\n\nb=2",
        "help.sel_text: code rows keep their interior blank line")
  check(help.sel_text(rows, { ri = 3, ci = 4 }, { ri = 2, ci = 0 })
        == "wrapped\n\nnext",
        "help.sel_text: reversed endpoints normalize")
  check(help.sel_text(rows, { ri = 1, ci = 3 }, { ri = 1, ci = 3 }) == "",
        "help.sel_text: an empty selection is empty text")

  -- escape clears an active selection (and only then consumes the key);
  -- selection state is module-local per win.id — NEVER on the captured
  -- window, so it can't ride state.canon into session.dat
  local w = { id = 990001 }
  local st = help.sel_state(w)
  st.a, st.b = { ri = 1, ci = 0 }, { ri = 1, ci = 2 }
  check(help.escape(w) == true and st.a == nil,
        "help.escape: clears the selection and consumes")
  check(help.escape({ id = 990002 }) == false,
        "help.escape: nothing selected, nothing consumed")
end

-- the reader's keyboard scrolling: the paging hotkeys are declarative kit
-- entries over pure clamped math (M.scroll_by) — drive them with fake wins
local function t_help_keys()
  local help = cm.require("cm.ed.win.help")
  local hk = {}
  for _, e in ipairs(help.hotkeys) do hk[e.key] = e end
  for _, k in ipairs({ "pgup", "pgdn", "home", "end",
                       "ctrl+pgup", "ctrl+pgdn" }) do
    check(hk[k] ~= nil, "help.keys: a '" .. k .. "' hotkey is declared")
    check(cm.require("cm.ed.kit").keyspec(k) ~= nil,
          "help.keys: '" .. k .. "' parses as a keyspec")
  end

  -- paging: down/up by 90% of the measured band, clamped both ends
  local w = { scroll = 0, _maxscroll = 1000, _band = 400, hl_line = 7 }
  hk.pgdn.fn(w)
  check(w.scroll == 360, "help.keys: pgdn pages by 0.9 of the band")
  check(w.hl_line == nil, "help.keys: paging dismisses the landed marker")
  hk.pgdn.fn(w); hk.pgdn.fn(w)
  check(w.scroll == 1000, "help.keys: pgdn clamps at the bottom")
  hk.pgup.fn(w)
  check(w.scroll == 640, "help.keys: pgup pages back up")
  hk["home"].fn(w)
  check(w.scroll == 0, "help.keys: home jumps to the top")
  hk["end"].fn(w)
  check(w.scroll == 1000, "help.keys: end jumps to the bottom")
  hk["ctrl+pgup"].fn(w)
  check(w.scroll == 0, "help.keys: ctrl+pgup also reaches the top")
  hk["ctrl+pgdn"].fn(w)
  check(w.scroll == 1000, "help.keys: ctrl+pgdn also reaches the bottom")
  local near_top = { scroll = 100, _maxscroll = 1000, _band = 400 }
  hk.pgup.fn(near_top)
  check(near_top.scroll == 0, "help.keys: pgup clamps at the top")

  -- the when-gate: nothing fires on a doc that fits its band
  local flat = { scroll = 0, _maxscroll = 0, _band = 400 }
  for _, k in ipairs({ "pgup", "pgdn", "home", "end" }) do
    check(hk[k].when(flat) == false,
          "help.keys: '" .. k .. "' gates off without overflow")
  end
  check(hk.pgdn.when({ scroll = 0, _maxscroll = 12, _band = 400 }) == true,
        "help.keys: the gate opens once content overflows")

  -- the scrollbar's pure math (draw feeds it live values)
  local ky, kh = help.sb_knob(0, 1000, 1600, 600, 100, 1)
  check(kh == 225, "help.sb: knob height is sh*sh/contenth")
  check(ky == 100, "help.sb: at scroll 0 the knob sits at the band top")
  ky = help.sb_knob(1000, 1000, 1600, 600, 100, 1)
  check(ky + kh == 700, "help.sb: at full scroll the knob touches the bottom")
  local _, kmin = help.sb_knob(0, 1e6, 1e6, 100, 0, 2)
  check(kmin == 40, "help.sb: the knob floors at 20*z")
  check(help.sb_target(-1e9, 0, 100, 600, 225, 1000) == 0,
        "help.sb: a drag past the top clamps to 0")
  check(help.sb_target(1e9, 0, 100, 600, 225, 1000) == 1000,
        "help.sb: a drag past the bottom clamps to maxscroll")
  check(help.sb_target(100 + 187.5, 0, 100, 600, 225, 1000) == 500,
        "help.sb: the knob maps linearly over the track")

  -- D135: paging is a stepping action — the entries opt into key repeat
  check(hk.pgdn.rep == true and hk.pgup.rep == true,
        "help.keys: paging keys declare rep")
  check(not hk["home"].rep and not hk["end"].rep,
        "help.keys: absolute jumps stay edge-triggered")
end

-- the kit hotkey dispatcher's key-repeat contract (D135): entries opt
-- into repeat with rep = true (stepping actions); a matched entry
-- consumes a held key either way, so repeats of an edge-only key the
-- kind owns can never leak into the shell's plain-key tier
local function t_kit_rep()
  local kit = cm.require("cm.ed.kit")
  local fired = { pg = 0, p = 0 }
  local kind = { hotkeys = {
    { key = "pgdn", rep = true,
      fn = function() fired.pg = fired.pg + 1 end },
    { key = "p", fn = function() fired.p = fired.p + 1 end },
    { key = "g", when = function() return false end,
      fn = function() fired.g = true end },
  } }
  local mods = {}
  local function ev(sc, rep)
    return { scancode = sc, down = true, rep = rep or false }
  end
  check(kit.hotkey(kind, {}, {}, ev(78), mods) and fired.pg == 1,
        "kit.rep: an edge press fires a rep entry")
  check(kit.hotkey(kind, {}, {}, ev(19), mods) and fired.p == 1,
        "kit.rep: an edge press fires a plain entry")
  check(kit.hotkey(kind, {}, {}, ev(78, true), mods) and fired.pg == 2,
        "kit.rep: a repeat steps a rep entry")
  check(kit.hotkey(kind, {}, {}, ev(19, true), mods) == true
        and fired.p == 1,
        "kit.rep: a repeat of a plain entry is consumed, not fired")
  check(kit.hotkey(kind, {}, {}, ev(10, true), mods) == false
        and fired.g == nil,
        "kit.rep: a gated-off entry passes the key through")
  check(kit.hotkey(kind, {}, {}, { scancode = 78, down = false },
                   mods) == false,
        "kit.rep: key ups pass through")
end

-- the game window's Aa-invariant pixel-perfect blit (the human's report:
-- raising the global text size blurred the game by its factor). blit_scale
-- snaps to the DESIGN multiple s/ds, clamped to what the well fits.
local function t_game_blit()
  -- D125 follow-up: the snap tests the WELL scale itself — the Aa
  -- compensation lives in the rect (win.aa reconcile), so s is already
  -- Aa-invariant. D122's s/ds division here, kept alongside the D123
  -- rect compensation, collapsed the image to r < s at s/ds-integer
  -- zoom crossings (the letterbox flicker while zooming at Aa 1.5).
  local game = cm.require("cm.ed.win.game")
  local function bs(s) local r, e = game.blit_scale(s) return r, e end
  local r, e = bs(2.0)
  check(r == 2 and e == true, "game.blit: an integer well scale snaps")
  r, e = bs(2.0004)
  check(r == 2 and e == true, "game.blit: float noise of an integer snaps")
  r, e = bs(2.4)
  check(r == 2.4 and e == false, "game.blit: a free resize passes through")
  r, e = bs(3.0)
  check(r == 3 and e == true,
        "game.blit: a reconciled 2x window at zoom 1.5 fills at a crisp 3x")
  r, e = bs(3.02)
  check(r == 3.02 and e == false,
        "game.blit: 3.02 (the old s/ds=2.013 flicker case) never collapses")
  r, e = bs(2.997)
  check(r == 2.997 and e == false,
        "game.blit: outside the noise window passes through")
  r, e = bs(0.999)
  check(r == 1 and e == true, "game.blit: noise below 1x still snaps to 1x")
  r, e = bs(0.5)
  check(r == 0.5 and e == false,
        "game.blit: a sub-1x well scale never snaps")
end

-- the CTRL-resize snap (D125 follow-up 2): lands on an exact SCREEN
-- design multiple — s*ds integer, not s (a world-integer multiple at
-- Aa 1.25 reads 2.5x on screen and is never crisp)
local function t_game_snap()
  local game = cm.require("cm.ed.win.game")
  check(game.snap_mult(2.1, 1) == 2,
        "game.snap: Aa 1 snaps the world multiple as before")
  check(game.snap_mult(1.9, 1.25) == 2 / 1.25,
        "game.snap: Aa 1.25 lands on a 2x SCREEN multiple (1.6 world)")
  check(game.snap_mult(2.9, 1.25) * 1.25 == 4,
        "game.snap: Aa 1.25 near 3.6 screen lands the next whole screen x")
  check(game.snap_mult(1.35, 1.5) == 2 / 1.5,
        "game.snap: Aa 1.5 snaps 2.025 screen to exactly 2x screen")
  check(game.snap_mult(0.3, 1.5) == 1 / 1.5,
        "game.snap: the floor is a 1x SCREEN multiple")
  -- the snapped shape survives an Aa flip crisp: k/ds is exactly what
  -- aa_rect's crisp branch recomputes
  local PW, PH = game.PAD_W, game.PAD_H
  local s = game.snap_mult(1.9, 1.25) -- 2x screen at Aa 1.25
  local w1, h1 = game.aa_rect(426 * s + PW, 240 * s + PH, 1.25, 1, 240)
  check(w1 == 426 * 2 + PW and h1 == 240 * 2 + PH,
        "game.snap: a CTRL-snapped rect flips to Aa 1 as an exact 2x")
  -- a FRESH game window spawns crisp at any Aa (the human's report: at
  -- 125% the default window wasn't pixel-perfect until ctrl+snapped)
  local view = cm.require("cm.view")
  local saved = view.cfg.editor_scale
  view.cfg.editor_scale = 1.25
  local _, dw, dh = game.defaults()
  view.cfg.editor_scale = saved
  local gw, gh = pal.gfx_size()
  local si = (dw - PW) / gw
  check(math.abs(si - game.snap_mult(1, 1.25)) < 1e-12
        and (gw * si * 1.25) % 1 == 0
        and math.abs((dh - PH) - gh * game.snap_mult(1, 1.25)) < 1e-9,
        "game.snap: a fresh spawn is a whole SCREEN multiple at Aa 1.25")
end

-- the derived target FOV (D125): the shell asserts pick_fov every live
-- frame — the FOV is never a latch, so nothing (a park re-aim, a closed
-- window) can leave the target stale
local function t_game_fov()
  local game = cm.require("cm.ed.win.game")
  local tw, th = 320, 240 -- 4:3 design -> supported range 320..426
  check(game.pick_fov({}, nil, tw, th) == nil,
        "game.fov: no game windows leaves the target alone")
  check(game.pick_fov({ { kind = "note", id = 1 } }, nil, tw, th) == nil,
        "game.fov: non-game windows do not count")
  local wins = { { kind = "note", id = 1 }, { kind = "game", id = 2 } }
  check(game.pick_fov(wins, nil, tw, th) == 320,
        "game.fov: an unsized game window asserts the design width")
  wins[#wins + 1] = { kind = "game", id = 3, fw = 426 }
  check(game.pick_fov(wins, nil, tw, th) == 426,
        "game.fov: the sized window wins over the unsized one")
  wins[#wins + 1] = { kind = "game", id = 4, fw = 360 }
  check(game.pick_fov(wins, nil, tw, th) == 360,
        "game.fov: the LAST sized window wins (D054 multi-window)")
  check(game.pick_fov(wins, 3, tw, th) == 426,
        "game.fov: the explicit owner beats doc order")
  check(game.pick_fov(wins, 9, tw, th) == 360,
        "game.fov: a stale owner id falls back to last-sized")
  check(game.pick_fov({ { kind = "game", id = 1, fw = 9999 } }, 1, tw, th)
        == 320, "game.fov: an out-of-range fw falls back to the design width")
end

-- the per-window Aa stamp reconcile (D125): image area scales by old/new
-- (screen footprint constant), crisp integer design multiples recompute
-- exactly (no drift across repeated flips). SIZE ONLY — the top-left
-- corner is Aa-invariant like every other window's (follow-up 3)
local function t_game_aa()
  local game = cm.require("cm.ed.win.game")
  local PW, PH = game.PAD_W, game.PAD_H
  local th = 240
  -- a crisp 2x 426-wide window laid out at Aa 1 moves to Aa 1.5
  local w0, h0 = 426 * 2 + PW, 240 * 2 + PH
  local w1, h1, extra = game.aa_rect(w0, h0, 1, 1.5, th)
  check(w1 == 426 * 2 / 1.5 + PW and h1 == 240 * 2 / 1.5 + PH,
        "game.aa: the image area rescales by aa0/ds, pads untouched")
  check(extra == nil,
        "game.aa: size only — no position offsets (the corner stays put)")
  local w2, h2 = game.aa_rect(w1, h1, 1.5, 1, th)
  check(w2 == w0 and h2 == h0,
        "game.aa: a round trip restores the exact rect")
  local wa, ha = game.aa_rect(320 * 3 / 1.25 + PW, 240 * 3 / 1.25 + PH,
                              1.25, 1.5, th)
  check(wa == 320 * 3 / 1.5 + PW and ha == 240 * 3 / 1.5 + PH,
        "game.aa: crisp multiples recompute exactly across scales")
  local wb = game.aa_rect(100 + PW, 90 + PH, 1, 2, th)
  check(wb == 100 / 2 + PW,
        "game.aa: a non-integer design multiple rescales plainly")
  local wc, hc = game.aa_rect(w0, h0, 1, 1, th)
  check(wc == w0 and hc == h0,
        "game.aa: equal scales are the exact identity")
end

-- the Aa camera anchor (D125): a display-scale change keeps the world
-- point at the viewport center AT the viewport center, so the layout
-- grows/shrinks in place instead of sliding away from the screen origin
local function t_cam_aa()
  local cam = cm.require("cm.ed.cam")
  local save = cam.display_scale
  local c = { x = 100, y = 50, zoom = 2 }
  local W, H = 1280, 800
  cam.display_scale = 1
  local wx, wy = cam.s2w(c, W * 0.5, H * 0.5) -- world point at center
  cam.aa_anchor(c, W, H, 1, 1.5)
  cam.display_scale = 1.5
  local sx, sy = cam.w2s(c, wx, wy)
  check(m.abs(sx - W * 0.5) < 1e-9 and m.abs(sy - H * 0.5) < 1e-9,
        "cam.aa: the viewport-center world point stays centered")
  check(c.zoom == 2, "cam.aa: the anchor never touches zoom")
  cam.aa_anchor(c, W, H, 1.5, 1)
  cam.display_scale = 1
  sx, sy = cam.w2s(c, wx, wy)
  check(m.abs(sx - W * 0.5) < 1e-9 and m.abs(sy - H * 0.5) < 1e-9,
        "cam.aa: the anchor round-trips")
  cam.display_scale = save
end

-- ---- the 3D fork modules (merged 2026-07-18): KATs to the same bar as
-- the 2d slices. cm.m4 / cm.kin / cm.walk / cm.rig are pure math (rig
-- reads record-backed input, neutral in this cartridge); the render-class
-- emitters (cm.gb/terr/spr/atlas/fig/mascot) stay pinned by the committed
-- pixel/trace goldens, the cm.gfx precedent. ----

local function near(a, b, eps) return m.abs(a - b) <= (eps or 1e-9) end

local function t_m4()
  local m4 = cm.require("cm.m4")
  local function pt(what, gx, gy, gz, x, y, z, eps)
    check(near(gx, x, eps) and near(gy, y, eps) and near(gz, z, eps), what)
  end
  pt("m4.ident is identity", 3, -2, 7, m4.apply(m4.ident(), 3, -2, 7))
  pt("m4.translate moves a point", 4, 7, 10,
     m4.apply(m4.translate(1, 2, 3), 3, 5, 7))
  pt("m4.applydir ignores translation", 3, 5, 7,
     m4.applydir(m4.translate(1, 2, 3), 3, 5, 7))
  pt("m4.scale scales a point", 6, -10, 21,
     m4.apply(m4.scale(2, -2, 3), 3, 5, 7))
  -- rotation conventions (the r3d.c port): quarter turns map axes
  -- (capture first: a mid-arglist multi-return truncates to one value)
  local rx, ry, rz = m4.apply(m4.rotx(m.pi / 2), 0, 1, 0)
  pt("m4.rotx maps +y to +z", 0, 0, 1, rx, ry, rz, 1e-9)
  rx, ry, rz = m4.apply(m4.roty(m.pi / 2), 0, 0, 1)
  pt("m4.roty maps +z toward +x", 1, 0, 0, rx, ry, rz, 1e-9)
  rx, ry, rz = m4.apply(m4.rotz(m.pi / 2), 1, 0, 0)
  pt("m4.rotz maps +x to +y", 0, 1, 0, rx, ry, rz, 1e-9)
  -- mul composes right-to-left: mul(T,S) scales first, then translates
  local T, S = m4.translate(1, 2, 3), m4.scale(2, 2, 2)
  pt("m4.mul(T,S) applies S first", 3, 4, 5, m4.apply(m4.mul(T, S), 1, 1, 1))
  pt("m4.mul(S,T) applies T first", 4, 6, 8, m4.apply(m4.mul(S, T), 1, 1, 1))
  local I = m4.mul(m4.ident(), m4.rotz(0.3))
  local J = m4.rotz(0.3)
  for i = 1, 16 do check(I[i] == J[i], "m4.mul by ident is exact") end
  -- lookat: eye on +z looking at the origin — eye maps to the view origin,
  -- a point in front maps onto -z, right/up map to +x/+y
  local V = m4.lookat(0, 0, 5, 0, 0, 0, 0, 1, 0)
  pt("m4.lookat maps the eye to origin", 0, 0, 0, m4.apply(V, 0, 0, 5))
  pt("m4.lookat looks down -z", 0, 0, -1, m4.apply(V, 0, 0, 4))
  pt("m4.lookat right is +x", 1, 0, 0, m4.apply(V, 1, 0, 5))
  pt("m4.lookat up is +y", 0, 1, 0, m4.apply(V, 0, 1, 5))
  -- persp: the five live entries at fovy 90 (f = 1), aspect 2, zn 1, zf 101
  local P = m4.persp(90, 2, 1, 101)
  check(near(P[1], 0.5, 1e-6) and near(P[6], 1, 1e-6), "m4.persp focal terms")
  check(near(P[11], -1.02, 1e-9) and P[12] == -1
        and near(P[15], -2.02, 1e-9), "m4.persp depth terms")
  local zero = { 2, 3, 4, 5, 7, 8, 9, 10, 13, 14, 16 }
  for _, i in ipairs(zero) do check(P[i] == 0, "m4.persp zero entry " .. i) end
  -- ortho: half-extents map to clip +-1, depth stays GL-style
  local O = m4.ortho(4, 2, 1, 101)
  check(near(O[1], 0.25, 1e-9) and near(O[6], 0.5, 1e-9),
        "m4.ortho extent terms")
  check(near(O[11], -0.02, 1e-9) and near(O[15], -1.02, 1e-9)
        and O[16] == 1 and O[12] == 0, "m4.ortho depth terms (w stays 1)")
end

local function t_kin()
  local K = cm.require("cm.kin")
  check(K.approach(0, 10, 1) == 1 and K.approach(5, 0, 2) == 3
        and K.approach(9.5, 10, 3) == 10 and K.approach(-2, -10, 1) == -3,
        "kin.approach caps toward the target from both sides")
  -- overlaps: strict on the sides, half-open feet-up on y
  local b = { 0, 0, 0, 1, 1, 1 }
  check(K.overlaps(b, 0.5, 0.5, 0.5, 0.3, 1), "kin.overlaps inside")
  check(not K.overlaps(b, -0.5, 0.5, 0.5, 0.5, 1),
        "kin.overlaps flush -x face is out (strict)")
  check(not K.overlaps(b, 0.5, 1.0, 0.5, 0.3, 1),
        "kin.overlaps feet at the top face are out (half-open)")
  check(not K.overlaps(b, 0.5, -1.0, 0.5, 0.3, 1),
        "kin.overlaps head flush under the floor is out")
  -- the D029 fixed-apex curve, and the apex_t floor
  local g, v0 = K.jump_curve(1, 60)
  check(g == 2 and v0 == 2, "kin.jump_curve h=1 apex=60")
  g, v0 = K.jump_curve(1, 0.25)
  check(g == 7200 and v0 == 120, "kin.jump_curve clamps apex_t to 1")
  -- run: accel toward the wish + turn, or brake
  local vx, vz, yaw = K.run(0, 0, 0, 1, 0, 10, 60, 120, 1)
  check(near(vx, 1, 1e-12) and vz == 0, "kin.run accelerates toward the wish")
  check(near(yaw, m.pi / 2, 1e-4), "kin.run turns to the heading (turn=1)")
  vx, vz, yaw = K.run(5, 0, 1.2, 0, 0, 10, 60, 120, 1)
  check(near(vx, 3, 1e-12) and yaw == 1.2, "kin.run brakes, yaw untouched")
  -- gravity: rise slope vs the heavier fall
  check(near(K.gravity(2, 60, 2), 1, 1e-12), "kin.gravity rising")
  check(near(K.gravity(-1, 60, 2), -3, 1e-12), "kin.gravity falling (mul)")
  -- jump: grounded press fires; coyote fires; buffer holds; paddle hops
  local vy, jb, co, gr, evt = K.jump(0, 0, true, true, 6, 5, 7, false)
  check(vy == 7 and evt == "jump" and gr == false and jb == 0 and co == 0,
        "kin.jump grounded press fires and consumes")
  vy, jb, co, gr, evt = K.jump(0, 3, false, true, 6, 5, 7, false)
  check(vy == 7 and evt == "jump", "kin.jump coyote fires airborne")
  vy, jb, co, gr, evt = K.jump(0, 0, false, true, 6, 5, 7, false)
  check(vy == nil and evt == nil and jb == 5 and gr == false,
        "kin.jump airborne press only arms the buffer")
  vy, jb, co, gr, evt = K.jump(jb, co, true, false, 6, 5, 7, false)
  check(vy == 7 and evt == "jump", "kin.jump buffered press fires on landing")
  vy, jb, co, gr, evt = K.jump(0, 0, false, true, 6, 5, 8, true, 0.5)
  check(vy == 4 and evt == "paddle" and gr == false,
        "kin.jump swim paddle hop, no ground leave")
  -- slide: face from the pre-move side, EPS-tolerant, squeezed clamps
  -- nothing, mantle raises instead
  local box = { 2, 0, 2, 4, 2, 4 }
  local n, v, cy = K.slide({ box }, true, 2.0, 0.5, 3.0, 1.5, 5, 0.3, 1)
  check(n == 1.7 and v == 0 and cy == 0.5, "kin.slide clamps to the -x face")
  n, v = K.slide({ box }, true, 4.0, 0.5, 3.0, 4.5, -5, 0.3, 1)
  check(n == 4.3 and v == 0, "kin.slide clamps to the +x face (pre-move side)")
  n, v = K.slide({ box }, true, 3.1, 0.5, 3.0, 3.0, 5, 0.3, 1)
  check(n == 3.1 and v == 5, "kin.slide squeezed pre-move overlap clamps nothing")
  n, v = K.slide({ box }, false, 3.0, 0.5, 2.0, 1.5, 5, 0.3, 1)
  check(n == 1.7 and v == 0, "kin.slide z axis clamps too")
  n, v = K.slide({ box }, true, 1.75, 0.5, 3.0, 1.7, 5, 0.3, 1)
  check(n == 1.7 and v == 0, "kin.slide EPS: a flush player still reads outside")
  n, v, cy = K.slide({ box }, true, 2.0, 0.5, 3.0, 1.5, 5, 0.3, 1,
                     function(bb) return bb[5] end)
  check(cy == 2 and v == 5 and n == 2.0,
        "kin.slide mantle raises the feet and keeps the run")
  -- mantle_top: the lift window and the fit probe
  local step = { 2, 0, 2, 4, 0.5, 4 }
  check(K.mantle_top(step, { step }, 3, 3, 0.2, 0.3, 1, 0.6) == 0.5,
        "kin.mantle_top lifts within step_h when the body fits")
  local lid = { 2, 0, 2, 4, 3, 4 }
  check(K.mantle_top(step, { step, lid }, 3, 3, 0.2, 0.3, 1, 0.6) == nil,
        "kin.mantle_top refuses when blocked at the new height")
  check(K.mantle_top(step, { step }, 3, 3, 0.2, 0.3, 1, 0.2) == nil,
        "kin.mantle_top refuses past step_h")
  check(K.mantle_top(step, { step }, 3, 3, 1.0, 0.3, 1, 0.6) == nil,
        "kin.mantle_top refuses a top at or below the feet")
  -- ground_top: interior-footprint landing plane
  local deck = { 0, 0, 0, 4, 1, 4 }
  check(K.ground_top({ deck }, 0, 2, 1.0, 2, 0.3) == 1,
        "kin.ground_top raises to a box top under the feet")
  check(K.ground_top({ deck }, 0, 5, 1.0, 2, 0.3) == 0,
        "kin.ground_top ignores a footprint outside the box")
  check(K.ground_top({ deck }, 0, 2, 0.5, 2, 0.3) == 0,
        "kin.ground_top ignores a top above the feet")
  -- landing squash + lean
  local amt, t = K.land_squash(-10, 1, 20, 8)
  check(amt == 0.5 and t == 8, "kin.land_squash scales with fall speed")
  check(K.land_squash(-1, 1, 20, 8) == nil,
        "kin.land_squash ignores a soft touch")
  check(near(K.lean(0, 5, 0.3, 5), 0.06, 1e-12),
        "kin.lean eases toward the scaled target")
end

local function t_mesh()
  -- cm.mesh (E4, D137): the .msh codec + pure geometry ops the mesh
  -- window drives.
  local ME = cm.require("cm.mesh")

  local doc = ME.fresh("crate")
  check(#doc.verts // 3 == 8 and #doc.faces == 6, "mesh.fresh: a unit box")
  local b1 = ME.encode(doc)
  check(b1:sub(1, 4) == "CMSH", "mesh: CMSH magic")
  check(ME.encode(ME.decode(b1)) == b1, "mesh: canonical round trip (box)")

  -- outward normals (the lighting + pick-front contract)
  local function N(fi) return ME.face_normal(doc, fi) end
  local _, ny = N(5)
  check(ny == 1, "mesh: box top normal +y")
  local _, ny2 = N(6)
  check(ny2 == -1, "mesh: box bottom normal -y")
  local nx = N(3)
  check(nx == 1, "mesh: box right normal +x")

  -- bounds
  local bb = ME.bounds(doc)
  check(bb[1] == -0.5 and bb[4] == 0.5 and bb[2] == -0.5 and bb[5] == 0.5,
        "mesh: unit box bounds")

  -- pick: a ray from +z hits the front face (idx 2), not the back
  local ray = { ox = 0.1, oy = 0.05, oz = 5, dx = 0, dy = 0, dz = -1 }
  local fi, t = ME.pick_face(doc, ray)
  check(fi == 2, "mesh: pick hits the front face")
  check(math.abs(t - 4.5) < 1e-9, "mesh: pick t at the near plane")
  ray = { ox = 3, oy = 3, oz = 3, dx = 0, dy = 0, dz = -1 }
  check(ME.pick_face(doc, ray) == nil, "mesh: pick miss = nil")

  -- features round trip: color, ds, unlit, texture region
  doc.faces[1].col = { 1, 0, 0 }
  doc.faces[2].ds = true
  doc.faces[3].unlit = true
  doc.tex = "art/crate.png"
  doc.faces[4].uv = { 0, 0, 16, 0, 16, 16, 0, 16 }
  local b2 = ME.encode(doc)
  local d2 = ME.decode(b2)
  check(ME.encode(d2) == b2, "mesh: canonical round trip (features)")
  check(d2.faces[1].col[1] == 1 and d2.faces[2].ds and d2.faces[3].unlit
        and d2.faces[4].uv[5] == 16 and d2.tex == "art/crate.png",
        "mesh: features survive")

  -- refusals
  check(not pcall(ME.decode, "XXXX" .. b2:sub(5)), "mesh: bad magic refuses")
  check(not pcall(ME.decode, b2:sub(1, #b2 - 6)), "mesh: truncation refuses")
  do
    local bad = ME.fresh("x")
    bad.faces[1].v[1] = 99
    check(not pcall(ME.encode, bad), "mesh: out-of-range vert refuses")
  end

  -- extrude: the top face gains 4 rim quads + moves up
  local ed2 = ME.fresh("ex")
  local nf0 = #ed2.faces
  ME.extrude(ed2, 5, 0.5) -- the +y top
  check(#ed2.faces == nf0 + 4, "mesh: extrude adds the rim")
  local bb2 = ME.bounds(ed2)
  check(math.abs(bb2[5] - 1.0) < 1e-6, "mesh: extrude moved the cap up")
  local _, ny3 = ME.face_normal(ed2, 5)
  check(ny3 == 1, "mesh: extruded cap keeps its normal")

  -- flip reverses the winding
  local fl = ME.fresh("fl")
  ME.flip(fl, 5)
  local _, nyf = ME.face_normal(fl, 5)
  check(nyf == -1, "mesh: flip reverses the normal")

  -- merge + compact: collapsing an edge kills degenerate faces + verts
  local mg = ME.fresh("mg")
  ME.merge_verts(mg, { 3, 7 }) -- a vertical edge of the box
  local okd = true
  local nv2 = #mg.verts // 3
  for _, f in ipairs(mg.faces) do
    okd = okd and #f.v >= 3
    for _, vi in ipairs(f.v) do okd = okd and vi >= 1 and vi <= nv2 end
  end
  check(okd and nv2 == 7, "mesh: merge welds + compacts")

  -- mirror pairing
  local mp = ME.fresh("mp")
  local pair = ME.mirror_pair(mp, 1) -- (-s,-s,-s) pairs (s,-s,-s) = 2
  check(pair == 2, "mesh: mirror-x pairing")

  -- primitives are well-formed + canonical
  for _, kind in ipairs({ "plane", "wedge", "prism" }) do
    local pd = { name = kind, tex = "", verts = {}, faces = {} }
    ME.add_prim(pd, kind, { n = 6 })
    check(ME.encode(ME.decode(ME.encode(pd))) == ME.encode(pd),
          "mesh: " .. kind .. " canonical")
  end

  -- emit: groups by color; ds doubles tris; unlit takes the zero slot
  local em = ME.fresh("em")
  em.faces[1].col = { 1, 0, 0 }
  em.faces[2].ds = true
  em.faces[3].unlit = true
  local groups = ME.bake_groups(em)
  check(#groups == 2, "mesh: two color groups")
  local nt = 0
  local out = {}
  local m4 = cm.require("cm.m4")
  nt = ME.emit(out, m4.ident(), m4.ident(), em)
  check(nt == (6 + 1) * 2, "mesh: emit tris (ds face doubles)")
  local unlit_ok = false
  for _, gr in ipairs(groups) do
    for i = 1, gr.bk.nv do
      local sl = gr.bk.ni[i]
      if gr.bk.nrm[sl * 3 + 1] == 0 and gr.bk.nrm[sl * 3 + 2] == 0
         and gr.bk.nrm[sl * 3 + 3] == 0 then
        unlit_ok = true
      end
    end
  end
  check(unlit_ok, "mesh: unlit face takes the zero-normal slot")

  -- ---- topology + selection (the window's universal mode substrate) ----
  local bx = ME.fresh("topo")

  -- edge keys are canonical both ways
  check(ME.ekey(3, 7) == ME.ekey(7, 3), "mesh: ekey is undirected")
  local ka, kb = ME.eunkey(ME.ekey(7, 3))
  check(ka == 3 and kb == 7, "mesh: eunkey round trip")

  -- a box has 12 edges, each shared by exactly 2 faces
  local elist, eindex = ME.edges(bx)
  check(#elist == 12, "mesh: box has 12 edges")
  local two = true
  for _, e in ipairs(elist) do two = two and #e.fs == 2 end
  check(two, "mesh: every box edge borders 2 faces")
  check(eindex[ME.ekey(2, 3)] ~= nil, "mesh: edge index by key")

  -- pick_hits orders front-to-back: a +z ray sees front then back
  local hits = ME.pick_hits(bx, { ox = 0.1, oy = 0.05, oz = 5,
                                  dx = 0, dy = 0, dz = -1 })
  check(#hits == 1, "mesh: single-sided backface stays unpicked")
  check(hits[1].fi == 2, "mesh: pick_hits front face first")
  bx.faces[1].ds = true -- the back face becomes hittable from inside
  hits = ME.pick_hits(bx, { ox = 0.1, oy = 0.05, oz = 5,
                            dx = 0, dy = 0, dz = -1 })
  check(#hits == 2 and hits[1].fi == 2 and hits[2].fi == 1
        and hits[1].t < hits[2].t, "mesh: pick_hits drills to the back")
  bx.faces[1].ds = nil

  -- visibility: from +z the front corners show, the back corners hide
  check(ME.vert_visible(bx, 0, 0, 5, 6), "mesh: front corner visible")
  check(not ME.vert_visible(bx, 0.02, 0.03, 5, 1),
        "mesh: back corner occluded by the front face")

  -- a lone cube edge dead-ends the vertex walk at both corners
  -- (valence 3), so the loop falls back to an adjacent FACE's boundary
  -- — prefer_face (the face under the cursor) picks the side
  local keys, lfaces = ME.edge_loop(bx, 2, 3, 3) -- prefer the right face
  check(#keys == 4 and #lfaces == 1 and lfaces[1] == 3,
        "mesh: cube edge loop falls back to the preferred face ring")
  local kset = {}
  for _, k in ipairs(keys) do kset[k] = true end
  check(kset[ME.ekey(2, 3)] and kset[ME.ekey(3, 7)]
        and kset[ME.ekey(7, 6)] and kset[ME.ekey(6, 2)],
        "mesh: the fallback ring is the right face's 4 edges")
  local keys2, lfaces2 = ME.edge_loop(bx, 2, 3) -- no preference
  check(#keys2 == 4 and #lfaces2 == 1,
        "mesh: no preference falls back to the first adjacent face")

  -- the REAL loop: extrude the top face — the waist ring's verts are
  -- valence 4, and the walk closes around all 4 middle edges
  do
    local xb = ME.fresh("xb")
    ME.extrude(xb, 5, 0.5)
    local wk, wf = ME.edge_loop(xb, 3, 4)
    check(#wk == 4, "mesh: the extruded waist loop closes (4 edges)")
    local ws = {}
    for _, k in ipairs(wk) do ws[k] = true end
    check(ws[ME.ekey(3, 4)] and ws[ME.ekey(4, 8)]
          and ws[ME.ekey(8, 7)] and ws[ME.ekey(7, 3)],
          "mesh: the waist loop is the 4 middle edges")
    check(#wf == 8, "mesh: the waist loop touches both strips (8 faces)")
  end

  -- triangles break the straight-ahead rule: the wedge's base right
  -- edge dead-ends into its tris and falls back to the bottom face
  local tw = ME.fresh("tw")
  ME.add_prim(tw, "wedge", {})
  local wkeys, wfaces = ME.edge_loop(tw, 10, 11)
  check(#wkeys == 4 and #wfaces == 1,
        "mesh: a tri-bounded edge falls back to its quad's ring")

  -- sel_verts unions a mixed selection
  local u = ME.sel_verts(bx, { 1 }, { ME.ekey(2, 3) }, { 2 })
  check(#u == 7, "mesh: sel_verts unions vert+edge+face") -- 1,2,3,5,6,7,8

  -- selection continuity: face -> verts -> face -> edges
  local vs, es, fs = ME.convert_sel(bx, {}, {}, { 5 }, "vtx")
  check(#vs == 4 and #es == 0 and #fs == 0,
        "mesh: face converts to its 4 corners")
  local vs2, es2, fs2 = ME.convert_sel(bx, vs, {}, {}, "face")
  check(#fs2 == 1 and fs2[1] == 5 and #vs2 == 0 and #es2 == 0,
        "mesh: the corners convert back to exactly their face")
  local _, es3 = ME.convert_sel(bx, vs, {}, {}, "edge")
  check(#es3 == 4, "mesh: the corners convert to the 4 boundary edges")
  local kv, ke, kf = ME.convert_sel(bx, { 1 }, { ME.ekey(2, 3) }, { 5 },
                                    "sel")
  check(#kv == 1 and #ke == 1 and #kf == 1,
        "mesh: sel mode keeps a mixed selection as-is")
end

local function t_terr3()
  -- cm.terr3 (E1, D137): the .terr codec + pure readers — the 3D map
  -- asset the 3d map window edits and games consume.
  local T3 = cm.require("cm.terr3")
  local terr = cm.require("cm.terr")

  -- fresh: a valid flat doc; encode(decode(encode)) is byte-canonical
  local doc = T3.fresh("vale", 8, 6, 2.0)
  check(#doc.hts == 9 * 7 and doc.mats[1].name == "grass",
        "terr3.fresh: plane sized, grass seeded")
  local b1 = T3.encode(doc)
  check(b1:sub(1, 4) == "CTER", "terr3: CTER magic")
  local b2 = T3.encode(T3.decode(b1))
  check(b1 == b2, "terr3: canonical round trip (flat fresh)")

  -- populate every chunk kind and round-trip again
  terr.hset(doc, 3, 2, 4.5)
  terr.hset(doc, 4, 2, 1.25)
  doc.wts[1] = {}
  for i = 1, T3.plane_size(doc) do doc.wts[1][i] = 0 end
  doc.wts[1][5] = 200
  doc.mats[2] = { name = "dirt", col = { 0.5, 0.4, 0.3 }, tex = "art/d.png" }
  doc.wts[2] = {}
  for i = 1, T3.plane_size(doc) do doc.wts[2][i] = i % 7 == 0 and 80 or 0 end
  doc.shade = {}
  for i = 1, T3.plane_size(doc) do doc.shade[i] = 255 end
  doc.shade[9] = 120
  doc.water = { on = true, y = 0.3, col = { 0.2, 0.4, 0.6 }, alpha = 144 }
  doc.props[1] = { path = "art/tree.msh", name = "oak", x = 5.5, z = 3.5,
                   y = 0, yaw = 0.5, scale = 2, caster = true,
                   blocker = true, col = { mode = "auto" } }
  doc.props[2] = { path = "art/hero.png", x = 2, z = 2, y = 0.25, abs = true,
                   scale = 3, col = { mode = "box",
                   box = { -1, 0, -1, 1, 2, 1 } },
                   extras = { { k = "team", v = "red" } } }
  doc.markers[1] = { kind = "spawn", x = 4, z = 4, r = 0.5 }
  doc.markers[2] = { kind = "route", label = "patrol", x = 1, z = 1,
                     points = { 1, 1, 5, 1, 5, 5 },
                     extras = { { k = "speed", v = "2" } } }
  doc.wovr[1] = { cx = 3, cz = 3, v = 0 }
  doc.wovr[2] = { cx = 5, cz = 3, v = 1 } -- forces walk on a steep+blocked cell
  local eb = T3.encode(doc)
  local dd = T3.decode(eb)
  check(T3.encode(dd) == eb, "terr3: canonical round trip (every chunk)")
  check(dd.props[1].name == "oak" and dd.props[1].caster
        and dd.props[1].blocker and dd.props[1].col.mode == "auto",
        "terr3: prop flags/colmode survive")
  check(dd.props[2].abs and dd.props[2].col.box[5] == 2
        and dd.props[2].extras[1].v == "red",
        "terr3: abs + box + extras survive")
  check(dd.markers[2].points[5] == 5 and dd.markers[2].extras[1].k == "speed",
        "terr3: route polyline + extras survive")
  check(dd.wovr[2].cx == 5 and dd.wovr[2].v == 1, "terr3: walk overrides")
  check(dd.shade[9] == 120 and dd.wts[2][7] == 80, "terr3: planes survive")

  -- refusals: bad magic, truncation, wrong plane size
  check(not pcall(T3.decode, "XXXX" .. eb:sub(5)), "terr3: bad magic refuses")
  check(not pcall(T3.decode, eb:sub(1, #eb - 8)), "terr3: truncation refuses")
  do
    local short = T3.fresh("x", 4, 4)
    short.hts[#short.hts] = nil
    check(not pcall(T3.encode, short), "terr3: short HTS refuses at encode")
  end

  -- readers: ground == terr.sample; prop y modes; weights normalize
  check(T3.ground(dd, 7, 5) == terr.sample(dd, 7, 5),
        "terr3.ground == terr.sample")
  check(T3.prop_y(dd, dd.props[2]) == 0.25, "terr3: absolute prop y")
  check(T3.prop_y(dd, dd.props[1])
        == terr.sample(dd, 5.5, 3.5) + 0, "terr3: ground-snapped prop y")
  local wz = T3.weights_at(dd, 1) -- zero-sum vertex -> mat 1
  check(wz[1] == 1 and wz[2] == 0, "terr3: zero weights fall to mat 1")
  local w5 = T3.weights_at(dd, 5)
  check(w5[1] == 1 and w5[2] == 0, "terr3: single-plane weight normalizes")

  -- the walk grid: steep cell blocked, flat cell walkable, override wins
  local grid, gw, gh = T3.walk_grid(dd)
  check(gw == 16 and gh == 12 and #grid == gw * gh, "terr3: GAT dims")
  local function wat(cx, cz) return grid:byte(cz * gw + cx + 1) == 1 end
  check(not wat(6, 4), "terr3: steep slope blocks")          -- under the cliff
  check(wat(14, 10), "terr3: flat far corner walks")
  check(not wat(3, 3), "terr3: override forces block")
  check(wat(5, 3), "terr3: override forces walk over steep+blocked")
  check(not wat(4, 2), "terr3: blocker prop stamps its footprint")

  -- boxes: auto footprint + scaled local box
  local boxes = T3.boxes(dd)
  check(#boxes == 2, "terr3: two collidable props")
  local a = boxes[1]
  check(a[1] == 5.5 - 1 and a[4] == 5.5 + 1 and a[5] - a[2] == 3.2,
        "terr3: auto box scales")
  local bx = boxes[2]
  check(bx[1] == 2 - 3 and bx[6] == 2 + 3 and bx[2] == 0.25,
        "terr3: local box scales from absolute y")

  -- markers filter; route points intact
  check(#T3.markers(dd) == 2 and #T3.markers(dd, "route") == 1
        and T3.markers(dd, "route")[1].label == "patrol",
        "terr3: marker kind filter")

  -- emission: tri counts (render-class; pixels are golden territory)
  local out = {}
  local nt = T3.emit_terrain(out, dd)
  check(nt == dd.w * dd.h * 2, "terr3: full-grid tri count")
  local wout = {}
  check(T3.emit_water(wout, dd) > 0, "terr3: water emits when on")
  dd.water.on = false
  check(T3.emit_water({}, dd) == 0, "terr3: water off emits zero")
  dd.water.on = true

  -- the runtime door: save -> use -> readers -> reload picks up disk edits
  local tmp = "/tmp/cosmic_t3_" .. tostring(pal.time_ns()):sub(-6)
  local path = tmp .. "/vale.terr"
  pal.mkdir(tmp)
  check(T3.save(dd, path), "terr3.save writes")
  local inst = T3.use{ path = path, name = "t3test" }
  check(inst.active and inst.doc.name == "vale", "terr3.use loads + activates")
  check(T3.get("oak") ~= nil and T3.get("oak").x == 5.5,
        "terr3.get finds a named prop")
  check(T3.walkable(inst, 14, 10) and not T3.walkable(inst, 3, 3),
        "terr3: instance walkable reads the grid")
  check(#T3.inst_boxes(inst) == 2, "terr3: instance boxes")
  -- disk changes + reload republish
  local d2 = T3.decode(T3.encode(dd))
  d2.props[#d2.props + 1] = { path = "art/rock.msh", name = "rock",
                              x = 1, z = 1, scale = 1,
                              col = { mode = "auto" } }
  check(T3.save(d2, path), "terr3: second save")
  T3.reload(path)
  check(T3.get("rock") ~= nil, "terr3.reload republishes disk")
  check(#T3.inst_boxes(inst) == 3, "terr3: derived boxes rebuilt on reload")
  T3.release("t3test")
  check(T3.get("rock") == nil or T3.cur == nil, "terr3.release clears")

  -- placements (E3): sizes, aabbs, ray pick, emit segments
  local bdoc = T3.fresh("pk", 8, 8, 2.0)
  bdoc.props[1] = { path = "a/tree.msh", x = 4, z = 4, scale = 2,
                    col = { mode = "auto" } }
  bdoc.props[2] = { path = "a/guy.png", x = 10, z = 4, scale = 3 }
  local dims = function() return 16, 32 end -- tall image: aspect 0.5
  local w1, h1 = T3.prop_size(bdoc.props[2], dims)
  check(h1 == 3 and w1 == 1.5, "terr3: billboard size from aspect")
  local bb = T3.prop_aabb(bdoc, bdoc.props[2], dims)
  check(bb[2] == 0 and bb[5] == 3 and bb[1] == 10 - 0.75,
        "terr3: billboard aabb")
  local rayd = { ox = 4, oy = 10, oz = 4, dx = 0, dy = -1, dz = 0 }
  check(T3.pick_prop(bdoc, rayd, dims) == 1, "terr3: ray picks the box")
  rayd = { ox = 10, oy = 10, oz = 4, dx = 0, dy = -1, dz = 0 }
  check(T3.pick_prop(bdoc, rayd, dims) == 2, "terr3: ray picks the billboard")
  rayd = { ox = 7, oy = 10, oz = 7, dx = 0, dy = -1, dz = 0 }
  check(T3.pick_prop(bdoc, rayd, dims) == nil, "terr3: ray miss = nil")
  rayd = { ox = -5, oy = 1, oz = 4, dx = 1, dy = 0, dz = 0 }
  check(T3.pick_prop(bdoc, rayd, dims) == 1, "terr3: nearest prop wins")
  local segs = T3.emit_props(bdoc, {
    cam_yaw = 0, dims = dims,
    tex = function(pth) return pth:find("png") and 7 or nil end })
  check(#segs == 2, "terr3: two prop segments (stand-in + billboard)")
  check(segs[1].tex == 0 and segs[1].flags == 0 and segs[1].ntris == 10,
        "terr3: stand-in box segment")
  check(segs[2].tex == 7 and segs[2].flags == 3 and segs[2].ntris == 2,
        "terr3: billboard segment is alphatest+nearest")
  local miny = 1e9
  for k = 0, 5 do
    local yv = string.unpack("<f", segs[2].bytes, k * 24 + 5)
    miny = math.min(miny, yv)
  end
  check(miny == 0, "terr3: billboard feet at the ground")

  -- sprite brush stamps: mask = alpha x luminance; aspect-true sampling
  do
    -- 4x2 RGBA: left half opaque white, right half transparent black
    local px4 = string.rep("\255\255\255\255", 2)
                .. string.rep("\0\0\0\0", 2)
    -- the noise brush field (D141 follow-up): bipolar, repeatable,
    -- seed-sensitive, wave-clamped — position-keyed so a stroke plus its
    -- right-button inverse restores the exact height
    local inr, moved, rep = true, false, true
    for vz = 0, 9 do
      for vx = 0, 9 do
        local n = T3.noise_at(131, 4, vx, vz)
        if n < -1 or n > 1 then inr = false end
        if n ~= T3.noise_at(131, 4, vx, vz) then rep = false end
        if T3.noise_at(262, 4, vx, vz) ~= n then moved = true end
      end
    end
    check(inr and rep, "terr3: noise_at bipolar in [-1,1] + repeatable")
    check(moved, "terr3: noise_at reseed moves the field")
    check(T3.noise_at(7, 0, 3, 3) == T3.noise_at(7, 1, 3, 3),
          "terr3: noise_at clamps wave under 1")

    local mk = T3.stamp_mask(px4 .. px4, 4, 2)
    check(mk.w == 4 and mk.h == 2 and mk[1] == 1 and mk[4] == 0,
          "terr3: stamp_mask weights alpha x luminance")
    -- aspect 2: fits 2r wide x r tall; center-left samples white
    check(T3.stamp_at(mk, -0.5, 0, 1) == 1, "terr3: stamp_at left is 1")
    check(T3.stamp_at(mk, 0.5, 0, 1) == 0, "terr3: stamp_at right is 0")
    -- outside the aspect-fit band (|dz| >= r/aspect) is 0, not clamped
    check(T3.stamp_at(mk, -0.5, 0.6, 1) == 0,
          "terr3: stamp_at outside the fit band is 0")
    -- a half-gray opaque texel weighs by luminance
    local mg = T3.stamp_mask("\128\128\128\255", 1, 1)
    check(math.abs(mg[1] - 128 / 255) < 1e-9,
          "terr3: gray stamps paint lighter")
  end

  -- the atlas bake (§4.5 nearest v1): stamp hash, baked texels, the
  -- atlas emit mode
  do
    local d3 = T3.fresh("bake", 2, 1, 2.0)
    check(T3.atlas_path("maps/vale.terr") == "maps/vale-atlas.png",
          "terr3: atlas path beside its map")
    local h1 = T3.mat_hash(d3)
    check(h1 ~= 0 and h1 == T3.mat_hash(d3),
          "terr3: mat_hash nonzero and stable")
    d3.mats[2] = { name = "dirt", col = { 1, 0, 0 }, tex = "" }
    local h2 = T3.mat_hash(d3)
    check(h2 ~= h1, "terr3: a new material changes the stamp")
    d3.mats[2].tex = "art/dirt.png"
    check(T3.mat_hash(d3) ~= h2, "terr3: a tex assignment changes the stamp")
    d3.mats[2].tex = ""
    d3.wts[2] = {}
    for i2 = 1, T3.plane_size(d3) do d3.wts[2][i2] = 0 end
    local h3 = T3.mat_hash(d3)
    d3.wts[2][3] = 255 -- the top-right vert goes full dirt
    check(T3.mat_hash(d3) ~= h3, "terr3: a paint edit changes the stamp")
    d3.wts[2][3] = 0
    check(T3.mat_hash(d3) == h3, "terr3: reverting restores the stamp")
    d3.hts[1] = 1.25 -- lighting bakes into the texels: sculpting stales
    check(T3.mat_hash(d3) ~= h3, "terr3: a sculpt edit changes the stamp")
    d3.hts[1] = 0
    check(T3.mat_hash(d3) == h3, "terr3: reverting a sculpt restores it")

    -- bake: 2x1 tiles at ts=2 -> 4x2 px; texels = albedo x shade x
    -- jitter x LIGHTING (the flat-ground L = amb + suncol*d, exactly
    -- the emitter's normal math). Lighting lives in the TEXELS because
    -- a vertex color clamps at 1.0 and flattens sunlit ground (the
    -- solid-green native report).
    local px1, W1, H1 = T3.bake_pixels(d3, nil, 2)
    check(W1 == 4 and H1 == 2 and #px1 == 4 * 2 * 4, "terr3: bake dims")
    local gcol = d3.mats[1].col
    local tm = cm.require("cm.terr")
    local function jof(vx, vz)
      return 1 + (tm.hash(31, vx, vz) - 0.5) * 0.10
    end
    -- texel (0,0): tile (0,0), fu=fv=0.25 on a FLAT doc: d = -sun.y
    local dd = -d3.sun[2] * (2.0 / math.sqrt(4.0))
    local L1 = d3.amb[1] + d3.suncol[1] * dd
    local jj = (jof(0, 0) * 0.75 + jof(1, 0) * 0.25) * 0.75
             + (jof(0, 1) * 0.75 + jof(1, 1) * 0.25) * 0.25
    local r0, g0, b0 = px1:byte(1, 3)
    check(r0 == math.min(255, (gcol[1] * jj * L1 * 255) // 1),
          "terr3: a flat texel is the lit material color")
    local px2 = T3.bake_pixels(d3, { [1] = function() return 0, 0, 1 end },
                               2)
    check(px2:byte(1) == 0 and px2:byte(3) == 255,
          "terr3: a sampler colors its material's texels")
    -- painted shade darkens the bake
    d3.shade = {}
    for i2 = 1, T3.plane_size(d3) do d3.shade[i2] = 127 end
    local px3 = T3.bake_pixels(d3, nil, 2)
    check(px3:byte(1) < r0, "terr3: painted shade darkens the bake")
    d3.shade = nil
    -- directional light survives the bake: a ridge's sun-facing tile
    -- bakes brighter than its away-facing twin
    local d4 = T3.fresh("ridge", 2, 1, 2.0)
    d4.hts[2] = 1.5 -- the middle column: tile 0 faces away, tile 1 sun
    d4.hts[5] = 1.5
    local px4 = T3.bake_pixels(d4, nil, 2)
    local away = px4:byte((0 * 4 + 1) * 4 + 2) -- texel (1,0), green
    local toward = px4:byte((0 * 4 + 3) * 4 + 2) -- texel (3,0), green
    check(toward > away,
          ("terr3: the bake keeps directional light (%d > %d)")
          :format(toward, away))

    -- atlas emit: map-normalized uvs, PURE WHITE vertex colors (the
    -- material mix, shade, jitter and lighting all live in the texels)
    local out3 = {}
    local n3 = T3.emit_terrain(out3, d3, { atlas = true })
    check(n3 == 4, "terr3: atlas emit tris")
    local ab = table.concat(out3)
    local _, _, _, u1, v1 = string.unpack("<fffff", ab, 1)
    check(u1 == 0 and v1 == 0, "terr3: atlas uv origin")
    local _, _, _, u2 = string.unpack("<fffff", ab, 6 * 24 + 1)
    check(u2 == 0.5, "terr3: atlas uv spans the map")
    check(ab:byte(21) == 255 and ab:byte(22) == 255 and ab:byte(23) == 255,
          "terr3: atlas verts are pure white")

    -- bake_into (the editor's budgeted live bake): a full image
    -- assembled from two row bands + a re-baked sub-rect is byte-
    -- identical to the one-shot bake_pixels
    local pxf = T3.bake_pixels(d3, nil, 2)
    local buf3 = pal.buf(nil, 4 * 2 * 4)
    T3.bake_into(d3, nil, 2, buf3, 0, 0, 3, 0) -- top row band
    T3.bake_into(d3, nil, 2, buf3, 0, 1, 3, 1) -- bottom row band
    check(buf3:str(0, 4 * 2 * 4) == pxf,
          "terr3: bake_into row bands == bake_pixels")
    buf3:setstr(4, "\0\0\0\0\0\0\0\0") -- scar two texels mid-row
    T3.bake_into(d3, nil, 2, buf3, 1, 0, 2, 0) -- re-bake just the rect
    check(buf3:str(0, 4 * 2 * 4) == pxf,
          "terr3: bake_into patches a sub-rect in place")
  end
end

local function t_terr3_smoothlight()
  -- the D140-addendum vote: terrain lighting is SMOOTH per vertex —
  -- central-difference normals, one color per shared vert, so quad
  -- seams are impossible by construction (per-face normals turned
  -- every sculpted tile into a visible plate; openworld's procedural
  -- field only hid it because its finest octave spans ~5 tiles)
  local T3 = cm.require("cm.terr3")
  local tm = cm.require("cm.terr")
  local d = T3.fresh("np", 1, 1, 2.0)
  d.hts[4] = 1.5 -- raise h11 only: the old scheme's worst case
  -- the emitter's exact per-vertex math (s=2, flat=2, hget clamps)
  local function vg(doc2, vx, vz)
    local function h(x, z) return tm.hget(doc2, x, z) end
    local nx = (h(vx - 1, vz) - h(vx + 1, vz)) / 4
    local nz = (h(vx, vz - 1) - h(vx, vz + 1)) / 4
    local nl = m.sqrt(nx * nx + 4 + nz * nz)
    local dd = m.max(0, -(nx / nl * doc2.sun[1] + 2 / nl * doc2.sun[2]
                          + nz / nl * doc2.sun[3]))
    local j = 1 + (tm.hash(31, vx, vz) - 0.5) * 0.10
    return m.clamp(doc2.mats[1].col[2] * j
                   * (doc2.amb[2] + doc2.suncol[2] * dd), 0, 1) * 255 // 1
  end
  local out = {}
  check(T3.emit_terrain(out, d) == 2, "smoothlight: 1x1 emits 2 tris")
  local vb = table.concat(out)
  -- verts are 24 bytes, A B C A C D; green = byte 22 of each vert
  check(vb:byte(0 * 24 + 22) == vg(d, 0, 0)
        and vb:byte(2 * 24 + 22) == vg(d, 1, 1),
        "smoothlight: verts carry the central-difference vertex tone")
  -- cross-QUAD continuity: on a 2x1 doc a shared vertex emits the
  -- IDENTICAL 24 bytes in both quads — the no-seam guarantee
  local d2 = T3.fresh("cont", 2, 1, 2.0)
  for i, h in ipairs({ 1, 2, 0, 3, 4, 1 }) do d2.hts[i] = h end
  local out2 = {}
  T3.emit_terrain(out2, d2)
  local vb2 = table.concat(out2)
  check(vb2:sub(1 * 24 + 1, 2 * 24) == vb2:sub(144 + 1, 144 + 24),
        "smoothlight: a shared vert is byte-identical across quads (B==A)")
  check(vb2:sub(2 * 24 + 1, 3 * 24) == vb2:sub(144 + 5 * 24 + 1, 144 + 144),
        "smoothlight: a shared vert is byte-identical across quads (C==D)")
  -- a FLAT doc keeps the historical flat-ground tone exactly
  local df = T3.fresh("fl", 1, 1, 2.0)
  local outf = {}
  T3.emit_terrain(outf, df)
  check(table.concat(outf):byte(22) == vg(df, 0, 0),
        "smoothlight: flat ground tone is unchanged")
  -- the atlas bake bilerps the four corner vertex light terms, exact
  local function jof(vx, vz)
    return 1 + (tm.hash(31, vx, vz) - 0.5) * 0.10
  end
  local function vl(vx, vz)
    local function h(x, z) return tm.hget(d, x, z) end
    local nx = (h(vx - 1, vz) - h(vx + 1, vz)) / 4
    local nz = (h(vx, vz - 1) - h(vx, vz + 1)) / 4
    local nl = m.sqrt(nx * nx + 4 + nz * nz)
    local dd = m.max(0, -(nx / nl * d.sun[1] + 2 / nl * d.sun[2]
                          + nz / nl * d.sun[3]))
    return d.amb[2] + d.suncol[2] * dd
  end
  local function bakeg(fu, fv)
    local jj = jof(0, 0) * (1 - fu) * (1 - fv) + jof(1, 0) * fu * (1 - fv)
             + jof(0, 1) * (1 - fu) * fv + jof(1, 1) * fu * fv
    local L = (vl(0, 0) * (1 - fu) + vl(1, 0) * fu) * (1 - fv)
            + (vl(0, 1) * (1 - fu) + vl(1, 1) * fu) * fv
    return m.clamp((d.mats[1].col[2] * jj * L * 255) // 1, 0, 255)
  end
  local px = T3.bake_pixels(d, nil, 2)
  check(px:byte((0 * 2 + 1) * 4 + 2) == bakeg(0.75, 0.25)
        and px:byte((1 * 2 + 0) * 4 + 2) == bakeg(0.25, 0.75),
        "smoothlight: bake texels bilerp the vertex light exactly")
  -- the spill contract the editor's stroke_patch rides: after a height
  -- edit at vertex v, re-baking tiles [v-2 .. v+1] alone reproduces
  -- the full re-bake byte-exactly (normals move at v+-1, colors at
  -- the tiles around them — nothing outside the widened rect)
  local d5 = T3.fresh("spill", 6, 6, 2.0)
  local px5 = T3.bake_pixels(d5, nil, 2)
  local buf5 = pal.buf(nil, 12 * 12 * 4)
  buf5:setstr(0, px5)
  d5.hts[3 * 7 + 3 + 1] = 2.0 -- sculpt vertex (3,3)
  local full5 = T3.bake_pixels(d5, nil, 2)
  T3.bake_into(d5, nil, 2, buf5, 2, 2, 9, 9) -- tiles 1..4 = the rect
  check(buf5:str(0, 12 * 12 * 4) == full5,
        "smoothlight: the widened stroke rect covers the light spill")
end

local function t_lathe_norms()
  -- D140: lathe/ball shading is smooth ALONG the profile — per-point
  -- normals averaged from adjacent segments; per-SEGMENT normals gave
  -- every latitude ring a hard circular lighting seam (the mascot)
  local gb = cm.require("cm.gb")
  -- two segments meeting at a right angle: point normals are exact
  local bk = gb.bake_lathe({ 0, -1, 1, 0, 0, 1 }, 4)
  local function slot(sidx)
    return bk.nrm[sidx * 3 + 1], bk.nrm[sidx * 3 + 2], bk.nrm[sidx * 3 + 3]
  end
  -- band 0 i=0 records kb0,kb1,ka0,ka1 = slots 0..3 (ring1, ring1,
  -- ring0, ring0 at angles 0/1); band 1 i=0 records slots 16..19
  local x0, y0, z0 = slot(0)  -- ring 1 @ angle 0, from band 0 (b side)
  local x1, y1, z1 = slot(18) -- ring 1 @ angle 0, from band 1 (a side)
  check(x0 == x1 and y0 == y1 and z0 == z1,
        "lathe: a shared ring wears ONE normal on both sides (no seam)")
  check(m.abs(x0 - 1) < 1e-12 and m.abs(y0) < 1e-12 and m.abs(z0) < 1e-12,
        "lathe: the averaged right-angle point normal is exact")
  local ex, ey, ez = slot(2) -- ring 0 (an endpoint): its single segment
  local s2 = m.sqrt(2) / 2
  check(m.abs(ex - s2) < 1e-12 and m.abs(ey + s2) < 1e-12
        and m.abs(ez) < 1e-12,
        "lathe: an endpoint keeps its segment perpendicular")
  -- the immediate emitter matches the bake byte-for-byte (same
  -- normals through the same expressions — the D137 bake contract)
  local m4 = cm.require("cm.m4")
  local xf = m4.translate(0, 0, 0)
  local col = { 0.5, 0.6, 0.7 }
  local o1, o2 = {}, {}
  gb.lathe(o1, xf, { 0, -1, 1, 0, 0, 1 }, 4, col)
  local ref = { nv = bk.nv, ns = bk.ns, pos = bk.pos, uv = bk.uv,
                ni = bk.ni, nrm = bk.nrm, lit = {}, blob = false }
  gb.emit_baked(o2, xf, xf, ref, col)
  check(table.concat(o1) == table.concat(o2),
        "lathe: immediate emit == baked emit bytes")
end

local function t_walk()
  local W = cm.require("cm.walk")
  local cx, cz = W.cell(8, -3.2, 9.7)
  check(cx == 0 and cz == 7, "walk.cell clamps into the grid")
  cx, cz = W.cell(8, 3.7, 0.2)
  check(cx == 3 and cz == 0, "walk.cell floors world coords")
  local blocked = {}
  local function ok(x, z)
    return x >= 0 and x < 8 and z >= 0 and z < 8 and not blocked[z * 8 + x]
  end
  cx, cz = W.snap(8, ok, 3, 3, 2)
  check(cx == 3 and cz == 3, "walk.snap walkable cell is itself")
  blocked[3 * 8 + 3] = true
  cx, cz = W.snap(8, ok, 3, 3, 2)
  check(ok(cx, cz) and m.max(m.abs(cx - 3), m.abs(cz - 3)) == 1,
        "walk.snap finds the nearest ring")
  check(W.snap(8, function() return false end, 3, 3, 2) == nil,
        "walk.snap nil past r rings")
  blocked = {}
  local path = W.astar(8, ok, 0, 0, 3, 0)
  check(#path == 3 and path[3] == 3, "walk.astar straight line")
  path = W.astar(8, ok, 0, 0, 2, 2)
  check(#path == 2 and path[2] == 2 * 8 + 2, "walk.astar diagonals count one")
  check(#W.astar(8, ok, 4, 4, 4, 4) == 0, "walk.astar start==goal is empty")
  blocked[0 * 8 + 1] = true -- wall at (1,0): no corner cutting past it
  path = W.astar(8, ok, 0, 0, 2, 0)
  check(path and #path == 4 and path[4] == 2,
        "walk.astar routes around, no corner cut")
  blocked = { [0 * 8 + 5] = true }
  check(W.astar(8, ok, 0, 0, 5, 0) == nil,
        "walk.astar unwalkable goal refuses")
  blocked = {}
  -- raycast: march + bisect over an analytic ground
  local x, z = W.raycast(function() return 0 end, 0, 10, 0, 1, -1, 0)
  check(near(x, 10, 1e-2) and z == 0, "walk.raycast flat ground hit")
  x, z = W.raycast(function(gx) return gx end, 0, 1, 0, 1, 0, 0)
  check(near(x, 1, 1e-2), "walk.raycast sloped ground hit")
  check(W.raycast(function() return 0 end, 0, 10, 0, 0, 1, 0) == nil,
        "walk.raycast miss is nil")
  -- command + step over a real walker buffer (layout is the module's)
  local buf = pal.buf("st.walk", 40 + 16 * 4)
  buf:f32(0, 0.5); buf:f32(4, 0.5)
  check(W.command(buf, 16, 8, ok, 3.7, 0.5, 2, 30) == true,
        "walk.command paths to a walkable point")
  check(buf:u32(16) == 3 and buf:u32(20) == 0 and buf:f32(32) == 30,
        "walk.command stores the chain and arms the marker")
  check(W.moving(buf), "walk.moving while the chain is live")
  for _ = 1, 3 do W.step(buf, 8, 60, 1) end
  check(near(buf:f32(0), 3.5, 1e-5) and near(buf:f32(4), 0.5, 1e-5),
        "walk.step arrives at the goal cell center")
  check(not W.moving(buf) and buf:u32(20) == 3,
        "walk.step consumed the chain")
  check(near(buf:f32(12), 3, 1e-5), "walk.step accumulates dist_phase")
  check(near(buf:f32(8), m.pi / 2, 1e-4), "walk.step eases facing to travel")
  check(buf:f32(32) == 27, "walk.step decays the marker ttl")
  check(W.command(buf, 16, 8, function() return false end, 5, 5, 1, 30)
        == false and buf:u32(16) == 3,
        "walk.command refusal leaves the walker untouched")
  pal.buf_free("st.walk")
end

local function t_rig()
  local rig = cm.require("cm.rig")
  local input = cm.require("cm.input")
  check(near(rig.angdiff(m.pi / 2, 0), m.pi / 2, 1e-6)
        and near(rig.angdiff(0, m.pi / 2), -m.pi / 2, 1e-6)
        and near(rig.angdiff(m.tau + 0.1, 0), 0.1, 1e-6)
        and near(rig.angdiff(-0.1, 0.1), -0.2, 1e-6),
        "rig.angdiff shortest arc")
  -- a fake f32 accessor (the injected-fake precedent): rig owns the layout,
  -- the store is any :f32(off[,v]) object
  local mem = {}
  local cam = { f32 = function(_, off, val)
    if val ~= nil then mem[off] = val else return mem[off] or 0 end
  end }
  local kc = rig.defaults()
  input.map({ { "cam_l", input.key.left }, { "cam_r", input.key.right },
              { "cam_u", input.key.up }, { "cam_d", input.key.down },
              { "recenter", input.key.c } })
  rig.reset(cam, kc, 10, 0, 0, 0)
  check(near(cam:f32(0), m.pi, 1e-9) and cam:f32(8) == kc.dist
        and cam:f32(12) == 10, "rig.reset seeds behind the facing")
  -- still target: nothing moves (no input in this cartridge)
  rig.step(cam, kc, 10, 0, 0, 0, 0, 0)
  check(near(cam:f32(0), m.pi, 1e-6) and cam:f32(12) == 10,
        "rig.step holds on a still target")
  -- the focus chases by pos_lerp
  rig.step(cam, kc, 20, 0, 0, 0, 0, 0)
  check(near(cam:f32(12), 11, 1e-9), "rig.step focus chases the target")
  -- yaw-follow eases behind a sideways run; the back cone holds instead
  mem = {}
  rig.step(cam, kc, 0, 0, 0, 5, 0, 0)
  check(near(cam:f32(0), -m.pi / 2 * kc.yaw_follow * kc.yaw_lerp, 1e-6),
        "rig.step yaw-follow circles a sideways run")
  mem = {}
  rig.step(cam, kc, 0, 0, 0, 0, 5, 0)
  check(cam:f32(0) == 0, "rig.step back cone: into-camera run holds yaw")
  mem = {}
  rig.step(cam, kc, 0, 0, 0, 0, -5, 0)
  check(cam:f32(0) == 0, "rig.step away-run heading is already behind")
  -- a manual hold pauses yaw-follow and decays
  mem = {}
  cam:f32(24, 10)
  rig.step(cam, kc, 0, 0, 0, 5, 0, 0)
  check(cam:f32(0) == 0 and cam:f32(24) == 9,
        "rig.step hold pauses yaw-follow and decrements")
  -- recenter: eases to behind-the-facing, snaps + clears when close (seed
  -- yaw at 1 so the arc to pi is unambiguous — from 0 the sign of
  -- angdiff(pi, 0) hangs on sin(pi) rounding)
  mem = {}
  cam:f32(0, 1); cam:f32(36, 1)
  rig.step(cam, kc, 0, 0, 0, 0, 0, 0)
  check(near(cam:f32(0), 1 + (m.pi - 1) * kc.recenter_lerp, 1e-6)
        and cam:f32(36) == 1, "rig.step recenter eases toward tyaw+pi")
  mem = {}
  cam:f32(0, m.pi - 0.005); cam:f32(4, 0.005); cam:f32(36, 1)
  rig.step(cam, kc, 0, 0, 0, 0, 0, 0)
  check(near(cam:f32(0), m.pi, 1e-9) and cam:f32(4) == 0 and cam:f32(36) == 0,
        "rig.step recenter snaps and clears when converged")
  -- captured-cursor look (v21): an applied MREL record steers the orbit
  -- with the drag-look knobs; a v1 record afterwards is inert
  mem = {}
  local v1 = string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0)
  input.apply(v1 .. string.pack("<I1I1i2i2", 2, 4, 10, 4))
  rig.step(cam, kc, 0, 0, 0, 0, 0, 0)
  check(near(cam:f32(0), -10 * kc.mouse_yaw, 1e-6)
        and near(cam:f32(4), 4 * kc.mouse_pitch, 1e-6)
        and cam:f32(24) == kc.hold_frames - 1,
        "rig.step mouse-look from the recorded MREL deltas")
  mem = {}
  input.apply(v1)
  rig.step(cam, kc, 0, 0, 0, 0, 0, 0)
  check(cam:f32(0) == 0 and cam:f32(4) == 0,
        "rig.step v1 record moves nothing")

  -- wish: camera-relative unit vector from orbit yaw
  mem = {}
  local wx, wz = rig.wish(cam, 1, 0)
  check(near(wx, 0, 1e-6) and near(wz, -1, 1e-6), "rig.wish forward at yaw 0")
  wx, wz = rig.wish(cam, 0, 1)
  check(near(wx, 1, 1e-6) and near(wz, 0, 1e-6), "rig.wish right at yaw 0")
  wx, wz = rig.wish(cam, 1, 1)
  check(near(wx * wx + wz * wz, 1, 1e-6), "rig.wish diagonal is unit")
  wx, wz = rig.wish(cam, 0, 0)
  check(wx == 0 and wz == 0, "rig.wish zero input is zero")
  -- view: at pitch 0 / knob dist the eye hangs behind at the knob height,
  -- and the matrix maps its own eye to the view origin
  mem = {}
  cam:f32(8, kc.dist)
  local V = rig.view(cam, kc)
  local ex, ey, ez = 0, kc.height, kc.dist
  local vx2, vy2, vz2 = cm.require("cm.m4").apply(V, ex, ey, ez)
  check(near(vx2, 0, 1e-3) and near(vy2, 0, 1e-3) and near(vz2, 0, 1e-3),
        "rig.view maps the derived eye to the origin")
end

local function t_input_mrel()
  local input = cm.require("cm.input")
  -- extension walk (the apply() framing): tag -> payload, for asserting
  -- what a record does and does not carry
  local function exts(rec)
    local out, pos = {}, 11
    while pos <= #rec do
      local tag, len = rec:byte(pos), rec:byte(pos + 1)
      out[tag] = rec:sub(pos + 2, pos + 1 + len)
      pos = pos + 2 + len
    end
    return out
  end
  local function motion(rx, ry)
    return { type = "motion", x = 0, y = 0, rx = rx, ry = ry }
  end

  -- dormant domain: relative motion arrives but no capture was ever asked
  -- for — the record carries no MREL and applied deltas stay zero
  input.mrel_reset()
  local rec = input.collect({ motion(5.0, 2.0) })
  check(exts(rec)[2] == nil, "mrel: dormant domain emits no extension")
  input.apply(rec)
  local dx, dy = input.mouse_rel()
  check(dx == 0 and dy == 0, "mrel: dormant domain reads (0,0)")

  -- capture latches the domain; deltas floor to whole px, remainder carried
  input.capture_mouse(true) -- headless: no OS capture, the latch still arms
  rec = input.collect({ motion(3.7, -1.2) })
  local p = exts(rec)[2]
  check(p and #p == 4, "mrel: captured domain emits the 4-byte extension")
  input.apply(rec)
  dx, dy = input.mouse_rel()
  check(dx == 3 and dy == -1, "mrel: whole-px deltas apply")
  -- carries (0.7, -0.2) + (0.5, 0) -> emits (1, 0), keeps (0.2, -0.2)
  input.apply(input.collect({ motion(0.5, 0) }))
  dx, dy = input.mouse_rel()
  check(dx == 1 and dy == 0, "mrel: fractional carry completes")

  -- a still frame still carries the extension (zeros), and a bare v1
  -- record resets the applied delta — replayed v1 traces read no motion
  input.apply(input.collect({}))
  dx, dy = input.mouse_rel()
  check(dx == 0 and dy == 0, "mrel: still frame applies (0,0)")
  input.apply(input.collect({ motion(9.0, 9.0) }))
  input.apply(string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0))
  dx, dy = input.mouse_rel()
  check(dx == 0 and dy == 0, "mrel: a v1 record zeroes the delta")

  -- malformed MREL errors loudly; an unknown tag is skipped
  local v1 = string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0)
  check(not pcall(input.apply, v1 .. string.pack("<I1I1i1i2", 2, 3, 1, 1)),
        "mrel: malformed extension refused")
  check(pcall(input.apply, v1 .. string.pack("<I1I1I4", 9, 4, 0)),
        "mrel: unknown tag skipped")

  -- reset drops the latch: records go extension-free again
  input.mrel_reset()
  rec = input.collect({ motion(2.0, 2.0) })
  check(exts(rec)[2] == nil, "mrel: reset ends the domain")

  -- the capture pump (D126): capture_mouse is a WISH, the pump derives
  -- the OS state every tick from wish AND the shell's consent. Headless
  -- the PAL no-ops, so these observe the reconciled flag (captured()).
  input.mrel_reset()
  check(input.captured() == false, "cap: fresh domain is uncaptured")
  input.capture_mouse(true)
  check(input.captured() == false, "cap: a wish alone captures nothing")
  input.capture_pump(false)
  check(input.captured() == false, "cap: wish without consent stays out")
  input.capture_pump(true)
  check(input.captured() == true, "cap: wish + consent engages")
  input.capture_pump(false)
  check(input.captured() == false, "cap: withdrawn consent releases")
  input.capture_pump(true)
  check(input.captured() == true, "cap: returned consent re-engages")
  input.capture_mouse(false)
  input.capture_pump(true)
  check(input.captured() == false, "cap: a dropped wish releases")
  rec = input.collect({})
  check(exts(rec)[2] ~= nil, "cap: the MREL domain outlives the wish")
  input.capture_mouse(true)
  input.capture_pump(true)
  input.mrel_reset()
  check(input.captured() == false, "cap: reset clears wish and state")
  input.capture_pump(true)
  check(input.captured() == false, "cap: no wish survives a reset")
end

-- the FSIZ extension (D123): the frame's live target size as recorded sim
-- input — a LATCH (a bare record keeps the last size), design-res fallback
local function t_input_fsiz()
  local input = cm.require("cm.input")
  local view = cm.require("cm.view")
  local function exts(rec)
    local out, pos = {}, 11
    while pos <= #rec do
      local tag, len = rec:byte(pos), rec:byte(pos + 1)
      out[tag] = rec:sub(pos + 2, pos + 1 + len)
      pos = pos + 2 + len
    end
    return out
  end

  -- dormant domain: no extension, and reads fall back to the design res
  input.fsiz_reset()
  local rec = input.collect({})
  check(exts(rec)[3] == nil, "fsiz: dormant domain emits no extension")
  input.apply(rec)
  local w, h = input.game_size() -- this read latches the domain
  check(w == view.cfg.ref_w and h == view.cfg.ref_h,
        "fsiz: unsized state reads the design res")

  -- latched: every record carries the live target; apply makes it the read
  rec = input.collect({})
  local p = exts(rec)[3]
  check(p and #p == 4, "fsiz: a latched domain emits the 4-byte extension")
  input.apply(rec)
  local gw, gh = pal.gfx_size()
  w, h = input.game_size()
  check(w == gw and h == gh, "fsiz: the applied record carries the target")

  -- a bare v1 record KEEPS the applied size (latch, not a delta) — and a
  -- hand-built sized record is the authority over the live target
  input.apply(string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0))
  w, h = input.game_size()
  check(w == gw and h == gh, "fsiz: a bare v1 record keeps the last size")
  input.apply(string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0)
              .. string.pack("<I1I1i2i2", 3, 4, 320, 180))
  w, h = input.game_size()
  check(w == 320 and h == 180, "fsiz: the recorded size is the authority")

  -- malformed refused loudly
  local v1 = string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0)
  check(not pcall(input.apply, v1 .. string.pack("<I1I1i2", 3, 2, 64)),
        "fsiz: malformed extension refused")

  -- reset drops the latch AND the applied size
  input.fsiz_reset()
  rec = input.collect({})
  check(exts(rec)[3] == nil, "fsiz: reset ends the domain")
  w, h = input.game_size()
  check(w == view.cfg.ref_w and h == view.cfg.ref_h,
        "fsiz: reset forgets the applied size")

  -- the non-latching chrome read (the replay-follow door): nil when
  -- unsized, the applied size after, and reading it never arms the domain
  input.fsiz_reset()
  check(input.fsiz_applied() == nil, "fsiz: applied reads nil when unsized")
  rec = input.collect({})
  check(exts(rec)[3] == nil, "fsiz: the applied read never latches")
  input.apply(string.pack("<I4i2i2I1i1", 0, 0, 0, 0, 0)
              .. string.pack("<I1I1i2i2", 3, 4, 426, 240))
  local aw, ah = input.fsiz_applied()
  check(aw == 426 and ah == 240, "fsiz: applied reads the recorded size")
  input.fsiz_reset() -- leave the cartridge's domain clean
end

-- the atlas shipped-bake snapshot (D124): a finished bake exports as PNG
-- and imports byte-identical into a fresh atlas of the same layout
local function t_atlas_snapshot()
  local atlas = cm.require("cm.atlas")
  local function texel(wx, wz) -- a position-dependent, exact pattern
    return (wx * 31) % 256, (wz * 57) % 256, (wx + wz) % 256
  end
  local a = atlas.build{ pixels = "rc.st.atl1", state = "rc.st.atls1",
                         n = 2, tile = 1.0, stamp = 7 }
  local none, why = atlas.export(a)
  check(none == nil and why == "bake not finished",
        "atlas: export refuses an unfinished bake")
  atlas.bake(a, 4, texel)
  check(atlas.done(a), "atlas: 4 tiles bake in one budget-4 call")
  local png = atlas.export(a)
  check(type(png) == "string" and #png > 8, "atlas: a finished bake exports")
  local b = atlas.build{ pixels = "rc.st.atl2", state = "rc.st.atls2",
                         n = 2, tile = 1.0, stamp = 7 }
  check(not atlas.done(b), "atlas: the fresh twin starts unbaked")
  check(atlas.import(b, png) == true, "atlas: the export imports")
  check(atlas.done(b), "atlas: an imported bake reads done")
  check(b.buf:str(0, b.sx * b.sy * 4) == a.buf:str(0, a.sx * a.sy * 4),
        "atlas: imported pixels are byte-identical to the bake")
  local c = atlas.build{ pixels = "rc.st.atl3", state = "rc.st.atls3",
                         n = 3, tile = 1.0, stamp = 7 }
  local ok3, why3 = atlas.import(c, png)
  check(ok3 == nil and why3:find("want"),
        "atlas: a layout-mismatched import refuses")
  check(atlas.import(b, "not a png") == nil, "atlas: garbage bytes refuse")
  pal.tex_free(a.tex); pal.tex_free(b.tex); pal.tex_free(c.tex)
  pal.buf_free("rc.st.atl1"); pal.buf_free("rc.st.atls1")
  pal.buf_free("rc.st.atl2"); pal.buf_free("rc.st.atls2")
  pal.buf_free("rc.st.atl3"); pal.buf_free("rc.st.atls3")
end

local function t_figverts()
  local gb = cm.require("cm.gb")
  local m4 = cm.require("cm.m4")
  -- the C door (pal.x_figverts) must reproduce the Lua reference loop
  -- byte-for-byte — same doubles, same expression order — across every
  -- shape kind, under a deforming xf with a rigid nxf (the squash case)
  local xf = m4.mul(m4.mul(m4.translate(1.5, 2.5, -3.5), m4.rotx(0.7)),
                    m4.scale(1.2, 0.8, 1.0))
  local nxf = m4.mul(m4.roty(0.4), m4.rotx(-0.2))
  local col = { 0.83, 0.51, 0.32 }
  local shapes = {
    { name = "lathe", bk = gb.bake_lathe({ 0, -1, 0.5, -0.5, 0.7, 0.3,
                                           0, 1 }, 12), alpha = 200 },
    { name = "ball", bk = gb.bake_ball(0.8, 10) },
    { name = "prism", bk = gb.bake_prism(6, 0.5, 0.34, 1.05, 3) },
    { name = "gbox", bk = gb.bake_gbox({ 1, 2, 0.5 }, { 0, 1, 0 }, 0.7) },
  }
  for _, s in ipairs(shapes) do
    local bk = s.bk
    local ref = { nv = bk.nv, ns = bk.ns, pos = bk.pos, uv = bk.uv,
                  ni = bk.ni, nrm = bk.nrm, lit = {}, blob = false }
    local o1, o2 = {}, {}
    local n1 = gb.emit_baked(o1, xf, nxf, ref, col, s.alpha)
    local n2 = gb.emit_baked(o2, xf, nxf, bk, col, s.alpha)
    check(bk.blob and bk.blob ~= false, "figverts: " .. s.name .. " built a blob")
    check(n1 == n2 and n1 > 0, "figverts: " .. s.name .. " tri counts agree")
    check(table.concat(o1) == table.concat(o2),
          "figverts: " .. s.name .. " C bytes == Lua reference bytes")
  end
  -- refusals: an undersized blob and an out-of-range alpha error loudly
  local bk = shapes[1].bk
  check(not pcall(pal.x_figverts, bk.blob, bk.nv + 1, xf, nxf,
                  gb.sun, gb.ambient, col, 255),
        "figverts: oversized nv refused")
  check(not pcall(pal.x_figverts, bk.blob, bk.nv, xf, nxf,
                  gb.sun, gb.ambient, col, 300),
        "figverts: out-of-range alpha refused")
end

local function t_fig_file()
  -- the .fig asset (CFIG, E5, D137): codec + doc helpers the figure
  -- window drives, and the mascot converter's byte-exact contract.
  local F = cm.require("cm.fig")
  local m4 = cm.require("cm.m4")
  local mascot = cm.require("cm.mascot")

  -- fresh: valid starter; canonical round trip
  local doc = F.fresh("hero")
  check(#doc.parts == 3 and #doc.clips == 1, "fig: fresh starter shape")
  local b1 = F.encode(doc)
  check(b1:sub(1, 4) == "CFIG", "fig: CFIG magic")
  check(F.encode(F.decode(b1)) == b1, "fig: canonical round trip (fresh)")

  -- features round trip: every shape kind, alpha/caps flags, sparse keys
  local fd = F.fresh("kinds")
  fd.parts[1].shapes = {
    { kind = "gbox", col = { 0.2, 0.3, 0.4 }, size = { 1, 2, 0.5 },
      center = { 0, 1, 0 } },
    { kind = "prism", col = { 0.5, 0.5, 0.5 }, n = 6, r0 = 0.5,
      r1 = 0.3, h = 1.2, caps = true },
    { kind = "lathe", col = { 0.6, 0.2, 0.2 }, n = 8,
      prof = { 0, -1, 0.5, 0, 0, 1 }, alpha = 128 },
    { kind = "ball", col = { 0.9, 0.9, 0.9 }, r = 0.4, n = 8,
      at = { 0, 1, 0 }, scale = { 1, 0.5, 1 } },
    { kind = "mesh", col = { 1, 1, 1 }, path = "art/hat.msh" },
  }
  fd.clips[1].keys = { { base = { 0.1, nil, nil, nil, 0.5 } }, {} }
  local b2 = F.encode(fd)
  local d2 = F.decode(b2)
  check(F.encode(d2) == b2, "fig: canonical round trip (features)")
  check(d2.parts[1].shapes[2].caps == true
        and d2.parts[1].shapes[3].alpha == 128
        and d2.parts[1].shapes[5].path == "art/hat.msh",
        "fig: shape features survive")
  check(d2.clips[1].keys[1].base[1] == 0.1
        and d2.clips[1].keys[1].base[2] == nil
        and d2.clips[1].keys[1].base[5] == 0.5,
        "fig: sparse pose channels survive exactly")

  -- refusals
  check(not pcall(F.decode, "XXXX" .. b2:sub(5)), "fig: bad magic refuses")
  check(not pcall(F.decode, b2:sub(1, #b2 - 6)), "fig: truncation refuses")
  do
    local bad = F.fresh("bad")
    bad.parts[2].parent = "nope"
    local bb = F.encode(bad)
    check(not pcall(F.decode, bb), "fig: undefined parent refuses")
  end

  -- THE converter contract: the shipped mascot.fig is byte-identical to
  -- a fresh conversion, and its decoded figure emits BYTE-EXACTLY what
  -- the code mascot emits (f64 floats end to end)
  local stock = pal.read_file("engine/stock/fig/mascot.fig")
  check(stock ~= nil, "fig: stock mascot.fig ships")
  local mdoc = F.doc_of(mascot.fig, "mascot", {
    { name = "idle", rate = 0.6, loop = true, keys = mascot.idle },
    { name = "walk", rate = 1.6, loop = true, keys = mascot.walk },
    { name = "swim", rate = 1.0, loop = true, keys = mascot.swim },
    { name = "wave", rate = 1.0, loop = true, keys = mascot.wave },
  })
  check(F.encode(mdoc) == stock, "fig: mascot.fig == a fresh conversion")
  local fdoc = F.decode(stock)
  local ffg = F.build_doc(fdoc)
  local pose_f = F.cycle(fdoc.clips[2].keys, 0.3)
  local pose_c = F.cycle(mascot.walk, 0.3)
  local o1, o2 = {}, {}
  local n1 = F.emit(o1, mascot.fig, m4.ident(), pose_c)
  local n2 = F.emit(o2, ffg, m4.ident(), pose_f)
  check(n1 == n2 and table.concat(o1) == table.concat(o2),
        "fig: file mascot emits byte-exactly the code mascot")

  -- joints: world positions ride the emit chain (identity pose = summed
  -- parent joints; a base translation moves every child)
  local js = F.joints(mascot.fig, {})
  check(math.abs(js[1][2] - 0.95) < 1e-12, "fig: base joint at 0.95")
  local js2 = F.joints(mascot.fig, { base = { 0, 0, 0, 1, 0, 0 } })
  check(math.abs(js2[3][1] - (js[3][1] + 1)) < 1e-12,
        "fig: base tx carries children")

  -- mirror_lr: creates/updates the _r twin x-negated
  local md = F.fresh("m")
  md.parts[#md.parts + 1] = {
    name = "arm_l", parent = "body", joint = { 0.4, 0.2, 0 },
    shapes = { { kind = "ball", col = { 1, 0, 0 }, r = 0.1, n = 6,
                 at = { 0.1, 0, 0 } } },
  }
  local ti = F.mirror_lr(md, #md.parts)
  check(ti and md.parts[ti].name == "arm_r"
        and md.parts[ti].joint[1] == -0.4
        and md.parts[ti].shapes[1].at[1] == -0.1,
        "fig: mirror_lr negates x geometry")
  check(F.mirror_lr(md, 1) == nil, "fig: mirror needs a *_l part")

  -- remove_part: children reparent, clips forget the part
  local rd = F.fresh("r")
  rd.clips[1].keys[1].body = { 0.5 }
  check(F.remove_part(rd, 2), "fig: remove_part")
  check(#rd.parts == 2 and rd.parts[2].name == "head"
        and rd.parts[2].parent == "base"
        and rd.clips[1].keys[1].body == nil,
        "fig: children reparent + clips forget")

  -- build_doc resolves mesh shapes through the read callback
  local ME = cm.require("cm.mesh")
  local mshb = ME.encode(ME.fresh("hat"))
  local hd = F.fresh("h")
  hd.parts = { { name = "base", joint = { 0, 0, 0 }, shapes = {
    { kind = "mesh", col = { 1, 1, 1 }, path = "art/hat.msh" } } } }
  local hfg = F.build_doc(hd, function(path)
    return path == "art/hat.msh" and mshb or nil
  end)
  local ho = {}
  local hn = F.emit(ho, hfg, m4.ident(), {})
  check(hn == 12, "fig: mesh shape emits through the figure (12 tris)")
  local hfg2 = F.build_doc(hd) -- no read: draws nothing, honestly
  local ho2 = {}
  check(F.emit(ho2, hfg2, m4.ident(), {}) == 0,
        "fig: unresolved mesh shape draws nothing")
end

local function t_console_sel()
  -- the console log's drag-selection (D118's console half): pure pick /
  -- extract / escape math with an injected measure — the t_help_sel model
  local con = cm.require("cm.ed.win.console")
  -- fake measure: 10 px per CODEPOINT (utf8-aware like the real font)
  local function measure(s)
    local n = 0
    for _ in s:gmatch("[\x01-\x7f\xc2-\xfd][\x80-\xbf]*") do n = n + 1 end
    return n * 10
  end
  check(con.pick_ci("hello", -3, 12, measure) == 0, "consel: left gutter is 0")
  check(con.pick_ci("hello", 14, 12, measure) == 1,
        "consel: mid-glyph snaps to the nearer edge (left)")
  check(con.pick_ci("hello", 17, 12, measure) == 2,
        "consel: mid-glyph snaps to the nearer edge (right)")
  check(con.pick_ci("hello", 999, 12, measure) == 5, "consel: past the end")
  -- utf8: never lands mid-codepoint ("é" is 2 bytes)
  check(con.pick_ci("a\xc3\xa9x", 13, 12, measure) == 1
        and con.pick_ci("a\xc3\xa9x", 18, 12, measure) == 3,
        "consel: utf8 boundaries only")
  local lines = { "  0.001 > one", "  0.002 = two", "  0.003 three" }
  check(con.sel_text(lines, { li = 1, ci = 8 }, { li = 1, ci = 13 })
        == "> one", "consel: single-line span")
  check(con.sel_text(lines, { li = 1, ci = 8 }, { li = 3, ci = 13 })
        == "> one\n  0.002 = two\n  0.003 three",
        "consel: multi-line span keeps whole middles")
  check(con.sel_text(lines, { li = 3, ci = 13 }, { li = 1, ci = 8 })
        == "> one\n  0.002 = two\n  0.003 three",
        "consel: endpoints normalize either way")
  -- escape clears an active selection and consumes; idle consumes nothing
  local win = { id = 990101 }
  local sl = con.sel_of(win)
  sl.a, sl.b = { li = 1, ci = 0 }, { li = 2, ci = 3 }
  check(con.escape(win) == true and sl.a == nil,
        "consel: escape clears and consumes")
  check(con.escape({ id = 990102 }) == false,
        "consel: nothing selected, nothing consumed")
end

-- ---- cm.ui keyboard/pad navigation (D128, A8 accessibility) ----

local function t_ui_nav()
  local ui = cm.require("cm.ui")

  -- pure spatial pick over a 2x2 grid + a wide bottom row:
  --   A(0,0)   B(50,0)
  --   C(0,20)  D(50,20)
  --   E(0,40, full width)
  local G = {
    { id = "A", x = 0, y = 0, w = 40, h = 10 },
    { id = "B", x = 50, y = 0, w = 40, h = 10 },
    { id = "C", x = 0, y = 20, w = 40, h = 10 },
    { id = "D", x = 50, y = 20, w = 40, h = 10 },
    { id = "E", x = 0, y = 40, w = 90, h = 10 },
  }
  check(ui.nav_pick(G, nil, "down") == "A", "uinav: no cursor picks first")
  check(ui.nav_pick(G, "zz", "up") == "A", "uinav: stale cursor picks first")
  check(ui.nav_pick({}, nil, "down") == nil, "uinav: empty list picks none")
  check(ui.nav_pick(G, "A", "down") == "C",
        "uinav: down lands the aligned next row, not the diagonal")
  check(ui.nav_pick(G, "C", "down") == "E", "uinav: down again reaches E")
  check(ui.nav_pick(G, "A", "right") == "B",
        "uinav: right walks the row, not the closer-x next row")
  check(ui.nav_pick(G, "E", "down") == "A",
        "uinav: down off the bottom wraps to the top")
  check(ui.nav_pick(G, "A", "up") == "E",
        "uinav: up off the top wraps to the bottom")
  check(ui.nav_pick(G, "B", "right") == "A",
        "uinav: right off the row end wraps to the row start")
  local col = { { id = "A", x = 0, y = 0, w = 40, h = 10 },
                { id = "C", x = 0, y = 20, w = 40, h = 10 } }
  check(ui.nav_pick(col, "A", "left") == nil,
        "uinav: sideways in a single column stays put")
  -- the shadow rule: down from a full-width row must land the NEXT row's
  -- overlapping widget, never skip to a better-ALIGNED distant row (the
  -- options menu's fullscreen row above two button columns above a
  -- centered third column)
  local F = {
    { id = "full", x = 0, y = 0, w = 210, h = 10 },
    { id = "colL", x = 0, y = 20, w = 100, h = 10 },
    { id = "colR", x = 110, y = 20, w = 100, h = 10 },
    { id = "mid", x = 70, y = 40, w = 70, h = 10 },
  }
  check(ui.nav_pick(F, "full", "down") == "colL",
        "uinav: down from a full row lands the next row (shadow rule)")
  check(ui.nav_pick(F, "colL", "down") == "mid",
        "uinav: down from a column falls through to the overlapping row")

  -- integration: real ui frames with synthetic key/pad events. The scope
  -- engages one frame after the first claim (the imgui latency), items
  -- register while claimed, the cursor seeds onto the first item.
  local clicks, vol = {}, 50
  local function menu()
    ui.nav_scope()
    ui.begin_panel("t_nav", 0, 0, 120, 90)
    if ui.button("alpha") then clicks.alpha = (clicks.alpha or 0) + 1 end
    if ui.button("beta") then clicks.beta = (clicks.beta or 0) + 1 end
    local v, ch = ui.slider("vol", vol, 0, 100, { id = "vol" })
    if ch then vol = v end
    ui.end_panel()
  end
  local function frame(evs)
    ui.frame(evs or {})
    menu()
    ui.frame_end()
  end
  local function key(sc) return { type = "key", scancode = sc, down = true,
                                  rep = false } end
  ui.nav.id, ui.nav.want, ui.nav.on = nil, false, false
  ui.nav.held, ui.nav.ax, ui.nav.dir = {}, { 0, 0 }, nil
  frame() -- claim; nav engages next frame
  frame() -- items register; the cursor seeds onto the first widget
  check(ui.nav.id == "t_nav/alpha", "uinav: cursor seeds the first widget")
  frame({ key(81) }) -- down arrow
  check(ui.nav.id == "t_nav/beta", "uinav: down arrow moves the cursor")
  frame({ key(81) })
  check(ui.nav.id == "t_nav/vol", "uinav: cursor reaches the slider")
  frame({ key(80) }) -- left on an adjustable widget steps it, no move
  check(vol == 45 and ui.nav.id == "t_nav/vol",
        "uinav: left steps the slider down by (max-min)/20")
  frame({ key(79) })
  check(vol == 50, "uinav: right steps the slider back up")
  frame({ key(82) }) -- up
  frame({ key(82) })
  check(ui.nav.id == "t_nav/alpha", "uinav: up arrows walk back to the top")
  frame({ key(40) }) -- Enter
  check(clicks.alpha == 1, "uinav: Enter clicks the cursored button")
  frame({ { type = "gpadbtn", button = 12, down = true } }) -- dpad down
  check(ui.nav.id == "t_nav/beta", "uinav: dpad down moves the cursor")
  for _ = 1, 18 do frame() end -- held: repeat kicks in after the delay
  check(ui.nav.id ~= "t_nav/beta",
        "uinav: a held dpad direction repeats the move")
  frame({ { type = "gpadbtn", button = 12, down = false } })
  ui.nav.id = "t_nav/alpha"
  frame({ { type = "gpadaxis", axis = 1, value = 20000 } }) -- stick down
  check(ui.nav.id == "t_nav/beta", "uinav: stick deflection moves once")
  frame({ { type = "gpadaxis", axis = 1, value = 0 } }) -- release
  frame({ { type = "gpadbtn", button = 0, down = true } }) -- south
  check(clicks.beta == 1, "uinav: pad south activates the cursored button")
  frame({ { type = "gpadbtn", button = 0, down = false } })
  ui.focus = "t_nav/fake_focus" -- a text widget owns the keyboard:
  ui.frame({ key(81) })         -- nav must not interpret the arrows
  check(ui.nav.id == "t_nav/beta",
        "uinav: nav suspends while a text widget holds focus")
  ui.focus = nil
  menu()
  ui.frame_end()
  -- mouse press syncs the cursor (mixed mouse/pad use): beta's row is the
  -- second 11px strip inside the panel padding
  frame({ { type = "motion", x = 20, y = 21, ui_x = 20, ui_y = 21,
            wx = 20, wy = 21 },
          { type = "button", button = 1, down = true, x = 20, y = 21,
            ui_x = 20, ui_y = 21, wx = 20, wy = 21 } })
  check(ui.nav.id == "t_nav/beta", "uinav: a mouse press syncs the cursor")
  frame({ { type = "button", button = 1, down = false, x = 20, y = 21,
            ui_x = 20, ui_y = 21, wx = 20, wy = 21 } })

  -- scroll-into-view: six rows in a 30px window; navigating below the view
  -- scrolls the region so the cursored widget is visible
  local function scrolly()
    ui.nav_scope()
    ui.begin_panel("t_nav2", 0, 0, 120, 60)
    ui.begin_scroll("scr", 30)
    for i = 1, 6 do ui.button("b" .. i, { id = "b" .. i }) end
    ui.end_scroll()
    ui.end_panel()
  end
  local function sframe(evs)
    ui.frame(evs or {})
    scrolly()
    ui.frame_end()
  end
  ui.nav.id = nil
  sframe()
  sframe()
  check(ui.nav.id == "t_nav2/scr/b1",
        "uinav: scroll list seeds its first row")
  for _ = 1, 5 do sframe({ key(81) }) end
  check(ui.nav.id == "t_nav2/scr/b6", "uinav: arrows reach the last row")
  sframe() -- the registration pass after the last move applies the scroll
  local ss = ui.s["t_nav2/scr"]
  check(ss and ss.scroll and ss.scroll > 30,
        "uinav: the cursored off-view row scrolled into view (scroll="
        .. tostring(ss and ss.scroll) .. ")")

  -- the edge-item limit cycle (D132, the vibration report): the first
  -- row's 2px top margin is unsatisfiable at scroll 0, so the correction
  -- must clamp to the legal range and go QUIET — an out-of-range write
  -- re-arms the elastic spring and the two fight ~1px forever
  for _ = 1, 5 do sframe({ key(82) }) end -- up arrows back to b1
  check(ui.nav.id == "t_nav2/scr/b1", "uinav: arrows return to the top row")
  for _ = 1, 12 do sframe() end -- idle: any residual physics must settle
  ss = ui.s["t_nav2/scr"]
  check(ss.scroll == 0 and (ss.vel or 0) == 0,
        "uinav: an edge-cursored scroll rests at exactly 0, no limit cycle"
        .. " (scroll=" .. tostring(ss.scroll)
        .. " vel=" .. tostring(ss.vel) .. ")")

  -- page-vanish prune: stop drawing; the cursor clears with the scope
  ui.frame({})
  ui.frame_end()
  check(ui.nav.id == nil and not ui.nav_active(),
        "uinav: cursor and scope clear when the overlay stops drawing")

  -- ---- the options menu pad grammar (back/select = the pad Esc) ----
  local options = cm.require("cm.options")
  local function oframe(evs)
    ui.frame(evs or {})
    options.frame()
    ui.frame_end()
  end
  local function padbtn(b, down)
    return { type = "gpadbtn", button = b, down = down ~= false }
  end
  options.toggle(false)
  oframe({ padbtn(4) }) -- back/select opens the closed menu
  check(options.on, "uinav: pad back/select opens the options menu")
  oframe({ padbtn(4, false) })
  oframe({ padbtn(1) }) -- east walks back = closes from the main page
  check(not options.on, "uinav: pad east closes the menu from main")
  oframe({ padbtn(1, false) })
  oframe({ padbtn(1) }) -- ...but east must NOT open a closed menu
  check(not options.on, "uinav: pad east never opens the menu")
  oframe({ padbtn(1, false) })
  options.toggle(true)
  options.page = "controls"
  oframe({ padbtn(4) }) -- back/select from the controls page = page back
  check(options.on and options.page == "main",
        "uinav: pad back walks controls -> main, menu stays open")
  oframe({ padbtn(4, false) })
  options.page = "controls"
  local input = cm.require("cm.input")
  input.define("uinav_jump", {})
  options.arm = { action = "uinav_jump" }
  oframe({ padbtn(1) }) -- east while a capture is armed must BIND (players
                        -- bind east), never walk the menu grammar
  check(options.arm == nil and options.on,
        "uinav: east while armed reaches the capture")
  local got
  for _, b in ipairs(input.bindings("uinav_jump")) do
    if b == "pad:east" then got = true end
  end
  check(got, "uinav: ...and binds as pad:east")
  oframe({ padbtn(1, false) })
  options.arm = { action = "uinav_jump" }
  oframe({ padbtn(4) }) -- back/select cancels the capture like F1
  check(options.arm == nil and options.on
        and options.note == "rebind cancelled",
        "uinav: pad back cancels an armed capture")
  oframe({ padbtn(4, false) })

  -- keyboard grammar (D133): F1 is the menu key; ESC BELONGS TO GAMES —
  -- it walks back only while the menu is already open (input captured,
  -- the game never hears it) and BINDS while a capture is armed
  options.toggle(false)
  oframe({ key(41) }) -- Esc must never open the closed menu
  check(not options.on, "uinav: esc never opens the menu (games bind it)")
  oframe({ key(58) }) -- F1 opens
  check(options.on, "uinav: F1 opens the closed menu")
  oframe({ key(41) }) -- Esc closes from the main page while open
  check(not options.on, "uinav: esc closes the open menu from main")
  options.toggle(true)
  options.page = "controls"
  oframe({ key(58) })
  check(options.on and options.page == "main",
        "uinav: F1 walks controls -> main, menu stays open")
  options.arm = { action = "uinav_jump" }
  oframe({ key(41) }) -- Esc while armed must BIND, never cancel
  check(options.arm == nil and options.on,
        "uinav: esc while armed reaches the capture")
  local esc_bound
  for _, b in ipairs(input.bindings("uinav_jump")) do
    if b == "key:41" then esc_bound = true end
  end
  check(esc_bound, "uinav: ...and binds as key:41")
  options.arm = { action = "uinav_jump" }
  oframe({ key(58) }) -- F1 cancels the armed capture (it is reserved)
  check(options.arm == nil and options.on
        and options.note == "rebind cancelled",
        "uinav: F1 cancels an armed capture")
  options.toggle(false)
  oframe()
  ui.nav.id, ui.nav.want, ui.nav.on = nil, false, false
  cm.require("cm.console").open = false -- a failed bind-save summons it
  cm.adopt_disk() -- drop the test action + binding from the input defs
end

function game.init()
  checks = 0
  t_rand_kat()
  t_rand_dist()
  t_trig_sweep()
  t_atan_sweep()
  t_canon()
  t_exp2()
  t_ease()
  t_box()
  t_actor()
  t_camera()
  t_tween()
  t_reduce_fx()
  t_depth()
  t_snapshot()
  t_buf_poke()
  t_input()
  t_input_pad()
  t_input_gpad()
  t_input_bind()
  t_move()
  t_options()
  t_save()
  t_text()
  t_hud()
  t_repl()
  t_ui()
  t_uispace()
  t_console()
  t_collide()
  t_map()
  t_inspect()
  t_bundle()
  t_ring()
  t_ring_edoc()
  t_ring_spill()
  t_viewport()
  t_ig_absence()
  t_ladder()
  t_capture()
  t_paint()
  t_brush()
  t_grad()
  t_procfill()
  t_blend()
  t_sprite()
  t_anim()
  t_asset_reload()
  t_ed_cam()
  t_ed_wm()
  t_ed_game()
  t_atomic_write()
  t_project_settings()
  t_project_location()
  t_project_duplicate()
  t_project_archive()
  t_project_delete()
  t_project_export()
  t_project_templates()
  t_picker_nav()
  t_crash()
  t_ed_text_save()
  t_ed_session()
  t_ed_cache()
  t_ed_journal()
  t_ed_kit()
  t_snd()
  t_ins()
  t_stock_ins()
  t_words()
  t_palette()
  t_song()
  t_stock_songs()
  t_snd_claim()
  t_preview_voice()
  t_stock_window()
  t_ed_lex()
  t_ed_assets()
  t_ed_map()
  t_ed_map_tmsnap()
  t_ed_maptool()
  t_ed_synth()
  t_ed_filter()
  t_ed_viewlock()
  t_ed_hot()
  t_ed_rewind()
  t_ed_pick()
  t_ed_winview()
  t_ed_orbit()
  t_ed_park()
  t_timeline_summary()
  t_timeline_thumbs()
  t_timeline_retention()
  t_project_blobs()
  t_standalone_clip()
  t_clip_nondestructive()
  t_clip_lifecycle()
  t_crash_resolve()
  t_crash_focus()
  t_clip_trust()
  t_crash_tail()
  t_ed_domain()
  t_docs()
  t_help_sel()
  t_help_keys()
  t_kit_rep()
  t_game_blit()
  t_game_snap()
  t_game_fov()
  t_game_aa()
  t_cam_aa()
  t_m4()
  t_kin()
  t_mesh()
  t_terr3()
  t_terr3_smoothlight()
  t_lathe_norms()
  t_walk()
  t_rig()
  t_input_mrel()
  t_input_fsiz()
  t_atlas_snapshot()
  t_figverts()
  t_fig_file()
  t_console_sel()
  t_ui_nav()
  pal.log(("SELFTEST PASS (%d checks)"):format(checks))
end

function game.step() end

function game.draw()
  pal.begin_frame(0.05, 0.35, 0.10, 1) -- green = pass (you only see this alive)
end

return game
