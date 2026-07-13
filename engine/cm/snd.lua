-- cm.snd — the sim-side audio surface (R9b, docs/AUDIO.md §6): a thin
-- layer over pal.snd_*. Patches are friendly Lua tables packed to the
-- 80-byte flat struct the kernel reads (pure both ways — KAT'd); voice
-- calls forward to the sim bank (snd.bank — recorded, replayed,
-- rewound by construction). The sequencer (cm.snd.seq) and the .ins
-- slot cache land at R9d/R9c; the editor bank's audition mirror is
-- x_snd_ed_* with the same packed bytes.
--
-- The patch table (every field defaulted — the wstudio lesson):
--   { type = "fm"|"sample", alg = 0..7, fb = 0..7, pan = -64..64,
--     gain = 0..255 (128 unity),
--     ops = { { wave = "sine"|"square"|"pulse25"|"pulse12"|"saw"|
--                      "tri"|"noise"|"noise2",
--               coarse = 0..15 (0 = x0.5), fine = -63..63,
--               level = 0..255, a/d/r = ms, s = 0..255,
--               detune = -63..63, fixed = hz|nil }, x4 },
--     -- type "sample":
--     pcm = "<named buffer>" (mono i16 @48k), root = midi note,
--     loop = bool, loop0/loop1 = sample frames, a/d/r = ms, s = 0..255 }

local M = select(2, ...) or {}

M.WAVES = { sine = 0, square = 1, pulse25 = 2, pulse12 = 3,
            saw = 4, tri = 5, noise = 6, noise2 = 7 }
local WAVE_NAMES = {}
for k, v in pairs(M.WAVES) do WAVE_NAMES[v] = k end

local pack, unpack = string.pack, string.unpack

local OP_FMT = "<I1I1i1I1I2I2I2I1i1I1I1I2"
local HDR_FMT = "<I1I1I1I1i1I1I2"

local function pack_op(op)
  op = op or {}
  return pack(OP_FMT,
    M.WAVES[op.wave or "sine"] or 0,
    op.coarse or 1, op.fine or 0, op.level or 0,
    op.a or 5, op.d or 100, op.r or 80, op.s or 200,
    op.detune or 0, op.fixed and 1 or 0, 0, op.fixed or 0)
end

-- the pure packer: patch table -> the kernel's 80 bytes
function M.pack(t)
  t = t or {}
  local typ = t.type == "sample" and 1 or 0
  local head = pack(HDR_FMT, typ, t.alg or 0, t.fb or 0, 0,
                    t.pan or 0, t.gain or 128, 0)
  if typ == 1 then
    local name = tostring(t.pcm or "")
    assert(#name <= 24, "pcm buffer name over 24 bytes")
    local body = name .. string.rep("\0", 24 - #name)
      .. pack("<I1I1I2I2I2I1I1I4I4", t.root or 60, t.loop and 1 or 0,
              t.a or 2, t.d or 0, t.r or 30, t.s or 255, 0,
              t.loop0 or 0, t.loop1 or 0)
      .. string.rep("\0", 22)
    return head .. body .. string.rep("\0", 8)
  end
  local ops = t.ops or {}
  return head .. pack_op(ops[1]) .. pack_op(ops[2]) .. pack_op(ops[3])
         .. pack_op(ops[4]) .. string.rep("\0", 8)
end

-- the inverse (the synth window edits over decoded tables)
function M.unpack(bytes)
  assert(#bytes == 80, "patch must be 80 bytes")
  local typ, alg, fb, _, pan, gain = unpack(HDR_FMT, bytes)
  local t = { alg = alg, fb = fb, pan = pan, gain = gain }
  if typ == 1 then
    t.type = "sample"
    t.pcm = bytes:sub(9, 32):gsub("%z+$", "")
    local root, sflags, a, d, r, s, _, l0, l1 =
      unpack("<I1I1I2I2I2I1I1I4I4", bytes, 33)
    t.root, t.loop = root, sflags % 2 == 1
    t.a, t.d, t.r, t.s = a, d, r, s
    t.loop0, t.loop1 = l0, l1
    return t
  end
  t.type = "fm"
  t.ops = {}
  local off = 9
  for i = 1, 4 do
    local wave, coarse, fine, level, a, d, r, s, detune, ofl, _, fhz =
      unpack(OP_FMT, bytes, off)
    t.ops[i] = { wave = WAVE_NAMES[wave] or "sine", coarse = coarse,
                 fine = fine, level = level, a = a, d = d, r = r, s = s,
                 detune = detune, fixed = ofl % 2 == 1 and fhz or nil }
    off = off + 16
  end
  return t
end

-- ---- the sim bank (recorded; call from sim code only) ----

function M.patch(slot, t)
  pal.snd_patch(slot, type(t) == "string" and t or M.pack(t))
end

function M.on(slot, note, vel)
  return pal.snd_on(slot, note, vel or 100)
end

function M.off(voice)
  pal.snd_off(voice)
end

-- ---- the editor bank (render-only audition; editor code only) ----

function M.ed_patch(slot, t)
  pal.x_snd_ed_patch(slot, type(t) == "string" and t or M.pack(t))
end

M.ed_on = pal and pal.x_snd_ed_on
M.ed_off = pal and pal.x_snd_ed_off

return M
