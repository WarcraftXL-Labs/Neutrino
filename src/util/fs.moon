--- Path helpers and file access.
-- luv is required lazily: the framework itself does not depend on it, and only
-- the asynchronous helpers here and core.async's worker pool need it at all.
---@module util.fs

M = {}

luv = nil
require_luv = ->
  unless luv
    ok, result = pcall require, "luv"
    error "util.fs needs luv: run tools/luarocks.ps1 install luv" unless ok
    luv = result
  luv

M.join = (...) ->
  parts = {...}
  sep = "\\"
  return table.concat(parts, sep)\gsub("[\\\\/]+", sep)

M.normalize = (path) ->
  return "" unless path
  sep = "\\"
  return path\gsub("[\\\\/]+", sep)

M.dirname = (path) ->
  return path\match("(.*)[\\\\/]") or "."

M.is_file = (path) ->
  stat = require_luv!.fs_stat path
  stat != nil and stat.type == "file"

M.read_async = (path, callback) ->
  luv = require_luv!
  luv.fs_open path, "r", 438, (err, fd) ->
    return callback(err) if err
    luv.fs_fstat fd, (err, stat) ->
      return callback(err) if err
      luv.fs_read fd, stat.size, 0, (err, data) ->
        luv.fs_close fd
        callback(err, data)

return M