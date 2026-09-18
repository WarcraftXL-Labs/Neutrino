--- JSON codec.
-- Thin adapter over lua-cjson (vendored in deps/rocks), so the framework gets a
-- fast C implementation rather than a hand-rolled parser. The indirection is
-- worth keeping: it gives Neutrino one import to change if the backend ever
-- does, and a place to document the conventions callers depend on.
--
-- Conventions inherited from cjson:
--   * JSON null decodes to `json.null`, a sentinel, so nulls inside an array do
--     not silently shorten it. Compare with `value == json.null`.
--   * A Lua table with a non-zero length encodes as an array, anything else as
--     an object; an empty table therefore encodes as `{}`.
-- @module util.json

ok, cjson = pcall require, "cjson"
unless ok
  error "util.json requires lua-cjson. Install it with:\n" ..
        "  .\\tools\\luarocks.ps1 install lua-cjson\n" ..
        "(original error: #{tostring cjson})"

--- Encodes a Lua value as a JSON document.
-- @param value The value to encode.
-- @return (string) The JSON text.
encode = cjson.encode

--- Decodes a JSON document, raising on malformed input.
-- @param text (string) The JSON text.
-- @return The decoded value.
decode = cjson.decode

--- Decodes a document, returning nil plus a message instead of raising.
-- Preferred on the IPC and routing boundaries, where the payload comes from the
-- page and malformed input is a normal occurrence rather than a bug.
-- @param text (string) The JSON text.
-- @return The decoded value, or nil and an error message.
try_decode = (text) ->
  return nil, "expected a string, got #{type text}" unless type(text) == "string"
  ok, result = pcall cjson.decode, text
  return nil, result unless ok
  result

--- Encodes a value, returning nil plus a message instead of raising.
-- @param value The value to encode.
-- @return (string) The JSON text, or nil and an error message.
try_encode = (value) ->
  ok, result = pcall cjson.encode, value
  return nil, result unless ok
  result

--- Marks a table as an array, so an empty one encodes as `[]` and not `{}`.
--
-- Lua cannot tell an empty list from an empty map, and the guess cjson makes is
-- the wrong one for a list that happens to be empty: the page then iterates an
-- object and renders nothing, or reads `.length` and gets undefined. Say which
-- it is.
--
--     state\set "files", json.array {}        -- []
--     state\set "files", json.array entries   -- [ ... ]
--
-- @param items (table) The table to mark. Defaults to a new one.
-- @return (table) The same table.
array = (items = {}) -> setmetatable items, cjson.empty_array_mt

--- Whether a value should encode as a JSON array.
--
-- The marker `array` leaves is the only reliable answer for an empty table, and
-- `#` is the answer cjson itself uses for the rest. Kept in step with cjson on
-- purpose: two encoders that disagree about what a table is would produce a
-- file that changes shape depending on which one wrote it.
--
-- Anything that is not a table is not an array. Worth stating, because `#` is
-- defined on strings too and answers a length rather than an error — so a
-- version of this without the guard calls every non-empty string a list.
-- @param value (any)
-- @return (boolean)
is_array = (value) ->
  return false unless type(value) == "table"
  return true if (getmetatable value) == cjson.empty_array_mt
  #value > 0

ESCAPES = {
  [ '"' ]: '\\"'
  [ "\\" ]: "\\\\"
  [ "\b" ]: "\\b"
  [ "\f" ]: "\\f"
  [ "\n" ]: "\\n"
  [ "\r" ]: "\\r"
  [ "\t" ]: "\\t"
}

escape = (text) ->
  (text\gsub '[%c"\\]', (char) ->
    ESCAPES[char] or string.format "\\u%04x", char\byte!)

-- JSON has no infinity and no NaN, and cjson's habit of emitting them as bare
-- words produces a document nothing else will read. Refuse instead of writing a
-- file that only this program can parse.
number = (value) ->
  error "encode_pretty: NaN is not a JSON number" if value != value
  if value == math.huge or value == -math.huge
    error "encode_pretty: infinity is not a JSON number"

  -- An integer written as "3" rather than "3". A build number with a decimal
  -- point in it reads as a mistake to whoever opens the file next.
  return string.format "%d", value if value == math.floor(value) and
    math.abs(value) < 2 ^ 53

  string.format "%.14g", value

-- Mixed key types are grouped rather than compared, because `<` on a number and
-- a string raises. Within a type the order is the natural one.
object_keys = (value) ->
  keys = {}
  for key in pairs value
    kind = type key
    table.insert keys, key if kind == "string" or kind == "number"

  table.sort keys, (a, b) ->
    return a < b if (type a) == (type b)
    (tostring a) < (tostring b)

  keys

--- Encodes a value as JSON a person can read, and diff.
--
-- `encode` is the right thing for a wire format and the wrong thing for a file
-- somebody keeps in version control: it emits one line, and it walks the table
-- with `pairs`, so the same settings encode to a different byte string on every
-- run. The diff is then the whole document and it changes when nothing did.
-- Here the keys are sorted and the structure is indented.
--
-- Raises on a cycle, on NaN and infinity, and on a value JSON has no shape for
-- — a function, a thread, an unrecognised userdata. Callers writing a file
-- should `pcall` it, the way `try_encode` wraps `encode`.
--
-- @param value The value to encode.
-- @param indent (string) One level of indentation. Defaults to two spaces.
-- @return (string) The JSON text, without a trailing newline.
encode_pretty = (value, indent = "  ") ->
  buffer = {}
  open = {}

  -- Forward declared: a local referenced before it is declared is a global, and
  -- a global named `write` here would simply be nil when the recursion reached
  -- it.
  write = nil
  write = (item, depth) ->
    kind = type item

    if item == nil or item == cjson.null
      table.insert buffer, "null"
    elseif kind == "boolean"
      table.insert buffer, item and "true" or "false"
    elseif kind == "number"
      table.insert buffer, number item
    elseif kind == "string"
      table.insert buffer, '"' .. (escape item) .. '"'
    elseif kind == "table"
      error "encode_pretty: the value contains a cycle" if open[item]
      open[item] = true

      inner = indent\rep depth + 1
      closing = indent\rep depth

      if is_array item
        count = #item
        if count == 0
          table.insert buffer, "[]"
        else
          table.insert buffer, "[\n"
          for index = 1, count
            table.insert buffer, inner
            write item[index], depth + 1
            table.insert buffer, index < count and ",\n" or "\n"
          table.insert buffer, closing .. "]"
      else
        keys = object_keys item
        count = #keys
        if count == 0
          table.insert buffer, "{}"
        else
          table.insert buffer, "{\n"
          for index = 1, count
            key = keys[index]
            table.insert buffer, inner
            table.insert buffer, '"' .. (escape tostring key) .. '": '
            write item[key], depth + 1
            table.insert buffer, index < count and ",\n" or "\n"
          table.insert buffer, closing .. "}"

      open[item] = nil
    else
      error "encode_pretty: cannot encode a #{kind}"

  write value, 0
  table.concat buffer

{
  :encode, :decode, :try_decode, :try_encode, :array, :encode_pretty, :is_array
  null: cjson.null
  :cjson
}
