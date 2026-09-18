// Neutrino - the C entry points LuaJIT calls through FFI.
//
// This file is deliberately thin: it validates arguments, translates between
// the C ABI and CEF types, and delegates. All the behaviour lives in the
// client, the Views delegates and the scheme handler.

#include <windows.h>

#include <string>
#include <vector>

#include "app.h"
#include "client.h"
#include "neutrino_api.h"
#include "neutrino_json.h"
#include "neutrino_state.h"
#include "scheme_handler.h"
#include "session.h"
#include "shell.h"
#include "timers.h"
#include "window_delegate.h"

#include "include/cef_app.h"
#include "include/cef_image.h"
#include "include/cef_parser.h"
#include "include/cef_version.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_display.h"
#include "include/views/cef_window.h"

using neutrino::JsQuote;
using neutrino::LastError;
using neutrino::Registry;
using neutrino::WindowPtr;

namespace {

CefRefPtr<NeutrinoApp> g_app;
bool g_initialized = false;

// Backing storage for the const char* accessors. Valid until the next call to
// the same function, which is the usual C convention and all LuaJIT needs since
// it copies with ffi.string() immediately.
std::string g_url_buffer;
std::string g_title_buffer;
std::string g_version_buffer;
std::string g_config_summary = "{}";

// Assigns a CefString only when the C string is present and non-empty, so an
// unset option keeps CEF's default rather than clearing it.
//
// Note the named local. Writing `CefString(target) = value;` here would be a
// most vexing parse: with `target` a plain identifier, the compiler reads it as
// a declaration of a local CefString called `target` that shadows the
// parameter, so the assignment goes to the local and the caller's struct is
// never touched. CEF then falls back to its defaults, and on Windows the
// default subprocess is the host executable - which is how an unset
// browser_subprocess_path turns into every child process relaunching the Lua
// interpreter.
void AssignIfSet(cef_string_t* target, const char* value) {
  if (value && *value) {
    CefString attached(target);  // attaches without taking ownership
    attached.FromString(std::string(value));
  }
}

// Same, for an option that is a filesystem path.
//
// Paths are spelled the way the platform spells them before CEF sees them.
// Chromium and CEF both compare cache paths against each other as strings, so
// mixing separators does not fail loudly: a request context whose cache path is
// written with forward slashes is quietly refused, and the partition falls back
// to memory having reported itself as persistent.
void AssignPathIfSet(cef_string_t* target, const char* value) {
  if (value && *value) {
    CefString attached(target);
    attached.FromString(neutrino::NativePath(std::string(value)));
  }
}

// Resolves a window id, returning nullptr when the window is gone. Every
// exported accessor goes through this so a stale id from Lua is inert instead
// of a crash.
WindowPtr Find(int id) {
  return Registry::Get(id);
}

// Resolves a window that also has a live browser.
WindowPtr FindWithBrowser(int id) {
  auto win = Registry::Get(id);
  return (win && win->browser) ? win : nullptr;
}

// Hands a fully described registry entry to CEF: browser view, top-level
// window, title.
//
// Split out of neutrino_window_create because a window in a partition cannot be
// built until its request context has finished initializing, so this runs
// either inline or from the context's ready callback. Reports the reason in
// LastError() and leaves the entry for the caller to remove.
bool BuildWindow(const WindowPtr& win) {
  CefBrowserSettings browser_settings;
  browser_settings.background_color = win->background;

  // Null for the default partition, which is how CreateBrowserView asks for
  // the global context.
  CefRefPtr<CefRequestContext> request_context =
      neutrino::GetPartition(win->partition);

  win->browser_view = CefBrowserView::CreateBrowserView(
      win->client, win->url, browser_settings, nullptr, request_context,
      new NeutrinoBrowserViewDelegate(win->id));

  if (!win->browser_view) {
    LastError() = "CefBrowserView::CreateBrowserView failed";
    return false;
  }

  // The delegate picks the registry entry back up in OnWindowCreated and
  // completes the wiring there; the browser itself arrives asynchronously and
  // announces itself with the "ready" event.
  CefWindow::CreateTopLevelWindow(new NeutrinoWindowDelegate(win->id));

  if (!win->window) {
    LastError() = "CefWindow::CreateTopLevelWindow failed";
    return false;
  }

  if (!win->title.empty()) {
    win->window->SetTitle(win->title);
  }
  return true;
}

cef_show_state_t ToShowState(int value) {
  switch (value) {
    case 1:  return CEF_SHOW_STATE_MINIMIZED;
    case 2:  return CEF_SHOW_STATE_MAXIMIZED;
    case 3:  return CEF_SHOW_STATE_FULLSCREEN;
    default: return CEF_SHOW_STATE_NORMAL;
  }
}

}  // namespace

