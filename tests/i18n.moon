-- Text in the language the person reads: bundles, fallback, placeholders,
-- plural forms, and the two reports that say what was and was not translated.
--
-- No window and no CEF: this is a Lua module and the suite treats it as one.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\i18n.lua

Neutrino = require "neutrino"
t = require "harness"

fs = Neutrino.fs
i18n = Neutrino.i18n

print "Neutrino: i18n"

-- ═══════════════════════════════════════════════════════════════════════════
-- Bundles from disk
-- ═══════════════════════════════════════════════════════════════════════════

t.section "Reading a folder of languages"

-- Real files, because reading them is half of what this does. A table handed
-- straight to `add` would exercise the lookup and none of the loading.
base = ((os.getenv("TEMP") or os.getenv("TMP") or ".")\gsub "\\", "/")
folder = "#{base}/neutrino-i18n-#{os.time!}-#{math.floor os.clock! * 1000000 % 100000}"
fs.make_dir folder

fs.write "#{folder}/en.json", [[{
  "actions": { "save": "Save", "close": "Close" },
  "grid": {
    "empty": "Nothing to show",
    "rows": { "one": "1 row", "other": "{n} rows" },
    "of": "{shown} of {total}"
  },
  "only_in_english": "Left behind"
}]], true

-- Deliberately partial: no "actions.close", no "grid.of".
fs.write "#{folder}/fr.json", [[{
  "actions": { "save": "Enregistrer" },
  "grid": {
    "empty": "Rien à afficher",
    "rows": { "one": "1 ligne", "other": "{n} lignes" }
  }
}]], true

fs.write "#{folder}/notes.txt", "not a bundle", true

tags, err = i18n.load folder
t.check "the folder is read", err == nil, tostring err
t.check "one tag per json file", #tags == 2, table.concat tags, ","
t.check "and they are named after the files",
  (table.concat tags, ",") == "en,fr", table.concat tags, ","
t.check "a file that is not json is left alone",
  #i18n.available! == 2, table.concat i18n.available!, ","

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Asking for a string"

i18n.use "en"
i18n.reset_report!

t.check "the tag in use is reported", i18n.current! == "en", tostring i18n.current!
t.check "a dotted key walks into the bundle",
  (i18n.t "actions.save") == "Save", i18n.t "actions.save"
t.check "and reaches a nested one",
  (i18n.t "grid.empty") == "Nothing to show", i18n.t "grid.empty"

-- The key itself, not an empty string: a blank space on screen is a bug
-- nobody reports.
t.check "a key nothing answers comes back as itself",
  (i18n.t "nope.not.here") == "nope.not.here", i18n.t "nope.not.here"
t.check "an empty key is not a lookup", (i18n.t "") == "", i18n.t ""

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Placeholders"

t.check "a value is filled in",
  (i18n.t "grid.of", { shown: 40, total: 200 }) == "40 of 200",
  i18n.t "grid.of", { shown: 40, total: 200 }

-- Visible rather than blanked, and recorded. "{total}" on screen is something
-- somebody reports; a gap is not.
half = i18n.t "grid.of", { shown: 40 }
t.check "a placeholder with nothing to fill it stays visible",
  half == "40 of {total}", half

i18n.reset_report!
i18n.t "grid.of", { shown: 1 }
t.check "and is reported as missing",
  (table.concat i18n.missing!, ",")\find("{total}") != nil,
  table.concat i18n.missing!, ","

-- ═══════════════════════════════════════════════════════════════════════════

t.section "One or many"

t.check "n of 1 takes the singular",
  (i18n.t "grid.rows", { n: 1 }) == "1 row", i18n.t "grid.rows", { n: 1 }
t.check "and anything else takes the other form",
  (i18n.t "grid.rows", { n: 7 }) == "7 rows", i18n.t "grid.rows", { n: 7 }
t.check "zero is not singular",
  (i18n.t "grid.rows", { n: 0 }) == "0 rows", i18n.t "grid.rows", { n: 0 }

-- ═══════════════════════════════════════════════════════════════════════════

t.section "A partly translated language"

i18n.use "fr"
i18n.set_fallback "en"
i18n.reset_report!

t.check "what the language has is used",
  (i18n.t "actions.save") == "Enregistrer", i18n.t "actions.save"
t.check "and its plural forms too",
  (i18n.t "grid.rows", { n: 3 }) == "3 lignes", i18n.t "grid.rows", { n: 3 }

-- A mixed interface rather than a broken one.
t.check "what it does not have falls through",
  (i18n.t "actions.close") == "Close", i18n.t "actions.close"
t.check "including a string with placeholders",
  (i18n.t "grid.of", { shown: 2, total: 9 }) == "2 of 9",
  i18n.t "grid.of", { shown: 2, total: 9 }

t.check "a key neither language has is still itself",
  (i18n.t "actions.explode") == "actions.explode", i18n.t "actions.explode"

-- The bundle handed to a page is the fallback with the translations laid over
-- it, so a branch the language has nothing in is still a branch: a page
-- reading `t.grid.of` against a bundle with no `grid` does not get an empty
-- string, it throws, and takes every binding after it down with it.
view = i18n.bundle!
t.check "the bundle for a page carries the fallback underneath",
  view.grid and view.grid.of == "{shown} of {total}",
  view.grid and tostring view.grid.of or "no grid branch"
t.check "with the translations laid over it",
  view.actions and view.actions.save == "Enregistrer",
  view.actions and tostring view.actions.save or "no actions branch"

