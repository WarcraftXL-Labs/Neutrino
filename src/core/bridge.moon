--- Routes the native callbacks to the right Lua object.
-- The C layer has one callback of each kind for the whole process, and every
-- one of them carries a window id. This module owns those callbacks and hands
-- each call to the matching BrowserWindow.
--
-- Every dispatcher is wrapped in pcall: an error escaping an FFI callback
-- unwinds through C++ frames, which LuaJIT cannot do safely.
-- @module core.bridge

ffi = require "ffi"
cef = require "core.cef"
json = require "util.json"

M = {
  -- window id -> BrowserWindow
  windows: {}
  -- Set by Server; receives every neutrino:// request.
  request_handler: nil
  -- timer id -> callback, registered by core.timer.
  timers: {}
  -- session request id -> resolver, registered by browser.session. Session work
  -- belongs to a partition rather than to a window, so it is routed by request
  -- id here instead of through a BrowserWindow.
  sessions: {}
  -- Set by App; called once the last window has gone.
  on_last_window_closed: nil
  -- Set by system.shell; receives the arguments of a second launch.
  second_instance: nil
  installed: false
}

report = (context, err) ->
  io.stderr\write "[neutrino] error in #{context}: #{tostring err}\n"

--- Registers a window so callbacks carrying its id reach it.
M.register = (window) ->
  M.windows[window.id] = window

--- Forgets a window. Called once its "closed" event has been delivered.
M.unregister = (id) ->
  return unless M.windows[id]
  M.windows[id] = nil

  -- CEF's loop keeps running with no windows left, so something has to decide
  -- when the application is over. App installs this hook.
  if M.on_last_window_closed and M.count! == 0
    M.on_last_window_closed!

--- Returns the window for an id, or nil.
M.window = (id) ->
  M.windows[id]

--- Number of windows the Lua side is currently tracking.
M.count = ->
  n = 0
  n += 1 for _ in pairs M.windows
  n

-- ═══════════════════════════════════════════════════════════════════════════
-- DISPATCHERS
-- ═══════════════════════════════════════════════════════════════════════════

dispatch_invoke = (window_id, request_id, channel_ptr, args_ptr, user) ->
  channel = ffi.string channel_ptr
  window = M.windows[window_id]

  unless window
    report "IPC dispatch", "no window #{window_id} for channel '#{channel}'"
    cef.lib.neutrino_invoke_reject request_id, -1, "unknown window #{window_id}"
    return nil

  ok, result = pcall window._handle_invoke, window, request_id, channel,
    (ffi.string args_ptr)

  unless ok
    report "IPC channel '#{channel}'", result
    cef.lib.neutrino_invoke_reject request_id, -1, tostring result
    return nil

  -- nil means the handler awaited something; it will resolve by request id.
  return nil if result == nil

  -- C reads this pointer as soon as we return, so the string has to outlive
  -- the callback frame.
  cef.anchors.invoke_result = result
  cef.anchors.invoke_result

dispatch_event = (window_id, event_ptr, json_ptr, user) ->
  event = ffi.string event_ptr
  window = M.windows[window_id]
  return unless window

  detail, decode_error = json.try_decode (ffi.string json_ptr)
  unless detail
    report "event '#{event}' payload", decode_error
    detail = {}

  ok, err = pcall window._handle_event, window, event, detail
  report "event '#{event}'", err unless ok

dispatch_can_close = (window_id, user) ->
  window = M.windows[window_id]
  return 1 unless window

  ok, allowed = pcall window._handle_can_close, window
  unless ok
    report "close handler", allowed
    return 1  -- never trap the user in an unclosable window

  allowed == false and 0 or 1

dispatch_eval = (window_id, request_id, ok_flag, json_ptr, user) ->
  window = M.windows[window_id]
  return unless window

  ok, err = pcall window._handle_eval, window, request_id, ok_flag == 1,
    (ffi.string json_ptr)
  report "eval result", err unless ok

