-- cm.ed.win.anim — the animation window (the board's "maybe split
-- animation stuff into separate window", deferred at R4e, built
-- 2026-07-13): clip preview + clip editing over a .spr's clip table.
--
-- The working state IS the sprite ed's — the same CSPR bytes in
-- doc.assets[path].spr through cm.ed.win.sprite's open/commit doors, so
-- clip edits ride the same journal (ctrl+Z/Y, dirty dot, revert) and a
-- sprite window on the same path updates live. Playback is a dev-only
-- preview (ephemeral plumbing on ed.g.aw[path]; one editor frame = one
-- 1/60s tick — cm.anim's pure evaluator does the walking).
--
-- Bind by dragging a .spr in (accepts/rebind), the spawn menu + drag,
-- or the sprite ed's header "anim" button.

local M = select(2, ...) or {}
local anim = cm.require("cm.anim")
local sprite = cm.require("cm.sprite")
local paint = cm.require("cm.paint")

M.kind = "anim"
M.help = "win-sprite"
M.menu = "animation"
M.DEF_W, M.DEF_H = 420, 300

local COL = {
  rail = 0x1a1728ff, btn = 0x262238ff, btn_on = 0x4a4370ff,
  btn_hot = 0x3a3560ff, text = 0xd8d2f2ff, dim = 0x8a84b0ff,
  hot = 0xE8E4FFff, accent = 0x7fd8a8ff, danger = 0xf07a7aff,
  checker_a = 0x232030ff, checker_b = 0x2b2838ff,
}

function M.defaults()
  return { path = "", clip = "", sel = 1 }
end

function M.title(win)
  local base = win.path:match("([^/]+)$") or "animation"
  return base .. " · anim"
end

function M.accepts(win, path)
  return path:lower():find("%.spr$") ~= nil
end

function M.rebind(win, ed, path)
  win.path = path
  win.clip, win.sel = "", 1
  ed.touch()
end

-- the §6 contract delegates to the sprite kind — same path, same
-- working bytes, same journal (both windows walk the one history)
local S = function() return cm.require("cm.ed.win.sprite") end
function M.dirty(win, ed) return S().dirty(win, ed) end
function M.save(win, ed) return S().save(win, ed) end
function M.undo(win, ed) return S().undo(win, ed) end
function M.redo(win, ed) return S().redo(win, ed) end
function M.revert(win, ed) return S().revert(win, ed) end

local function plumb(ed, path)
  local g = ed.g
  g.aw = g.aw or {}
  local p = g.aw[path]
  if not p then
    p = { playing = true, t = 0 }
    g.aw[path] = p
  end
  return p
end

-- Animation previews own independent raw textures on g.aw. Rewind parking
-- invalidates that cache just like the sprite editor's g.sw cache.
function M.drop_ephemeral(ed)
  for _, p in pairs(ed.g.aw or {}) do
    if p.tex then
      pal.tex_free(p.tex)
      p.tex = nil
    end
  end
end

local function checker(x, y, w, h, z)
  pal.x_ig_rect_fill(x, y, w, h, COL.checker_a, 3 * z)
  local step = 10 * z
  pal.x_ig_clip_push(x, y, w, h)
  for iy = 0, math.ceil(h / step) - 1 do
    for ix = 0, math.ceil(w / step) - 1 do
      if (ix + iy) % 2 == 0 then
        pal.x_ig_rect_fill(x + ix * step, y + iy * step, step, step,
                           COL.checker_b)
      end
    end
  end
  pal.x_ig_clip_pop()
end

-- composite the preview frame (1-based) into the window's own texture
local function refresh(pw, doc, fi)
  if pw.tex and pw.docref == doc and pw.frame == fi then return end
  if not pw.comp or pw.comp.w ~= doc.w or pw.comp.h ~= doc.h then
    pw.comp = paint.image(doc.w, doc.h)
    if pw.tex then
      pal.tex_free(pw.tex)
      pw.tex = nil
    end
  end
  sprite.composite_into(doc, fi, pw.comp)
  if not (pw.tex
          and pal.tex_update(pw.tex, pw.comp.buf, doc.w, doc.h)) then
    if pw.tex then pal.tex_free(pw.tex) end
    pw.tex = pal.tex_create(doc.w, doc.h,
                            pw.comp.buf:str(0, doc.w * doc.h * 4))
  end
  pw.docref, pw.frame = doc, fi
end

local function button(i, ctx, x, y, w, h, label, on, px)
  local hov = ctx.hot and i.wx >= x and i.wx < x + w
              and i.wy >= y and i.wy < y + h
  pal.x_ig_rect_fill(x, y, w, h, on and COL.btn_on
                     or (hov and COL.btn_hot or COL.btn), 3 * ctx.z)
  local tw = pal.x_ig_text_size(label, px, 1)
  pal.x_ig_text(x + (w - tw) * 0.5, y + (h - px) * 0.45, px,
                (on or hov) and COL.hot or COL.dim, label, 1)
  return hov and i.clicked[1]
end

local LOOPS = { loop = "once", once = "pingpong", pingpong = "loop" }

function M.draw(win, ctx)
  local ed = ctx.ed
  local z = ctx.z
  local px = math.max(4, 11 * z)
  local i = cm.require("cm.ui").inp

  if win.path == "" then
    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, COL.dim,
                  "no sprite bound — drag a .spr here", 0)
    return
  end

  local a, p = S().open_path(ed, win.path)
  local doc = p and p.doc
  if not doc then
    pal.x_ig_text(ctx.cx + 8 * z, ctx.cy + 8 * z, px, COL.danger,
                  p and p.err or "unreadable sprite", 0)
    return
  end
  local pw = plumb(ed, win.path)
  local commit = function() S().commit_path(ed, win.path) end

  -- resolve the clip (captured selection; fall back to the first)
  local clips = doc.clips or {}
  local cur = anim.find(clips, win.clip) or clips[1]
  if cur and win.clip ~= cur.name then win.clip = cur.name end

  -- ---- layout: preview | clip rail; transport + entries below ----
  local RR = math.min(110 * z, ctx.cw * 0.34) -- clip rail
  local BB = px * 3.6                         -- transport + entries
  local cvx, cvy = ctx.cx, ctx.cy
  local cvw, cvh = ctx.cw - RR, ctx.ch - BB
  if cvw < 40 or cvh < 40 then return end

  -- playback (dev preview: one editor frame = one tick)
  local nsel = cur and math.min(win.sel or 1, #cur.frames) or 1
  local fi -- 1-based composite frame
  if cur and #cur.frames > 0 then
    if pw.playing then
      pw.t = (pw.t or 0) + 1
      fi = anim.frame_at(cur, pw.t) + 1
    else
      fi = (cur.frames[nsel] and cur.frames[nsel].frame or 0) + 1
    end
  else -- no clips: play the whole strip at 8 ticks/frame
    pw.t = (pw.t or 0) + 1
    fi = (pw.t // 8) % math.max(1, doc.frames) + 1
  end
  if fi < 1 then fi = 1 elseif fi > doc.frames then fi = doc.frames end
  refresh(pw, doc, fi)

  -- preview (aspect fit over a checker)
  checker(cvx, cvy, cvw, cvh, z)
  local m = 6 * z
  local s = math.min((cvw - 2 * m) / doc.w, (cvh - 2 * m) / doc.h)
  if pw.tex then
    pal.x_ig_image(pw.tex, cvx + (cvw - doc.w * s) * 0.5,
                   cvy + (cvh - doc.h * s) * 0.5, doc.w * s, doc.h * s)
  end
  pal.x_ig_text(cvx + 5 * z, cvy + 4 * z, px * 0.85, COL.dim,
                ("frame %d/%d"):format(fi, doc.frames), 0)

  -- ---- the clip rail ----
  local rx = ctx.cx + ctx.cw - RR + 3 * z
  pal.x_ig_rect_fill(rx - 3 * z, ctx.cy, RR, cvh, COL.rail, 4 * z)
  local ry = ctx.cy + 4 * z
  local rh = px * 1.6
  pal.x_ig_text(rx + 2 * z, ry, px * 0.85, COL.dim, "clips", 0)
  ry = ry + px * 1.3
  for ci, c in ipairs(clips) do
    local on = cur == c
    local hov = ctx.hot and i.wx >= rx and i.wx < rx + RR - 8 * z
                and i.wy >= ry and i.wy < ry + rh
    if on or hov then
      pal.x_ig_rect_fill(rx, ry, RR - 9 * z, rh,
                         on and COL.btn_on or COL.btn_hot, 3 * z)
    end
    pal.x_ig_clip_push(rx, ry, RR - 12 * z, rh)
    pal.x_ig_text(rx + 4 * z, ry + (rh - px) * 0.45, px * 0.95,
                  on and COL.hot or COL.text,
                  (c.name or ("clip " .. ci))
                  .. " · " .. (c.loop or "loop"), 0)
    pal.x_ig_clip_pop()
    if hov and i.clicked[1] then
      win.clip = c.name
      win.sel = 1
      pw.t = 0
      ctx.touch()
    end
    ry = ry + rh + 2 * z
    if ry > ctx.cy + cvh - rh * 2 then break end
  end
  local bw = (RR - 14 * z) / 2
  if button(i, ctx, rx, ry, bw, rh, "+", false, px) then
    local n = #clips + 1
    clips[n] = { name = "clip" .. n, loop = "loop",
                 frames = { { frame = fi - 1, dur = 8 } } }
    doc.clips = clips
    win.clip = clips[n].name
    win.sel = 1
    commit()
  end
  if button(i, ctx, rx + bw + 2 * z, ry, bw, rh, "-", false, px)
     and cur then
    for ci, c in ipairs(clips) do
      if c == cur then table.remove(clips, ci) end
    end
    win.clip = clips[1] and clips[1].name or ""
    win.sel = 1
    commit()
  end

  -- ---- transport + the entry strip ----
  local ty = ctx.cy + cvh + 3 * z
  local th = px * 1.6
  local x = ctx.cx + 2 * z
  if button(i, ctx, x, ty, px * 3.4, th, pw.playing and "pause" or "play",
            pw.playing, px * 0.9) then
    pw.playing = not pw.playing
    pw.t = 0
  end
  x = x + px * 3.4 + 4 * z
  if cur then
    if button(i, ctx, x, ty, px * 3.4, th, cur.loop or "loop", false,
              px * 0.9) then
      cur.loop = LOOPS[cur.loop or "loop"]
      commit()
    end
    x = x + px * 3.4 + 8 * z
    -- entries: chips of frame:dur; click = pause + show; sel edits.
    -- The UI speaks 1-BASED frame numbers (the sprite ed's chips); the
    -- clip DATA stays 0-based (the .anim codec + runtime contract) —
    -- the +1/-1 happens only here at the display/input boundary.
    local ey = ty
    for ei, e in ipairs(cur.frames) do
      local label = ("%d:%d"):format(e.frame + 1, e.dur or 1)
      local w2 = pal.x_ig_text_size(label, px * 0.85, 0) + 8 * z
      if x + w2 > ctx.cx + ctx.cw - 2 * z then break end
      if button(i, ctx, x, ey, w2, th, label, ei == nsel and not pw.playing,
                px * 0.85) then
        win.sel = ei
        pw.playing = false
        ctx.touch()
      end
      x = x + w2 + 3 * z
    end
    -- the second row: entry ops + fields for the selected entry
    local y2 = ty + th + 3 * z
    x = ctx.cx + 2 * z
    if button(i, ctx, x, y2, px * 2.4, th, "+f", false, px * 0.85) then
      local last = cur.frames[#cur.frames]
      cur.frames[#cur.frames + 1] = { frame = last and last.frame or 0,
                                      dur = last and last.dur or 8 }
      win.sel = #cur.frames
      commit()
    end
    x = x + px * 2.4 + 3 * z
    if button(i, ctx, x, y2, px * 2.4, th, "-f", false, px * 0.85)
       and #cur.frames > 1 and cur.frames[nsel] then
      table.remove(cur.frames, nsel)
      win.sel = math.max(1, nsel - 1)
      commit()
    end
    x = x + px * 2.4 + 8 * z
    local sel = cur.frames[nsel]
    if sel and not ctx.occluded then
      local function field(id, label, val, w2)
        pal.x_ig_text(x, y2 + (th - px * 0.9) * 0.45, px * 0.8, COL.dim,
                      label, 0)
        local lx = x + pal.x_ig_text_size(label, px * 0.8, 0) + 3 * z
        pal.x_ig_rect(lx, y2 + 1, w2, th - 2, 0x4a437088, 1, 2 * z)
        local text, _, _, st = pal.x_ig_edit {
          id = id .. win.id, x = lx + 1, y = y2 + 2, w = w2 - 2, h = th - 4,
          text = val, px = px * 0.9, font = 1, enter = true,
          multiline = false,
        }
        x = lx + w2 + 6 * z
        return st and st.submit and text or nil
      end
      local got = field("anf", "frame", tostring(sel.frame + 1), 30 * z)
      if got and tonumber(got) then
        sel.frame = math.max(0, math.min(doc.frames - 1,
                                         math.floor(tonumber(got)) - 1))
        commit()
      end
      got = field("and", "dur", tostring(sel.dur or 1), 30 * z)
      if got and tonumber(got) then
        sel.dur = math.max(1, math.floor(tonumber(got)))
        commit()
      end
    end
  else
    pal.x_ig_text(x + 4 * z, ty + (th - px) * 0.45, px * 0.9, COL.dim,
                  "no clips — + adds one (plays all frames meanwhile)", 0)
  end
end

return M
