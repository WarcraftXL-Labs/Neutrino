--- Display enumeration.
-- Bounds are density independent pixels, matching BrowserWindow geometry, so a
-- window can be positioned from these numbers directly regardless of the
-- display's scale factor.
---@module browser.screen

ffi = require "ffi"
cef = require "core.cef"

M = {}

to_table = (rect) ->
  { x: rect[0].x, y: rect[0].y, width: rect[0].width, height: rect[0].height }

--- Returns every connected display.
-- Only meaningful after App:init(); CEF cannot enumerate displays before then.
---@return table[] displays Each has index, bounds, work_area, scale_factor, primary.
M.get_all_displays = ->
  error "screen requires the native library" unless cef.lib

  bounds = ffi.new "neutrino_rect[1]"
  work_area = ffi.new "neutrino_rect[1]"
  scale = ffi.new "float[1]"
  primary = ffi.new "int[1]"

  displays = {}
  for index = 0, cef.lib.neutrino_display_count! - 1
    continue unless cef.lib.neutrino_display_info(index, bounds, work_area, scale, primary) == 1

    table.insert displays, {
      :index
      bounds: to_table bounds
      -- Excludes the taskbar; this is what to centre a window against.
      work_area: to_table work_area
      -- tonumber so the table stays plain Lua and survives JSON encoding.
      scale_factor: tonumber scale[0]
      primary: primary[0] == 1
    }

  displays

--- Returns the primary display.
---@return table|nil
M.get_primary_display = ->
  for display in *M.get_all_displays!
    return display if display.primary
  nil

M
