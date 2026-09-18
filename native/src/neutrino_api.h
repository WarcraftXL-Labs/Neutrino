// Neutrino - C ABI exposed to LuaJIT via FFI.
//
// Every declaration here is mirrored verbatim in src/core/cef.moon.
// Keep the two in sync: this header is the single source of truth.
//
// Threading contract
// ------------------
// CEF owns the message loop (CefRunMessageLoop) and runs it on the thread that
// called neutrino_init(), which is the Lua thread. Every callback below is
// invoked on that same thread, so Lua state is only ever touched from the
// thread that owns it. Anything CEF hands us on another thread - the scheme
// handler runs on the IO thread - is marshalled back before it reaches Lua.

#ifndef NEUTRINO_API_H
#define NEUTRINO_API_H

#include <stdint.h>

#define NEUTRINO_API extern "C" __declspec(dllexport)

// --- Callbacks --------------------------------------------------------------

// JS called window.neutrino.invoke(channel, args).
//
// Return the JSON reply to answer immediately; the returned string is read by
// C++ before the call returns, so Lua must anchor it. Return NULL to answer
// later, then call neutrino_invoke_resolve/reject with |request_id|. Deferring
// is what lets a handler await IO without stalling the message pump.
typedef const char* (*neutrino_invoke_fn)(int window_id,
                                          int request_id,
                                          const char* channel,
                                          const char* args,
                                          void* user);

// Generic window event. |json| is a JSON object carrying the event details, or
// "{}". Routing every CEF handler through one callback means adding a handler
// later costs an event name, not an ABI change.
typedef void (*neutrino_event_fn)(int window_id,
                                  const char* event,
                                  const char* json,
                                  void* user);

// A neutrino:// request.
//
// Lua answers with neutrino_response_set(response_id, ...), either before
// returning or at any point afterwards. C++ copies every buffer, so Lua never
// owns C memory, and a request left unanswered simply stays open - which is how
// a route awaits a file read without blocking the loop.
typedef void (*neutrino_request_fn)(int window_id,
                                    int response_id,
                                    const char* method,
                                    const char* url,
                                    const char* headers_json,
                                    const char* body,
                                    int body_len,
                                    void* user);

// Return 0 to veto a close request, 1 to allow it.
typedef int (*neutrino_can_close_fn)(int window_id, void* user);

// Result of neutrino_window_eval(). |json| is the JSON-encoded value, or the
// error message when ok == 0.
typedef void (*neutrino_eval_fn)(int window_id,
                                 int request_id,
                                 int ok,
                                 const char* json,
                                 void* user);

// A timer started with neutrino_timer_start() has come due.
typedef void (*neutrino_timer_fn)(int timer_id, void* user);

// The page asked for a context menu. |params_json| describes what was clicked.
//
// Return a JSON array of menu items to show, "[]" or NULL to show nothing.
// Showing nothing is the useful default for an application: Chromium's own menu
// offers Back, Reload and View Source, which rarely belong in a tool.
//
// Items are objects: {"id","label","enabled","checked","type","items"} where
// type is "normal" (default), "separator" or "checkbox", and "items" makes a
// submenu. The id comes back through the "context-menu-command" event.
typedef const char* (*neutrino_context_menu_fn)(int window_id,
                                                const char* params_json,
                                                void* user);

// A key event, before the page sees it. Return 1 to consume it, which is how an
// accelerator blocks a browser shortcut such as F12 or Ctrl+R.
typedef int (*neutrino_key_fn)(int window_id,
                              const char* event_json,
                              void* user);

// A resource request is about to load. |request_json| carries the url, method,
// referrer, resource type and headers.
//
// Return a JSON decision, or NULL for no opinion:
//   {"action":"continue"}                      let it through
//   {"action":"cancel"}                        block it
//   {"action":"redirect","url":"..."}          send it elsewhere
//   {"action":"continue","headers":{"K":"V"}}  rewrite request headers,
//                                              a null value removing one
//
// Registering this handler puts every request through a hop to the Lua thread
// and back, so it stays unattached until an application asks for it.
typedef const char* (*neutrino_resource_fn)(int window_id,
                                            const char* request_json,
                                            void* user);

