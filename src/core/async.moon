--- Cooperative concurrency on coroutines.
--
-- The Lua thread is also the CEF UI thread, so a handler that blocks stops the
-- window repainting. This module is how a handler waits without blocking: it
-- suspends the coroutine, the event loop keeps pumping, and the coroutine
-- resumes when the result arrives.
--
-- Nothing here makes Lua multi-threaded. It makes waiting cheap. For work that
-- genuinely saturates a core, use `work`, which hands the job to a real thread
-- with its own Lua state - the one thing CEF cannot provide.
--
--     async.run ->
--       contents = async.await (resolve) ->
--         read_file_somehow path, (data) -> resolve data
--       res\json { size: #contents }
---@module core.async

timer = require "core.timer"

M = {}

--- Reports a failure that has nowhere else to go.
---@param context string
---@param err any
---@private
report = (context, err) ->
  io.stderr\write "[neutrino] #{context}: #{tostring err}\n"

--- Resumes a task, reporting an error rather than letting it escape.
-- Errors must not propagate out of here: a resume usually happens inside a
-- native callback, and an error crossing that boundary cannot unwind safely.
---@param task thread
---@param ... any Values returned from the yield.
---@return boolean ok
M.resume = (task, ...) ->
  return false if coroutine.status(task) == "dead"

  ok, err = coroutine.resume task, ...
  unless ok
    report "task failed", "#{tostring err}\n#{debug.traceback task}"
  ok

--- Runs a function as a task.
-- The function starts immediately and runs until it finishes or awaits, so a
-- task that never awaits behaves exactly like a direct call.
---@param fn function
---@param ... any Arguments passed to fn.
---@return thread task
M.run = (fn, ...) ->
  task = coroutine.create fn
  M.resume task, ...
  task

--- Reports whether the caller is inside a task and may await.
---@return boolean
M.is_async = ->
  coroutine.running! != nil

--- Suspends the current task until `starter`'s resolve callback fires.
--
-- `starter` receives a resolve function and arranges for it to be called with
-- the results. Resolving more than once is ignored, and resolving before the
-- task suspends is handled, so a value that turns out to be available
-- immediately costs nothing.
---@param starter fun(resolve: fun(...: any))
---@return ... any Whatever resolve was called with.
M.await = (starter) ->
  task = coroutine.running!
  error "async.await must be called inside async.run", 2 unless task

  settled = false
  suspended = false
  values = nil
  count = 0

  resolve = (...) ->
    return if settled
    settled = true
    count = select "#", ...
    values = { ... }

    -- Only resume if we actually suspended. A starter that resolves before
    -- returning leaves the task running, and resuming it here would fail.
    M.resume task if suspended

  starter resolve

  unless settled
    suspended = true
    coroutine.yield!

  return unless values
  unpack values, 1, count

--- Suspends the current task for a delay.
---@param ms integer Delay in milliseconds.
M.sleep = (ms) ->
  M.await (resolve) ->
    timer.after ms, resolve

-- luv is loaded only when a worker is actually requested, and its loop is only
-- serviced while one is in flight. CEF owns the application's message loop, so
-- libuv has no reason to run the rest of the time.
pending_workers = 0
worker_pump = nil

pump_workers = ->
  luv = require "luv"
  luv.run "nowait"

start_worker_pump = ->
  pending_workers += 1
  return if worker_pump
  -- 4 ms: brisk enough that a finished job is picked up promptly, and it only
  -- runs while there is something to pick up.
  worker_pump = timer.every 4, pump_workers

stop_worker_pump = ->
  pending_workers -= 1
  return if pending_workers > 0 or not worker_pump
  timer.stop worker_pump
  worker_pump = nil

--- Runs a function on a worker thread and awaits its result.
--
-- This is the one place where Lua being single-threaded actually bites, and the
-- answer is a real thread rather than a coroutine. The worker runs in its own
-- Lua state, so `fn` must be self-contained: no upvalues, and arguments and
-- results limited to strings, numbers, booleans and nil.
--
--     count = async.work (path) ->
--       file = io.open path, "rb"
--       data = file\read "*a"
--       file\close!
--       #data
--     , "big.mpq"
---@param fn function Self-contained function to run off the main thread.
---@param ... any Primitive arguments passed to fn.
---@return ... any Whatever fn returned.
M.work = (fn, ...) ->
  ok, luv = pcall require, "luv"
  error "async.work requires luv: run tools/luarocks.ps1 install luv" unless ok

  args = { ... }
  argc = select "#", ...

  M.await (resolve) ->
    start_worker_pump!
    worker = luv.new_work fn, (...) ->
      stop_worker_pump!
      resolve ...
    worker\queue unpack args, 1, argc

--- Awaits several starters at once, resolving when all of them have.
-- Each starter is given its own resolve; results come back in order.
---@param starters fun(resolve: fun(...: any))[]
---@return table results One entry per starter.
M.all = (starters) ->
  total = #starters
  return {} if total == 0

  results = {}
  remaining = total

  M.await (resolve) ->
    for index, starter in ipairs starters
      -- The index has to be captured per iteration, hence the inner function.
      do
        position = index
        starter (...) ->
          results[position] = ...
          remaining -= 1
          resolve results if remaining == 0

M
