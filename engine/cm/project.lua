-- cm.project — durable project scaffolding shared by the picker and tests.
-- project.lua is the authority marker and is published last: a directory is
-- never discoverable as a project until every required source is durable.

local M = select(2, ...) or {}

M.PROJECT_TMPL = [==[
-- a fresh cosmic2d project. Tweak these; the picker + packager read them.
return {
  name = "__NAME__",
  internal_w = 480,
  internal_h = 270,
  window_scale = 2,
  entry = "main.lua",
  author = "",
  version = "0.1",
  description = "",
  -- A player export additionally needs project-local icon/controls/credits
  -- files and at least one license. The project settings UI will fill these;
  -- see the scripting guide for the declarative metadata contract.
  -- icon = "icon.png",
  -- controls = "CONTROLS.md",
  -- credits = "CREDITS.md",
  -- licenses = { "LICENSE.md" },
}
]==]

M.MAIN_TMPL = [==[
-- __NAME__ — a fresh project. Edit me while the game runs (hot reload)!
local state = cm.require("cm.state")
local input = cm.require("cm.input")
local text = cm.require("cm.text")
local m = cm.require("cm.math")
local W, H = pal.gfx_size()
local game = {}
function game.init()
  input.map({ { "left", input.key.left }, { "right", input.key.right },
              { "jump", input.key.space } })
  local d = state.doc
  d.x, d.y, d.vy = d.x or W / 2, d.y or H - 24, d.vy or 0
end
function game.step()
  local d = state.doc
  if input.down("left") then d.x = d.x - 2 end
  if input.down("right") then d.x = d.x + 2 end
  if input.pressed("jump") and d.y >= H - 24 then d.vy = -5.2 end
  d.vy = d.vy + 0.3
  d.y = m.min(H - 24, d.y + d.vy)
  if d.y >= H - 24 then d.vy = 0 end
  d.x = m.clamp(d.x, 0, W - 16)
end
function game.draw()
  pal.begin_frame(0.13, 0.15, 0.22, 1)
  pal.quad(0, H - 8, W, 8, 0.30, 0.40, 0.36, 1)
  local d = state.doc
  pal.quad(d.x, d.y - 16, 16, 16, 0.95, 0.75, 0.42, 1)
  text.draw(6, 6, "hello from __NAME__ — arrows + space. edit main.lua!",
            { r = 0.95, g = 0.92, b = 0.8, a = 0.9 })
end
return game
]==]

function M.scaffold(dir, name, fail)
  if pal.read_file(dir .. "/project.lua") then
    return nil, "project already exists: " .. dir
  end
  if not pal.mkdir(dir) then return nil, "create project directory failed: " .. dir end
  local main = dir .. "/main.lua"
  local meta = dir .. "/project.lua"
  local ok, err = pal.write_file_atomic(main, (M.MAIN_TMPL:gsub("__NAME__", name)),
                                         fail and fail.main)
  if not ok then
    pal.x_remove(dir)
    return nil, "write project source " .. main .. " failed: " .. tostring(err)
  end
  ok, err = pal.write_file_atomic(meta, (M.PROJECT_TMPL:gsub("__NAME__", name)),
                                  fail and fail.meta)
  if not ok then
    pal.x_remove(main)
    pal.x_remove(dir)
    return nil, "write project metadata " .. meta .. " failed: " .. tostring(err)
  end
  return true
end

return M
