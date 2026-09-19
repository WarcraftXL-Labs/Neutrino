-- Serving files from disk: what gets through, and what must not.
--
-- No browser anywhere in this suite. A static route is a function of a url, so
-- server\fetch answers every question here - which also means it runs in
-- milliseconds and can afford to try every spelling of a traversal.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\static.lua

Neutrino = require "neutrino"
t = require "harness"

static = require "serve.static"

print "Neutrino: static files"

-- Neither the native library nor a running loop: a static route answers a
-- url, and nothing on that path reaches CEF.

-- ═══════════════════════════════════════════════════════════════════════════
-- The path check, on its own
-- ═══════════════════════════════════════════════════════════════════════════

t.section "Paths that are refused"

REFUSED = {
  "../secret"
  "a/../../secret"
  "..%2fsecret"                    -- encoded, decoded before the check
  "%2e%2e/secret"                  -- both dots encoded
  "..\\secret"                     -- backslash, because Windows accepts it
  "/etc/passwd"
  "\\\\server\\share\\file"        -- a UNC path
  "C:/Windows/System32/drivers/etc/hosts"
  "theme.css%00.txt"               -- a NUL truncates the name underneath
  "theme.css."                     -- Windows strips the trailing dot
  ""
}

for path in *REFUSED
  t.check "refuses #{path == "" and "an empty path" or path}",
    (static.safe_path path) == nil, tostring static.safe_path path

t.section "Paths that are allowed"

ALLOWED = {
  { "theme.css", "theme.css" }
  { "css/theme.css", "css/theme.css" }
  { "./css/theme.css", "css/theme.css" }
  { "my%20file.css", "my file.css" }
  { "a//b///c.png", "a/b/c.png" }
}

for pair in *ALLOWED
  given, expected = pair[1], pair[2]
  t.check "allows #{given}", (static.safe_path given) == expected,
    tostring static.safe_path given

t.section "Content types"

t.check "css is a stylesheet",
  (static.content_type "a/theme.css", static.TYPES)\match("^text/css") != nil
t.check "an extension script is javascript",
  (static.content_type "a/app.mjs", static.TYPES)\match("^text/javascript") != nil
t.check "the extension is matched case insensitively",
  (static.content_type "A/LOGO.PNG", static.TYPES) == "image/png"
t.check "an unknown extension is a stream of bytes",
  (static.content_type "a/archive.mpq", static.TYPES) == "application/octet-stream"
t.check "and so is a file with no extension",
  (static.content_type "a/LICENSE", static.TYPES) == "application/octet-stream"

-- ═══════════════════════════════════════════════════════════════════════════
-- Mounted on a router
-- ═══════════════════════════════════════════════════════════════════════════

server = Neutrino.Server!
server\static "/assets", "static"

-- The other half of the answer: an extension can have its own, on its own origin.
class Themed extends Neutrino.Extension
  name: "themed"
  routes: (router) => router\static "/own", "static"

app = Neutrino.App t.app_options!
app\register_extension Themed

-- Every fetch below resolves inline, so the task runs to its end before the
-- next statement. The guard is there in case that ever stops being true.
t.expect_completion!

t.task "static routes", ->
  t.section "Serving"

  css = server\fetch "neutrino://app/assets/theme.css"
  t.check "a file is served", css.status == 200, tostring css.status
  t.check "with the right content type",
    css.mime\match("^text/css") != nil, css.mime
  t.check "and its contents", css.body\match("%-%-n%-accent") != nil,
    "#{#css.body} bytes"

  -- Read in text mode a png loses bytes on Windows, in a way that depends on
  -- which bytes they are - so it works until it does not.
  png = server\fetch "neutrino://app/assets/pixel.png"
  t.check "a binary file keeps its type", png.mime == "image/png", png.mime
  t.check "and every one of its bytes", #png.body == 70, "#{#png.body} bytes"
  t.check "including the png signature",
    png.body\sub(1, 4) == "\137PNG", "#{png.body\byte 1}"

  t.section "Refusing"

  t.check "a traversal is forbidden, not 404",
    (server\fetch "neutrino://app/assets/../../neutrino.lua").status == 403
  t.check "an absolute path too",
    (server\fetch "neutrino://app/assets/C:/Windows/win.ini").status == 403
  t.check "a missing file is 404",
    (server\fetch "neutrino://app/assets/nothing.css").status == 404

  -- The point of the refusal: the file it was reaching for does exist.
  reachable = server\fetch "neutrino://app/neutrino.lua"
  t.check "and the route above it is untouched", reachable.status == 404,
    tostring reachable.status

  t.section "Where a path really points"

  fs = Neutrino.fs

  t.check "a path is inside itself", fs.contains "E:/app/static", "E:/app/static"
  t.check "and a file under it is inside it",
    fs.contains "E:/app/static", "E:/app/static/css/theme.css"
  t.check "a sibling with a longer name is not",
    not fs.contains "E:/app/static", "E:/app/static2/secret"
  t.check "separators and case do not decide it",
    fs.contains "E:/app/static", "E:\\APP\\Static\\theme.css"
  t.check "and a parent is not inside its child",
    not fs.contains "E:/app/static/css", "E:/app/static"

  -- The case the string check cannot see. A junction inside the served folder
  -- is an ordinary name on the way in and anywhere at all on the way out, so
  -- the route has to ask the filesystem where it actually went.
  os.execute 'cmd /c rmdir "static\\escape" >nul 2>&1'
  os.execute 'cmd /c mklink /J "static\\escape" "." >nul 2>&1'

  junction = fs.real "static/escape"
  made = t.check "a junction out of the folder can be made to test with",
    junction != nil and not fs.contains(fs.real("static"), junction),
    tostring junction

  if made
    escaped = server\fetch "neutrino://app/assets/escape/neutrino.lua"
    t.check "and following it out is forbidden", escaped.status == 403,
      "#{escaped.status}, #{#escaped.body} bytes"

    -- Without this the check above could pass because the folder stopped
    -- serving altogether, which would look identical from one assertion.
    t.check "while the folder itself still serves",
      (server\fetch "neutrino://app/assets/theme.css").status == 200

  os.execute 'cmd /c rmdir "static\\escape" >nul 2>&1'

  t.section "Both shapes at once"

  own = server\fetch "neutrino://themed/own/theme.css"
  t.check "an extension serves its own assets on its own origin",
    own.status == 200 and own.mime\match("^text/css") != nil,
    "#{own.status} #{own.mime}"

  t.check "the application's folder is still there",
    (server\fetch "neutrino://app/assets/theme.css").status == 200

  -- Unregistering takes the extension's routes with it, assets included.
  app\unregister_extension "themed"
  t.check "an extension's assets leave with the extension",
    (server\fetch "neutrino://themed/own/theme.css").status == 404

  t.done!

t.finish!
