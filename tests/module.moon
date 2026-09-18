-- Modules: the namespace they claim, the internal dispatch, and what is left
-- when one is taken back down.
--
-- The first half needs no browser at all, which is the point: a route is now
-- testable without a window. The second half opens one, because IPC and window
-- ownership cannot be tested any other way.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\module.lua

Neutrino = require "neutrino"
t = require "harness"

async = Neutrino.async
json = Neutrino.json
Module = Neutrino.Module

print "Neutrino: modules"

t.load_native!

-- ═══════════════════════════════════════════════════════════════════════════
-- Two modules that know nothing about each other
-- ═══════════════════════════════════════════════════════════════════════════

-- Recorded by the modules and read by the checks.
seen = {
  archive_started: false
  archive_stopped: false
  archive_ticks: 0
}

class Archive extends Module
  name: "archive"
  partition: true

  routes: (router) =>
    seen.archive_started = true

    router\get "/", (req, res) ->
      res\html "<!doctype html><meta charset='utf-8'><title>Archive</title>
        <body><p id='hello'>archive</p>"

    router\get "/entry/:id", (req, res) ->
      res\json { id: req.params.id, host: req.host }

    -- Waits before replying, to prove an internal fetch follows the same
    -- deferred path a real request does.
    router\get "/slow", (req, res) ->
      async.sleep 120
      res\json { waited: true }

  on_quit: => seen.archive_stopped = true

-- Declares no name, so it gets one from its class name.
class ViewerModule extends Module
  routes: (router) =>
    router\get "/", (req, res) -> res\text "viewer"

    -- Composition: one module serving another's output without knowing it is
    -- a module, which is the whole of what HMVC's sub-request buys.
    router\get "/embed", (req, res) ->
      inner = @fetch "neutrino://archive/entry/42"
      -- Parenthesised: without them the call swallows the rest of the table as
      -- further arguments, and decode gets two.
      res\json { embedded: (json.decode inner.body), status: inner.status }

    -- A bare path resolves against the module's own origin.
    router\get "/self", (req, res) -> res\text (@fetch "/").body

server = Neutrino.Server!

server.router\get "/", (req, res) ->
  res\html "<!doctype html><meta charset='utf-8'><title>Shell</title><body>"

app = Neutrino.App t.app_options { quit_on_last_window: false }
t.expect_completion!

archive = app\register_module Archive
viewer = app\register_module ViewerModule

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Namespace"

t.check "a module keeps the name it declares", archive.name == "archive"
t.check "a module without one takes it from its class",
  viewer.name == "viewer", viewer.name
t.check "a module owns an origin", archive.origin == "neutrino://archive/",
  archive.origin
t.check "it builds urls under that origin",
  (archive\url "entry/1") == "neutrino://archive/entry/1", archive\url "entry/1"
t.check "a leading slash makes no difference",
  (archive\url "/entry/1") == archive\url "entry/1"
t.check "it prefixes its ipc channels",
  (archive\channel "open") == "archive:open", archive\channel "open"

t.check "partition: true means persist under the module name",
  (archive\partition_name!) == "persist:archive", archive\partition_name!
t.check "a module that asks for nothing uses the default session",
  (viewer\partition_name!) == "", viewer\partition_name!

-- A window has one partition, so a module attached to somebody else's window
-- does not get its own session however clearly it asked. Stub windows here:
-- what is being tested is the rule, not a browser.
t.check "a module says so when a window's session is not the one it wants",
  (archive\partition_mismatch { partition: "", closed: false }) != nil
t.check "and says nothing when the window matches",
  (archive\partition_mismatch { partition: "persist:archive" }) == nil
t.check "a module that wants no partition never complains",
  (viewer\partition_mismatch { partition: "persist:elsewhere" }) == nil

t.check "registering starts the module", seen.archive_started
t.check "and the app can find it back", (app\module "archive") == archive
t.check "a second module of the same name is refused",
  not pcall -> app\register_module Archive

t.section "Serving without a browser"

