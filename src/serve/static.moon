--- Serving a directory of files.
--
-- Mounted on any router, so the same mechanism covers both shapes:
--
--     server\static "/assets", "static"      -- one folder for the application
--     module\static "www"                    -- one folder for a module
--
-- Three things have to be right and each fails quietly when it is not.
--
-- **The path.** A request names a file, and a request that names
-- `../../../Windows/System32/config/SAM` must not get it. The scheme is
-- reachable from any page loaded in the window, so this is the one place the
-- framework exposes the filesystem to content. The url is decoded *before* the
-- check, because validating first and decoding after is how this bug is
-- normally written.
--
-- **The content type.** A stylesheet served as text/html is ignored, and a
-- module script served as anything but JavaScript is rejected outright. The
-- browser says so in a console nobody is reading.
--
-- **The mode.** A png read as text is a corrupt png, and on Windows it is
-- corrupt in a way that depends on the bytes, so it sometimes works.
---@module serve.static

fs = require "util.fs"
paths = require "util.paths"

-- Extension to content type. Short on purpose: an application serving something
-- exotic passes its own table rather than waiting for this list to grow.
TYPES = {
  html: "text/html; charset=utf-8"
  htm: "text/html; charset=utf-8"
  css: "text/css; charset=utf-8"
  js: "text/javascript; charset=utf-8"
  mjs: "text/javascript; charset=utf-8"
  json: "application/json; charset=utf-8"
  txt: "text/plain; charset=utf-8"
  csv: "text/csv; charset=utf-8"
  xml: "application/xml; charset=utf-8"
  svg: "image/svg+xml"
  png: "image/png"
  jpg: "image/jpeg"
  jpeg: "image/jpeg"
  gif: "image/gif"
  webp: "image/webp"
  avif: "image/avif"
  ico: "image/x-icon"
  woff: "font/woff"
  woff2: "font/woff2"
  ttf: "font/ttf"
  otf: "font/otf"
  mp3: "audio/mpeg"
  ogg: "audio/ogg"
  wav: "audio/wav"
  mp4: "video/mp4"
  webm: "video/webm"
  wasm: "application/wasm"
  pdf: "application/pdf"
  zip: "application/zip"
}

DEFAULT_TYPE = "application/octet-stream"

--- Decodes percent-escapes in a url path.
---@param text string
---@return string
---@private
url_decode = (text) ->
  (text\gsub "%%(%x%x)", (hex) -> string.char tonumber hex, 16)

--- Turns a url path into a safe relative path, or nil when it is not one.
--
-- Everything is rejected rather than cleaned: a request that tried to leave the
-- directory is not a request with a typo in it, and quietly serving what it
-- "meant" is how a traversal becomes a feature.
---@param path string Path from the url, still encoded.
---@return string|nil
---@private
safe_path = (path) ->
  decoded = url_decode path

  -- A NUL truncates the name in the C call underneath, so "a.png\0.txt" would
  -- open a.png while passing an extension check.
  return nil if decoded\find "%z"

  -- Anything anchored elsewhere: an absolute path, a drive, a UNC share.
  --
  -- Both calls parenthesised. Without them the first one swallows the `or` and
  -- compiles to match("^[/\\]" or match("^%a:")), so only the first pattern is
  -- ever tried - and a drive letter walks straight through.
  return nil if (decoded\match "^[/\\]") or (decoded\match "^%a:")

  segments = {}
  for segment in decoded\gmatch "[^/\\]+"
    return nil if segment == ".."
    continue if segment == "."

    -- Trailing dots and spaces are stripped by Windows when it opens a file,
    -- so "index.html." and "index.html" name the same thing; refusing the odd
    -- spelling keeps one name per file.
    return nil if segment\match "[%. ]$"

    table.insert segments, segment

  return nil if #segments == 0
  table.concat segments, "/"

--- The content type for a filename.
---@param name string
---@param types table<string, string> Extension to type.
---@return string
---@private
content_type = (name, types) ->
  extension = name\match "%.([%w]+)$"
  return DEFAULT_TYPE unless extension
  types[extension\lower!] or DEFAULT_TYPE

--- Reads a whole file as bytes.
---@param file_path string
---@return string|nil
---@private
read_file = (file_path) ->
  -- Synchronous, which is right for an asset on a local disk and wrong for
  -- anything large. The asynchronous path needs a luv pump that does not exist
  -- yet; when it does, this is the one place to change.
  return nil unless fs.is_file file_path
  fs.read file_path

--- Whether a file the path check let through really sits inside the folder.
--
-- That check proves the *string* stays inside. It cannot prove the filesystem
-- agrees: a directory junction inside the folder looks like an ordinary name
-- and leads anywhere on the disk. Only asking where the path actually points
-- settles it.
--
-- Stands down when luv is missing, since that is what resolves a real path. A
-- rock that failed to build should not stop a folder being served, and the
-- string check still holds on its own.
---@param root_real string|nil
---@param file_path string
---@return boolean
---@private
inside = (root_real, file_path) ->
  return true unless root_real

  resolved = fs.real file_path

  -- Nothing to resolve means nothing is there. That is a 404, answered by the
  -- read below; calling it forbidden here would turn every typo into a refusal
  -- and say nothing useful.
  return true unless resolved

  fs.contains root_real, resolved

--- Mounts a directory on a router.
---@param router Router The router to register on.
---@param prefix string Url prefix, such as "/assets".
---@param directory string Directory on disk, relative to the application root.
---@param opts? table
---@field opts.index string File served for a directory, such as "index.html".
---@field opts.cache string Cache-Control value. None by default.
---@field opts.types table<string, string> Extra or replacement content types.
---@return Router router, for chaining.
mount = (router, prefix, directory, opts = {}) ->
  root = paths.resolve directory

  -- Resolved once, on the way in. A folder that does not exist yet resolves to
  -- nil, and the containment check stands down rather than refusing everything.
  root_real = fs.real root

  types = TYPES
  if opts.types
    types = { key, value for key, value in pairs TYPES }
    types[key] = value for key, value in pairs opts.types

  prefix = "/#{prefix}" unless prefix\sub(1, 1) == "/"
  prefix = prefix\gsub "/+$", ""

  router\get "#{prefix}/*", (req, res) ->
    relative = safe_path req.params.splat or ""

    unless relative
      res\status(403)\text "Forbidden"
      return

    file = "#{root}/#{relative}"

    -- The index stands in for a directory, and faces the same checks.
    file = "#{file}/#{opts.index}" if opts.index and fs.is_dir file

    unless inside root_real, file
      res\status(403)\text "Forbidden"
      return

    data = read_file file

    unless data
      res\status(404)\text "Not found"
      return

    res\header "Cache-Control", opts.cache if opts.cache
    -- Parenthesised: an unparenthesised call swallows what follows it, and
    -- send would be handed one argument instead of two.
    res\send data, (content_type file, types)

  router

{ :mount, :safe_path, :content_type, :TYPES }
