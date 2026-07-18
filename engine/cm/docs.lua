-- cm.docs — the documentation search index (A8). The shipped guides under
-- engine/stock/docs/*.md are rendered by the help reader (cm.ed.win.help,
-- D061), but until now nothing could SEARCH them: the reader had history and
-- links but no find, and the launcher ranked only the three doc FILENAMES.
-- A8's "searchable public API/task reference" needs a real substrate — this
-- is it: a pure section index + cross-doc ranked matcher the help reader (and,
-- later, the launcher) queries.
--
--   local docs = cm.require("cm.docs")
--   for _, hit in ipairs(docs.search("camera shake")) do
--     -- hit = { name, title, section, line, snippet, score }
--     -- open hit.name in the reader, scroll to hit.line
--   end
--
-- Everything here is PURE over the markdown text (search/sections/section_at/
-- heading_slug take a source string or a supplied corpus), so the ranking is
-- KAT-pinned against synthetic corpora. Only list() touches the filesystem
-- (pal.list_dir/read_file at the engine root, exactly like help's own reader),
-- and it is editor/tool code — never the sim: no buffer, no doc, no snapshot,
-- no verify path ever calls it. Directory order can't leak in: list() sorts by
-- name and every scan below is line-ordered, so results are deterministic
-- regardless of the host's readdir order.
--
-- Semantics, pinned by KATs:
--   * sections(src) -> ordered { {level,title,line,lo,hi}, ... }. One entry
--     per markdown heading (level = #'#'), covering source lines lo..hi (until
--     the next heading or EOF). A synthetic lead section {level=0} covers any
--     preamble before the first heading, and is dropped when the doc opens on
--     a heading (all shipped docs do). Headings inside ``` fences are text,
--     not headings — a shell/lua comment in a code sample never splits a doc.
--   * section_at(secs, line) -> the section owning a source line (the last
--     heading at or before it), or nil.
--   * heading_slug(title) -> a GitHub-style anchor slug ("Camera (cm.camera)"
--     -> "camera-cmcamera"). Both sides of an in-doc #anchor use THIS, so the
--     reader's deep links resolve by construction.
--   * search(query, corpus?) -> ranked { {name,title,section,line,snippet,
--     score}, ... }. corpus defaults to list(). Query tokens split on
--     whitespace, lower-cased, matched LITERALLY (so "cm.actor" is not a Lua
--     pattern). A doc qualifies only if it contains EVERY token (doc-level
--     AND). Within a qualifying doc, a section that itself covers every token
--     is a "full" hit and is emitted; if no section covers them all, the doc's
--     best-covering section is emitted once (the scattered-terms fallback).
--     Ranking: full-section hits first, then more terms in the heading, then
--     more terms co-occurring on one body line, then deeper (more specific)
--     headings, then tighter sections; ties break by (name, line) so the order
--     is total. Empty/whitespace query -> {}.

local M = select(2, ...) or {}

local STOCK = "engine/stock/docs"

-- ---- the shipped-doc corpus (cached; reads at the engine root like help) ----

local cache
function M.list()
  if cache then return cache end
  local out = {}
  for _, n in ipairs(pal.list_dir(STOCK) or {}) do
    local file = n:match("([^/]+%.md)$")
    if file then
      local src = pal.read_file(STOCK .. "/" .. file) or ""
      local title = src:match("^#+%s*([^\n]+)")
                    or file:gsub("%.md$", ""):gsub("[%-_]", " ")
      out[#out + 1] = { name = file, title = title,
                        path = STOCK .. "/" .. file, src = src }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  cache = out
  return out
end

-- drop the cache (an editor doc-save could restage; the shipped guides are
-- static, but keep the door honest)
function M.reload() cache = nil end

-- ---- parsing ----

-- split a source string into its numbered lines (1-based). Terminate the last
-- line if the source didn't, but do NOT double-terminate a source already
-- ending in a newline (that would invent a phantom trailing line and throw the
-- line numbering — and thus every goto target — off by one).
local function split_lines(src)
  src = tostring(src or "")
  if src:sub(-1) ~= "\n" then src = src .. "\n" end
  local lines, n = {}, 0
  for line in src:gmatch("([^\n]*)\n") do
    n = n + 1
    lines[n] = line
  end
  return lines, n
end
M._lines = split_lines

function M.sections(src)
  local lines, total = split_lines(src)
  local secs = {}
  secs[1] = { level = 0, title = "(intro)", line = 1, lo = 1 }
  local fence = false
  for ln = 1, total do
    local line = lines[ln]
    if line:match("^%s*```") then
      fence = not fence
    elseif not fence then
      local h, title = line:match("^(#+)%s+(.-)%s*$")
      if h then
        secs[#secs].hi = ln - 1
        secs[#secs + 1] = { level = #h, title = title, line = ln, lo = ln }
      end
    end
  end
  secs[#secs].hi = total
  -- an empty lead (the doc opened on a heading) contributes nothing
  if (secs[1].hi or 0) < secs[1].lo then table.remove(secs, 1) end
  return secs
end

-- classify every source line for the reader as "fence" (a ``` marker line —
-- drawn as nothing), "code" (a code-BODY line: inside a ``` fence, or a
-- 4-space indented block, INCLUDING lines indented deeper than 4 for nested
-- code and interior blank lines that the block resumes past), or "text"
-- (everything else — headings, bullets, blanks, paragraphs — which the reader
-- lays out itself). Pure over the text; this owns the code/prose boundary (the
-- stateful part: fence toggling + indent runs) so it is KAT-pinned, while the
-- reader keeps prose layout. Returns kind[1..n], lines, n.
function M.line_kinds(src)
  local lines, n = split_lines(src)
  local kind = {}
  local fence = false
  for ln = 1, n do
    local line = lines[ln]
    if line:match("^%s*```") then
      kind[ln] = "fence"; fence = not fence
    elseif fence then
      kind[ln] = "code"                                   -- a fenced body line
    elseif line:match("^    ") and line:match("%S") then
      kind[ln] = "code"                     -- an indented line (>=4, any depth)
    else
      kind[ln] = "text"
    end
  end
  -- second pass: a blank line between two indented code lines is interior to
  -- the block (so blank-separated groups render as ONE contiguous block, not
  -- fragmented by prose gaps). Fenced interior blanks are already "code" above.
  for ln = 1, n do
    if kind[ln] == "text" and not lines[ln]:match("%S") then
      local prev, nxt
      for k = ln - 1, 1, -1 do if lines[k]:match("%S") then prev = kind[k]; break end end
      for k = ln + 1, n do if lines[k]:match("%S") then nxt = kind[k]; break end end
      if prev == "code" and nxt == "code" then kind[ln] = "code" end
    end
  end
  return kind, lines, n
end

function M.section_at(secs, line)
  local owner
  for _, s in ipairs(secs) do
    if s.lo <= line and line <= (s.hi or s.lo) then return s end
    if s.lo <= line then owner = s end
  end
  return owner
end

function M.heading_slug(title)
  local s = tostring(title):lower():gsub("`", "")
  s = s:gsub("[^%w%s%-]", "")     -- keep letters/digits/space/hyphen
  s = s:gsub("%s+", "-"):gsub("%-+", "-")
  s = s:gsub("^%-", ""):gsub("%-$", "")
  return s
end

-- ---- search ----

-- a readable one-line snippet around the first matching term
local function snippet_of(line, terms)
  local s = tostring(line or "")
  s = s:gsub("^%s*#+%s*", ""):gsub("^%s*[%-%*]%s+", "")
  s = s:gsub("`", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local low = s:lower()
  local pos
  for _, t in ipairs(terms) do
    local p = low:find(t, 1, true)
    if p and (not pos or p < pos) then pos = p end
  end
  pos = pos or 1
  local W = 84
  local a = math.max(1, pos - 24)
  local out = s:sub(a, a + W)
  if a > 1 then out = "…" .. out end
  if a + W < #s then out = out .. "…" end
  return out
end
M._snippet = snippet_of

local function tokenize(query)
  local terms = {}
  for t in tostring(query or ""):lower():gmatch("%S+") do
    terms[#terms + 1] = t
  end
  return terms
end
M._tokenize = tokenize

-- score a doc that already passed the doc-level AND gate; append its result(s)
local function score_doc(d, terms, lines, secs, out)
  local nterms = #terms
  local emitted_full = false
  local best
  for _, s in ipairs(secs) do
    local htitle = s.title:lower()
    local covered = {}         -- term index -> true if present in this section
    local headcov = 0
    for ti, t in ipairs(terms) do
      if htitle:find(t, 1, true) then covered[ti] = true; headcov = headcov + 1 end
    end
    local bestline, bestlinecov = nil, 0
    for li = s.lo, (s.hi or s.lo) do
      local low = (lines[li] or ""):lower()
      local lc = 0
      for ti, t in ipairs(terms) do
        if low:find(t, 1, true) then covered[ti] = true; lc = lc + 1 end
      end
      if lc > bestlinecov then bestlinecov = lc; bestline = li end
    end
    local cov = 0
    for _ in pairs(covered) do cov = cov + 1 end
    if cov > 0 then
      local full = cov == nterms
      local width = (s.hi or s.lo) - s.lo
      -- deeper headings are more specific; the lead (level 0) is least
      local specificity = s.level * 0.5
      local score = (full and 1000 or 0) + headcov * 100 + bestlinecov * 10
                    + specificity - width * 0.001
      local hitline = (headcov > 0 and bestlinecov == 0) and s.line
                      or (bestline or s.line)
      -- a heading hit reveals the heading, but previews the first body line
      -- (the section name is already the card's subtitle — don't repeat it)
      local snipline = hitline
      if hitline == s.line then
        for li = s.lo + 1, (s.hi or s.lo) do
          if (lines[li] or ""):match("%S") then snipline = li; break end
        end
      end
      local cand = { name = d.name, title = d.title, section = s.title,
                     line = hitline, score = score,
                     snippet = snippet_of(lines[snipline], terms) }
      if full then
        out[#out + 1] = cand
        emitted_full = true
      elseif not best or score > best.score then
        best = cand
      end
    end
  end
  if not emitted_full and best then out[#out + 1] = best end
end

function M.search(query, corpus)
  corpus = corpus or M.list()
  local terms = tokenize(query)
  if #terms == 0 then return {} end
  local out = {}
  for _, d in ipairs(corpus) do
    local src = d.src or ""
    local low = src:lower()
    local docok = true
    for _, t in ipairs(terms) do
      if not low:find(t, 1, true) then docok = false; break end
    end
    if docok then
      local lines = split_lines(src)
      score_doc(d, terms, lines, M.sections(src), out)
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.name ~= b.name then return a.name < b.name end
    return a.line < b.line
  end)
  return out
end

return M
