-- MangaLivre / ToonLivre (toonlivre.net). A React SPA with a JSON API: the
-- catalogue, detail page and chapter list are all plain `/api` calls, ported
-- from the Keiyoushi Kotlin extension's shapes.
--
-- The one thing the API will not give out over bare HTTP is the page list:
-- `POST /api/reader/chapter/access` answers 403 unless the requester holds a
-- solved Cloudflare Turnstile token. The Kotlin extension handles this by
-- opening a WebView and harvesting the CDN URLs the rendered reader page
-- requests; Leaf's equivalent is the harvest window — so `page_list` here
-- tries the API first (it works whenever the site's bot gate waves the
-- request through) and otherwise fails with the reader page's URL, which is
-- exactly what "Find images" needs to open.

SOURCE = {
  id = "user.mangalivre",
  name = "MangaLivre (ToonLivre)",
  kind = "reader",
  description = "Portuguese manga; the site is mid-migration between two domains.",
  lang = "pt",
  base_url = "https://toonlivre.net",
  -- The site is mid-migration: `toonlivre.net` intermittently 302s to
  -- `www.mangalivre.net`, a name that does not resolve yet (NXDOMAIN from
  -- both Google and Cloudflare as of this writing). Declared as a mirror so
  -- `leaf.http`'s origin pin allows that hop the moment it exists, instead
  -- of the extension dying when the redirect starts being served.
  mirrors = { "https://www.mangalivre.net" },
}

local PAGE_SIZE = 24

-- The site serves its images from its own CDN, sometimes wrapped through an
-- EdgeCompute proxy whose only job is to carry the real URL as a `?url=`
-- parameter. Both spellings appear in the reader payload.
local CDN_HOST = "cdn.toonlivre.net"
local PROXY_HOST = "slightly-free-mayfly.edgecompute.app"

--[[ --------------------------------------------------------- utilities -- ]]

-- Percent-encode one query value; search text is arbitrary.
local function url_encode(s)
  return (tostring(s):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Percent-decode, ASCII only: proxy-wrapped URLs arrive percent-encoded, and
-- a lone %XX for a non-ASCII byte is left as-is — a raw continuation byte in
-- the middle of the URL would be worse than the encoded form, which fetches
-- and dedupes fine.
local function url_decode(s)
  return (s:gsub("%%(%x%x)", function(hex)
    local n = tonumber(hex, 16)
    if n < 0x80 then
      return string.char(n)
    end
    return "%" .. hex
  end))
end

local function host_of(url)
  return url:match("^https?://([^/]+)")
end

-- `?url=`'s value for a proxy-wrapped image, decoded; nil for anything else.
local function proxied_url(url)
  if host_of(url) ~= PROXY_HOST then
    return nil
  end
  local raw = url:match("[?&]url=([^&]+)")
  return raw and url_decode(raw)
end

-- Portuguese titles carry accents the site's own slugs drop (its JS does
-- `.normalize("NFD").replace(/[\u0300-\u036f]/g, "")`; Lua has no
-- Normalizer, so the letters that actually occur in pt-BR get a table).
-- Only used to *guess* a reader URL for the harvest hint — every real API
-- call is driven by ids, never by slugs.
local ACCENTS = {
  ["á"] = "a", ["à"] = "a", ["ã"] = "a", ["â"] = "a",
  ["é"] = "e", ["ê"] = "e", ["í"] = "i",
  ["ó"] = "o", ["õ"] = "o", ["ô"] = "o",
  ["ú"] = "u", ["ü"] = "u", ["ç"] = "c",
}

local function slugify(title)
  local s = title:lower()
  for from, to in pairs(ACCENTS) do
    s = s:gsub(from, to)
  end
  s = s:gsub("[^a-z0-9]+", "-")
  return (s:gsub("^-+|-+$", ""))
end

