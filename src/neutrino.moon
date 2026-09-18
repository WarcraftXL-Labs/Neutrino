--- Neutrino public API.
-- @module neutrino

-- Required before anything else: it puts the vendored rocks on the path, and
-- every module below expects to find them there.
paths = require "util.paths"

-- Line-buffer stdout. Redirected to a file or a pipe, the C runtime buffers in
-- blocks, so print() output from a long-running app appears only when it exits
-- and interleaves unhelpfully with Chromium's own logging.
pcall -> io.stdout\setvbuf "line"

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
  uv: require "core.uv"
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
