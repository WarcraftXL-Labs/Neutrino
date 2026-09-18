--- Self-contained parts of an application.
--
-- A module is not a required way to build with Neutrino: an application can
-- open a window and register routes without ever declaring one. What a module
-- adds is a boundary. It claims a name, and that name becomes everything it
-- owns:
--
--   neutrino://<name>/   its origin, and the only routes it can serve
--   "<name>:action"      the IPC channels it answers on
--   "persist:<name>"     its session, when it asks for one
--
-- Because the boundary is real rather than a convention, a module can be taken
-- back down at runtime: App:unregister_module drops its routes, removes its IPC
-- handlers from every window it reached, cancels its timers and closes the
-- windows it opened. That is what lets one shell host several tools that do not
-- know about each other.
--
--     class Mpq extends Module
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
--     app\register_module Mpq
---@module core.module

sessions = require "browser.session"
servers = require "serve.server"
timer = require "core.timer"
BrowserWindow = (require "browser.window").BrowserWindow

--- Derives a namespace from a class name, so a module that does not declare
--- one still gets something predictable rather than "UnnamedModule".
--
-- `MpqBrowser` becomes "mpq-browser", `ArchiveModule` becomes "archive".
---@param class_name? string
---@return string
default_name = (class_name) ->
  return "module" unless class_name

  name = class_name\gsub "Module$", ""
  name = name\gsub "(%l)(%u)", "%1-%2"
  name = name\lower!

  name != "" and name or "module"

