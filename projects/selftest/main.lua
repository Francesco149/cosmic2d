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

-- ---- cm.tilemap: header/cells + the AABB mover (M3) ----

local function t_tilemap()
  local tilemap = cm.require("cm.tilemap")
  local T = { [1] = { solid = true }, [2] = { oneway = true } }

  -- 12x8 cells of 16px: floor along the bottom, a wall column, a plank
  local tm = tilemap.new{ name = "selftest.map", w = 12, h = 8, tile = 16,
                          tiles = T }
  check(tm.buf:u32(0) == 12 and tm.buf:u32(4) == 8 and tm.buf:u32(8) == 16,
        "tilemap: header written")
  check(tm.pw == 192 and tm.ph == 128, "tilemap: pixel size")
  tm:fill(0, 7, 12, 1, 1) -- floor row
  tm:fill(6, 4, 1, 3, 1) -- wall column x=6, rows 4..6
  tm:fill(2, 5, 3, 1, 2) -- one-way plank row 5, x 2..4
  tm:set(9, 2, 1) -- lone ceiling block for the head-bonk test
  check(tm:get(6, 5) == 1 and tm:get(3, 5) == 2 and tm:get(0, 0) == 0,
        "tilemap: get/set/fill")
  check(tm:solid_at(100, 116) and tm:solid_at(100, 100)
        and not tm:solid_at(90, 100), "tilemap: solid_at")
  check(tm:solid_at(-1, 0) and tm:solid_at(193, 0) and tm:solid_at(0, 129)
        and not tm:solid_at(0, -50), "tilemap: oob walls + open sky")

  -- re-new with same shape keeps cells (init idempotence)
  tm = tilemap.new{ name = "selftest.map", w = 12, h = 8, tile = 16, tiles = T }
  check(tm:get(6, 5) == 1, "tilemap: re-new keeps cells")
  -- open() adopts by header
  local tm2 = tilemap.open("selftest.map", T)
  check(tm2.w == 12 and tm2.h == 8 and tm2.tile == 16 and tm2:get(3, 5) == 2,
        "tilemap: open reads header")

  local body_w, body_h = 10, 14
  local stand = 112 - body_h -- bottom exactly on the floor top

  -- X: run right into the wall (wall left face at 96)
  local nx, ny, hit = tm:move(60, stand, body_w, body_h, 40, 0)
  check(nx == 96 - body_w and ny == stand and hit.right and not hit.left,
        "tilemap: clamp right at wall (" .. nx .. ")")
  -- X: from the other side (wall right face at 112)
  nx, ny, hit = tm:move(130, stand, body_w, body_h, -40, 0)
  check(nx == 112 and hit.left, "tilemap: clamp left at wall")
  -- X: body above the wall passes freely
  nx, ny, hit = tm:move(60, 30, body_w, body_h, 40, 0)
  check(nx == 100 and not hit.right, "tilemap: free run above wall")
  -- X: body straddling two rows hits a wall present in either
  nx, ny, hit = tm:move(60, 58, body_w, body_h, 40, 0) -- rows 3..4, wall in 4
  check(nx == 96 - body_w and hit.right, "tilemap: partial row overlap blocks")
  -- X: huge step cannot tunnel through the wall column
  nx, ny, hit = tm:move(0, stand, body_w, body_h, 1000, 0)
  check(nx == 96 - body_w and hit.right, "tilemap: no x tunneling")

  -- Y: fall and land on the floor (top at 112)
  nx, ny, hit = tm:move(20, 60, body_w, body_h, 0, 200)
  check(ny == stand and hit.down and not hit.oneway,
        "tilemap: land on floor, no y tunneling")
  -- Y: standing on the boundary stays put under small gravity
  nx, ny, hit = tm:move(20, stand, body_w, body_h, 0, 0.25)
  check(ny == stand and hit.down, "tilemap: standing is stable")
  -- Y: head bonk on the lone ceiling block (underside at 48)
  nx, ny, hit = tm:move(146, 60, body_w, body_h, 0, -30)
  check(ny == 48 and hit.up, "tilemap: head bonk clamps (" .. ny .. ")")

  -- one-way plank (row 5, top at 80, x cells 2..4 = px 32..80)
  -- land from above
  nx, ny, hit = tm:move(40, 50, body_w, body_h, 0, 60)
  check(ny == 80 - body_h and hit.down and hit.oneway,
        "tilemap: land on one-way")
  -- jump up through it: rising never collides with one-ways
  nx, ny, hit = tm:move(40, 90, body_w, body_h, 0, -40)
  check(ny == 50 and not hit.up, "tilemap: rise through one-way")
  -- walk across it sideways: never blocks horizontally
  nx, ny, hit = tm:move(20, 80 - body_h, body_w, body_h, 30, 0)
  check(nx == 50 and not hit.right, "tilemap: one-way never blocks x")
  -- drop through with opts.drop
  nx, ny, hit = tm:move(40, 80 - body_h, body_w, body_h, 0, 10,
                        { drop = true })
  check(ny == 80 - body_h + 10 and not hit.down, "tilemap: drop-through")
  -- starting below the plank top (inside its cell) falls freely
  nx, ny, hit = tm:move(40, 82, body_w, body_h, 0, 10)
  check(ny == 92 and not hit.down, "tilemap: below plank top, no snag")

  -- walking off a ledge: columns clear of the plank -> no support
  nx, ny, hit = tm:move(8, 80 - body_h, body_w, body_h, 0, 0.25)
  check(not hit.down and ny > 80 - body_h, "tilemap: ledge gives no support")
  check(tm:grounded(40, 80 - body_h, body_w, body_h),
        "tilemap: grounded probe on plank")
  check(not tm:grounded(40, 60, body_w, body_h), "tilemap: airborne probe")

  -- map borders: walls left/right/below even with empty cells
  nx, ny, hit = tm:move(4, 20, body_w, body_h, -30, 0)
  check(nx == 0 and hit.left, "tilemap: left border wall")
  nx, ny, hit = tm:move(170, 20, body_w, body_h, 30, 0)
  check(nx == 192 - body_w and hit.right, "tilemap: right border wall")
  -- above the map is open: rising out and falling back is free
  nx, ny, hit = tm:move(20, 4, body_w, body_h, 0, -40)
  check(ny == -36 and not hit.up, "tilemap: open sky above")

  -- diagonal: x resolves before y (slides along the wall, then lands)
  nx, ny, hit = tm:move(60, 90, body_w, body_h, 60, 30)
  check(nx == 96 - body_w and ny == 112 - body_h and hit.right and hit.down,
        "tilemap: axis-separated diagonal")

  -- live resize: different shape rebuilds zeroed with the new header
  tm = tilemap.new{ name = "selftest.map", w = 8, h = 12, tile = 16, tiles = T }
  check(tm.buf:u32(0) == 8 and tm.buf:u32(4) == 12 and tm:get(6, 5) == 0,
        "tilemap: resize rebuilds")
  pal.buf_free("selftest.map")
