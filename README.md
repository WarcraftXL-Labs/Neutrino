# Neutrino

A desktop application framework built on CEF (Chromium Embedded Framework) and
LuaJIT. The UI is a web page; the application logic is Lua. Same shape as
Electron, with Lua in place of Node.

Part of **WarcraftXL Labs**. Neutrino exists so the tools built on top of it do
not each have to solve windowing, IPC and asset serving again.

Windows only at present.

## How it fits together

```
  luajit.exe
      |
      |  FFI
      v
  neutrinocef.dll  ──────────►  libcef.dll
      |                              |
      |  spawns                      |
      v                              v
  neutrinocef_helper.exe      renderer / GPU / utility processes
```

`neutrinocef.dll` is a C++ layer exposing a flat C API to LuaJIT. The Lua side
never touches CEF types directly; it works with window ids and events.

### Threading

CEF owns the message loop and runs it on the thread that called `App:init()`,
which makes that thread both the CEF UI thread and the Lua thread. Every
callback the framework hands you — an IPC request, a close request, a page
event — arrives there, on the thread that owns the Lua state.

The alternative, `external_message_pump`, hands the loop to the application and
with it the responsibility for dispatching the Win32 queue, re-entrancy and
modal loops. CEF documents that mode as not recommended, and it is work
Chromium already does correctly.

This buys simplicity: no locks, no marshalling, and IPC handlers can answer
synchronously. It costs what the same arrangement costs Electron: a handler
that *blocks* for a long time blocks the UI.

Waiting, though, is not blocking. Handlers run as coroutines, so a route or an
IPC handler can await a file read or a worker job and the loop keeps pumping
underneath it. See **Waiting without blocking** below.

The one place CEF does not cooperate is the scheme handler, which it calls on
the IO thread. That request is posted to the UI thread before it reaches Lua.

### Windowing

Windows are built with CEF's Views framework (`CefWindow` + `CefBrowserView`)
rather than raw Win32. Geometry is therefore in density independent pixels and
behaves correctly at any display scale, and the code has a path to other
platforms if that ever matters. `BrowserWindow:get_native_handle()` returns the
HWND when something genuinely needs Win32.

Any number of windows can exist at once. Each has its own id, its own IPC
handlers and its own events. Popups opened by `window.open()` are adopted into
the framework rather than escaping it.

### The custom scheme

Pages are served from Lua over `neutrino://`, handled in C++ and routed in Lua.
Nothing listens on a TCP port, so there is no firewall prompt and no local
socket for another process to connect to.

Each host is a separate origin with its own routes, so modules can own
`neutrino://mpq/` without colliding with `neutrino://app/`.

## Getting started

You need git, CMake and the Visual Studio C++ build tools. Everything else is
fetched.

```powershell
.\tools\get-deps.ps1       # CEF, LuaJIT, LuaRocks and the rocks. Once, and slow.
.\tools\build-native.ps1   # the C++ layer
.\tools\build.ps1          # MoonScript to dist/, plus the CEF runtime
.\tools\run.ps1 app.lua    # runs a built script from dist/
.\tools\test.ps1           # every suite
```

`deps/` is not in the repository. `get-deps.ps1` downloads the CEF binary
distribution, builds LuaJIT from source - it publishes no Windows binaries -
and compiles the rocks against it. It is pinned to exact versions and skips
whatever is already there, so re-running it is cheap.

Use `tools\run.ps1` rather than calling `luajit.exe` directly: it sets
`LUA_PATH` and `LUA_CPATH` explicitly, so a machine-wide LuaRocks installation
cannot shadow the vendored modules.

## A minimal application

```moon
Neutrino = require "neutrino"

Neutrino.cef.setup "bin"

app = Neutrino.App {
  resources_path: "bin"
  locales_path: "bin/locales"
  subprocess_path: "bin/neutrinocef_helper.exe"
}

server = Neutrino.Server!
server.router\get "/", (req, res) ->
  res\html "<h1>Hello</h1><button onclick='neutrino.invoke(\"greet\")'>Go</button>"

app\on "ready", ->
  win = Neutrino.BrowserWindow {
    title: "Example"
    url: "neutrino://app/"
    width: 900
    height: 600
  }

  -- JS calls Lua; the return value resolves the promise on the page.
  win\handle "greet", (payload) -> { message: "hello from Lua" }

  -- Lua pushes to the page; JS receives it via neutrino.on("progress").
  win\send "progress", { percent: 42 }

  -- Read a value back out of the page.
  win\eval "document.title", (value, err) -> print value

app\run!
```

