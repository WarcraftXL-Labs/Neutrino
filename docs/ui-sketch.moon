-- A sketch of the UI layer, not working code.
--
-- Nothing here runs today: Container and Button exist as stubs, Extension has no
-- rendering, and App! takes options this omits. It is kept because it is the
-- clearest statement of where src/ui is meant to end up - an extension that
-- declares its interface in Lua rather than assembling HTML strings.
--
-- Delete it once the real thing exists.

App = (require "core.app").App
Extension = (require "core.extension").Extension
Container = (require "ui.components.container").Container
Button = (require "ui.components.button").Button

--- The MPQ Editor Extension, rewritten using Neutrino.
class MPQEditorExtension extends Extension
  new: (app) =>
    super app
    @name = "MPQ Editor"
    
  on_ready: =>
    -- Build the toolbar programmatically instead of HTML strings
    @toolbar = Container {
      id: "mpq-toolbar"
      classes: { "toolbar" }
      children: {
        Button {
          label: "Extract"
          icon: "download"
          disabled: true
          action: {
            method: "GET"
            url: "/mpq/extract"
            target: "#modal"
          }
        },
        Button {
          label: "New MPQ"
          icon: "plus"
          primary: true
          action: {
            method: "GET"
            url: "/mpq/new"
            target: "#view"
            swap: "innerHTML"
          }
        }
      }
    }
    
    print "MPQ Toolbar Generated UI:"
    print @toolbar\render!

-- Run the demonstration
my_app = App!
my_app\register_extension MPQEditorExtension
my_app\run!