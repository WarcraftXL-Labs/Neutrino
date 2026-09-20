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

-- `list` is files and `dirs` is directories, because the underlying listing
-- answers one or the other and never both. Filtering `list` with `is_dir`
-- answers nothing at all, which is silent: an application listing the projects
-- under a root that way finds none and shows an empty picker.
fs.make_dir "#{scratch}/one"
fs.make_dir "#{scratch}/two"

listed = fs.list scratch
folders = fs.dirs scratch

t.check "listing a folder gives its files and not its subfolders",
  #[1 for entry in *listed when fs.is_dir entry] == 0,
  "#{#listed} entries"
t.check "and dirs gives the subfolders", #folders == 2, "#{#folders} entries"
t.check "by name", ((fs.basename folders[1]) == "one") and
  ((fs.basename folders[2]) == "two"),
  "#{fs.basename folders[1]}, #{fs.basename folders[2]}"

t.check "a file's size is known without reading it",
  (fs.size "#{scratch}/source") == 5, tostring fs.size "#{scratch}/source"
t.check "and what is not a file is nothing rather than an error",
  (fs.size "#{scratch}/never-existed") == 0 and (fs.size scratch) == 0

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Zip"

zip = Neutrino.zip

-- Asserted against the bytes that come back out, never against the archive
-- existing: a zip with a wrong CRC or a wrong offset is a file of the right
-- size that every archiver refuses.
archive = "#{scratch}/archive.zip"

-- Twice the deflate window, so the compressed form is not accidentally the
-- stored one, and a second entry small enough that storing it is right.
big = string.rep "WDBC\0\0\0\1the same row again and again", 4000
fs.make_dir "#{scratch}/tree/inner"
fs.write "#{scratch}/tree/inner/big.bin", big
fs.write "#{scratch}/tree/note.txt", "hello"

-- Named first, because without it everything below still passes except the
-- compression, and "method 0" is a long way from "the rock is not installed".
t.check "the deflate rock is installed", zip.compresses!,
  "libdeflate is missing: run tools/get-deps.ps1 -Only rocks"

count, pack_err = zip.pack archive, "#{scratch}/tree"
t.check "a folder packs", count == 2, tostring pack_err

entries = zip.entries archive
t.check "and the directory names what went in", entries != nil and #entries == 2,
  entries and "#{#entries} entries" or "no directory"

-- Forward slashes, relative to the folder. An archive of absolute paths
-- extracts onto the machine it came from and nowhere else.
names = table.concat [entry.name for entry in *entries], ","
t.check "under names relative to it, with forward slashes",
  names == "inner/big.bin,note.txt", names

t.check "the big one was compressed rather than stored",
  entries[1].method == 8 and entries[1].compressed < entries[1].size,
  "method #{entries[1].method}, #{entries[1].compressed} of #{entries[1].size}"

-- Compressing something incompressible makes it bigger, and the format allows
-- either method per entry, so there is no reason to write the worse one.
t.check "and the tiny one was stored, because deflating it would not help",
  entries[2].method == 0, "method #{entries[2].method}"

t.check "an entry reads back byte for byte", (zip.read archive, "inner/big.bin") == big,
  "#{#((zip.read archive, 'inner/big.bin') or '')} of #{#big}"
t.check "and so does a stored one",
  (zip.read archive, "note.txt") == "hello",
  tostring zip.read archive, "note.txt"

missing_data, missing_err = zip.read archive, "nowhere.txt"
t.check "asking for what is not in it fails rather than raising",
  missing_data == nil and missing_err != nil, tostring missing_err

not_an_archive, archive_err = zip.entries "#{scratch}/source"
t.check "and so does a file that is not an archive",
  not_an_archive == nil and archive_err != nil, tostring archive_err

-- The CRC is the whole of what an archiver checks before it hands the bytes
-- over, so the known answer is worth pinning.
t.check "the CRC-32 is the one every archiver expects",
  (zip.crc32 "123456789") == 0xCBF43926,
  string.format "%08X", zip.crc32 "123456789"

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Where the application's files are"

paths = Neutrino.paths

-- Two layouts have to work: development, where `dist/` holds the Lua and
-- `static/` side by side, and a package, where the Lua is under `app/`. A
-- module asking for the files it ships wants the tree, not the root - and
-- resolving the wrong one works all through development and fails only in the
-- package. That has happened twice.
t.check "the Lua tree is known", paths.app != nil and paths.app != "",
  tostring paths.app
t.check "and it is where this suite was loaded from",
  (fs.is_file "#{paths.app}/neutrino.lua"), "#{paths.app}/neutrino.lua"

t.check "a relative path resolves under it",
  (paths.in_app "locales") == "#{paths.app}/locales", paths.in_app "locales"
t.check "an absolute one is left alone",
  (paths.in_app "C:/elsewhere/x.json") == "C:/elsewhere/x.json",
  paths.in_app "C:/elsewhere/x.json"
t.check "and backslashes are normalised",
  (paths.in_app "a\\b") == "#{paths.app}/a/b", paths.in_app "a\\b"

-- The root is the other answer, and the two differ exactly where it matters.
t.check "the root is where static/ lives",
  (fs.is_dir "#{paths.root}/static"), "#{paths.root}/static"

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
