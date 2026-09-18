-- The UI layer: one store, two sides.
--
-- Every check here drives a real page, because the only thing worth asserting
-- about a reactive runtime is that the DOM actually changed - and the only
-- thing worth asserting about the bridge is that Lua actually heard.
--
-- Named ui-layer rather than ui because the suites compile into dist/ beside
-- the packages, and a dist/ui.lua would shadow dist/ui/init.lua.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\ui-layer.lua

Neutrino = require "neutrino"
t = require "harness"

async = Neutrino.async
json = Neutrino.json
ui = Neutrino.ui

print "Neutrino: ui"

t.load_native!

-- ═══════════════════════════════════════════════════════════════════════════
-- Building a document
-- ═══════════════════════════════════════════════════════════════════════════

t.section "Documents"

-- No browser needed for these: they are string handling, and string handling
-- around markup is where the injection bugs live.
plain = ui.document { title: "Plain", body: "<p>hi</p>" }

t.check "a document carries a doctype", plain\match("^<!doctype html>") != nil
t.check "and the body as written", plain\match("<p>hi</p>") != nil
t.check "and the runtime", plain\match("window%.nui") != nil
t.check "the runtime can be left out",
  (ui.document { runtime: false })\match("window%.nui") == nil

escaped = ui.document { title: '<script>alert("x")</script>' }
t.check "a title cannot open a tag", escaped\match("<title>&lt;script&gt;") != nil,
  escaped\match "<title>[^<]*"

-- A string in the initial state is the obvious way to smuggle markup in, since
-- it is written straight into a script element.
smuggled = ui.document { state: { note: "</script><img src=x onerror=boom>" } }
-- Up to the closing tag, not to the end of the line: that tag is the script
-- element's own, and counting it would make the check pass for the wrong side.
inlined = smuggled\match "window%.__NEUTRINO_STATE__=(.-)</script>"

-- Checked as "no angle bracket survives" rather than against a particular
-- escape, because cjson escapes "/" as well and the exact spelling of the
-- output is not the point.
t.check "state cannot open or close a tag",
  inlined and (inlined\find "<", 1, true) == nil, inlined
t.check "and is escaped rather than dropped",
  inlined and (inlined\find "\\u003c", 1, true) != nil, inlined

t.check "escape covers the five characters that matter",
  (ui.escape "<a href=\"x\">&'") == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;",
  ui.escape "<a href=\"x\">&'"

-- ═══════════════════════════════════════════════════════════════════════════
-- A page driven from both ends
-- ═══════════════════════════════════════════════════════════════════════════

BODY = [[
  <p id="count" data-text="count"></p>
  <p id="name" data-text="user.name"></p>
  <p id="banner" data-show="flag">visible</p>
  <p id="tag" data-class-active="flag"></p>
  <a id="link" data-attr-href="'neutrino://app/' + count"></a>
  <button id="inc" data-on-click="count = count + 1">+</button>
  <input id="note" data-model="note">
]]

server = Neutrino.Server!
server.router\get "/", (req, res) ->
  res\html ui.document {
    title: "UI suite"
    state: { count: 1, user: { name: "thor" }, flag: true, note: "" }
    body: BODY
  }

app = Neutrino.App t.app_options { quit_on_last_window: false }
t.expect_completion!

