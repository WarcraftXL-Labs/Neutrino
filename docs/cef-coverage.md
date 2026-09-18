# CEF coverage

What Neutrino wires up today and what it does not, measured against the CEF
152 headers in `deps/cef/.../include`.

The goal is that nothing an application needs has to reach past the framework
into raw CEF. Anything marked missing below is a place where it would have to.

Legend: **done** · **partial** — some callbacks wired · **missing**

---

## CefClient handlers

`CefClient` exposes 18 handler interfaces. Thirteen are attached to
`NeutrinoClient` today.

| Handler | State | Notes |
| :--- | :--- | :--- |
| `CefLifeSpanHandler` | partial | Creation, close handshake and popup adoption are wired. `OnBeforeDevToolsPopup` and `OnBeforePopupAborted` are not. |
| `CefLoadHandler` | partial | `OnLoadingStateChange`, `OnLoadEnd`, `OnLoadError`. `OnLoadStart` unused. |
| `CefDisplayHandler` | partial | Title, address, console, fullscreen. Missing: status text, tooltip, favicon URLs, loading progress, cursor, media access state. |
| `CefRequestHandler` | partial | `OnBeforeBrowse`, renderer termination, and `GetResourceRequestHandler` for intercepting every request. See the section below for what remains. |
| `CefDragHandler` | done | Draggable regions feed the Views window. |
| `CefFocusHandler` | partial | `OnGotFocus`. `OnTakeFocus` and `OnSetFocus` are not wired, so focus cannot be redirected or refused. |
| `CefContextMenuHandler` | done | Chromium's menu is always cleared. The application builds its own per click, with separators, submenus and checkboxes; no builder means no menu. |
| `CefKeyboardHandler` | partial | `OnPreKeyEvent` drives accelerators and a raw hook. `OnKeyEvent`, after the page has had its turn, is not wired. |
| `CefDialogHandler` | partial | Open, save and folder dialogs are driven from Lua through `CefBrowserHost::RunFileDialog`, and await their result. `OnFileDialog`, which would let the application replace a dialog the *page* opened via `<input type=file>`, is not wired; the OS dialog is used. |
| `CefJSDialogHandler` | done | `alert`, `confirm`, `prompt` and `onbeforeunload` are answered from Lua, and may be answered asynchronously. Suppressed when no handler is registered, since Alloy style has no dialog of its own. |
| `CefDownloadHandler` | done | The application chooses the destination, and may await a save dialog before deciding. Progress, pause, resume and cancel are exposed. Without a handler CEF prompts, rather than refusing or writing somewhere unasked. |
| `CefPermissionHandler` | **missing** | Camera, microphone, notifications, clipboard read. |
| `CefFindHandler` | **missing** | Find-in-page. |
| `CefCommandHandler` | **missing** | Chrome commands and `--app` style command routing. |
| `CefPrintHandler` | **missing** | Printing and print-to-PDF. |
| `CefFrameHandler` | **missing** | Frame attach/detach and main-frame change. Needed before iframes can be addressed individually. |
| `CefAudioHandler` | **missing** | Raw audio capture from the page. |
| `CefRenderHandler` | **missing** | Offscreen rendering. Only relevant if a tool ever needs to composite the UI into something else, such as a 3D view. |

### What is still unwired on `CefRequestHandler`

`GetResourceRequestHandler` is in place: every request, not only `neutrino://`,
can be blocked, redirected or have its headers rewritten from Lua, and the
handler is only attached once an application registers an interceptor, so one
that does not intercept pays nothing.

Still missing on this handler:

- `CefResponseFilter`, for streaming rewrites of a response *body*
- `GetCookieAccessFilter`, for vetoing individual cookies per request
- `OnCertificateError` and `OnSelectClientCertificate`
- `GetAuthCredentials`, for HTTP auth prompts
- `OnDocumentAvailableInMainFrame`

---

## Browser and application APIs

