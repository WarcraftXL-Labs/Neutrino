--- Low-level FFI binding to neutrinocef.dll.
-- Mirrors native/src/neutrino_api.h one declaration at a time; the header is
-- the source of truth, so change it first and reflect it here.
-- @module core.cef

ffi = require "ffi"

ffi.cdef [[
  // ═══════════════════════════════════════════════════════════════════════════
  // CALLBACKS  (all invoked on the Lua thread, which is also the CEF UI thread)
  // ═══════════════════════════════════════════════════════════════════════════

  // Return the JSON reply to answer inline, or NULL to answer later through
  // neutrino_invoke_resolve / neutrino_invoke_reject.
  typedef const char* (*neutrino_invoke_fn)(int window_id, int request_id,
                                            const char* channel,
                                            const char* args, void* user);

  typedef void (*neutrino_event_fn)(int window_id, const char* event,
                                    const char* json, void* user);

  // Answer with neutrino_response_set(response_id, ...), during the call or at
  // any point afterwards.
  typedef void (*neutrino_request_fn)(int window_id, int response_id,
                                      const char* method,
                                      const char* url, const char* headers_json,
                                      const char* body, int body_len,
                                      void* user);

  typedef int (*neutrino_can_close_fn)(int window_id, void* user);

  typedef void (*neutrino_eval_fn)(int window_id, int request_id, int ok,
                                   const char* json, void* user);

  typedef void (*neutrino_timer_fn)(int timer_id, void* user);

  // Returns a JSON array of menu items, or NULL to show no menu at all.
  typedef const char* (*neutrino_context_menu_fn)(int window_id,
                                                  const char* params_json,
                                                  void* user);

  // Returns 1 to consume the key event before the page sees it.
  typedef int (*neutrino_key_fn)(int window_id, const char* event_json,
                                 void* user);

  // Returns 1 to answer later through neutrino_dialog_respond.
  typedef int (*neutrino_dialog_fn)(int window_id, int dialog_id,
                                    const char* info_json, void* user);

  // A file dialog was dismissed. paths_json is a JSON array, empty if cancelled.
  typedef void (*neutrino_file_dialog_fn)(int window_id, int request_id,
                                          const char* paths_json, void* user);

  // Returns a JSON decision for a request, or NULL for no opinion.
  typedef const char* (*neutrino_resource_fn)(int window_id,
                                              const char* request_json,
                                              void* user);

  // Returns 1 to choose the destination through neutrino_download_begin.
  typedef int (*neutrino_download_fn)(int window_id, int download_id,
                                      const char* info_json, void* user);

  // The result of a session operation: json is the value produced, or the
  // error message when ok is 0. Answered exactly once per request id.
  typedef void (*neutrino_session_fn)(int request_id, int ok, const char* json,
                                      void* user);

  // Another copy of the application was started and handed over its arguments.
  typedef void (*neutrino_second_instance_fn)(const char* payload, void* user);

  // ═══════════════════════════════════════════════════════════════════════════
  // STRUCTURES
  // ═══════════════════════════════════════════════════════════════════════════

  typedef struct neutrino_app_options {
    const char* scheme_name;
    const char* cache_path;
    const char* root_cache_path;
    const char* subprocess_path;
    const char* resources_path;
    const char* locales_path;
    const char* log_file;
    const char* user_agent;
    const char* locale;
    int log_severity;
    int remote_debugging_port;
    int persist_session_cookies;
    int disable_gpu;
    unsigned char bg_r, bg_g, bg_b;
  } neutrino_app_options;

  typedef struct neutrino_window_options {
    const char* title;
    const char* url;
    const char* partition;
    int width, height;
    int x, y;
    int min_width, min_height;
    int max_width, max_height;
    int frameless;
    int resizable;
    int maximizable;
    int minimizable;
    int centered;
    int show;
    int always_on_top;
    int show_state;
    int chrome_style;
    unsigned char bg_r, bg_g, bg_b;
  } neutrino_window_options;

  typedef struct neutrino_rect { int x, y, width, height; } neutrino_rect;

  // ═══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════════

  int  neutrino_init(const neutrino_app_options* opts);
  void neutrino_run(void);
  void neutrino_quit(void);
  void neutrino_shutdown(void);
  void neutrino_sleep(int ms);
  int  neutrino_window_count(void);

  int  neutrino_timer_start(int delay_ms, int repeat_ms);
  void neutrino_timer_stop(int timer_id);
  const char* neutrino_last_error(void);
  const char* neutrino_cef_version(void);
  const char* neutrino_config_summary(void);

  // ═══════════════════════════════════════════════════════════════════════════
  // CALLBACK REGISTRATION
  // ═══════════════════════════════════════════════════════════════════════════

  void neutrino_set_invoke_handler(neutrino_invoke_fn fn, void* user);
  void neutrino_set_event_handler(neutrino_event_fn fn, void* user);
  void neutrino_set_request_handler(neutrino_request_fn fn, void* user);
  void neutrino_set_can_close_handler(neutrino_can_close_fn fn, void* user);
  void neutrino_set_eval_handler(neutrino_eval_fn fn, void* user);
  void neutrino_set_timer_handler(neutrino_timer_fn fn, void* user);
  void neutrino_set_context_menu_handler(neutrino_context_menu_fn fn, void* user);
  void neutrino_set_key_handler(neutrino_key_fn fn, void* user);
  void neutrino_set_dialog_handler(neutrino_dialog_fn fn, void* user);

  void neutrino_set_file_dialog_handler(neutrino_file_dialog_fn fn, void* user);
  void neutrino_set_download_handler(neutrino_download_fn fn, void* user);
  void neutrino_set_resource_handler(neutrino_resource_fn fn, void* user);
  void neutrino_set_session_handler(neutrino_session_fn fn, void* user);
  void neutrino_set_second_instance_handler(neutrino_second_instance_fn fn, void* user);

  int neutrino_dialog_respond(int dialog_id, int success, const char* user_input);

  int neutrino_window_file_dialog(int id, int mode, const char* title,
                                  const char* default_path,
                                  const char* filters_json);

  int neutrino_download_begin(int download_id, const char* path, int show_dialog);
  int neutrino_download_cancel(int download_id);
  int neutrino_download_control(int download_id, int action);

  // ═══════════════════════════════════════════════════════════════════════════
  // WINDOW LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════════

  int  neutrino_window_create(const neutrino_window_options* opts);
  int  neutrino_window_valid(int id);
  int  neutrino_window_ready(int id);
  void neutrino_window_close(int id, int force);

  // ═══════════════════════════════════════════════════════════════════════════
  // NAVIGATION
  // ═══════════════════════════════════════════════════════════════════════════

  void neutrino_window_load_url(int id, const char* url);
  void neutrino_window_reload(int id, int ignore_cache);
  void neutrino_window_stop(int id);
  void neutrino_window_back(int id);
  void neutrino_window_forward(int id);
  int  neutrino_window_can_back(int id);
  int  neutrino_window_can_forward(int id);
  const char* neutrino_window_url(int id);
  const char* neutrino_window_title(int id);
  int  neutrino_window_is_loading(int id);

  // ═══════════════════════════════════════════════════════════════════════════
  // SCRIPT & IPC
  // ═══════════════════════════════════════════════════════════════════════════

  void neutrino_window_exec_js(int id, const char* code);
  int  neutrino_window_eval(int id, const char* code);
  void neutrino_window_send(int id, const char* channel, const char* payload);

  void   neutrino_window_set_zoom(int id, double level);
  double neutrino_window_get_zoom(int id);

  // ═══════════════════════════════════════════════════════════════════════════
  // DEVTOOLS
  // ═══════════════════════════════════════════════════════════════════════════

  void neutrino_window_open_devtools(int id);
  void neutrino_window_close_devtools(int id);
  int  neutrino_window_has_devtools(int id);

  // ═══════════════════════════════════════════════════════════════════════════
  // WINDOW STATE
  // ═══════════════════════════════════════════════════════════════════════════

  void neutrino_window_show(int id);
  void neutrino_window_hide(int id);
  void neutrino_window_minimize(int id);
  void neutrino_window_maximize(int id);
  void neutrino_window_restore(int id);
  void neutrino_window_focus(int id);
  void neutrino_window_center(int id);
  void neutrino_window_set_title(int id, const char* title);
  void neutrino_window_set_fullscreen(int id, int on);
  void neutrino_window_set_always_on_top(int id, int on);
  int  neutrino_window_is_maximized(int id);
  int  neutrino_window_is_minimized(int id);
  int  neutrino_window_is_fullscreen(int id);
  int  neutrino_window_is_visible(int id);
  int  neutrino_window_is_active(int id);

  // ═══════════════════════════════════════════════════════════════════════════
  // GEOMETRY  (density independent pixels)
  // ═══════════════════════════════════════════════════════════════════════════

  void  neutrino_window_set_bounds(int id, const neutrino_rect* bounds);
  void  neutrino_window_get_bounds(int id, neutrino_rect* out);
  void  neutrino_window_set_min_size(int id, int w, int h);
  void  neutrino_window_set_max_size(int id, int w, int h);
  void* neutrino_window_handle(int id);
  int   neutrino_window_set_icon(int id, const char* png_data, int png_len);
  void  neutrino_window_click(int id, int x, int y, int button, int click_count);

  // ═══════════════════════════════════════════════════════════════════════════
  // DISPLAYS
  // ═══════════════════════════════════════════════════════════════════════════

  int neutrino_display_count(void);
  int neutrino_display_info(int index, neutrino_rect* bounds,
                            neutrino_rect* work_area, float* scale_factor,
                            int* is_primary);

  // ═══════════════════════════════════════════════════════════════════════════
  // SESSIONS & COOKIES
  // ═══════════════════════════════════════════════════════════════════════════

  const char* neutrino_session_info(const char* partition);

  int neutrino_cookies_get(const char* partition, const char* url,
                           int include_http_only);
  int neutrino_cookies_set(const char* partition, const char* url,
                           const char* cookie_json);
  int neutrino_cookies_delete(const char* partition, const char* url,
                              const char* name);
  int neutrino_cookies_flush(const char* partition);

  int neutrino_session_clear_cache(const char* partition);
  int neutrino_session_clear_auth(const char* partition);
  int neutrino_session_close_connections(const char* partition);
  int neutrino_session_set_color_scheme(const char* partition, int variant,
                                        unsigned int argb);

  // ═══════════════════════════════════════════════════════════════════════════
  // PLATFORM SHELL  (not CEF: Win32)
  // ═══════════════════════════════════════════════════════════════════════════

  const char* neutrino_clipboard_read(void);
  int  neutrino_clipboard_write(const char* text);

  int  neutrino_shell_open_external(const char* url);
  int  neutrino_shell_open_path(const char* path);
  int  neutrino_shell_show_in_folder(const char* path);

  int  neutrino_single_instance_acquire(const char* name);
  int  neutrino_single_instance_notify(const char* name, const char* payload);
  void neutrino_single_instance_release(void);

  // ═══════════════════════════════════════════════════════════════════════════
  // SCHEME RESPONSES
  // ═══════════════════════════════════════════════════════════════════════════

  int neutrino_response_set(int response_id, int status, const char* mime,
                            const char* headers_json, const char* body,
                            int body_len);

  int neutrino_invoke_resolve(int request_id, const char* json);
  int neutrino_invoke_reject(int request_id, int code, const char* message);

  // ═══════════════════════════════════════════════════════════════════════════
  // WINDOWS OS HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  int SetDllDirectoryA(const char* lpPathName);
]]