// --- Lifecycle --------------------------------------------------------------

NEUTRINO_API int neutrino_init(const neutrino_app_options* opts) {
  if (g_initialized) {
    LastError() = "neutrino_init already called";
    return 0;
  }
  if (!opts) {
    LastError() = "neutrino_init requires options";
    return 0;
  }

  if (opts->scheme_name && *opts->scheme_name) {
    neutrino::SetSchemeName(opts->scheme_name);
  }

  CefMainArgs main_args(GetModuleHandle(nullptr));

  g_app = new NeutrinoApp();
  g_app->set_disable_gpu(opts->disable_gpu != 0);

  CefSettings settings;
  settings.no_sandbox = true;

  // CEF owns the message loop and runs it on this thread, which makes this the
  // CEF UI thread and therefore lets Lua callbacks run without marshalling.
  //
  // The alternative, external_message_pump, hands the loop to the application -
  // and with it responsibility for dispatching the Win32 queue, re-entrancy and
  // modal loops. CEF documents that mode as not recommended, and it is exactly
  // the work Chromium already does correctly here.
  settings.multi_threaded_message_loop = false;
  settings.external_message_pump = false;

  settings.windowless_rendering_enabled = false;
  settings.log_severity = static_cast<cef_log_severity_t>(opts->log_severity);
  settings.remote_debugging_port = opts->remote_debugging_port;
  settings.persist_session_cookies = opts->persist_session_cookies;
  settings.background_color =
      CefColorSetARGB(255, opts->bg_r, opts->bg_g, opts->bg_b);

  AssignPathIfSet(&settings.cache_path, opts->cache_path);
  AssignPathIfSet(&settings.root_cache_path, opts->root_cache_path);
  AssignPathIfSet(&settings.browser_subprocess_path, opts->subprocess_path);
  AssignPathIfSet(&settings.resources_dir_path, opts->resources_path);
  AssignPathIfSet(&settings.locales_dir_path, opts->locales_path);
  AssignPathIfSet(&settings.log_file, opts->log_file);
  AssignIfSet(&settings.user_agent, opts->user_agent);
  AssignIfSet(&settings.locale, opts->locale);

  // Captured before CefInitialize, which takes ownership of the strings, so
  // neutrino_config_summary() can report what CEF actually received. Getting a
  // path wrong here fails at runtime in confusing ways - child processes
  // silently relaunch the host executable - so it is worth being able to see.
  g_config_summary =
      neutrino::JsonObject()
          .Str("scheme", neutrino::SchemeName())
          .Str("subprocessPath",
               CefString(&settings.browser_subprocess_path).ToString())
          .Str("resourcesPath",
               CefString(&settings.resources_dir_path).ToString())
          .Str("localesPath", CefString(&settings.locales_dir_path).ToString())
          .Str("cachePath", CefString(&settings.cache_path).ToString())
          .Str("rootCachePath", CefString(&settings.root_cache_path).ToString())
          .Bool("ownsMessageLoop", settings.external_message_pump == 0)
          .Build();

  // Partitions have to be created under this, so it is remembered before
  // CefInitialize consumes the strings. CEF treats cache_path as the root when
  // root_cache_path is unset, and so does Neutrino.
  {
    const std::string root = CefString(&settings.root_cache_path).ToString();
    neutrino::SetRootCachePath(
        root.empty() ? CefString(&settings.cache_path).ToString() : root);
  }

  if (!CefInitialize(main_args, settings, g_app.get(), nullptr)) {
    LastError() = "CefInitialize failed";
    g_app = nullptr;
    return 0;
  }

  g_initialized = true;
  return 1;
}

NEUTRINO_API const char* neutrino_config_summary(void) {
  return g_config_summary.c_str();
}

NEUTRINO_API void neutrino_run(void) {
  if (!g_initialized) {
    return;
  }
  // Blocks here for the lifetime of the application. CEF dispatches Win32
  // messages, services its own task queue, and runs every Neutrino callback on
  // this thread until neutrino_quit() is called.
  CefRunMessageLoop();
}

NEUTRINO_API void neutrino_quit(void) {
  if (g_initialized) {
    CefQuitMessageLoop();
  }
}

NEUTRINO_API void neutrino_shutdown(void) {
  if (!g_initialized) {
    return;
  }
  g_initialized = false;

  // Timers hold queued tasks that must not outlive CEF.
  neutrino::StopAllTimers();

  // The listening window has to go before the process does, or a second
  // instance started moments later finds a window nobody is reading.
  neutrino::ReleaseSingleInstance();

  g_app = nullptr;
  CefShutdown();
}

// --- Timers -----------------------------------------------------------------

NEUTRINO_API int neutrino_timer_start(int delay_ms, int repeat_ms) {
  return neutrino::StartTimer(delay_ms, repeat_ms);
}

