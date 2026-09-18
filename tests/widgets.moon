-- Widgets: what they render, and what the browser does with it.
--
-- Half of this needs no browser - a widget is a string - and half of it needs
-- one badly, because the whole point is a shadow root and only a browser has
-- those.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\widgets.lua

Neutrino = require "neutrino"
t = require "harness"

async = Neutrino.async
json = Neutrino.json
ui = Neutrino.ui
w = ui.widgets

print "Neutrino: widgets"

t.load_native!

-- ═══════════════════════════════════════════════════════════════════════════
-- Rendering
-- ═══════════════════════════════════════════════════════════════════════════

t.section "Rendering"

button = w.Button { label: "Refresh", action: "nui.set('tick', 1)" }
markup = button\render!

t.check "a widget renders its own element",
  markup\match("^<n%-button ") != nil, markup\sub 1, 40
t.check "with a declarative shadow root",
  markup\match('<template shadowrootmode="open"') != nil
t.check "marked clonable, so a repeated row keeps it",
  markup\match('shadowrootclonable') != nil
t.check "carrying its own style", markup\match("<style>") != nil
t.check "and an id it can be found by", markup\match('id="n%-button%-%d+"') != nil,
  markup\match 'id="[^"]*"'

-- Labels come from data - an archive's filename, a user's note - so escaping is
-- the default and has to actually hold.
dangerous = w.Button { label: "<img src=x onerror=boom>" }
t.check "a value is escaped, not inserted as markup",
  (dangerous\render!)\match("<img") == nil
t.check "and survives as text",
  (dangerous\render!)\match("&lt;img src=x") != nil

-- The action lands in an attribute, so quotes have to come back out intact.
quoted = w.Button { label: "Go", action: "nui.set('a', \"b\")" }
t.check "an action with quotes stays in its attribute",
  (quoted\render!)\match('data%-on%-click="nui.set') != nil,
  (quoted\render!)\match 'data%-on%-click="[^"]*"'

t.section "Composition"

panel = w.Panel { title: "Archives", children: { button } }
composed = panel\render!

t.check "a child renders inside its parent",
  composed\match("<n%-panel.-<n%-button.-</n%-panel>") != nil
t.check "the parent offers a slot for it",
  composed\match("<slot></slot>") != nil

-- A list's children are its row, not its content, so they must not also appear
-- in the light DOM - they would render once outside the repeat.
list = w.List { path: "files", children: { w.Text { value: "file.name" } } }
rendered = list\render!
-- No parentheses around the call: they would truncate gsub to its first
-- return value and the count would be nil.
outside = select 2, rendered\gsub "</template><n%-text", ""

t.check "a list keeps its children in the repeat template", outside == 0,
  "#{outside} escaped the template"
t.check "and declares what to repeat over",
  rendered\match('data%-for="item, index in files"') != nil,
  rendered\match 'data%-for="[^"]*"'

t.check "two widgets never share an id",
  (w.Button!)\render!\match('id="([^"]*)"') !=
    (w.Button!)\render!\match 'id="([^"]*)"'

-- ═══════════════════════════════════════════════════════════════════════════
-- In a page
-- ═══════════════════════════════════════════════════════════════════════════

FILES = {
  { name: "common.mpq", size: 120 }
  { name: "patch.mpq", size: 45 }
}

page = w.Panel {
  title: "Files"
  children: {
    w.List {
      path: "files"
      as: "file"
      empty: "No archives"
      children: { w.Text { value: "file.name" } }
    }
    w.Field { label: "Search", path: "query" }
    w.Button { label: "Go", action: "nui.set('clicked', true)", variant: "primary" }
  }
}

server = Neutrino.Server!

server.router\get "/", (req, res) ->
  res\html ui.document {
    title: "Widgets"
    state: { files: FILES, query: "", clicked: false }
    -- A page rule that would reach a widget if the shadow root were not doing
    -- its job. Nothing in the page should be able to restyle a widget.
    style: "button { color: rgb(1, 2, 3) } body { background: #111 }"
    body: page\render!
  }

-- Fetched and injected by the page, to prove markup that did not come from the
-- parser still becomes a widget.
server.router\get "/late", (req, res) ->
  res\html (w.Panel { title: "Late", children: { w.Button { label: "Late" } } })\render!

app = Neutrino.App t.app_options { quit_on_last_window: false }
t.expect_completion!