On the page:

```js
neutrino.invoke("greet", { any: "payload" }).then(reply => ...)
neutrino.on("progress", data => ...)
```

Payloads are JSON-encoded in both directions.

A handler with nothing to report should end in `nil`. MoonScript returns the
last expression and the window methods are chainable, so a handler written as a
single call returns the window object, which cannot be JSON-encoded:

```moon
-- Returns the window. Neutrino warns and replies null.
win\handle "minimise", -> win\minimize!

-- Says what it means.
win\handle "minimise", ->
  win\minimize!
  nil
```

## Waiting without blocking

Route handlers and IPC handlers run as tasks, so they may await. The request or
the promise stays open, and the message pump keeps running:

```moon
async = Neutrino.async

server.router\get "/archive/:name", (req, res) ->
  -- Suspends this handler. Other requests, input and painting carry on.
  contents = async.await (resolve) ->
    luv.fs_readFile "data/#{req.params.name}", (err, data) -> resolve data

  res\json { size: #contents }

win\handle "scan", (payload) ->
  async.sleep 200              -- a delay, not a freeze
  { done: true }
```

A handler that returns without awaiting is answered inline, exactly as before;
nothing pays for the machinery it does not use.

For work that actually saturates a core — parsing a large archive, hashing —
use `async.work`, which runs the function on a libuv worker thread with its own
Lua state and awaits the result:

```moon
size = async.work (path) ->
  file = io.open path, "rb"
  data = file\read "*a"
  file\close!
  #data
, "big.mpq"
```

The function must be self-contained: no upvalues, and primitive arguments and
results only, because it is compiled into a separate Lua state.

## Sessions and cookies

A session is an isolated set of cookies, cache and local storage - Electron's
`session`, and CEF's `CefRequestContext` underneath. A window joins one by name:

```moon
win = Neutrino.BrowserWindow { url: "...", partition: "persist:account-a" }
other = Neutrino.BrowserWindow { url: "...", partition: "persist:account-b" }
```

Those two windows can be logged into the same site as different users, because
they share nothing. The naming follows Electron's, since it is the one you
already know:

| name | where it lives |
| :--- | :--- |
| `""` (the default) | the application's own cache directory |
| `"persist:name"` | on disk, under `<cache_path>/partition-name` |
| `"name"` | in memory, gone when the process exits |

Every session call is asynchronous. Inside a task it is awaited and returns its
result; outside one, pass a callback. A failure comes back as `nil, message`
rather than raising:

```moon
Neutrino.async.run ->
  s = win\session!

  s\set_cookie {
    url: "https://example.com"
    name: "token"
    value: token
    httpOnly: true
    expires: os.time! + 86400      -- seconds since the Unix epoch; omit for a
  }                                -- session cookie

  for cookie in *s\get_cookies "https://example.com"
    print cookie.name, cookie.value

  s\remove_cookies "https://example.com", "token"
  s\flush_cookies!                 -- returns once the store is on disk
```

Also on a session: `clear_cache`, `clear_auth`, `close_connections`, and
`set_color_scheme "dark"` for Chrome-style windows.

`s\info!` reports what the partition actually resolved to. It is worth checking
when a `persist:` partition does not seem to remember anything: with no
`cache_path` on the `App` there is nowhere to persist to, and the session falls
back to memory.

## Modules

Nothing above this point needed a module, and that is deliberate: a window and a
few routes are a complete application. A module is what you reach for when one
application holds several tools that should not know about each other.

A module claims a name, and the name is the boundary:

| what it claims | from the name `mpq` |
| :--- | :--- |
| its origin | `neutrino://mpq/`, and no other routes |
| its IPC channels | `mpq:open`, `mpq:close`, … |
| its session | `persist:mpq`, if it asks for one |

