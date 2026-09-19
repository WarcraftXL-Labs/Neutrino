--- A named scope that claims things and can give them all back.
--
-- Nothing here is a required way to build with Neutrino: an application can
-- open a window and register routes without ever declaring one. What this adds
-- is a boundary. It claims a name, and that name becomes everything it owns:
--
--   neutrino://<name>/   its origin, and the only routes it can serve
--   "<name>:action"      the IPC channels it answers on
--   "persist:<name>"     its session, when it asks for one
--
-- Because the boundary is real rather than a convention, one can be taken back
-- down at runtime: App:unregister_extension drops its routes, removes its IPC
-- handlers from every window it reached, cancels its timers and closes the
-- windows it opened. That releasing is the whole point; everything else here
-- exists so that `stop` has something to release.
--
-- It is called an extension rather than a module because a framework should not
-- name the shape of the application built on it. "Module" invited an
-- architecture - one that WowLabs, the only application on this framework, does
-- not use - and the invitation was written into the code: `default_name` used
-- to strip a "Module" suffix, expecting classes called `ArchiveModule`.
--
-- Two of them can share one window, which is what `attach` is for; one can own
-- its own, which is what `open` is for. Neither is assumed.
--
--     class Mpq extends Extension
--       name: "mpq"
--       partition: true          -- persist:mpq
--
--       routes: (router) =>
--         router\get "/", (req, res) -> res\html @page!
--         router\get "/tree/*", (req, res) -> res\json @read req.params.splat
--
--       on_ready: =>
--         @handle "open", (payload) -> @open_archive payload.path
--         @window = @open title: "Archives"
--
--     app\register_extension Mpq
---@module core.extension

servers = require "serve.server"
timer = require "core.timer"
log = require "util.log"
BrowserWindow = (require "browser.window").BrowserWindow

--- Derives a namespace from a class name, so one that does not declare a name
--- still gets something predictable rather than "UnnamedExtension".
--
-- `MpqBrowser` becomes "mpq-browser", `ArchiveExtension` becomes "archive".
---@param class_name? string
---@return string
default_name = (class_name) ->
  return "extension" unless class_name

  name = class_name\gsub "Extension$", ""
  name = name\gsub "(%l)(%u)", "%1-%2"
  name = name\lower!

  name != "" and name or "extension"