-- Building that view must not write into the language it was laid over.
-- Sharing a sub-table rather than copying it did exactly that: asking for the
-- French view rewrote the English bundle in place.
i18n.use "en"
t.check "and building it left the fallback alone",
  (i18n.t "actions.save") == "Save", i18n.t "actions.save"
i18n.use "fr"

i18n.set_fallback nil
i18n.use "fr"
t.check "with no fallback the key shows through",
  (i18n.t "actions.close") == "actions.close", i18n.t "actions.close"

-- ═══════════════════════════════════════════════════════════════════════════

t.section "What was and was not translated"

i18n.use "en"
i18n.reset_report!

t.check "nothing is missing before anything is asked for",
  #i18n.missing! == 0, table.concat i18n.missing!, ","

i18n.t "actions.save"
i18n.t "grid.empty"
i18n.t "grid.rows", { n: 2 }
i18n.t "grid.of", { shown: 1, total: 2 }

t.check "a run that found everything reports nothing missing",
  #i18n.missing! == 0, table.concat i18n.missing!, ","

i18n.t "actions.quit"
i18n.t "grid.headers.id"
t.check "two keys nothing answered are both reported",
  #i18n.missing! == 2, table.concat i18n.missing!, ","
t.check "and they are sorted",
  (table.concat i18n.missing!, ",") == "actions.quit,grid.headers.id",
  table.concat i18n.missing!, ","

-- The other direction: what the bundle holds and the interface never asked
-- for. This is the one that finds strings an interface left behind.
leftovers = i18n.unused "en"
t.check "a string nothing asked for is reported as unused",
  (table.concat leftovers, ",")\find("only_in_english") != nil,
  table.concat leftovers, ","
t.check "and one that was asked for is not",
  (table.concat leftovers, ",")\find("actions.save") == nil,
  table.concat leftovers, ","

-- A plural entry is one key with named forms, not two keys. Counted as `rows`
-- if it were ever unused, never as `rows.one` and `rows.other`.
t.check "a plural entry counts as one key, not one per form",
  (table.concat leftovers, ",")\find("rows.one") == nil,
  table.concat leftovers, ","

t.check "the report can be forgotten", (i18n.reset_report! or true) and
  #i18n.missing! == 0, table.concat i18n.missing!, ","

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Several contributors, one bundle"

-- A shell and the tools it hosts each bring their own strings. Whoever loads
-- last must not take the others' away.
i18n.reset!
i18n.add "en", { shell: { file: "File" }, common: { ok: "OK" } }
i18n.add "en", { common: { cancel: "Cancel" } }
i18n.use "en"

t.check "what the first contributor added is still there",
  (i18n.t "shell.file") == "File", i18n.t "shell.file"
t.check "and so is the second's",
  (i18n.t "common.cancel") == "Cancel", i18n.t "common.cancel"
t.check "merged key by key rather than branch by branch",
  (i18n.t "common.ok") == "OK", i18n.t "common.ok"

-- Two tools can both call something "save" and mean different words.
i18n.add "en", { actions: { save: "Save table" } }, "dbc"
i18n.add "en", { actions: { save: "Export model" } }, "m2"

t.check "a namespace keeps one tool's strings off another's",
  (i18n.t "dbc.actions.save") == "Save table", i18n.t "dbc.actions.save"
t.check "and the other keeps its own",
  (i18n.t "m2.actions.save") == "Export model", i18n.t "m2.actions.save"
t.check "while what was there before is untouched",
  (i18n.t "shell.file") == "File", i18n.t "shell.file"

-- The same word in the same place is a replacement, not a second entry.
i18n.add "en", { shell: { file: "Fichier" } }
t.check "a later contributor overwrites an exact key",
  (i18n.t "shell.file") == "Fichier", i18n.t "shell.file"

i18n.reset!
t.check "and everything can be forgotten",
  #i18n.available! == 0, table.concat i18n.available!, ","

-- ═══════════════════════════════════════════════════════════════════════════

t.section "The same word, written twice"

-- Where a bundle lives is the application's choice. What is worth seeing is
-- when that choice went wrong and two tools each grew their own "Save"
-- instead of binding the one at the root.
i18n.reset!
i18n.add "en", {
  actions: { save: "Save", close: "Close" }
  dbc: { toolbar: { save: "Save" } }
  m2: { toolbar: { save: "Save", export: "Export" } }
  empty_one: ""
  empty_two: ""
}
i18n.use "en"

groups = i18n.duplicates!
t.check "one group, for the word written three times",
  #groups == 1, "#{#groups} groups"
t.check "and it names that word",
  groups[1] and groups[1].text == "Save", groups[1] and groups[1].text or "none"
t.check "with every key that says it",
  groups[1] and #groups[1].keys == 3, groups[1] and #groups[1].keys or 0
t.check "sorted, so two runs read the same",
  groups[1] and (table.concat groups[1].keys, ",") ==
    "actions.save,dbc.toolbar.save,m2.toolbar.save",
  groups[1] and table.concat groups[1].keys, ","

-- Two empty strings are two blanks, not the same word twice.
t.check "a word written once is not reported",
  #groups == 1, "#{#groups} groups"

i18n.reset!

-- Put the folder's bundles back for the section below.
i18n.load folder

-- ═══════════════════════════════════════════════════════════════════════════

t.section "A folder that is not there"

gone, load_err = i18n.load "#{folder}/nowhere"
t.check "it is reported rather than raised", load_err != nil, tostring load_err
t.check "and nothing came back", #gone == 0, "#{#gone} tags"

fs.remove "#{folder}/en.json"
fs.remove "#{folder}/fr.json"
fs.remove "#{folder}/notes.txt"

t.finish!
