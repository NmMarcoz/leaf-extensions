-- BRScans (brscans.vercel.app) — Portuguese (Brazil) manhwa, machine-translated.
-- Port of the Keiyoushi `pt/brscans` extension. The site is a Next.js front
-- end over a small REST API on AWS API Gateway; images are served from a
-- CloudFront distribution.
--
-- Ids: a series is its numeric API id ("166"); a chapter is its numeric API
-- id ("9851"), which is all page_list needs.
--
-- Differences from the Keiyoushi source:
--   * The Kotlin lists every chapter three times (translated / original /
--     raw "no text" variants). Leaf has no per-chapter label, so duplicate
--     numbers would be confusing: only the Portuguese-translated pages are
--     served, falling back page by page to the original image when a
--     translation is missing (exactly what the Kotlin does).
--   * Non-chapter rows ("Notice.") have no number and are skipped.
--   * Search and the popular list are not paginated by the API.
--   * Filters: none exist on the site's API, nothing to drop.
--
-- Catalogue shape (popular, latest, manga_details, volumes, covers) is
-- included so the site is offered in Explore.

SOURCE = {
  id = "user.brscans",
  name = "BRScans",
  kind = "reader",
  description = "Portuguese (Brazil) translated manhwa from BRScans.",
  lang = "pt",
  base_url = "https://brscans.vercel.app",
  mirrors = {
    "https://3wzrvo9ltl.execute-api.sa-east-1.amazonaws.com",
    "https://d47sf0ah3vbtc.cloudfront.net",
  },
}

local API = "https://3wzrvo9ltl.execute-api.sa-east-1.amazonaws.com/dev"

local function urlencode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Returns decoded JSON, or nil on 404 when allow_404 is set.
local function api_get(path, allow_404)
  local res = leaf.http.get(API .. path, {
    headers = { Accept = "application/json" },
    referer = "https://brscans.vercel.app/",
  })
  if res.status == 404 and allow_404 then
    return nil
  end
  if res.status ~= 200 then
    error(string.format("%s answered %d", path, res.status))
  end
  return leaf.json.decode(res.body)
end

local function present(v)
  if type(v) ~= "string" or v == "" then
    return nil
  end
  return v
end

local function id_string(n)
  n = tonumber(n)
  if n and n == math.floor(n) then
    return tostring(math.floor(n))
  end
  return tostring(n)
end

local function number_string(n)
  if n == math.floor(n) then
    return tostring(math.floor(n))
  end
  return tostring(n)
end

local function cover_of(row)
  return type(row.thumbnail) == "table" and present(row.thumbnail.original) or nil
end

local function to_page(rows, has_next)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = { id = id_string(row.id), title = row.title, cover_url = cover_of(row) }
  end
  return { manga = out, has_next_page = has_next }
end

--[[ ---------------------------------------------------------- catalogue -- ]]

function popular(page)
  if page > 1 then
    return { manga = {}, has_next_page = false }
  end
  return to_page(api_get("/manhwas/top/"), false)
end

function latest(page)
  local data = api_get("/manhwas/?page=" .. page, true)
  if not data then
    return { manga = {}, has_next_page = false }
  end
  return to_page(data.results or {}, type(data.next) == "string")
end

function search(query, page)
  if page > 1 then
    return { manga = {}, has_next_page = false }
  end
  return to_page(api_get("/manhwas/search/?query=" .. urlencode(query)), false)
end

local function fetch_manhwa(id)
  local data = api_get("/manhwas/" .. urlencode(id) .. "/", true)
  if not data then
    error("Obra não encontrada")
  end
  return data
end

function manga_details(id)
  local m = fetch_manhwa(id)
  local description = present(m.description) or ""
  local original = present(m.original_title)
  if original and original:lower() ~= (m.title or ""):lower() then
    description = description .. "\n\nTítulo original: " .. original
  end
  local tags = {}
  for _, g in ipairs(m.genres or {}) do
    if type(g) == "string" then
      tags[#tags + 1] = g
    elseif type(g) == "table" and present(g.name) then
      tags[#tags + 1] = g.name
    end
  end
  return {
    title = m.title,
    title_romaji = original,
    author = present(m.author),
    description = description,
    tags = tags,
    cover_url = cover_of(m),
  }
end

function covers(id)
  local url = cover_of(fetch_manhwa(id))
  if not url then
    return {}
  end
  return { { url = url } }
end

--[[ ---------------------------------------------------------- chapters -- ]]

function chapters(manga_id)
  local m = fetch_manhwa(manga_id)
  local rows = {}
  for _, ch in ipairs(m.chapters or {}) do
    -- "Chapter 12", "Chapter 0.5"; announcements ("Notice.") have no number.
    local n = tonumber((tostring(ch.title or ""):match("(%d+%.?%d*)")))
    if n then
      rows[#rows + 1] = { n = n, id = id_string(ch.id), raw = ch.id }
    end
  end
  table.sort(rows, function(a, b)
    if a.n ~= b.n then
      return a.n < b.n
    end
    return a.raw < b.raw
  end)
  local out = {}
  for i, r in ipairs(rows) do
    out[i] = { number = number_string(r.n), id = r.id }
  end
  return out
end

function volumes(manga_id, language)
  return { { volume = "Unsorted", chapters = chapters(manga_id) } }
end

--[[ ---------------------------------------------------------- page_list -- ]]

function page_list(chapter_id)
  local data = api_get("/chapters/" .. urlencode(chapter_id) .. "/", true)
  if not data then
    error("Capítulo não encontrado.")
  end
  local out = {}
  for _, p in ipairs(data.pages or {}) do
    local img = p.images or {}
    local url = present(img.translated) or present(img.original)
    if url then
      out[#out + 1] = url
    end
  end
  if #out == 0 then
    error("Este capítulo não tem páginas disponíveis.")
  end
  return out
end
