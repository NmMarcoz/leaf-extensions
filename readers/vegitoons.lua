-- Vegitoons (vegitoons.black) — another site on the "GreenShit" platform
-- (see verdinha.lua / maidscan.lua). Same API shape, hosted on its own
-- domain: api.vegitoons.black for JSON (scoped by a `scan-id: 1` header) and
-- cdn.vegitoons.black for images. No bot gate, no auth for public chapters.

SOURCE = {
  id = "user.vegitoons",
  name = "Vegitoons",
  kind = "reader",
  description = "Portuguese scanlations from Vegitoons (GreenShit platform).",
  lang = "pt",
  base_url = "https://vegitoons.black",
  mirrors = { "https://api.vegitoons.black", "https://cdn.vegitoons.black" },
}

local API_URL = "https://api.vegitoons.black"
local CDN_URL = "https://cdn.vegitoons.black"

-- The multisrc's identity: every API call carries the scan group's number,
-- and the ranking differs depending on it.
local SCAN_ID = "1"

-- One page of listings, like the Kotlin's limitPerPage.
local PAGE_SIZE = 26

-- `leaf.json` hands every JSON number back as a Lua float (`10714` →
-- `10714.0`), so any id or path component that was numeric in JSON needs a
-- floor before it can be stringified.
local function id_string(n)
  return tostring(math.floor(tonumber(n) or 0))
end

-- Chapter numbers, same float problem, but fractional ones (1.5) must stay
-- fractional: drop the trailing `.0` only when the value is whole.
local function number_string(n)
  n = tonumber(n)
  if not n then
    return "0"
  end
  if n == math.floor(n) then
    return tostring(math.floor(n))
  end
  return tostring(n)
end

local function api_get(path, params)
  local url = API_URL .. path
  if params and #params > 0 then
    local parts = {}
    for _, kv in ipairs(params) do
      parts[#parts + 1] = kv[1] .. "="
          .. (tostring(kv[2]):gsub("([^%w%-_%.~])", function(c)
               return string.format("%%%02X", string.byte(c))
             end))
    end
    url = url .. "?" .. table.concat(parts, "&")
  end
  local res = leaf.http.get(url, { headers = { ["scan-id"] = SCAN_ID } })
  if res.status ~= 200 then
    error(string.format("%s answered %d", path, res.status))
  end
  return leaf.json.decode(res.body)
end

--[[ --------------------------------------------------------- images -- ]]

-- Covers go through the API's own resizing endpoint (that is what
-- `cdnApiUrl` is: `api…/cdn/<path>?width=…`); pages come straight off the
-- CDN. A blank src means the site has no cover, and the callers must not
-- hand out a half-built URL for it.
local function cover_url(row)
  if not row.obr_imagem or row.obr_imagem == "" then
    return nil
  end
  return string.format(
    "%s/cdn/scans/%s/obras/%s/%s?width=300",
    API_URL, id_string(row.scan_id or SCAN_ID), id_string(row.obr_id), row.obr_imagem)
end

--[[ -------------------------------------------------------- catalogue -- ]]

-- The list endpoints say how many pages exist, not whether the next one has
-- rows; the Kotlin compares totalPaginas against the current page, which is
-- what `pagina_atual`-style fields were for.
local function to_page(data)
  local manga = {}
  for i, row in ipairs(data.obras or {}) do
    manga[i] = { id = id_string(row.obr_id), title = row.obr_nome, cover_url = cover_url(row) }
  end
  local page = tonumber(data.pagina or data.currentPage) or 1
  return { manga = manga, has_next_page = (tonumber(data.totalPaginas) or 0) > page }
end

function popular(page)
  return to_page(api_get("/obras/ranking", {
    { "tipo", "visualizacoes_geral" },
    { "limite", PAGE_SIZE },
    { "pagina", page },
    -- defaultGenreId from the GreenShit multisrc (MaidScan overrides it to 4); the endpoint requires a
    -- gen_id to answer at all.
    { "gen_id", "1" },
  }))
end

function latest(page)
  return to_page(api_get("/obras/atualizacoes", {
    { "pagina", page },
    { "limite", PAGE_SIZE },
    { "gen_id", "1" },
  }))
