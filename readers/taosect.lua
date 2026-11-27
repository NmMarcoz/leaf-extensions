-- Tao Sect (taosect.com) — Brazilian scanlation group. Port of the Keiyoushi
-- `pt/taosect` extension. The site is WordPress with custom REST routes
-- under /wp-json/wp/v2: `projetos` are series, `capitulos` are chapters.
-- Page images are Google Drive thumbnails listed by the chapter endpoint.
--
-- Ids: a series is its project slug ("one-punch-man"); a chapter is
-- "<project slug>/<chapter slug>", because the chapter route needs both.
--
-- It also carries the whole catalogue shape (popular, latest, manga_details,
-- volumes) so the site is offered in Explore. Filters are not ported: Leaf has
-- no slot for them.
--
-- Not ported: the Kotlin posts a view counter to admin-ajax.php for the
-- scanlator; leaf.http.post only sends JSON, so that call is left out.

SOURCE = {
  id = "user.taosect",
  name = "Tao Sect",
  kind = "reader",
  description = "Portuguese scanlations from Tao Sect (pages are hosted on Google Drive).",
  lang = "pt",
  base_url = "https://taosect.com",
  -- Page images are Google Drive thumbnails, which redirect to googleusercontent.
  mirrors = { "https://drive.google.com", "https://lh3.googleusercontent.com" },
}

local API = SOURCE.base_url .. "/wp-json/wp/v2"
local PER_PAGE = 18

local DRIVE_LIMIT = "Limite de visualizações atingido no Google Drive. Tente novamente mais tarde."
local DRIVE_DOWN = "O Google Drive está indisponível no momento. Tente novamente mais tarde."