dispatch_context_menu = (window_id, params_ptr, user) ->
  window = M.windows[window_id]
  return nil unless window

  raw = ffi.string params_ptr
  params, decode_error = json.try_decode raw
  unless params
    -- Falling back to an empty table here would turn a malformed payload into
    -- a confusing nil field inside the application's own callback. The raw text
    -- goes in the report too: without it, a decode failure says nothing about
    -- which field produced it.
    report "context menu params", "#{decode_error} | raw: #{raw\sub 1, 300}"
    return nil

  ok, items = pcall window._handle_context_menu, window, params

  unless ok
    report "context menu", items
    return nil

  return nil if items == nil

  -- Read by C as soon as we return, so it has to outlive this frame.
  cef.anchors.menu_items = items
  cef.anchors.menu_items

dispatch_key = (window_id, event_ptr, user) ->
  window = M.windows[window_id]
  return 0 unless window

  event, decode_error = json.try_decode (ffi.string event_ptr)
  unless event
    report "key event payload", decode_error
    return 0

  ok, handled = pcall window._handle_key, window, event
  unless ok
    report "key handler", handled
    return 0

  handled == true and 1 or 0

dispatch_dialog = (window_id, dialog_id, info_ptr, user) ->
  window = M.windows[window_id]
  return 0 unless window

  info, decode_error = json.try_decode (ffi.string info_ptr)
  unless info
    report "dialog payload", decode_error
    return 0

  ok, handled = pcall window._handle_dialog, window, dialog_id, info
  unless ok
    report "dialog handler", handled
    return 0

  handled == true and 1 or 0

dispatch_resource = (window_id, request_ptr, user) ->
  window = M.windows[window_id]
  return nil unless window

  request, decode_error = json.try_decode (ffi.string request_ptr)
  unless request
    report "resource request", decode_error
    return nil

  ok, decision = pcall window._handle_resource, window, request
  unless ok
    -- A failing interceptor must not take the page down with it: letting the
    -- request through is the safe reading of "the handler had no answer".
    report "resource interceptor", decision
    return nil

  return nil if decision == nil

  cef.anchors.resource_decision = decision
  cef.anchors.resource_decision

dispatch_file_dialog = (window_id, request_id, paths_ptr, user) ->
  window = M.windows[window_id]
  return unless window

  paths, decode_error = json.try_decode (ffi.string paths_ptr)
  unless paths
    report "file dialog paths", decode_error
    paths = {}

  ok, err = pcall window._handle_file_dialog, window, request_id, paths
  report "file dialog", err unless ok

dispatch_download = (window_id, download_id, info_ptr, user) ->
  window = M.windows[window_id]
  return 0 unless window

  info, decode_error = json.try_decode (ffi.string info_ptr)
  unless info
    report "download info", decode_error
    return 0

  ok, handled = pcall window._handle_download, window, download_id, info
  unless ok
    report "download handler", handled
    return 0

  handled == true and 1 or 0

dispatch_session = (request_id, ok_flag, json_ptr, user) ->
  resolve = M.sessions[request_id]
  return unless resolve

  -- Dropped first: the native side answers a request id exactly once, and
  -- clearing before the callback runs keeps a raising resolver from leaving a
  -- stale entry behind.
  M.sessions[request_id] = nil

  raw = ffi.string json_ptr
  value, decode_error = json.try_decode raw

  ok, err = if ok_flag == 1
    if value == nil
      pcall resolve, nil, "malformed session result: #{decode_error} | raw: #{raw\sub 1, 200}"
    else
      pcall resolve, value, nil
  else
    -- A failure carries its message as a JSON string, so the decoded value is
    -- the message; the raw text is the fallback if even that failed to parse.
    pcall resolve, nil, (type(value) == "string" and value or raw)

  report "session result", err unless ok

dispatch_second_instance = (payload_ptr, user) ->
  return unless M.second_instance

  raw = ffi.string payload_ptr

  -- Split on the tab system.shell joins with, so the handler receives the same
  -- shape as `arg` rather than one string it has to take apart itself.
  args = {}
  for piece in raw\gmatch "[^\t]+"
    table.insert args, piece

  handler = M.second_instance
  ok, err = pcall handler, args, raw
  report "second instance", err unless ok

