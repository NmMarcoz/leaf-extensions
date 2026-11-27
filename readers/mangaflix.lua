-- MangaFlix (mangaflix.net) — Brazilian manga/manhwa/manhua reader. Port of the
-- Keiyoushi `pt/mangaflix` extension. The site is a front end over a JSON API at
-- api.mangaflix.net/v1; images are served from static.mangaflix.net.
--
-- Ids: a series is its API id (24 hex chars); a chapter is its API id too (the
-- chapter list returns it, so page_list needs no lookup).
--
-- Not ported: the genre filter (Leaf scripts have no filter hook). The API
-- pages nothing for browse/latest/search, so popular ("Mais Lidos", 30 titles)
-- and latest are one page each and search returns one page of matches;
-- has_next_page is always false and later pages are empty.

SOURCE = {
  id = "user.mangaflix",
  name = "MangaFlix",
  kind = "reader",
  description = "Portuguese manga, manhwa and manhua from MangaFlix.",
  lang = "pt",
  base_url = "https://mangaflix.net",
  mirrors = { "https://api.mangaflix.net", "https://static.mangaflix.net" },
}

local API = "https://api.mangaflix.net/v1"
local LANG = "selected_language=pt-br"

local function urlencode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function api_get(path)
  local res = leaf.http.get(API .. path, {
    headers = { Accept = "application/json" },
    referer = "https://mangaflix.net/",
  })
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

local function cover_of(item)
  return type(item.poster) == "table" and present(item.poster.default_url) or nil
end

-- Chapter numbers arrive as strings ("7", "10.5", sometimes "7.0").
local function number_string(n)
  local v = tonumber(n)
  if not v then
    return present(n)
  end
  if v == math.floor(v) then
    return string.format("%d", v)
  end
  return tostring(v)
end

--[[ ---------------------------------------------------------- catalogue -- ]]

local function to_page(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    if item._id and item.name then
      out[#out + 1] = { id = item._id, title = item.name, cover_url = cover_of(item) }
    end
  end
  return { manga = out, has_next_page = false }
end

function popular(page)
  if page > 1 then
    return { manga = {}, has_next_page = false }
  end
  local data = api_get("/browse").data or {}
  for _, section in ipairs(data) do
    if section.key == "most-read" then
      return to_page(section.items)
    end
  end
  return { manga = {}, has_next_page = false }
end

function latest(page)
  if page > 1 then
    return { manga = {}, has_next_page = false }
  end
  return to_page(api_get("/latest-releases?" .. LANG).data)
end

function search(query, page)
  if page > 1 then
    return { manga = {}, has_next_page = false }
  end
  query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then
    return latest(page)
  end
  local data = api_get("/search/mangas?query=" .. urlencode(query) .. "&" .. LANG).data or {}
  return to_page(data.works)
end

local function details_raw(id)
  local data = api_get("/mangas/" .. urlencode(id)).data
  if type(data) ~= "table" then
    error("Obra não encontrada")
  end
  return data
end

function manga_details(id)
  local m = details_raw(id)
  local tags = {}
  for _, g in ipairs(m.genres or {}) do
    if present(g.name) then
      tags[#tags + 1] = g.name
    end
  end
  local author
  local first = (m.chapters or {})[1]
  if first and type(first.owners) == "table" and first.owners[1] then
    author = present(first.owners[1].name)
  end
  return {
    title = m.name,
    author = author,
    description = m.description or "",
    tags = tags,
    cover_url = cover_of(m),
  }
end

function covers(id)
  local url = cover_of(details_raw(id))
  if not url then
    return {}
  end
  return { { url = url } }
end

--[[ ---------------------------------------------------------- chapters -- ]]

function chapters(manga_id)
  local rows = details_raw(manga_id).chapters or {}
  -- Newest first from the API; Leaf wants oldest first.
  local out = {}
  for i = #rows, 1, -1 do
    local row = rows[i]
    if row._id then
      out[#out + 1] = { number = number_string(row.number) or "0", id = row._id }
    end
  end
  return out
end

-- One flat list: the site has no volumes.
function volumes(manga_id, language)
  return { { volume = "Unsorted", chapters = chapters(manga_id) } }
end

--[[ ---------------------------------------------------------- page_list -- ]]

function page_list(chapter_id)
  local data = api_get("/chapters/" .. urlencode(chapter_id) .. "?" .. LANG).data
  local out = {}
  if type(data) == "table" then
    for _, image in ipairs(data.images or {}) do
      if present(image.default_url) then
        out[#out + 1] = image.default_url
      end
    end
  end
  if #out == 0 then
    error("Este capítulo não está disponível para leitura.")
  end
  return out
end
