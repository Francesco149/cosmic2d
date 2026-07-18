-- cm.ed.win.settings — the game's settings as a canvas window (D132).
-- The dev surface over the SAME model the player-facing Esc menu renders:
-- project-declared options (cm.options.add — live values against their
-- declared defaults), the volume knobs, the stick tuning, and the
-- user-wide accessibility toggles — so a dev tests what players will get
-- (including D129's reduced effects, live against the running game
-- window) without leaving the editor. Values route through cm.options'
-- public doors (preview while dragging, set on release), so persistence
-- and on_change behave exactly as they do for a player. Pure dev chrome:
-- no working bytes, no journal, close it fearlessly.
--
-- Deliberately NOT here: rebinding (the capture grammar is player-facing;
-- test it in player mode) and window-size/fullscreen/ui-scale (those
-- reshape the editor's own window — the Esc menu owns them in player
-- mode, the OS window and Aa chrome own them here).

local M = select(2, ...) or {}

M.kind = "settings"
M.menu = "settings"
M.DEF_W, M.DEF_H = 240, 310

local COL = {
  dim = 0x8a84b0ff, text = 0xd8d2f2ff, hot = 0xE8E4FFff,
  head = 0xa89ee0ff, well = 0x1a1728ff, fill = 0x59519eff,
  knob = 0xd8d2f2ff, btn = 0x262238ff, btn_hot = 0x342f4cff,
  on = 0xffb46eff, note = 0x6a6490ff,
}

function M.defaults()
  return { sy = 0 }
end

function M.title(win)
  return "settings"
end

-- one drag gesture at a time; module-local (never a captured win field)
local drag = nil

-- content wheel: scroll (the console model — sy is a captured scalar)
function M.wheel(win, ed, dy)
  win.sy = math.max(0, (win.sy or 0) - dy * 24)
  ed.touch()
end

local function slider(ctx, id, x, y, w, val, lo, hi, fmt)
  local i = cm.require("cm.ui").inp
  local z = ctx.z
  local px = math.max(4, 8.5 * z)
  local bh = math.max(3, px * 0.7)
  pal.x_ig_rect_fill(x, y, w, bh, COL.well, 2 * z)
  local f = (val - lo) / (hi - lo)
  pal.x_ig_rect_fill(x, y, w * f, bh, COL.fill, 2 * z)
  pal.x_ig_rect_fill(x + w * f - 1.5 * z, y - z, 3 * z, bh + 2 * z,
                     COL.knob, z)
  pal.x_ig_text(x + w + 4 * z, y - px * 0.15, px, COL.text,
                (fmt or "%d"):format(val), 0)
  local over = i.wx >= x - 4 * z and i.wx < x + w + 4 * z
               and i.wy >= y - 3 * z and i.wy < y + bh + 3 * z
  if ctx.hot and i.clicked[1] and over and not drag then drag = id end
  if drag == id then
    if i.buttons[1] then
      local nf = math.max(0, math.min(1, (i.wx - x) / w))
      return math.floor(lo + nf * (hi - lo) + 0.5), false
    end
    drag = nil
    return val, true -- released: persist once
  end
  return nil, false
end

local function checkbox(ctx, x, y, label, on)
  local i = cm.require("cm.ui").inp
  local z = ctx.z
  local px = math.max(4, 8.5 * z)
  local s = px * 1.2
  pal.x_ig_rect_fill(x, y, s, s, COL.well, 2 * z)
  if on then pal.x_ig_rect_fill(x + 2 * z, y + 2 * z, s - 4 * z, s - 4 * z,
                                COL.on, z) end
  local tw = pal.x_ig_text_size(label, px, 0)
  pal.x_ig_text(x + s + 4 * z, y + (s - px) * 0.5, px, COL.text, label, 0)
  local over = i.wx >= x and i.wx < x + s + 8 * z + tw
               and i.wy >= y and i.wy < y + s
  if over then pal.x_ig_rect(x - z, y - z, s + 2 * z, s + 2 * z,
                             COL.dim, z, z) end
  return ctx.hot and i.clicked[1] and over
end

local function cyclebtn(ctx, x, y, w, label)
  local i = cm.require("cm.ui").inp
  local z = ctx.z
  local px = math.max(4, 8.5 * z)
  local h = px * 1.7
  local over = i.wx >= x and i.wx < x + w and i.wy >= y and i.wy < y + h
  pal.x_ig_rect_fill(x, y, w, h, over and COL.btn_hot or COL.btn, 2 * z)
  pal.x_ig_text(x + (w - pal.x_ig_text_size(label, px, 0)) * 0.5,
                y + (h - px) * 0.45, px, over and COL.hot or COL.text,
                label, 0)
  return ctx.hot and i.clicked[1] and over
