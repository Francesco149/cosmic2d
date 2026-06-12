-- selftest cartridge — engine invariants that don't need a recorded trace:
-- PRNG known-answer tests against the reference C implementation, trig
-- accuracy sweeps against the host libm, and (as M1 grows) serializer and
-- snapshot round-trips. Run: bin/pettan projects/selftest --headless --frames 1
-- (--frames sets exit_on_error, so any failed check exits 1).

local rand = pt.require("pt.rand")
local m = pt.require("pt.math")
local state = pt.require("pt.state")

local game = {}
local checks = 0

local function check(cond, what)
  checks = checks + 1
  if not cond then error("SELFTEST FAIL: " .. what, 0) end
end

-- ---- pt.rand vs reference xoshiro256++/splitmix64 (vectors from the
-- Blackman/Vigna C, generated 2026-06-10) ----

local function t_rand_kat()
  local sim = pal.buf("pt.sim", 64)
  -- raw state {1,2,3,4}
  for i = 0, 3 do sim:i64(8 + 8 * i, i + 1) end
  local raw = { 0x0000000002800001, 0x0000000003800067, 0x000cc00003800067,
                0x000cc201994400b2, 0x8012a2019ac433cd }
  for i, want in ipairs(raw) do
    check(rand.u64() == want, "xoshiro raw1234 output " .. i)
  end
  -- splitmix-seeded from the "pettan2d" seed
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

-- ---- pt.math vs host libm (accuracy, not bit-equality: libm is the
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

-- ---- pt.state: canonical serializer ----

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

-- ---- pt.state: snapshot round-trip ----

local function t_snapshot()
  local sim = pal.buf("pt.sim", 64)
  rand.seed(777)
  sim:i64(0, 1234) -- pretend we're at frame 1234

  local b1 = pal.buf("selftest.b1", 128)
  for i = 0, 127 do b1:u8(i, (i * 7 + 3) % 256) end
  local b1_bytes = b1:str(0, 128)

  state.doc.player = { x = 10, y = 20.5, name = "pet" }
  state.doc.flags = { true, false, true }

  local snap = state.snapshot()
  local epoch_before = pt.code_epoch

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

  check(pt.code_epoch > epoch_before, "restore bumps code epoch")
  check(#pt.reload() == 0, "disk reload paused while on bundle code")
  pt.adopt_disk()
  pal.buf_free("selftest.b1")
end

-- ---- pt.math.exp2 + pt.ease ----

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
  local ease = pt.require("pt.ease")
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

-- ---- pt.input: records, edges, snapshot consistency ----

local function t_input()
  local input = pt.require("pt.input")
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
  pt.adopt_disk()
  check(input.pressed("right"), "press edge restored from snapshot")
  input.apply(input.collect({ key(79, false) }))
end

-- ---- pt.text: glyph pixels land exactly in their cell ----

local function t_text()
  local text = pt.require("pt.text")
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

-- ---- pt.repl: exec semantics (the deterministic console path, D022) ----

local function t_repl()
  local repl = pt.require("pt.repl")

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
    check(repl.exec("pt.state.doc.t_repl = 7"), "repl: statement ok")
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
  repl.submit("pt.state.doc.t_q = 'a'")
  repl.submit("pt.state.doc.t_q = pt.state.doc.t_q .. 'b'")
  check(#repl.queue == 2, "repl: submits queue")
  local drained = repl.drain()
  check(#drained == 2 and #repl.queue == 0, "repl: drain empties queue")
  check(state.doc.t_q == "ab", "repl: drain executes in order")
  check(repl.drain() == nil, "repl: idle drain is nil")
  state.doc.t_q = nil
  check(repl.history[#repl.history]:find("t_q"), "repl: history records")
end

-- ---- pt.ui: interaction logic via synthetic events (headless-safe; the
-- 64x64 gfx target is live, so widgets really draw — logic is what we
-- assert, pixels are the glyph test's job) ----

local function t_ui()
  local ui = pt.require("pt.ui")
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

-- ---- pt.console: toggle/error logic (drawing exercised, not asserted) ----

local function t_console()
  local ui = pt.require("pt.ui")
  local con = pt.require("pt.console")
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
  local repl = pt.require("pt.repl")
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

-- ---- pt.tilemap: header/cells + the AABB mover (M3) ----

local function t_tilemap()
  local tilemap = pt.require("pt.tilemap")
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

-- ---- pt.tilemap M4 statics: fresh flag, poke/peek, save/load, cell_line --

local function t_tilemap_tools()
  local tilemap = pt.require("pt.tilemap")
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
  local tmp = (os.getenv("TMPDIR") or "/tmp") .. "/pettan_selftest_map.dat"
  check(tilemap.save("selftest.map4", tmp) == true, "tilemap: save writes")
  tilemap.poke("selftest.map4", 1, 2, 1) -- diverge live state from the file
  check(tilemap.load("selftest.map4", tmp) == true, "tilemap: load ok")
  local tm4 = tilemap.open("selftest.map4", T)
  check(tm4.w == 5 and tm4.h == 6 and tm4:get(1, 2) == 7,
        "tilemap: save/load round trip restores bytes")
  local ok, err = tilemap.load("selftest.map4", tmp .. ".nope")
  check(ok == nil and err == "no file", "tilemap: load missing file refused")
  check(pal.write_file(tmp, "PETTANBOGUS") == true, "selftest tmp writable")
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

-- ---- pt.state.buf_poke/buf_peek (the inspector's buffer eval unit) ----

local function t_buf_poke()
  local repl = pt.require("pt.repl")
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

  -- the actual eval form: a self-contained command string through pt.repl
  check(repl.exec('pt.state.buf_poke("selftest.poke","f32",28,2.25)') == true,
        "buf_poke: exec as an eval string")
  check(state.buf_peek("selftest.poke", "f32", 28) == 2.25,
        "buf_poke: eval landed")
  check(repl.exec('pt.state.buf_poke("selftest.poke","u8",999,1)') == false,
        "buf_poke: erroring eval is contained")

  pal.buf_free("selftest.poke")
end

-- ---- pt.inspect (the M4 inspector panel: eval building + render) ----

local function t_inspect()
  local inspect = pt.require("pt.inspect")
  local repl = pt.require("pt.repl")
  local ui = pt.require("pt.ui")

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
  local knob = pt.require("knob")
  check(knob.value == 1, "knob module baseline")
  pt.restore_bundle({
    { name = "knob", path = "projects/selftest/knob.lua",
      source = "return { value = 2 }" },
  })
  check(knob.value == 2, "bundle code re-executed into the same table")
  check(pt.require("knob") == knob, "module identity preserved")
  local changed = pt.adopt_disk()
  check(knob.value == 1, "adopt_disk returns to disk code")
  check(#changed == 1 and changed[1] == "knob", "adopt reports the reload")
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
  t_console()
  t_tilemap()
  t_tilemap_tools()
  t_inspect()
  t_bundle()
  pal.log(("SELFTEST PASS (%d checks)"):format(checks))
end

function game.step() end

function game.draw()
  pal.begin_frame(0.05, 0.35, 0.10, 1) -- green = pass (you only see this alive)
end

return game
