--- A titled box that holds other widgets.
--
--     Panel { title: "Archives", children: { list } }
--
-- Children land in the light DOM and the panel's <slot> picks them up, so the
-- panel needs to know nothing about them.
---@module ui.widgets.panel

Widget = (require "ui.widget").Widget

---@class Panel : Widget
class Panel extends Widget
  tag: "n-panel"

  defaults: { title: "" }

  style: [[
    section {
      border: 1px solid var(--n-border, #3a3a3a);
      border-radius: var(--n-radius, 4px);
      background: var(--n-panel-bg, #222);
      overflow: hidden;
    }
    header {
      padding: 8px 12px;
      font-weight: 600;
      font-size: 13px;
      border-bottom: 1px solid var(--n-border, #3a3a3a);
      color: var(--n-fg, #e8e8e8);
    }
    .body { padding: 12px }
  ]]

  template: [[
    <section>
      <% if title ~= "" then %><header><%= title %></header><% end %>
      <div class="body"><slot></slot></div>
    </section>
  ]]

{ :Panel }