end

function M.draw(win, ctx)
  local options = cm.require("cm.options")
  local input = cm.require("cm.input")
  local view = cm.require("cm.view")
  local z = ctx.z
  local px = math.max(4, 8.5 * z)
  local row = px * 2.1
  local x0 = ctx.cx + 4 * z
  local iw = ctx.cw - 8 * z
  local sw = math.min(iw - 46 * z, 120 * z) -- slider track width
  local y = ctx.cy + 4 * z - (win.sy or 0) * z
  local function head(s)
    pal.x_ig_text(x0, y, px, COL.head, s, 0)
    y = y + row
  end
  local function label(s)
    pal.x_ig_text(x0, y, px, COL.dim, s, 0)
  end

  -- game options: the project's cm.options.add declarations
  head("game options")
  if #options.defs == 0 then
    label("none declared - see cm.options.add")
    y = y + row
  end
  for _, d in ipairs(options.defs) do
    local v = options.get(d.id)
    if d.kind == "toggle" then
      if checkbox(ctx, x0, y, d.label, v) then options.set(d.id, not v) end
    elseif d.kind == "slider" then
      label(d.label)
      y = y + row * 0.8
      local nv, done = slider(ctx, "opt:" .. d.id, x0 + 4 * z, y, sw,
                              v, d.min, d.max)
      if nv then options.preview(d.id, nv) end
      if done then options.set(d.id, options.get(d.id)) end
      y = y + row * 0.4
    else -- choice: one button cycles
      label(d.label)
      if cyclebtn(ctx, x0 + iw - 70 * z, y - px * 0.3, 66 * z,
                  tostring(v)) then
        local at = 1
        for i, c in ipairs(d.choices) do if c == v then at = i end end
        options.set(d.id, d.choices[at % #d.choices + 1])
      end
    end
    y = y + row
  end

  -- volumes (this machine, this project — video.dat)
  head("volume")
  for _, k in ipairs({ "master", "music", "sfx" }) do
    label(k)
    local nv, done = slider(ctx, "vol:" .. k, x0 + 34 * z, y + px * 0.15,
                            sw, options.vol[k], 0, 100, "%d%%")
    if nv then options.preview_vol(k, nv) end
    if done then options.set_vol(k, options.vol[k]) end
    y = y + row
  end

  -- stick tuning (input.dat — the live axis policy knobs, D085)
  head("stick")
  label("deadzone")
  local dz, dzdone = slider(ctx, "stick:dz", x0 + 34 * z, y + px * 0.15, sw,
                            input.deadzone * 100 // 32767, 0, 75, "%d%%")
  if dz then input.set_deadzone(dz * 32767 // 100) end
  if dzdone then input.save_binds() end
  y = y + row
  label("press at")
  local th, thdone = slider(ctx, "stick:th", x0 + 34 * z, y + px * 0.15, sw,
                            math.floor(input.axis_threshold * 100 / 127 + 0.5),
                            1, 100, "%d%%")
  if th then input.set_axis_threshold(math.max(1, th * 127 // 100)) end
  if thdone then input.save_binds() end
  y = y + row

  -- accessibility (user-wide — editor.dat, D129)
  head("accessibility (all projects)")
  if checkbox(ctx, x0, y, "reduce screen shake", view.cfg.reduce_shake) then
    view.set_reduce_shake(not view.cfg.reduce_shake)
  end
  y = y + row
  if checkbox(ctx, x0, y, "reduce flashes", view.cfg.reduce_flash) then
    view.set_reduce_flash(not view.cfg.reduce_flash)
  end
  y = y + row

  pal.x_ig_text(x0, y + row * 0.3, px, COL.note,
                "players reach these in the esc menu;", 0)
  pal.x_ig_text(x0, y + row * 0.3 + px * 1.3, px, COL.note,
                "test rebinding + the menu itself in player mode", 0)
  y = y + row * 2

  -- clamp the wheel scroll to the real content height
  local content = (y + (win.sy or 0) * z - ctx.cy - 4 * z) / z
  local maxsy = math.max(0, content - ctx.ch / z + 8)
  if (win.sy or 0) > maxsy then win.sy = maxsy end
end

return M