app\on "ready", ->
  t.deadline app

  window = Neutrino.BrowserWindow {
    title: "Widgets"
    url: "neutrino://app/"
    width: 640
    height: 480
    show: false
  }

  state = ui.State window, { files: FILES, query: "", clicked: false }

  t.task "widget suite", ->
    t.wait_for window, "did-finish-load", (detail) ->
      detail.url and detail.url\match "^neutrino://app/"

    t.check "the runtime booted", state\ready_then!

    t.section "Shadow roots"

    t.check "a widget has one",
      (window\eval "!!document.querySelector('n-panel').shadowRoot") == true
    t.check "its template rendered into it",
      (window\eval "document.querySelector('n-panel').shadowRoot
        .querySelector('header').textContent.trim()") == "Files",
      window\eval "document.querySelector('n-panel').shadowRoot.innerHTML.length"

    t.section "Style stays where it belongs"

    -- The page says every button is rgb(1, 2, 3). The widget's button must not
    -- hear it, and must still have its own rule.
    colour = window\eval "getComputedStyle(document.querySelector('n-button')
      .shadowRoot.querySelector('button')).color"
    t.check "a page rule does not reach into a widget", colour != "rgb(1, 2, 3)",
      colour

    t.check "and the widget's own rule applies",
      (window\eval "getComputedStyle(document.querySelector('n-button')
        .shadowRoot.querySelector('button')).cursor") == "pointer"

    t.section "Repeating"

    rows = -> window\eval "document.querySelector('n-list').shadowRoot
      .querySelectorAll('.rows > n-text').length"

    t.check "a row appears per item", rows! == 2, tostring rows!

    -- The one that is easy to get wrong. Chromium turns the row template's
    -- declarative shadow roots into real ones even inside template content, and
    -- cloneNode drops a shadow root unless it was marked clonable - so a widget
    -- in a row would come out empty and unstyled, with nothing reported.
    t.check "a widget inside a row keeps its shadow root",
      (window\eval "!!document.querySelector('n-list').shadowRoot
        .querySelector('n-text').shadowRoot") == true

    t.check "and reads the row's own names",
      (window\eval "document.querySelector('n-list').shadowRoot
        .querySelector('n-text').shadowRoot.querySelector('span').textContent") ==
        "common.mpq",
      window\eval "document.querySelector('n-list').shadowRoot
        .querySelector('n-text').shadowRoot.querySelector('span').textContent"

    state\set "files", { { name: "a.mpq" }, { name: "b.mpq" }, { name: "c.mpq" } }
    t.check "adding an item adds a row", (t.wait_until -> rows! == 3), tostring rows!

    -- An empty Lua table encodes as {} rather than [], which is why json.array
    -- exists and why the empty condition does not simply read .length.
    state\set "files", json.array {}
    t.check "emptying the list removes every row",
      (t.wait_until -> rows! == 0), tostring rows!
    t.check "and shows what stands in for them",
      (t.wait_until ->
        (window\eval "document.querySelector('n-list').shadowRoot
          .querySelector('.empty').hidden") == false)

    t.section "Widgets that talk back"

    window\exec_js "document.querySelector('n-button').shadowRoot
      .querySelector('button').click()"
    t.check "a button's action reaches Lua",
      (t.wait_until -> (state\get "clicked") == true), tostring state\get "clicked"

    window\exec_js "const input = document.querySelector('n-field').shadowRoot
        .querySelector('input')
      input.value = 'patch'
      input.dispatchEvent(new Event('input'))"
    t.check "a field writes to the store",
      (t.wait_until -> (state\get "query") == "patch"), tostring state\get "query"

    state\set "query", "from lua"
    t.check "and reads back from it",
      (t.wait_until ->
        (window\eval "document.querySelector('n-field').shadowRoot
          .querySelector('input').value") == "from lua")

    t.section "Markup that arrives later"

    -- innerHTML drops a declarative shadow root without a word; nui.html does
    -- not, which is the only reason a fetched widget works at all.
    window\exec_js "document.body.insertAdjacentHTML('beforeend',
      '<div id=\"late\"></div>')
      fetch('neutrino://app/late').then(r => r.text()).then(html => {
        nui.html(document.getElementById('late'), html)
      })"

    t.check "an injected widget gets its shadow root",
      (t.wait_until ->
        (window\eval "!!(document.querySelector('#late n-panel') &&
          document.querySelector('#late n-panel').shadowRoot)") == true)

    t.check "and so does the widget inside it",
      (window\eval "!!document.querySelector('#late n-button').shadowRoot") == true

    window\close true

    t.done!
    app\quit!

app\run!
t.finish!
