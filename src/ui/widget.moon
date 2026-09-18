--- Widgets: a class that renders its own shadow root.
--
-- A widget is markup plus the style that belongs to it, and the two travel
-- together. It renders to a custom element carrying a declarative shadow root,
-- so the browser scopes the style on its own - nothing leaks out of a widget,
-- and the page's own CSS does not reach in.
--
--     class Card extends Widget
--       tag: "n-card"
--       defaults: { title: "" }
--
--       style: [[
--         .card { border: 1px solid var(--n-border, #333); padding: 12px }
--         h2 { margin: 0 0 8px; font-size: 14px }
--       ]]
--
--       template: [[
--         <div class="card">
--           <h2><%= title %></h2>
--           <slot></slot>
--         </div>
--       ]]
--
--     card = Card { title: "Archives", children: { button } }
--     card\render!
--
-- Templates are etlua: `<%= value %>` inserts it escaped, `<%- value %>` raw,
-- `<% code %>` runs. Escaping is the default, which is the right way round -
-- an archive's filename is not markup and should never be treated as any.
--
-- Children go in the light DOM, where `<slot>` picks them up. That is what
-- makes composition work without the parent knowing anything about the child.
---@module ui.widget

etlua = require "etlua"

-- Compiled templates, keyed by their source. Two classes declaring the same
-- template share one compiled function, and a class compiles once rather than
-- once per instance.
compiled = {}

--- Compiles a template, raising with the template's own error message.
---@param source string
---@return function
---@private
compile = (source) ->
  unless compiled[source]
    fn, err = etlua.compile source
    error "widget template: #{err}" unless fn
    compiled[source] = fn

  compiled[source]

-- One counter for the process. Not random: two runs of the same interface
-- should produce the same ids, or a test cannot name an element and a diff of
-- two rendered pages is noise.
counter = 0

--- Returns an id unique within this process.
---@param prefix string
---@return string
---@private
next_id = (prefix) ->
  counter += 1
  "#{prefix}-#{counter}"

--- Escapes text for an HTML attribute value.
---@param value any
---@return string
---@private
attribute_value = (value) ->
  text = tostring value
  text = text\gsub "&", "&amp;"
  text = text\gsub '"', "&quot;"
  text\gsub "<", "&lt;"

---@class Widget
---@field props table The widget's values, defaults merged with what was given.
---@field children (Widget|string)[] Light DOM children, picked up by a slot.
---@field id string The host element's id.
class Widget
  --- The custom element the widget renders as. Subclasses set their own.
  tag: "n-widget"

  --- etlua source for the shadow root's markup.
  template: ""

  --- CSS for the shadow root. Scoped by the browser, so selectors can be plain.
  style: ""

  --- Values the template can count on, overridden by what the caller passes.
  defaults: {}

  --- Whether children go in the light DOM for a slot to pick up.
  -- A widget that places them itself - a list putting them in its row template
  -- through `content` - sets this false, or they would be rendered twice.
  slotted: true

  --- Builds a widget.
  ---@param props? table Template values, plus id, classes, attributes, children.
  new: (props = {}) =>
    @props = {}
    @props[key] = value for key, value in pairs @defaults
    @props[key] = value for key, value in pairs props

    @children = props.children or {}
    @id = props.id or next_id @tag
    @classes = props.classes or {}
    @attributes = props.attributes or {}

  --- Adds a child, rendered into the widget's slot.
  ---@param child Widget|string A widget, or markup as a string.
  ---@return Widget self, for chaining.
  add: (child) =>
    table.insert @children, child
    @

  --- Renders the whole element: host, shadow root and children.
  ---@return string html
  render: =>
    light = @slotted and @render_children! or ""

    "<#{@tag}#{@render_host_attributes!}>" ..
      -- shadowrootclonable, because a widget repeated by data-for is put in
      -- the page by cloning a <template>. Chromium turns a declarative
      -- shadow root into a real one even inside template content, and
      -- cloneNode does not copy a shadow root unless it says it is
      -- clonable - so every row would come out unstyled and empty.
      "<template shadowrootmode=\"open\" shadowrootclonable=\"\">" ..
      "#{@render_shadow!}</template>" ..
      light ..
      "</#{@tag}>"

  --- Renders what goes inside the shadow root: the style, then the template.
  ---@return string html
  render_shadow: =>
    css = @style and @style != "" and "<style>#{@style}</style>" or ""
    css .. @render_template!

  --- Renders the template against the widget's values.
  --
  -- `content` holds the rendered children, for a widget that would rather place
  -- them itself than leave it to a slot.
  ---@return string html
  render_template: =>
    return "" if not @template or @template == ""

    values = { key, value for key, value in pairs @props }
    values.id = @id
    values.widget = @
    values.content = @render_children!

    -- Globals stay reachable, so a template can still call tostring. A name
    -- that is neither a value nor a global renders as nothing rather than as
    -- the word "nil" - etlua's own answer for a missing value - and says so.
    missing = (_, key) ->
      found = _G[key]
      return found if found != nil

      io.stderr\write "[neutrino] widget #{@tag}: template reads '#{key}', " ..
        "which is neither a value nor a global\n"
      ""

    render = compile @template
    render setmetatable values, { __index: missing }

  --- Renders the children into the light DOM.
  ---@return string html
  render_children: =>
    return "" if #@children == 0

    parts = for child in *@children
      if type(child) == "table" and child.render then child\render! else tostring child

    table.concat parts

  --- Renders the host element's attributes, id and classes included.
  ---@return string
  ---@private
  render_host_attributes: =>
    parts = { " id=\"#{attribute_value @id}\"" }

    if #@classes > 0
      table.insert parts, " class=\"#{attribute_value table.concat @classes, " "}\""

    for name, value in pairs @attributes
      continue if value == nil or value == false
      if value == true
        table.insert parts, " #{name}"
      else
        table.insert parts, " #{name}=\"#{attribute_value value}\""

    table.concat parts

{ :Widget, :next_id }