-- Everything here runs before CEF is up. A route is a function of a request
-- now, so nothing about it needs a window.
t.task "offline fetch", ->
  reply = server\fetch "neutrino://archive/entry/42"
  t.check "an internal fetch reaches the module's router",
    reply.status == 200, tostring reply.status
  t.check "it carries the mime type the route set",
    reply.mime\match("^application/json") != nil, reply.mime

  body = json.decode reply.body
  t.check "the route saw its own parameters", body and body.id == "42",
    reply.body
  t.check "and the host it was addressed by", body and body.host == "archive",
    reply.body

  t.check "an unknown path answers 404",
    (server\fetch "neutrino://archive/nowhere").status == 404

  t.check "an unknown host falls back to the default router",
    (server\fetch "neutrino://app/").status == 200

  composed = server\fetch "neutrino://viewer/embed"
  embedded = json.decode composed.body
  t.check "a module composes another module's reply",
    embedded and embedded.embedded and embedded.embedded.id == "42",
    composed.body

  t.check "a bare path resolves against the module's own origin",
    (server\fetch "neutrino://viewer/self").body == "viewer",
    (server\fetch "neutrino://viewer/self").body

  -- Outside a task there is no awaiting, so the callback form has to work.
  answered = nil
  server\fetch "neutrino://viewer/", (reply) -> answered = reply
  t.check "the callback form answers too", answered and answered.body == "viewer",
    answered and answered.body or "no answer"

app\on "ready", ->
  t.deadline app

  t.task "module suite", ->
    t.section "A route that waits"

    -- Left until the loop is running, because the handler sleeps on a timer and
    -- there is nothing to fire it before then. Everything above this point ran
    -- with CEF still down.
    slow = server\fetch "neutrino://archive/slow"
    t.check "a deferred route still answers an internal fetch",
      (json.decode slow.body).waited == true, slow.body

    t.section "Windows and IPC"

    window = archive\open { width: 480, height: 320, show: false }
    t.check "a module window loads the module's origin",
      window\get_url!\match("^neutrino://archive/") != nil, window\get_url!
    t.check "and uses the module's partition",
      window.partition == "persist:archive", window.partition
    t.check "the module owns it", #archive.windows == 1, tostring #archive.windows

    archive\handle "echo", (payload) -> { heard: payload.word }

    t.wait_for window, "did-finish-load", (detail) ->
      detail.url and detail.url\match "^neutrino://archive/"

    -- A handler declared after the window was opened still has to be installed
    -- on it, which is the half of the wiring that is easy to get wrong.
    window\exec_js "window.neutrino.invoke('archive:echo', { word: 'hi' })
      .then(r => { window.__echo = r.heard })
      .catch(e => { window.__echo = 'ERR: ' + e.message })"

    t.check "a namespaced handler answers the page",
      (t.wait_until -> (window\eval "window.__echo") != json.null) and
        (window\eval "window.__echo") == "hi",
      window\eval "window.__echo"

    -- Two modules in one window: the point of the prefix.
    viewer\attach window
    viewer\handle "echo", (payload) -> { heard: "viewer" }

    window\exec_js "window.neutrino.invoke('viewer:echo', {})
      .then(r => { window.__viewer = r.heard })"

    t.check "a second module shares the window without colliding",
      (t.wait_until -> (window\eval "window.__viewer") != json.null) and
        (window\eval "window.__viewer") == "viewer" and
        (window\eval "window.__echo") == "hi",
      window\eval "window.__viewer"

    window\exec_js "window.neutrino.on('archive:changed',
      p => { window.__pushed = p.what })"
    archive\broadcast "changed", { what: "entry" }

    t.check "a module pushes a namespaced event",
      (t.wait_until -> (window\eval "window.__pushed") != json.null) and
        (window\eval "window.__pushed") == "entry",
      window\eval "window.__pushed"

    t.section "Taking a module down"

    -- A timer the module owns: it has to stop with the module, or an
    -- unregistered module keeps running.
    archive\set_timer 25, (-> seen.archive_ticks += 1), 25
    async.sleep 120
    ticks_before = seen.archive_ticks
    t.check "a module timer runs while the module does", ticks_before > 0,
      tostring ticks_before

    removed = app\unregister_module "archive"

    t.check "unregistering hands the module back", removed == archive
    t.check "and calls on_quit", seen.archive_stopped
    t.check "and forgets it", (app\module "archive") == nil

    t.check "its routes stop answering",
      (server\fetch "neutrino://archive/entry/42").status == 404

    t.check "its windows are closed", t.wait_until -> window.closed

    async.sleep 120
    t.check "its timers stop", seen.archive_ticks == ticks_before,
      "#{ticks_before} -> #{seen.archive_ticks}"

    -- The other module never asked to be taken down, so it must be untouched.
    t.check "another module keeps serving",
      (server\fetch "neutrino://viewer/").status == 200

    t.done!
    app\quit!

app\run!
t.finish!
