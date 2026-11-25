-- Pages for MangaDex chapters.
--
-- A reader only: Leaf's built-in MangaDex catalogue lists series, volumes and
-- chapters, and finds this script to turn a MangaDex chapter id into pages
-- because it declares the same site (mangadex.org). Installing it is what
-- makes MangaDex chapters readable and downloadable at all; Leaf fetches no
-- pages of its own.
--
-- Pages come from MangaDex@Home: `/at-home/server/{chapter}` hands out an
-- image server and a hash, valid for a short while, so `page_list` is asked
-- right before each read or download and its answer is never stored. The
-- image servers are volunteer-run hosts under `*.mangadex.network`; they are
-- not declared below because this script never requests them itself — the
-- page URLs it returns are fetched by Leaf's downloader, which only checks
-- that they are public addresses.

SOURCE = {
  id = "user.mangadex",
  name = "MangaDex",
  kind = "reader",
  description = "Pages for chapters from Leaf's built-in MangaDex catalogue, via MangaDex@Home.",
  lang = "multi",
  base_url = "https://mangadex.org",
  mirrors = { "https://api.mangadex.org" },
}

local API = "https://api.mangadex.org"
local COVERS = "https://uploads.mangadex.org/covers"

-- The chapter feed answers at most 500 rows per request. Bounded so a very
-- long series cannot run `chapters` past the host's 20 s per-call limit;
-- 4 000 chapters covers anything real.
local FEED_PAGE = 500
local FEED_MAX_PAGES = 8

-- The language `chapters` resolves in. MangaDex chapter ids are
-- per-translation and `chapters` has no language argument, so it picks
-- English and falls back to every language when there is no English at all.
local PREFERRED_LANGUAGE = "en"

local function url_encode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- `params` is an array of {key, value} pairs, since MangaDex repeats keys
-- (`includes[]`, `translatedLanguage[]`).
local function api_get(path, params)
  local url = API .. path
  if params and #params > 0 then
    local parts = {}
    for i, pair in ipairs(params) do
      parts[i] = url_encode(pair[1]) .. "=" .. url_encode(pair[2])
    end
    url = url .. "?" .. table.concat(parts, "&")
  end
  local res = leaf.http.get(url, { headers = { ["Accept"] = "application/json" } })
  if res.status == 429 then
    error("MangaDex is rate-limiting requests; wait a minute and try again", 0)
  end
  if res.status ~= 200 then
    error("MangaDex answered " .. res.status .. " for " .. path, 0)
  end
  return leaf.json.decode(res.body)
end

-- `leaf.json.decode` hands numbers back as floats; MangaDex's ids are
-- strings, but totals and offsets are not.
local function int(n)
  return math.floor(tonumber(n) or 0)
end

local function title_of(attrs)
  local titles = attrs.title or {}
  if titles.en then
    return titles.en
  end
  for _, alt in ipairs(attrs.altTitles or {}) do
    if alt.en then
      return alt.en
    end
  end
  for _, value in pairs(titles) do
    return value
  end
  return "?"
end

local function cover_of(item)
  for _, rel in ipairs(item.relationships or {}) do
    if rel.type == "cover_art" and rel.attributes and rel.attributes.fileName then
      return COVERS .. "/" .. item.id .. "/" .. rel.attributes.fileName .. ".256.jpg"
    end
  end
  return nil
end

function search(query, page)
  local offset = (page - 1) * 20
  local body = api_get("/manga", {
    { "title", query },
    { "limit", "20" },
    { "offset", tostring(offset) },
    { "includes[]", "cover_art" },
    { "order[relevance]", "desc" },
    { "contentRating[]", "safe" },
    { "contentRating[]", "suggestive" },
    { "contentRating[]", "erotica" },
  })
  local manga = {}
  for i, item in ipairs(body.data or {}) do
    manga[i] = { id = item.id, title = title_of(item.attributes or {}), cover_url = cover_of(item) }
  end
  return { manga = manga, has_next_page = offset + #manga < int(body.total) }
end

-- Every chapter of a series in one language, by number — the same numbers
-- Leaf's MangaDex catalogue uses (`"none"` for an unnumbered chapter, as the
-- aggregate endpoint spells it). First upload of a number wins.
local function feed(manga_id, language)
  local chapters, seen = {}, {}
  for page = 0, FEED_MAX_PAGES - 1 do
    local params = {
      { "limit", tostring(FEED_PAGE) },
      { "offset", tostring(page * FEED_PAGE) },
      { "order[chapter]", "asc" },
      { "includeExternalUrl", "0" },
      { "includeEmptyPages", "0" },
      { "contentRating[]", "safe" },
      { "contentRating[]", "suggestive" },
      { "contentRating[]", "erotica" },
      { "contentRating[]", "pornographic" },
    }
    if language then
      params[#params + 1] = { "translatedLanguage[]", language }
    end
    local body = api_get("/manga/" .. manga_id .. "/feed", params)
    local rows = body.data or {}
    for _, row in ipairs(rows) do
      local number = (row.attributes or {}).chapter or "none"
      if not seen[number] then
        seen[number] = true
        chapters[#chapters + 1] = { number = number, id = row.id }
      end
    end
    if (page + 1) * FEED_PAGE >= int(body.total) or #rows == 0 then
      break
    end
  end
  return chapters
end

function chapters(manga_id)
  local found = feed(manga_id, PREFERRED_LANGUAGE)
  if #found == 0 then
    found = feed(manga_id, nil)
  end
  return found
end

function page_list(chapter_id)
  local body = api_get("/at-home/server/" .. chapter_id)
  local base = body.baseUrl
  local hash = body.chapter and body.chapter.hash
  local files = body.chapter and body.chapter.data or {}

  -- A chapter MangaDex indexes but does not host answers with an empty list
  -- and a success status. The publisher's page goes last in the message:
  -- Leaf's reader offers a URL at the end of an error as a button. Level 0,
  -- so no "script:N:" position is prefixed to a message meant for a reader.
  if not base or not hash or hash == "" or #files == 0 then
    local ok, chapter = pcall(api_get, "/chapter/" .. chapter_id)
    local external = ok and chapter.data and chapter.data.attributes
      and chapter.data.attributes.externalUrl
    if external then
      error("MangaDex indexes this chapter but does not host its images — it is "
        .. "officially licensed and published at " .. external, 0)
    end
    error("MangaDex has no images for this chapter.", 0)
  end

  local pages = {}
  for i, file in ipairs(files) do
    pages[i] = base .. "/data/" .. hash .. "/" .. file
  end
  return pages
end
