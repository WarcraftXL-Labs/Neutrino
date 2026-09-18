-- SUPERSEDED - kept for reference, not loaded by anything.
--
-- The first sketch of a UI layer: widgets rendered to HTML strings in Lua, in
-- an htmx flavour. It was written before the framework had a decision about
-- where state lives, and it does not survive that decision:
--
--   * it renders in Lua, so every change means re-rendering and replacing DOM
--   * it interpolates ids, classes and attributes into HTML without escaping
--   * _generate_id uses math.random without a seed, so two runs collide
--
-- The layer that replaced it keeps display state in the page and treats Lua as
-- the source of truth for data. See src/ui/ and docs/architecture.md.

-- ─────────────────────────────────────────────────────────────────────────
-- src/ui/widget.moon
-- ─────────────────────────────────────────────────────────────────────────

--- Base UI Widget Class.
-- Represents a generic DOM element that can be rendered and interacted with.
-- @classmod Widget

class Widget
  --- Constructor for a new Widget.
  -- @param opts (table) Configuration options for the widget.
  -- @param opts.id (string) Optional unique identifier for the DOM element.
  -- @param opts.classes (table) List of CSS classes.
  new: (opts = {}) =>
    @id = opts.id or @_generate_id!
    @classes = opts.classes or {}
    @attributes = opts.attributes or {}
    @children = opts.children or {}
    @parent = nil

    -- Bind children to parent
    for child in *@children
      child.parent = @

  --- Adds a child widget to this widget.
  -- @param child (Widget) The child widget to add.
  add_child: (child) =>
    child.parent = @
    table.insert @children, child

  --- Generates the HTML representation of this widget and its children.
  -- @return (string) Rendered HTML.
  render: =>
    error "render() must be implemented by subclasses"

  --- Renders the attributes table into an HTML string.
  -- @return (string) HTML attribute string (e.g., `id="btn" class="primary"`).
  _render_attributes: =>
    parts = {}
    
    if @id
      table.insert parts, 'id="' .. @id .. '"'
      
    if #@classes > 0
      table.insert parts, 'class="' .. table.concat(@classes, " ") .. '"'
      
    for k, v in pairs @attributes
      -- Convert camelCase to kebab-case for htmx (e.g. hxTarget -> hx-target)
      kebab_key = k\gsub("(%l)(%u)", "%1-%2")\lower!
      table.insert parts, kebab_key .. '="' .. tostring(v) .. '"'
      
    return table.concat parts, " "

  --- Generates a unique ID for the widget if none is provided.
  -- @return (string) A unique ID.
  _generate_id: =>
    "widget_" .. tostring(math.random(100000, 999999))

{ :Widget }
-- ─────────────────────────────────────────────────────────────────────────
-- src/ui/components/button.moon
-- ─────────────────────────────────────────────────────────────────────────

--- Button UI Component.
-- Represents a clickable button, potentially with an icon, handling HTMX actions automatically.
-- @classmod Button

Widget = (require "ui.widget").Widget

class Button extends Widget
  --- Constructor for a new Button.
  -- @param opts (table) Configuration options.
  -- @param opts.label (string) The text displayed on the button.
  -- @param opts.icon (string) Optional icon name.
  -- @param opts.disabled (boolean) Whether the button is disabled.
  -- @param opts.action (table) Action binding (URL, Method, Target).
  new: (opts = {}) =>
    super opts
    @label = opts.label or ""
    @icon = opts.icon
    @disabled = opts.disabled or false
    @action = opts.action

    -- Default button classes
    table.insert @classes, "btn"
    if opts.primary then table.insert @classes, "primary"
    
    @_bind_action! if @action

  --- Binds the HTMX action attributes based on the configuration.
  _bind_action: =>
    method = (@action.method or "GET")\lower!
    url = @action.url
    
    if method == "get"
      @attributes.hxGet = url
    elseif method == "post"
      @attributes.hxPost = url
    elseif method == "put"
      @attributes.hxPut = url
    elseif method == "delete"
      @attributes.hxDelete = url
      
    if @action.target
      @attributes.hxTarget = @action.target
      
    if @action.swap
      @attributes.hxSwap = @action.swap

  --- Renders the HTML for the button.
  -- @return (string) HTML string.
  render: =>
    attrs = @_render_attributes!
    disabled_attr = @disabled and " disabled" or ""
    
    -- In a real environment, this would call the icon resolver
    icon_html = @icon and ('<i class="icon-' .. @icon .. '"></i> ') or ""
    
    return string.format '<button %s%s>%s<span>%s</span></button>', attrs, disabled_attr, icon_html, @label

{ :Button }
-- ─────────────────────────────────────────────────────────────────────────
-- src/ui/components/container.moon
-- ─────────────────────────────────────────────────────────────────────────

--- Container UI Component.
-- A layout element that holds other widgets (div, section, header, etc.).
-- @classmod Container

Widget = (require "ui.widget").Widget

class Container extends Widget
  --- Constructor for a new Container.
  -- @param opts (table) Configuration options.
  -- @param opts.tag (string) The HTML tag to use (default: "div").
  new: (opts = {}) =>
    super opts
    @tag = opts.tag or "div"

  --- Renders the HTML for the container and recursively renders its children.
  -- @return (string) HTML string.
  render: =>
    attrs = @_render_attributes!
    
    children_html = {}
    for child in *@children
      table.insert children_html, child\render!
      
    inner_html = table.concat children_html, "\n"
    
    return string.format '<%s %s>\n%s\n</%s>', @tag, attrs, inner_html, @tag

{ :Container }
