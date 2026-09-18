--- A managed top-level window, in the style of Electron's BrowserWindow.
--
-- Each instance owns a native window identified by a numeric id; any number of
-- them can exist at once. Native callbacks are routed here by core.bridge.
--
-- All coordinates are density independent pixels, so the same numbers behave
-- identically on a 100% and a 200% display.
---@module browser.window

ffi = require "ffi"
EventEmitter = (require "core.events").EventEmitter
async = require "core.async"
bridge = require "core.bridge"
cef = require "core.cef"
json = require "util.json"
keys = require "browser.keys"
sessions = require "browser.session"

-- Native event name -> the event BrowserWindow emits. Events not listed here
-- are re-emitted under their own name, so a new CEF handler on the C++ side
-- reaches Lua without touching this table.
EVENT_ALIASES = {
  "loading-start": "loading"
  "loading-end": "loaded"
}

---@class BrowserWindow : EventEmitter
---@field id integer Native window id.
---@field closed boolean True once the window has been destroyed.
---@field browser_ready boolean True once the browser process is up.
class BrowserWindow extends EventEmitter
  --- Creates and opens a window.
  ---@param opts table Window options.
  ---@field opts.title string Window title.
  ---@field opts.url string URL to load.
  ---@field opts.width integer Width in DIP. Defaults to 1024.
  ---@field opts.height integer Height in DIP. Defaults to 768.
  ---@field opts.x integer Left edge; setting it disables centering.
  ---@field opts.y integer Top edge; setting it disables centering.
  ---@field opts.min_width integer Minimum width in DIP.
  ---@field opts.min_height integer Minimum height in DIP.
  ---@field opts.max_width integer Maximum width in DIP.
  ---@field opts.max_height integer Maximum height in DIP.
  ---@field opts.frameless boolean Drops the system title bar and border.
  ---@field opts.resizable boolean Defaults to true.
  ---@field opts.maximizable boolean Defaults to true.
  ---@field opts.minimizable boolean Defaults to true.
  ---@field opts.centered boolean Defaults to true unless x or y is given.
  ---@field opts.show boolean Shows the window on creation. Defaults to true.
  ---@field opts.always_on_top boolean Keeps the window above others.
  ---@field opts.show_state string "normal", "minimized", "maximized" or "fullscreen".
  ---@field opts.background table RGB triple for the background colour.
  ---@field opts.chrome_style boolean Uses Chrome runtime style instead of Alloy.
  ---@field opts.partition string Session to use: "" for the default one,
  --- "persist:name" for one kept on disk, any other name for one kept in memory.
  new: (opts = {}) =>
    super!

    unless cef.lib
      error "BrowserWindow requires the native library. Call Neutrino.cef.setup(dir) first."

    bridge.install!

    @closed = false
    @browser_ready = false
    @_ready_detail = nil
    @_ipc_handlers = {}
    @_eval_pending = {}
    @_close_guard = nil
    @_menu_builder = nil
    @_menu_actions = {}
    @_menu_id = 0
    @_accelerators = {}
    @_key_handler = nil
    @_dialog_handler = nil
    @_file_dialogs = {}
    @_download_handler = nil
    @_resource_handler = nil
    @_bounds = ffi.new "neutrino_rect[1]"
    @partition = opts.partition or ""

    @id = cef.lib.neutrino_window_create cef.build_window_options opts
    if @id == 0
      error "failed to create window: #{cef.last_error!}"

    bridge.register @

  --- Registers a listener, replaying "ready" if the browser is already up.
  -- Without the replay, code that creates a window and subscribes immediately
  -- afterwards could miss the event, since the browser may come up first.
  ---@param event string Event name.
  ---@param callback function Listener.
  ---@return BrowserWindow self, for chaining.
  on: (event, callback) =>
    super event, callback
    if event == "ready" and @browser_ready
      ok, err = pcall callback, @_ready_detail
      unless ok
        io.stderr\write "[neutrino] replayed ready handler failed: #{tostring err}\n"
    @

  -- ═══════════════════════════════════════════════════════════════════════════
  -- NATIVE CALLBACKS  (called by core.bridge, not by application code)
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Runs the handler registered for an IPC channel.
  --
  -- The handler runs as a task, so it may await. One that returns without
  -- awaiting is answered inline; one that awaits leaves the query open and
  -- resolves it by id once it finishes, which keeps the message pump running
  -- in the meantime.
  ---@param request_id integer Native id used to resolve a deferred reply.
  ---@param channel string Channel name.
  ---@param args_json string JSON payload, or an empty string.
  ---@return string|nil reply JSON reply, or nil when the handler awaited.
  ---@private
  _handle_invoke: (request_id, channel, args_json) =>
    handler = @_ipc_handlers[channel]
    unless handler
      error "no IPC handler registered for channel '#{channel}'"

    -- Falls back to the raw string when the payload is not valid JSON, so
    -- handlers accept plain strings as well as structured values.
    payload = if args_json == ""
      nil
    else
      json.try_decode(args_json) or args_json

    -- Set once this method has returned, which tells the task whether it still
    -- has an inline reply to hand back or must resolve through the native id.
    returned = false
    reply = nil
    failure = nil

    async.run ->
      ok, value = pcall handler, payload, @
      if ok
        reply = @_encode_reply channel, value
      else
        failure = tostring value

      if returned
        if failure
          cef.lib.neutrino_invoke_reject request_id, -1, failure
        else
          cef.lib.neutrino_invoke_resolve request_id, reply

    returned = true

    error failure if failure
    reply

  --- Encodes a handler's return value, tolerating one that cannot be encoded.
  --
  -- MoonScript returns the last expression, and this class is chainable, so a
  -- handler whose body is a single call such as minimize! returns the window
  -- itself. That is almost always "I have no reply" rather than a real value,
  -- and rejecting the page's promise over it would be hostile. Warn and answer
  -- null instead.
  ---@param channel string
  ---@param value any
  ---@return string json
  ---@private
  _encode_reply: (channel, value) =>
    return "null" if value == nil

    encoded, err = json.try_encode value
    return encoded if encoded

    -- Reported rather than swallowed: answering null silently would leave a
    -- page waiting on a value it will never recognise, with nothing to read.
    io.stderr\write "[neutrino] reply on channel '#{channel}' could not be " ..
      "serialised (#{tostring err}); answered null. Return an explicit value " ..
      "if the page expects one.\n"
    "null"

  --- Turns a native event into an emitted event.
  ---@param event string Native event name.
  ---@param detail table Decoded event payload.
  ---@private
  _handle_event: (event, detail) =>
    switch event
      when "ready"
        @browser_ready = true
        @_ready_detail = detail
        @emit "ready", detail
        return
      when "context-menu-command"
        @_handle_menu_command detail.id
        @emit "context-menu-command", detail
        return
      when "closed"
        @closed = true
        @emit "closed"
        -- Last thing that happens for this window: the id is now dead.
        bridge.unregister @id
        return

    @emit (EVENT_ALIASES[event] or event), detail

  --- Asks the close guard whether the window may close.
  ---@return boolean False cancels the close.
  ---@private
  _handle_can_close: =>
    return true unless @_close_guard

    -- Bound to a local on purpose: `@_close_guard(@)` would compile to a colon
    -- call and hand the guard self as an extra leading argument.
    guard = @_close_guard
    guard(@) != false

  --- Delivers an eval result to whoever is waiting for it.
  ---@param request_id integer Matches the request eval started.
  ---@param ok boolean False when the script raised.
  ---@param payload string JSON result, or the error message.
  ---@private
  _handle_eval: (request_id, ok, payload) =>
    resolve = @_eval_pending[request_id]
    @_eval_pending[request_id] = nil
    return unless resolve

    unless ok
      resolve nil, payload
      return

    value, err = json.try_decode payload
    if err
      resolve nil, "could not decode the result: #{err}"
    else
      resolve value, nil

  -- ═══════════════════════════════════════════════════════════════════════════
  -- IPC
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Registers a handler for `window.neutrino.invoke(channel, payload)`.
  -- The handler receives the decoded payload and this window; its return value
  -- is JSON-encoded back to the promise on the JavaScript side.
  ---@param channel string Channel name.
  ---@param handler fun(payload: any, window: BrowserWindow): any
  ---@return BrowserWindow self, for chaining.
  handle: (channel, handler) =>
    @_ipc_handlers[channel] = handler
    @

  --- Removes a channel handler.
  ---@param channel string Channel name.
  ---@return BrowserWindow self, for chaining.
  unhandle: (channel) =>
    @_ipc_handlers[channel] = nil
    @

  --- Pushes an event to the page, received by `window.neutrino.on(channel)`.
  ---@param channel string Channel name.
  ---@param payload any Any JSON-encodable value.
  ---@return BrowserWindow self, for chaining.
  send: (channel, payload) =>
    encoded = payload == nil and "" or json.encode payload
    cef.lib.neutrino_window_send @id, channel, encoded
    @

  -- ═══════════════════════════════════════════════════════════════════════════
  -- SCRIPT
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Runs JavaScript in the page without waiting for a result.
  ---@param code string JavaScript source.
  ---@return BrowserWindow self, for chaining.
  exec_js: (code) =>
    cef.lib.neutrino_window_exec_js @id, code
    @

  --- Evaluates JavaScript in the page and hands back the result.
  --
  -- The value is serialised with the page's own JSON.stringify, so anything
  -- JSON can express survives the round trip. A promise arrives unresolved.
  --
  -- Called from inside a task it awaits and returns the value, which is what
  -- lets a sequence of evaluations read as a sequence rather than as a stack of
  -- callbacks. Outside a task, pass a callback instead.
  --
  --     title = win\eval "document.title"
  --
  ---@param code string Expression to evaluate.
  ---@param callback? fun(value: any, err: string|nil)
  ---@return any value, string|nil err when awaited; otherwise the window.
  eval: (code, callback) =>
    start = (resolve) ->
      request_id = cef.lib.neutrino_window_eval @id, code
      if request_id == 0
        resolve nil, "window is not ready"
      else
        @_eval_pending[request_id] = resolve

    return async.await start if callback == nil and async.is_async!

    start (value, err) -> callback value, err if callback
    @

  -- ═══════════════════════════════════════════════════════════════════════════
  -- NAVIGATION
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Navigates to a URL.
  ---@param url string
  ---@return BrowserWindow self, for chaining.
  load_url: (url) =>
    cef.lib.neutrino_window_load_url @id, url
    @

  --- Reloads the current page.
  ---@param ignore_cache? boolean Bypasses the cache when true.
  ---@return BrowserWindow self, for chaining.
  reload: (ignore_cache = false) =>
    cef.lib.neutrino_window_reload @id, ignore_cache and 1 or 0
    @

  --- Stops the current load.
  ---@return BrowserWindow self, for chaining.
  stop: =>
    cef.lib.neutrino_window_stop @id
    @

  --- Goes back one entry in the history.
  ---@return BrowserWindow self, for chaining.
  go_back: =>
    cef.lib.neutrino_window_back @id
    @

  --- Goes forward one entry in the history.
  ---@return BrowserWindow self, for chaining.
  go_forward: =>
    cef.lib.neutrino_window_forward @id
    @

  --- Reports whether backward navigation is possible.
  ---@return boolean
  can_go_back: => cef.lib.neutrino_window_can_back(@id) == 1

  --- Reports whether forward navigation is possible.
  ---@return boolean
  can_go_forward: => cef.lib.neutrino_window_can_forward(@id) == 1

  --- Returns the current URL.
  ---@return string
  get_url: => ffi.string cef.lib.neutrino_window_url @id

  --- Returns the current document title.
  ---@return string
  get_title: => ffi.string cef.lib.neutrino_window_title @id

  --- Reports whether a load is in progress.
  ---@return boolean
  is_loading: => cef.lib.neutrino_window_is_loading(@id) == 1

  --- Sets the zoom level. 0 is 100%, each step is roughly 20%.
  ---@param level number
  ---@return BrowserWindow self, for chaining.
  set_zoom: (level) =>
    cef.lib.neutrino_window_set_zoom @id, level
    @

  --- Returns the current zoom level.
  ---@return number
  get_zoom: => cef.lib.neutrino_window_get_zoom @id

  -- ═══════════════════════════════════════════════════════════════════════════
  -- DEVTOOLS
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Opens DevTools in a separate window.
  ---@return BrowserWindow self, for chaining.
  open_devtools: =>
    cef.lib.neutrino_window_open_devtools @id
    @

  --- Closes DevTools.
  ---@return BrowserWindow self, for chaining.
  close_devtools: =>
    cef.lib.neutrino_window_close_devtools @id
    @

  --- Reports whether DevTools is open.
  ---@return boolean
  has_devtools: => cef.lib.neutrino_window_has_devtools(@id) == 1

  --- Opens DevTools if closed, closes it if open.
  ---@return BrowserWindow self, for chaining.
  toggle_devtools: =>
    if @has_devtools! then @close_devtools! else @open_devtools!
    @

  -- ═══════════════════════════════════════════════════════════════════════════
  -- WINDOW MANAGEMENT
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Shows the window.
  ---@return BrowserWindow self, for chaining.
  show: =>
    cef.lib.neutrino_window_show @id
    @

  --- Hides the window without destroying it.
  ---@return BrowserWindow self, for chaining.
  hide: =>
    cef.lib.neutrino_window_hide @id
    @

  --- Minimizes the window.
  ---@return BrowserWindow self, for chaining.
  minimize: =>
    cef.lib.neutrino_window_minimize @id
    @

  --- Maximizes the window.
  ---@return BrowserWindow self, for chaining.
  maximize: =>
    cef.lib.neutrino_window_maximize @id
    @

  --- Restores the window from a minimized or maximized state.
  ---@return BrowserWindow self, for chaining.
  restore: =>
    cef.lib.neutrino_window_restore @id
    @

  --- Brings the window forward and gives it focus.
  ---@return BrowserWindow self, for chaining.
  focus: =>
    cef.lib.neutrino_window_focus @id
    @

  --- Centres the window on its current display.
  ---@return BrowserWindow self, for chaining.
  center: =>
    cef.lib.neutrino_window_center @id
    @

  --- Sets the window title.
  ---@param title string
  ---@return BrowserWindow self, for chaining.
  set_title: (title) =>
    cef.lib.neutrino_window_set_title @id, title
    @

  --- Enters or leaves fullscreen.
  ---@param enabled boolean
  ---@return BrowserWindow self, for chaining.
  set_fullscreen: (enabled) =>
    cef.lib.neutrino_window_set_fullscreen @id, enabled and 1 or 0
    @

  --- Keeps the window above others, or stops doing so.
  ---@param enabled boolean
  ---@return BrowserWindow self, for chaining.
  set_always_on_top: (enabled) =>
    cef.lib.neutrino_window_set_always_on_top @id, enabled and 1 or 0
    @

  --- Closes the window.
  ---@param force? boolean Skips the guard registered with on_close_request.
  ---@return BrowserWindow self, for chaining.
  close: (force = false) =>
    cef.lib.neutrino_window_close @id, force and 1 or 0
    @

  --- Registers a guard consulted before the window closes.
  -- Returning false cancels the close, which is how an "unsaved changes"
  -- prompt is expressed. Passing nil clears the guard.
  ---@param guard fun(window: BrowserWindow): boolean
  ---@return BrowserWindow self, for chaining.
  on_close_request: (guard) =>
    @_close_guard = guard
    @

  -- ═══════════════════════════════════════════════════════════════════════════
  -- STATE
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Reports whether the native window still exists.
  ---@return boolean
  is_valid: => cef.lib.neutrino_window_valid(@id) == 1

  --- Reports whether the browser process is up and able to run script.
  ---@return boolean
  is_ready: => cef.lib.neutrino_window_ready(@id) == 1

  --- Reports whether the window is maximized.
  ---@return boolean
  is_maximized: => cef.lib.neutrino_window_is_maximized(@id) == 1

  --- Reports whether the window is minimized.
  ---@return boolean
  is_minimized: => cef.lib.neutrino_window_is_minimized(@id) == 1

  --- Reports whether the window is fullscreen.
  ---@return boolean
  is_fullscreen: => cef.lib.neutrino_window_is_fullscreen(@id) == 1

  --- Reports whether the window is visible.
  ---@return boolean
  is_visible: => cef.lib.neutrino_window_is_visible(@id) == 1

  --- Reports whether the window is the active one.
  ---@return boolean
  is_active: => cef.lib.neutrino_window_is_active(@id) == 1

  -- ═══════════════════════════════════════════════════════════════════════════
  -- GEOMETRY
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Moves and resizes the window. Omitted fields keep their current value.
  ---@param bounds table x, y, width, height in DIP.
  ---@return BrowserWindow self, for chaining.
  set_bounds: (bounds = {}) =>
    current = @get_bounds!
    @_bounds[0].x = bounds.x or current.x
    @_bounds[0].y = bounds.y or current.y
    @_bounds[0].width = bounds.width or current.width
    @_bounds[0].height = bounds.height or current.height
    cef.lib.neutrino_window_set_bounds @id, @_bounds
    @

  --- Returns the current position and size.
  ---@return table bounds x, y, width, height in DIP.
  get_bounds: =>
    cef.lib.neutrino_window_get_bounds @id, @_bounds
    {
      x: @_bounds[0].x
      y: @_bounds[0].y
      width: @_bounds[0].width
      height: @_bounds[0].height
    }

  --- Sets the smallest size the user can resize the window to.
  ---@param width integer
  ---@param height integer
  ---@return BrowserWindow self, for chaining.
  set_min_size: (width, height) =>
    cef.lib.neutrino_window_set_min_size @id, width, height
    @

  --- Sets the largest size the user can resize the window to.
  ---@param width integer
  ---@param height integer
  ---@return BrowserWindow self, for chaining.
  set_max_size: (width, height) =>
    cef.lib.neutrino_window_set_max_size @id, width, height
    @

  -- ═══════════════════════════════════════════════════════════════════════════
  -- CONTEXT MENU
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Builds the menu for a right-click, or suppresses it.
  --
  -- The builder receives what was clicked and returns a list of items. Each is
  -- `{ label, action }`, `{ type: "separator" }`, `{ label, items }` for a
  -- submenu, or `{ label, type: "checkbox", checked, action }`. Returning nil
  -- or an empty list shows no menu, which is also what happens when no builder
  -- is registered: an application is not a browser, so Chromium's own menu is
  -- never shown.
  --
  --     win\on_context_menu (params) ->
  --       return nil unless params.isEditable
  --       {
  --         { label: "Coller", action: -> win\exec_js "document.execCommand('paste')" }
  --         { type: "separator" }
  --         { label: "Inspecter", action: -> win\open_devtools! }
  --       }
  ---@param builder fun(params: table): table|nil
  ---@return BrowserWindow self, for chaining.
  on_context_menu: (builder) =>
    @_menu_builder = builder
    @

  --- Asks the builder for a menu and encodes it for the native layer.
  ---@param params table What was clicked.
  ---@return string|nil json Menu items, or nil for no menu.
  ---@private
  _handle_context_menu: (params) =>
    return nil unless @_menu_builder

    -- Bound to a local: see the note in _handle_can_close.
    builder = @_menu_builder
    items = builder params, @
    return nil unless items and #items > 0

    -- Actions stay on this side. Only ids cross into C++, and they are
    -- regenerated for each menu so a stale command cannot fire an old action.
    @_menu_actions = {}
    encoded = @_encode_menu_items items
    return nil if #encoded == 0

    json.encode encoded

  --- Converts builder items into the native shape, recursing into submenus.
  ---@param items table
  ---@return table
  ---@private
  _encode_menu_items: (items) =>
    encoded = {}

    for item in *items
      continue unless type(item) == "table"

      if item.type == "separator"
        table.insert encoded, { type: "separator" }
        continue

      continue unless item.label

      entry = { label: item.label }
      entry.enabled = false if item.enabled == false

      if item.items
        entry.items = @_encode_menu_items item.items
      else
        @_menu_id += 1
        id = "item#{@_menu_id}"
        entry.id = id
        @_menu_actions[id] = item.action if item.action

        if item.type == "checkbox"
          entry.type = "checkbox"
          entry.checked = item.checked and true or false

      table.insert encoded, entry

    encoded

  --- Runs the action behind a chosen menu item.
  ---@param id string
  ---@private
  _handle_menu_command: (id) =>
    action = @_menu_actions and @_menu_actions[id]
    return unless action

    ok, err = pcall action, @
    unless ok
      io.stderr\write "[neutrino] context menu action failed: #{tostring err}\n"

  -- ═══════════════════════════════════════════════════════════════════════════
  -- KEYBOARD
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Claims a keyboard shortcut.
  --
  -- The handler runs before the page sees the key, and the event is consumed,
  -- so this is also how a browser shortcut is taken out of circulation:
  -- registering "Ctrl+R" with an empty handler stops the page reloading.
  ---@param accelerator string For example "Ctrl+Shift+I", "F12", "Alt+Left".
  ---@param handler fun(window: BrowserWindow)
  ---@return BrowserWindow self, for chaining.
  register_accelerator: (accelerator, handler) =>
    spec, err = keys.parse accelerator
    error err unless spec

    table.insert @_accelerators, { :spec, :handler, :accelerator }
    @

  --- Releases a shortcut claimed with register_accelerator.
  ---@param accelerator string
  ---@return BrowserWindow self, for chaining.
  unregister_accelerator: (accelerator) =>
    for index = #@_accelerators, 1, -1
      table.remove @_accelerators, index if @_accelerators[index].accelerator == accelerator
    @

  --- Registers a handler for every key event, ahead of the page.
  -- Return true to consume the event. Accelerators are checked first.
  ---@param handler fun(event: table, window: BrowserWindow): boolean
  ---@return BrowserWindow self, for chaining.
  on_key: (handler) =>
    @_key_handler = handler
    @

  --- Matches accelerators, then falls through to the raw handler.
  ---@param event table
  ---@return boolean True to consume the event.
  ---@private
  _handle_key: (event) =>
    for entry in *@_accelerators
      continue unless keys.matches entry.spec, event

      ok, err = pcall entry.handler, @
      unless ok
        io.stderr\write "[neutrino] accelerator #{entry.accelerator} failed: #{tostring err}\n"
      return true

    return false unless @_key_handler

    ok, handled = pcall @_key_handler, event, @
    unless ok
      io.stderr\write "[neutrino] key handler failed: #{tostring handled}\n"
      return false

    handled == true

  -- ═══════════════════════════════════════════════════════════════════════════
  -- JAVASCRIPT DIALOGS
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Handles alert(), confirm(), prompt() and the unload prompt.
  --
  -- The handler receives the request and a `respond` function, and may answer
  -- whenever it likes - after awaiting, or once the user has clicked something
  -- in the page. Returning false declines, and the dialog is suppressed.
  --
  -- With no handler registered these are suppressed too. Alloy style has no
  -- dialog implementation of its own, so the alternative is a page that hangs
  -- forever on alert().
  --
  --     win\on_js_dialog (info, respond) ->
  --       if info.type == "confirm"
  --         win\send "confirm", { message: info.message }
  --         pending_respond = respond
  --         true
  ---@param handler fun(info: table, respond: fun(ok: boolean, text?: string), window: BrowserWindow): boolean
  ---@return BrowserWindow self, for chaining.
  on_js_dialog: (handler) =>
    @_dialog_handler = handler
    @

  --- Offers a dialog to the handler.
  ---@param dialog_id integer
  ---@param info table
  ---@return boolean True when the application will answer.
  ---@private
  _handle_dialog: (dialog_id, info) =>
    return false unless @_dialog_handler

    answered = false
    respond = (ok, text) ->
      return if answered
      answered = true
      cef.lib.neutrino_dialog_respond dialog_id, (ok and 1 or 0), (text or "")

    ok, result = pcall @_dialog_handler, info, respond, @
    unless ok
      io.stderr\write "[neutrino] dialog handler failed: #{tostring result}\n"
      return false

    result != false

  -- ═══════════════════════════════════════════════════════════════════════════
  -- ICON
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Sets the window and taskbar icon from a PNG.
  ---@param png string Either a path to a .png file or the PNG bytes themselves.
  ---@return boolean ok, string? error
  set_icon: (png) =>
    data = png

    -- Treat a short string with no PNG signature as a path.
    unless png\sub(1, 8) == "\137PNG\r\n\26\n"
      file, err = io.open png, "rb"
      return false, "could not open icon '#{png}': #{tostring err}" unless file
      data = file\read "*a"
      file\close!

    if cef.lib.neutrino_window_set_icon(@id, data, #data) == 1
      true
    else
      false, cef.last_error!

  -- ═══════════════════════════════════════════════════════════════════════════
  -- FILE DIALOGS
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Opens the platform file dialog.
  --
  -- Called from inside a task it awaits and returns the selection directly,
  -- which is what makes a file picker read like a function call rather than a
  -- chain of callbacks. Outside a task, pass a callback instead.
  --
  --     paths = win\show_open_dialog { title: "Ouvrir", filters: { ".mpq" } }
  --     return unless paths[1]
  --
  ---@param opts table mode, title, default_path, filters.
  ---@field opts.mode string "open", "open_multiple", "folder" or "save".
  ---@field opts.filters string[] Accept filters: ".png", "image/*" or "Label|.png;.jpg".
  ---@param callback? fun(paths: string[])
  ---@return string[]|integer paths when awaited, otherwise the request id.
  show_file_dialog: (opts = {}, callback) =>
    mode = switch opts.mode
      when "open_multiple" then 1
      when "folder" then 2
      when "save" then 3
      else 0

    filters = opts.filters and json.encode(opts.filters) or nil

    start = (resolve) ->
      request_id = cef.lib.neutrino_window_file_dialog @id, mode,
        (opts.title or ""), (opts.default_path or ""), filters

      if request_id == 0
        resolve {}
      else
        @_file_dialogs[request_id] = resolve

    return async.await start if callback == nil and async.is_async!

    start (paths) -> callback paths if callback

  --- Opens a dialog for choosing one existing file.
  ---@param opts? table Passed to show_file_dialog.
  ---@param callback? fun(paths: string[])
  show_open_dialog: (opts = {}, callback) =>
    opts.mode = "open"
    @show_file_dialog opts, callback

  --- Opens a dialog for choosing a save location.
  ---@param opts? table Passed to show_file_dialog.
  ---@param callback? fun(paths: string[])
  show_save_dialog: (opts = {}, callback) =>
    opts.mode = "save"
    @show_file_dialog opts, callback

  --- Opens a dialog for choosing a folder.
  ---@param opts? table Passed to show_file_dialog.
  ---@param callback? fun(paths: string[])
  show_folder_dialog: (opts = {}, callback) =>
    opts.mode = "folder"
    @show_file_dialog opts, callback

  --- Delivers a dismissed file dialog to whoever is waiting for it.
  ---@param request_id integer
  ---@param paths string[]
  ---@private
  _handle_file_dialog: (request_id, paths) =>
    resolve = @_file_dialogs[request_id]
    @_file_dialogs[request_id] = nil
    resolve paths if resolve

  -- ═══════════════════════════════════════════════════════════════════════════
  -- DOWNLOADS
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Decides what happens when the page starts a download.
  --
  -- The handler receives the download and a `begin` function. Calling
  -- `begin(path)` writes there; `begin(nil, true)` asks the user; returning
  -- false refuses the download outright. The handler may await first, so the
  -- destination can come from a file dialog.
  --
  -- With no handler registered, CEF asks the user where to save, which beats
  -- both refusing silently and writing somewhere nobody chose.
  --
  --     win\on_download (item, begin) ->
  --       paths = win\show_save_dialog { default_path: item.suggestedName }
  --       return false unless paths[1]
  --       begin paths[1]
  --
  ---@param handler fun(item: table, begin: fun(path?: string, ask?: boolean), window: BrowserWindow): boolean
  ---@return BrowserWindow self, for chaining.
  on_download: (handler) =>
    @_download_handler = handler
    @

  --- Offers a starting download to the handler.
  ---@param download_id integer
  ---@param info table
  ---@return boolean True when the application is choosing the destination.
  ---@private
  _handle_download: (download_id, info) =>
    return false unless @_download_handler

    decided = false
    begin = (path, ask) ->
      return if decided
      decided = true
      cef.lib.neutrino_download_begin download_id, (path or ""), (ask and 1 or 0)

    -- Run as a task so the handler may await a save dialog before deciding.
    refused = false
    async.run ->
      ok, result = pcall @_download_handler, info, begin, @
      unless ok
        io.stderr\write "[neutrino] download handler failed: #{tostring result}\n"
        cef.lib.neutrino_download_cancel download_id unless decided
        return

      if result == false and not decided
        decided = true
        refused = true
        cef.lib.neutrino_download_cancel download_id

    -- True either way: the download is ours now, decided already or pending.
    true

  -- ═══════════════════════════════════════════════════════════════════════════
  -- REQUEST INTERCEPTION
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Inspects every request the page makes, not only neutrino:// ones.
  --
  -- The handler returns what should happen: nil or nothing to let the request
  -- through, `{ cancel: true }` to block it, `{ redirect: url }` to send it
  -- elsewhere, or `{ headers: { ... } }` to rewrite request headers, where a
  -- false value removes one.
  --
  -- Every request goes through the Lua thread while this is registered, so
  -- register it only when it is wanted, and keep the handler quick.
  --
  --     win\on_request (req) ->
  --       return { cancel: true } if req.url\match "doubleclick%.net"
  --       { headers: { Authorization: "Bearer #{token}" } }
  --
  ---@param handler fun(request: table, window: BrowserWindow): table|nil
  ---@return BrowserWindow self, for chaining.
  on_request: (handler) =>
    @_resource_handler = handler
    @

  --- Turns a handler's answer into the native decision.
  ---@param request table
  ---@return string|nil json
  ---@private
  _handle_resource: (request) =>
    return nil unless @_resource_handler

    -- Bound to a local: see the note in _handle_can_close.
    handler = @_resource_handler
    decision = handler request, @
    return nil unless type(decision) == "table"

    if decision.cancel
      return json.encode { action: "cancel" }

    encoded = { action: decision.redirect and "redirect" or "continue" }
    encoded.url = decision.redirect if decision.redirect

    if decision.headers
      -- cjson drops a nil value, so removal is spelled false and translated to
      -- the JSON null the native side reads as "remove this header".
      headers = {}
      for name, value in pairs decision.headers
        headers[name] = value == false and json.null or tostring value
      encoded.headers = headers

    json.encode encoded

  --- Cancels a download, whether it is pending or already running.
  ---@param download_id integer
  ---@return BrowserWindow self, for chaining.
  cancel_download: (download_id) =>
    cef.lib.neutrino_download_cancel download_id
    @

  --- Pauses a running download.
  ---@param download_id integer
  ---@return BrowserWindow self, for chaining.
  pause_download: (download_id) =>
    cef.lib.neutrino_download_control download_id, 1
    @

  --- Resumes a paused download.
  ---@param download_id integer
  ---@return BrowserWindow self, for chaining.
  resume_download: (download_id) =>
    cef.lib.neutrino_download_control download_id, 2
    @

  --- Sends a mouse click at page coordinates.
  -- Press and release together, so the renderer sees a complete click.
  --
  -- Note that an injected right-click does not raise the context menu on a
  -- windowed browser: that menu is driven by the real window's input, not by
  -- events fed to the renderer. Clicks on page content do work.
  ---@param x integer
  ---@param y integer
  ---@param button? string "left" (default), "middle" or "right".
  ---@param click_count? integer Defaults to 1; 2 is a double click.
  ---@return BrowserWindow self, for chaining.
  click: (x, y, button = "left", click_count = 1) =>
    code = switch button
      when "right" then 2
      when "middle" then 1
      else 0

    cef.lib.neutrino_window_click @id, x, y, code, click_count
    @

  --- Returns the session this window's browser was created in.
  --
  -- Windows sharing a partition share one Session object, so cookies written
  -- through either are visible to both - they are the same store.
  --
  --     win\session!\get_cookies "https://example.com"
  --
  ---@return Session
  session: => sessions.for_partition @partition

  --- Returns the native window handle, an HWND on Windows.
  -- An escape hatch for platform-specific work; the framework itself never
  -- needs it, since everything goes through the Views layer.
  ---@return userdata
  get_native_handle: => cef.lib.neutrino_window_handle @id

{ :BrowserWindow }
