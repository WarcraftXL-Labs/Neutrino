--- Platform integration: clipboard, system shell, single instance.
--
-- None of this comes from CEF, because none of it is Chromium's business. It is
-- here because a tool that cannot copy a string, open a folder in the Explorer
-- or refuse to run twice is not a desktop application yet.
--
-- Everything here is synchronous: these are local calls, not network or disk
-- work, so there is nothing to await.
---@module system.shell

ffi = require "ffi"
bridge = require "core.bridge"
cef = require "core.cef"

M = {}

--- Reads the clipboard as text.
-- An empty string when the clipboard holds no text - an image, say - which is
-- not an error and needs no special case at the call site.
---@return string
M.read_text = ->
  return "" unless cef.lib
  ffi.string cef.lib.neutrino_clipboard_read!

--- Replaces the clipboard contents.
---@param text string
---@return boolean ok, string|nil err Fails when another process holds it.
M.write_text = (text) ->
  return false, "no library loaded" unless cef.lib
  return true if cef.lib.neutrino_clipboard_write(tostring text) == 1
  false, cef.last_error!

--- Opens a url with the user's default handler.
--
-- http, https and mailto only. That is a deliberate limit, not an oversight:
-- the same Win32 call given a path will run an executable, so anything that
-- reached Lua from a page must not be able to get there. A path the application
-- built itself goes through open_path, which says so at the call site.
---@param url string
---@return boolean ok, string|nil err
M.open_external = (url) ->
  return false, "no library loaded" unless cef.lib
  return true if cef.lib.neutrino_shell_open_external(tostring url) == 1
  false, cef.last_error!

--- Opens a file or folder with its registered application.
--
-- Runs an executable if handed one, exactly as a double click would. Do not
-- pass a path that came from the page without checking it first.
---@param path string
---@return boolean ok, string|nil err
M.open_path = (path) ->
  return false, "no library loaded" unless cef.lib
  return true if cef.lib.neutrino_shell_open_path(tostring path) == 1
  false, cef.last_error!

--- Opens the containing folder in the Explorer with the item selected.
---@param path string
---@return boolean ok, string|nil err
M.show_in_folder = (path) ->
  return false, "no library loaded" unless cef.lib
  return true if cef.lib.neutrino_shell_show_in_folder(tostring path) == 1
  false, cef.last_error!

--- Claims |name| for this process, and routes later arrivals to |on_second|.
--
-- Returns false when another copy is already running. The caller is expected to
-- hand its arguments over and exit:
--
--     unless shell.claim_single_instance "wxl-tool", (args) ->
--         win\restore!\focus!
--         open_file args[1] if args[1]
--       shell.notify_first_instance "wxl-tool"
--       os.exit 0
--
-- The handler runs on the Lua thread like every other callback, so it may touch
-- windows directly.
---@param name string Unique to the application, not to the window.
---@param on_second? fun(args: string[], raw: string)
---@return boolean claimed True when this process is the only one.
M.claim_single_instance = (name, on_second) ->
  return false, "no library loaded" unless cef.lib

  bridge.install!
  bridge.second_instance = on_second

  cef.lib.neutrino_single_instance_acquire(tostring name) == 1

--- Hands this process's command line to the instance already running.
--
-- Returns false when nobody is listening, which is a race rather than a bug:
-- the first instance can exit between the failed claim and this call. Treat it
-- as "carry on starting normally".
---@param name string The same name passed to claim_single_instance.
---@param payload? string Defaults to this process's arguments, tab separated.
---@return boolean delivered
M.notify_first_instance = (name, payload) ->
  return false unless cef.lib

  unless payload
    -- Tab separated because a Windows path can contain almost anything else,
    -- including spaces, semicolons and quotes.
    parts = {}
    if arg
      index = 1
      while arg[index]
        table.insert parts, arg[index]
        index += 1
    payload = table.concat parts, "\t"

  cef.lib.neutrino_single_instance_notify(tostring(name), payload) == 1

--- Releases the lock. App:run does this on shutdown, so this is for a process
--- that exits without ever starting the loop.
M.release_single_instance = ->
  cef.lib.neutrino_single_instance_release! if cef.lib

M
