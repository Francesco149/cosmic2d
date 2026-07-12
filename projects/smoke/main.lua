-- smoke main.lua — the engine's minimal test cartridge (revamp R0, D046):
-- ONE room with a couple of platforms + the feel-approved M7 moveset,
-- nothing else. A cut-down cosmic greybox that carries the trace/pixel
-- goldens and stays the live testbed through the editor-rewrite phase
-- (REVAMP.md R1–R4); the actual game lives in ../cosmic2d-game.
--
-- Controls: arrows move (down+jump drops through planks) · space jump /
-- flash-jump / up-jump · e hop (hold = flutter) · q grapple · r teleport ·
-- d slice(stub) · ` console (game.demo(1) = the KITCHECK choreography) ·
-- F1 editor · Esc options (the sprite ed lives in --edit since R4, D051).
--
-- Determinism: sim state in named buffers (smoke.*) + doc tree only;
-- randomness from cm.rand; trig from cm.math; fixed dt (ARCHITECTURE
-- "Determinism").

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local gfx = cm.require("cm.gfx")
local level = cm.require("level")
local player = cm.require("player")
local fx = cm.require("fx")
local demo = cm.require("demo")

local W, H = pal.gfx_size()

local game = {}
game.level = level -- console/editor evals reach the room: game.level.reset()

-- feel knobs, all live (doc tree -> snapshots, traces, console, F1 panels).
-- The M7 moveset defaults, verbatim from the feel-approved kit. Merged
-- key-by-key so docs from older sessions grow new knobs in place — and shed
-- retired ones.
local KNOBS = {
  move = {
    cw = 12, ch = 18,
    walk_speed = 42, walk_accel = 640, ground_fric = 900,
    air_accel = 110, air_fric = 36,
    jump_h = 20, jump_apex_t = 21.3, fall_mul = 1.3, fall_max = 360,
    coyote = 6, buffer = 5, mantle = 4,
    fj_vx = 186, fj_vy = -52,
    upjump_h = 56,
    hop_vx = 120, hop_h = 18,
    flutter_interval = 30, flutter_boosts = 4, flutter_h = 11, flutter_vx = 30,
    hop_cd = 600,
    grapple_range_max = 244, grapple_range_min_pref = 120,
    grapple_extend = 270, grapple_accel = 720, grapple_vmax = 220,
    grapple_stop_ch = 2.0, grapple_min_t = 6, grapple_cd = 180,
    tp_dist = 60, tp_min_interval = 30,
    attack_interval = 6, attack_reach = 22,
  },
  cam = { lerp = 0.10, lerp_y = 0.08, look = 26, look_lerp = 0.05, dead = 26 },
  fx = { gravity = 420, drag = 2.2, run_dist = 22 },
  feel = { squash = 0.55, squash_t = 0.16, stretch = 0.4, stretch_t = 0.12 },
}

local cam

local function knob_file() return cm.main.args.project .. "/knobs.dat" end

local function load_knobs()
  local bytes = pal.read_file(knob_file())
  if not bytes then return nil end
  local ok, t = pcall(state.parse, bytes)
  if ok and type(t) == "table" then return t end
  pal.log("[knobs] knobs.dat unreadable; using defaults")
  return nil
end

function game.save_knobs()
  return pal.write_file(knob_file(), state.canon(state.doc.knobs))
end

function game.init()
  local d = state.doc
  d.knobs = d.knobs or load_knobs() or {}
  for group, defaults in pairs(KNOBS) do
    d.knobs[group] = d.knobs[group] or {}
    for key, v in pairs(defaults) do
      if d.knobs[group][key] == nil then d.knobs[group][key] = v end
    end
    for key in pairs(d.knobs[group]) do
      if defaults[key] == nil then d.knobs[group][key] = nil end
    end
  end
  if d.demo == nil then d.demo = 0 end
  if d.demo_t0 == nil then d.demo_t0 = 0 end

  -- build the room FIRST (player.init reads level.spawn)
  level.reset()
  fx.init()
  player.init()

  cam = pal.buf("smoke.cam", 32)
  if cam:f32(0) == 0 and cam:f32(4) == 0 then -- virgin: snap to the player
    local px, py = player.center()
    cam:f32(0, m.clamp(px - W / 2, 0, level.pw - W))
    cam:f32(4, m.clamp(py - H / 2, 0, level.ph - H))
  end

  input.map({
    { "left", input.key.left }, { "right", input.key.right },
    { "up", input.key.up }, { "down", input.key.down },
    { "jump", input.key.space }, { "hop", input.key.e },
    { "grapple", input.key.q }, { "teleport", input.key.r },
    { "attack", input.key.d },
  })

  -- R8a: no cm.editor.attach — the F1 tile editor has nothing to edit in
  -- a .map world (colliders edit in the R8c map window; cm.editor dies at
  -- R8e, MAPS.md §10).
end

-- game.demo(1) in the console (or --eval, when recording the golden) hands
-- the controls to the KITCHECK script; any real action press takes back.
function game.demo(on)
  local d = state.doc
  if on and on ~= 0 then
    d.demo = 1
    d.demo_t0 = state.frame()
  else
    d.demo = 0
  end
end

local ACTIONS = { "left", "right", "up", "down", "jump", "hop", "grapple",
                  "teleport", "attack" }

-- ctl edges (see player.M.step): jump/hop carry both a press edge and the
-- held bit (held = jump auto-repeat, hop->flutter); grapple is a press edge;
-- teleport/attack are held (teleport rate-limits its own spam).
local function build_ctl()
  local d = state.doc
  if d.demo ~= 0 then
    for _, a in ipairs(ACTIONS) do
      if input.pressed(a) then
        game.demo(0)
        break
      end
    end
  end
  if d.demo ~= 0 then
    local rel = state.frame() - d.demo_t0
    local function dn(a) return demo.down(rel, a) end
    local function was(a) return demo.down(rel - 1, a) end
    return {
      left = dn("left"), right = dn("right"),
      up = dn("up"), down = dn("down"),
      jump_pressed = dn("jump") and not was("jump"), jump_held = dn("jump"),
      hop_pressed = dn("hop") and not was("hop"), hop_held = dn("hop"),
      grapple_pressed = dn("grapple") and not was("grapple"),
      teleport_held = dn("teleport"),
      attack_held = dn("attack"),
    }
  end
  return {
    left = input.down("left"), right = input.down("right"),
    up = input.down("up"), down = input.down("down"),
    jump_pressed = input.pressed("jump"), jump_held = input.down("jump"),
    hop_pressed = input.pressed("hop"), hop_held = input.down("hop"),
    grapple_pressed = input.pressed("grapple"),
    teleport_held = input.down("teleport"),
    attack_held = input.down("attack"),
  }
end

local function cam_step()
  local kc = state.doc.knobs.cam
  local px, py = player.center()
  local look = cam:f32(8)
  look = look + (player.facing() * kc.look - look) * kc.look_lerp
  local cx, cy = cam:f32(0), cam:f32(4)
  cx = cx + (px + look - W / 2 - cx) * kc.lerp
  local err = py - (cy + H / 2)
  if err > kc.dead then cy = cy + (err - kc.dead) * kc.lerp_y
  elseif err < -kc.dead then cy = cy + (err + kc.dead) * kc.lerp_y end
  cam:f32(0, m.clamp(cx, 0, level.pw - W))
  cam:f32(4, m.clamp(cy, 0, level.ph - H))
  cam:f32(8, look)
end

function game.step()
  player.step(build_ctl())
  fx.step()
  cam_step()
  -- choreography telemetry (the demo-tuning loop): --eval "_G.DEMO_DBG=30"
  -- prints the player track every N frames; reads + prints only
  if DEMO_DBG and state.frame() % DEMO_DBG == 0 then
    local px, py = player.pos()
    local function pk(off)
      return cm.state.buf_peek("smoke.player", "f32", off)
    end
    print(("DBG f=%d x=%d y=%d vy=%d gnd=%d hop_cd=%d grap=%d tp=%d"):format(
      state.frame(), px // 1, py // 1, pk(12) // 1, pk(20) // 1,
      pk(64) // 1, pk(68) // 1, pk(84) // 1))
  end
end

function game.draw()
  pal.begin_frame(0.42, 0.58, 0.80, 1)
  local frame = state.frame()
  local camx, camy = cam:f32(0), cam:f32(4)
  gfx.camera(camx, camy)

  level.draw_bg()

  gfx.layer(1)
  level.draw(camx, camy)
  player.draw()
  fx.draw()

  gfx.layer(0)
  local rec = cm.trace and cm.trace.recording and cm.trace.recording()
  text.draw(3, 3, ("frame %d%s"):format(frame, rec and "  REC" or ""),
            { g = 0.95, b = 0.8, a = 0.9 })
  local title = "SMOKE ROOM"
  text.draw((W - text.measure(title)) // 2, 3, title,
            { r = 1, g = 0.92, b = 0.7, a = 0.95 })
  if state.doc.demo ~= 0 then
    local msg = "KITCHECK * press any key to play"
    text.draw((W - text.measure(msg)) // 2, 24, msg,
              { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  end
  text.draw(3, H - 11,
            "arrows  space:jump/flash/up  e:hop(hold=flutter)  q:grapple  r:teleport  d:slice",
            { r = 0.90, g = 0.88, b = 0.78, a = 0.9 })
end

return game
