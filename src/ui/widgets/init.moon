--- A small set of widgets, and an example of how to write more.
--
-- Four of them, chosen because a tool cannot be built without them: something
-- to press, something to group, something to type into, and something to show a
-- list of. Anything more opinionated belongs in the application rather than in
-- the framework.
--
--     widgets = Neutrino.ui.widgets
--
--     panel = widgets.Panel {
--       title: "Archives"
--       children: {
--         widgets.List { path: "files", children: {
--           widgets.Text { value: "file.name" }
--         }}
--         widgets.Button { label: "Refresh", action: "nui.set('refresh', Date.now())" }
--       }
--     }
--
-- Every widget styles itself through custom properties with a fallback, so an
-- application can retheme them from the page without reaching into a shadow
-- root it does not own.
---@module ui.widgets

{
  Button: (require "ui.widgets.button").Button
  Panel: (require "ui.widgets.panel").Panel
  Field: (require "ui.widgets.field").Field
  List: (require "ui.widgets.list").List
  Text: (require "ui.widgets.text").Text
}
