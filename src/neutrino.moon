--- Neutrino public API.
-- @module neutrino

ffi = require "ffi"

-- Line-buffer stdout. Redirected to a file or a pipe, the C runtime buffers in
-- blocks, so print() output from a long-running app appears only when it exits
-- and interleaves unhelpfully with Chromium's own logging.
pcall -> io.stdout\setvbuf "line"

-- Where this application's files are.
--
-- Two layouts have to work and an entry point should not have to know which one
-- it is in. Packaged, the host executable has already set package.path and
-- hands the directories over in globals. In development, they are worked out
-- from the interpreter and the working directory, and the vendored rocks are
-- put on the path here - before anything requires them.
--
--   paths.root  the application root
--   paths.bin   neutrinocef.dll and the CEF runtime; pass it to cef.setup
paths = { root: nil, bin: nil }

if NEUTRINO_ROOT and NEUTRINO_BIN
  -- Packaged: the host resolved everything from its own location, so this
  -- works from a shortcut, a file association or any working directory.
  paths.root = NEUTRINO_ROOT
  paths.bin = NEUTRINO_BIN
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
    paths.root = cwd\match("(.*)/dist$") and cwd or (cwd .. "/dist")
    paths.bin = paths.root .. "/bin"

    repo = executable\match("(.*)/deps/luajit/bin") or
      cwd\match("(.*)/dist$") or cwd

    rocks_path = "#{repo}/deps/rocks/share/lua/5.1/?.lua;#{repo}/deps/rocks/share/lua/5.1/?/init.lua;"
    rocks_cpath = "#{repo}/deps/rocks/lib/lua/5.1/?.dll;"

    package.path = rocks_path .. package.path unless package.path\find rocks_path, 1, true
    package.cpath = rocks_cpath .. package.cpath unless package.cpath\find rocks_cpath, 1, true

{
  App: (require "core.app").App
  BrowserWindow: (require "browser.window").BrowserWindow
  Server: (require "serve.server").Server
  Response: (require "serve.server").Response
  Router: (require "serve.router").Router
  Module: (require "core.module").Module
  Session: (require "browser.session").Session
  EventEmitter: (require "core.events").EventEmitter

  -- Where this application's files are, resolved the same way whether it is
  -- running from dist/ or from a packaged folder.
  :paths

  async: require "core.async"
  server: require "serve.server"
  session: require "browser.session"
  shell: require "system.shell"
  timer: require "core.timer"
  ui: require "ui"
  keys: require "browser.keys"
  screen: require "browser.screen"
  json: require "util.json"
  fs: require "util.fs"

  -- Low-level escape hatches. Reach for these only when the high-level API
  -- does not cover what you need.
  cef: require "core.cef"
  bridge: require "core.bridge"
}