-- The one call every catalogue question goes through.
local function api_get(path, params)
  local url = SOURCE.base_url .. path
  local parts = {}
  for _, kv in ipairs(params or {}) do
    parts[#parts + 1] = kv[1] .. "=" .. url_encode(kv[2])
  end
  if #parts > 0 then
    url = url .. "?" .. table.concat(parts, "&")
  end

  local res = leaf.http.get(url)
  if res.status ~= 200 then
    error(string.format(
      "%s answered %d — the site's bot gate is refusing this request right " ..
      "now. Try again shortly.", path, res.status))
  end
  return leaf.json.decode(res.body)
end

--[[ -------------------------------------------------------- catalogue -- ]]

-- Popular, Latest and search are the same endpoint with different sorts; the
-- Kotlin extension drives it exactly that way.
local function browse(page, query, sort_by)
  local params = {
    { "page", page },
    { "limit", PAGE_SIZE },
    { "sortBy", sort_by },
    { "sortOrder", "desc" },
  }
  if query ~= "" then
    params[#params + 1] = { "q", query }
  end
  local data = api_get("/api/mangas/search", params)

  local manga = {}
  for i, row in ipairs(data.mangas or {}) do
    -- The `id` (`obra-…`) is what every later API call wants — `manga-by-slug`
    -- accepts it despite the name — and it is stable, unlike the title slug.
    manga[i] = { id = row.id, title = row.title, cover_url = row.coverUrl }
  end
  return { manga = manga, has_next_page = (data.pagination or {}).hasNextPage or false }
end

function popular(page)
  return browse(page, "", "popular")
end

function latest(page)
  return browse(page, "", "updated")
end

function search(query, page)
  return browse(page, query, "popular")
end

--[[ ----------------------------------------------------- detail page -- ]]

local function fetch_manga(id)
  return api_get("/api/manga-by-slug/" .. url_encode(id))
end

function manga_details(id)
  local data = fetch_manga(id)
  return {
    title = data.title,
    -- The site's alternative title is its English name, which is what the
    -- metadata fill (MangaDex/Kitsu/AniList/Jikan) searches on — handing it
    -- over as `title_romaji` lets those tiers improve the match.
    title_romaji = data.alternativeTitle,
    author = data.authors and table.concat(data.authors, ", ") or nil,
    artist = data.artists and table.concat(data.artists, ", ") or nil,
    description = data.description,
    tags = data.genres or {},
    cover_url = data.coverUrl,
  }
end

--[[ --------------------------------------------------------- chapters -- ]]

-- No volume concept on the site, only a flat chapter list — same answer as
-- MangaTaro gives: everything under "Unsorted".
local UNSORTED = "Unsorted"

function volumes(id, language)
  local data = fetch_manga(id)
  local chapters = {}
  for i, row in ipairs(data.chapters or {}) do
    chapters[i] = {
      number = row.number,
      -- `page_list` needs both ids *and* something to build a reader URL
      -- from when the access endpoint refuses, so the chapter ref packs all
      -- three. Nothing upstream looks inside an id; it is this script's
      -- private format.
      id = id .. "|" .. row.id .. "|" .. row.number,
      unavailable = false,
    }
  end
  return { { volume = UNSORTED, chapters = chapters } }
end

function covers(id)
  local data = fetch_manga(id)
  if not data.coverUrl then
    return {}
  end
  -- One gallery image, not volume art; reported without a volume so the
  -- library treats it as the series cover.
  return { { url = data.coverUrl } }
end

--[[ -------------------------------------------------------- page_list -- ]]

-- Page files live under /obras/<mangaId>/<chapterNumber>/ and carry their
-- position in the filename (`…_007.jpg`, `…_12.webp`); anything else on that
-- CDN (covers, avatars) is filtered out by exactly that path shape — the
-- same check the Kotlin does.
local function is_chapter_image(url, manga_id, number)
  if host_of(url) ~= CDN_HOST then
    return false
  end
  local path = url:match("^https?://[^/]+(/.-)/?[^/]*$") or url:match("^https?://[^/]+(/.*)$")
  return path ~= nil
      and path:find("/obras/" .. manga_id .. "/" .. number .. "/", 1, true) ~= nil
end

local function page_number_of(url)
  local file = url:match("/([^/]+)$")
  if not file then
    return math.huge
  end
  local digits = file:match("_(%d+)%.") or file:match("^(%d+)%.")
  return digits and tonumber(digits) or math.huge
end

function page_list(chapter_id)
  local manga_id, real_id, number = chapter_id:match("^([^|]+)|([^|]+)|([^|]+)$")
  if not manga_id then
    error(string.format("malformed chapter reference %q", chapter_id))
  end

  local res = leaf.http.post(
    SOURCE.base_url .. "/api/reader/chapter/access",
    leaf.json.encode({ mangaId = manga_id, chapterId = real_id }),
    { referer = SOURCE.base_url .. "/" })

  if res.status == 403 then
    -- The Turnstile answer. A plain HTTP client cannot solve it and neither
    -- can this sandbox; name the reader page so the harvest window (or a
    -- browser) can be opened on it instead.
    local slug = ""
    local ok, data = pcall(fetch_manga, manga_id)
    if ok and data.title then
      slug = slugify(data.title)
    end
    local reader_url = SOURCE.base_url .. "/" .. slug .. "/" .. number
    error(string.format(
      "this site gates its pages behind a Cloudflare check only a real browser " ..
      "can pass. Open %s with Find images and capture the pages once the " ..
      "reader loads them.", reader_url))
  end
  if res.status ~= 200 then
    error(string.format("reader access answered %d", res.status))
  end

  local data = leaf.json.decode(res.body)
  local seen, candidates = {}, {}
  for _, raw in ipairs(((data or {}).chapter or {}).pages or {}) do
    local url = proxied_url(raw) or raw
    -- Same normalization the Kotlin does: https, on the CDN, of this
    -- chapter's shape, deduplicated.
    if url:match("^https://") and is_chapter_image(url, manga_id, number) and not seen[url] then
      seen[url] = true
      candidates[#candidates + 1] = url
    end
  end

  table.sort(candidates, function(a, b)
    local pa, pb = page_number_of(a), page_number_of(b)
    if pa ~= pb then
      return pa < pb
    end
    return a < b
  end)
  return candidates
end