---@class Extension
---@field app App The application that owns this extension.
---@field name string Its namespace.
---@field server Server The server its routes live on.
---@field router Router Routes for neutrino://<name>/.
---@field origin string "neutrino://<name>/".
---@field windows BrowserWindow[] Windows it opened itself.
---@field started boolean
class Extension
  --- The session its windows use.
  -- A string names a partition; `true` means "persist:<name>", which is the
  -- usual choice for an extension with state of its own. Declared as a class field.
  partition: false

  --- Creates the extension and binds it to an application.
  -- App:register_extension does this; construct one directly only to use an extension
  -- outside an application.
  ---@param app? App The application that owns this extension.
  new: (app) =>
    @app = app

    -- A subclass usually declares `name` as a class field. Falling back to the
    -- class name keeps an extension that forgot from colliding with every other
    -- extension that forgot.
    @name or= default_name @@__name

    @server = servers.current!
    @router = @server\host @name

    scheme = app and app.options and app.options.scheme or "neutrino"
    @origin = "#{scheme}://#{@name}/"

    @windows = {}
    @started = false

    -- Action -> handler, and the windows they have been installed on. Kept
    -- apart because a window can be attached after a handler is declared and a
    -- handler declared after a window is attached; both have to end up wired.
    @_handlers = {}
    @_attached = {}
    @_timers = {}

  -- ═══════════════════════════════════════════════════════════════════════════
  -- HOOKS  (subclasses override these; the defaults do nothing)
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Registers its routes. Called by start().
  -- The router is its own, already bound to neutrino://<name>/, so a
  -- path registered here is relative to that origin.
  ---@param router Router The extension's router.
  routes: (router) =>

  --- Runs when the application is ready, or immediately when the extension is
  --- registered after that. Subclasses open their windows here.
  on_ready: =>

  --- Runs when the application is shutting down, or when the extension is
  --- unregistered. Subclasses release what the framework cannot see.
  on_quit: =>

  -- ═══════════════════════════════════════════════════════════════════════════
  -- LIFECYCLE
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Brings the extension up by registering its routes.
  --- Calling it twice is a no-op.
  ---@return Extension self, for chaining.
  start: =>
    return @ if @started
    @started = true
    @routes @router
    @

  --- Takes the extension back down.
  --
  -- Everything the extension claimed is released: its routes, its IPC handlers on
  -- every window it attached to, its timers, and the windows it opened itself.
  -- Windows it was merely attached to stay open, because it does not own them -
  -- only its handlers are removed.
  ---@return Extension self, for chaining.
  stop: =>
    return @ unless @started
    @started = false

    for window in *@_attached
      continue if window.closed
      for action in pairs @_handlers
        window\unhandle @channel action

    timer.stop id for id in *@_timers

    -- Forced, because an extension being unregistered has already had its say in
    -- on_quit; a close guard vetoing here would leave it half removed.
    for window in *@windows
      window\close true unless window.closed

    -- The extension owns the origin outright, so this drops its routes and nobody
    -- else's.
    @server\drop_host @name

    @windows = {}
    @_attached = {}
    @_timers = {}
    @

  -- ═══════════════════════════════════════════════════════════════════════════
  -- NAMESPACE
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Builds a URL under its own origin.
  ---@param path? string Path, with or without a leading slash.
  ---@return string
  url: (path = "/") =>
    path = "/#{path}" unless path\sub(1, 1) == "/"
    @origin\sub(1, -2) .. path

  --- Prefixes an action with its namespace.
  ---@param action string
  ---@return string channel "<name>:<action>".
  channel: (action) => "#{@name}:#{action}"

  --- The partition name its windows use.
  ---@return string "" for the default session.
  partition_name: =>
    return "persist:#{@name}" if @partition == true
    return @partition if type(@partition) == "string"
    ""

  --- Explains why a window will not store through its session, or nil
  --- when it will.
  --
  -- A window has exactly one partition, so an extension attached to somebody
  -- else's window stores through that window's session no matter what it
  -- declared. `partition_name` still answers with what it asked for, so the two
  -- diverge - which is worth saying out loud rather than leaving to be
  -- discovered later.
  ---@param window BrowserWindow
  ---@return string|nil
  partition_mismatch: (window) =>
    wanted = @partition_name!
    return nil if wanted == "" or not window
    return nil if window.partition == wanted

    "extension '#{@name}' expects partition '#{wanted}' but the window it " ..
      "attached to uses '#{window.partition}'; the page stores through the " ..
      "window's"

  --- Runs a request through the routers and hands the reply back to Lua.
  -- A bare path is resolved against its own origin, so an extension can
  -- fetch its own routes; an absolute URL reaches any extension.
  ---@param url string Path or absolute URL.
  ---@param opts? table Passed to Server:fetch. May be the callback.
  ---@param callback? fun(reply: table)
  ---@return table|nil reply when awaited.
  fetch: (url, opts, callback) =>
    url = @url url unless url\find "://", 1, true
    @server\fetch url, opts or {}, callback

  -- ═══════════════════════════════════════════════════════════════════════════
  -- WINDOWS AND IPC
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Registers an IPC handler, reachable from the page as
  --- `neutrino.invoke("<name>:<action>")`.
  --
  -- The handler is installed on every window the extension is attached to, now and
  -- later. The namespace is what lets two modules share one window.
  ---@param action string Action name, without the extension prefix.
  ---@param handler fun(payload: any, window: BrowserWindow): any
  ---@return Extension self, for chaining.
  handle: (action, handler) =>
    @_handlers[action] = handler

    channel = @channel action
    for window in *@_attached
      window\handle channel, handler unless window.closed

    @

  --- Installs its handlers on a window it did not open.
  -- This is how a shell window hosts several modules at once.
  ---@param window BrowserWindow
  ---@return Extension self, for chaining.
  attach: (window) =>
    return @ unless window and not window.closed

    if mismatch = @partition_mismatch window
      log.warn "%s", mismatch

    for attached in *@_attached
      return @ if attached == window

    table.insert @_attached, window
    for action, handler in pairs @_handlers
      window\handle (@channel action), handler

    @

  --- Removes its handlers from a window and forgets it.
  ---@param window BrowserWindow
  ---@return Extension self, for chaining.
  detach: (window) =>
    for index, attached in ipairs @_attached
      continue unless attached == window

      unless window.closed
        for action in pairs @_handlers
          window\unhandle @channel action

      table.remove @_attached, index
      break

    @

  --- Opens a window belonging to the extension.
  --
  -- The extension's origin, partition and handlers are applied unless the options
  -- say otherwise, and the window closes with the extension.
  ---@param opts? table Window options, as BrowserWindow takes them.
  ---@return BrowserWindow
  open: (opts = {}) =>
    options = { key, value for key, value in pairs opts }
    options.url or= @url!
    options.title or= @name
    options.partition or= @partition_name!

    window = BrowserWindow options
    table.insert @windows, window
    @attach window

    window\on "closed", -> @_forget window
    window

  --- Pushes an event to every window the extension is attached to, received by
  --- `neutrino.on("<name>:<event>")`.
  ---@param event string Event name, without the extension prefix.
  ---@param payload? any Any JSON-encodable value.
  ---@return Extension self, for chaining.
  broadcast: (event, payload) =>
    channel = @channel event
    for window in *@_attached
      window\send channel, payload unless window.closed
    @

  --- Schedules a timer that is cancelled when the extension stops.
  ---@param delay_ms integer
  ---@param callback function
  ---@param interval_ms? integer Repeat interval; omit for a one-shot timer.
  ---@return integer id
  set_timer: (delay_ms, callback, interval_ms = 0) =>
    id = if interval_ms > 0
      timer.every interval_ms, callback, delay_ms
    else
      timer.after delay_ms, callback

    table.insert @_timers, id
    id

  --- Drops a closed window from both lists.
  ---@param window BrowserWindow
  ---@private
  _forget: (window) =>
    for index, owned in ipairs @windows
      if owned == window
        table.remove @windows, index
        break

    for index, attached in ipairs @_attached
      if attached == window
        table.remove @_attached, index
        break

{ :Extension, :default_name }
