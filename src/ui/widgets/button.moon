--- A button that runs a statement in the page.
--
--     Button { label: "Refresh", action: "nui.set('tick', Date.now())" }
--
-- `action` is JavaScript, run with the store and the row's scope in scope, the
-- same as any data-on-click. `disabled` is an expression, so a button can grey
-- itself out from state: `disabled: "busy"`.
---@module ui.widgets.button

Widget = (require "ui.widget").Widget

---@class Button : Widget
class Button extends Widget
  tag: "n-button"

  defaults: {
    label: ""
    action: ""
    disabled: ""
    variant: "default"
  }

  style: [[
    button {
      font: inherit;
      padding: var(--n-button-padding, 6px 14px);
      border: 1px solid var(--n-border, #3a3a3a);
      border-radius: var(--n-radius, 4px);
      background: var(--n-button-bg, #2a2a2a);
      color: var(--n-fg, #e8e8e8);
      cursor: pointer;
    }
    button:hover:not(:disabled) { background: var(--n-button-bg-hover, #333) }
    button:disabled { opacity: .5; cursor: default }
    button.primary {
      background: var(--n-accent, #3b6ea5);
      border-color: var(--n-accent, #3b6ea5);
    }
  ]]

  -- Inside <% %> the language is Lua, not MoonScript: `~=`, not `!=`.
  --
  -- The attributes use <%= %> rather than <%- %>. Escaping is what an attribute
  -- value wants - a quote becomes &quot; and the parser hands the statement
  -- back intact - so an action containing a string literal survives.
  template: [[
    <button part="button" class="<%= variant %>"
      <% if action ~= "" then %>data-on-click="<%= action %>"<% end %>
      <% if disabled ~= "" then %>data-attr-disabled="<%= disabled %>"<% end %>
    ><%= label %></button>
  ]]

{ :Button }
