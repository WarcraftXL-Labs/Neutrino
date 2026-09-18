--- A span whose text comes from an expression.
--
--     Text { value: "user.name" }
--     Text { value: "file.name" }     -- inside a List row
--
-- `value` is an expression rather than a string, which is what makes it useful
-- inside a list: the row's own names are in scope there.
---@module ui.widgets.text

Widget = (require "ui.widget").Widget

---@class Text : Widget
class Text extends Widget
  tag: "n-text"

  defaults: { value: "''" }

  style: [[ :host { display: inline } ]]

  template: [[<span data-text="<%= value %>"></span>]]

{ :Text }
