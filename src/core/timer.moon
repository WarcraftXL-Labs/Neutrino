--- Timers, backed by CEF's task runner.
--
-- A delayed task posted to the UI thread is already a timer, and CEF's message
-- loop is the one running. That means timers need no second event loop, and no
-- integration between two of them: the callback simply arrives on the Lua
-- thread like every other framework callback.
---@module core.timer

bridge = require "core.bridge"
cef = require "core.cef"

M = {}

--- Runs a callback once after a delay.
---@param delay_ms integer Delay in milliseconds.
---@param callback fun()
---@return integer id Handle for M.stop.
M.after = (delay_ms, callback) ->
  bridge.install!

  id = cef.lib.neutrino_timer_start delay_ms, 0
  bridge.timers[id] = (timer_id) ->
    -- One-shot: the native side has already forgotten it, so drop our entry
    -- before running the callback rather than after, in case it raises.
    bridge.timers[timer_id] = nil
    callback!
  id

--- Runs a callback repeatedly.
---@param interval_ms integer Interval in milliseconds.
---@param callback fun()
---@param delay_ms? integer Delay before the first run. Defaults to interval_ms.
---@return integer id Handle for M.stop.
M.every = (interval_ms, callback, delay_ms) ->
  bridge.install!

  id = cef.lib.neutrino_timer_start (delay_ms or interval_ms), interval_ms
  bridge.timers[id] = -> callback!
  id

--- Stops a timer. Safe for an id that has already fired or been stopped, and
--- safe to call from inside the timer's own callback.
---@param id integer
M.stop = (id) ->
  return unless id
  bridge.timers[id] = nil
  cef.lib.neutrino_timer_stop id

M