dispatch_timer = (timer_id, user) ->
  callback = M.timers[timer_id]
  return unless callback

  ok, err = pcall callback, timer_id
  report "timer #{timer_id}", err unless ok

dispatch_request = (window_id, response_id, method_ptr, url_ptr, headers_ptr,
                    body_ptr, body_len, user) ->
  unless M.request_handler
    body = "Neutrino: no Server attached"
    cef.lib.neutrino_response_set response_id, 503, "text/plain", nil, body, #body
    return

  request = {
    window_id: window_id
    method: ffi.string method_ptr
    url: ffi.string url_ptr
    headers_json: ffi.string headers_ptr
    body: body_len > 0 and (ffi.string body_ptr, body_len) or ""
  }

  ok, err = pcall M.request_handler, request, response_id
  unless ok
    report "request #{request.method} #{request.url}", err
    body = "<h1>500 Internal Server Error</h1><pre>#{tostring err}</pre>"
    cef.lib.neutrino_response_set response_id, 500, "text/html", nil, body, #body

--- Installs the native callbacks. Safe to call more than once.
M.install = ->
  return if M.installed
  error "bridge.install called before cef.setup" unless cef.lib

  -- Anchored so the GC never collects a callback the C side still holds.
  cef.anchors.cb_invoke = ffi.cast "neutrino_invoke_fn", dispatch_invoke
  cef.anchors.cb_event = ffi.cast "neutrino_event_fn", dispatch_event
  cef.anchors.cb_can_close = ffi.cast "neutrino_can_close_fn", dispatch_can_close
  cef.anchors.cb_eval = ffi.cast "neutrino_eval_fn", dispatch_eval
  cef.anchors.cb_timer = ffi.cast "neutrino_timer_fn", dispatch_timer
  cef.anchors.cb_context_menu = ffi.cast "neutrino_context_menu_fn", dispatch_context_menu
  cef.anchors.cb_key = ffi.cast "neutrino_key_fn", dispatch_key
  cef.anchors.cb_dialog = ffi.cast "neutrino_dialog_fn", dispatch_dialog
  cef.anchors.cb_file_dialog = ffi.cast "neutrino_file_dialog_fn", dispatch_file_dialog
  cef.anchors.cb_download = ffi.cast "neutrino_download_fn", dispatch_download
  cef.anchors.cb_resource = ffi.cast "neutrino_resource_fn", dispatch_resource
  cef.anchors.cb_request = ffi.cast "neutrino_request_fn", dispatch_request
  cef.anchors.cb_session = ffi.cast "neutrino_session_fn", dispatch_session
  cef.anchors.cb_second_instance = ffi.cast "neutrino_second_instance_fn",
    dispatch_second_instance

  cef.lib.neutrino_set_invoke_handler cef.anchors.cb_invoke, nil
  cef.lib.neutrino_set_event_handler cef.anchors.cb_event, nil
  cef.lib.neutrino_set_can_close_handler cef.anchors.cb_can_close, nil
  cef.lib.neutrino_set_eval_handler cef.anchors.cb_eval, nil
  cef.lib.neutrino_set_timer_handler cef.anchors.cb_timer, nil
  cef.lib.neutrino_set_context_menu_handler cef.anchors.cb_context_menu, nil
  cef.lib.neutrino_set_key_handler cef.anchors.cb_key, nil
  cef.lib.neutrino_set_dialog_handler cef.anchors.cb_dialog, nil
  cef.lib.neutrino_set_file_dialog_handler cef.anchors.cb_file_dialog, nil
  cef.lib.neutrino_set_download_handler cef.anchors.cb_download, nil
  cef.lib.neutrino_set_resource_handler cef.anchors.cb_resource, nil
  cef.lib.neutrino_set_request_handler cef.anchors.cb_request, nil
  cef.lib.neutrino_set_session_handler cef.anchors.cb_session, nil
  cef.lib.neutrino_set_second_instance_handler cef.anchors.cb_second_instance, nil

  M.installed = true

M
