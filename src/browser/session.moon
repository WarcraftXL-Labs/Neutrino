--- Sessions: cookies, cache and stored credentials, isolated per partition.
--
-- A session is Electron's `session`, and CEF's `CefRequestContext` underneath.
-- Windows created with the same partition name share cookies, cache and local
-- storage; windows in different partitions share none of it, which is what lets
-- one application hold two logins to the same site at once.
--
--   ""              the default session, used by every window that asks for none
--   "persist:name"  kept on disk, under <cache_path>/partitions/name
--   "name"          kept in memory, gone when the process exits
--
-- Every call here is asynchronous and answers exactly once. Inside a task it is
-- awaited and returns its result; outside one, pass a callback. Failures come
-- back as `nil, message` rather than raising, because most of them describe the
-- state of the browser rather than a bug in the caller.
--
--     cookies = session\get_cookies "https://example.com"
--     session\set_cookie { url: "https://example.com", name: "token", value: t }
---@module browser.session

ffi = require "ffi"
async = require "core.async"
bridge = require "core.bridge"
cef = require "core.cef"
json = require "util.json"

-- Maps a friendly colour scheme name to cef_color_variant_t.
COLOR_VARIANTS = {
  system: 0
  light: 1
  dark: 2
  tonal: 3
  neutral: 4
  vibrant: 5
  expressive: 6
}

--- Runs one native session call in whichever style the caller wants.
--
-- The native side answers every request id exactly once, whether the work
-- reached CEF or failed on the way, so both shapes reduce to the same thing:
-- start the call, park a resolver under the id it returned.
---@param start fun(): integer Performs the call, returning its request id.
---@param callback? fun(value: any, err: string|nil)
---@return any value, string|nil err when awaited; nothing otherwise.
---@private
settle = (start, callback) ->
  arrange = (resolve) ->
    request_id = start!
    bridge.sessions[request_id] = resolve

  return async.await arrange if callback == nil and async.is_async!

  arrange (value, err) -> callback value, err if callback

---@class Session
---@field partition string The partition name, "" for the default session.
class Session
  --- Wraps a partition. Prefer `session.for_partition`, which reuses instances.
  ---@param partition? string
  new: (partition = "") =>
    @partition = partition

  --- Returns what the partition resolved to: whether it is the default session,
  -- whether it persists, and the directory it ended up in.
  --
  -- Worth checking when a "persist:" partition does not seem to remember
  -- anything: without a cache_path on the App there is nowhere to persist to,
  -- and the session silently falls back to memory.
  ---@return table
  info: =>
    decoded = json.try_decode ffi.string cef.lib.neutrino_session_info @partition
    decoded or {}

  -- ═══════════════════════════════════════════════════════════════════════════
  -- COOKIES
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Reads cookies, filtered by url when one is given.
  --
  -- Each cookie is a table: name, value, domain, path, secure, httpOnly,
  -- hasExpires, expires, creation, lastAccess, sameSite, priority. The three
  -- times are seconds since the Unix epoch.
  ---@param filter? string|table A url, or { url, include_http_only }.
  ---@param callback? fun(cookies: table[], err: string|nil)
  ---@return table[]|nil cookies, string|nil err when awaited.
  get_cookies: (filter, callback) =>
    filter = { url: filter } if type(filter) == "string"
    filter or= {}

    -- HTTP-only cookies are included by default: a session cookie is usually
    -- exactly what a tool is looking for, and hiding it would be surprising
    -- here in a way it is not in a page.
    include = filter.include_http_only != false
    partition, url = @partition, (filter.url or "")

    settle (-> cef.lib.neutrino_cookies_get partition, url, (include and 1 or 0)),
      callback

  --- Writes one cookie.
  --
  -- `url` decides which host the cookie belongs to and must be given. `expires`
  -- is in seconds since the Unix epoch; leaving it out makes a session cookie,
  -- which is what a Set-Cookie header without an Expires attribute does.
  ---@param cookie table url, name, value, and optionally domain, path, secure,
  --- httpOnly, expires, sameSite ("none"/"lax"/"strict"), priority.
  ---@param callback? fun(ok: boolean, err: string|nil)
  ---@return boolean|nil ok, string|nil err when awaited.
  set_cookie: (cookie, callback) =>
    url = cookie.url or ""
    encoded = json.encode cookie
    partition = @partition

    settle (-> cef.lib.neutrino_cookies_set partition, url, encoded), callback

  --- Deletes cookies, answering with how many went.
  --
  -- An empty url clears every host in the partition; an empty name clears every
  -- cookie of that host.
  ---@param url? string
  ---@param name? string
  ---@param callback? fun(deleted: integer, err: string|nil)
  ---@return integer|nil deleted, string|nil err when awaited.
  remove_cookies: (url = "", name = "", callback) =>
    partition = @partition
    settle (-> cef.lib.neutrino_cookies_delete partition, url, name), callback

  --- Writes the cookie store to disk, answering once it is there.
  -- The point of awaiting this is that a crash afterwards no longer loses the
  -- change, which matters before the application shuts itself down.
  ---@param callback? fun(ok: boolean, err: string|nil)
  ---@return boolean|nil ok, string|nil err when awaited.
  flush_cookies: (callback) =>
    partition = @partition
    settle (-> cef.lib.neutrino_cookies_flush partition), callback

  -- ═══════════════════════════════════════════════════════════════════════════
  -- STORAGE AND CONNECTIONS
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Empties the HTTP cache for this partition.
  ---@param callback? fun(ok: boolean, err: string|nil)
  ---@return boolean|nil ok, string|nil err when awaited.
  clear_cache: (callback) =>
    partition = @partition
    settle (-> cef.lib.neutrino_session_clear_cache partition), callback

  --- Forgets saved HTTP authentication credentials for this partition.
  ---@param callback? fun(ok: boolean, err: string|nil)
  ---@return boolean|nil ok, string|nil err when awaited.
  clear_auth: (callback) =>
    partition = @partition
    settle (-> cef.lib.neutrino_session_clear_auth partition), callback

  --- Closes every open connection, so the next request opens a fresh one.
  ---@param callback? fun(ok: boolean, err: string|nil)
  ---@return boolean|nil ok, string|nil err when awaited.
  close_connections: (callback) =>
    partition = @partition
    settle (-> cef.lib.neutrino_session_close_connections partition), callback

  --- Sets the Chrome colour scheme for every browser in this partition.
  --
  -- Affects Chrome runtime style only: an Alloy window has no Chromium UI to
  -- recolour, so this changes nothing there. It does not restyle the page,
  -- which follows `prefers-color-scheme` on its own.
  ---@param mode? string "system" (default), "light", "dark", "tonal",
  --- "neutral", "vibrant" or "expressive".
  ---@param color? integer Accent colour as 0xAARRGGBB; 0 keeps Chromium's own.
  ---@return boolean True when the partition accepted it.
  set_color_scheme: (mode = "system", color = 0) =>
    variant = COLOR_VARIANTS[mode]
    unless variant
      io.stderr\write "[neutrino] unknown colour scheme '#{tostring mode}'\n"
      return false

    cef.lib.neutrino_session_set_color_scheme(@partition, variant, color) == 1

-- One instance per partition: two Session objects for the same name would hold
-- the same native context anyway, and sharing them lets a caller compare them.
instances = {}

--- Returns the session for a partition, creating it on first use.
---@param partition? string "" for the default session.
---@return Session
for_partition = (partition = "") ->
  instances[partition] or= Session partition
  instances[partition]

{ :Session, :for_partition }
