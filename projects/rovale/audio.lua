-- audio — rovale's sound hooks (the bounce/openworld SFX pattern): the
-- walk-order click tick and the NPC greet bell, human-heard presets
-- copied into ins/. All sim code (cm.snd records/replays); a missing
-- .ins just mutes that hook (headless-safe).

local ins = cm.require("cm.ins")
local snd = cm.require("cm.snd")

local M = select(2, ...) or {}

-- ORDERED (no hash-order dependence): slot i-1 gets SFX[i]
local SFX = {
  { "click", "sfx-click", 88 }, -- the coin blip, high + quiet: a tick
  { "greet", "sfx-greet", 76 }, -- the fm-bell hello (openworld's)
}
local by_name = {}

function M.init()
  local proj = cm.main.args.project
  for i, s in ipairs(SFX) do
    local slot = i - 1
    local bytes = pal.read_file(proj .. "/ins/" .. s[2] .. ".ins")
    if bytes then
      local doc = ins.decode(bytes)
      ins.upload(doc, slot, "sim", "sfx" .. slot)
      by_name[s[1]] = { slot = slot, note = s[3] }
    end
  end
end

function M.sfx(name, vel, note)
  local s = by_name[name]
  if s then snd.on(s.slot, note or s.note, vel or 110) end
end

return M