NEUTRINO_API void neutrino_timer_stop(int timer_id) {
  neutrino::StopTimer(timer_id);
}

NEUTRINO_API void neutrino_sleep(int ms) {
  if (ms > 0) {
    Sleep(static_cast<DWORD>(ms));
  }
}

NEUTRINO_API int neutrino_window_count(void) {
  return static_cast<int>(Registry::Count());
}

NEUTRINO_API const char* neutrino_last_error(void) {
  return LastError().c_str();
}

NEUTRINO_API const char* neutrino_cef_version(void) {
  g_version_buffer = std::string(CEF_VERSION) + " (Chromium " +
                     std::to_string(CHROME_VERSION_MAJOR) + "." +
                     std::to_string(CHROME_VERSION_MINOR) + "." +
                     std::to_string(CHROME_VERSION_BUILD) + "." +
                     std::to_string(CHROME_VERSION_PATCH) + ")";
  return g_version_buffer.c_str();
}

// --- Callback registration --------------------------------------------------

NEUTRINO_API void neutrino_set_invoke_handler(neutrino_invoke_fn fn, void* user) {
  neutrino::GetCallbacks().invoke = fn;
  neutrino::GetCallbacks().invoke_user = user;
}

NEUTRINO_API void neutrino_set_event_handler(neutrino_event_fn fn, void* user) {
  neutrino::GetCallbacks().event = fn;
  neutrino::GetCallbacks().event_user = user;
}

NEUTRINO_API void neutrino_set_request_handler(neutrino_request_fn fn, void* user) {
  neutrino::GetCallbacks().request = fn;
  neutrino::GetCallbacks().request_user = user;
}

NEUTRINO_API void neutrino_set_can_close_handler(neutrino_can_close_fn fn, void* user) {
  neutrino::GetCallbacks().can_close = fn;
  neutrino::GetCallbacks().can_close_user = user;
}

NEUTRINO_API void neutrino_set_eval_handler(neutrino_eval_fn fn, void* user) {
  neutrino::GetCallbacks().eval = fn;
  neutrino::GetCallbacks().eval_user = user;
}

NEUTRINO_API void neutrino_set_timer_handler(neutrino_timer_fn fn, void* user) {
  neutrino::GetCallbacks().timer = fn;
  neutrino::GetCallbacks().timer_user = user;
}

NEUTRINO_API void neutrino_set_context_menu_handler(neutrino_context_menu_fn fn,
                                                    void* user) {
  neutrino::GetCallbacks().context_menu = fn;
  neutrino::GetCallbacks().context_menu_user = user;
}

NEUTRINO_API void neutrino_set_key_handler(neutrino_key_fn fn, void* user) {
  neutrino::GetCallbacks().key = fn;
  neutrino::GetCallbacks().key_user = user;
}

NEUTRINO_API void neutrino_set_dialog_handler(neutrino_dialog_fn fn, void* user) {
  neutrino::GetCallbacks().dialog = fn;
  neutrino::GetCallbacks().dialog_user = user;
}

NEUTRINO_API void neutrino_set_file_dialog_handler(neutrino_file_dialog_fn fn,
                                                   void* user) {
  neutrino::GetCallbacks().file_dialog = fn;
  neutrino::GetCallbacks().file_dialog_user = user;
}

NEUTRINO_API void neutrino_set_download_handler(neutrino_download_fn fn,
                                                void* user) {
  neutrino::GetCallbacks().download = fn;
  neutrino::GetCallbacks().download_user = user;
}

NEUTRINO_API void neutrino_set_resource_handler(neutrino_resource_fn fn,
                                                void* user) {
  neutrino::GetCallbacks().resource = fn;
  neutrino::GetCallbacks().resource_user = user;
}

NEUTRINO_API void neutrino_set_session_handler(neutrino_session_fn fn,
                                              void* user) {
  neutrino::GetCallbacks().session = fn;
  neutrino::GetCallbacks().session_user = user;
}

NEUTRINO_API int neutrino_dialog_respond(int dialog_id,
                                         int success,
                                         const char* user_input) {
  return NeutrinoRespondToDialog(dialog_id, success != 0,
                                 user_input ? user_input : "")
             ? 1
             : 0;
}

// --- Window lifecycle -------------------------------------------------------

