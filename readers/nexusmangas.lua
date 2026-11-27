-- Nexus Mangás (nexusmangas.com) — Brazilian manhwa/manga/manhua site. Port of
-- the Keiyoushi `pt/nexusmangas` extension. The site is a front end over a
-- Supabase backend (PostgREST at /rest/v1, an edge function for pages), and
-- images live on assets.nexusmangas.com.
--
-- Ids: a series is its slug; a chapter is its uuid (the chapter list returns
-- it, so page_list needs no lookup, unlike the Kotlin's number-based URLs).
--
-- The backend wants the site's public anonymous API key on every request. It
-- is the same key the web app ships to every browser (and the Keiyoushi
-- source embeds); if the site rotates it, update ANON_KEY below.
--
-- It also carries the catalogue shape (popular, latest, manga_details,
-- volumes) so the site is offered in Explore. Filters (type, status,
-- demographic, genre) are not ported: Leaf has no slot for them.

SOURCE = {
  id = "user.nexusmangas",
  name = "Nexus Mangás",
  kind = "reader",
  description = "Portuguese manhwa, manga and manhua from Nexus Mangás.",
  lang = "pt",
  base_url = "https://www.nexusmangas.com",
  mirrors = { "https://supabase.nexusmangas.com", "https://assets.nexusmangas.com" },
}

local API = "https://supabase.nexusmangas.com/rest/v1"
local FUNCTIONS = "https://supabase.nexusmangas.com/functions/v1"
local ASSETS = "https://assets.nexusmangas.com/"

local ANON_KEY = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJzdXBhYmFzZSIsImlhdCI6MTc4NzgwMjAwMCwiZXhwIjo0OTQzNDc1NjAwLCJyb2xlIjoiYW5vbiJ9.Cnl8Jw2DeKe84OAkmJYfO33xlcZsw0TC2Nw_il0tpRs"

local PAGE_SIZE = 30
local CHAPTER_PAGE_SIZE = 1000
local LIST_COLUMNS = "slug,title,cover_url,status,type"
local DETAIL_COLUMNS = "slug,title,description,cover_url,alternative_title,status,type,author,artist,"
    .. "demographic,scan:scans(name),work_genres(genres(name))"

local function urlencode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function auth_headers(extra)
  local headers = {
    apikey = ANON_KEY,
    Authorization = "Bearer " .. ANON_KEY,
    Accept = "application/json",
  }
  for k, v in pairs(extra or {}) do
    headers[k] = v
  end
  return headers
end

local function rest_get(path, params)
  local parts = {}
  for _, kv in ipairs(params) do
    parts[#parts + 1] = kv[1] .. "=" .. urlencode(kv[2])
  end
  local res = leaf.http.get(API .. path .. "?" .. table.concat(parts, "&"), {
    headers = auth_headers(),
  })
  if res.status ~= 200 then
    error(string.format("%s answered %d", path, res.status))
  end
  return leaf.json.decode(res.body)
end

local function present(v)
  if v == nil or v == "" or type(v) ~= "string" then
    return nil
  end
  return v
end

-- Covers are keys into the public bucket; the site's own media route just
-- redirects there, so go straight to it.
local function cover_url(row)
  local key = present(row.cover_url)
  if not key then
    return nil
  end
  return ASSETS .. key
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

--[[ ---------------------------------------------------------- catalogue -- ]]

local function to_page(rows)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = { id = row.slug, title = row.title, cover_url = cover_url(row) }
  end
  return { manga = out, has_next_page = #rows >= PAGE_SIZE }
end

local function list_works(page, order, query)
  local params = {
    { "select", LIST_COLUMNS },
    { "order", order .. ",id.desc" },
    { "limit", PAGE_SIZE },
    { "offset", (page - 1) * PAGE_SIZE },
    -- Light novels are text, not pages.
    { "type", "neq.NOVEL" },
  }
  query = (query or ""):gsub("[%*%%]", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if query ~= "" then
    -- Quoted so commas and parentheses in a title cannot end the filter early.
    local term = '"*' .. query:gsub("\\", "\\\\"):gsub('"', '\\"') .. '*"'
    table.insert(params, { "or", "(title.ilike." .. term .. ",alternative_title.ilike." .. term .. ")" })
  end
  return to_page(rest_get("/works", params))
end

function popular(page)
  return list_works(page, "avg_rating.desc.nullslast")
end

function latest(page)
  return list_works(page, "updated_at.desc")
end

function search(query, page)
  return list_works(page, "avg_rating.desc.nullslast", query)
end

-- Only for the ASCII enums (type, demographic: "MANHWA", "SLICE_OF_LIFE");
-- genre names are already proper-cased, and Lua's lower/upper would mangle
-- their accents.
local function humanize(value)
  return (value:gsub("_", " "):lower():gsub("(%a)([%w]*)", function(a, b)
    return a:upper() .. b
  end))
end

function manga_details(id)
  local rows = rest_get("/works", {
    { "select", DETAIL_COLUMNS },
    { "slug", "eq." .. id },
    { "limit", 1 },
  })
  local work = rows[1]
  if not work then
    error("Obra não encontrada")
  end

  local tags, seen = {}, {}
  local function add(tag, enum)
    if tag and tag ~= "" then
      if enum then
        tag = humanize(tag)
      end
      if not seen[tag] then
        seen[tag] = true
        tags[#tags + 1] = tag
      end
    end
  end
  add(work.type, true)
  if work.demographic ~= "NONE" then
    add(work.demographic, true)
  end
  for _, wg in ipairs(work.work_genres or {}) do
    if wg.genres then
      add(wg.genres.name)
    end
  end

  local description = work.description or ""
  local alt = present(work.alternative_title)
  if alt then
    description = description .. "\n\nTítulo alternativo: " .. alt
  end
  local scan = type(work.scan) == "table" and present(work.scan.name) or nil
  if scan then
    description = description .. "\nScan: " .. scan
  end

  return {
    title = work.title,
    title_romaji = alt,
    author = present(work.author),
    artist = present(work.artist),
    description = description,
    tags = tags,
    cover_url = cover_url(work),
  }
end

function covers(id)
  local rows = rest_get("/works", { { "select", "cover_url" }, { "slug", "eq." .. id }, { "limit", 1 } })
  local url = rows[1] and cover_url(rows[1])
  if not url then
    return {}
  end
  return { { url = url } }
end

--[[ ---------------------------------------------------------- chapters -- ]]

function chapters(manga_id)
  local rows = {}
  for _ = 1, 20 do
    local batch = rest_get("/chapters", {
      { "select", "id,number,chapter_label,title,published_at,works!work_id!inner()" },
      { "works.slug", "eq." .. manga_id },
      { "order", "sort_order.desc,id.desc" },
      { "limit", CHAPTER_PAGE_SIZE },
      { "offset", #rows },
    })
    for _, row in ipairs(batch) do
      rows[#rows + 1] = row
    end
    if #batch < CHAPTER_PAGE_SIZE then
      break
    end
  end

  -- Newest first from the API; Leaf wants oldest first. A chapter with no
  -- number keeps its label ("Extra", "Oneshot") so it is not lost.
  local out = {}
  for i = #rows, 1, -1 do
    local row = rows[i]
    out[#out + 1] = {
      number = number_string(row.number) or present(row.chapter_label) or "0",
      id = row.id,
    }
  end
  return out
end

-- One flat list: the site has no volumes.
function volumes(manga_id, language)
  return { { volume = "Unsorted", chapters = chapters(manga_id) } }
end

--[[ ---------------------------------------------------------- page_list -- ]]

function page_list(chapter_id)
  local res = leaf.http.post(FUNCTIONS .. "/read-chapter", leaf.json.encode({ chapterId = chapter_id }), {
    headers = auth_headers({ ["x-nexus-client"] = "reader-v3" }),
  })
  if res.status ~= 200 then
    error(string.format("read-chapter answered %d", res.status))
  end
  local data = leaf.json.decode(res.body)
  if not (data.access and data.access.allowed) then
    error("Este capítulo não está disponível para leitura.")
  end
  local pages = data.chapter and data.chapter.pages or {}
  local out = {}
  for i, url in ipairs(pages) do
    out[i] = url
  end
  return out
end
