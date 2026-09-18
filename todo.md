# TODO

## CEF

- [ ] `CefURLRequest` — HTTP from Lua on Chromium's stack (proxy, cookies)
- [ ] `CefDevToolsMessageObserver` — CDP: screenshots, tracing, DOM, automated UI tests
- [ ] `CefPermissionHandler` — camera, microphone, notifications, clipboard read
- [ ] `CefFindHandler` — find in page
- [ ] `CefRequestHandler::GetAuthCredentials` — HTTP auth
- [ ] `CefRequestHandler::OnCertificateError`, `OnSelectClientCertificate`
- [ ] `CefResourceRequestHandler::GetCookieAccessFilter`
- [ ] `CefResponseFilter` — rewrite a response body
- [ ] `CefFrameHandler` — iframes addressed individually
- [ ] `CefPrintHandler`, `CefBrowserHost::PrintToPDF`
- [ ] `CefPreferenceManager` — Chromium preferences
- [ ] `CefTaskManager` — per-process CPU and memory
- [ ] `CefBrowserHost::SendKeyEvent` — key injection
- [ ] `CefDisplayHandler` — status text, tooltip, favicon, loading progress, cursor
- [ ] `CefLifeSpanHandler::OnBeforeDevToolsPopup`, `OnBeforePopupAborted`
- [ ] `CefFocusHandler::OnTakeFocus`, `OnSetFocus`
- [ ] `CefKeyboardHandler::OnKeyEvent`
- [ ] `CefDialogHandler::OnFileDialog` — replace a dialog the page opened
- [ ] `CefRequestContext` — `ResolveHost`, website and content settings
- [ ] `CefV8` — expose native functions to the renderer
- [ ] `CefDOMDocument` / `CefDOMNode`
- [ ] `CefAccessibilityHandler`
- [ ] `CefCrashUtil`
- [ ] `CefRenderHandler` — offscreen rendering
- [ ] `CefAudioHandler`
- [ ] `CefMediaRouter`

## Platform (Win32)

- [ ] Tray icon and balloon notifications
- [ ] Native application menu bar
- [ ] Global shortcuts
- [ ] Auto-start, jump lists, taskbar progress and overlay icons
- [ ] Power and session monitoring (sleep, resume, lock)
- [ ] File associations
- [ ] Installer

## Framework

- [ ] A luv pump that runs for the process, not only during `async.work` — luv
      callbacks (spawn, fs watchers, sockets) never fire without one
- [ ] Logging to a file — a packaged app has no console, so `print` goes nowhere
- [ ] Executable icon in `package.ps1` — needs a resource editor
- [ ] Trim the CEF runtime from the package (407 MB)
- [ ] An example application; `examples/` is empty until the API settles
- [ ] `customElements.define` for widgets, for a lifecycle and `:defined`
- [ ] More widgets: tree, table, tabs, menu, dialog
- [ ] Per-key reactivity below the top level, if a real interface ever needs it
- [ ] Module assets: a static route under the module's origin, without each
      module writing its own
