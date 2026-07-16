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
      { name = "bg", vis = true, on = true },
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
local function tmproot()
  return (pal.platform == "windows" and os.getenv("TEMP"))
         or os.getenv("TMPDIR") or "/tmp"
end

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
end

local function t_project_location()
  local location = cm.require("cm.project_location")
  local project = cm.require("cm.project")
  local source, parent = "/projects/source", "/else"
  local destination = parent .. "/renamed π project"
  local bytes = project.PROJECT_TMPL:gsub("__NAME__", "location test")

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
  check(left and #left == 1 and left[1] == "stream"
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
  check(kit.hotkey(kind, kwin, ed,
                   { down = true, rep = true, scancode = 19 }, none)
        == false, "ed.kit: key repeats never dispatch")
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

  -- Inclusive loop playback shows A, then every frame through B, then wraps.
  local rewind = cm.require("cm.ed.rewind")
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

local function t_ed_domain()
  -- the ed.* buffer domain is invisible to sim snapshots + traces (D050)
  local state = cm.require("cm.state")
  check(state.sim_buffer("cm.sim") and state.sim_buffer("smoke.player"),
        "ed domain: sim names pass")
  check(not state.sim_buffer("ed.text") and not state.sim_buffer("ed."),
        "ed domain: ed.* names excluded")
  check(state.sim_buffer("edit.thing") and state.sim_buffer("ed"),
        "ed domain: only the exact ed. prefix excludes")

  local v = pal.buf("ed.selftest", 16)
  v:u32(0, 0xdeadbeef)
  local snap = state.parse_snapshot(state.snapshot())
  for _, b in ipairs(snap.bufs) do
    check(b.name ~= "ed.selftest", "ed domain: snapshot excludes ed.*")
  end
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
  ed.kinds.project.drop_ephemeral(ed)
  ed.on, ed.doc, ed.root = was_on, was_doc, was_root
  view.mode = was_mode
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
  t_snapshot()
  t_buf_poke()
  t_input()
  t_text()
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
  t_grad()
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
  t_project_export()
  t_crash()
  t_ed_text_save()
  t_ed_session()
  t_ed_cache()
  t_ed_journal()
  t_ed_kit()
  t_snd()
  t_ins()
  t_words()
  t_palette()
  t_song()
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
  t_ed_park()
  t_ed_domain()
  pal.log(("SELFTEST PASS (%d checks)"):format(checks))
end

function game.step() end

function game.draw()
  pal.begin_frame(0.05, 0.35, 0.10, 1) -- green = pass (you only see this alive)
end

return game