```moon
class Mpq extends Neutrino.Module
  name: "mpq"
  partition: true                  -- persist:mpq

  routes: (router) =>
    router\get "/", (req, res) -> res\html PAGE
    router\get "/entry/:id", (req, res) -> res\json @read req.params.id

  on_ready: =>
    @handle "open", (payload) -> @open_archive payload.path
    @window = @open title: "Archives"

app\register_module Mpq
```

`@open` creates a window on the module's own origin, in its own partition, with
its handlers installed. `@handle "open"` answers `neutrino.invoke("mpq:open")`
from the page, and `@broadcast "changed", detail` pushes to
`neutrino.on("mpq:changed")`. `@attach window` installs the same handlers on a
window the module did not open, which is how one shell window hosts several
modules at once.

Two shapes are supported, and they mix. A module owns its window, or several
modules share one:

```moon
app\on "ready", ->
  shell = Neutrino.BrowserWindow { url: "neutrino://app/", width: 1280 }
  mod\attach shell for mod in *app.modules
```

A window has exactly one partition, so a module attached to a window it does not
own stores through *that* window's session whatever it declared. `attach` warns
when the two differ; per-module isolation is only real when the module opens its
own window.

The boundary is real rather than a convention, so a module can be taken back
down while the application runs:

```moon
app\unregister_module "mpq"
```

That drops its routes, removes its handlers from every window it reached,
cancels the timers it started with `@set_timer`, and closes the windows it
opened. Windows it was merely attached to stay open, minus its handlers.

### Routes without a browser

`server\fetch` runs a request through the routers and hands the reply back to
Lua. Same handlers, same parameters, same deferred replies - the answer goes to
you instead of to CEF:

```moon
reply = server\fetch "neutrino://mpq/entry/42"
print reply.status, reply.mime, #reply.body
```

A route is then testable without a window, a page's content can be computed
before the window that will show it exists, and one module can consume another's
output without knowing it is a module:

```moon
routes: (router) =>
  router\get "/dashboard", (req, res) ->
    res\html @render (@fetch "neutrino://mpq/summary").body
```

Inside a task it is awaited; outside one, pass a callback.

## State and the page

Lua owns the data. The page owns what is on screen. `ui.State` is the channel
between them, and there is nothing else in the middle - no template engine, no
virtual DOM, nothing that re-renders a document.

```moon
ui = Neutrino.ui

server.router\get "/", (req, res) ->
  res\html ui.document {
    title: "Counter"
    state: { count: 0 }
    body: "<button data-on-click='count++'>+</button>
           <span data-text='count'></span>"
  }

app\on "ready", ->
  window = Neutrino.BrowserWindow url: "neutrino://app/"
  state = ui.State window, { count: 0 }

  state\set "count", 5                     -- the span updates
  state\on "count", (value, source) ->     -- source is "page" or "lua"
    print "count is now #{value}"
```

`ui.document` inlines the initial state and the runtime, so the first paint
already has its values - there is no flash of an empty interface and no push to
wait for. Paths are dotted: `state\set "user.name", "…"` reaches into a table
without replacing it, and `nil` removes a key rather than storing a null.

The directives the runtime understands, all of them plain attributes:

| attribute | effect |
| :--- | :--- |
| `data-text="expr"` | `textContent` |
| `data-html="expr"` | `innerHTML` |
| `data-show="expr"` | hides the element when falsy |
| `data-model="path"` | two-way, for inputs and checkboxes |
| `data-attr-<name>="expr"` | sets the attribute, or removes it when falsy |
| `data-class-<name>="expr"` | toggles the class |
| `data-on-<event>="stmt"` | a listener; `$el` and `$event` are in scope |
| `data-for="item in expr"` | repeats its `<template>` child, once per element |

Expressions are ordinary JavaScript over the store, so `count + 1`, `user.name`
and `items.length` all work. Anything the store does not declare falls through
to normal scope, which is why `Math` and `JSON` are still reachable.

`data-for` names the row, and the name is in scope for everything inside it:

```html
<ul data-for="file, index in files">
  <template>
    <li data-text="index + ': ' + file.name"></li>
  </template>
</ul>
```

One caveat that has nothing to do with the browser: Lua cannot tell an empty
list from an empty map, so an empty table encodes as `{}` and the page receives
an object. `json.array` says which it is.

