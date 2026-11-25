-- HQNow (hq-now.com). Brazilian comics archive. Unlike most sources this one
-- is not scraped HTML at all: the site is a SPA over a public GraphQL API at
-- `admin.hq-now.com/graphql`, ported query-for-query from the Keiyoushi Kotlin
-- extension. No bot gate anywhere — the endpoint answers bare requests, and
-- the picture CDN needs no Referer.

SOURCE = {
  id = "user.hqnow",
  name = "HQNow",
  kind = "reader",
  description = "Portuguese comics and manga through the site's GraphQL API.",
  lang = "pt",
  -- Declared as the base because it is the site the user reads; every call
  -- this script actually makes goes to the API host below, declared as the
  -- one mirror.
  base_url = "https://www.hq-now.com",
  mirrors = { "https://admin.hq-now.com" },
}

local GRAPHQL_URL = "https://admin.hq-now.com/graphql"

--[[ ---------------------------------------------------------- GraphQL -- ]]

-- GraphQL hands numbers back through `leaf.json` as Lua floats, so ids need
-- a floor before they can be strings.
local function id_string(n)
  return tostring(math.floor(tonumber(n) or 0))
end

-- The one call every question goes through. GraphQL answers 200 even for a
-- failed query — the error rides in the body — so check for that before
-- handing the data back.
local function gql(operation, query, variables)
  local res = leaf.http.post(GRAPHQL_URL, leaf.json.encode({
    operationName = operation,
    query = query,
    variables = variables or leaf.json.decode("{}"),
  }))
  if res.status ~= 200 then
    error(string.format("%s answered %d", operation, res.status))
  end
  local parsed = leaf.json.decode(res.body)
  if parsed.errors then
    error(operation .. ": " .. tostring(parsed.errors[1] and parsed.errors[1].message or "error"))
  end
  return parsed.data
end

-- The CDN spells every URL `http://` and 301s to the identical `https://`
-- path; ask for the final form directly.
local function secure(url)
  if type(url) ~= "string" then
    return nil
  end
  return (url:gsub("^http://", "https://"))
end

--[[ -------------------------------------------------------- catalogue -- ]]

-- All three listings are one-shot: the API's own shape has no paging (the
-- Kotlin returns `hasNextPage = false` for each, with popular capped at a
-- `limit` big enough to be the whole catalogue).
local LIST_FIELDS = [[
  id
  name
  hqCover
  synopsis
]]

local function to_summary(row)
  return { id = id_string(row.id), title = row.name, cover_url = secure(row.hqCover) }
end

local function list_from(data, key)
  local manga = {}
  for i, row in ipairs(data[key] or {}) do
    manga[i] = to_summary(row)
  end
  return { manga = manga, has_next_page = false }
end

function popular(page)
  if page > 1 then
    return { manga = {}, has_next_page = false }
  end
  local query = "query getHqsByFilters($orderByViews: Boolean, $limit: Int, $loadCovers: Boolean) {"
      .. " getHqsByFilters(orderByViews: $orderByViews, limit: $limit, loadCovers: $loadCovers) {"
      .. LIST_FIELDS .. " } }"
  local data = gql("getHqsByFilters", query, {
    orderByViews = true,
    loadCovers = true,
    -- Same cap the Kotlin asks for; the whole catalogue is under it.
    limit = 300,
  })
  return list_from(data, "getHqsByFilters")
end

function latest(page)
  if page > 1 then
    return { manga = {}, has_next_page = false }
  end
  local data = gql("getRecentlyUpdatedHqs",
    "query getRecentlyUpdatedHqs { getRecentlyUpdatedHqs { " .. LIST_FIELDS .. " } }")
  return list_from(data, "getRecentlyUpdatedHqs")
end

function search(query, page)
  if page > 1 then
    return { manga = {}, has_next_page = false }
  end
  local data = gql("getHqsByName",
    "query getHqsByName($name: String!) { getHqsByName(name: $name) { " .. LIST_FIELDS .. " } }",
    { name = query })
  return list_from(data, "getHqsByName")
end

--[[ -------------------------------------------------------- detail page -- ]]

function manga_details(id)
  local data = gql("getHqsById",
    "query getHqsById($id: Int!) { getHqsById(id: $id) { id name synopsis publisherName"
      .. " status hqCover } }",
    { id = tonumber(id) })
  local book = (data.getHqsById or {})[1]
  if not book then
    error("no such issue series " .. tostring(id))
  end
  return {
    title = book.name,
    author = book.publisherName,
    description = book.synopsis,
    cover_url = secure(book.hqCover),
  }
end

--[[ ---------------------------------------------------------- chapters -- ]]

-- One flat chapter list per series and no volume concept, so everything lands
-- in the library's "Unsorted" bucket like every other single-list site.
local UNSORTED = "Unsorted"

function volumes(id, language)
  local data = gql("getHqsById",
    "query getHqsById($id: Int!) { getHqsById(id: $id) { id capitulos { id number } } }",
    { id = tonumber(id) })
  local book = (data.getHqsById or {})[1]
  if not book then
    error("no such issue series " .. tostring(id))
  end

  local chapters = {}
  for i, row in ipairs(book.capitulos or {}) do
    chapters[i] = {
      number = tostring(row.number),
      -- The chapter's numeric id is all `page_list` needs — unlike the
      -- catalogue id it is unique across the whole site, not just this
      -- series.
      id = id_string(row.id),
      unavailable = false,
    }
  end
  return { { volume = UNSORTED, chapters = chapters } }
end

function covers(id)
  local data = gql("getHqsById",
    "query getHqsById($id: Int!) { getHqsById(id: $id) { hqCover } }",
    { id = tonumber(id) })
  local book = (data.getHqsById or {})[1]
  if not book or not book.hqCover then
    return {}
  end
  return { { url = secure(book.hqCover) } }
end

--[[ -------------------------------------------------------- page_list -- ]]

function page_list(chapter_id)
  local data = gql("getChapterById",
    "query getChapterById($chapterId: Int!) { getChapterById(chapterId: $chapterId) { pictures { pictureUrl } } }",
    { chapterId = tonumber(chapter_id) })
  local chapter = data.getChapterById or {}

  local urls = {}
  for i, pic in ipairs(chapter.pictures or {}) do
    -- Document order is page order; the filenames' embedded page numbers are
    -- not even worth parsing because the API already emits the reading order.
    urls[i] = secure(pic.pictureUrl)
  end
  return urls
end
