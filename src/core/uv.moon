--- Servicing libuv's loop from CEF's.
--
-- CEF owns the application's message loop; libuv has one of its own and nobody
-- runs it. Without this, `uv.spawn`, a filesystem watcher and a socket all
-- register happily and then never call back - no error, no warning, nothing
-- happens at all. That is the worst shape a gap can take.
--
-- So libuv is pumped from a CEF delayed task: `uv.run "nowait"` drains whatever
-- is ready, and the next pump is scheduled for when libuv says it next wants
-- attention. Nothing is polled when there is nothing to poll, and nothing
-- sleeps longer than libuv asked to.
--
--     uv = Neutrino.uv
--     handle = uv.luv!.spawn "cmd.exe", { args: { "/c", "dir" } }, on_exit
--     uv.wake!                            -- from here it will actually fire
--
-- Framework calls that create libuv work wake it themselves. Raw libuv used
-- directly is the case that needs the call, because nothing else can see it.
---@module core.uv

timer = require "core.timer"

-- Never longer than this between pumps while the loop has work, so a handle
-- that libuv would block on indefinitely - a watcher, a socket - is still
-- serviced promptly.
MAX_DELAY = 50

-- And never shorter, so a loop with something immediately ready cannot turn
-- into a spin that starves the UI.
MIN_DELAY = 1

M = {}

luv = nil
luv_missing = false

scheduled = nil     -- id of the pending pump, or nil when idle
retained = 0        -- callers that need the loop serviced regardless

--- Returns luv, or nil when it is not installed.
-- Everything here degrades to doing nothing rather than raising: luv is the one
-- rock `get-deps` treats as optional.
---@return table|nil
M.luv = ->
  return luv if luv
  return nil if luv_missing

  ok, result = pcall require, "luv"
  unless ok
    luv_missing = true
    return nil

  luv = result
  luv

-- Forward declaration. The two below call each other, and without this the
-- reference in `schedule` compiles to a global lookup that resolves to nil -
-- which fails inside a timer callback, where nobody is listening.
pump = nil

--- Schedules the next pump, unless one is already pending.
---@param delay integer
---@private
schedule = (delay) ->
  return if scheduled

  -- pcall: timers are CEF tasks, and code may reach here before CEF is up.
  -- Failing to schedule is not worth taking the caller down for; the next wake
  -- will try again.
  ok, id = pcall timer.after, delay, -> pump!
  scheduled = ok and id or nil

--- Drains libuv and decides when to come back.
---@private
pump = ->
  scheduled = nil

  found = M.luv!
  return unless found

  found.run "nowait"

  return unless retained > 0 or found.loop_alive!

  -- backend_timeout is how long libuv would have slept: 0 when something is
  -- ready now, negative when it would have blocked with no deadline.
  timeout = found.backend_timeout!
  timeout = MAX_DELAY if timeout < 0

  schedule math.max MIN_DELAY, math.min MAX_DELAY, timeout

--- Starts servicing libuv, if it is not already being serviced.
-- Call this after registering anything with libuv directly.
---@return boolean Whether libuv is available at all.
M.wake = ->
  return false unless M.luv!
  schedule MIN_DELAY
  true

--- Keeps the loop serviced even while libuv reports nothing pending.
-- For work that is about to exist but does not yet, such as a job queued on a
-- worker thread. Pair with `release`.
M.retain = ->
  retained += 1
  M.wake!

--- Drops a claim made with `retain`.
M.release = ->
  retained -= 1 if retained > 0

--- Runs an external program, calling back when it exits.
--
-- A thin wrapper over `luv.spawn` that holds the loop open for the child's
-- lifetime. Written out because forgetting the wake is the whole failure this
-- module exists to prevent, and running a converter or an extractor is the
-- first thing a tool wants to do.
--
--     uv.spawn "cmd.exe", { args: { "/c", "dir" } }, (code) -> print code
--
---@param command string Program to run.
---@param options? table Passed to luv.spawn: args, cwd, env, stdio.
---@param on_exit? fun(code: integer, signal: integer)
---@return userdata|nil handle, any pid or an error message.
M.spawn = (command, options, on_exit) ->
  found = M.luv!
  return nil, "luv is not installed" unless found

  released = false
  handle, pid = found.spawn command, options or {}, (code, signal) ->
    unless released
      released = true
      M.release!
    on_exit code, signal if on_exit

  unless handle
    released = true
    return nil, pid

  M.retain!
  handle, pid

--- Watches a path for changes.
--
-- The handle is the caller's: stop it and close it when done, or the loop keeps
-- being serviced for as long as it lives.
--
--     watcher = uv.watch "static", (name) -> reload name
--     watcher\close!
--
---@param path string File or directory to watch.
---@param callback fun(filename: string|nil, events: table, err: any)
---@return userdata|nil handle, string|nil err
M.watch = (path, callback) ->
  found = M.luv!
  return nil, "luv is not installed" unless found

  handle = found.new_fs_event!
  return nil, "could not create a watcher" unless handle

  ok, err = handle\start path, {}, (watch_err, filename, events) ->
    callback filename, events, watch_err

  unless ok
    pcall -> handle\close!
    return nil, err

  M.wake!
  handle

--- Whether a pump is currently scheduled.
---@return boolean
M.is_pumping = -> scheduled != nil

--- How many callers are holding the loop open.
---@return integer
M.retained = -> retained

M
