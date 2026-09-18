--- Where this application's files are.
--
-- Two layouts have to work and nothing above this should have to know which one
-- it is in. Packaged, the host executable resolved everything from its own
-- location and handed the directories over in globals. In development they are
-- worked out from the interpreter and the working directory, and the vendored
-- rocks are put on the path here - before anything requires them, which is why
-- this module is required first.
--
--   paths.root  the application root; static/ and app data live under it
--   paths.bin   neutrinocef.dll and the CEF runtime; pass it to cef.setup
---@module util.paths

ffi = require "ffi"

M = { root: nil, bin: nil }

if NEUTRINO_ROOT and NEUTRINO_BIN
  -- Packaged: works from a shortcut, a file association or any working
  -- directory, because the host asked Windows where it was loaded from.
  M.root = NEUTRINO_ROOT
  M.bin = NEUTRINO_BIN
else
  pcall ->
    ffi.cdef [[
      unsigned long GetModuleFileNameA(void* hModule, char* lpFilename, unsigned long nSize);
      unsigned long GetCurrentDirectoryA(unsigned long nBufferLength, char* lpBuffer);
    ]]

    buffer = ffi.new "char[512]"
    ffi.C.GetModuleFileNameA nil, buffer, 512
    executable = (ffi.string buffer)\gsub "\\", "/"

    ffi.C.GetCurrentDirectoryA 512, buffer
    cwd = (ffi.string buffer)\gsub "\\", "/"

    -- dist/ is where a development build lands, so that is where the runtime
    -- is, whether the script was started from there or from the repo root.
    M.root = cwd\match("(.*)/dist$") and cwd or (cwd .. "/dist")
    M.bin = M.root .. "/bin"

    repo = executable\match("(.*)/deps/luajit/bin") or
      cwd\match("(.*)/dist$") or cwd

    rocks_path = "#{repo}/deps/rocks/share/lua/5.1/?.lua;#{repo}/deps/rocks/share/lua/5.1/?/init.lua;"
    rocks_cpath = "#{repo}/deps/rocks/lib/lua/5.1/?.dll;"

    package.path = rocks_path .. package.path unless package.path\find rocks_path, 1, true
    package.cpath = rocks_cpath .. package.cpath unless package.cpath\find rocks_cpath, 1, true

--- Resolves a path against the application root.
-- An absolute path is returned unchanged, so a caller that knows exactly where
-- something is does not have to fight this.
---@param path string
---@return string
M.resolve = (path) ->
  path = (tostring path)\gsub "\\", "/"

  -- A drive letter or a leading slash means the caller meant it.
  return path if path\match "^%a:[/\\]" or path\match "^/"
  return path unless M.root

  "#{M.root}/#{path}"

M