end

-- ---- cm.tilemap M4 statics: fresh flag, poke/peek, save/load, cell_line --

local function t_tilemap_tools()
  local tilemap = cm.require("cm.tilemap")
  local T = { [1] = { solid = true } }

  local tm, fresh = tilemap.new{ name = "selftest.map4", w = 6, h = 5,
                                 tile = 16, tiles = T }
  check(fresh == true, "tilemap: first new is fresh")
  tm:set(2, 3, 1)
  local tm2, fresh2 = tilemap.new{ name = "selftest.map4", w = 6, h = 5,
                                   tile = 16, tiles = T }
  check(fresh2 == false and tm2:get(2, 3) == 1,
        "tilemap: same-shape new adopts, not fresh")
  local _, fresh3 = tilemap.new{ name = "selftest.map4", w = 5, h = 6,
                                 tile = 16, tiles = T }
  check(fresh3 == true, "tilemap: resize is fresh again")

  -- poke/peek by name (the editor's eval unit)
  tilemap.poke("selftest.map4", 1, 2, 7)
  check(tilemap.peek("selftest.map4", 1, 2) == 7, "tilemap: poke/peek")
  tilemap.poke("selftest.map4", -1, 0, 9) -- oob: inert, like TM:set
  tilemap.poke("selftest.map4", 0, 99, 9)
  check(tilemap.peek("selftest.map4", -1, 0) == 0
        and tilemap.peek("selftest.map4", 0, 99) == 0,
        "tilemap: poke/peek oob is inert")

  -- save/load round trip (raw self-describing bytes)
  local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/cosmic_selftest_map.dat"
  check(tilemap.save("selftest.map4", tmp) == true, "tilemap: save writes")
  tilemap.poke("selftest.map4", 1, 2, 1) -- diverge live state from the file
  check(tilemap.load("selftest.map4", tmp) == true, "tilemap: load ok")
  local tm4 = tilemap.open("selftest.map4", T)
  check(tm4.w == 5 and tm4.h == 6 and tm4:get(1, 2) == 7,
        "tilemap: save/load round trip restores bytes")
  local ok, err = tilemap.load("selftest.map4", tmp .. ".nope")
  check(ok == nil and err == "no file", "tilemap: load missing file refused")
  check(pal.write_file(tmp, "COSMICBOGUS") == true, "selftest tmp writable")
  ok, err = tilemap.load("selftest.map4", tmp)
  check(ok == nil and err ~= nil, "tilemap: load garbage refused")
  check(tilemap.peek("selftest.map4", 1, 2) == 7,
        "tilemap: refused load leaves the buffer untouched")
  pal.buf_free("selftest.map4")

  -- cell_line: endpoints inclusive, 8-connected steps, expected lengths
  local function walk(x0, y0, x1, y1)
    local cells = {}
    tilemap.cell_line(x0, y0, x1, y1, function(x, y)
      cells[#cells + 1] = { x, y }
    end)
    return cells
  end
  local c = walk(3, 3, 3, 3)
  check(#c == 1 and c[1][1] == 3 and c[1][2] == 3, "cell_line: single cell")
  c = walk(0, 0, 4, 0)
  check(#c == 5 and c[5][1] == 4 and c[5][2] == 0, "cell_line: horizontal")
  c = walk(2, 5, 2, 1)
  check(#c == 5 and c[5][2] == 1, "cell_line: vertical up")
  c = walk(0, 0, 3, 3)
  check(#c == 4 and c[4][1] == 3 and c[4][2] == 3, "cell_line: diagonal")
  c = walk(10, 2, -2, 9) -- arbitrary slope through negatives
  check(c[1][1] == 10 and c[1][2] == 2
        and c[#c][1] == -2 and c[#c][2] == 9, "cell_line: endpoints exact")
  for i = 2, #c do
    local dx = c[i][1] - c[i - 1][1]
    local dy = c[i][2] - c[i - 1][2]
    if dx < 0 then dx = -dx end
    if dy < 0 then dy = -dy end
    check(dx <= 1 and dy <= 1 and dx + dy >= 1, "cell_line: 8-connected step")
  end
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

local function t_ed_cam()
  local cam = cm.require("cm.ed.cam")
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

  -- A-rightclick closes; asset state would survive by design (§6)
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
  local loaded = session.load(root)
  check(loaded and state.canon(loaded) == state.canon(doc),
        "ed.session: load round-trips")
  check(session.load(root .. "_nope") == nil, "ed.session: missing = nil")

  -- a corrupt session file degrades to nil (fresh boot), never an error
  pal.write_file(session.path(root), "CEDSgarbage")
  check(session.load(root) == nil, "ed.session: corrupt = nil")
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
  pal.write_file(journal.file(root, "a.txt"), "")
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

  -- the cap drops the oldest
  local cap = journal.CAP
  journal.CAP = 3
  journal.push(j4, "x1", 0, 6)
  journal.push(j4, "x2", 0, 7) -- 5th entry against cap 3
  check(#j4.entries == 3 and j4.entries[1].bytes == "fork",
        "ed.journal: cap drops the oldest")
  check(j4.pos == 3 and journal.at(j4).bytes == "x2",
        "ed.journal: cap keeps the tip current")
  local j5 = journal.open(root, "a.txt")
  check(#j5.entries == 3, "ed.journal: capped file persisted")
  journal.CAP = cap

  -- a corrupt journal degrades to fresh, never an error
  pal.write_file(journal.file(root, "bad.txt"), "CJRNnotachunk")
  local jb = journal.open(root, "bad.txt")
  check(#jb.entries == 0, "ed.journal: corrupt = fresh")
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
  t_tilemap()
  t_tilemap_tools()
  t_inspect()
  t_bundle()
  t_ring()
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
  t_ed_session()
  t_ed_journal()
  t_ed_domain()
  pal.log(("SELFTEST PASS (%d checks)"):format(checks))
end

function game.step() end

function game.draw()
  pal.begin_frame(0.05, 0.35, 0.10, 1) -- green = pass (you only see this alive)
end

return game
