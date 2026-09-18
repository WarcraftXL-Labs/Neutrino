-- The browser half: a window, the custom scheme, IPC both ways, eval, the
-- context menu, request interception, and waiting without blocking.
--
-- Written as one task that reads top to bottom. Every step that has to wait for
-- the page awaits it, so the order on screen is the order it happens in.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\browser.lua

Neutrino = require "neutrino"
t = require "harness"

async = Neutrino.async
json = Neutrino.json

print "Neutrino: browser"

t.load_native!
print "  info  #{Neutrino.cef.version!}"

-- ═══════════════════════════════════════════════════════════════════════════
-- What the page is served
-- ═══════════════════════════════════════════════════════════════════════════

-- Recorded by the handlers below and read by the checks. Grouped rather than
-- scattered as loose locals, so what the suite observes is in one place.
seen = {
  requests: {}
  blocked_route_hit: false
  menu_params: nil
  menu_window: nil
  menu_action_ran: false
  heartbeats: 0
  veto_used: false
  closed: false
  request_shape: nil
}

server = Neutrino.Server!

server.router\get "/", (req, res) ->
  res\html "<!doctype html><meta charset='utf-8'><title>Browser</title>
    <body><p id='hello'>hi</p>"

server.router\get "/blocked.js", (req, res) ->
  seen.blocked_route_hit = true
  res\send "window.__blocked = true", "application/javascript"

server.router\get "/redirected.js", (req, res) ->
  res\send "window.__redirected = true", "application/javascript"

server.router\get "/allowed.js", (req, res) ->
  res\send "window.__allowed = true", "application/javascript"

server.router\get "/api/echo/:value", (req, res) ->
  res\json { value: req.params.value, upper: req.params.value\upper! }

-- Waits before replying. The request stays open while the loop keeps running,
-- which is the whole point of a deferred response.
server.router\get "/api/slow", (req, res) ->
  async.sleep 250
  res\json { waited: true }

-- The loop has to outlive the last window: this suite closes the window and
-- then keeps checking, and the default would end the loop there and cut the
-- task off mid-flight.
app = Neutrino.App t.app_options { quit_on_last_window: false }
t.expect_completion!

-- ═══════════════════════════════════════════════════════════════════════════

