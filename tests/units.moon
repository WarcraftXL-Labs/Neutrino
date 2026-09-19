-- Pure units: no window, no browser, no CEF.
--
-- Kept apart from the rest because none of it needs Chromium, so it runs in
-- milliseconds. When one of these fails the cause is in the file it names, not
-- somewhere in a browser three processes away.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\units.lua

Neutrino = require "neutrino"
t = require "harness"

print "Neutrino: units"

-- ═══════════════════════════════════════════════════════════════════════════

t.section "JSON"

json = Neutrino.json
round_tripped = json.decode json.encode { a: 1, b: { "x", "y" } }
t.check "a nested value survives the round trip", round_tripped.b[2] == "y"

-- try_decode is what the IPC and routing boundaries use, where malformed input
-- arrives from the page as a matter of course rather than as a bug.
t.check "malformed input returns nil instead of raising",
  (json.try_decode "{oops") == nil

-- encode_pretty writes files a person edits by hand, so the two things that
-- matter are that the bytes do not move when the data does not, and that what
-- comes out is still JSON.
pretty = json.encode_pretty { zebra: 1, apple: 2, middle: { "b", "a" } }

t.check "pretty output is indented rather than one line",
  (pretty\match "\n") != nil, pretty
t.check "and its keys are in a stable order",
  (pretty\find "apple") < (pretty\find "middle") and
    (pretty\find "middle") < (pretty\find "zebra"), pretty
t.check "an array keeps the order it was given",
  (pretty\find '"b"') < (pretty\find '"a"'), pretty
t.check "and it decodes back to what went in",
  (json.decode pretty).middle[1] == "b"

-- Lua cannot tell an empty list from an empty map, so the marker has to survive
-- this encoder as well as cjson's. A settings file whose empty list encoded as
-- {} would be read back as an object.
empty_list = json.encode_pretty { items: json.array {} }
t.check "an empty marked array is still an array",
  (empty_list\match "%[%]") != nil, empty_list

awkward = 'a "b"\nc'
t.check "a string with a quote and a newline is escaped",
  (json.decode json.encode_pretty { text: awkward }).text == awkward

-- `#` is defined on strings, so a version of is_array without a type guard
-- calls every non-empty string a list - and a caller merging defaults then
-- replaces the string with an empty table.
t.check "a string is not an array", (json.is_array "3.3.5.12340") == false
t.check "nor is a number or nil",
  (json.is_array 7) == false and (json.is_array nil) == false
t.check "but a list is", (json.is_array { "a" }) == true
t.check "and so is an empty marked one", (json.is_array json.array {}) == true

-- A cycle would otherwise recurse until the stack gave out, which reports the
-- stack rather than the table.
cycle = {}
cycle.self = cycle
t.check "a cycle is refused rather than followed",
  (pcall json.encode_pretty, cycle) == false

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Files"

fs = Neutrino.fs

base = ((os.getenv("TEMP") or os.getenv("TMP") or ".")\gsub "\\", "/")
scratch = "#{base}/neutrino-units-#{os.time!}-#{os.clock! * 1000000 % 100000}"
fs.make_dir scratch

-- Writing a file safely is writing a temporary one and moving it over the
-- original, so that a failure halfway through leaves the original alone. That
-- needs a move that replaces, which is not what the platform gives on Windows.
fs.write "#{scratch}/first", "one"
fs.write "#{scratch}/second", "two"

moved, move_err = fs.move "#{scratch}/first", "#{scratch}/second"
t.check "a move over an existing file reports success", moved != nil,
  tostring move_err

t.check "and what was moved is gone", not fs.is_file "#{scratch}/first"
t.check "and the destination holds what was moved",
  (fs.read "#{scratch}/second") == "one", tostring fs.read "#{scratch}/second"

t.check "a file can be removed", (fs.remove "#{scratch}/second") and
  not fs.is_file "#{scratch}/second"

-- Removing what is not there is what a caller cleaning up after itself does,
-- and it is not a failure.
t.check "removing what is not there says so quietly",
  (fs.remove "#{scratch}/never-existed") == true

fs.write "#{scratch}/source", "bytes"
fs.copy "#{scratch}/source", "#{scratch}/copied"
t.check "a copy leaves both",
  (fs.read "#{scratch}/source") == "bytes" and
    (fs.read "#{scratch}/copied") == "bytes"

-- ═══════════════════════════════════════════════════════════════════════════

t.section "URL parsing"

{ :parse_url, :parse_query } = require "serve.server"

host, path, query = parse_url "neutrino://app/api/items/7?verbose=1&q=a%20b"
t.check "the host comes out of the url", host == "app", host
t.check "the path comes out of the url", path == "/api/items/7", path

parsed = parse_query query
t.check "a query flag is readable", parsed.verbose == "1"
t.check "a percent-encoded value is decoded", parsed.q == "a b", parsed.q

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Router"

router = Neutrino.Router!
router\get "/items/:id", -> nil
router\get "/assets/*", -> nil

handler, params = router\resolve "GET", "/items/42"
t.check "a named parameter is captured",
  handler != nil and params.id == "42"

handler, params = router\resolve "GET", "/assets/css/app.css"
t.check "a wildcard captures the rest of the path",
  handler != nil and params.splat == "css/app.css"

t.check "an unmatched path resolves to nothing",
  (router\resolve "GET", "/nope") == nil

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Accelerators"

keys = require "browser.keys"

spec = keys.parse "Ctrl+Shift+I"
t.check "modifiers are parsed",
  spec and spec.ctrl and spec.shift and not spec.alt
t.check "a letter is parsed", spec and spec.key_code == string.byte "I"
t.check "a function key is parsed", (keys.parse "F12").key_code == 0x7B
-- Punctuation written as itself, because that is how a menu prints it.
comma = keys.parse "Ctrl+,"
t.check "punctuation is parsed as the character",
  comma != nil and comma.key_code == 0xBC and comma.ctrl == true
t.check "and agrees with its named spelling",
  comma != nil and comma.key_code == (keys.parse "Ctrl+Comma").key_code

-- Split on "+", so the key itself can only be reached by name.
t.check "plus is still only reachable by name",
  (keys.parse "Ctrl+Plus") != nil

t.check "nonsense is rejected", (keys.parse "Ctrl+Nope") == nil

keydown = {
  type: "rawkeydown"
  keyCode: string.byte "I"
  ctrl: true, shift: true, alt: false, meta: false
}
t.check "a matching event matches", keys.matches spec, keydown

-- A shortcut that fired on keyup as well as keydown would run twice.
keyup = { k, v for k, v in pairs keydown }
keyup.type = "keyup"
t.check "key release does not match", not keys.matches spec, keyup

-- A missing modifier must not match: Ctrl+I is not Ctrl+Shift+I.
without_shift = { k, v for k, v in pairs keydown }
without_shift.shift = false
t.check "every modifier has to agree", not keys.matches spec, without_shift

t.finish!
