--- Shared state between Lua and one window's page.
--
-- Lua holds the data; the page holds what is on screen. A `State` is the one
-- channel between them: a write on either side is applied on the other, and the
-- page's effects re-run from there.
--
--     state = Neutrino.ui.State window, { count: 0, user: { name: "Thor" } }
--
--     state\set "count", 5              -- the page's data-text updates
--     state\on "count", (value) -> ...  -- fires when the page changes it
--
-- Paths are dotted: `"user.name"` reaches into a table without replacing it.
--
-- There is deliberately no merging and no conflict resolution. The last write
-- to a path wins, whichever side made it, because anything cleverer would be
-- guessing at which side was right.
---@module ui.state

async = require "core.async"
json = require "util.json"

--- Splits "user.name" into its parts.
---@param path string
---@return string[]
---@private
split = (path) -> [part for part in tostring(path)\gmatch "[^.]+"]

--- Reads a dotted path out of a table.
---@param data table
---@param parts string[]
---@return any
---@private
read = (data, parts) ->
  node = data
  for part in *parts
    return nil unless type(node) == "table"
    node = node[part]
  node

--- Writes a dotted path into a table, creating what it passes through.
-- A nil value removes the key, which is what the page means by deleting one.
---@param data table
---@param parts string[]
---@param value any
---@private
write = (data, parts, value) ->
  node = data
  for index = 1, #parts - 1
    part = parts[index]
    node[part] = {} unless type(node[part]) == "table"
    node = node[part]

  node[parts[#parts]] = value

--- Turns JSON's null sentinel back into nil, at every depth.
-- cjson decodes null to a sentinel so that nulls in an array do not shorten it;
-- inside state that distinction is not wanted, and a caller comparing against
-- nil should not have to know about it.
---@param value any
---@return any
---@private
denull = (value) ->
  return nil if value == json.null
  return value unless type(value) == "table"

  result = {}
  for key, item in pairs value
    converted = denull item
    result[key] = converted if converted != nil

  result

---@class State
---@field window BrowserWindow The window this state is bound to.
---@field data table Lua's copy, and the source of truth for data.
---@field ready boolean True once the page's runtime has announced itself.
class State
  --- Binds a state to a window and installs the channels the runtime uses.
  --
  -- The initial values are not pushed: `ui.document` inlines them into the page
  -- so the first paint already has them. Pushing as well would repaint for
  -- nothing and race with the document's own script.
  ---@param window BrowserWindow
  ---@param initial? table Values the page starts with.
  new: (window, initial = {}) =>
    @window = window
    @data = initial
    @ready = false

    @_listeners = {}
    @_ready_waiters = {}

    -- Thin arrows: `handle` calls back with (payload, window), and a fat arrow
    -- here would take the payload as its self.
    window\handle "ui:state", (payload) ->
      if type(payload) == "table" and type(payload.path) == "string"
        @_receive payload.path, denull payload.value
      nil

    window\handle "ui:ready", ->
      @ready = true
      waiters, @_ready_waiters = @_ready_waiters, {}
      waiter! for waiter in *waiters
      nil

  --- Reads a path. Returns the whole table when the path names one.
  ---@param path? string Dotted path; omit for everything.
  ---@return any
  get: (path) =>
    return @data unless path
    read @data, split path

  --- Writes a path and pushes it to the page.
  ---@param path string Dotted path.
  ---@param value any Any JSON-encodable value; nil removes the key.
  ---@return State self, for chaining.
  set: (path, value) =>
    parts = split path
    return @ if #parts == 0

    write @data, parts, value
    @window\send "ui:state", { :path, :value } unless @window.closed
    @_notify path, value, "lua"
    @

  --- Writes several top-level keys at once.
  ---@param values table
  ---@return State self, for chaining.
  patch: (values) =>
    @set key, value for key, value in pairs values
    @

  --- Calls back when a path changes, from either side.
  --
  -- The source says which: "page" for a change the interface made, "lua" for
  -- one this state made. Most callers want "page" and can ignore the rest.
  ---@param path string Dotted path.
  ---@param callback fun(value: any, source: string, path: string)
  ---@return State self, for chaining.
  on: (path, callback) =>
    @_listeners[path] or= {}
    table.insert @_listeners[path], callback
    @

  --- Suspends until the page's runtime has booted, or returns immediately when
  --- it already has.
  --
  -- Only needed by code that pushes before the page has loaded; a state that is
  -- only read from handlers the page itself triggers never has to wait.
  ---@param callback? fun()
  ready_then: (callback) =>
    if @ready
      callback! if callback
      return true

    arrange = (resolve) -> table.insert @_ready_waiters, -> resolve true

    return async.await arrange if callback == nil and async.is_async!
    arrange -> callback! if callback
    false

  --- Applies a change the page made.
  ---@param path string
  ---@param value any
  ---@private
  _receive: (path, value) =>
    write @data, (split path), value
    @_notify path, value, "page"

  --- Runs the listeners for a path and for every path above it, so watching
  --- "user" also hears about "user.name".
  ---@param path string
  ---@param value any
  ---@param source string
  ---@private
  _notify: (path, value, source) =>
    parts = split path
    prefix = nil

    for index = 1, #parts
      prefix = prefix and "#{prefix}.#{parts[index]}" or parts[index]
      listeners = @_listeners[prefix]
      continue unless listeners

      -- The listener for a parent path is told about the parent's new value,
      -- not the leaf's, because that is what it asked to watch.
      reported = prefix == path and value or @get prefix

      for callback in *listeners
        ok, err = pcall callback, reported, source, path
        unless ok
          io.stderr\write "[neutrino] state listener for '#{prefix}': #{tostring err}\n"

{ :State }