// A file dialog opened with neutrino_window_file_dialog() was dismissed.
// |paths_json| is a JSON array of selected paths, empty when cancelled.
typedef void (*neutrino_file_dialog_fn)(int window_id,
                                        int request_id,
                                        const char* paths_json,
                                        void* user);

// A download is about to start. |info_json| describes it, including the name
// the server suggested.
//
// Return 1 to take charge: the download stays paused until
// neutrino_download_begin() or neutrino_download_cancel() is called, which is
// what lets the destination be chosen after asking the user. Return 0 to let
// CEF prompt for a location itself.
typedef int (*neutrino_download_fn)(int window_id,
                                    int download_id,
                                    const char* info_json,
                                    void* user);

// The page called alert(), confirm() or prompt(), or is asking to unload.
//
// Return 1 to take responsibility for the dialog and answer later through
// neutrino_dialog_respond(). Return 0 to suppress it.
typedef int (*neutrino_dialog_fn)(int window_id,
                                  int dialog_id,
                                  const char* info_json,
                                  void* user);

// The result of a session operation - cookies, cache, credentials.
//
// |json| is the JSON value the operation produced (an array of cookies, a
// count, true) or the error message when ok == 0. Every call answers exactly
// once, including one that failed before it reached CEF, so a caller only ever
// waits on its request id.
typedef void (*neutrino_session_fn)(int request_id,
                                    int ok,
                                    const char* json,
                                    void* user);

// Another copy of the application was started and handed its command line
// over. The running instance is expected to raise its window and act on it.
typedef void (*neutrino_second_instance_fn)(const char* payload, void* user);

// --- Structures -------------------------------------------------------------

struct neutrino_app_options {
  const char* scheme_name;       // custom scheme, defaults to "neutrino"
  const char* cache_path;
  const char* root_cache_path;
  const char* subprocess_path;
  const char* resources_path;
  const char* locales_path;
  const char* log_file;
  const char* user_agent;
  const char* locale;
  int log_severity;              // cef_log_severity_t
  int remote_debugging_port;
  int persist_session_cookies;
  int disable_gpu;
  unsigned char bg_r, bg_g, bg_b;
};

struct neutrino_window_options {
  const char* title;
  const char* url;
  // Partition name, empty for the default context. "persist:name" keeps the
  // cookies and storage on disk, any other name keeps them in memory.
  const char* partition;
  int width, height;
  int x, y;                      // honoured only when centered == 0
  int min_width, min_height;
  int max_width, max_height;
  int frameless;
  int resizable;
  int maximizable;
  int minimizable;
  int centered;
  int show;                      // show the window as soon as it is created
  int always_on_top;
  int show_state;                // 0 normal, 1 minimized, 2 maximized, 3 fullscreen
  int chrome_style;              // 0 = Alloy (default), 1 = Chrome
  unsigned char bg_r, bg_g, bg_b;
};

struct neutrino_rect {
  int x, y, width, height;
};

// --- Lifecycle --------------------------------------------------------------

NEUTRINO_API int  neutrino_init(const neutrino_app_options* opts);

// Runs CEF's message loop and blocks until neutrino_quit(). CEF dispatches the
// Win32 queue itself, so nothing else has to pump anything: this is the mode
// CEF recommends, and it is why the framework has no message loop of its own.
NEUTRINO_API void neutrino_run(void);

// Ends the loop started by neutrino_run(). UI thread only.
NEUTRINO_API void neutrino_quit(void);

NEUTRINO_API void neutrino_shutdown(void);
NEUTRINO_API void neutrino_sleep(int ms);
NEUTRINO_API int  neutrino_window_count(void);

// --- Timers -----------------------------------------------------------------

// Posts a delayed task that fires on the Lua thread. |repeat_ms| of 0 makes the
// timer one-shot. Returns the id passed to the timer callback.
NEUTRINO_API int  neutrino_timer_start(int delay_ms, int repeat_ms);
NEUTRINO_API void neutrino_timer_stop(int timer_id);
NEUTRINO_API const char* neutrino_last_error(void);
NEUTRINO_API const char* neutrino_cef_version(void);