end

function search(query, page)
  return to_page(api_get("/obras/buscar", {
    { "limite", PAGE_SIZE },
    { "pagina", page },
    query ~= "" and { "obr_nome", query } or nil,
    -- Without this the endpoint filters to genre 4 the way browse does;
    -- a search should see the whole catalogue (the Kotlin sets the same
    -- flag when no genre filter is ticked).
    { "todos_generos", "1" },
  }))
end

--[[ ----------------------------------------------------- detail page -- ]]

local function fetch_manga(id)
  return api_get("/obras/" .. id)
end

function manga_details(id)
  local book = fetch_manga(id)
  -- `obr_descricao` arrives as HTML the site renders with <br> and such;
  -- leaf.html has no plain-text mode, and the library shows the string as
  -- text anyway, so tags are stripped by hand.
  local description = book.obr_descricao
  if description then
    description = description:gsub("</?[%w][^>]*>", " "):gsub("%s+", " ")
  end

  local tags = {}
  if book.genero and book.genero.gen_nome then
    tags[#tags + 1] = book.genero.gen_nome
  end
  for _, tag in ipairs(book.tags or {}) do
    if tag.tag_nome and tag.tag_nome ~= "" then
      tags[#tags + 1] = tag.tag_nome
    end
  end

  return {
    title = book.obr_nome,
    -- "A Princess Who Reads Fortune" style — the source language name, which
    -- the metadata tiers match on better than the PT title.
    title_romaji = (book.obr_outros_nomes ~= nil and book.obr_outros_nomes ~= "")
        and book.obr_outros_nomes or nil,
    description = description,
    tags = tags,
    cover_url = cover_url(book),
  }
end

--[[ -------------------------------------------------------- chapters -- ]]

-- One flat chapter list, no volume concept: "Unsorted" like the other sites.
local UNSORTED = "Unsorted"

function volumes(id, language)
  local book = fetch_manga(id)
  local chapters = {}
  for _, row in ipairs(book.capitulos or {}) do
    -- A `cap_liberado: false` chapter has an unlock time and 403s without a
    -- logged-in VIP token — the library can't read it, so say so rather
    -- than hand out a chapter that only fails at download.
    if row.cap_liberado ~= false then
      chapters[#chapters + 1] = {
        number = number_string(row.cap_numero),
        -- cap_id is globally unique, so page_list needs nothing else.
        id = id_string(row.cap_id),
        unavailable = false,
      }
    end
  end
  return { { volume = UNSORTED, chapters = chapters } }
end

function covers(id)
  local book = fetch_manga(id)
  local url = cover_url(book)
  if not url then
    return {}
  end
  return { { url = url } }
end

--[[ -------------------------------------------------------- page_list -- ]]

function page_list(chapter_id)
  local data = api_get("/capitulos/" .. chapter_id)
  local obra = data.obra or {}
  local obra_id = obra.obr_id or data.obr_id

  local urls = {}
  local n = 0
  for _, pic in ipairs(data.cap_paginas or {}) do
    -- Normalize like the Kotlin's serializer: an entry can be a bare string.
    if type(pic) == "string" then
      pic = { src = pic }
    end
    local url
    if pic.path and pic.path ~= "" then
      -- The API hands the CDN-relative path of most pages outright — that
      -- beats the Kotlin's reconstruction from obra/scan/number, which is
      -- why it had to re-derive chapter numbers into `54` or `1_5` style
      -- directories and special-case wp-shaped srcs.
      url = CDN_URL .. "/" .. (pic.path:gsub("^/+", ""))
    elseif pic.src and pic.src ~= "" then
      -- Older rows give only the src; rebuild the directory the way the
      -- Kotlin does (chapter number with `.` → `_`).
      local number = number_string(data.cap_numero):gsub("%.", "_")
      url = string.format("%s/scans/%s/obras/%s/capitulos/%s/%s",
        CDN_URL, id_string(obra.scan_id or SCAN_ID), id_string(obra_id),
        number, (pic.src:gsub("^/+", "")))
    end
    if url then
      n = n + 1
      urls[n] = url
    end
  end
  return urls
end
