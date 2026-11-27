-- Drope Scan (beta.dropescan.com) — Brazilian Portuguese scanlation site. Port
-- of the Keiyoushi `pt/dropescan` extension. The site is a Next.js front end
-- over a JSON API (api.dropescan.com/v1); images live on bucket-1.dropescan.com.
--
-- Ids: a series is its ObraId (uuid); a chapter is its ChapterId (uuid), which
-- is all /chapter/<id> needs.
--
-- The API has no single-series endpoint (GET /obras/<id> is a 404) and the
-- Keiyoushi source reads details out of the Next.js page, but that page embeds
-- every chapter and takes 30+ s to render. manga_details/covers instead walk
-- /obras (100 per page, stable order, ~2 s each) until they find the id.
--
-- Chapters come back in string order ("1","10","100","2"...) so they are sorted
-- numerically here. When several groups released the same number, every
-- release is kept (same number, different id), as in the Keiyoushi source.
--
-- Carries the catalogue shape (popular, latest, search, manga_details,
-- volumes, covers) so the site shows in Discover. Not ported: the filters
-- (sort, status, demographic, content rating/warning, language, year, tag
-- groups): Leaf scripts have no filter hook.

SOURCE = {
  id = "user.dropescan",
  name = "Drope Scan",
  kind = "reader",
  description = "Mangás, manhwas e webcomics em português do Drope Scan.",
  lang = "pt",
  base_url = "https://beta.dropescan.com",
  mirrors = { "https://api.dropescan.com", "https://bucket-1.dropescan.com" },
}

local API = "https://api.dropescan.com/v1"
local CDN = "https://bucket-1.dropescan.com/"
local PAGE_SIZE = 20
local SCAN_SIZE = 100 -- the API's maximum

local function urlencode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function api_get(path)
  local res = leaf.http.get(API .. path, {
    headers = { Accept = "application/json" },
    referer = SOURCE.base_url .. "/",
  })
  if res.status ~= 200 then
    error(string.format("%s answered %d", path:gsub("%?.*$", ""), res.status))
  end
  return leaf.json.decode(res.body)
end

local function present(v)
  if type(v) ~= "string" or v == "" then
    return nil
  end
  return v
end

-- JSON numbers arrive as floats: 113 → "113", 10.5 stays "10.5".
local function number_string(n)
  n = tonumber(n)
  if not n then
    return nil
  end
  if n == math.floor(n) then
    return tostring(math.floor(n))
  end
  return tostring(n)
end

local function image_url(path)
  path = present(path)
  if not path then
    return nil
  end
  if path:sub(1, 4) == "http" then
    return path
  end
  return CDN .. path:gsub("^/", "")
end

-- Banners use capitalised keys (Variants/SourceHigh/Source), chapter pages
-- lowercase ones (variants/sourceHigh/source).
local function high_path(item)
  local v = item.Variants or item.variants
  if type(v) == "table" and type(v.high) == "table" and present(v.high.source) then
    return v.high.source
  end
  return present(item.SourceHigh) or present(item.sourceHigh) or present(item.Source) or present(item.source)
end

local function cover_of(obra)
  local banners = obra.Banners
  if type(banners) ~= "table" then
    return nil
  end
  local chosen = banners[1]
  for _, b in ipairs(banners) do
    if b.isPrimary then
      chosen = b
      break
    end
  end
  return chosen and image_url(high_path(chosen)) or nil
end

--[[ ---------------------------------------------------------- catalogue -- ]]

