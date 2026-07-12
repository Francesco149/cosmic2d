-- cm.ed.lex — pure per-line tokenizers for the code ed (EDITOR.md §12.2).
-- No drawing, no pal calls — selftested headless. The code window draws
-- every glyph itself (the D051 ghost-widget split), so "syntax
-- highlighting" is literally: split each visible line into colored spans.
--
--   M.line(lang, s, carry) -> tokens, carry_out
--     tokens = array of {a, b, k [, t]} — 1-based inclusive byte range,
--     kind, and (md links) the link target. Gaps between tokens are the
--     caller's default face. carry is the multi-line lexer state at the
--     line START ("" = none); thread it line to line.
--   M.carry_line(lang, s, carry) -> carry_out
--     the cheap scan: advances carry without building tokens (recomputing
--     the whole file's carry array on every keystroke must be fast).
--   M.link_at(s, pos) -> a, b, target
--     the token under byte pos that looks like a link (md targets, module
--     dots, path-ish words); resolution against real files is the window's.
--
-- Kinds: kw str num com  (lua)   h code link em  (md)
-- Carry codes (strings, compare cheap): "" none; "c0".."cN" in a long
-- comment with N equals; "s0".."sN" long string; "f" inside an md fence.

local M = select(2, ...) or {}

local KW = {}
for w in ("and break do else elseif end false for function goto if in local " ..
          "nil not or repeat return then true until while"):gmatch("%S+") do
  KW[w] = true
end

function M.lang_of(path)
  local ext = path:match("%.([%w_]+)$")
  ext = ext and ext:lower() or ""
  if ext == "lua" then return "lua" end
  if ext == "md" then return "md" end
  return "txt"
end

-- ---- lua ----

-- the close of a [=*[ bracket with n equals, searched from pos.
-- returns the index AFTER the closing bracket, or nil.
local function long_close(s, pos, n)
  local pat = "]" .. ("="):rep(n) .. "]"
  local a, b = s:find(pat, pos, true)
  if a then return b + 1, a end
end

-- a [=*[ opener at pos? returns equals count + index after it
local function long_open(s, pos)
  if s:byte(pos) ~= 91 then return nil end -- '['
  local i = pos + 1
  while s:byte(i) == 61 do i = i + 1 end -- '='
  if s:byte(i) == 91 then return i - pos - 1, i + 1 end
end

local function lua_line(s, carry, toks)
  local n = #s
  local pos = 1
  -- resume a long bracket from a previous line
  if carry ~= "" then
    local kind = carry:sub(1, 1) == "c" and "com" or "str"
    local eq = tonumber(carry:sub(2)) or 0
    local nxt, at = long_close(s, 1, eq)
    if not nxt then
      if toks and n > 0 then toks[#toks + 1] = { a = 1, b = n, k = kind } end
      return carry
    end
    if toks then toks[#toks + 1] = { a = 1, b = nxt - 1, k = kind } end
    pos = nxt
  end
  while pos <= n do
    local c = s:byte(pos)
    if c == 45 and s:byte(pos + 1) == 45 then -- '--'
      local eq, body = long_open(s, pos + 2)
      if eq then
        local nxt = long_close(s, body, eq)
        if not nxt then
          if toks then toks[#toks + 1] = { a = pos, b = n, k = "com" } end
          return "c" .. eq
        end
        if toks then toks[#toks + 1] = { a = pos, b = nxt - 1, k = "com" } end
        pos = nxt
      else
        if toks then toks[#toks + 1] = { a = pos, b = n, k = "com" } end
        return ""
      end
    elseif c == 34 or c == 39 then -- quote
      local i = pos + 1
      while i <= n do
        local b = s:byte(i)
        if b == 92 then i = i + 2 -- escape
        elseif b == c then break
        else i = i + 1 end
      end
      if i > n then i = n end
      if toks then toks[#toks + 1] = { a = pos, b = i, k = "str" } end
      pos = i + 1
    elseif c == 91 then -- maybe a long string
      local eq, body = long_open(s, pos)
      if eq then
        local nxt = long_close(s, body, eq)
        if not nxt then
          if toks then toks[#toks + 1] = { a = pos, b = n, k = "str" } end
          return "s" .. eq
        end
        if toks then toks[#toks + 1] = { a = pos, b = nxt - 1, k = "str" } end
        pos = nxt
      else
        pos = pos + 1
      end
    elseif c >= 48 and c <= 57 then -- digit
      local a = pos
      local i = pos + 1
      if c == 48 and (s:byte(i) == 120 or s:byte(i) == 88) then -- 0x
        i = i + 1
        while i <= n do
          local b = s:byte(i)
          if (b >= 48 and b <= 57) or (b >= 97 and b <= 102)
             or (b >= 65 and b <= 70) then i = i + 1 else break end
        end
      else
        while i <= n do
          local b = s:byte(i)
          if (b >= 48 and b <= 57) or b == 46 or b == 101 or b == 69 then
            i = i + 1
          else break end
        end
      end
      if toks then toks[#toks + 1] = { a = a, b = i - 1, k = "num" } end
      pos = i
    elseif (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or c == 95 then
      local a = pos
      local i = pos + 1
      while i <= n do
        local b = s:byte(i)
        if (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b == 95
           or (b >= 48 and b <= 57) then i = i + 1 else break end
      end
      if toks and KW[s:sub(a, i - 1)] then
        toks[#toks + 1] = { a = a, b = i - 1, k = "kw" }
      end
      pos = i
    else
      pos = pos + 1
    end
  end
  return ""
end

-- ---- md (the docs face: mono grid + colored structure, EDITOR.md §12.2) ----

local function md_line(s, carry, toks)
  local n = #s
  if s:find("^```") then
    if toks then toks[#toks + 1] = { a = 1, b = n, k = "code" } end
    return carry == "f" and "" or "f"
  end
  if carry == "f" then
    if toks and n > 0 then toks[#toks + 1] = { a = 1, b = n, k = "code" } end
    return "f"
  end
  if not toks then return "" end
  local ha, hb = s:find("^#+")
  if ha then
    toks[#toks + 1] = { a = 1, b = n, k = "h" }
    return ""
  end
  -- inline faces: `code`, [text](target), **em**, bare [[wiki]] links
  local pos = 1
  while pos <= n do
    local a, b = s:find("`[^`]+`", pos)
    local la, lb, txt, tgt = s:find("%[([^%]]*)%]%(([^%)]+)%)", pos)
    local wa, wb, wt = s:find("%[%[([^%]]+)%]%]", pos)
    local ea, eb = s:find("%*%*[^%*]+%*%*", pos)
    -- earliest match wins
    local best, bk, bt = nil, nil, nil
    if a and (not best or a < best) then best, bk, bt = a, "code", nil end
    if la and (not best or la < best) then best, bk, bt = la, "link", tgt end
    if wa and (not best or wa < best) then best, bk, bt = wa, "link", wt end
    if ea and (not best or ea < best) then best, bk, bt = ea, "em", nil end
    if not best then break end
    local e
    if bk == "code" and best == a then e = b
    elseif bt == tgt and best == la then e = lb
    elseif bt == wt and best == wa then e = wb
    else e = eb end
    toks[#toks + 1] = { a = best, b = e, k = bk, t = bt }
    pos = e + 1
  end
  return ""
end

-- ---- the public face ----

function M.line(lang, s, carry)
  carry = carry or ""
  local toks = {}
  local out
  if lang == "lua" then out = lua_line(s, carry, toks)
  elseif lang == "md" then out = md_line(s, carry, toks)
  else out = "" end
  return toks, out
end

function M.carry_line(lang, s, carry)
  carry = carry or ""
  if lang == "lua" then
    -- fast path: lines without bracket/comment/quote starters can't change
    -- the carry when none is active
    if carry == "" and not s:find("[%-%[\"']") then return "" end
    return lua_line(s, carry, nil)
  elseif lang == "md" then
    return md_line(s, carry, nil)
  end
  return ""
end

-- the link-ish token under byte pos in line s (any lang; the caller
-- resolves candidates against real files). Checked in order: md targets,
-- [[wiki]], quoted strings, dotted module names, bare path words.
function M.link_at(s, pos)
  -- md [text](target): the whole construct is clickable
  local init = 1
  while true do
    local a, b, _, tgt = s:find("%[([^%]]*)%]%(([^%)]+)%)", init)
    if not a then break end
    if pos >= a and pos <= b then return a, b, tgt end
    init = b + 1
  end
  init = 1
  while true do
    local a, b, tgt = s:find("%[%[([^%]]+)%]%]", init)
    if not a then break end
    if pos >= a and pos <= b then return a, b, tgt end
    init = b + 1
  end
  init = 1
  while true do -- quoted: require("cm.ed.wm"), "docs/EDITOR.md"
    local a, b, tgt = s:find("[\"']([^\"']+)[\"']", init)
    if not a then break end
    if pos > a and pos < b then return a + 1, b - 1, tgt end
    init = b + 1
  end
  -- bare word around pos containing '/' or dots (path-ish / module-ish)
  local a = pos
  while a > 1 and s:sub(a - 1, a - 1):find("[%w_%./%-]") do a = a - 1 end
  local b = pos
  while b < #s and s:sub(b + 1, b + 1):find("[%w_%./%-]") do b = b + 1 end
  local word = s:sub(a, b)
  if word:find("[/%.]") and word:find("%w") then return a, b, word end
  return nil
end

return M
