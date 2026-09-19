--- Application lifecycle and event loop, in the style of Electron's app module.
--
-- CEF owns the message loop and runs it on the thread that called init(), so
-- that thread is both the CEF UI thread and the Lua thread. Every callback the
-- framework hands you arrives there, which is why nothing in the framework
-- needs locking or marshalling.
--
-- The cost is the same one Electron pays: a handler that blocks for a long time
-- blocks the UI. Waiting, however, does not - see core.async.
---@module core.app

EventEmitter = (require "core.events").EventEmitter
bridge = require "core.bridge"
cef = require "core.cef"
servers = require "serve.server"
timer = require "core.timer"

---@class App : EventEmitter
---@field state string "init", "initialized", "running", "quitting" or "stopped".
---@field extensions Extension[] Registered extensions.
class App extends EventEmitter
  --- Creates the application.
  ---@param opts table Options passed to the native layer.
  ---@field opts.scheme string Custom scheme name. Defaults to "neutrino".
  ---@field opts.cache_path string Directory for the browser cache.
  ---@field opts.root_cache_path string Parent of every cache path.
  ---@field opts.subprocess_path string Path to neutrinocef_helper.exe.
  ---@field opts.resources_path string Directory holding the CEF .pak files.
  ---@field opts.locales_path string Directory holding the locale .pak files.
  ---@field opts.log_file string Path for CEF's log.
  ---@field opts.log_severity integer CEF log severity.
  ---@field opts.user_agent string Overrides the default user agent.
  ---@field opts.locale string Application locale.
  ---@field opts.remote_debugging_port integer Enables DevTools over HTTP.
  ---@field opts.persist_session_cookies boolean Keeps session cookies on disk.
  ---@field opts.disable_gpu boolean Forces software rendering.
  ---@field opts.angle_backend string Which backend ANGLE translates GL to:
  --- "d3d11", "gl", "vulkan" or "swiftshader". Empty leaves Chromium to
  --- choose, which is right on most machines; name one where the default
  --- leaves the page with no WebGL context.
  ---@field opts.background table RGB triple for the default background.
  ---@field opts.quit_on_last_window boolean Stops the loop when the last window
  --- closes. Defaults to true.
  new: (opts = {}) =>
    super!

    @options = opts
    @state = "init"
    @extensions = {}

    @_running = false
    @_initialized = false
    @_quit_on_last_window = opts.quit_on_last_window != false

  --- Brings up CEF.
  -- run() calls this; call it directly only when a window has to exist before
  -- the loop starts. Calling it twice is a no-op.
  ---@return App self, for chaining.
  init: =>
    return @ if @_initialized

    unless cef.lib
      error "App requires the native library. Call Neutrino.cef.setup(dir) first."

    unless cef.lib.neutrino_init(cef.build_app_options @options) == 1
      error "failed to initialise CEF: #{cef.last_error!}"

    bridge.install!

    if @_quit_on_last_window
      -- CEF keeps running with no windows left, so the application decides when
      -- it is over.
      bridge.on_last_window_closed = -> @quit!

    @_initialized = true
    @state = "initialized"
    @

  --- The server serving the custom scheme, created on first use.
  -- An application that built its own with Neutrino.Server gets that one back.
  ---@return Server
  server: => servers.current!

  --- Instantiates an extension class, registers it and starts it.
  --
  -- Starting registers the extension's routes, so an extension is serving as soon as
  -- it is registered. One registered while the application is already running
  -- gets its "ready" straight away rather than never.
  ---@param extension_class table A class deriving from Extension.
  ---@return Extension The instance.
  register_extension: (extension_class) =>
    instance = extension_class @

    -- The UI runtime answers on ui:state and ui:ready, so an extension called "ui"
    -- would collide with it on every window it attached to.
    if instance.name == "ui"
      error "'ui' is reserved: the UI runtime uses that channel prefix"

    -- Two extensions sharing a name would share an origin and an IPC prefix, and
    -- unregistering either would take down the other's routes.
    for existing in *@extensions
      if existing.name == instance.name
        error "an extension named '#{instance.name}' is already registered"

    table.insert @extensions, instance

    instance\start! if instance.start
    instance\on_ready! if @state == "running" and instance.on_ready

    instance

  --- Takes an extension back down and forgets it.
  -- The extension releases its routes, its IPC handlers, its timers and its
  -- windows; see Extension:stop.
  ---@param target Extension|string The extension or its name.
  ---@return Extension|nil The extension that was removed.
  unregister_extension: (target) =>
    name = type(target) == "string" and target or target.name

    for index, mod in ipairs @extensions
      continue unless mod.name == name

      table.remove @extensions, index
      mod\on_quit! if mod.on_quit
      mod\stop! if mod.stop
      return mod

    nil

  --- Finds a registered extension by name.
  ---@param name string
  ---@return Extension|nil
  extension: (name) =>
    for mod in *@extensions
      return mod if mod.name == name
    nil

  --- Schedules a function to run after a delay, and optionally repeat.
  ---@param delay_ms integer Delay before the first run.
  ---@param callback function The function to run.
  ---@param interval_ms? integer Repeat interval; omit for a one-shot timer.
  ---@return integer id Stop it with App:clear_timer(id).
  set_timer: (delay_ms, callback, interval_ms = 0) =>
    if interval_ms > 0
      timer.every interval_ms, callback, delay_ms
    else
      timer.after delay_ms, callback

  --- Cancels a timer started with set_timer.
  ---@param id integer
  clear_timer: (id) =>
    timer.stop id
    @

  --- Runs the event loop until quit() is called or the last window closes.
  -- Emits "ready" once CEF is up, then "quit" as the loop exits.
  ---@return App self, for chaining.
  run: =>
    @init!

    @state = "running"
    @emit "ready"

    for mod in *@extensions
      mod\on_ready! if mod.on_ready

    @_running = true

    -- Blocks inside CEF until quit(). Callbacks, timers and IPC all run on this
    -- thread while it does.
    cef.lib.neutrino_run!

    @_running = false
    @state = "quitting"
    @emit "quit"

    -- on_quit only: Extension:stop closes windows and drops routes, which is what
    -- unregistering needs and what shutting down does not. CEF is on its way
    -- out, so poking it here would be work at best and a crash at worst.
    for mod in *@extensions
      mod\on_quit! if mod.on_quit

    cef.lib.neutrino_shutdown!
    @state = "stopped"
    @

  --- Stops the loop, which makes run() return.
  ---@return App self, for chaining.
  quit: =>
    cef.lib.neutrino_quit! if @_initialized
    @

{ :App }