local function urlencode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function api_get(path, params)
  local parts = {}
  for _, kv in ipairs(params) do
    parts[#parts + 1] = kv[1] .. "=" .. urlencode(kv[2])
  end
  local res = leaf.http.get(API .. path .. "?" .. table.concat(parts, "&"), {
    headers = { Accept = "application/json" },
  })
  if res.status ~= 200 then
    error(string.format("%s answered %d", path, res.status))
  end
  return leaf.json.decode(res.body)
end

-- WordPress titles come back HTML-escaped (`&#8211;`, `&amp;`).
local NAMED = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
local function unescape(s)
  s = s or ""
  s = s:gsub("&#(%d+);", function(n) return utf8.char(tonumber(n)) end)
  s = s:gsub("&#[xX](%x+);", function(n) return utf8.char(tonumber(n, 16)) end)
  s = s:gsub("&(%a+);", function(name) return NAMED[name] end)
  return s
end

--[[ ---------------------------------------------------------- catalogue -- ]]

local LIST_FIELDS = "title,thumbnail,link,slug"

local function to_page(rows)
  local out = {}
  for i, row in ipairs(rows) do
    local cover = row.thumbnail
    if cover == "" then
      cover = nil
    end
    out[i] = {
      id = row.slug,
      title = unescape(row.title and row.title.rendered),
      cover_url = cover,
    }
  end
  -- The Kotlin reads X-WP-TotalPages; leaf.http exposes no headers, so a
  -- full page is the signal there may be another.
  return { manga = out, has_next_page = #rows >= PER_PAGE }
end

function search(query, page)
  local params = {
    { "page", page },
    { "per_page", PER_PAGE },
    { "_fields", LIST_FIELDS },
  }
  if query and query ~= "" then
    table.insert(params, { "search", query })
  end
  return to_page(api_get("/projetos", params))
end

function popular(page)
  return to_page(api_get("/projetos", {
    { "order", "desc" },
    { "orderby", "views" },
    { "page", page },
    { "per_page", PER_PAGE },
    { "_fields", LIST_FIELDS },
  }))
end

-- Newest chapters first, folded into the series they belong to. One chapter
-- page maps to one list page, so a series with a burst of releases can appear
-- again on the next page (the Kotlin kept state between pages to dedupe).
local LATEST_CHAPTERS = 100

function latest(page)
  local chapter_rows = api_get("/capitulos", {
    { "order", "desc" },
    { "orderby", "date" },
    { "page", page },
    { "per_page", LATEST_CHAPTERS },
    { "_fields", "post_id" },
  })

  local ids, seen = {}, {}
  for _, row in ipairs(chapter_rows) do
    if row.post_id and not seen[row.post_id] then
      seen[row.post_id] = true
      ids[#ids + 1] = row.post_id
    end
  end
  if #ids == 0 then
    return { manga = {}, has_next_page = false }
  end

  local result = to_page(api_get("/projetos", {
    { "include", table.concat(ids, ",") },
    { "per_page", #ids },
    { "orderby", "include" },
    { "_fields", LIST_FIELDS },
  }))
  result.has_next_page = #chapter_rows >= LATEST_CHAPTERS
  return result
end

local function strip_html(html)
  html = (html or ""):gsub("<[^>]*>", " ")
  return (unescape(html):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

function manga_details(id)
  local rows = api_get("/projetos", {
    { "per_page", 1 },
    { "slug", id },
    { "_fields", "title,informacoes,content,thumbnail,link" },
  })
  local project = rows[1]
  if not project then
    error("Projeto não encontrado.")
  end
  local info = project.informacoes or {}

  local tags = {}
  for _, genre in ipairs(info.generos or {}) do
    if genre.nome and genre.nome ~= "" then
      tags[#tags + 1] = genre.nome
    end
  end

  local description = strip_html(project.content and project.content.rendered)
  if info.titulo_pais_origem and info.titulo_pais_origem ~= "" then
    description = description .. "\n\nTítulo original: " .. info.titulo_pais_origem
  end
  if info.serializacao and info.serializacao ~= "" then
    description = description .. "\nSerialização: " .. info.serializacao
  end

  local function present(v)
    if v == nil or v == "" then
      return nil
    end
    return v
  end

  return {
    title = unescape(project.title and project.title.rendered),
    author = present(info.roteiro),
    artist = present(info.arte),
    description = description,
    tags = tags,
    cover_url = present(project.thumbnail),
  }
end

--[[ ---------------------------------------------------------- chapters -- ]]

-- "Capítulo 10.5" → "10.5". Names with no number ("Extra") are kept whole so
-- the row is not lost.
local function chapter_number(name)
  local n = (name or ""):match("%d+[%.,]%d+") or (name or ""):match("%d+")
  if n then
    return (n:gsub(",", "."))
  end
  return unescape(name)
end

function chapters(manga_id)
  local rows = api_get("/capitulos", {
    { "projeto", manga_id },
    { "per_page", 1000 },
    { "order", "desc" },
    { "orderby", "sequencia" },
    { "_fields", "nome_capitulo,post_id,slug,data_insercao" },
  })
  if #rows == 0 then
    error("Capítulos não encontrados.")
  end

  -- The API answers newest first; Leaf wants oldest first.
  local out = {}
  for i = #rows, 1, -1 do
    local row = rows[i]
    out[#out + 1] = {
      number = chapter_number(row.nome_capitulo),
      id = manga_id .. "/" .. row.slug,
    }
  end
  return out
end

function covers(id)
  local cover = manga_details(id).cover_url
  if not cover then
    return {}
  end
  return { { url = cover } }
end

-- One flat list: the site has no volumes.
function volumes(manga_id, language)
  return { { volume = "Unsorted", chapters = chapters(manga_id) } }
end

--[[ ---------------------------------------------------------- page_list -- ]]

function page_list(chapter_id)
  local project, chapter = chapter_id:match("^([^/]+)/([^/]+)$")
  if not project then
    error("invalid chapter id: " .. chapter_id)
  end

  local data = api_get("/capitulos/" .. urlencode(project) .. "/" .. urlencode(chapter), {
    { "_fields", "id_capitulo,paginas,post_id" },
  })
  local pages = data.paginas or {}
  if #pages == 0 then
    return {}
  end

  -- Google Drive stops serving a file once it passes its daily view quota,
  -- answering with an HTML page or a 403. Probe the first image so the reader
  -- shows a real message instead of a chapter of broken pages. A failed probe
  -- (network, redirect outside the declared origins) is not proof of anything.
  local referer = string.format("%s/leitor-online/projeto/%s/%s", SOURCE.base_url, project, chapter)
  local ok, res = pcall(leaf.http.get, pages[1], { referer = referer })
  if ok and res then
    local html = (res.body or ""):sub(1, 15):lower():find("^%s*<") ~= nil
    if res.status == 403 or res.status == 429 then
      error(DRIVE_LIMIT)
    elseif res.status ~= 200 or html then
      error(DRIVE_DOWN)
    end
  end

  return pages
end
