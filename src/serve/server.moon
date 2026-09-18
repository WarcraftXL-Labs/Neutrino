--- Serves the custom scheme from Lua.
-- Requests to neutrino://<host>/<path> are intercepted in C++ and handed here,
-- where they are routed like HTTP requests. Nothing listens on a TCP port, so
-- there is no firewall prompt and nothing for another process to connect to.
--
-- The response never allocates memory that C++ would have to free: the body is
-- copied out of the Lua string by neutrino_response_set before it returns.
---@module serve.server

async = require "core.async"
bridge = require "core.bridge"
cef = require "core.cef"
json = require "util.json"
Router = (require "serve.router").Router

--- Decodes application/x-www-form-urlencoded text.
---@param text string
---@return string
url_decode = (text) ->
  (text\gsub("+", " ")\gsub "%%(%x%x)", (hex) -> string.char tonumber hex, 16)

--- Splits a query string into a table. Repeated keys keep the last value.
---@param query string
---@return table<string, string>
parse_query = (query) ->
  result = {}
  return result unless query and query != ""

  for pair in query\gmatch "[^&]+"
    key, value = pair\match "^([^=]*)=?(.*)$"
    result[url_decode key] = url_decode value if key and key != ""

  result

--- Splits neutrino://host/path?query into its parts.
---@param url string
---@return string host, string path, string query
parse_url = (url) ->
  host, rest = url\match "^%a[%w+.-]*://([^/?#]*)(.*)$"
  return "", "/", "" unless host

  path, query = rest\match "^([^?#]*)%??([^#]*)$"
  path = "/" if not path or path == ""

  host, path, query or ""

-- ═══════════════════════════════════════════════════════════════════════════
-- RESPONSE
-- ═══════════════════════════════════════════════════════════════════════════

--- The response handed to a route handler.
-- Sending is one-way and final: the first send wins, so a handler that has
-- already replied cannot be overridden by a later error.
---@class Response
---@field status_code integer
---@field mime string
---@field headers table<string, string>
class Response
  --- Wraps a native response id.
  ---@param id integer Response id from the native layer.
  new: (id) =>
    @_id = id
    @_sent = false
    @status_code = 200
    @mime = "text/html; charset=utf-8"
    @headers = {}

  --- Sets the status code.
  ---@param code integer
  ---@return Response self, for chaining.
  status: (code) =>
    @status_code = code
    @

  --- Sets a response header.
  ---@param name string
  ---@param value string
  ---@return Response self, for chaining.
  header: (name, value) =>
    @headers[name] = value
    @

  --- Sets the content type.
  ---@param mime string
  ---@return Response self, for chaining.
  type: (mime) =>
    @mime = mime
    @

  --- Sends a body and ends the request.
  ---@param body string Body, which may contain binary data.
  ---@param mime? string Content type.
  send: (body, mime) =>
    @mime = mime if mime
    @_flush body or ""

  --- Sends a body as HTML.
  ---@param body string
  html: (body) => @send body, "text/html; charset=utf-8"

  --- Sends a body as plain text.
  ---@param body string
  text: (body) => @send body, "text/plain; charset=utf-8"

  --- Encodes a value as JSON and sends it.
  ---@param value any
  json: (value) => @send (json.encode value), "application/json; charset=utf-8"

  --- Redirects the browser to another URL.
  ---@param url string
  ---@param code? integer Status code. Defaults to 302.
  redirect: (url, code = 302) =>
    @status_code = code
    @headers.Location = url
    @_flush ""

  --- Reports whether a reply has already been sent.
  ---@return boolean
  sent: => @_sent

  --- Hands the response to the native layer, which copies every buffer.
  ---@param body string
  ---@private
  _flush: (body) =>
    return if @_sent
    @_sent = true

    headers_json = nil
    if next(@headers) != nil
      headers_json = json.encode @headers

    -- Returns 0 when the request is already gone, which a reply arriving after
    -- the page navigated away legitimately does.
    cef.lib.neutrino_response_set @_id, @status_code, @mime, headers_json,
      body, #body

--- A response that answers Lua instead of the browser.
--
-- Everything a route does goes through _flush, so capturing the reply is a
-- matter of overriding that one method: the handler cannot tell the difference,
-- and neither can the router.
---@class BufferedResponse : Response
---@private
class BufferedResponse extends Response
  --- Wraps a resolver called once with the finished reply.
  ---@param done fun(reply: table) Receives status, mime, headers and body.
  new: (done) =>
    -- The id is never used: _flush below does not reach the native layer.
    super 0
    @_done = done

  ---@param body string
  ---@private
  _flush: (body) =>
    return if @_sent
    @_sent = true

    -- Through a local, because `@_done args` compiles to a colon call and would
    -- hand the resolver this response as its first argument.
    done = @_done
    done {
      status: @status_code
      mime: @mime
      headers: @headers
      :body
    }

-- ═══════════════════════════════════════════════════════════════════════════
-- SERVER
-- ═══════════════════════════════════════════════════════════════════════════

-- The Server the scheme currently reaches. Declared here so the constructor
-- below can record itself in it; read through current().
current_server = nil