app\on "ready", ->
  t.deadline app

  t.section "Displays"

  -- Only enumerable once CEF is up, which run() does just before "ready".
  displays = Neutrino.screen.get_all_displays!
  t.check "at least one display is found", #displays > 0, "#{#displays} found"
  t.check "a display reports its scale factor",
    #displays > 0 and displays[1].scale_factor > 0

  t.section "Window"

  window = Neutrino.BrowserWindow {
    title: "Browser suite"
    url: "neutrino://app/"
    width: 640
    height: 420
  }

  t.check "the window is created", window.id > 0
  t.check "the window is valid", window\is_valid!

  bounds = window\get_bounds!
  t.check "it reports usable bounds", bounds.width > 0 and bounds.height > 0,
    "#{bounds.width}x#{bounds.height}"

  window\set_title "Browser suite (renamed)"
  window\on "ready", -> t.check "the browser announces itself ready", true
  window\on "closed", -> seen.closed = true

  -- --- Handlers, registered before anything can reach them ------------------

  window\handle "add", (payload) -> { sum: payload.a + payload.b }

  -- A handler whose body is a single chained call returns the window, which
  -- holds functions and cdata. It has to answer null rather than reject.
  window\handle "chained", -> window\center!

  -- Awaits inside an IPC handler: the query is left open and resolved later.
  window\handle "slow-add", (payload) ->
    async.sleep 200
    { sum: payload.a + payload.b, deferred: true }

  window\handle "start-heartbeat", ->
    app\set_timer 50, (-> seen.heartbeats += 1), 50
    { started: true }

  -- Blocks one script, redirects another, adds a header to everything else.
  window\on_request (request) ->
    seen.request_shape or= type(request) == "table" and type(request.url)
    table.insert seen.requests, request.url

    return { cancel: true } if request.url\match "blocked%.js$"
    return { redirect: "neutrino://app/redirected.js" } if request.url\match "toredirect%.js$"

    { headers: { ["X-Neutrino"]: "intercepted" } }

  window\on_context_menu (params, win) ->
    seen.menu_params = params
    seen.menu_window = win
    {
      { label: "Test", action: -> seen.menu_action_ran = true }
      { type: "separator" }
      { label: "Sub", items: { { label: "Nested", action: -> nil } } }
    }

  -- Refuses the first close, allows the second.
  window\on_close_request ->
    return true if seen.veto_used
    seen.veto_used = true
    false

  -- ═════════════════════════════════════════════════════════════════════════

  t.task "browser suite", ->
    -- "ready" only means the browser process exists; the document is not parsed
    -- until did-finish-load. That also fires for the blank document a browser
    -- starts on, so the URL is what says which one this is.
    t.wait_for window, "did-finish-load", (detail) ->
      detail.url and detail.url\match "^neutrino://app/"

    -- JSON.stringify(undefined) arrives as null, so "not set yet" and "set to
    -- null" are indistinguishable. Nothing here ever sets anything to null.
    settled = (expression) ->
      t.wait_until -> (window\eval expression) != json.null

    t.section "Evaluating in the page"

    -- The page came from the Lua router over neutrino://. Reaching an element
    -- by id also proves the response was parsed as HTML rather than shown as
    -- escaped source, which is what a malformed content type produces.
    text, err = window\eval "document.getElementById('hello').textContent"
    t.check "a DOM value comes back", text == "hi", err or tostring text

    structured, err = window\eval "[1, 'two', { three: 3 }]"
    t.check "a nested structure comes back",
      structured and structured[3].three == 3, err

    -- Proves the scheme answers fetch(), not only navigation.
    _, err = window\eval(
      "fetch('neutrino://app/api/echo/abc').then(r => r.json()).then(j => j.upper)")
    t.check "a promise is serialised rather than failing", err == nil, err

    bridged, err = window\eval "typeof window.neutrino === 'object' &&
      typeof window.neutrino.invoke === 'function'"
    t.check "the bridge is installed in the page", bridged == true, err

    -- A script that throws has to report the error, not a value.
    broken, err = window\eval "this.does.not.exist"
    t.check "a failing script reports an error",
      broken == nil and type(err) == "string", err

    t.section "IPC"

    window\exec_js "window.neutrino.invoke('add', { a: 2, b: 3 })
      .then(r => { window.__ipc = r.sum })
      .catch(e => { window.__ipc = 'ERR: ' + e.message })"

    t.check "the page reaches Lua and gets its answer",
      (settled "window.__ipc") and (window\eval "window.__ipc") == 5,
      window\eval "window.__ipc"

    window\exec_js "window.neutrino.invoke('chained')
      .then(r => { window.__chained = (r === null) ? 'null' : typeof r })
      .catch(e => { window.__chained = 'REJECTED' })"

    t.check "an unserialisable reply answers null rather than rejecting",
      (settled "window.__chained") and (window\eval "window.__chained") == "null",
      window\eval "window.__chained"

    -- The other direction: Lua pushes, the page receives through neutrino.on.
    window\exec_js "window.neutrino.on('greet', p => { window.__push = p.hello })"
    window\send "greet", { hello: "world" }

    t.check "Lua pushes an event to the page",
      (settled "window.__push") and (window\eval "window.__push") == "world",
      window\eval "window.__push"

    t.section "Context menu"

    -- An injected right click does not raise the menu on a windowed browser:
    -- that menu is driven by the real window's input, not by events fed to the
    -- renderer. The building half is exercised directly instead.
    window\focus!
    window\click 40, 40

    encoded = window\_handle_context_menu {
      x: 10, y: 20, selectionText: "", pageUrl: "neutrino://app/"
    }
    t.check "the builder produces JSON", type(encoded) == "string"

    -- The builder must receive the params first and the window second.
    -- MoonScript turns `@field args` into a colon call, which silently shifts
    -- every argument along by one; this is what catches that.
    t.check "the builder receives the params first",
      seen.menu_params and seen.menu_params.x == 10, type seen.menu_params
    t.check "the builder receives the window second", seen.menu_window == window

    if type(encoded) == "string"
      items = json.decode encoded
      t.check "the items keep their order and count", #items == 3, tostring #items
      t.check "an item carries a generated id",
        items[1].label == "Test" and type(items[1].id) == "string"
      t.check "a separator survives", items[2].type == "separator"
      t.check "a submenu stays nested",
        items[3].items and items[3].items[1].label == "Nested"

      window\_handle_menu_command items[1].id
      t.check "choosing an item runs its action", seen.menu_action_ran

    t.section "Request interception"

    t.check "the interceptor receives the request first",
      seen.request_shape == "string", tostring seen.request_shape

    window\exec_js "
      for (const src of ['blocked.js', 'toredirect.js', 'allowed.js']) {
        const s = document.createElement('script')
        s.src = 'neutrino://app/' + src
        document.head.appendChild(s)
      }
      window.__scripts_added = true"

    -- The three scripts settle at different times; waiting for the two that
    -- should arrive is what makes the blocked one meaningful.
    t.wait_until -> (window\eval "!!window.__redirected") == true and
      (window\eval "!!window.__allowed") == true

    t.check "a blocked request never loads",
      (window\eval "!!window.__blocked") == false
    t.check "and never reaches the router", not seen.blocked_route_hit
    t.check "a redirected request loads the target",
      (window\eval "!!window.__redirected") == true
    t.check "an uninvolved request still loads",
      (window\eval "!!window.__allowed") == true
    t.check "the interceptor saw the requests", #seen.requests > 0,
      "#{#seen.requests} seen"

    t.section "Downloads"

    -- A file dialog is a modal OS window: opening one here would hang the run
    -- waiting for a person, so it stays a manual check. What can be tested is
    -- that stale ids are inert, since ids go stale constantly in real use.
    window\cancel_download 999999
    window\pause_download 999999
    window\resume_download 999999
    t.check "a stale download id is inert", true

    t.section "Waiting without blocking"

    window\exec_js "window.neutrino.invoke('start-heartbeat')"

    -- Both of these wait on the Lua side. If waiting blocked the message pump,
    -- neither would come back and the heartbeat would not tick.
    window\exec_js "
      window.__t0 = Date.now()
      Promise.all([
        neutrino.invoke('slow-add', { a: 20, b: 22 }),
        fetch('neutrino://app/api/slow').then(r => r.json())
      ]).then(([ipc, http]) => {
        window.__async = { sum: ipc.sum, deferred: ipc.deferred,
                           waited: http.waited, ms: Date.now() - window.__t0 }
      }).catch(e => { window.__async = { error: e.message } })"

    settled "window.__async"
    result = window\eval "window.__async"
    describe = -> result and (result.error or json.encode result) or "no result"

    t.check "an IPC handler that waits still answers",
      result and result.sum == 42 and result.deferred, describe!
    t.check "a route that waits still answers", result and result.waited == true,
      describe!

    -- Both waited at once, so the total is nearer the slower of them (250 ms)
    -- than their sum (450 ms).
    t.check "the two waits overlapped rather than queueing",
      result and result.ms and result.ms < 420,
      result and tostring result.ms or "no timing"

    -- The timer ticks every 50 ms and the waits above take about 450 ms, so
    -- anything close to zero means the loop stopped turning.
    t.check "the loop kept running throughout", seen.heartbeats >= 4,
      "#{seen.heartbeats} heartbeats"

    t.section "Closing"

    window\close!
    async.sleep 250
    t.check "the first close is refused by the guard",
      seen.veto_used and not seen.closed

    window\close!
    t.check "the second close goes through", t.wait_until -> seen.closed
    t.check "the window reports itself closed", window.closed

    -- Unregistration happens after the event is delivered.
    t.check "and is no longer registered",
      t.wait_until -> Neutrino.bridge.window(window.id) == nil

    t.done!
    app\quit!

app\run!
t.finish!