// JSON summary of the paths CEF was actually initialised with. Useful when a
// child process misbehaves: the usual cause is a path CEF silently rejected.
NEUTRINO_API const char* neutrino_config_summary(void);

// --- Callback registration --------------------------------------------------

NEUTRINO_API void neutrino_set_invoke_handler(neutrino_invoke_fn fn, void* user);
NEUTRINO_API void neutrino_set_event_handler(neutrino_event_fn fn, void* user);
NEUTRINO_API void neutrino_set_request_handler(neutrino_request_fn fn, void* user);
NEUTRINO_API void neutrino_set_can_close_handler(neutrino_can_close_fn fn, void* user);
NEUTRINO_API void neutrino_set_eval_handler(neutrino_eval_fn fn, void* user);
NEUTRINO_API void neutrino_set_timer_handler(neutrino_timer_fn fn, void* user);
NEUTRINO_API void neutrino_set_context_menu_handler(neutrino_context_menu_fn fn, void* user);
NEUTRINO_API void neutrino_set_key_handler(neutrino_key_fn fn, void* user);
NEUTRINO_API void neutrino_set_dialog_handler(neutrino_dialog_fn fn, void* user);
NEUTRINO_API void neutrino_set_file_dialog_handler(neutrino_file_dialog_fn fn, void* user);
NEUTRINO_API void neutrino_set_download_handler(neutrino_download_fn fn, void* user);
NEUTRINO_API void neutrino_set_resource_handler(neutrino_resource_fn fn, void* user);
NEUTRINO_API void neutrino_set_session_handler(neutrino_session_fn fn, void* user);
NEUTRINO_API void neutrino_set_second_instance_handler(neutrino_second_instance_fn fn, void* user);

// Answers a dialog whose handler returned 1. |user_input| is the prompt reply.
// Returns 0 when the dialog is gone, which a late answer must tolerate.
NEUTRINO_API int neutrino_dialog_respond(int dialog_id,
                                         int success,
                                         const char* user_input);

// --- Window lifecycle -------------------------------------------------------

NEUTRINO_API int  neutrino_window_create(const neutrino_window_options* opts);
NEUTRINO_API int  neutrino_window_valid(int id);
NEUTRINO_API int  neutrino_window_ready(int id);
NEUTRINO_API void neutrino_window_close(int id, int force);

// --- Navigation -------------------------------------------------------------

NEUTRINO_API void neutrino_window_load_url(int id, const char* url);
NEUTRINO_API void neutrino_window_reload(int id, int ignore_cache);
NEUTRINO_API void neutrino_window_stop(int id);
NEUTRINO_API void neutrino_window_back(int id);
NEUTRINO_API void neutrino_window_forward(int id);
NEUTRINO_API int  neutrino_window_can_back(int id);
NEUTRINO_API int  neutrino_window_can_forward(int id);
NEUTRINO_API const char* neutrino_window_url(int id);
NEUTRINO_API const char* neutrino_window_title(int id);
NEUTRINO_API int  neutrino_window_is_loading(int id);

// --- Script and IPC ---------------------------------------------------------

NEUTRINO_API void neutrino_window_exec_js(int id, const char* code);

// Evaluates |code| in the renderer and reports the JSON-encoded result to the
// eval handler. Returns the request id used to match the reply, or 0.
NEUTRINO_API int  neutrino_window_eval(int id, const char* code);

// Pushes an event to the page; JS receives it via window.neutrino.on(channel).
NEUTRINO_API void neutrino_window_send(int id, const char* channel, const char* payload);

NEUTRINO_API void   neutrino_window_set_zoom(int id, double level);
NEUTRINO_API double neutrino_window_get_zoom(int id);

// --- DevTools ---------------------------------------------------------------

NEUTRINO_API void neutrino_window_open_devtools(int id);
NEUTRINO_API void neutrino_window_close_devtools(int id);
NEUTRINO_API int  neutrino_window_has_devtools(int id);

// --- Window state -----------------------------------------------------------