app\on "ready", ->
  t.deadline app

  window = Neutrino.BrowserWindow {
    title: "UI suite"
    url: "neutrino://app/"
    width: 520
    height: 400
    show: false
  }

  state = ui.State window, { count: 1, user: { name: "thor" }, flag: true, note: "" }

  -- Recorded by the listeners, read by the checks.
  heard = { count: nil, source: nil, user: nil }

  state\on "count", (value, source) ->
    heard.count = value
    heard.source = source

  -- A listener on a parent path hears about a change to a leaf under it.
  state\on "user", (value) -> heard.user = value

  t.task "ui suite", ->
    t.wait_for window, "did-finish-load", (detail) ->
      detail.url and detail.url\match "^neutrino://app/"

    text = (id) -> window\eval "document.getElementById('#{id}').textContent"

    t.section "The page starts from the state Lua inlined"

    t.check "the runtime booted", state\ready_then!
    t.check "a value renders", (text "count") == "1", text "count"
    t.check "a nested value renders", (text "name") == "thor", text "name"
    t.check "the store only declares what it was given",
      (window\eval "Object.keys(nui.state).sort().join(',')") ==
        "count,flag,note,user",
      window\eval "Object.keys(nui.state).sort().join(',')"

    t.section "Lua writes, the page follows"

    state\set "count", 7
    t.check "a scalar reaches the page",
      (t.wait_until -> (text "count") == "7"), text "count"

    t.check "an attribute directive follows it",
      (window\eval "document.getElementById('link').getAttribute('href')") ==
        "neutrino://app/7",
      window\eval "document.getElementById('link').getAttribute('href')"

    state\set "user.name", "iThorgrim"
    t.check "a dotted path reaches into a table",
      (t.wait_until -> (text "name") == "iThorgrim"), text "name"
    t.check "and leaves the rest of the branch alone",
      (window\eval "JSON.stringify(nui.get('user'))") == '{"name":"iThorgrim"}',
      window\eval "JSON.stringify(nui.get('user'))"

    state\set "flag", false
    t.check "data-show hides an element",
      t.wait_until -> (window\eval "document.getElementById('banner').hidden") == true
    t.check "data-class drops the class",
      (window\eval "document.getElementById('tag').classList.contains('active')") == false

    state\set "flag", true
    t.check "and puts it back",
      t.wait_until ->
        (window\eval "document.getElementById('tag').classList.contains('active')") == true

    t.section "The page writes, Lua follows"

    window\exec_js "document.getElementById('inc').click()"

    t.check "a click reaches Lua",
      (t.wait_until -> (state\get "count") == 8), tostring state\get "count"
    t.check "the listener was told", heard.count == 8, tostring heard.count
    t.check "and told which side changed it", heard.source == "page", heard.source

    -- The echo is what a naive bridge gets wrong: Lua applies the page's write
    -- and pushes it straight back. Counting the pushes that arrive is the only
    -- way to see it, because the page already holds that value - an echo would
    -- land silently, change nothing on screen, and cost a round trip per
    -- keystroke.
    window\exec_js "window.__pushes = 0
      neutrino.on('ui:state', () => { window.__pushes++ })"

    window\exec_js "document.getElementById('inc').click()"
    t.check "the page reaches 9 as well", (t.wait_until -> (state\get "count") == 9)
    async.sleep 150

    t.check "a page write is not echoed back to it",
      (window\eval "window.__pushes") == 0,
      "#{window\eval "window.__pushes"} arrived"

    -- And the counter is not simply blind: a write from Lua does arrive. This
    -- is the half that makes the one above mean something.
    state\set "count", 11
    t.check "while a write from Lua does arrive",
      (t.wait_until -> (window\eval "window.__pushes") == 1),
      "#{window\eval "window.__pushes"} arrived"

    t.section "Running without an element"

    -- What a keyboard shortcut needs: the evaluation a directive gets, with the
    -- store in scope, from code that is attached to nothing.
    t.check "an expression reads the store",
      (window\eval "nui.evaluate('count + 1')") == 12,
      window\eval "nui.evaluate('count + 1')"

    window\exec_js "nui.run('count = count * 2')"
    t.check "a statement writes to it, and Lua hears",
      (t.wait_until -> (state\get "count") == 22), tostring state\get "count"

    t.check "and a scope of its own is in reach as well",
      (window\eval "nui.evaluate('row.name', { row: { name: 'mpq' } })") == "mpq",
      window\eval "nui.evaluate('row.name', { row: { name: 'mpq' } })"

    t.section "Two-way inputs"

    window\exec_js "const note = document.getElementById('note')
      note.value = 'typed'
      note.dispatchEvent(new Event('input'))"

    t.check "typing reaches Lua",
      (t.wait_until -> (state\get "note") == "typed"), tostring state\get "note"

    state\set "note", "from lua"
    t.check "and Lua reaches the input",
      (t.wait_until ->
        (window\eval "document.getElementById('note').value") == "from lua"),
      window\eval "document.getElementById('note').value"

    t.section "Listeners"

    t.check "a listener on a parent path hears a leaf change",
      heard.user and heard.user.name == "iThorgrim",
      heard.user and json.encode heard.user

    -- A raise in one listener must not take the others with it, nor the query
    -- the page is waiting on.
    state\on "count", -> error "deliberate"
    state\set "count", 10
    t.check "a listener that raises does not stop the rest",
      (state\get "count") == 10 and heard.count == 10, tostring heard.count

    t.section "Removing"

    state\set "user.name", nil
    t.check "nil removes a key rather than storing a null",
      (state\get "user.name") == nil
    t.check "and the page agrees",
      (t.wait_until ->
        (window\eval "JSON.stringify(nui.get('user'))") == "{}"),
      window\eval "JSON.stringify(nui.get('user'))"

    window\close true

    t.done!
    app\quit!

app\run!
t.finish!