NEUTRINO_API int neutrino_window_create(const neutrino_window_options* opts) {
  if (!g_initialized) {
    LastError() = "neutrino_init must be called before creating a window";
    return 0;
  }
  if (!opts) {
    LastError() = "neutrino_window_create requires options";
    return 0;
  }

  auto win = Registry::Create();

  win->frameless = opts->frameless != 0;
  win->resizable = opts->resizable != 0;
  win->maximizable = opts->maximizable != 0;
  win->minimizable = opts->minimizable != 0;
  win->centered = opts->centered != 0;
  win->show_on_create = opts->show != 0;
  win->always_on_top = opts->always_on_top != 0;
  win->chrome_style = opts->chrome_style != 0;
  win->show_state = ToShowState(opts->show_state);
  win->title = opts->title ? opts->title : "Neutrino";
  win->url = opts->url ? opts->url : "about:blank";
  win->partition = opts->partition ? opts->partition : "";

  win->initial_bounds =
      CefRect(opts->x, opts->y, opts->width > 0 ? opts->width : 1024,
              opts->height > 0 ? opts->height : 768);
  win->min_size = CefSize(opts->min_width, opts->min_height);
  win->max_size = CefSize(opts->max_width, opts->max_height);

  win->client = new NeutrinoClient(win->id);
  win->background =
      CefColorSetARGB(255, opts->bg_r, opts->bg_g, opts->bg_b);

  // Everything above is recorded on the registry entry rather than used here,
  // because a window in a partition may have to wait for its request context
  // before any of it can be handed to CEF.
  if (neutrino::PreparePartition(win->partition)) {
    if (!BuildWindow(win)) {
      Registry::Remove(win->id);
      return 0;
    }
    return win->id;
  }

  // The context is still coming up. The id comes back now so the caller can
  // register its handlers, and the window appears once the context is ready -
  // which is also when "ready" fires, exactly as it does for any other window.
  const int pending_id = win->id;
  neutrino::WhenPartitionReady(win->partition, [pending_id]() {
    auto pending = Registry::Get(pending_id);
    if (!pending) {
      return;  // closed before its context came up
    }
    if (!BuildWindow(pending)) {
      neutrino::EmitEvent(
          pending_id, "create-failed",
          neutrino::JsonObject().Str("error", LastError()).Build());
      neutrino::EmitEvent(pending_id, "closed");
      Registry::Remove(pending_id);
    }
  });
  return pending_id;
}

NEUTRINO_API int neutrino_window_valid(int id) {
  return Find(id) ? 1 : 0;
}

NEUTRINO_API int neutrino_window_ready(int id) {
  return FindWithBrowser(id) ? 1 : 0;
}

NEUTRINO_API void neutrino_window_close(int id, int force) {
  auto win = Find(id);
  if (!win) {
    return;
  }
  // force skips the Lua veto in NeutrinoWindowDelegate::CanClose.
  win->force_close = force != 0;
  if (win->window) {
    win->window->Close();
    return;
  }

  // Closed before it was built: the window is still waiting on its partition's
  // context. Dropping it from the registry is what cancels that, since the
  // ready callback looks the id back up and finds nothing. "closed" is emitted
  // by hand because no CefWindow ever existed to report it.
  neutrino::EmitEvent(id, "closed");
  Registry::Remove(id);
}

// --- Navigation -------------------------------------------------------------

NEUTRINO_API void neutrino_window_load_url(int id, const char* url) {
  auto win = FindWithBrowser(id);
  if (win && url) {
    win->browser->GetMainFrame()->LoadURL(url);
  }
}

NEUTRINO_API void neutrino_window_reload(int id, int ignore_cache) {
  if (auto win = FindWithBrowser(id)) {
    if (ignore_cache) {
      win->browser->ReloadIgnoreCache();
    } else {
      win->browser->Reload();
    }
  }
}

NEUTRINO_API void neutrino_window_stop(int id) {
  if (auto win = FindWithBrowser(id)) {
    win->browser->StopLoad();
  }
}

NEUTRINO_API void neutrino_window_back(int id) {
  if (auto win = FindWithBrowser(id)) {
    win->browser->GoBack();
  }
}

NEUTRINO_API void neutrino_window_forward(int id) {
  if (auto win = FindWithBrowser(id)) {
    win->browser->GoForward();
  }
}

NEUTRINO_API int neutrino_window_can_back(int id) {
  auto win = FindWithBrowser(id);
  return (win && win->browser->CanGoBack()) ? 1 : 0;
}

NEUTRINO_API int neutrino_window_can_forward(int id) {
  auto win = FindWithBrowser(id);
  return (win && win->browser->CanGoForward()) ? 1 : 0;
}

NEUTRINO_API const char* neutrino_window_url(int id) {
  auto win = Find(id);
  g_url_buffer = win ? win->url : std::string();
  return g_url_buffer.c_str();
}

NEUTRINO_API const char* neutrino_window_title(int id) {
  auto win = Find(id);
  g_title_buffer = win ? win->title : std::string();
  return g_title_buffer.c_str();
}