NEUTRINO_API void neutrino_window_show(int id);
NEUTRINO_API void neutrino_window_hide(int id);
NEUTRINO_API void neutrino_window_minimize(int id);
NEUTRINO_API void neutrino_window_maximize(int id);
NEUTRINO_API void neutrino_window_restore(int id);
NEUTRINO_API void neutrino_window_focus(int id);
NEUTRINO_API void neutrino_window_center(int id);
NEUTRINO_API void neutrino_window_set_title(int id, const char* title);
NEUTRINO_API void neutrino_window_set_fullscreen(int id, int on);
NEUTRINO_API void neutrino_window_set_always_on_top(int id, int on);
NEUTRINO_API int  neutrino_window_is_maximized(int id);
NEUTRINO_API int  neutrino_window_is_minimized(int id);
NEUTRINO_API int  neutrino_window_is_fullscreen(int id);
NEUTRINO_API int  neutrino_window_is_visible(int id);
NEUTRINO_API int  neutrino_window_is_active(int id);

// --- Geometry (density independent pixels) ----------------------------------

NEUTRINO_API void  neutrino_window_set_bounds(int id, const neutrino_rect* bounds);
NEUTRINO_API void  neutrino_window_get_bounds(int id, neutrino_rect* out);
NEUTRINO_API void  neutrino_window_set_min_size(int id, int w, int h);
NEUTRINO_API void  neutrino_window_set_max_size(int id, int w, int h);
NEUTRINO_API void* neutrino_window_handle(int id);   // HWND, for Win32 escape hatches

// Injects a mouse click at page coordinates. |button| is 0 left, 1 middle,
// 2 right. Sends press and release together, which is what a real click is.
// Exists so interaction-driven paths - the context menu above all - can be
// exercised by a test rather than only by a person.
NEUTRINO_API void neutrino_window_click(int id,
                                        int x,
                                        int y,
                                        int button,
                                        int click_count);

// --- File dialogs -----------------------------------------------------------

// Opens the platform file dialog. |mode| is 0 open, 1 open multiple,
// 2 pick folder, 3 save. |filters_json| is a JSON array of accept filters:
// a MIME type, an extension such as ".png", or "Label|.png;.jpg".
// Returns the request id reported to the file dialog handler, or 0.
NEUTRINO_API int neutrino_window_file_dialog(int id,
                                             int mode,
                                             const char* title,
                                             const char* default_path,
                                             const char* filters_json);

// --- Downloads --------------------------------------------------------------

// Starts a download whose handler returned 1. |show_dialog| asks CEF to confirm
// the location with the user. Returns 0 when the download is gone.
NEUTRINO_API int neutrino_download_begin(int download_id,
                                         const char* path,
                                         int show_dialog);

// Cancels a download that has not been started. Returns 0 when it is gone.
NEUTRINO_API int neutrino_download_cancel(int download_id);

// Acts on a running download: 0 cancel, 1 pause, 2 resume.
NEUTRINO_API int neutrino_download_control(int download_id, int action);

// Sets the window and taskbar icon from PNG bytes. Returns 0 if the image could
// not be decoded.
NEUTRINO_API int neutrino_window_set_icon(int id,
                                          const char* png_data,
                                          int png_len);

// --- Displays ---------------------------------------------------------------

NEUTRINO_API int neutrino_display_count(void);
NEUTRINO_API int neutrino_display_info(int index,
                                       neutrino_rect* bounds,
                                       neutrino_rect* work_area,
                                       float* scale_factor,
                                       int* is_primary);

// --- Sessions and cookies ---------------------------------------------------
//
// |partition| names the request context: "" is the default one, "persist:name"
// is kept on disk, any other name lives in memory only. The context is created
// on first use, so a partition needs no separate setup call.
//
// Each of these returns the request id its result is reported under.

// JSON description of a partition: whether it is the default context, whether
// it persists, and where its cache went. Valid until the next call.
NEUTRINO_API const char* neutrino_session_info(const char* partition);

// Enumerates cookies. An empty |url| visits every cookie in the store.
// Answers with a JSON array.
NEUTRINO_API int neutrino_cookies_get(const char* partition,
                                      const char* url,
                                      int include_http_only);

