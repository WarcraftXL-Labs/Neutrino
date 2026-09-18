-- Sessions: cookies, partitions, and the isolation between them.
--
-- Every call here is awaited, so the suite reads as a sequence of statements
-- about the cookie store rather than as a chain of callbacks.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\session.lua

Neutrino = require "neutrino"
t = require "harness"

async = Neutrino.async
json = Neutrino.json

print "Neutrino: sessions"

t.load_native!

server = Neutrino.Server!
server.router\get "/", (req, res) ->
  res\html "<!doctype html><meta charset='utf-8'><title>Sessions</title><body>"

-- Same reason as the browser suite: closing a window must not end the loop
-- while the task is still working.
app = Neutrino.App t.app_options { quit_on_last_window: false }
t.expect_completion!

-- Recorded while the app runs and checked after it has shut down, because the
-- only honest test of persistence is what survives the process.
persist_cache_path = nil

URL = "https://smoke.neutrino.test/"

app\on "ready", ->
  t.deadline app

  window = Neutrino.BrowserWindow {
    title: "Sessions"
    url: "neutrino://app/"
    width: 480
    height: 320
    show: false
  }

  t.task "session suite", ->
    t.section "Partitions"

    default_session = window\session!
    t.check "a window exposes its session", default_session != nil
    t.check "a window with no partition uses the default one",
      default_session and default_session.partition == ""

    info = default_session\info!
    t.check "the default session is the global context", info.global == true,
      json.encode info

    -- Two lookups of one name have to hand back the same object: they wrap the
    -- same native context, so anything else would invite two caches of it.
    t.check "one partition name maps to one session",
      Neutrino.session.for_partition("scratch") ==
        Neutrino.session.for_partition "scratch"

    t.section "The first window in a partition"

    -- CEF brings a request context up asynchronously and refuses a browser in
    -- one that is still coming up, so this used to fail on the first attempt
    -- and succeed on the second - which reads as bad luck rather than as a
    -- missing wait.
    --
    -- It has to be a "persist:" partition and it has to come before anything
    -- else touches that name: an in-memory context is ready immediately, and
    -- any earlier session call would have brought this one up already.
    partitioned = nil
    ready_detail, ready_error = async.await (resolve) ->
      opened, failure = pcall ->
        partitioned = Neutrino.BrowserWindow {
          title: "Partitioned"
          url: "neutrino://app/"
          width: 320
          height: 240
          show: false
          partition: "persist:suite"
        }

      unless opened
        resolve nil, tostring failure
        return

      partitioned\on "ready", (detail) -> resolve detail
      partitioned\on "create-failed", (detail) -> resolve nil, detail.error

      -- Resolving twice is ignored, so this only matters when nothing else
      -- answers: a hang here would otherwise eat every check below it.
      app\set_timer 5000, -> resolve nil, "no ready event within 5s"

    t.check "it opens on the first attempt", ready_detail != nil, ready_error
    t.check "and uses the partition it asked for",
      partitioned and partitioned\session!.partition == "persist:suite",
      partitioned and partitioned.partition

    t.section "Cookies"

    expiry = os.time! + 3600
    written, write_error = default_session\set_cookie {
      url: URL
      name: "token"
      value: "abc123"
      path: "/"
      httpOnly: true
      secure: true
      sameSite: "lax"
      expires: expiry
    }
    t.check "a cookie is written", written == true, write_error

    cookies, read_error = default_session\get_cookies URL
    t.check "the store can be read back", type(cookies) == "table", read_error

    found = nil
    if type(cookies) == "table"
      for cookie in *cookies
        found = cookie if cookie.name == "token"

    t.check "the cookie is in it", found != nil,
      cookies and "#{#cookies} cookies" or "none"
    t.check "its value survives", found and found.value == "abc123",
      found and found.value
    t.check "its flags survive",
      found and found.httpOnly == true and found.secure == true,
      found and json.encode found
    t.check "its sameSite survives", found and found.sameSite == "lax",
      found and found.sameSite

    -- Times cross the boundary as seconds since the Unix epoch, through CEF's
    -- own conversion rather than a hard-coded Windows epoch offset.
    t.check "its expiry survives the time conversion",
      found and found.hasExpires and math.abs(found.expires - expiry) < 2,
      found and tostring found.expires

    t.section "Isolation"

    -- The point of partitions: another session must not see the first one's
    -- cookies, even for the same url.
    isolated = Neutrino.session.for_partition "isolated"
    leaked = isolated\get_cookies URL
    t.check "another partition sees none of it",
      type(leaked) == "table" and #leaked == 0,
      leaked and "#{#leaked} leaked" or "no answer"

    t.section "Persistence"

    disk_session = Neutrino.session.for_partition "persist:suite"
    persistent = disk_session\info!

    t.check "a persist: partition reports itself on disk",
      persistent.persistent == true, json.encode persistent
    t.check "and lands under the app's cache",
      persistent.cachePath and (persistent.cachePath\match "partition%-suite"),
      persistent.cachePath

    disk_session\set_cookie { url: URL, name: "ondisk", value: "yes", path: "/" }
    disk_session\flush_cookies!

    own = disk_session\get_cookies URL
    t.check "it keeps its own cookies",
      type(own) == "table" and #own == 1 and own[1].name == "ondisk",
      own and "#{#own} found" or "no answer"

    -- Checked after shutdown, at the bottom of this file: Chromium keeps the
    -- store in SQLite's journal for as long as the process runs, so while the
    -- app is alive the file is empty whether the partition worked or not.
    persist_cache_path = persistent.cachePath

    t.section "Removing and clearing"

    deleted, delete_error = default_session\remove_cookies URL, "token"
    t.check "a cookie is deleted by name", deleted == 1,
      delete_error or tostring deleted

    remaining = default_session\get_cookies URL
    t.check "and is gone from the store",
      type(remaining) == "table" and #remaining == 0,
      remaining and "#{#remaining} left" or "no answer"

    t.check "the store flushes", (default_session\flush_cookies!) == true
    t.check "the http cache clears", (default_session\clear_cache!) == true
    t.check "stored credentials clear", (default_session\clear_auth!) == true

    -- A failure has to arrive as nil plus a message rather than as a raise:
    -- the url here is not one a cookie can belong to.
    refused, reason = default_session\set_cookie {
      url: "not-a-url", name: "x", value: "y"
    }
    t.check "a rejected cookie says why",
      refused == nil and type(reason) == "string", reason or tostring refused

    partitioned\close true if partitioned
    window\close true

    t.done!
    app\quit!

app\run!

-- ═══════════════════════════════════════════════════════════════════════════
-- After shutdown: what the partition left behind
-- ═══════════════════════════════════════════════════════════════════════════
--
-- This is the check that cannot be fooled. Reporting a cache path proves
-- nothing: when Chromium refuses to create a profile it says so only in its own
-- log, and the partition then runs in memory while still naming a directory.
-- Only a closed store on disk settles it, and the store closes with CEF.

t.section "On disk, after shutdown"

if persist_cache_path
  handle = io.open "#{persist_cache_path}\\Network\\Cookies", "rb"
  size = handle and handle\seek("end") or 0
  handle\close! if handle

  t.check "the partition left its cookies on disk", size > 0,
    "#{persist_cache_path} -> #{size} bytes"
else
  t.fail "the partition reported a cache path", "none recorded"

t.finish!
