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
