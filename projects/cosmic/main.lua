-- cosmic main.lua — the GREYBOX cartridge for the cosmic game (docs/STORY.md,
-- docs/maps/). The proven mecha-girl moveset (M7, D035 / GAME.md §4) walking a
-- multi-map blockout: each map (maps/*.lua) is geometry + annotated MARKERS that
-- spell out the plan (what goes where + why). Travel between maps via portals
-- (stand in one, press Up). This is a planning/feel tool — dialogue, triggers,
-- combat and the rich environment render come LATER (after the art mockup).
--
-- Controls: arrows move · space jump/flash/up · e hop(hold=flutter) · q grapple
-- · r teleport · d slice(stub) · UP at a portal = travel · M toggle plan overlay
-- · N next map (dev) · F1 editor · F2 studio · ` console · Esc options.

local m = cm.require("cm.math")
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local gfx = cm.require("cm.gfx")
local level = cm.require("level")
local player = cm.require("player")
local props = cm.require("props")
local fx = cm.require("fx")

local W, H = pal.gfx_size()

local game = {}
game.level = level -- console/editor evals reach the host: game.level.use("south_trail")
game.props = props

-- feel knobs, all live (doc tree -> snapshots, console, F1 panels). Same M7
-- moveset defaults as the sandbox; the cosmic project tunes its own knobs.dat.
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
  prop = { gravity = 700, fall_max = 340, rest = 0.3, wall_rest = 0.45, fric = 7.0 },
  fx = { gravity = 420, drag = 2.2, run_dist = 22 },
  feel = { squash = 0.55, squash_t = 0.16, stretch = 0.4, stretch_t = 0.12 },
}

local cam
local SHOW_MARKERS = true -- the plan overlay (render-only dev flag; M toggles)

local function knob_file() return cm.main.args.project .. "/knobs.dat" end

local function load_knobs()
  local bytes = pal.read_file(knob_file())
  if not bytes then return nil end
  local ok, t = pcall(state.parse, bytes)
  if ok and type(t) == "table" then return t end
  return nil
end

function game.save_knobs()
  return pal.write_file(knob_file(), state.canon(state.doc.knobs))
end

function game.init()
  local d = state.doc
  d.knobs = d.knobs or load_knobs() or {}
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

  -- build the live map FIRST (player.init reads level.spawn, props.init reads
  -- level.prop_spots). The current map persists in the doc tree.
  level.use(d.map or "rim_hub")

  fx.init()
  props.init()
  player.init()

  cam = pal.buf("cosmic.cam", 32)
  if cam:f32(0) == 0 and cam:f32(4) == 0 then
    local px, py = player.center()
    cam:f32(0, m.clamp(px - W / 2, 0, level.tm.pw - W))
    cam:f32(4, m.clamp(py - H / 2, 0, level.tm.ph - H))
  end

  input.map({
    { "left", input.key.left }, { "right", input.key.right },
    { "up", input.key.up }, { "down", input.key.down },
    { "jump", input.key.space }, { "hop", input.key.e },
    { "grapple", input.key.q }, { "teleport", input.key.r },
    { "attack", input.key.d },
    { "markers", input.key.m },   -- toggle the plan overlay
    { "nextmap", input.key.n },   -- dev: cycle to the next map
  })

  cm.editor.attach(function()
    return {
      tm = level.tm, atlas = level.tex,
      camx = cam:f32(0), camy = cam:f32(4),
      colliders = function()
        local px, py = player.pos()
        local list = { { x = px, y = py, w = player.W, h = player.H, kind = "player" } }
        for i = 1, props.count() do
          local x, y, w, h = props.get(i)
          list[#list + 1] = { x = x, y = y, w = w, h = h,
                              kind = props.held(i) and "held" or "prop" }
        end
        return list
      end,
      save = function() return game.save_knobs() end,
      reset_eval = "game.level.use(game.level.current)",
      props = {
        { name = "crate", icon = level.crate_uv,
          spawn = "game.props.spawn(%d,%d)",
          erase = "game.props.despawn_at(%d,%d)" },
      },
    }
  end)
end

-- travel to a map at an arrival marker (portal use, or the N dev key / console).
-- Re-seeds crates for the new map and snaps the camera to the arrival point.
function game.travel(name, at)
  local sp = level.go(name, at)
  if not sp then return false end
  player.warp(sp.x, sp.y)
  pal.buf_free("sandbox.props") -- force props to re-seed from the new map's spots
  props.init()
  local px, py = player.center()
  cam:f32(0, m.clamp(px - W / 2, 0, level.tm.pw - W))
  cam:f32(4, m.clamp(py - H / 2, 0, level.tm.ph - H))
  return true
end

local function build_ctl()
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
  cam:f32(0, m.clamp(cx, 0, level.tm.pw - W))
  cam:f32(4, m.clamp(cy, 0, level.tm.ph - H))
  cam:f32(8, look)
end

-- GREYBOX traversal: stand in a portal marker and tap Up to travel. (Up alone
-- is unambiguous — up-jump needs Up+space.) Locked/future portals do nothing.
local function try_portal()
  if not input.pressed("up") then return end
  local px, py = player.pos()
  local pw, ph = player.W, player.H
  for _, mk in ipairs(level.markers) do
    if mk.kind == "portal" and mk.to
       and px < mk.x + mk.w and px + pw > mk.x
       and py < mk.y + mk.h and py + ph > mk.y then
      if not game.travel(mk.to, mk.at) then
        pal.log("[cosmic] portal -> " .. mk.to .. " is locked (future area)")
      end
      return
    end
  end
end

function game.step()
  player.step(build_ctl())
  props.step()
  fx.step()
  cam_step()
  try_portal()
  if input.pressed("markers") then SHOW_MARKERS = not SHOW_MARKERS end
  if input.pressed("nextmap") then -- dev: cycle maps
    local i = 1
    for k, name in ipairs(level.order) do if name == level.current then i = k end end
    game.travel(level.order[(i % #level.order) + 1])
  end
end

-- ---- the plan overlay (render-only): labeled boxes at strategic spots ----

local KIND_COL = {
  spawn = { 0.40, 0.95, 0.55 }, portal = { 0.45, 0.80, 1.00 },
  npc = { 1.00, 0.52, 0.86 }, shop = { 1.00, 0.85, 0.35 },
  sandbox = { 1.00, 0.62, 0.32 }, arena = { 1.00, 0.42, 0.42 },
  secret = { 0.72, 0.52, 1.00 }, poi = { 0.82, 0.86, 0.92 },
}

local function draw_markers(camx, camy)
  for _, mk in ipairs(level.markers) do
    local sx, sy = mk.x - camx, mk.y - camy
    if sx < W and sx + mk.w > 0 and sy < H and sy + mk.h > 0 then
      local c = KIND_COL[mk.kind] or KIND_COL.poi
      pal.quad(sx, sy, mk.w, mk.h, c[1], c[2], c[3], 0.14)   -- fill
      pal.quad(sx, sy, mk.w, 1, c[1], c[2], c[3], 0.85)      -- edges
      pal.quad(sx, sy + mk.h - 1, mk.w, 1, c[1], c[2], c[3], 0.5)
      pal.quad(sx, sy, 1, mk.h, c[1], c[2], c[3], 0.6)
      pal.quad(sx + mk.w - 1, sy, 1, mk.h, c[1], c[2], c[3], 0.6)
      local ly = m.max(1, sy - 8)
      text.draw(sx + 1, ly, mk.label, { r = c[1], g = c[2], b = c[3], a = 0.95 })
      if mk.note and mk.note ~= "" then
        text.draw(sx + 2, sy + 2, mk.note, { r = 0.93, g = 0.93, b = 0.86, a = 0.78 })
      end
    end
  end
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
  if SHOW_MARKERS then draw_markers(camx, camy) end

  text.draw(3, 3, ("frame %d"):format(frame), { g = 0.95, b = 0.8, a = 0.9 })
  local title = (level.title or "?") .. "  [GREYBOX]"
  text.draw((W - text.measure(title)) // 2, 3, title,
            { r = 1, g = 0.92, b = 0.7, a = 0.95 })
  text.draw(3, H - 11,
            "arrows space:jump/flash/up  e:hop  q:grapple  r:tp  |  UP@portal:travel  M:plan  N:next map",
            { r = 0.90, g = 0.88, b = 0.78, a = 0.9 })
end

return game
