--- A labelled input bound to a path in the store.
--
--     Field { label: "Search", path: "query" }
--
-- Two-way: typing writes `query`, and a write from Lua puts the value back in
-- the input. The path is a store path, not an expression, so a field inside a
-- list row binds to the store rather than to the row.
--
-- The input type is `kind` rather than `type`, because a value named `type`
-- would shadow Lua's own `type` inside the template.
---@module ui.widgets.field

Widget = (require "ui.widget").Widget

---@class Field : Widget
class Field extends Widget
  tag: "n-field"

  defaults: {
    label: ""
    path: ""
    kind: "text"
    placeholder: ""
  }

  style: [[
    label { display: flex; flex-direction: column; gap: 4px }
    .label { font-size: 12px; color: var(--n-fg-dim, #9a9a9a) }
    input {
      font: inherit;
      padding: 6px 8px;
      border: 1px solid var(--n-border, #3a3a3a);
      border-radius: var(--n-radius, 4px);
      background: var(--n-input-bg, #1a1a1a);
      color: var(--n-fg, #e8e8e8);
    }
    input:focus { outline: 1px solid var(--n-accent, #3b6ea5) }
  ]]

  template: [[
    <label>
      <% if label ~= "" then %><span class="label"><%= label %></span><% end %>
      <input type="<%= kind %>" data-model="<%= path %>"
             placeholder="<%= placeholder %>">
    </label>
  ]]

{ :Field }
