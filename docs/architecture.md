# Neutrino — architecture notes

Why the framework is put together the way it is. For what it does and how to
use it, see [README.md](README.md).

## The message loop

This is the decision everything else follows from.

CEF offers three ways to run its message loop. Neutrino uses
`CefRunMessageLoop`: CEF takes the thread that called `CefInitialize` and runs
the loop on it until `CefQuitMessageLoop`. Chromium dispatches the Win32 queue,
services its own tasks, and calls back into Neutrino on that same thread.

`multi_threaded_message_loop` was rejected on principle. It keeps Chromium's UI
responsive independently of the application, but delivers every callback on a
CEF-owned thread. LuaJIT has one `lua_State` that may only be used from one
thread at a time, so those callbacks would need marshalling through a queue,
and every IPC call would become asynchronous.

`external_message_pump` was rejected by experience. Neutrino was built on it
first: CEF owns no thread, calls `OnScheduleMessagePumpWork(delay)` when it
needs attention, and the application calls `CefDoMessageLoopWork()` from a loop
of its own. It looked elegant, and the window it produced could not be clicked.

`CefDoMessageLoopWork()` does not dispatch the Win32 queue, so nothing routed
mouse and keyboard input to the window. Getting that right means owning message
dispatch, re-entrancy and modal loops — work Chromium already does correctly,
and which CEF's own documentation calls "not recommended for most users".
Moving to `CefRunMessageLoop` deleted more code than it added.

Whichever mode, the property the rest of the design rests on is the same: the
thread calling `CefInitialize` *is* the CEF UI thread, and it is the Lua thread,
so:

- callbacks run where the Lua state lives; nothing needs locking
- an IPC handler can compute its answer and return it inline, no task hop
- `CanClose` can ask Lua for a veto synchronously, which is what makes an
  "unsaved changes" prompt expressible at all

The trade is the familiar one: a Lua handler that blocks blocks the UI, exactly
as a blocking handler in Electron's main process does. Waiting is handled
separately, and does not block - see **Deferred replies** below.

### Timers and luv

Timers are `CefPostDelayedTask` on the UI thread. A delayed task posted to the
loop that is already running *is* a timer, so there is no second event loop and
nothing to integrate between two of them.

luv is pumped only while `async.work` has a job in flight. Anything else built
on luv — `uv.spawn`, a filesystem watcher, a socket — has to pump for itself, or
its callbacks never fire. That is a gap, and it is in `todo.md`.

### What CEF does not deliver on the UI thread

Each of these is marshalled back before Lua sees it:

- `CefResourceHandler::Open`, for the custom scheme, runs on the IO thread. It
  captures the request, reports that it will answer later, and posts.
- `CefResourceRequestHandler`, for request interception, likewise. That round
  trip is why the handler is only attached once an application registers an
  interceptor: one that does not intercept should pay nothing.
- Cookies are the exception that needs nothing. CEF 152 visits them on the UI
  thread and fires the session completion callbacks there too.

## Windowing: CEF Views

Windows use `CefWindow` and `CefBrowserView` rather than a raw `HWND` with
`SetAsPopup`.

Raw Win32 means owning the non-client area by hand: `WM_NCCALCSIZE` and
`WM_NCHITTEST` for frameless windows, per-monitor DPI, snap behaviour, and
monitor enumeration. Views already handles all of it, reports geometry in
density independent pixels, and keeps the door open to other platforms.

Windows are created with Alloy runtime style, which provides the client
callbacks an application framework needs — draggable regions, context menu and
keyboard control — without Chrome's browser UI. Chrome style is available per
window via the `chrome_style` option.

Frameless windows get their draggable title bar from
`CefDragHandler::OnDraggableRegionsChanged`, which is forwarded to
`CefWindow::SetDraggableRegions`. The page marks regions with
`-webkit-app-region: drag`, the same contract as Electron, and resize borders
and window snapping keep working.

## Window identity

Every managed window is a registry entry with an integer id. The C API is
`neutrino_window_*(id, ...)`, and ids are the only window handle Lua ever sees.

