--- Text in the language the person reads.
--
-- The interface never calls a translate function. A bundle is **one store
-- key**, so markup binds to it like anything else:
--
--     <button data-text="t.actions.save"></button>
--     <span data-text="t.grid.rows"></span>
--
-- That works with no new syntax, because page expressions compile with
-- `with ($state)` - a top-level store key is a bare variable. And because the
-- store is reactive per top-level key, replacing that one key re-renders every
-- translated string at once:
--
--     state\set "t", i18n.use "fr"
--
-- Switching language is one `set`. No page rebuild, no reload, no second
-- system that has to be kept in step with the first.
--
-- Lua-side text - a status line, a menu label, an error - asks for it directly:
--
--     i18n.t "errors.no_workspace"
--     i18n.t "grid.rows_selected", n: 12
--
-- **Three different things are called a locale**, and conflating them is the
-- mistake this module exists to make hard:
--
--   the interface language   what this module answers about
--   Chromium's own locale    `App` option `locale`, for its built-in strings
--   the data's locale        an application's business - which folder of a
--                            game client to read, say - and nothing to do
--                            with what language the buttons are in
--
-- Somebody editing a German client in an English interface is doing something
-- ordinary, not something to be corrected.
---@module util.i18n

fs = require "util.fs"
json = require "util.json"
paths = require "util.paths"

M = {}

-- tag -> nested table of strings.
bundles = {}

-- The tag in use, and the one to fall through to when a key is missing.
current = nil
fallback = nil

-- Every key that was asked for and not found, and every key that was found.
-- The difference between what a bundle holds and what was looked up is the
-- whole audit, and a framework is the only thing positioned to keep it: it
-- sees every lookup, which no application-side helper does.
missing = {}
seen = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- Bundles
-- ═══════════════════════════════════════════════════════════════════════════

--- Merges `incoming` into `target`, in place, deeply.
--
-- A string always wins over whatever was there. Two tables are walked, so a
-- tool adding `grid.empty` does not take `grid.rows` away from the one that
-- added it first.
---@param target table
---@param incoming table
---@private
merge = (target, incoming) ->
  for key, value in pairs incoming
    if type(value) == "table"
      -- A fresh table, never the one that came in. Assigning the reference
      -- would make two bundles share a branch, and the next merge into either
      -- would quietly rewrite the other: building the French view used to
      -- write French into the English bundle it was laid over.
      target[key] = {} unless type(target[key]) == "table"
      merge target[key], value
    else
      target[key] = value
  target

--- Merges a table of strings into a tag's bundle.
--
-- Merged rather than replaced, because an application is not one thing that
-- owns all its text: a shell contributes its own, and so does every tool it
-- hosts. Replacing would mean the last one loaded won and the rest vanished,
-- quietly, in whatever order the requires happened to run.
--
-- A namespace keeps them apart. `add "en", strings, "dbc"` puts them under
-- `t.dbc`, so two tools can both have an `actions.save` and mean different
-- words.
---@param tag string Language tag, such as "en" or "fr-FR".
---@param table_ table Nested table of strings.
---@param namespace? string Key to nest them under.
M.add = (tag, table_, namespace) ->
  bundles[tag] or= {}

  incoming = table_ or {}
  incoming = { [namespace]: incoming } if namespace and namespace != ""

  merge bundles[tag], incoming

--- Reads every `<tag>.json` in a directory.
--
-- Resolved against the application root, like everything else a build ships,
-- so the same call works from `dist/` and from a package.
---@param directory string Path under the application root.
---@param namespace? string Key to nest every bundle under.
---@return string[] tags, string|nil err
M.load = (directory, namespace) ->
  folder = paths.resolve directory
  return {}, "no folder at #{folder}" unless fs.is_dir folder

  tags = {}
  for path in *(fs.list folder, "*.json") or {}
    name = (fs.basename path)\gsub "%.json$", ""

    body = fs.read path, true
    continue unless body

    decoded, err = json.try_decode body
    unless decoded
      return tags, "#{name}.json: #{tostring err}"

    M.add name, decoded, namespace
    table.insert tags, name

  table.sort tags
  tags, nil

--- The tags that have a bundle.
---@return string[]
M.available = ->
  tags = [tag for tag in pairs bundles]
  table.sort tags
  tags

--- The language keys fall through to when the chosen one has no answer.
--
-- A half-translated interface should read as a mixed one rather than as a
-- broken one: a French bundle missing `actions.save` shows "Save", not
-- "actions.save" and not nothing.
---@param tag string|nil
M.set_fallback = (tag) -> fallback = tag

-- ═══════════════════════════════════════════════════════════════════════════
-- Choosing
-- ═══════════════════════════════════════════════════════════════════════════

--- Switches language and hands back the bundle to put in the store.
--
--     state\set "t", i18n.use "fr"
--
---@param tag string
---@return table bundle The bundle now in use; empty when the tag is unknown.
M.use = (tag) ->
  current = tag
  bundles[tag] or {}

--- The tag in use, or nil.
---@return string|nil
M.current = -> current

--- The bundle in use, for handing to the store.
--
-- The fallback underneath it, not the chosen language on its own. A partly
-- translated language is the normal case, and a page reading `t.home.title`
-- against a bundle with no `home` branch does not get an empty string - it
-- throws, and takes every binding after it down with it.
--
-- Merged here, so what the page holds has the shape of the fallback with the
-- translations laid over it. That is also exactly what `t` answers, so the
-- markup and Lua cannot disagree about what a key resolves to.
---@return table
M.bundle = ->
  chosen = current and bundles[current] or {}
  under = fallback and bundles[fallback]

  return chosen unless under and under != chosen

  merged = {}
  merge merged, under
  merge merged, chosen
  merged

