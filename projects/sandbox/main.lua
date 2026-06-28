-- sandbox main.lua — the cosmic hub testbed (the stock cartridge). The
-- mecha-girl MapleStory moveset (M7, D035 / GAME.md §4) in a tile world,
-- under a knobbed follow camera with parallax hills behind. Every value
-- tunes live (` console / F1 inspector). Controls:
--
--   arrows           move (down+jump drops through one-way planks)
--   space            jump (fixed height; hold to auto-repeat). Airborne:
--                    again = flash jump; Up+space = up jump
--   e                hop; HOLD after a hop = flutter (hover)
--   q                grapple up to a platform (spec key is `, the dev
--                    console — q is the proxy here; see input map below)
--   r                teleport blink (hold to spam; flips A↔B phase mode)
--   d                hold = continuous slice (enemies arrive at M12)
--   `                console — poke doc.knobs.* live, game.demo(1)
--   f1               editor mode — paint the map, collider overlay (M4)
--   escape           options menu (resolution / ui scale / fullscreen / quit)
--   alt+enter        toggle borderless fullscreen
--
-- Module split: level (tiles + map + backdrop), player (controller),
-- props (crate physics; the player no longer grabs — the sandbox grab/throw
-- "tool" returns with the physics milestone, GAME.md §7), fx (particles),
-- demo (attract script), pix (art helper). Determinism: sim state in named
-- buffers + doc tree only; randomness from cm.rand; trig from cm.math; fixed
-- dt (ARCHITECTURE "Determinism").

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local gfx = cm.require("cm.gfx")
local level = cm.require("level")
local player = cm.require("player")
local props = cm.require("props")
local fx = cm.require("fx")
local demo = cm.require("demo")

local W, H = pal.gfx_size()

local game = {}
game.level = level -- console/editor evals reach the map: game.level.reset()
game.props = props -- and the crates: game.props.spawn(x,y) / despawn_at(x,y)

-- feel knobs, all live (doc tree -> snapshots, traces, console, M4 panels).
-- Merged key-by-key so docs from older sessions grow new knobs in place —
-- and shed retired ones (renames would linger as dead inspector rows).
local KNOBS = {
  -- the MapleStory moveset (M7, D035 / GAME.md §4). cw/ch are the character
  -- box AND the CW/CH calibration unit; distances follow the spec's CW/CH
  -- relationships, sized for the current 16 px-tile map at 1:1. The absolute
  -- "6 CW ≈ ⅓ screen" anchor (CW ≈ 26 px) needs the zoom/real-sprite pass
  -- (M8 / M-art) — it's a cw/ch/zoom knob change. Timers are integer frames;
  -- these defaults are placeholders pending the human's feel sign-off.
  move = {
    cw = 12, ch = 18,
    -- walk (slow — you fly, you don't run) + minimal air control
    walk_speed = 42, walk_accel = 640, ground_fric = 900,
    air_accel = 110, air_fric = 36,
    -- jump: fixed apex ≈ 1 CH; hold to auto-repeat on landing. apex_t is set
    -- for ~2/3 s total airtime (human feel, 2026-06-28): airtime ≈ apex_t ×
    -- (1 + 1/sqrt(fall_mul)) frames; height stays jump_h regardless. The
    -- velocity-derived moves below are HEIGHT-based now, so retuning gravity
    -- keeps their heights automatically.
    jump_h = 20, jump_apex_t = 21.3, fall_mul = 1.3, fall_max = 360,
    coyote = 6, buffer = 5, mantle = 4,
    -- flash jump: ONCE per airtime, forward dash + sonic boom
    fj_vx = 186, fj_vy = -52,
    -- up jump: rise upjump_h px above the launch (jump→up-jump chain)
    upjump_h = 56,
    -- hop + flutter. hop_h = the hop's rise px. FLUTTER: hold E after a hop and
    -- keep holding once you've started FALLING → a small UPWARD mini-hop every
    -- flutter_interval frames, flutter_boosts times (≈ interval×boosts/60 s).
    -- Each is a height-based up-kick (flutter_h; small + frequent ~holds
    -- altitude with a gentle bob — raise it for more lift, lower it to descend)
    -- + an OPTIONAL forward nudge (flutter_vx, 0 = straight up); horizontal is
    -- otherwise steered/damped by air control. Then hop_cd (a plain TAP — E
    -- released before you fall — never arms it).
    hop_vx = 120, hop_h = 18,
    flutter_interval = 30, flutter_boosts = 4, flutter_h = 11, flutter_vx = 0,
    hop_cd = 600,
    -- grapple: the hook EXTENDS to a top above at grapple_extend px/s (~1
    -- screenful/s) under gravity, THEN reels you in (slow accel), STOPPING
    -- grapple_stop_ch character-heights short of the platform so the residual
    -- coasts up under gravity (damps the launch). grapple_min_t guarantees a
    -- short launch even on a very close target. 3 s cd.
    -- vmax is the LAUNCH cap: the post-reel coast ≈ vmax²/(2·gravity), so it
    -- dominates the launch height. Lowered 300→220 to dampen it (~2 CH overshoot
    -- after the early stop) while keeping the accel feel. grapple_accel unchanged.
    grapple_range_max = 244, grapple_range_min_pref = 120,
    grapple_extend = 270, grapple_accel = 720, grapple_vmax = 220,
    grapple_stop_ch = 2.0, grapple_min_t = 6, grapple_cd = 180,
    -- teleport: ~5 CW blink, max 2/s
    tp_dist = 60, tp_min_interval = 30,
    -- continuous attack (slash stub; enemies M12)
    attack_interval = 6, attack_reach = 22,
  },
  cam = { lerp = 0.10, lerp_y = 0.08, look = 26, look_lerp = 0.05,
          dead = 26 },
  prop = { gravity = 700, fall_max = 340, rest = 0.3, wall_rest = 0.45,
           fric = 7.0 },
  fx = { gravity = 420, drag = 2.2, run_dist = 22 },
  feel = { squash = 0.55, squash_t = 0.16, stretch = 0.4, stretch_t = 0.12 },
}

local cam

local function knob_file()
  return cm.main.args.project .. "/knobs.dat"
end

-- tuned knobs persist next to project.lua (knobs.dat: canonical doc bytes
-- of doc.knobs, like map.dat holds the map buffer). An empty boot — fresh
-- VM, parachute reboot — seeds doc.knobs from it before the defaults
-- merge fills gaps; a live doc always wins (hot reloads and snapshot
-- restores never re-read the file). Boot-time-only read by the D026 rule:
-- file bytes are not sim input; traces capture knobs via the doc tree.
local function load_knobs()
  local bytes = pal.read_file(knob_file())
  if not bytes then return nil end
  local ok, t = pcall(state.parse, bytes)
  if ok and type(t) == "table" then return t end
  pal.log("[knobs] knobs.dat unreadable; using defaults")
  return nil
end

-- pure read of sim state: safe to call directly (editor save button,
-- or game.save_knobs() in the console after a tuning session)
function game.save_knobs()
  return pal.write_file(knob_file(), state.canon(state.doc.knobs))
end

function game.init()
  local d = state.doc
  d.knobs = d.knobs or load_knobs() or {}
  -- M7 retired the old controller's knob groups (and reshaped move). Drop the
  -- dead top-level groups a live doc or old knobs.dat may still carry — the
  -- per-key prune below only cleans groups KNOBS still owns, so these would
  -- otherwise linger as dead inspector rows.
  for _, g in ipairs({ "dive", "dj", "throw" }) do d.knobs[g] = nil end
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

  fx.init()
  props.init()
  player.init()

  cam = pal.buf("sandbox.cam", 32)
  if cam:f32(0) == 0 and cam:f32(4) == 0 then -- virgin: snap to the player
    local px, py = player.center()
    cam:f32(0, m.clamp(px - W / 2, 0, level.tm.pw - W))
    cam:f32(4, m.clamp(py - H / 2, 0, level.tm.ph - H))
  end

  input.map({
    { "left", input.key.left },
    { "right", input.key.right },
    { "up", input.key.up },
    { "down", input.key.down },
    { "jump", input.key.space },
    { "hop", input.key.e },
    -- the spec's grapple key is ` (backtick), but that's the dev console
    -- (engine-reserved unless the project locks the editor); q is the dev
    -- proxy. A shipped/locked build can add input.key.grave here.
    { "grapple", input.key.q },
    { "teleport", input.key.r },
    { "attack", input.key.d },
    -- Esc is NOT bound here: it's engine-reserved for the options menu
    -- (cm.options, like ` for the console). A cartridge that quit on Esc would
    -- fire alongside the menu toggle and kill the game before it could open.
  })

  -- the M4 editor: what to paint, where the camera is, which boxes to
  -- outline. The getter runs once per editor frame and only reads.
  cm.editor.attach(function()
    return {
      tm = level.tm,
      atlas = level.tex,
      camx = cam:f32(0),
      camy = cam:f32(4),
      colliders = function()
        local px, py = player.pos()
        local list = { { x = px, y = py, w = player.W, h = player.H,
                         kind = "player" } }
        for i = 1, props.count() do
          local x, y, w, h = props.get(i)
          list[#list + 1] = { x = x, y = y, w = w, h = h,
                              kind = props.held(i) and "held" or "prop" }
        end
        return list
      end,
      save = function() return level.save() and game.save_knobs() end,
      reset_eval = "game.level.reset()",
      -- the spawn palette (D031): eval formats the editor fills with the
      -- clicked world point — spawning is a cartridge command like paint
      props = {
        { name = "crate", icon = level.crate_uv,
          spawn = "game.props.spawn(%d,%d)",
          erase = "game.props.despawn_at(%d,%d)" },
      },
    }
  end)
end

-- attract mode: game.demo(1) in the console (or --eval) hands the controls
-- to the demo script — game.demo(2) runs the kit-check timeline instead
-- (golden choreography; see demo.lua); any real action press takes back
function game.demo(on)
  local d = state.doc
  if on == 1 or on == true or on == 2 then
    d.demo = on == 2 and 2 or 1
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
    local function dn(a) return demo.down(rel, a, d.demo) end
    local function was(a) return demo.down(rel - 1, a, d.demo) end
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
  if err > kc.dead then
    cy = cy + (err - kc.dead) * kc.lerp_y
  elseif err < -kc.dead then
    cy = cy + (err + kc.dead) * kc.lerp_y
  end
  cam:f32(0, m.clamp(cx, 0, level.tm.pw - W))
  cam:f32(4, m.clamp(cy, 0, level.tm.ph - H))
  cam:f32(8, look)
end

function game.step()
  local ctl = build_ctl()
  player.step(ctl)
  props.step()
  fx.step()
  cam_step()
  -- choreography telemetry (the demo-tuning loop): --eval "_G.DEMO_DBG=30"
  -- prints the player track every N frames; reads + prints only
  if DEMO_DBG and state.frame() % DEMO_DBG == 0 then
    local px, py = player.pos()
    local function pk(off)
      return cm.state.buf_peek("sandbox.player", "f32", off)
    end
    print(("DBG f=%d x=%d y=%d vy=%d gnd=%d hop_cd=%d grap=%d tp=%d"):format(
      state.frame(), px // 1, py // 1, pk(12) // 1, pk(20) // 1,
      pk(64) // 1, pk(68) // 1, pk(84) // 1))
  end
end

-- TEMP (M7 testing): a cooldown / per-airtime HUD so feel-testing can SEE the
-- timers (hop/grapple/teleport cd, which air moves are spent, the phase mode,
-- live flutter). Render-only (reads player.dbg, never writes sim). Remove once
-- the editor can live-visualize emitter/ability state (deferred with the slice
-- VFX). Hidden during the attract demo so montages/goldens stay clean.
local function draw_cd_hud()
  local d = player.dbg()
  local k = state.doc.knobs.move
  local function bar(row, label, cur, maxv)
    local y = 14 + row * 8
    text.draw(3, y, label, { r = 0.92, g = 0.9, b = 0.8, a = 0.9 })
    local bx, bw = 42, 50
    pal.quad(bx, y, bw, 6, 0.08, 0.08, 0.10, 0.75)
    if cur > 0.5 then
      local f = maxv > 0 and m.clamp(cur / maxv, 0, 1) or 0
      pal.quad(bx, y, bw * f, 6, 0.96, 0.5, 0.28, 0.95) -- cooling down
      text.draw(bx + bw + 4, y, ("%.1fs"):format(cur / 60),
                { r = 0.96, g = 0.7, b = 0.5, a = 0.9 })
    else
      pal.quad(bx, y, bw, 6, 0.32, 0.85, 0.46, 0.8) -- ready
      text.draw(bx + bw + 4, y, "ready", { r = 0.5, g = 0.9, b = 0.6, a = 0.85 })
    end
  end
  bar(0, "hop", d.hop_cd, k.hop_cd)
  bar(1, "grapple", d.grapple_cd, k.grapple_cd)
  bar(2, "tp", d.tp_cd, k.tp_min_interval)
  local spent = {}
  if d.fj_used > 0.5 then spent[#spent + 1] = "FLASH" end
  if d.upjumped > 0.5 then spent[#spent + 1] = "UPJ" end
  if d.hop_used > 0.5 then spent[#spent + 1] = "HOP" end
  if d.grapple_used > 0.5 then spent[#spent + 1] = "GRAP" end
  text.draw(3, 38, #spent > 0 and ("spent: " .. table.concat(spent, " "))
            or "air: all ready", { r = 0.85, g = 0.8, b = 0.7, a = 0.85 })
  local mode = d.tp_mode > 0.5 and "B back/phase" or "A fwd/solid"
  local fl = d.fluttering > 0.5
            and ("  flutter %.1fs"):format(
              (k.flutter_interval * k.flutter_boosts - d.flutter_t) / 60)
            or ""
  text.draw(3, 46, "phase: " .. mode .. fl,
            { r = 0.55, g = 0.88, b = 0.95, a = 0.85 })
end

function game.draw()
  pal.begin_frame(0.42, 0.58, 0.80, 1)
  local frame = state.frame()
  local camx, camy = cam:f32(0), cam:f32(4)
  gfx.camera(camx, camy)

  level.draw_bg(frame)

  gfx.layer(1)
  level.tm:draw(level.tex, camx, camy)
  props.draw()
  player.draw()
  fx.draw()

  gfx.layer(0)
  local rec = cm.trace and cm.trace.recording and cm.trace.recording()
  text.draw(3, 3, ("frame %d%s"):format(frame, rec and "  REC" or ""),
            { g = 0.95, b = 0.8, a = 0.9 })
  if state.doc.demo ~= 0 then
    local msg = "DEMO * press any key to play"
    local tw = text.measure(msg)
    text.draw((W - tw) // 2, 24, msg, { r = 1, g = 0.92, b = 0.6, a = 0.95 })
  else
    draw_cd_hud() -- TEMP testing overlay (hidden during the demo)
  end
  text.draw(3, H - 11,
            "arrows  space:jump/flash/up  e:hop(hold=flutter)  q:grapple  r:teleport  d:slice",
            { r = 0.90, g = 0.88, b = 0.78, a = 0.9 })
end

return game