NEUTRINO_API int neutrino_window_is_loading(int id) {
  auto win = Find(id);
  return (win && win->is_loading) ? 1 : 0;
}

// --- Script and IPC ---------------------------------------------------------

NEUTRINO_API void neutrino_window_exec_js(int id, const char* code) {
  auto win = FindWithBrowser(id);
  if (win && code) {
    win->browser->GetMainFrame()->ExecuteJavaScript(
        code, win->browser->GetMainFrame()->GetURL(), 0);
  }
}

NEUTRINO_API int neutrino_window_eval(int id, const char* code) {
  auto win = FindWithBrowser(id);
  if (!win || !code) {
    return 0;
  }

  static int next_request_id = 1;
  const int request_id = next_request_id++;

  CefRefPtr<CefProcessMessage> message =
      CefProcessMessage::Create(neutrino_msg::kEvalRequest);
  CefRefPtr<CefListValue> args = message->GetArgumentList();
  args->SetInt(0, request_id);
  args->SetString(1, code);

  win->browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
  return request_id;
}

NEUTRINO_API void neutrino_window_send(int id, const char* channel, const char* payload) {
  auto win = FindWithBrowser(id);
  if (!win || !channel) {
    return;
  }

  // Both values are escaped into JS string literals, so arbitrary payloads
  // (quotes, newlines, </script>) cannot break out into executable code.
  const std::string script = "window.neutrino && window.neutrino._emit(" +
                             JsQuote(channel) + "," +
                             JsQuote(payload ? payload : "") + ");";

  win->browser->GetMainFrame()->ExecuteJavaScript(script, "neutrino://internal/send", 0);
}

NEUTRINO_API void neutrino_window_set_zoom(int id, double level) {
  if (auto win = FindWithBrowser(id)) {
    win->browser->GetHost()->SetZoomLevel(level);
  }
}

NEUTRINO_API double neutrino_window_get_zoom(int id) {
  auto win = FindWithBrowser(id);
  return win ? win->browser->GetHost()->GetZoomLevel() : 0.0;
}

// --- DevTools ---------------------------------------------------------------

NEUTRINO_API void neutrino_window_open_devtools(int id) {
  if (auto win = FindWithBrowser(id)) {
    // Default window info: CEF hosts DevTools in its own window, which
    // NeutrinoBrowserViewDelegate deliberately declines to adopt.
    CefWindowInfo window_info;
    CefBrowserSettings settings;
    win->browser->GetHost()->ShowDevTools(window_info, nullptr, settings,
                                          CefPoint());
  }
}

NEUTRINO_API void neutrino_window_close_devtools(int id) {
  if (auto win = FindWithBrowser(id)) {
    win->browser->GetHost()->CloseDevTools();
  }
}

NEUTRINO_API int neutrino_window_has_devtools(int id) {
  auto win = FindWithBrowser(id);
  return (win && win->browser->GetHost()->HasDevTools()) ? 1 : 0;
}

// --- Window state -----------------------------------------------------------

// Every accessor below goes through the Views window, so the coordinates are
// DIP and correct on any display scale without touching Win32.

NEUTRINO_API void neutrino_window_show(int id) {
  auto win = Find(id);
  if (win && win->window) {
    win->window->Show();
  }
}

NEUTRINO_API void neutrino_window_hide(int id) {
  auto win = Find(id);
  if (win && win->window) {
    win->window->Hide();
  }
}

NEUTRINO_API void neutrino_window_minimize(int id) {
  auto win = Find(id);
  if (win && win->window) {
    win->window->Minimize();
  }
}

NEUTRINO_API void neutrino_window_maximize(int id) {
  auto win = Find(id);
  if (win && win->window) {
    win->window->Maximize();
  }
}

NEUTRINO_API void neutrino_window_restore(int id) {
  auto win = Find(id);
  if (win && win->window) {
    win->window->Restore();
  }
}

NEUTRINO_API void neutrino_window_focus(int id) {
  auto win = Find(id);
  if (win && win->window) {
    win->window->Activate();
  }
}

NEUTRINO_API void neutrino_window_center(int id) {
  auto win = Find(id);
  if (win && win->window) {
    const CefRect bounds = win->window->GetBounds();
    win->window->CenterWindow(CefSize(bounds.width, bounds.height));
  }
}

NEUTRINO_API void neutrino_window_set_title(int id, const char* title) {
  auto win = Find(id);
  if (win && title) {
    win->title = title;
    if (win->window) {
      win->window->SetTitle(title);
    }
  }
}

NEUTRINO_API void neutrino_window_set_fullscreen(int id, int on) {
  auto win = Find(id);
  if (win && win->window) {
    win->window->SetFullscreen(on != 0);
  }
}

