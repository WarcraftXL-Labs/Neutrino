--- Shared scaffolding for the test suites.
--
-- Counting, reporting, and the two or three things every suite needs before it
-- can start: the paths, the native library, and a way to wait for an event.
--
--     t = require "harness"
--     t.section "Cookies"
--     t.check "a cookie survives the round trip", found and found.value == "x"
--     t.finish!
---@module harness

Neutrino = require "neutrino"
async = Neutrino.async

M = {
  checks: 0
  failures: 0
}

--- Records one assertion.
-- `detail` is printed only on failure, and is what turns "FAIL something" into
-- something you can act on without rerunning under a debugger.
---@param name string What is being asserted, as a statement.
---@param passed any Truthy for a pass.
---@param detail? any Shown on failure.
---@return boolean passed, so a check can gate what follows it.
M.check = (name, passed, detail) ->
  M.checks += 1

  if passed
    print "  ok    #{name}"
    return true

  M.failures += 1
  suffix = detail and " - #{tostring detail}" or ""
  print "  FAIL  #{name}#{suffix}"
  false

--- Prints a heading, so a long run reads as a list of subjects rather than a
--- wall of assertions.
---@param title string
M.section = (title) ->
  print ""
  print "-- #{title}"

--- Fails a check outright, for a path that should not have been reached.
---@param name string
---@param detail? any
M.fail = (name, detail) -> M.check name, false, detail

-- Whether the suite said it would run to a finish, and whether it got there.
--
-- A suite whose body is a task can be cut off mid-flight: the message loop ends
-- when the last window closes, and the task simply stops. The checks it had
-- already made still pass, the tally still adds up, and the run reports success
-- while several assertions never executed at all. Declaring the end and
-- checking for it is what turns that silence into a failure.
completion_expected = false
completion_reached = false

--- Says this suite ends inside a task, so finish() should insist on it.
M.expect_completion = -> completion_expected = true

--- Marks the end of the suite's own work. The last line of the task.
M.done = -> completion_reached = true

--- Prints the tally and ends the process with a status the shell can read.
---@return nothing This does not return.
M.finish = ->
  if completion_expected and not completion_reached
    M.check "the suite ran to the end", false,
      "it stopped early - the loop ended while a task was still running"

  print ""
  print "#{M.checks - M.failures}/#{M.checks} checks passed"
  os.exit M.failures == 0 and 0 or 1

-- ═══════════════════════════════════════════════════════════════════════════
-- Setup
-- ═══════════════════════════════════════════════════════════════════════════

--- Loads neutrinocef.dll, ending the run with a clear message if it is absent.
--- Safe to call more than once.
---@return string bin The directory the runtime was loaded from.
M.load_native = ->
  ok, err = Neutrino.cef.setup Neutrino.paths.bin
  unless ok
    print "  FAIL  load neutrinocef.dll - #{tostring err}"
    print ""
    print "Run .\\tools\\build.ps1 first."
    os.exit 1

  Neutrino.paths.bin

--- Options every suite passes to App, pointing at the development build.
---@param extra? table Merged over the defaults.
---@return table
M.app_options = (extra = {}) ->
  bin = Neutrino.paths.bin
  options = {
    cache_path: Neutrino.paths.root .. "/cache"
    resources_path: bin
    locales_path: bin .. "/locales"
    subprocess_path: bin .. "/neutrinocef_helper.exe"
  }
  options[key] = value for key, value in pairs extra
  options

-- ═══════════════════════════════════════════════════════════════════════════
-- Waiting
-- ═══════════════════════════════════════════════════════════════════════════

--- Suspends until `emitter` fires `event`, and returns what it carried.
--
-- `accept` filters: "did-finish-load" fires for the blank document a browser
-- starts on as well as for the page under test, so a suite usually wants the
-- second one rather than the first.
---@param emitter table Anything with an `on` method.
---@param event string
---@param accept? fun(detail: table): boolean
---@return table detail
M.wait_for = (emitter, event, accept) ->
  async.await (resolve) ->
    emitter\on event, (detail) ->
      -- Resolving twice is ignored, so a listener that keeps firing after the
      -- first match costs nothing; there is no need to unsubscribe.
      return if accept and not accept detail
      resolve detail or {}

--- Suspends until `predicate` is true, or gives up and answers false.
--
-- Bounded on purpose. A test that waits forever for something that will never
-- happen reports nothing at all, which is worse than reporting a failure.
-- The predicate runs inside the task, so it may await - polling an expression
-- in the page with eval is the usual use.
---@param predicate fun(): boolean
---@param timeout_ms? integer Defaults to 3 seconds.
---@param step_ms? integer Defaults to 25.
---@return boolean True when the predicate came good in time.
M.wait_until = (predicate, timeout_ms = 3000, step_ms = 25) ->
  -- A MoonScript call written without parentheses swallows whatever follows it,
  -- so `t.check "x", t.wait_until -> ready!, detail` hands the detail to this
  -- function as its timeout. Saying which mistake it was beats letting it
  -- surface later as "attempt to compare number with string".
  unless type(timeout_ms) == "number" and type(step_ms) == "number"
    error "wait_until: timeout and step must be numbers - parenthesise the " ..
      "call if an argument followed it on the next line", 2

  waited = 0
  while waited < timeout_ms
    return true if predicate!
    async.sleep step_ms
    waited += step_ms
  predicate! and true or false

--- Runs `body` as a task, and fails the suite rather than the process if it
--- raises. Without this an error inside a task is reported by core.async and
--- the run carries on looking healthy.
---@param name string Named in the failure.
---@param body function
M.task = (name, body) ->
  async.run ->
    ok, err = pcall body
    unless ok
      M.fail "#{name} raised", err
      M.on_task_error! if M.on_task_error

--- Arranges for the run to fail rather than hang.
--
-- Every suite drives a real browser, and a browser that never answers would
-- otherwise block until someone noticed. This turns that into a failure.
---@param app table The App.
---@param ms? integer Defaults to 20 seconds.
M.deadline = (app, ms = 20000) ->
  app\set_timer ms, ->
    M.fail "timed out after #{ms} ms"
    app\quit!

M
