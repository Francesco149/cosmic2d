-- audio — openworld's sound hooks: SFX one-shots on sim slots (the bounce
-- pattern, tuned .ins presets copied into ins/). All sim code (cm.snd is
-- recorded/replayed/rewound) so the mix is deterministic; a missing .ins
-- just mutes that hook (headless-safe).

local ins = cm.require("cm.ins")
local snd = cm.require("cm.snd")

local M = select(2, ...) or {}

-- ORDERED (no hash-order dependence — the determinism rule): slot i-1 gets
-- SFX[i]. { key, ins file, trigger note }
local SFX = {
  { "jump", "sfx-jump", 64 },
  { "land", "sfx-land", 55 },
  { "splash", "sfx-splash", 84 }, -- fixed-clock noise ops: the hiss (12k)
  -- + plosh (2.8k) don't track the note (a note-clocked LFSR at a low
  -- note is a buzz — the human's "low pitch laser"); vel still scales
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

return M
