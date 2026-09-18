--- Paths and files.
--
-- A thin layer over penlight's `pl.path` and `pl.dir` rather than a hand-rolled
-- one. The version this replaced hard-coded a backslash separator, which is
-- correct on Windows and quietly wrong everywhere else - and "quietly wrong on
-- the platform we have not ported to yet" is the kind of thing nobody finds
-- until the port.
--
-- The indirection earns its place the same way `util.json` does: one import to
-- change, and a place to say what the framework relies on.
--
--     fs.join "modules", "mpq", "www"     -- modules\mpq\www on Windows
--     fs.real "static/../neutrino.lua"    -- where it actually points
--     fs.contains root, candidate         -- is it under there, really
---@module util.fs

path = require "pl.path"
dir = require "pl.dir"
file = require "pl.file"

M = { sep: path.sep }

-- luv is required lazily: nothing here needs it except the asynchronous read
-- and the real-path resolution, and one rock failing to build should not take
-- the rest of the framework with it.
luv = nil
luv_missing = false

optional_luv = ->
  return luv if luv
  return nil if luv_missing

  ok, result = pcall require, "luv"
  unless ok
    luv_missing = true
    return nil

  luv = result
  luv

require_luv = ->
  found = optional_luv!
  error "util.fs needs luv: run tools/luarocks.ps1 install luv" unless found
  found

-- ═══════════════════════════════════════════════════════════════════════════
-- PATHS
-- ═══════════════════════════════════════════════════════════════════════════

--- Joins parts with the platform's separator.
---@param ... string
---@return string
M.join = (...) -> path.join ...

--- Collapses "." and ".." and normalises separators.
-- This *repairs* a path. It is the wrong tool for deciding whether a request
-- may have a file: see `contains`.
---@param p string
---@return string
M.normalize = (p) -> p and path.normpath(p) or ""

--- The form to compare two paths in: case-folded on Windows, as-is elsewhere.
---@param p string
---@return string
M.comparable = (p) -> path.normcase path.normpath p

--- The directory part of a path.
---@param p string
---@return string
M.dirname = (p) -> path.dirname p

--- The final component of a path.
---@param p string
---@return string
M.basename = (p) -> path.basename p

--- Splits off the extension, dot included.
---@param p string
---@return string stem, string extension
M.splitext = (p) -> path.splitext p

--- The extension, dot included, or "".
---@param p string
---@return string
M.extension = (p) -> select 2, path.splitext p

--- Whether a path is anchored: a drive, a root, or a UNC share.
---@param p string
---@return boolean
M.is_absolute = (p) -> path.isabs p

--- Resolves a path against the working directory.
---@param p string
---@param base? string Resolve against this instead.
---@return string
M.absolute = (p, base) -> path.abspath p, base

--- Expresses a path relative to a base.
---@param p string
---@param base string
---@return string
M.relative = (p, base) -> path.relpath p, base

--- Where a path actually points, with links and junctions followed.
--
-- This is the question `contains` needs answered and that no amount of string
-- handling can answer: a directory junction inside a served folder looks like
-- an ordinary name and leads anywhere on the disk.
--
-- Returns nil when the path does not exist, or when luv is not installed.
---@param p string
---@return string|nil
M.real = (p) ->
  found = optional_luv!
  return nil unless found
  found.fs_realpath p

--- Whether `candidate` is `root` or sits underneath it.
--
-- Compared on a separator boundary, so a sibling named `static2` does not count
-- as being inside `static`. Both sides should be real paths; comparing what the
-- caller typed compares strings and proves nothing about the filesystem.
---@param root string
---@param candidate string
---@return boolean
M.contains = (root, candidate) ->
  return false unless root and candidate

  root = M.comparable root
  candidate = M.comparable candidate

  return true if candidate == root

  prefix = (root\gsub "[/\\]+$", "") .. path.sep
  candidate\sub(1, #prefix) == prefix

-- ═══════════════════════════════════════════════════════════════════════════
-- FILES
-- ═══════════════════════════════════════════════════════════════════════════

--- Whether anything exists at a path.
---@param p string
---@return boolean
M.exists = (p) -> path.exists(p) and true or false

--- Whether a path names a file.
---@param p string
---@return boolean
M.is_file = (p) -> path.isfile p

--- Whether a path names a directory.
---@param p string
---@return boolean
M.is_dir = (p) -> path.isdir p

--- Reads a whole file as bytes.
-- Binary by default: a png read as text loses bytes on Windows, in a way that
-- depends on which bytes they are.
---@param p string
---@param text? boolean Read as text instead.
---@return string|nil contents, string|nil err
M.read = (p, text) -> file.read p, not text

--- Writes a whole file.
---@param p string
---@param data string
---@param text? boolean Write as text instead.
---@return boolean|nil ok, string|nil err
M.write = (p, data, text) -> file.write p, data, not text

--- Creates a directory and every parent it needs.
---@param p string
---@return boolean|nil ok, string|nil err
M.make_dir = (p) -> dir.makepath p

--- The files directly inside a directory.
---@param p string
---@param pattern? string Shell pattern, such as "*.mpq".
---@return string[]
M.list = (p, pattern) -> dir.getfiles p, pattern

--- Every file under a directory, at any depth.
---@param p string
---@param pattern? string Shell pattern, such as "*.mpq".
---@return string[]
M.walk = (p, pattern) -> dir.getallfiles p, pattern

--- Reads a file without blocking, through luv.
--
-- Needs a luv loop to be running for its callback to fire, and nothing pumps
-- one outside `async.work` yet. Until that exists, prefer `read`.
---@param p string
---@param callback fun(err: any, data: string|nil)
M.read_async = (p, callback) ->
  uv = require_luv!
  uv.fs_open p, "r", 438, (err, fd) ->
    return callback(err) if err
    uv.fs_fstat fd, (err, stat) ->
      return callback(err) if err
      uv.fs_read fd, stat.size, 0, (err, data) ->
        uv.fs_close fd
        callback err, data

M