--- The chosen language's own strings, without the fallback under them.
---@return table
M.own = -> current and bundles[current] or {}

-- ═══════════════════════════════════════════════════════════════════════════
-- Lookup
-- ═══════════════════════════════════════════════════════════════════════════

--- Walks a dotted key into a bundle.
---@param bundle table|nil
---@param key string
---@return any
---@private
reach = (bundle, key) ->
  return nil unless bundle

  node = bundle
  for part in key\gmatch "[^.]+"
    return nil unless type(node) == "table"
    node = node[part]
    return nil if node == nil

  node

--- Fills `{name}` placeholders from a table.
--
-- A name with nothing to fill it is left visible rather than blanked, and
-- recorded: `{count}` on screen is a bug somebody reports, an empty space is
-- one nobody notices.
---@param text string
---@param vars table|nil
---@param key string For the missing report.
---@return string
---@private
fill = (text, vars, key) ->
  return text unless text\find "{", 1, true

  (text\gsub "{([%w_]+)}", (name) ->
    value = vars and vars[name]
    if value == nil
      missing["#{key}:{#{name}}"] = true
      return "{#{name}}"
    tostring value)

--- One string, in the language in use.
--
-- `n` selects between the `one` and `other` forms when the entry is a table:
--
--     "rows": { "one": "1 row", "other": "{n} rows" }
--
-- Two forms is right for English, French, German and Spanish and wrong for
-- Russian and Polish, which need more. This deliberately does not pretend
-- otherwise: a language needing more forms needs a plural selector, and that
-- is worth writing when one is actually being translated rather than guessed
-- at now.
---@param key string Dotted key, such as "actions.save".
---@param vars? table Values for `{name}` placeholders. `n` also picks a form.
---@return string
M.t = (key, vars) ->
  return "" unless type(key) == "string" and key != ""

  found = reach M.own!, key
  found = reach (fallback and bundles[fallback]), key if found == nil

  if found == nil
    missing[key] = true
    return key

  seen[key] = true

  if type(found) == "table"
    count = vars and tonumber vars.n
    found = (count == 1) and found.one or found.other
    if found == nil
      missing[key] = true
      return key

  fill (tostring found), vars, key

-- ═══════════════════════════════════════════════════════════════════════════
-- What was and was not asked for
-- ═══════════════════════════════════════════════════════════════════════════

--- Every key looked up that no bundle answered, sorted.
--
-- Worth asserting on in a suite: the interface exercised, then this empty.
-- That turns "did we translate everything" from an audit somebody remembers to
-- do into a check that fails.
---@return string[]
M.missing = ->
  keys = [key for key in pairs missing]
  table.sort keys
  keys

--- Every key a bundle holds that nothing ever asked for, sorted.
--
-- The other direction, and the one that finds strings left behind by an
-- interface that moved on. Only meaningful after a run that exercised the
-- whole interface, so it reports rather than fails.
--
-- A language's own strings, not the merged view: every key the fallback holds
-- would otherwise count as unused in every other language.
---@param tag? string Which bundle to examine. Defaults to the one in use.
---@return string[]
M.unused = (tag) ->
  bundle = tag and bundles[tag] or M.own!
  leftovers = {}

  walk = (node, prefix) ->
    for name, value in pairs node
      key = prefix == "" and name or "#{prefix}.#{name}"

      -- A plural entry is one key with named forms, not two keys.
      plural = type(value) == "table" and (value.one or value.other)

      if type(value) == "table" and not plural
        walk value, key
      else
        table.insert leftovers, key unless seen[key]

  walk bundle, ""
  table.sort leftovers
  leftovers

--- Keys whose text is identical, grouped by that text.
--
-- Where a bundle is one folder or several is the application's choice: shared
-- strings at the root and a tool's own under its namespace, or everything in
-- one file, or the same folder split however it suits. Nothing here forces
-- that, and nothing should.
--
-- What is worth knowing is when the choice went wrong - when four tools each
-- grew their own "Save" instead of binding the one at the root. That is a
-- thing to see rather than a rule to obey: sometimes two keys sharing a word
-- in English are two different words in German, and merging them would be the
-- bug. So this reports and never refuses.
--
-- Only groups of two or more, sorted, with the keys in each sorted too. A
-- language's own strings, for the same reason `unused` looks at those: against
-- the merged view every untranslated key would duplicate its own fallback.
---@param tag? string Which bundle to examine. Defaults to the one in use.
---@return table[] groups { text = "Save", keys = { "a.save", "b.save" } }
M.duplicates = (tag) ->
  bundle = tag and bundles[tag] or M.own!
  by_text = {}

  walk = (node, prefix) ->
    for name, value in pairs node
      key = prefix == "" and name or "#{prefix}.#{name}"

      if type(value) == "table"
        walk value, key
      elseif type(value) == "string" and value != ""
        by_text[value] or= {}
        table.insert by_text[value], key

  walk bundle, ""

  groups = {}
  for text, keys in pairs by_text
    continue if #keys < 2
    table.sort keys
    table.insert groups, { :text, :keys }

  table.sort groups, (a, b) -> a.text < b.text
  groups

--- Forgets every bundle. For suites, and for reloading from disk.
M.reset = ->
  bundles = {}
  current = nil
  fallback = nil

--- Forgets what has been looked up. For suites, and between runs.
M.reset_report = ->
  missing = {}
  seen = {}

M