M = {
  lib: nil
  -- Anything the C side holds a pointer to lives here, out of reach of the
  -- garbage collector: ffi.cast callbacks, and the Lua strings that option
  -- structs point into.
  anchors: { strings: {} }
}

--- Loads neutrinocef.dll from a directory.
-- @param dir (string) Directory holding neutrinocef.dll and the CEF binaries.
-- @param dll_name (string) Optional DLL file name.
-- @return (boolean) True on success, false plus a message otherwise.
M.setup = (dir, dll_name = "neutrinocef.dll") ->
  return true if M.lib

  -- libcef.dll and friends sit next to neutrinocef.dll; without this the
  -- loader only searches the executable directory and the load fails.
  if ffi.os == "Windows"
    ffi.C.SetDllDirectoryA (dir\gsub "/", "\\")

  path = dir .. "/" .. dll_name
  ok, result = pcall ffi.load, path
  unless ok
    return false, "failed to load #{path}: #{tostring result}"

  M.lib = result
  true

--- Keeps a string alive for as long as the C side may dereference it.
-- Assigning a Lua string to a `const char*` field stores a pointer into the
-- string's own buffer, which is only valid while something still references it.
anchor = (value) ->
  return nil unless value
  text = tostring value
  table.insert M.anchors.strings, text
  text