---@class Server
---@field router Router Routes for the default host.
class Server
  --- Creates the server and attaches it to the native request handler.
  -- One Server owns the scheme for the whole process; create it once.
  new: =>
    @router = Router!
    -- Per-host routers, so modules can each own an origin such as
    -- neutrino://mpq/ without colliding.
    @hosts = {}

    bridge.request_handler = (request, handle) -> @dispatch request, handle

    -- One Server owns the scheme, so the last one built is the one requests
    -- actually reach. Recording it is what lets a module find its routes
    -- without the application having to hand the server around.
    if current_server and next(current_server.hosts) != nil
      io.stderr\write "[neutrino] a second Server took over the scheme; the " ..
        "routes of the one it replaced are now unreachable\n"
    current_server = @

  --- Returns the router for a host, creating it on first use.
  -- Lets a module own an origin such as neutrino://mpq/ without colliding with
  -- the shell's own routes.
  ---@param host string Host part of the URL, such as "mpq".
  ---@return Router
  host: (host) =>
    @hosts[host] or= Router!
    @hosts[host]

  --- Serves a directory of files from the default host.
  -- Shorthand for `server.router\static`; a module mounts its own on its own
  -- router instead.
  ---@param prefix string Url prefix, such as "/assets".
  ---@param directory string Directory on disk, relative to the app root.
  ---@param opts? table index, cache and types; see serve.static.
  ---@return Server self, for chaining.
  static: (prefix, directory, opts) =>
    @router\static prefix, directory, opts
    @

  --- Forgets a host and every route registered under it.
  -- This is how a module stops serving: it owns its origin outright, so
  -- dropping the router drops exactly its routes and nobody else's.
  ---@param host string
  ---@return Server self, for chaining.
  drop_host: (host) =>
    @hosts[host] = nil
    @

  --- Routes one request.
  -- Called by core.bridge; applications do not normally call it.
  ---@param request table method, url, headers_json, body, window_id.
  ---@param response_id integer Native response id.
  dispatch: (request, response_id) =>
    @_route request, Response response_id

  --- Runs a request through the routers without a browser.
  --
  -- The same handlers, the same parameters, the same deferred replies - the
  -- reply is handed back to Lua instead of to CEF. That makes a route testable
  -- without a window, lets a page's content be computed before the window that
  -- will show it exists, and lets one module consume another's output without
  -- knowing it is a module.
  --
  --     tree = server\fetch "neutrino://mpq/tree?path=World"
  --     print tree.status, tree.mime, #tree.body
  --
  -- Awaited inside a task; outside one, pass a callback.
  ---@param url string Absolute URL, such as "neutrino://mpq/tree".
  ---@param opts? table method, body, headers, window. May be the callback.
  ---@param callback? fun(reply: table)
  ---@return table|nil reply status, mime, headers, body when awaited.
  fetch: (url, opts = {}, callback) =>
    if type(opts) == "function"
      callback, opts = opts, {}

    request = {
      method: opts.method or "GET"
      :url
      body: opts.body or ""
      headers_json: opts.headers and (json.encode opts.headers) or nil
      window_id: opts.window and opts.window.id or 0
    }

    arrange = (resolve) -> @_route request, BufferedResponse resolve

    return async.await arrange if callback == nil and async.is_async!

    arrange (reply) -> callback reply if callback
    @

  --- Routes one request into a response, whichever kind it is.
  ---@param request table
  ---@param response Response
  ---@private
  _route: (request, response) =>
    host, path, query = parse_url request.url

    router = @hosts[host] or @router
    handler, params = router\resolve request.method, path

    unless handler
      response\status(404)\html "<h1>404 Not Found</h1><p>#{request.method} #{path}</p>"
      return

    req = {
      method: request.method
      url: request.url
      :host
      :path
      query: parse_query query
      :params
      body: request.body
      headers: json.try_decode(request.headers_json) or {}
      window: bridge.window request.window_id
    }

    -- Handlers run as tasks, so a route may await a file read or a worker job.
    -- One that never awaits finishes before run() returns and is answered
    -- inline; one that awaits leaves the request open until it replies.
    async.run ->
      ok, err = pcall handler, req, response
      unless ok
        io.stderr\write "[neutrino] #{request.method} #{path}: #{tostring err}\n"
        -- No-op when the handler already replied; a sent response is final.
        response\status(500)\html "<h1>500 Internal Server Error</h1><pre>#{tostring err}</pre>"
        return

      -- A handler that falls through without replying still has to produce a
      -- response, or the request would hang until the renderer times out.
      response\_flush "" unless response\sent!

--- Returns the Server the scheme reaches, creating it on first use.
--
-- An application that builds its own Server still gets it back from here, so
-- code that only needs somewhere to put routes - a module, mainly - does not
-- have to be handed one.
---@param create? boolean Pass false to look without creating.
---@return Server|nil
current = (create = true) ->
  current_server = Server! if create and not current_server
  current_server

{ :Server, :Response, :BufferedResponse, :current, :parse_url, :parse_query }
