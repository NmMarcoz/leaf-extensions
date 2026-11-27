-- Mango Toons (mangotoons.com) — Brazilian manhwa/manga site. Port of the
-- Keiyoushi `pt/mangotoons` extension. The site is a front end over a JSON API
-- (api.mangotoons.com/api/v1) and serves images from cdn.mangotoons.com.
--
-- Ids: a series is its numeric site id ("12151"); a chapter is
-- "<series id>/<chapter number>" (the manifest endpoint is keyed by number, so
-- the id carries both halves).
--
-- Page images answer 403 INVALID_ORIGIN without a Referer; Leaf's downloader
-- sends this source's base_url, which is enough.
--
-- The page manifest rate-limits (429) from about 12 requests a minute; the
-- Keiyoushi spaces them 5 s apart. Leaf has no sleep, so a 429 surfaces as an
-- error asking the reader to retry.
--
-- It also carries the catalogue shape (popular, latest, manga_details,
-- volumes) so the site is offered in Explore. Filters are not ported: the
-- Kotlin has none beyond the search text anyway, and Leaf has no slot for
-- them. Series status is not exposed by Leaf's details shape and is dropped.

SOURCE = {
  id = "user.mangotoons",
  name = "Mango Toons",
  kind = "reader",
  description = "Portuguese manhwa and manga from Mango Toons.",
  lang = "pt",
  base_url = "https://mangotoons.com",
  mirrors = { "https://api.mangotoons.com", "https://cdn.mangotoons.com" },
}

local API = "https://api.mangotoons.com/api/v1"
local CDN = "https://cdn.mangotoons.com"
local PAGE_LIMIT = 24

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
  if res.status == 429 then
    error("Muitas requisições ao Mango Toons; aguarde alguns segundos e tente de novo.")
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

-- Most covers are absolute CDN URLs, a few are paths on the site.
local function cover_url(obra)
  local img = present(obra.imagem)
  if not img then
    return nil
  end
  if img:sub(1, 1) == "/" then
    return SOURCE.base_url .. img
  end
  return img
end

--[[ ---------------------------------------------------------- catalogue -- ]]

local function list_obras(page, order, query)
  local path = string.format("/obras?pagina=%d&limite=%d", page, PAGE_LIMIT)
  if order then
    path = path .. "&ordenar=" .. order
  end
  query = (query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if query ~= "" then
    path = path .. "&busca=" .. urlencode(query)
  end
  local data = api_get(path)
  local out = {}
  for i, obra in ipairs(data.obras or {}) do
    out[i] = { id = number_string(obra.id), title = obra.nome, cover_url = cover_url(obra) }
  end
  local total = tonumber(data.total_paginas) or 0
  return { manga = out, has_next_page = (tonumber(data.pagina) or page) < total }
end

function popular(page)
  return list_obras(page, "populares")
end

function latest(page)
  return list_obras(page, "recentes")
end

function search(query, page)
  return list_obras(page, nil, query)
end

function manga_details(id)
  local obra = api_get("/obras/" .. urlencode(id))
  local tags = {}
  if present(obra.formato) then
    tags[#tags + 1] = obra.formato
  end
  for _, tag in ipairs(obra.tags or {}) do
    if present(tag) then
      tags[#tags + 1] = tag
    end
  end
  local author = present(obra.autor)
  if author == "Autor Desconhecido" then
    author = nil
  end
  local artist = present(obra.artista)
  if artist == "Arte" then
    artist = nil
  end
  return {
    title = obra.nome,
    author = author,
    artist = artist,
    description = present(obra.descricao) or "",
    tags = tags,
    cover_url = cover_url(obra),
  }
end

function covers(id)
  local url = cover_url(api_get("/obras/" .. urlencode(id)))
  if not url then
    return {}
  end
  return { { url = url } }
end

--[[ ---------------------------------------------------------- chapters -- ]]

function chapters(manga_id)
  local obra = api_get("/obras/" .. urlencode(manga_id))
  local rows = obra.capitulos or {}
  -- Newest first from the API; Leaf wants oldest first. VIP chapters are
  -- skipped: they cannot be read anonymously.
  local out = {}
  for i = #rows, 1, -1 do
    local row = rows[i]
    local number = number_string(row.numero) or present(row.numero)
    if number and not row.is_vip then
      out[#out + 1] = { number = number, id = manga_id .. "/" .. number }
    end
  end
  table.sort(out, function(a, b)
    local x, y = tonumber(a.number), tonumber(b.number)
    if x and y and x ~= y then
      return x < y
    end
    return false
  end)
  return out
end

-- One flat list: the site has no volumes.
function volumes(manga_id, language)
  return { { volume = "Unsorted", chapters = chapters(manga_id) } }
end

--[[ ---------------------------------------------------------- page_list -- ]]

function page_list(chapter_id)
  local manga_id, number = chapter_id:match("^([^/]+)/(.+)$")
  if not manga_id then
    error("Identificador de capítulo inválido: " .. tostring(chapter_id))
  end
  local data = api_get("/leitor/obras/" .. urlencode(manga_id) .. "/capitulos/" .. urlencode(number) .. "/manifest")
  local pages = data.pages or {}
  if #pages == 0 then
    error("Este capítulo não está disponível para leitura.")
  end
  table.sort(pages, function(a, b)
    return (tonumber(a.index) or 0) < (tonumber(b.index) or 0)
  end)
  local out = {}
  for i, p in ipairs(pages) do
    local url = p.url
    if type(url) == "string" and url:sub(1, 1) == "/" then
      url = CDN .. url
    end
    out[i] = url
  end
  return out
end
