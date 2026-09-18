--- Event emitting and listening, in the style of Node's EventEmitter.
---@module core.events

---@class EventEmitter
class EventEmitter
  --- Creates an emitter with no listeners.
  new: =>
    @_listeners = {}

  --- Registers a listener for an event.
  ---@param event string Event name.
  ---@param callback function Called with the arguments passed to emit.
  ---@return EventEmitter self, for chaining.
  on: (event, callback) =>
    @_listeners[event] or= {}
    table.insert @_listeners[event], callback
    @

  --- Registers a listener that runs at most once.
  ---@param event string Event name.
  ---@param callback function Called with the arguments passed to emit.
  ---@return EventEmitter self, for chaining.
  once: (event, callback) =>
    wrapper = (...) ->
      @off event, wrapper
      callback ...
    @on event, wrapper

  --- Removes a listener.
  ---@param event string Event name.
  ---@param callback function The exact function passed to on.
  ---@return EventEmitter self, for chaining.
  off: (event, callback) =>
    listeners = @_listeners[event]
    return @ unless listeners

    for index, listener in ipairs listeners
      if listener == callback
        table.remove listeners, index
        break
    @

  --- Removes every listener, for one event or for all of them.
  ---@param event? string Event name; omit to clear all events.
  ---@return EventEmitter self, for chaining.
  remove_all: (event) =>
    if event
      @_listeners[event] = nil
    else
      @_listeners = {}
    @

  --- Counts the listeners registered for an event.
  ---@param event string Event name.
  ---@return integer
  listener_count: (event) =>
    @_listeners[event] and #@_listeners[event] or 0

  --- Calls every listener registered for an event.
  -- Listeners run inside pcall, so one that raises does not stop the others
  -- or unwind into the native caller.
  ---@param event string Event name.
  ---@param ... any Arguments passed to each listener.
  ---@return EventEmitter self, for chaining.
  emit: (event, ...) =>
    listeners = @_listeners[event]
    return @ unless listeners

    -- Iterate a copy: a listener may call off() on itself.
    for callback in *[listener for listener in *listeners]
      ok, err = pcall callback, ...
      unless ok
        io.stderr\write "[neutrino] listener for '#{event}' failed: #{tostring err}\n"
    @

{ :EventEmitter }