```moon
state\set "files", Neutrino.json.array {}       -- [] rather than {}
```

Underneath, `window.nui` exposes `signal`, `effect`, `state`, `get`, `set`,
`bind(root)` and `html(el, markup)` for code that would rather write its own.
`bind` descends into shadow roots; `html` replaces an element's content and
wires what arrived, which plain `innerHTML` cannot do - it drops a declarative
shadow root without a word.

Reactivity is per top-level key: writing `tree.nodes[3].open` re-runs every
effect that read `tree`. That is coarse on purpose. For a tool's interface it is
enough, and the alternative is a proxy per node and a great deal more of it to
get wrong.

## Widgets

A widget is markup and the style that belongs to it, travelling together. It
renders to a custom element carrying a declarative shadow root, so the browser
scopes the style itself: nothing leaks out of a widget, and the page's own CSS
does not reach in.

```moon
class Card extends Neutrino.ui.Widget
  tag: "n-card"
  defaults: { title: "" }

  style: [[
    .card { border: 1px solid var(--n-border, #333); padding: 12px }
  ]]

  template: [[
    <div class="card">
      <h2><%= title %></h2>
      <slot></slot>
    </div>
  ]]

card = Card { title: "Archives", children: { button } }
res\html ui.document { body: cardender! }
```