NEUTRINO_API void neutrino_window_set_always_on_top(int id, int on) {
  auto win = Find(id);
  if (win) {
    win->always_on_top = on != 0;
    if (win->window) {
      win->window->SetAlwaysOnTop(on != 0);
    }
  }
}

NEUTRINO_API int neutrino_window_is_maximized(int id) {
  auto win = Find(id);
  return (win && win->window && win->window->IsMaximized()) ? 1 : 0;
}

NEUTRINO_API int neutrino_window_is_minimized(int id) {
  auto win = Find(id);
  return (win && win->window && win->window->IsMinimized()) ? 1 : 0;
}

NEUTRINO_API int neutrino_window_is_fullscreen(int id) {
  auto win = Find(id);
  return (win && win->window && win->window->IsFullscreen()) ? 1 : 0;
}

NEUTRINO_API int neutrino_window_is_visible(int id) {
  auto win = Find(id);
  return (win && win->window && win->window->IsVisible()) ? 1 : 0;
}

NEUTRINO_API int neutrino_window_is_active(int id) {
  auto win = Find(id);
  return (win && win->window && win->window->IsActive()) ? 1 : 0;
}

// --- Geometry ---------------------------------------------------------------

NEUTRINO_API void neutrino_window_set_bounds(int id, const neutrino_rect* bounds) {
  auto win = Find(id);
  if (win && win->window && bounds) {
    win->window->SetBounds(
        CefRect(bounds->x, bounds->y, bounds->width, bounds->height));
  }
}

NEUTRINO_API void neutrino_window_get_bounds(int id, neutrino_rect* out) {
  if (!out) {
    return;
  }
  out->x = out->y = out->width = out->height = 0;

  auto win = Find(id);
  if (win && win->window) {
    const CefRect bounds = win->window->GetBounds();
    out->x = bounds.x;
    out->y = bounds.y;
    out->width = bounds.width;
    out->height = bounds.height;
  }
}

NEUTRINO_API void neutrino_window_set_min_size(int id, int w, int h) {
  if (auto win = Find(id)) {
    win->min_size = CefSize(w, h);
    if (win->window) {
      // Re-runs GetMinimumSize on the delegate.
      win->window->InvalidateLayout();
    }
  }
}

NEUTRINO_API void neutrino_window_set_max_size(int id, int w, int h) {
  if (auto win = Find(id)) {
    win->max_size = CefSize(w, h);
    if (win->window) {
      win->window->InvalidateLayout();
    }
  }
}

NEUTRINO_API void* neutrino_window_handle(int id) {
  auto win = Find(id);
  if (win && win->window) {
    return static_cast<void*>(win->window->GetWindowHandle());
  }
  return nullptr;
}

NEUTRINO_API void neutrino_window_click(int id,
                                        int x,
                                        int y,
                                        int button,
                                        int click_count) {
  auto win = FindWithBrowser(id);
  if (!win) {
    return;
  }

  cef_mouse_button_type_t type = MBT_LEFT;
  if (button == 1) {
    type = MBT_MIDDLE;
  } else if (button == 2) {
    type = MBT_RIGHT;
  }

  CefMouseEvent event;
  event.x = x;
  event.y = y;
  event.modifiers = 0;

  const int count = click_count > 0 ? click_count : 1;
  CefRefPtr<CefBrowserHost> host = win->browser->GetHost();

  // Input is dropped by an unfocused browser, and the renderer expects the
  // pointer to be over the target before a button goes down, so a bare click
  // pair is not enough to reproduce what a user does.
  host->SetFocus(true);
  host->SendMouseMoveEvent(event, /*mouseLeave=*/false);

  // A click is a press and a release; sending only one leaves the renderer
  // believing a button is still held.
  host->SendMouseClickEvent(event, type, /*mouseUp=*/false, count);
  host->SendMouseClickEvent(event, type, /*mouseUp=*/true, count);
}

NEUTRINO_API int neutrino_window_set_icon(int id,
                                          const char* png_data,
                                          int png_len) {
  auto win = Find(id);
  if (!win || !win->window || !png_data || png_len <= 0) {
    return 0;
  }

  CefRefPtr<CefImage> image = CefImage::CreateImage();
  // Scale factor 1.0: CEF picks the representation it needs, and a single PNG
  // at the largest size it will ask for is the simplest thing that works.
  if (!image->AddPNG(1.0f, png_data, static_cast<size_t>(png_len))) {
    LastError() = "could not decode the icon PNG";
    return 0;
  }

  win->window->SetWindowIcon(image);     // title bar and Alt-Tab
  win->window->SetWindowAppIcon(image);  // taskbar
  return 1;
}

// --- Displays ---------------------------------------------------------------

NEUTRINO_API int neutrino_display_count(void) {
  std::vector<CefRefPtr<CefDisplay>> displays;
  CefDisplay::GetAllDisplays(displays);
  return static_cast<int>(displays.size());
}

