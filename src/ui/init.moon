--- The UI layer: reactive state shared between Lua and the page.
--
-- The decision this layer rests on is where state lives. Lua owns the data - it
-- is the side with the filesystem, the archives and the long-running work. The
-- page owns what is on screen: which tab is open, what is selected, what is
-- expanded. Neither side mirrors the other's job.
--
-- A `State` is the channel between them. Lua writes a path, the page's effects
-- re-run; the page writes a path, Lua's listeners fire. Nothing in between
-- re-renders a document or diffs a tree.
--
--     server.router\get "/", (req, res) ->
--       res\html ui.document {
--         title: "Counter"
--         state: { count: 0 }
--         body: "<button data-on-click='count++'>+</button>
--                <span data-text='count'></span>"
--       }
--
--     app\on "ready", ->
--       window = Neutrino.BrowserWindow url: "neutrino://app/"
--       state = ui.State window, { count: 0 }
--       state\on "count", (value, source) -> print "count is #{value} (#{source})"
--
-- The directives the runtime understands, all of them `data-`:
--
--   data-text="expr"        textContent
--   data-html="expr"        innerHTML
--   data-show="expr"        hides the element when falsy
--   data-model="path"       two-way, for inputs and checkboxes
--   data-attr-<name>="expr" sets or removes an attribute
--   data-class-<name>="e"   toggles a class
--   data-on-<event>="stmt"  a listener; $el and $event are in scope
---@module ui

--   data-for="item in expr"  repeats a <template> child, once per element
--
-- A widget is markup and its own style, rendered into a shadow root so the
-- browser scopes it. See ui.widget.
{
  State: (require "ui.state").State
  Widget: (require "ui.widget").Widget
  widgets: require "ui.widgets"
  document: (require "ui.document").document
  escape: (require "ui.document").escape
  runtime: require "ui.runtime"
}