The registry lives on the UI thread and is never locked. A stale id resolves to
null and the call becomes a no-op, so a window closing underneath Lua code is
inert rather than a crash.

Each window owns its own `NeutrinoClient`, so every CEF callback already knows
which window it belongs to without a lookup.

## Events

Rather than a C callback per event, there is one:

```c
typedef void (*neutrino_event_fn)(int window_id, const char* event,
                                  const char* json, void* user);
```

Details travel as a JSON object. Wiring up another CEF handler costs an event
name, not an ABI change and not a new binding on the Lua side — which matters,
because a good deal of CEF is still unwired.

Two callbacks stay separate because they need return values: `invoke`, which
returns the IPC reply, and `can_close`, which returns the veto.

`ready` is posted rather than emitted inline. Under Views the browser can be
created while `neutrino_window_create()` is still on the stack, so emitting
directly would deliver the event before the Lua object exists to receive it.
`BrowserWindow:on` also replays `ready` to handlers attached after the fact.

## The custom scheme

`neutrino://` is registered as a standard scheme: it has a real origin, so the
page gets `localStorage`, `fetch`, modules and the rest, and is treated as
secure rather than as mixed content.

The handler factory is registered with an empty domain, so every host under the
scheme reaches Lua. That is what lets a module own `neutrino://mpq/` as its own
origin while the shell keeps `neutrino://app/`.

Compared with a local HTTP server: no port is opened, so no firewall prompt and
nothing for another local process to reach.

### Response ownership

An earlier design had Lua `malloc` the body and mime type and hand back
pointers, which leaked on every request because nothing freed them.

Now the handler passes an opaque response token to Lua, and Lua calls
`neutrino_response_set(token, status, mime, headers, body, len)`. C++ copies
into its own buffers before the call returns. Lua never owns C memory, the body
may contain binary data, and responses can carry custom headers.

## Modules, and why the framework is not built around them

A module is optional. `App`, `BrowserWindow`, `Server` and `Session` are usable
on their own, and an application that opens one window never has to declare one.
That is a deliberate refusal to pick an application architecture on the
developer's behalf.

The obvious candidate was HMVC, since the pieces look the part: per-host routers
already let a module own `neutrino://mpq/` as its own origin. It was rejected,
for a reason specific to this kind of application: **the view does not live in
Lua.** It lives in the DOM, it is persistent, and it changes by IPC. An MVC on
the Lua side would be an MVC with no V, and the hierarchical sub-request that
makes HMVC worth naming only pays off when a page is assembled from rendered
fragments on every display. In a persistent page, composition happens in the
component tree. That hierarchy belongs in `src/ui/`, on the browser side of the
bridge - putting it in the core would be putting it on the wrong side.

What a module is instead is a **boundary**. It claims a name, and the name is
the whole of what it owns: `neutrino://<name>/` for routes, `<name>:action` for
IPC channels, `persist:<name>` for a session. Nothing else can serve under that
origin, and two modules cannot collide in one window.

Making that boundary real rather than conventional is what earns it a place in
the core. `App:unregister_module` drops the module's host router, removes its
handlers from every window it attached to, cancels its timers and closes the
windows it opened, all while the application keeps running. A convention cannot
do that; only something that recorded what it claimed can.

The teardown deliberately distinguishes the windows a module *opened* from those
it was *attached to*. It closes the first and only unwires the second, because a
shell window hosting three modules must survive the removal of one.

### One window, or one per module

Both work, and they are the only two shapes supported.

A module can own its window - `Module:open` puts it on the module's origin, in
the module's partition, with its handlers installed - or several modules can
share one window through `Module:attach`, each answering on its own `<name>:`
channels. Mixing the two is fine: a module attached to a shell window can still
open a detached viewer of its own.

Rendering a module inside an `<iframe>` was considered and rejected. It would
give style and script isolation for free, but the bridge is injected into every
V8 context while `send` and `eval` address `GetMainFrame()`, so pushes from Lua
would stop at the shell and every page would need a `postMessage` relay. Paying
for `CefFrameHandler` and that relay to isolate CSS between an application's own
tools is the wrong trade. A module attached to a shell window therefore
contributes to that window's document.