M.anchor = anchor

--- Builds the native application options struct.
M.build_app_options = (opts = {}) ->
  c_opts = ffi.new "neutrino_app_options[1]"

  c_opts[0].scheme_name = anchor opts.scheme
  c_opts[0].cache_path = anchor opts.cache_path
  c_opts[0].root_cache_path = anchor opts.root_cache_path
  c_opts[0].subprocess_path = anchor opts.subprocess_path
  c_opts[0].resources_path = anchor opts.resources_path
  c_opts[0].locales_path = anchor opts.locales_path
  c_opts[0].log_file = anchor opts.log_file
  c_opts[0].user_agent = anchor opts.user_agent
  c_opts[0].locale = anchor opts.locale

  c_opts[0].log_severity = opts.log_severity or 0
  c_opts[0].remote_debugging_port = opts.remote_debugging_port or 0
  c_opts[0].persist_session_cookies = opts.persist_session_cookies and 1 or 0
  c_opts[0].disable_gpu = opts.disable_gpu and 1 or 0

  background = opts.background or { 26, 29, 33 }
  c_opts[0].bg_r, c_opts[0].bg_g, c_opts[0].bg_b = background[1], background[2], background[3]

  c_opts

-- Maps a friendly show state to the native enum.
SHOW_STATES = { normal: 0, minimized: 1, maximized: 2, fullscreen: 3 }

