-- audio — bigworld's sound hooks: the openworld SFX set minus the star
-- coin (no pickups here). All sim code (cm.snd is recorded/replayed) so
-- the mix is deterministic; a missing .ins just mutes that hook.

local ins = cm.require("cm.ins")
local snd = cm.require("cm.snd")

local M = select(2, ...) or {}

-- ORDERED (no hash-order dependence): slot i-1 gets SFX[i]
local SFX = {
  { "jump", "sfx-jump", 64 },
  { "land", "sfx-land", 55 },
  { "splash", "sfx-splash", 84 },
  { "greet", "sfx-greet", 76 }, -- note overridden per species (ents.lua)
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
