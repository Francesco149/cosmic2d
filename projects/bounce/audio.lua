-- audio — bounce's sound hooks: SFX one-shots on sim slots 0..4 (the demo
-- cartridge's pattern + its tuned .ins presets, copied into ins/). All sim
-- code (cm.snd is recorded/replayed/rewound), so the mix is deterministic;
-- a missing .ins just mutes that hook (headless-safe).

local ins = cm.require("cm.ins")
local snd = cm.require("cm.snd")

local M = select(2, ...) or {}

-- ORDERED (no hash-order dependence — the determinism rule): slot i-1 gets
-- SFX[i]. { key, ins file, trigger note }
local SFX = {
  { "jump", "sfx-jump", 64 },
  { "land", "sfx-land", 55 },
  { "coin", "sfx-coin", 74 },
  { "hit", "sfx-hit", 58 },
  { "bell", "fm-bell", 76 },
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

function M.sfx(name, vel)
  local s = by_name[name]
  if s then snd.on(s.slot, s.note, vel or 110) end
end

-- goal fanfare: a bell major triad (one frame, three voices)
function M.goal()
  local s = by_name.bell
  if not s then return end
  snd.on(s.slot, 76, 105)
  snd.on(s.slot, 80, 100)
  snd.on(s.slot, 83, 110)
end

return M
