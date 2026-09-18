--- Builds the HTML document a window loads.
--
-- A page needs three things it should not have to assemble by hand: the
-- runtime, the state the runtime starts from, and the boilerplate around them.
--
--     server.router\get "/", (req, res) ->
--       res\html ui.document {
--         title: "Archives"
--         state: { count: 0 }
--         body: "<button data-on-click='count++' data-text='count'></button>"
--       }
--
-- `body` and `head` are HTML, and go in as written - they are the page's own
-- markup. Everything the builder puts around them is escaped.
---@module ui.document

json = require "util.json"
runtime = require "ui.runtime"

--- Escapes text for HTML.
---@param value any
---@return string
escape = (value) ->
  text = tostring value or ""
  text = text\gsub "&", "&amp;"
  text = text\gsub "<", "&lt;"
  text = text\gsub ">", "&gt;"
  text = text\gsub '"', "&quot;"
  text\gsub "'", "&#39;"

--- Encodes a value as JSON that is safe inside a script element.
--
-- A string holding "</script>" would otherwise close the element and put the
-- rest of the payload into the document as markup. Escaping the three
-- characters that can start a tag is enough, and leaves the JSON valid.
---@param value any
---@return string
script_json = (value) ->
  encoded = json.encode value
  encoded = encoded\gsub "<", "\\u003c"
  encoded = encoded\gsub ">", "\\u003e"
  encoded\gsub "&", "\\u0026"

--- Assembles a complete document around a body.
---@param opts? table
---@field opts.title string Document title. Defaults to "Neutrino".
---@field opts.state table Values the page's store starts with.
---@field opts.body string Body markup.
---@field opts.head string Extra markup for the head, such as a stylesheet link.
---@field opts.style string CSS, inlined into a style element.
---@field opts.lang string Language attribute. Defaults to "en".
---@field opts.runtime boolean Set false to leave the runtime out.
---@return string html
document = (opts = {}) ->
  parts = {
    "<!doctype html>"
    "<html lang=\"#{escape opts.lang or "en"}\">"
    "<head>"
    "<meta charset=\"utf-8\">"
    "<title>#{escape opts.title or "Neutrino"}</title>"
  }

  add = (fragment) -> table.insert parts, fragment if fragment and fragment != ""

  add opts.head
  add "<style>#{opts.style}</style>" if opts.style

  -- Before the runtime, which reads it on boot.
  add "<script>window.__NEUTRINO_STATE__=#{script_json opts.state or {}}</script>"
  add runtime.tag! unless opts.runtime == false

  add "</head>"
  add "<body>#{opts.body or ""}</body>"
  add "</html>"

  table.concat parts, "\n"

{ :document, :escape, :script_json }
