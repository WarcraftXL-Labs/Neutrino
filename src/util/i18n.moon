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

--- Adds a bundle under a tag, replacing one already there.
---@param tag string Language tag, such as "en" or "fr-FR".
---@param table_ table Nested table of strings.
M.add = (tag, table_) ->
  bundles[tag] = table_ or {}

--- Reads every `<tag>.json` in a directory.
--
-- Resolved against the application root, like everything else a build ships,
-- so the same call works from `dist/` and from a package.
---@param directory string Path under the application root.
---@return string[] tags, string|nil err
M.load = (directory) ->
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

    M.add name, decoded
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
---@return table
M.bundle = -> current and bundles[current] or {}

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

  found = reach M.bundle!, key
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
---@param tag? string Which bundle to examine. Defaults to the one in use.
---@return string[]
M.unused = (tag) ->
  bundle = tag and bundles[tag] or M.bundle!
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

--- Forgets what has been looked up. For suites, and between runs.
M.reset_report = ->
  missing = {}
  seen = {}

M
