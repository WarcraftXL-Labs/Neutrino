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

{
  :encode, :decode, :try_decode, :try_encode, :array
  null: cjson.null
  :cjson
}
