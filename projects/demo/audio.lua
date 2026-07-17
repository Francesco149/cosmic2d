-- audio — the demo's sound: SFX one-shots + the per-room BGM. All sim
-- code (cm.snd is recorded/replayed/rewound), so the mix is deterministic.
-- SFX live in sim slots 0..31, music tracks in 32..47 (the cm.snd
-- convention); the .ins are the R9f presets, copied into the project.

local ins = cm.require("cm.ins")
local snd = cm.require("cm.snd")

local M = select(2, ...) or {} -- adopt the module table (survives bundle re-execution)

-- ORDERED (no hash-order dependence — the determinism rule): slot i gets
-- SFX[i]. { key, ins file, trigger note }
local SFX = {
  { "jump", "sfx-jump", 64 },
  { "land", "sfx-land", 55 },
  { "coin", "sfx-coin", 74 },
  { "hit", "sfx-hit", 58 },
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

-- swap the BGM to the given room's song (loops). A no-op if already on it.
function M.bgm(room)
  local d = cm.require("cm.state").doc
  local song = room == "town" and "town" or "overworld"
  if d.bgm == song then return end
  d.bgm = song
  snd.music(cm.main.args.project .. "/sound/" .. song .. ".song", { loop = true })
end

return M
