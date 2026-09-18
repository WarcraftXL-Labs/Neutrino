--- Logging to a file.
--
-- A packaged application has no console. `print` goes nowhere, and so does
-- every `[neutrino] ...` line the framework writes to stderr when a handler
-- raises - which means that when a packaged build misbehaves on somebody else's
-- machine there is no information at all.
--
--     log = Neutrino.log
--     log.open log.app_data_path "MPQBrowser"
--     log.capture!
--
--     log.info "opened %s", path
--     print "this lands in the file too"
--
-- `capture` is the half that matters. Adding a logging API only helps code
-- written after it; capturing `print` and `io.stderr` collects what the
-- framework and every existing line already produce.
---@module util.log

fs = require "util.fs"
paths = require "util.paths"

LEVELS = { debug: 10, info: 20, warn: 30, error: 40, off: 100 }

M = {
  --- Lines below this level are dropped.
  level: "info"

  --- Also write to the console. Harmless when there is none.
  console: true
}

handle = nil
handle_path = nil
written = 0
max_bytes = 2 * 1024 * 1024

-- The real streams, kept so the console half of a write cannot come back
-- through the capture and recurse.
real_stdout = io.stdout
real_stderr = io.stderr
captured = false

--- A timestamp with milliseconds when luv can supply them.
---@return string
---@private
stamp = ->
  base = os.date "%Y-%m-%d %H:%M:%S"

  ok, luv = pcall require, "luv"
  return base unless ok

  _, usec = luv.gettimeofday!
  return base unless usec

  string.format "%s.%03d", base, math.floor usec / 1000

--- Moves the current file aside and starts a new one.
-- One backup, because two are rarely read and a log that grows without bound is
-- worse than one that forgets.
---@private
rotate = ->
  return unless handle and handle_path

  handle\close!
  handle = nil

  os.remove "#{handle_path}.1"
  os.rename handle_path, "#{handle_path}.1"

  handle = io.open handle_path, "ab"
  written = 0

--- Opens a log file, creating the directories it needs.
---@param path string
---@param opts? table
---@field opts.level string Minimum level. Defaults to the current one.
---@field opts.max_bytes integer Size at which the file is rotated.
---@field opts.console boolean Also write to the console. Defaults to true.
---@field opts.truncate boolean Start a fresh file rather than appending.
---@return boolean ok, string|nil err
M.open = (path, opts = {}) ->
  M.close!

  path = paths.resolve path
  fs.make_dir fs.dirname path

  file, err = io.open path, opts.truncate and "wb" or "ab"
  return false, err unless file

  handle = file
  handle_path = path
  written = opts.truncate and 0 or (fs.is_file(path) and (file\seek "end") or 0)

  M.level = opts.level if opts.level
  M.console = opts.console if opts.console != nil
  max_bytes = opts.max_bytes if opts.max_bytes

  true

--- Closes the log file. Safe to call when none is open.
M.close = ->
  return unless handle
  pcall -> handle\close!
  handle = nil
  handle_path = nil
  written = 0

--- The file currently being written to, or nil.
---@return string|nil
M.path = -> handle_path

--- Where a named application's log belongs on this machine.
-- Under the user's local app data, because a packaged application may well be
-- installed somewhere it cannot write.
---@param name string Application name.
---@return string
M.app_data_path = (name = "Neutrino") ->
  "#{paths.data_dir name}/#{name}.log"

--- Writes one line at a level.
---@param level string "debug", "info", "warn" or "error".
---@param text string
M.write = (level, text) ->
  threshold = LEVELS[M.level] or LEVELS.info
  rank = LEVELS[level] or LEVELS.info
  return if rank < threshold

  line = string.format "%s %-5s %s\n", stamp!, level\upper!, text

  if handle
    handle\write line

    -- Flushed on every line rather than left to the buffer. The C runtime on
    -- Windows treats line buffering as full buffering for a file, so the last
    -- lines before a crash - the ones worth reading - would be the ones lost.
    handle\flush!

    written += #line
    rotate! if written >= max_bytes

  if M.console
    stream = rank >= LEVELS.warn and real_stderr or real_stdout
    pcall -> stream\write line

--- Formats when given extra arguments, so a message costs nothing to build
--- when its level is off.
---@param level string
---@param message any
---@param ... any Arguments for string.format.
---@private
emit = (level, message, ...) ->
  text = tostring message
  if select("#", ...) > 0
    ok, formatted = pcall string.format, text, ...
    text = formatted if ok

  M.write level, text

M.debug = (message, ...) -> emit "debug", message, ...
M.info = (message, ...) -> emit "info", message, ...
M.warn = (message, ...) -> emit "warn", message, ...
M.error = (message, ...) -> emit "error", message, ...

-- ═══════════════════════════════════════════════════════════════════════════
-- CAPTURE
-- ═══════════════════════════════════════════════════════════════════════════

--- A stand-in for io.stderr that routes writes into the log.
-- Unknown members fall through to the real stream, so anything calling
-- `setvbuf` or `flush` on it still works.
---@param stream file
---@param level string
---@return table
---@private
proxy = (stream, level) ->
  pending = ""

  handlers = {
    write: (_, ...) ->
      for piece in *{ ... }
        pending ..= tostring piece

      -- Callers write a line in several pieces, so lines are assembled here and
      -- emitted whole; a partial tail waits for the rest of itself.
      while true
        head, rest = pending\match "^([^\n]*)\n(.*)$"
        break unless head
        M.write level, head
        pending = rest

      stream
  }

  -- Anything that is not `write` falls through to the real stream, rebound so
  -- it receives the stream as its self rather than this table.
  setmetatable handlers, __index: (_, key) ->
    value = stream[key]
    return value unless type(value) == "function"
    (_, ...) -> value stream, ...

--- Routes `print` and `io.stderr` into the log.
-- Calling it twice is a no-op.
M.capture = ->
  return if captured
  captured = true

  original_print = print

  -- _G rather than a bare assignment: inside a function that would declare a
  -- local and change nothing at all.
  _G.print = (...) ->
    parts = {}
    for index = 1, select "#", ...
      table.insert parts, tostring (select index, ...)
    M.write "info", table.concat parts, "\t"

  M._restore = ->
    _G.print = original_print
    io.stderr = real_stderr

  io.stderr = proxy real_stderr, "warn"

--- Puts `print` and `io.stderr` back.
M.restore = ->
  return unless captured
  captured = false

  M._restore! if M._restore
  M._restore = nil

--- Whether print and stderr are currently being captured.
---@return boolean
M.is_capturing = -> captured

M