Templates are [etlua](https://github.com/leafo/etlua): `<%= value %>` inserts it
**escaped**, `<%- value %>` raw, `<% code %>` runs Lua. Escaping is the default,
which is the right way round - an archive's filename is not markup and should
never be treated as any.

Children go in the light DOM and `<slot>` picks them up, so a parent needs to
know nothing about them.

`Neutrino.ui.widgets` has five to start from and to copy: `Button`, `Panel`,
`Field`, `Text` and `List`. Each styles itself through custom properties with a
fallback, so a page can retheme them without reaching into a shadow root it does
not own.

```moon
w = Neutrino.ui.widgets

w.Panel {
  title: "Archives"
  children: {
    w.List {
      path: "files", as: "file", empty: "No archives"
      children: { w.Text { value: "file.name" } }
    }
    w.Field { label: "Search", path: "query" }
    w.Button { label: "Refresh", action: "nui.set('tick', Date.now())" }
  }
}
```

A `List` is the one that reads differently: its children are the row rather than
the content, and inside them `file` names the current element.


## What is built

The native layer and the Lua API around it:

- multiple windows, each with its own id, handlers and events
- IPC in both directions, plus `eval` that returns the page's value to Lua
- a close guard, so a window can refuse to close
- the `neutrino://` scheme with routes, `:params`, `*` wildcards and per-host
  routers
- frameless windows with draggable regions driven by `-webkit-app-region`
- DevTools, zoom, navigation, display enumeration, window state and geometry
- an event loop that blocks rather than polls, and integrates luv timers
- deferred replies on both the scheme and IPC paths, with coroutine-based
  `await`, and a worker pool for CPU-bound work
- context menus, keyboard accelerators, JS dialogs, file dialogs and downloads
- request interception: block, redirect or rewrite the headers of any request
- sessions: cookies and isolated partitions, on disk or in memory
- modules: a named boundary over routes, IPC and windows, removable at runtime,
  and `server\fetch` to route a request without a browser
- a reactive store shared between Lua and the page, driven by `data-`
  directives, with nothing re-rendering
- widgets: etlua templates rendered into shadow roots, with a small library
- the platform shell: clipboard, opening a file or url with its handler, and a
  single-instance lock that hands a second launch's arguments to the first
- packaging: one folder with one named executable in it

## What is not built yet

Worth being explicit, because the architecture notes describe the intended
shape rather than the current state:

- **CEF handlers still to wire up**: permissions, find-in-page, printing,
  frames, the DevTools protocol, and response *body* filters (request headers
  and redirects are covered).
- **Application-level APIs**: tray icon, native menus, global shortcuts.
- **Widgets that register themselves**: they render as custom elements but
  nothing calls `customElements.define`, so there is no lifecycle and no
  `:defined` styling. Declarative shadow roots do not need it; a widget that
  wants to react to being attached would.

[todo.md](todo.md) is the list of what is left.
[docs/cef-coverage.md](docs/cef-coverage.md) is the longer reading: the whole
CEF surface against what is wired, and why.

## Shipping an application

`dist/` is a development tree. It assumes `luajit.exe`, the repository, and
someone who knows which script to pass. `package.ps1` produces the other thing:

```powershell
.\tools\package.ps1 -Name "MPQBrowser" -Entry "my_app.moon"
```

The result is a folder with one executable in it:

```
MPQBrowser/
  MPQBrowser.exe     the host; runs app/main.lua
  lua51.dll
  app/               the compiled application and the framework
  rocks/             vendored Lua modules
  bin/               neutrinocef.dll and the CEF runtime
```

The host resolves every path from its own location, so the folder can be moved,
renamed, or launched from a shortcut or a file association. An entry point reads
those paths from the framework rather than working them out:

```moon
Neutrino = require "neutrino"

-- The same two lines whether this is running from dist/ or from a package.
Neutrino.cef.setup Neutrino.paths.bin
app = Neutrino.App { cache_path: Neutrino.paths.root .. "/cache", ... }
```

Two things to know. The host is a GUI subsystem binary, so there is no console
and `print` goes nowhere - a packaged application that wants a log has to write
one. And the folder is around 400 MB, almost all of it the CEF runtime.

## Only one copy at a time

A tool opened from a file association is launched again for every file. The
lock turns that into a message to the copy already running:

```moon
shell = Neutrino.shell

unless shell.claim_single_instance "mpq-browser", (args) ->
    window\restore!\focus!
    open_archive args[1] if args[1]
  shell.notify_first_instance "mpq-browser"
  os.exit 0
```

The handler runs on the Lua thread like every other callback, and works before
any window exists - which is the point, since that is when the application is
deciding whether to start at all.

The rest of the shell:

```moon
shell.write_text "9.WarcraftXL"
text = shell.read_text!

shell.open_external "https://github.com"   -- http, https and mailto only
shell.open_path "C:/Games/WoW/Data"        -- anything, including executables
shell.show_in_folder "C:/Games/WoW/Data/patch.mpq"
```

`open_external` refuses anything that is not a url, and says so. That split is
deliberate: the same Win32 call handed a path will run an executable, so a url
that arrived from the page must not be able to reach it. `open_path` is the
caller stating the path is its own.

## Layout

```
native/src/       C++ layer; neutrino_api.h is the contract with Lua
src/core/         the engine: app loop, events, async, timers, modules, the
                  FFI binding and the bridge to it
src/browser/      windows, sessions, displays, key names
src/serve/        the neutrino:// server and its router
src/system/       the OS: clipboard, shell, single instance
src/util/         json, filesystem
src/ui/           the page: reactive state, directives, widgets
tests/            units, shell, module, ui-layer, widgets, browser, session,
                  single-instance
docs/             architecture notes and CEF coverage
tools/            get-deps, build, run, test, package
deps/             fetched, never committed
dist/             development build; wiped and regenerated by build.ps1
build/            packaged applications
```

`native/src/neutrino_api.h` and `src/core/cef.moon` mirror each other.
Change the header first.

One folder per subject rather than one folder for everything: a file's
neighbours should say what it is about. `require "browser.window"` names the
subject, and a new file has an obvious place to go.

## Dependencies

`get-deps.ps1` puts everything under `deps/`, which is not in the repository.
A clone needs git, CMake and a C++ toolchain; nothing else is installed
system-wide.

Versions are pinned in `tools/get-deps.ps1`. A framework that builds against
whatever CEF happened to be current today is one that stops building tomorrow.

To add a Lua package:

```powershell
.\tools\luarocks.ps1 install <rock>
```

Native rocks need the MSVC environment on PATH; run the command from a
Developer Command Prompt, or after `vcvars64.bat`.

`get-deps.ps1` installs `lua-cjson`, `luv`, `moonscript` and `etlua`; the
third pulls in `lpeg`, `lfs` and `argparse`. Add a rock to the `$Rocks` list there rather than
installing it by hand, or the next person to clone will not have it.

## License

MIT. See [LICENSE](LICENSE).