NEUTRINO_API int neutrino_display_info(int index,
                                       neutrino_rect* bounds,
                                       neutrino_rect* work_area,
                                       float* scale_factor,
                                       int* is_primary) {
  std::vector<CefRefPtr<CefDisplay>> displays;
  CefDisplay::GetAllDisplays(displays);

  if (index < 0 || index >= static_cast<int>(displays.size())) {
    return 0;
  }

  CefRefPtr<CefDisplay> display = displays[index];

  if (bounds) {
    const CefRect r = display->GetBounds();
    bounds->x = r.x;
    bounds->y = r.y;
    bounds->width = r.width;
    bounds->height = r.height;
  }
  if (work_area) {
    const CefRect r = display->GetWorkArea();
    work_area->x = r.x;
    work_area->y = r.y;
    work_area->width = r.width;
    work_area->height = r.height;
  }
  if (scale_factor) {
    *scale_factor = display->GetDeviceScaleFactor();
  }
  if (is_primary) {
    CefRefPtr<CefDisplay> primary = CefDisplay::GetPrimaryDisplay();
    *is_primary = (primary && primary->GetID() == display->GetID()) ? 1 : 0;
  }
  return 1;
}

// --- Scheme responses -------------------------------------------------------

NEUTRINO_API int neutrino_response_set(int response_id,
                                       int status,
                                       const char* mime,
                                       const char* headers_json,
                                       const char* body,
                                       int body_len) {
  return NeutrinoSetResponse(response_id, status, mime ? mime : "",
                             headers_json ? headers_json : "", body, body_len)
             ? 1
             : 0;
}

// --- Deferred IPC replies ---------------------------------------------------

NEUTRINO_API int neutrino_invoke_resolve(int request_id, const char* json) {
  return NeutrinoResolveInvoke(request_id, json ? json : "null") ? 1 : 0;
}

NEUTRINO_API int neutrino_invoke_reject(int request_id,
                                        int code,
                                        const char* message) {
  return NeutrinoRejectInvoke(request_id, code, message ? message : "error")
             ? 1
             : 0;
}

// --- File dialogs -----------------------------------------------------------

namespace {

/// Reports a dismissed file dialog back to Lua.
///
/// Holds only the ids, not the window, so a dialog outliving its window is a
/// lookup miss rather than a dangling reference.
class FileDialogCallback : public CefRunFileDialogCallback {
 public:
  FileDialogCallback(int window_id, int request_id)
      : window_id_(window_id), request_id_(request_id) {}

  void OnFileDialogDismissed(const std::vector<CefString>& file_paths) override {
    neutrino::Callbacks& cb = neutrino::GetCallbacks();
    if (!cb.file_dialog) {
      return;
    }

    // An empty array means the user cancelled, which the application has to be
    // able to tell apart from a selection.
    std::string json = "[";
    for (size_t i = 0; i < file_paths.size(); ++i) {
      if (i > 0) {
        json += ",";
      }
      json += neutrino::JsonQuote(file_paths[i].ToString());
    }
    json += "]";

    cb.file_dialog(window_id_, request_id_, json.c_str(), cb.file_dialog_user);
  }

 private:
  const int window_id_;
  const int request_id_;

  IMPLEMENT_REFCOUNTING(FileDialogCallback);
  DISALLOW_COPY_AND_ASSIGN(FileDialogCallback);
};

cef_file_dialog_mode_t ToFileDialogMode(int value) {
  switch (value) {
    case 1:  return FILE_DIALOG_OPEN_MULTIPLE;
    case 2:  return FILE_DIALOG_OPEN_FOLDER;
    case 3:  return FILE_DIALOG_SAVE;
    default: return FILE_DIALOG_OPEN;
  }
}

/// Decodes the JSON array of accept filters into the form CEF expects.
std::vector<CefString> ParseFilters(const char* filters_json) {
  std::vector<CefString> filters;
  if (!filters_json || !*filters_json) {
    return filters;
  }

  CefRefPtr<CefValue> parsed = CefParseJSON(filters_json, JSON_PARSER_RFC);
  if (!parsed || parsed->GetType() != VTYPE_LIST) {
    return filters;
  }

  CefRefPtr<CefListValue> list = parsed->GetList();
  for (size_t i = 0; i < list->GetSize(); ++i) {
    if (list->GetType(i) == VTYPE_STRING) {
      filters.push_back(list->GetString(i));
    }
  }
  return filters;
}

}  // namespace