The consequence lands on `src/ui/`: the isolation an iframe would have given has
to come from scoped components instead. That is a reason for the UI layer to
exist, not an accident of it.

The other consequence is a constraint worth stating plainly, because nothing
about it is visible at runtime: **a window has exactly one partition**. A module
attached to a window it does not own stores through *that* window's session,
whatever it declared, while its own `session()` keeps answering about its own
partition. `Module:attach` warns when the two differ rather than letting it be
discovered later. Per-module isolation is only real in the one-window-per-module
shape.

### One Server, found rather than passed

The scheme handler is process-wide, so there is one `Server`. `serve.server`
records it, and a module resolves its router from there instead of being handed
one. That keeps `app\register_module Mpq` free of plumbing, and keeps the
free-form path - `server = Neutrino.Server!` at the top of a script - working
unchanged, since both meet at the same object.

### Sub-requests, kept anyway

`Server:fetch` routes a request and hands the reply to Lua rather than to CEF.
Everything a route does goes through `Response:_flush`, so a response that
captures instead of calling into the native layer is a subclass with one method
overridden: the handler cannot tell the difference, and neither can the router.

This is the one piece of HMVC worth having on its own merits. It makes a route
testable without a window, lets a page's content be computed before the window
exists, and lets one module consume another's output without knowing it is a
module - without asking anyone to arrange their code as controllers.

## The UI layer: where state lives

One decision, and the rest follows from it: **Lua owns the data, the page owns
what is on screen.**

Lua is the side with the filesystem, the archives and the long-running work, so
it holds the data and is the authority on it. What is selected, what is
expanded, which tab is open - none of that is data, and round-tripping it
through IPC would make an interface that feels remote from itself. It stays in
the page.

`ui.State` is the only channel between the two. A write on either side is
applied on the other and nothing else happens: no template is re-evaluated, no
tree is diffed, no document is replaced. The page's effects re-run, and only
those that read what changed.

The initial state is inlined into the document rather than pushed after load.
Pushing would mean the first paint shows an empty interface and then fills in,
and it would race with the document's own script.

### Not echoing

The mistake a naive bridge makes is to treat its own copy as the event source: a
write arriving from the page is applied *and* pushed back out. Nothing visible
breaks, because the page already holds that value, which is precisely why it
survives into production - it just costs a round trip per keystroke and fights
whatever the page did next.

So `State` has two paths inward. `set` writes and pushes; `_receive` writes and
does not. The page's runtime matches it: `nui.set` notifies Lua, and the handler
for Lua's own pushes applies without notifying.

### Coarse reactivity, deliberately

A signal per top-level key, not per leaf. Writing `tree.nodes[3].open` re-runs
every effect that read `tree`.

Per-leaf reactivity means a proxy per node, invalidation as the shape changes,
and a great deal of care about identity. For a tool's interface, re-running the
effects that read one top-level key costs nothing measurable, and the whole
store is about sixty lines. The finer version can be built later if an interface
ever proves it needs it; it cannot be un-built.

### Expressions, and what they can see

Directives compile through `new Function` with `with (store)`. The store's proxy
answers `has` only for keys that were declared, so an identifier the store does
not know falls through to normal scope and `Math`, `JSON` and the rest stay
reachable. It also means the store's shape is declared up front, by whoever
built the document, rather than accumulating by accident.

`new Function` is what makes `with` available at all: this runtime is strict
code, and a function built that way is not.

### Widgets, and the two traps under them

A widget renders to a custom element carrying a declarative shadow root. That
buys real style scoping from the browser rather than from a naming convention,
and it is what made refusing iframes affordable.

Templates are etlua, and the choice that matters is that `<%= %>` escapes by
default. Widget values are data - a filename, a note, a title - and the failure
of the sketch this replaced was that they went in raw.

Two things about declarative shadow roots are worth writing down, because both
fail silently and neither is guessable:

