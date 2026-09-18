#ifndef NEUTRINO_CLIENT_H
#define NEUTRINO_CLIENT_H

#include <map>
#include <string>

#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_drag_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_request_handler.h"
#include "include/wrapper/cef_message_router.h"

#include "neutrino_ipc.h"

/// Per-window CefClient.
///
/// One instance per managed window, so every CEF callback already knows which
/// window it belongs to without looking anything up. All of these run on the UI
/// thread, which is also the Lua thread, so they may call straight into Lua.
class NeutrinoClient : public CefClient,
                       public CefLifeSpanHandler,
                       public CefDisplayHandler,
                       public CefLoadHandler,
                       public CefRequestHandler,
                       public CefDragHandler,
                       public CefFocusHandler,
                       public CefContextMenuHandler,
                       public CefKeyboardHandler,
                       public CefJSDialogHandler,
                       public CefDownloadHandler {
 public:
  explicit NeutrinoClient(int window_id);
  ~NeutrinoClient() override;

  int window_id() const { return window_id_; }

  // --- CefClient ---
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDragHandler> GetDragHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

  // --- CefLifeSpanHandler ---
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     cef_window_open_disposition_t target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popup_features,
                     CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;

  // --- CefDisplayHandler ---
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override;
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                              bool fullscreen) override;

  // --- CefLoadHandler ---
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool is_loading,
                            bool can_go_back,
                            bool can_go_forward) override;
  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int http_status_code) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   cef_errorcode_t error_code,
                   const CefString& error_text,
                   const CefString& failed_url) override;

  // --- CefRequestHandler ---
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override;
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 cef_termination_status_t status,
                                 int error_code,
                                 const CefString& error_string) override;

  // Attached only when the application registers an interceptor: returning
  // null here is what keeps an uninterested application at zero cost.
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override;

  // --- CefDragHandler ---
  // Feeds `-webkit-app-region: drag` regions to the Views window, which is what
  // makes an HTML title bar draggable on a frameless window.
  void OnDraggableRegionsChanged(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const std::vector<CefDraggableRegion>& regions) override;

  // --- CefFocusHandler ---
  void OnGotFocus(CefRefPtr<CefBrowser> browser) override;

  // --- CefContextMenuHandler ---
  // Replaces Chromium's menu with whatever the application returns, and shows
  // nothing at all when it returns nothing.
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override;
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags event_flags) override;
  void OnContextMenuDismissed(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame) override;

  // --- CefKeyboardHandler ---
  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                     const CefKeyEvent& event,
                     CefEventHandle os_event,
                     bool* is_keyboard_shortcut) override;

  // --- CefJSDialogHandler ---
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString& origin_url,
                  cef_jsdialog_type_t dialog_type,
                  const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppress_message) override;
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override;

  // --- CefDownloadHandler ---
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;

 private:
  /// Fills |model| from a JSON array produced by the application.
  /// Returns the number of items added.
  int BuildMenu(CefRefPtr<CefMenuModel> model,
                const std::string& items_json,
                int& next_command_id);

  const int window_id_;
  CefRefPtr<CefMessageRouterBrowserSide> message_router_;

  /// CEF command id -> the application's own item id, rebuilt for each menu.
  std::map<int, std::string> menu_commands_;

  IMPLEMENT_REFCOUNTING(NeutrinoClient);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoClient);
};

/// Bridges window.neutrino.invoke() to the Lua invoke handler.
///
/// Because the UI thread is the Lua thread, a handler that has its answer ready
/// returns it inline and the promise resolves without a task hop. A handler
/// that needs to wait returns nothing instead, and the query stays open until
/// Lua resolves it by id.
class NeutrinoQueryHandler : public CefMessageRouterBrowserSide::Handler {
 public:
  explicit NeutrinoQueryHandler(int window_id) : window_id_(window_id) {}

  bool OnQuery(CefRefPtr<CefBrowser> browser,
               CefRefPtr<CefFrame> frame,
               int64_t query_id,
               const CefString& request,
               bool persistent,
               CefRefPtr<Callback> callback) override;

  void OnQueryCanceled(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int64_t query_id) override;

 private:
  const int window_id_;
};

/// Resolves an invoke that Lua deferred, with a JSON-encoded value.
/// Returns false for an unknown id: the page navigated away or the window
/// closed while the handler was still working.
bool NeutrinoResolveInvoke(int request_id, const std::string& json);

/// Rejects a deferred invoke, raising an Error in the page's promise.
bool NeutrinoRejectInvoke(int request_id, int code, const std::string& message);

/// Starts or cancels a download the application took charge of.
/// Returns false when the download is no longer pending.
bool NeutrinoBeginDownload(int download_id,
                           const std::string& path,
                           bool show_dialog);
bool NeutrinoCancelPendingDownload(int download_id);

/// Acts on a running download: 0 cancel, 1 pause, 2 resume.
bool NeutrinoControlDownload(int download_id, int action);

/// Answers a JavaScript dialog the application took responsibility for.
/// Returns false for an unknown id: the page navigated away or the window
/// closed while the dialog was still open.
bool NeutrinoRespondToDialog(int dialog_id,
                             bool success,
                             const std::string& user_input);

#endif  // NEUTRINO_CLIENT_H
