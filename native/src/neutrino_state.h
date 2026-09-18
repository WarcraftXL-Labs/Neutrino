/// Process-wide state: the Lua callback table and the window registry.
///
/// Everything here is touched only on the CEF UI thread, which under
/// CefRunMessageLoop() is also the Lua thread. Nothing is locked, because
/// nothing is reachable from another thread.

#ifndef NEUTRINO_STATE_H
#define NEUTRINO_STATE_H

#include <map>
#include <memory>
#include <string>
#include <vector>

#include "neutrino_api.h"

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"

namespace neutrino {

// One managed top-level window: the Views window, the browser view it hosts,
// and the browser itself once the renderer has spun up.
struct Window {
  int id = 0;

  CefRefPtr<CefWindow> window;
  CefRefPtr<CefBrowserView> browser_view;
  CefRefPtr<CefBrowser> browser;
  // Held as the base type so this header stays independent of client.h; the
  // concrete type is always a NeutrinoClient.
  CefRefPtr<CefClient> client;

  // Snapshot of the creation options the Views delegates keep consulting.
  bool frameless = false;
  bool resizable = true;
  bool maximizable = true;
  bool minimizable = true;
  bool centered = true;
  bool show_on_create = true;
  bool always_on_top = false;
  bool chrome_style = false;
  cef_show_state_t show_state = CEF_SHOW_STATE_NORMAL;
  cef_color_t background = 0;
  CefRect initial_bounds;
  CefSize min_size;
  CefSize max_size;

  // Live state mirrored for cheap synchronous queries from Lua.
  bool is_loading = false;
  bool browser_gone = false;
  std::string title;
  std::string url;

  // Partition the browser was created in, "" for the default context.
  std::string partition;

  // Set once the Lua close handler has agreed; keeps the veto from being asked
  // again during the asynchronous close handshake.
  bool close_confirmed = false;
  bool force_close = false;
};

using WindowPtr = std::shared_ptr<Window>;

// The window registry. Ids start at 1 so 0 can mean "no window".
class Registry {
 public:
  static WindowPtr Create();
  static WindowPtr Get(int id);
  static WindowPtr FromBrowser(CefRefPtr<CefBrowser> browser);
  static WindowPtr FromBrowserId(int browser_id);
  static void Remove(int id);
  static size_t Count();
  static std::vector<WindowPtr> All();

 private:
  static std::map<int, WindowPtr>& Map();
};

// --- Lua callbacks ----------------------------------------------------------

struct Callbacks {
  neutrino_invoke_fn invoke = nullptr;
  void* invoke_user = nullptr;

  neutrino_event_fn event = nullptr;
  void* event_user = nullptr;

  neutrino_request_fn request = nullptr;
  void* request_user = nullptr;

  neutrino_can_close_fn can_close = nullptr;
  void* can_close_user = nullptr;

  neutrino_eval_fn eval = nullptr;
  void* eval_user = nullptr;

  neutrino_timer_fn timer = nullptr;
  void* timer_user = nullptr;

  neutrino_context_menu_fn context_menu = nullptr;
  void* context_menu_user = nullptr;

  neutrino_key_fn key = nullptr;
  void* key_user = nullptr;

  neutrino_dialog_fn dialog = nullptr;
  void* dialog_user = nullptr;

  neutrino_file_dialog_fn file_dialog = nullptr;
  void* file_dialog_user = nullptr;

  neutrino_download_fn download = nullptr;
  void* download_user = nullptr;

  neutrino_resource_fn resource = nullptr;
  void* resource_user = nullptr;

  neutrino_session_fn session = nullptr;
  void* session_user = nullptr;

  neutrino_second_instance_fn second_instance = nullptr;
  void* second_instance_user = nullptr;
};

Callbacks& GetCallbacks();

// Fires a window event on the Lua side. |json| defaults to an empty object.
void EmitEvent(int window_id, const char* event, const std::string& json = "{}");

// --- Global configuration ---------------------------------------------------

// The custom scheme name ("neutrino" unless overridden). Shared with the helper
// process through the --neutrino-scheme command-line switch.
const std::string& SchemeName();
void SetSchemeName(const std::string& name);

// The directory every partition cache path has to live under: root_cache_path
// when the application set one, cache_path otherwise. Empty when it set
// neither, in which case no partition can persist.
// Spells a path the way the platform does.
//
// Chromium compares a profile's parent directory against its user data
// directory as strings, and CEF validates one cache path against another the
// same way, so a path written with forward slashes on Windows matches neither.
// Every path CEF is given goes through here first.
std::string NativePath(std::string path);

const std::string& RootCachePath();
void SetRootCachePath(const std::string& path);

std::string& LastError();

/// Monotonic milliseconds.
int64_t NowMs();

}  // namespace neutrino

#endif  // NEUTRINO_STATE_H