- **`innerHTML` drops them.** Assigning markup that contains
  `<template shadowrootmode>` leaves an inert template: the widget renders with
  no styles and no slots, and nothing is reported. `setHTMLUnsafe` parses them,
  which is what `nui.html` uses and why fetching a fragment from a module's
  route works at all.
- **`cloneNode` drops them too.** Chromium applies a declarative shadow root
  even inside another template's content, so by the time `data-for` clones a
  row the widget inside it already *has* a shadow root - and a clone does not
  copy one unless the template said `shadowrootclonable`. Without that
  attribute every repeated row comes out empty.

Nothing about the second one is visible from the markup. It was found by asking
the page what it actually had, rather than by reasoning about what it should
have had.

## Deferred replies

A handler that has to wait must not hold the loop, or the window stops
repainting for as long as it waits. Both inbound paths therefore support
answering later.

For the custom scheme, `CefResourceHandler` already allows it: `Open` reports
that it will answer later, and the request resumes when `CefCallback::Continue`
is called. Neutrino keeps that callback and hands Lua a response id. For IPC,
the message router's `Callback` is kept in the same way, and the Lua invoke
handler returns NULL to mean "not yet".

Both registries are keyed by an integer rather than a pointer, so a reply that
arrives after the page navigated away or the window closed is a lookup miss
instead of a dangling dereference. `OnQueryCanceled` and `Cancel` drop entries
as their requests die.

On top of that, handlers run inside coroutines. A handler that returns without
awaiting finishes before `async.run` returns, and is answered inline with no
extra loop turn - the common case costs nothing. One that awaits suspends, the
loop carries on, and the reply goes out by id when it resumes.

That covers waiting. It does not cover computing: a coroutine that spins for a
second still holds the thread. `async.work` is the answer there, handing the
job to a libuv worker thread with its own Lua state. That is the one place
where Lua being single-threaded genuinely constrains the design, and the fix is
a worker pool rather than a shared interpreter.

## Evaluating JavaScript

`exec_js` is fire and forget. `eval` returns a value, which needs a renderer
round trip:

1. browser sends `neutrino.eval` with a request id and the code
2. the renderer enters the frame's V8 context, evaluates, and serialises the
   result with the page's own `JSON.stringify`
3. the renderer replies with `neutrino.eval.result`, and the browser resolves
   whoever was waiting - a callback, or a task suspended on `eval`

Entering the context matters: most `CefV8Value` operations are only valid
inside their context, and skipping the step yields null results rather than an
error. A promise serialises as `{}`; awaiting one is not supported yet.

## Processes

`neutrinocef_helper.exe` is the subprocess for renderer, GPU and utility
processes. It links only the renderer-side sources and never touches the window
registry or the Lua callbacks.

It learns the scheme name from a `--neutrino-scheme` switch appended in
`OnBeforeChildProcessLaunch`, and parses it from the OS command line rather
than CEF's global one, which is not reliably available as early as
`OnRegisterCustomSchemes` runs.

Two failure modes here are worth knowing, because both were hit during
development and neither reports itself clearly:

- If `browser_subprocess_path` does not reach CEF, it silently falls back to
  the host executable. Every child process then relaunches the Lua interpreter,
  which exits immediately, and the browser never gets a renderer.
  `neutrino_config_summary()` exists to make that visible.
- A partial CEF runtime — missing the ANGLE or SwiftShader DLLs — kills child
  processes with no useful message. `build.ps1` therefore copies the runtime
  straight from the SDK rather than from a hand-maintained folder.

## Layers

```
  Lua application
        |
  Module                                   optional; a boundary over the below
        |
  BrowserWindow / Server / Router /        src/core/
  Session
        |
  bridge: routes callbacks by window id    src/core/bridge.moon
        |
  FFI binding                              src/core/cef.moon
        |
  ============ C ABI ============          native/src/neutrino_api.h
        |
  exports, argument checking               native/src/main.cpp
        |
  registry, client, Views delegates,       native/src/
  scheme handler
        |
  CEF
```

`neutrino_api.h` is the contract. `cef_binding.moon` mirrors it by hand, so the
header changes first.