--- Builds the native window options struct.
M.build_window_options = (opts = {}) ->
  c_opts = ffi.new "neutrino_window_options[1]"

  c_opts[0].title = anchor (opts.title or "Neutrino")
  c_opts[0].url = anchor (opts.url or "about:blank")
  c_opts[0].partition = anchor (opts.partition or "")

  c_opts[0].width = opts.width or 1024
  c_opts[0].height = opts.height or 768
  c_opts[0].x = opts.x or 0
  c_opts[0].y = opts.y or 0

  c_opts[0].min_width = opts.min_width or 0
  c_opts[0].min_height = opts.min_height or 0
  c_opts[0].max_width = opts.max_width or 0
  c_opts[0].max_height = opts.max_height or 0

  c_opts[0].frameless = opts.frameless and 1 or 0
  c_opts[0].resizable = opts.resizable == false and 0 or 1
  c_opts[0].maximizable = opts.maximizable == false and 0 or 1
  c_opts[0].minimizable = opts.minimizable == false and 0 or 1

  -- An explicit position wins over centering.
  centered = if opts.centered != nil
    opts.centered
  else
    not (opts.x or opts.y)
  c_opts[0].centered = centered and 1 or 0

  c_opts[0].show = opts.show == false and 0 or 1
  c_opts[0].always_on_top = opts.always_on_top and 1 or 0
  c_opts[0].show_state = SHOW_STATES[opts.show_state or "normal"] or 0
  c_opts[0].chrome_style = opts.chrome_style and 1 or 0

  background = opts.background or { 26, 29, 33 }
  c_opts[0].bg_r, c_opts[0].bg_g, c_opts[0].bg_b = background[1], background[2], background[3]

  c_opts

--- Returns the last native error message.
M.last_error = ->
  return "no library loaded" unless M.lib
  ffi.string M.lib.neutrino_last_error!

--- Returns the CEF and Chromium version string.
M.version = ->
  return "unknown" unless M.lib
  ffi.string M.lib.neutrino_cef_version!

--- Returns the paths CEF was initialised with, as a JSON string.
-- Only meaningful after App:init(). When child processes misbehave, compare
-- these against what you expected: CEF drops values it considers invalid.
M.config_summary = ->
  return "{}" unless M.lib
  ffi.string M.lib.neutrino_config_summary!

M
