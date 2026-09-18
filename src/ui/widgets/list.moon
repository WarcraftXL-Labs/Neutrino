--- Repeats its children once per item in a list from the store.
--
--     List {
--       path: "files"
--       children: { Text { value: "file.name" } }
--     }
--
-- The children are the row, not the content: they go into the repeat template
-- rather than into a slot, which is why `slotted` is false. Inside them, `item`
-- names the element and `index` its position - or whatever `as` renames them
-- to, which is what makes nested lists readable.
---@module ui.widgets.list

Widget = (require "ui.widget").Widget

---@class List : Widget
class List extends Widget
  tag: "n-list"
  slotted: false

  defaults: {
    path: "items"
    as: "item"
    index: "index"
    empty: ""
  }

  style: [[
    .rows { display: flex; flex-direction: column; gap: var(--n-gap, 4px) }
    .empty { color: var(--n-fg-dim, #9a9a9a); font-size: 12px; margin: 0 }
  ]]

  template: [[
    <div class="rows" data-for="<%= as %>, <%= index %> in <%= path %>">
      <template><%- content %></template>
    </div>
    <% if empty ~= "" then %>
      <!-- (length || 0): a Lua table that happens to be empty encodes as {},
           and {}.length is undefined rather than 0. -->
      <p class="empty" data-show="!<%= path %> || (<%= path %>.length || 0) === 0"><%= empty %></p>
    <% end %>
  ]]

{ :List }