NEUTRINO_API int neutrino_window_file_dialog(int id,
                                             int mode,
                                             const char* title,
                                             const char* default_path,
                                             const char* filters_json) {
  auto win = FindWithBrowser(id);
  if (!win) {
    return 0;
  }

  static int next_request_id = 1;
  const int request_id = next_request_id++;

  win->browser->GetHost()->RunFileDialog(
      ToFileDialogMode(mode), title ? CefString(title) : CefString(),
      default_path ? CefString(default_path) : CefString(),
      ParseFilters(filters_json), new FileDialogCallback(id, request_id));

  return request_id;
}

// --- Downloads --------------------------------------------------------------

NEUTRINO_API int neutrino_download_begin(int download_id,
                                         const char* path,
                                         int show_dialog) {
  return NeutrinoBeginDownload(download_id, path ? path : "", show_dialog != 0)
             ? 1
             : 0;
}

NEUTRINO_API int neutrino_download_cancel(int download_id) {
  // Either it is still waiting for a destination, or it is already running.
  if (NeutrinoCancelPendingDownload(download_id)) {
    return 1;
  }
  return NeutrinoControlDownload(download_id, 0) ? 1 : 0;
}

NEUTRINO_API int neutrino_download_control(int download_id, int action) {
  return NeutrinoControlDownload(download_id, action) ? 1 : 0;
}

// --- Sessions and cookies ---------------------------------------------------

namespace {

// Null and empty both mean the default partition, so callers can pass either.
std::string Str(const char* value) {
  return value ? std::string(value) : std::string();
}

std::string g_session_info;

}  // namespace

NEUTRINO_API const char* neutrino_session_info(const char* partition) {
  g_session_info = neutrino::PartitionInfo(Str(partition));
  return g_session_info.c_str();
}

NEUTRINO_API int neutrino_cookies_get(const char* partition,
                                      const char* url,
                                      int include_http_only) {
  return neutrino::SessionGetCookies(Str(partition), Str(url),
                                     include_http_only != 0);
}

NEUTRINO_API int neutrino_cookies_set(const char* partition,
                                      const char* url,
                                      const char* cookie_json) {
  return neutrino::SessionSetCookie(Str(partition), Str(url),
                                    Str(cookie_json));
}

NEUTRINO_API int neutrino_cookies_delete(const char* partition,
                                         const char* url,
                                         const char* name) {
  return neutrino::SessionDeleteCookies(Str(partition), Str(url), Str(name));
}

NEUTRINO_API int neutrino_cookies_flush(const char* partition) {
  return neutrino::SessionFlushCookies(Str(partition));
}

NEUTRINO_API int neutrino_session_clear_cache(const char* partition) {
  return neutrino::SessionClearCache(Str(partition));
}

NEUTRINO_API int neutrino_session_clear_auth(const char* partition) {
  return neutrino::SessionClearAuth(Str(partition));
}

NEUTRINO_API int neutrino_session_close_connections(const char* partition) {
  return neutrino::SessionCloseConnections(Str(partition));
}

NEUTRINO_API int neutrino_session_set_color_scheme(const char* partition,
                                                   int variant,
                                                   unsigned int argb) {
  return neutrino::SessionSetColorScheme(Str(partition), variant, argb) ? 1 : 0;
}

// --- Platform shell ---------------------------------------------------------

namespace {
std::string g_clipboard_buffer;
}  // namespace

NEUTRINO_API void neutrino_set_second_instance_handler(
    neutrino_second_instance_fn fn,
    void* user) {
  neutrino::GetCallbacks().second_instance = fn;
  neutrino::GetCallbacks().second_instance_user = user;
}

NEUTRINO_API const char* neutrino_clipboard_read(void) {
  g_clipboard_buffer = neutrino::ClipboardReadText();
  return g_clipboard_buffer.c_str();
}

NEUTRINO_API int neutrino_clipboard_write(const char* text) {
  return neutrino::ClipboardWriteText(Str(text)) ? 1 : 0;
}

NEUTRINO_API int neutrino_shell_open_external(const char* url) {
  return neutrino::OpenExternal(Str(url)) ? 1 : 0;
}

NEUTRINO_API int neutrino_shell_open_path(const char* path) {
  return neutrino::OpenPath(Str(path)) ? 1 : 0;
}

NEUTRINO_API int neutrino_shell_show_in_folder(const char* path) {
  return neutrino::ShowInFolder(Str(path)) ? 1 : 0;
}

NEUTRINO_API int neutrino_single_instance_acquire(const char* name) {
  return neutrino::AcquireSingleInstance(Str(name)) ? 1 : 0;
}

NEUTRINO_API int neutrino_single_instance_notify(const char* name,
                                                 const char* payload) {
  return neutrino::NotifyFirstInstance(Str(name), Str(payload)) ? 1 : 0;
}

NEUTRINO_API void neutrino_single_instance_release(void) {
  neutrino::ReleaseSingleInstance();
}