| Area | State | Notes |
| :--- | :--- | :--- |
| Windows, multi-window | done | Registry by id, Views-based. |
| Navigation, zoom, DevTools | done | |
| IPC, both directions | done | Deferred replies supported on both sides. |
| `eval` with a return value | partial | Works. A returned promise serialises as `{}` rather than being awaited. |
| Custom scheme | done | Routes, params, wildcards, per-host routers, binary bodies, deferred responses. |
| Displays | done | `CefDisplay`, DIP, multi-monitor. |
| Frameless windows | done | Draggable regions via `-webkit-app-region`. |
| `CefCookieManager` | done | Read, write, delete and flush, per partition. Attributes, including expiry, survive the round trip. |
| `CefRequestContext` | partial | Partitions with Electron's naming: `persist:name` on disk, any other name in memory. Window creation waits for the context to initialise, so the first window in a partition opens like any other. Also `ClearHttpCache`, `ClearHttpAuthCredentials`, `CloseAllConnections` and `SetChromeColorScheme`. Not wired: `ResolveHost`, website and content settings, `CefMediaRouter`. |
| `CefPreferenceManager` | **missing** | Chromium preferences at global and context level. |
| `CefDevToolsMessageObserver` | **missing** | The DevTools protocol. `SendDevToolsMessage` gives scripted access to CDP: screenshots, tracing, network capture, DOM inspection. |
| `CefMenuModel` | partial | Driven by the context menu handler. Not yet exposed for menu bars or tray menus. |
| `CefURLRequest` | **missing** | HTTP from Lua using Chromium's stack, with the browser's cookies and proxy. |
| `CefV8` in the renderer | partial | Used for the bridge and for `eval`. No way yet to expose native functions or register extensions from Lua. |
| `CefDOMDocument` / `CefDOMNode` | **missing** | Direct DOM access from the renderer process. |
| `CefImage` | partial | Window and taskbar icons from PNG. Not exposed for anything else. |
| `CefTaskManager` | **missing** | Per-process CPU and memory, useful for a diagnostics panel. |
| `CefMediaRouter` | **missing** | Cast and presentation. Unlikely to matter here. |
| `CefServer` | **missing** | An actual HTTP server. Deliberately unused: the custom scheme exists to avoid opening a port. |
| Print to PDF | **missing** | `CefBrowserHost::PrintToPDF`. |
| Screenshots | **missing** | Via CDP `Page.captureScreenshot`, so it depends on the DevTools observer. |
| `CefBrowserHost` input injection | partial | Mouse clicks, with focus and a move first. An injected right-click does not raise the context menu on a windowed browser. `SendKeyEvent` is not wired. |
| Accessibility | **missing** | `CefAccessibilityHandler`. |

---

## Not CEF, but expected of a framework like this

Electron provides these outside the browser engine, and they will have to be
built on Win32 rather than found in CEF:

- tray icon and balloon notifications
- native application and context menus
- global shortcuts registered outside the window
- clipboard read and write
- open a URL or a file with the system handler (`ShellExecute`)
- single-instance lock and second-instance activation
- auto-start, jump lists, taskbar progress and overlay icons
- power and session monitoring (sleep, resume, lock)
- crash reporting (`CefCrashUtil` exists and is unwired)
- an application packager producing a single distributable folder

---

## Suggested order

Grouped by what unblocks the most work for the tools that will be built on top.

**First — an application stops looking like a browser** — *done*
1. ~~`CefContextMenuHandler` + `CefMenuModel`~~
2. ~~`CefKeyboardHandler` — accelerators, and blocking browser shortcuts~~
3. ~~`CefJSDialogHandler`~~
4. ~~Window icons, which need `CefImage`~~

**Second — file and data work, which every WarcraftXL tool needs** — *done*
5. ~~`CefDialogHandler` — open, save, folder picker~~
6. ~~`CefDownloadHandler`~~
7. ~~`GetResourceRequestHandler` — interception~~ (response filters still missing)
8. ~~`CefCookieManager` + `CefRequestContext` — sessions and per-window state~~

**Third — the platform shell**
9. Tray, native menus, global shortcuts, clipboard, shell open
10. Single-instance lock
11. Packaging

**Fourth — tooling and diagnostics**
12. `CefDevToolsMessageObserver` — CDP, and screenshots through it
13. `CefTaskManager`, crash reporting
14. Input injection for automated UI tests

`CefRenderHandler` and `CefAudioHandler` are deliberately last: neither is
needed unless a tool has to embed the UI into another surface or capture page
audio.