// Writes one cookie, described as a JSON object: "name" and "value" are
// required, "domain", "path", "secure", "httpOnly", "expires" (seconds since
// the Unix epoch), "sameSite" and "priority" are optional. Answers with true,
// or false when Chromium rejected the attributes.
NEUTRINO_API int neutrino_cookies_set(const char* partition,
                                      const char* url,
                                      const char* cookie_json);

// Deletes cookies. An empty |url| clears every host; an empty |name| clears
// every cookie of that host. Answers with the number deleted.
NEUTRINO_API int neutrino_cookies_delete(const char* partition,
                                         const char* url,
                                         const char* name);

// Writes the cookie store to disk. Answers once it is there.
NEUTRINO_API int neutrino_cookies_flush(const char* partition);

NEUTRINO_API int neutrino_session_clear_cache(const char* partition);
NEUTRINO_API int neutrino_session_clear_auth(const char* partition);
NEUTRINO_API int neutrino_session_close_connections(const char* partition);

// Sets the Chrome colour scheme for every browser in the partition. |variant|
// is a cef_color_variant_t: 0 system, 1 light, 2 dark. |argb| of 0 keeps
// Chromium's own accent colour. Chrome runtime style only; returns 0 on
// failure. Synchronous, so it reports nothing through the session callback.
NEUTRINO_API int neutrino_session_set_color_scheme(const char* partition,
                                                   int variant,
                                                   unsigned int argb);

// --- Platform shell ---------------------------------------------------------
//
// Not CEF: the clipboard, the system shell and the single-instance lock. An
// application that cannot copy a string, open a folder or refuse to run twice
// is not a desktop application yet, and none of it comes with Chromium.

// Reads the clipboard as UTF-8. Empty when it holds no text, which is not an
// error. Valid until the next call.
NEUTRINO_API const char* neutrino_clipboard_read(void);

// Replaces the clipboard contents. Returns 0 when another process holds it.
NEUTRINO_API int neutrino_clipboard_write(const char* text);

// Opens a url with the user's default handler. http, https and mailto only:
// ShellExecute on an arbitrary string will run an executable, so anything that
// came from a page must not reach it. Use neutrino_shell_open_path for a file.
NEUTRINO_API int neutrino_shell_open_external(const char* url);

// Opens a file or folder with its registered application. Will run an
// executable if handed one, exactly as a double click would.
NEUTRINO_API int neutrino_shell_open_path(const char* path);

// Opens the containing folder with the item selected.
NEUTRINO_API int neutrino_shell_show_in_folder(const char* path);

// Claims |name| for this process. Returns 1 when this is the only instance, 0
// when another already holds it - in which case the caller is expected to hand
// its arguments over and exit.
NEUTRINO_API int neutrino_single_instance_acquire(const char* name);

// Hands |payload| to the instance holding |name|. Returns 0 when nobody is
// listening, which is a race rather than a bug: the first instance can exit
// between the failed claim and this call.
NEUTRINO_API int neutrino_single_instance_notify(const char* name,
                                                 const char* payload);

// Releases the lock. Called by neutrino_shutdown(), so an application that
// quits normally never needs it.
NEUTRINO_API void neutrino_single_instance_release(void);

// --- Scheme responses -------------------------------------------------------

// Answers a neutrino:// request, from inside the handler or long after it.
// Copies every buffer, so Lua never allocates memory that C++ would free.
// Returns 0 when the request is gone, which a late reply must tolerate.
NEUTRINO_API int neutrino_response_set(int response_id,
                                       int status,
                                       const char* mime,
                                       const char* headers_json,
                                       const char* body,
                                       int body_len);

// --- Deferred IPC replies ---------------------------------------------------

// Resolves an invoke whose handler returned NULL. |json| is handed to the
// promise on the page. Returns 0 when the request is gone.
NEUTRINO_API int neutrino_invoke_resolve(int request_id, const char* json);

// Rejects a deferred invoke, raising an Error in the page's promise.
NEUTRINO_API int neutrino_invoke_reject(int request_id,
                                        int code,
                                        const char* message);

#endif  // NEUTRINO_API_H