local function to_entries(rows)
  local out, seen = {}, {}
  for _, obra in ipairs(rows) do
    if obra.ObraId and not seen[obra.ObraId] then
      seen[obra.ObraId] = true
      out[#out + 1] = { id = obra.ObraId, title = obra.Title, cover_url = cover_of(obra) }
    end
  end
  return out
end

local function list_obras(page, query)
  page = tonumber(page) or 1
  local path = string.format("/obras?limit=%d&offset=%d", PAGE_SIZE, (page - 1) * PAGE_SIZE)
  query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if query ~= "" then
    path = path .. "&query=" .. urlencode(query)
  end
  local data = api_get(path)
  local rows = data.data or {}
  local meta = data.meta or {}
  local offset = tonumber(meta.offset) or ((page - 1) * PAGE_SIZE)
  local total = tonumber(meta.total) or 0
  return { manga = to_entries(rows), has_next_page = offset + #rows < total }
end

function popular(page)
  return list_obras(page)
end

function search(query, page)
  return list_obras(page, query)
end

function latest(page)
  page = tonumber(page) or 1
  local data = api_get("/chapters/recent?page=" .. page)
  local body = data.data or {}
  local meta = body.meta or {}
  return {
    manga = to_entries(body.data or {}),
    has_next_page = (tonumber(meta.CurrentPage) or page) < (tonumber(meta.LastPage) or page),
  }
end

-- Walk the catalogue until the series turns up.
local function find_obra(id)
  local offset = 0
  for _ = 1, 10 do
    local data = api_get(string.format("/obras?limit=%d&offset=%d", SCAN_SIZE, offset))
    local rows = data.data or {}
    for _, obra in ipairs(rows) do
      if obra.ObraId == id then
        return obra
      end
    end
    offset = offset + #rows
    if #rows == 0 or offset >= (tonumber(data.meta and data.meta.total) or 0) then
      break
    end
  end
  error("Obra não encontrada")
end

local function names(list, key)
  local out = {}
  for _, item in ipairs(type(list) == "table" and list or {}) do
    if present(item[key]) then
      out[#out + 1] = item[key]
    end
  end
  return out
end

function manga_details(id)
  local obra = find_obra(id)

  local tags, seen = {}, {}
  for _, group in ipairs({
    names(obra.Formats, "FormatName"),
    names(obra.Genres, "GenreName"),
    names(obra.Themes, "ThemeName"),
  }) do
    for _, tag in ipairs(group) do
      if not seen[tag] then
        seen[tag] = true
        tags[#tags + 1] = tag
      end
    end
  end

  local description = present(obra.Synopsis) or ""
  local info = {}
  if obra.PublicationYear then
    info[#info + 1] = number_string(obra.PublicationYear)
  end
  if present(obra.DemographicTarget) and obra.DemographicTarget ~= "Not Applicable" then
    info[#info + 1] = obra.DemographicTarget
  end
  if #info > 0 then
    description = table.concat(info, " · ") .. "\n\n" .. description
  end
  local alts = {}
  for _, t in ipairs(type(obra.OtherTitles) == "table" and obra.OtherTitles or {}) do
    local name = present(t.title) or present(t.Title)
    if name then
      alts[#alts + 1] = name
    end
  end
  if #alts > 0 then
    description = description .. "\n\nTítulos alternativos: " .. table.concat(alts, ", ")
  end

  local authors = table.concat(names(obra.Authors, "AuthorName"), ", ")
  local artists = table.concat(names(obra.Artists, "ArtistName"), ", ")

  return {
    title = obra.Title,
    title_romaji = alts[1],
    author = present(authors),
    artist = present(artists),
    description = description,
    tags = tags,
    cover_url = cover_of(obra),
  }
end

function covers(id)
  local obra = find_obra(id)
  local out, seen = {}, {}
  for _, b in ipairs(type(obra.Banners) == "table" and obra.Banners or {}) do
    local url = image_url(high_path(b))
    if url and not seen[url] then
      seen[url] = true
      out[#out + 1] = { url = url }
    end
  end
  return out
end

--[[ ---------------------------------------------------------- chapters -- ]]

function chapters(manga_id)
  local data = api_get("/obras/" .. urlencode(manga_id) .. "/chapters")
  local rows = (data.data and data.data.chapters) or {}

  local items = {}
  for i, row in ipairs(rows) do
    if row.ChapterId then
      local n = tonumber(row.ChapterNumber)
      items[#items + 1] = {
        n = n or -1,
        i = i,
        number = number_string(n) or present(row.ChapterNumber) or "0",
        id = row.ChapterId,
      }
    end
  end
  -- Oldest first; table.sort is not stable, so ties fall back to API order.
  table.sort(items, function(a, b)
    if a.n ~= b.n then
      return a.n < b.n
    end
    return a.i < b.i
  end)

  local out = {}
  for i, it in ipairs(items) do
    out[i] = { number = it.number, id = it.id }
  end
  return out
end

-- One flat list: the site has no volumes worth exposing.
function volumes(manga_id, language)
  return { { volume = "Unsorted", chapters = chapters(manga_id) } }
end

--[[ ---------------------------------------------------------- page_list -- ]]

function page_list(chapter_id)
  local data = api_get("/chapter/" .. urlencode(chapter_id))
  local chapter = data.data and data.data.chapter
  if not chapter then
    error("Capítulo não encontrado.")
  end
  local status = chapter.ChapterStatus
  if present(status) and status ~= "published" then
    error("Este capítulo ainda não está disponível para leitura.")
  end
  local out = {}
  for _, page in ipairs(chapter.ChapterContent or {}) do
    local url = image_url(high_path(page))
    if url then
      out[#out + 1] = url
    end
  end
  if #out == 0 then
    error("Este capítulo não tem páginas disponíveis.")
  end
  return out
end
