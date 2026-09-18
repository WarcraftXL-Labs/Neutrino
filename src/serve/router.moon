--- Request router for the custom scheme.
-- A small Express-style router: exact paths, `:named` parameters and a `*`
-- wildcard, which is the minimum needed to serve both pages and static assets.
--
-- Routes match in registration order, so register specific paths before
-- wildcards.
---@module serve.router

static_files = require "serve.static"

--- Compiles a route path into a Lua pattern and the names it captures.
-- `/module/:name/assets/*` becomes `^/module/([^/]+)/assets/(.*)$` with the
-- names { "name", "splat" }.
---@param path string Route path.
---@return string pattern, string[] names
compile = (path) ->
  names = {}

  -- Escape every pattern magic character except the ones we assign meaning to.
  pattern = path\gsub "[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1"

  pattern = pattern\gsub ":([%w_]+)", (name) ->
    table.insert names, name
    "([^/]+)"

  pattern = pattern\gsub "%*", ->
    table.insert names, "splat"
    "(.*)"

  "^" .. pattern .. "$", names

---@class Router
class Router
  --- Creates an empty router.
  new: =>
    -- method -> ordered list of routes
    @routes = {}

  --- Registers a handler for a method and path.
  ---@param method string HTTP method.
  ---@param path string Route path, such as "/", "/items/:id" or "/assets/*".
  ---@param handler fun(req: table, res: Response)
  ---@return Router self, for chaining.
  register: (method, path, handler) =>
    method = method\upper!
    @routes[method] or= {}

    pattern, names = compile path
    table.insert @routes[method], { :path, :pattern, :names, :handler }
    @

  get: (path, handler) => @register "GET", path, handler
  post: (path, handler) => @register "POST", path, handler
  put: (path, handler) => @register "PUT", path, handler
  delete: (path, handler) => @register "DELETE", path, handler
  patch: (path, handler) => @register "PATCH", path, handler

  --- Serves a directory of files under a url prefix.
  --
  -- The same call whichever router it is on, so an application can have one
  -- folder for everything, a module can have its own, or both:
  --
  --     server\static "/assets", "static"
  --     module.router\static "/assets", "modules/mpq/www"
  --
  ---@param prefix string Url prefix, such as "/assets".
  ---@param directory string Directory on disk, relative to the app root.
  ---@param opts? table index, cache and types; see serve.static.
  ---@return Router self, for chaining.
  static: (prefix, directory, opts) =>
    static_files.mount @, prefix, directory, opts or {}

  --- Registers the same handler for every common method.
  ---@param path string Route path.
  ---@param handler fun(req: table, res: Response)
  ---@return Router self, for chaining.
  any: (path, handler) =>
    for method in *{ "GET", "POST", "PUT", "DELETE", "PATCH" }
      @register method, path, handler
    @

  --- Finds the handler matching a method and path.
  ---@param method string HTTP method.
  ---@param path string Path with the query string already stripped.
  ---@return function|nil handler, table|nil params
  resolve: (method, path) =>
    routes = @routes[method\upper!]
    return nil unless routes

    for route in *routes
      -- With no captures in the pattern, match returns the whole matched
      -- string, so a nil first element always means "no match".
      captures = { path\match route.pattern }
      continue if captures[1] == nil

      params = {}
      for index, name in ipairs route.names
        params[name] = captures[index]

      return route.handler, params

    nil

{ :Router, :compile }