---@class Module
---@field app App The application that owns this module.
---@field name string The module's namespace.
---@field server Server The server its routes live on.
---@field router Router Routes for neutrino://<name>/.
---@field origin string "neutrino://<name>/".
---@field windows BrowserWindow[] Windows this module opened.
---@field started boolean
class Module
  --- The session the module's windows use.
  -- A string names a partition; `true` means "persist:<name>", which is the
  -- usual choice for a module with state of its own. Declared as a class field.
  partition: false

  --- Creates the module and binds it to an application.
  -- App:register_module does this; construct one directly only to use a module
  -- outside an application.
  ---@param app? App The application that owns this module.
  new: (app) =>
    @app = app

    -- A subclass usually declares `name` as a class field. Falling back to the
    -- class name keeps a module that forgot from colliding with every other
    -- module that forgot.
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

  --- Registers the module's routes. Called by start().
  -- The router is the module's own, already bound to neutrino://<name>/, so a
  -- path registered here is relative to that origin.
  ---@param router Router The module's router.
  routes: (router) =>

  --- Runs when the application is ready, or immediately when the module is
  --- registered after that. Subclasses open their windows here.
  on_ready: =>

  --- Runs when the application is shutting down, or when the module is
  --- unregistered. Subclasses release what the framework cannot see.
  on_quit: =>

  -- ═══════════════════════════════════════════════════════════════════════════
  -- LIFECYCLE
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Brings the module up by registering its routes.
  --- Calling it twice is a no-op.
  ---@return Module self, for chaining.
  start: =>
    return @ if @started
    @started = true
    @routes @router
    @

  --- Takes the module back down.
  --
  -- Everything the module claimed is released: its routes, its IPC handlers on
  -- every window it attached to, its timers, and the windows it opened itself.
  -- Windows it was merely attached to stay open, because it does not own them -
  -- only its handlers are removed.
  ---@return Module self, for chaining.
  stop: =>
    return @ unless @started
    @started = false

    for window in *@_attached
      continue if window.closed
      for action in pairs @_handlers
        window\unhandle @channel action

    timer.stop id for id in *@_timers

    -- Forced, because a module being unregistered has already had its say in
    -- on_quit; a close guard vetoing here would leave it half removed.
    for window in *@windows
      window\close true unless window.closed

    -- The module owns the origin outright, so this drops its routes and nobody
    -- else's.
    @server\drop_host @name

    @windows = {}
    @_attached = {}
    @_timers = {}
    @

  -- ═══════════════════════════════════════════════════════════════════════════
  -- NAMESPACE
  -- ═══════════════════════════════════════════════════════════════════════════

  --- Builds a URL under the module's own origin.
  ---@param path? string Path, with or without a leading slash.
  ---@return string
  url: (path = "/") =>
    path = "/#{path}" unless path\sub(1, 1) == "/"
    @origin\sub(1, -2) .. path

  --- Prefixes an action with the module's namespace.
  ---@param action string
  ---@return string channel "<name>:<action>".
  channel: (action) => "#{@name}:#{action}"

  --- The partition name the module's windows use.
  ---@return string "" for the default session.
  partition_name: =>
    return "persist:#{@name}" if @partition == true
    return @partition if type(@partition) == "string"
    ""

  --- The module's session.
  ---@return Session
  session: => sessions.for_partition @partition_name!

  --- Explains why a window will not store through the module's session, or nil
  --- when it will.
  --
  -- A window has exactly one partition, so a module attached to somebody else's
  -- window stores through that window's session no matter what it declared. The
  -- module's own `session()` still answers about its own partition, so the two
  -- diverge - which is worth saying out loud rather than leaving to be
  -- discovered later.
  ---@param window BrowserWindow
  ---@return string|nil
  partition_mismatch: (window) =>
    wanted = @partition_name!
    return nil if wanted == "" or not window
    return nil if window.partition == wanted

    "module '#{@name}' expects partition '#{wanted}' but the window it " ..
      "attached to uses '#{window.partition}'; the page stores through the " ..
      "window's"

  --- Serves a directory of files under the module's own origin.
  --
  -- A module that ships its own icons or fonts keeps them with itself, so
  -- unregistering it takes its routes with it. A module that only needs the
  -- application's shared assets does not call this and uses those.
  ---@param directory string Directory on disk, relative to the app root.
  ---@param prefix? string Url prefix. Defaults to "/assets".
  ---@param opts? table index, cache and types; see serve.static.
  ---@return Module self, for chaining.
  static: (directory, prefix = "/assets", opts) =>
    @router\static prefix, directory, opts
    @

  --- Runs a request through the routers and hands the reply back to Lua.
  -- A bare path is resolved against the module's own origin, so a module can
  -- fetch its own routes; an absolute URL reaches any module.
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
  -- The handler is installed on every window the module is attached to, now and
  -- later. The namespace is what lets two modules share one window.
  ---@param action string Action name, without the module prefix.
  ---@param handler fun(payload: any, window: BrowserWindow): any
  ---@return Module self, for chaining.
  handle: (action, handler) =>
    @_handlers[action] = handler

    channel = @channel action
    for window in *@_attached
      window\handle channel, handler unless window.closed

    @

  --- Installs the module's handlers on a window it did not open.
  -- This is how a shell window hosts several modules at once.
  ---@param window BrowserWindow
  ---@return Module self, for chaining.
  attach: (window) =>
    return @ unless window and not window.closed

    if mismatch = @partition_mismatch window
      io.stderr\write "[neutrino] #{mismatch}\n"

    for attached in *@_attached
      return @ if attached == window

    table.insert @_attached, window
    for action, handler in pairs @_handlers
      window\handle (@channel action), handler

    @

  --- Removes the module's handlers from a window and forgets it.
  ---@param window BrowserWindow
  ---@return Module self, for chaining.
  detach: (window) =>
    for index, attached in ipairs @_attached
      continue unless attached == window

      unless window.closed
        for action in pairs @_handlers
          window\unhandle @channel action

      table.remove @_attached, index
      break

    @

  --- Opens a window belonging to the module.
  --
  -- The module's origin, partition and handlers are applied unless the options
  -- say otherwise, and the window closes with the module.
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

  --- Pushes an event to every window the module is attached to, received by
  --- `neutrino.on("<name>:<event>")`.
  ---@param event string Event name, without the module prefix.
  ---@param payload? any Any JSON-encodable value.
  ---@return Module self, for chaining.
  broadcast: (event, payload) =>
    channel = @channel event
    for window in *@_attached
      window\send channel, payload unless window.closed
    @

  --- Schedules a timer that is cancelled when the module stops.
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

{ :Module, :default_name }
