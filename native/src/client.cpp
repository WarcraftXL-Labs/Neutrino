#include "client.h"

#include <iterator>
#include <map>
#include <string>

#include "neutrino_json.h"
#include "resource_interceptor.h"
#include "neutrino_state.h"

#include "include/cef_menu_model.h"
#include "include/cef_parser.h"

#include "include/base/cef_callback.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"

using neutrino::JsonObject;
using neutrino::Registry;

namespace {

// Posted from OnAfterCreated rather than emitted inline. Under the Views
// framework the browser can be created while neutrino_window_create() is still
// on the stack, so emitting directly would deliver "ready" before the Lua
// BrowserWindow finished constructing and registered itself - the event would
// land nowhere. Deferring by one loop turn guarantees a receiver.
void EmitReady(int window_id, int browser_id, std::string url) {
  neutrino::EmitEvent(window_id, "ready",
                      JsonObject().Int("browserId", browser_id)
                          .Str("url", url)
                          .Build());
}

}  // namespace

// --- NeutrinoClient ---------------------------------------------------------

NeutrinoClient::NeutrinoClient(int window_id) : window_id_(window_id) {
  message_router_ = CefMessageRouterBrowserSide::Create(NeutrinoRouterConfig());
  message_router_->AddHandler(new NeutrinoQueryHandler(window_id_), true);
}

NeutrinoClient::~NeutrinoClient() = default;

bool NeutrinoClient::OnProcessMessageReceived(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefProcessId source_process,
    CefRefPtr<CefProcessMessage> message) {
  const std::string name = message->GetName().ToString();

  if (name == neutrino_msg::kEvalResponse) {
    CefRefPtr<CefListValue> args = message->GetArgumentList();
    neutrino::Callbacks& cb = neutrino::GetCallbacks();
    if (cb.eval && args->GetSize() >= 3) {
      cb.eval(window_id_, args->GetInt(0), args->GetBool(1) ? 1 : 0,
              args->GetString(2).ToString().c_str(), cb.eval_user);
    }
    return true;
  }

  return message_router_->OnProcessMessageReceived(browser, frame,
                                                   source_process, message);
}

// --- CefLifeSpanHandler -----------------------------------------------------

void NeutrinoClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  auto win = Registry::Get(window_id_);
  if (!win) {
    return;
  }
  win->browser = browser;
  win->url = browser->GetMainFrame()->GetURL().ToString();

  CefPostTask(TID_UI, base::BindOnce(&EmitReady, window_id_,
                                     browser->GetIdentifier(), win->url));
}

bool NeutrinoClient::DoClose(CefRefPtr<CefBrowser> browser) {
  // Under the Views framework the window delegate drives the close handshake
  // (see NeutrinoWindowDelegate::CanClose), so this must not short-circuit it.
  return false;
}

void NeutrinoClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  message_router_->OnBeforeClose(browser);

  if (auto win = Registry::Get(window_id_)) {
    win->browser = nullptr;
  }
}

bool NeutrinoClient::OnBeforePopup(CefRefPtr<CefBrowser> browser,
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
                                   bool* no_javascript_access) {
  // Register the popup up front so window.open() produces a window the
  // framework owns, rather than an unmanaged Chromium popup that Lua cannot
  // see or control.
  auto parent = Registry::Get(window_id_);
  auto popup = Registry::Create();

  popup->url = target_url.ToString();
  popup->frameless = false;
  popup->centered = true;
  popup->show_on_create = true;
  popup->chrome_style = parent ? parent->chrome_style : false;

  if (popup_features.widthSet && popup_features.width > 0) {
    popup->initial_bounds.width = popup_features.width;
  } else {
    popup->initial_bounds.width = 1024;
  }
  if (popup_features.heightSet && popup_features.height > 0) {
    popup->initial_bounds.height = popup_features.height;
  } else {
    popup->initial_bounds.height = 768;
  }

  popup->client = new NeutrinoClient(popup->id);
  client = popup->client;

  neutrino::EmitEvent(window_id_, "popup",
                      JsonObject().Int("popupWindowId", popup->id)
                          .Str("url", popup->url)
                          .Bool("userGesture", user_gesture)
                          .Build());

  return false;  // allow the popup; the Views delegates will host it
}

// --- CefDisplayHandler ------------------------------------------------------

void NeutrinoClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                   const CefString& title) {
  auto win = Registry::Get(window_id_);
  if (!win) {
    return;
  }
  win->title = title.ToString();

  // The Views window does not pick up the document title on its own.
  if (win->window) {
    win->window->SetTitle(title);
  }

  neutrino::EmitEvent(window_id_, "title-changed",
                      JsonObject().Str("title", win->title).Build());
}

void NeutrinoClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     const CefString& url) {
  if (!frame->IsMain()) {
    return;
  }
  if (auto win = Registry::Get(window_id_)) {
    win->url = url.ToString();
  }
  neutrino::EmitEvent(window_id_, "navigated",
                      JsonObject().Str("url", url.ToString()).Build());
}

bool NeutrinoClient::OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                                      cef_log_severity_t level,
                                      const CefString& message,
                                      const CefString& source,
                                      int line) {
  neutrino::EmitEvent(window_id_, "console",
                      JsonObject().Int("level", level)
                          .Str("message", message.ToString())
                          .Str("source", source.ToString())
                          .Int("line", line)
                          .Build());
  return false;  // keep Chromium's own console output
}

void NeutrinoClient::OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                                            bool fullscreen) {
  // Triggered by content going fullscreen (a video, Element.requestFullscreen).
  // With Alloy style the window has to follow by hand.
  if (auto win = Registry::Get(window_id_)) {
    if (win->window) {
      win->window->SetFullscreen(fullscreen);
    }
  }
  neutrino::EmitEvent(window_id_, "fullscreen",
                      JsonObject().Bool("fullscreen", fullscreen).Build());
}

// --- CefLoadHandler ---------------------------------------------------------

void NeutrinoClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                          bool is_loading,
                                          bool can_go_back,
                                          bool can_go_forward) {
  if (auto win = Registry::Get(window_id_)) {
    win->is_loading = is_loading;
  }
  neutrino::EmitEvent(window_id_,
                      is_loading ? "loading-start" : "loading-end",
                      JsonObject().Bool("canGoBack", can_go_back)
                          .Bool("canGoForward", can_go_forward)
                          .Build());
}

void NeutrinoClient::OnLoadEnd(CefRefPtr<CefBrowser> browser,
                               CefRefPtr<CefFrame> frame,
                               int http_status_code) {
  if (!frame->IsMain()) {
    return;
  }
  neutrino::EmitEvent(window_id_, "did-finish-load",
                      JsonObject().Int("statusCode", http_status_code)
                          .Str("url", frame->GetURL().ToString())
                          .Build());
}

void NeutrinoClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                 CefRefPtr<CefFrame> frame,
                                 cef_errorcode_t error_code,
                                 const CefString& error_text,
                                 const CefString& failed_url) {
  // ERR_ABORTED just means a navigation was superseded; it is not a failure.
  if (error_code == ERR_ABORTED) {
    return;
  }
  neutrino::EmitEvent(window_id_, "load-error",
                      JsonObject().Int("errorCode", error_code)
                          .Str("errorText", error_text.ToString())
                          .Str("url", failed_url.ToString())
                          .Bool("isMainFrame", frame->IsMain())
                          .Build());
}

// --- CefRequestHandler ------------------------------------------------------

bool NeutrinoClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    CefRefPtr<CefRequest> request,
                                    bool user_gesture,
                                    bool is_redirect) {
  // Required so the router drops pending queries from the outgoing document.
  message_router_->OnBeforeBrowse(browser, frame);
  return false;
}

void NeutrinoClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                               cef_termination_status_t status,
                                               int error_code,
                                               const CefString& error_string) {
  message_router_->OnRenderProcessTerminated(browser);

  if (auto win = Registry::Get(window_id_)) {
    win->browser_gone = true;
  }

  neutrino::EmitEvent(window_id_, "render-process-gone",
                      JsonObject().Int("status", status)
                          .Int("errorCode", error_code)
                          .Str("errorText", error_string.ToString())
                          .Build());
}

CefRefPtr<CefResourceRequestHandler> NeutrinoClient::GetResourceRequestHandler(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    bool is_navigation,
    bool is_download,
    const CefString& request_initiator,
    bool& disable_default_handling) {
  // Called on the IO thread for every single resource. Without an interceptor
  // registered there is nothing to ask, and returning null keeps CEF on its
  // default path with no marshalling at all.
  if (!neutrino::GetCallbacks().resource) {
    return nullptr;
  }
  return new NeutrinoResourceInterceptor(window_id_);
}

// --- CefDragHandler ---------------------------------------------------------

void NeutrinoClient::OnDraggableRegionsChanged(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const std::vector<CefDraggableRegion>& regions) {
  if (!frame->IsMain()) {
    return;
  }
  auto win = Registry::Get(window_id_);
  if (win && win->window) {
    win->window->SetDraggableRegions(regions);
  }
}

// --- CefFocusHandler --------------------------------------------------------

void NeutrinoClient::OnGotFocus(CefRefPtr<CefBrowser> browser) {
  neutrino::EmitEvent(window_id_, "focus");
}

// --- NeutrinoQueryHandler ---------------------------------------------------

namespace {

/// An invoke whose handler has not answered yet.
struct PendingInvoke {
  CefRefPtr<CefMessageRouterBrowserSide::Callback> callback;
  int64_t query_id = 0;
};

/// UI-thread only, so no lock. Keyed by the id handed to Lua rather than by the
/// router's query id, so that a reply for a query that has since been cancelled
/// is a lookup miss instead of a use-after-free.
std::map<int, PendingInvoke>& PendingInvokes() {
  static std::map<int, PendingInvoke> pending;
  return pending;
}

int NextInvokeId() {
  static int next = 1;
  return next++;
}

}  // namespace

bool NeutrinoResolveInvoke(int request_id, const std::string& json) {
  auto& pending = PendingInvokes();
  auto it = pending.find(request_id);
  if (it == pending.end()) {
    return false;
  }

  CefRefPtr<CefMessageRouterBrowserSide::Callback> callback = it->second.callback;
  pending.erase(it);
  callback->Success(json);
  return true;
}

bool NeutrinoRejectInvoke(int request_id, int code, const std::string& message) {
  auto& pending = PendingInvokes();
  auto it = pending.find(request_id);
  if (it == pending.end()) {
    return false;
  }

  CefRefPtr<CefMessageRouterBrowserSide::Callback> callback = it->second.callback;
  pending.erase(it);
  callback->Failure(code, message);
  return true;
}

bool NeutrinoQueryHandler::OnQuery(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   int64_t query_id,
                                   const CefString& request,
                                   bool persistent,
                                   CefRefPtr<Callback> callback) {
  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.invoke) {
    callback->Failure(-1, "No Neutrino invoke handler registered");
    return true;
  }

  // Wire format is "channel\x01payload"; \x01 cannot appear in a JSON document,
  // so the split is unambiguous without framing the payload.
  const std::string req = request.ToString();
  const size_t sep = req.find('\x01');
  const std::string channel =
      sep == std::string::npos ? req : req.substr(0, sep);
  const std::string args =
      sep == std::string::npos ? std::string() : req.substr(sep + 1);

  // Registered before the call, because a handler may resolve synchronously
  // from inside it - an awaited value that was already available, for instance.
  const int request_id = NextInvokeId();
  PendingInvokes()[request_id] = PendingInvoke{callback, query_id};

  const char* result = cb.invoke(window_id_, request_id, channel.c_str(),
                                 args.c_str(), cb.invoke_user);

  if (result) {
    // Answered inline. Copy before returning: Lua only guarantees the buffer
    // for the duration of the call.
    NeutrinoResolveInvoke(request_id, std::string(result));
  }
  // A null result means the handler deferred; the query stays open.
  return true;
}

void NeutrinoQueryHandler::OnQueryCanceled(CefRefPtr<CefBrowser> browser,
                                           CefRefPtr<CefFrame> frame,
                                           int64_t query_id) {
  // The page navigated away or the window closed. Drop anything still waiting,
  // so a later reply from Lua finds nothing rather than a dead callback.
  auto& pending = PendingInvokes();
  for (auto it = pending.begin(); it != pending.end();) {
    it = (it->second.query_id == query_id) ? pending.erase(it) : std::next(it);
  }
}

// --- CefContextMenuHandler ---------------------------------------------------

namespace {

/// Fills |model| from a JSON array, recursing into submenus.
/// Returns how many entries were added.
int AddMenuItems(CefRefPtr<CefMenuModel> model,
                 CefRefPtr<CefListValue> items,
                 int& next_command_id,
                 std::map<int, std::string>& commands) {
  int added = 0;

  for (size_t i = 0; i < items->GetSize(); ++i) {
    if (items->GetType(i) != VTYPE_DICTIONARY) {
      continue;
    }
    CefRefPtr<CefDictionaryValue> item = items->GetDictionary(i);

    const std::string type =
        item->HasKey("type") ? item->GetString("type").ToString() : "normal";

    if (type == "separator") {
      model->AddSeparator();
      ++added;
      continue;
    }

    const CefString label = item->GetString("label");
    if (label.empty()) {
      continue;  // an item with no label would render as a blank row
    }

    if (next_command_id >= MENU_ID_USER_LAST) {
      break;  // out of reserved ids; a short menu beats colliding with CEF
    }
    const int command_id = next_command_id++;

    if (item->HasKey("items") && item->GetType("items") == VTYPE_LIST) {
      CefRefPtr<CefMenuModel> submenu = model->AddSubMenu(command_id, label);
      if (submenu) {
        AddMenuItems(submenu, item->GetList("items"), next_command_id, commands);
      }
      ++added;
      continue;
    }

    if (type == "checkbox") {
      model->AddCheckItem(command_id, label);
      if (item->HasKey("checked") && item->GetBool("checked")) {
        model->SetChecked(command_id, true);
      }
    } else {
      model->AddItem(command_id, label);
    }

    if (item->HasKey("enabled") && !item->GetBool("enabled")) {
      model->SetEnabled(command_id, false);
    }
    if (item->HasKey("id")) {
      commands[command_id] = item->GetString("id").ToString();
    }
    ++added;
  }

  return added;
}

/// Describes what was clicked, so the application can decide on a menu.
std::string ContextMenuParamsToJson(CefRefPtr<CefContextMenuParams> params) {
  return JsonObject()
      .Int("x", params->GetXCoord())
      .Int("y", params->GetYCoord())
      .Str("linkUrl", params->GetLinkUrl().ToString())
      .Str("sourceUrl", params->GetSourceUrl().ToString())
      .Str("pageUrl", params->GetPageUrl().ToString())
      .Str("frameUrl", params->GetFrameUrl().ToString())
      .Str("titleText", params->GetTitleText().ToString())
      .Str("selectionText", params->GetSelectionText().ToString())
      .Str("misspelledWord", params->GetMisspelledWord().ToString())
      .Bool("isEditable", params->IsEditable())
      .Int("mediaType", params->GetMediaType())
      .Int("typeFlags", params->GetTypeFlags())
      .Int("editStateFlags", params->GetEditStateFlags())
      .Build();
}

}  // namespace

int NeutrinoClient::BuildMenu(CefRefPtr<CefMenuModel> model,
                              const std::string& items_json,
                              int& next_command_id) {
  CefRefPtr<CefValue> parsed = CefParseJSON(items_json, JSON_PARSER_RFC);
  if (!parsed || parsed->GetType() != VTYPE_LIST) {
    return 0;
  }
  return AddMenuItems(model, parsed->GetList(), next_command_id, menu_commands_);
}

void NeutrinoClient::OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         CefRefPtr<CefContextMenuParams> params,
                                         CefRefPtr<CefMenuModel> model) {
  menu_commands_.clear();

  // Chromium's default menu offers Back, Reload and View Source: a browser's
  // menu, not an application's. Clear it and show only what the application
  // asks for, which by default is nothing at all.
  model->Clear();

  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.context_menu) {
    return;
  }

  const std::string params_json = ContextMenuParamsToJson(params);
  const char* items =
      cb.context_menu(window_id_, params_json.c_str(), cb.context_menu_user);
  if (!items) {
    return;
  }

  int next_command_id = MENU_ID_USER_FIRST;
  BuildMenu(model, std::string(items), next_command_id);
}

bool NeutrinoClient::OnContextMenuCommand(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    int command_id,
    EventFlags event_flags) {
  auto it = menu_commands_.find(command_id);
  if (it == menu_commands_.end()) {
    return false;  // not one of ours; let CEF deal with it
  }

  neutrino::EmitEvent(window_id_, "context-menu-command",
                      JsonObject().Str("id", it->second).Build());
  return true;
}

void NeutrinoClient::OnContextMenuDismissed(CefRefPtr<CefBrowser> browser,
                                            CefRefPtr<CefFrame> frame) {
  menu_commands_.clear();
  neutrino::EmitEvent(window_id_, "context-menu-dismissed");
}

// --- CefKeyboardHandler ------------------------------------------------------

bool NeutrinoClient::OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                                   const CefKeyEvent& event,
                                   CefEventHandle os_event,
                                   bool* is_keyboard_shortcut) {
  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.key) {
    return false;
  }

  const char* type = "keydown";
  switch (event.type) {
    case KEYEVENT_RAWKEYDOWN: type = "rawkeydown"; break;
    case KEYEVENT_KEYDOWN:    type = "keydown";    break;
    case KEYEVENT_KEYUP:      type = "keyup";      break;
    case KEYEVENT_CHAR:       type = "char";       break;
    default: break;
  }

  // Modifier bits are decoded here rather than in Lua, so an accelerator can be
  // expressed without every caller having to know CEF's flag values.
  const std::string json =
      JsonObject()
          .Str("type", type)
          .Int("keyCode", event.windows_key_code)
          .Int("nativeKeyCode", event.native_key_code)
          .Int("modifiers", static_cast<int64_t>(event.modifiers))
          .Bool("ctrl", (event.modifiers & EVENTFLAG_CONTROL_DOWN) != 0)
          .Bool("shift", (event.modifiers & EVENTFLAG_SHIFT_DOWN) != 0)
          .Bool("alt", (event.modifiers & EVENTFLAG_ALT_DOWN) != 0)
          .Bool("meta", (event.modifiers & EVENTFLAG_COMMAND_DOWN) != 0)
          .Int("character", static_cast<int64_t>(event.character))
          .Bool("isSystemKey", event.is_system_key != 0)
          .Bool("inEditable", event.focus_on_editable_field != 0)
          .Build();

  return cb.key(window_id_, json.c_str(), cb.key_user) == 1;
}

// --- CefJSDialogHandler ------------------------------------------------------

namespace {

/// Dialogs the application said it would answer. UI-thread only.
std::map<int, CefRefPtr<CefJSDialogCallback>>& PendingDialogs() {
  static std::map<int, CefRefPtr<CefJSDialogCallback>> pending;
  return pending;
}

int NextDialogId() {
  static int next = 1;
  return next++;
}

}  // namespace

bool NeutrinoRespondToDialog(int dialog_id,
                             bool success,
                             const std::string& user_input) {
  auto& pending = PendingDialogs();
  auto it = pending.find(dialog_id);
  if (it == pending.end()) {
    return false;
  }

  CefRefPtr<CefJSDialogCallback> callback = it->second;
  pending.erase(it);
  callback->Continue(success, user_input);
  return true;
}

bool NeutrinoClient::OnJSDialog(CefRefPtr<CefBrowser> browser,
                                const CefString& origin_url,
                                cef_jsdialog_type_t dialog_type,
                                const CefString& message_text,
                                const CefString& default_prompt_text,
                                CefRefPtr<CefJSDialogCallback> callback,
                                bool& suppress_message) {
  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.dialog) {
    // Alloy style ships no dialog implementation, so falling through would
    // leave alert() hanging the page forever. Suppressing is the safe default.
    suppress_message = true;
    return false;
  }

  const char* kind = "alert";
  switch (dialog_type) {
    case JSDIALOGTYPE_ALERT:   kind = "alert";   break;
    case JSDIALOGTYPE_CONFIRM: kind = "confirm"; break;
    case JSDIALOGTYPE_PROMPT:  kind = "prompt";  break;
    default: break;
  }

  const int dialog_id = NextDialogId();
  PendingDialogs()[dialog_id] = callback;

  const std::string json =
      JsonObject()
          .Str("type", kind)
          .Str("message", message_text.ToString())
          .Str("defaultText", default_prompt_text.ToString())
          .Str("url", origin_url.ToString())
          .Build();

  if (cb.dialog(window_id_, dialog_id, json.c_str(), cb.dialog_user) == 1) {
    return true;  // answered later through neutrino_dialog_respond
  }

  PendingDialogs().erase(dialog_id);
  suppress_message = true;
  return false;
}

bool NeutrinoClient::OnBeforeUnloadDialog(
    CefRefPtr<CefBrowser> browser,
    const CefString& message_text,
    bool is_reload,
    CefRefPtr<CefJSDialogCallback> callback) {
  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.dialog) {
    // Let the navigation proceed rather than stalling it behind a dialog that
    // nothing can display.
    callback->Continue(true, CefString());
    return true;
  }

  const int dialog_id = NextDialogId();
  PendingDialogs()[dialog_id] = callback;

  const std::string json = JsonObject()
                               .Str("type", "beforeunload")
                               .Str("message", message_text.ToString())
                               .Bool("isReload", is_reload)
                               .Build();

  if (cb.dialog(window_id_, dialog_id, json.c_str(), cb.dialog_user) == 1) {
    return true;
  }

  PendingDialogs().erase(dialog_id);
  callback->Continue(true, CefString());
  return true;
}

// --- CefDownloadHandler ------------------------------------------------------

namespace {

/// Downloads waiting for the application to choose a destination.
/// Keyed by the download id, which stays stable for the item's lifetime.
std::map<int, CefRefPtr<CefBeforeDownloadCallback>>& PendingDownloads() {
  static std::map<int, CefRefPtr<CefBeforeDownloadCallback>> pending;
  return pending;
}

/// Downloads already running, so they can be paused, resumed or cancelled.
/// Replaced on every progress update, since CEF hands over a fresh callback.
std::map<int, CefRefPtr<CefDownloadItemCallback>>& ActiveDownloads() {
  static std::map<int, CefRefPtr<CefDownloadItemCallback>> active;
  return active;
}

/// Describes a download for the application.
std::string DownloadItemToJson(CefRefPtr<CefDownloadItem> item,
                               const std::string& suggested_name) {
  JsonObject obj;
  obj.Int("id", item->GetId())
      .Str("url", item->GetURL().ToString())
      .Str("originalUrl", item->GetOriginalUrl().ToString())
      .Str("mimeType", item->GetMimeType().ToString())
      .Str("fullPath", item->GetFullPath().ToString())
      .Int("totalBytes", item->GetTotalBytes())
      .Int("receivedBytes", item->GetReceivedBytes())
      .Int("percentComplete", item->GetPercentComplete())
      .Int("currentSpeed", item->GetCurrentSpeed())
      .Bool("inProgress", item->IsInProgress())
      .Bool("complete", item->IsComplete())
      .Bool("canceled", item->IsCanceled())
      .Bool("interrupted", item->IsInterrupted())
      .Bool("paused", item->IsPaused());

  if (!suggested_name.empty()) {
    obj.Str("suggestedName", suggested_name);
  } else {
    obj.Str("suggestedName", item->GetSuggestedFileName().ToString());
  }
  return obj.Build();
}

}  // namespace

bool NeutrinoBeginDownload(int download_id,
                           const std::string& path,
                           bool show_dialog) {
  auto& pending = PendingDownloads();
  auto it = pending.find(download_id);
  if (it == pending.end()) {
    return false;
  }

  CefRefPtr<CefBeforeDownloadCallback> callback = it->second;
  pending.erase(it);
  callback->Continue(path, show_dialog);
  return true;
}

bool NeutrinoCancelPendingDownload(int download_id) {
  auto& pending = PendingDownloads();
  auto it = pending.find(download_id);
  if (it == pending.end()) {
    return false;
  }

  // Dropping the callback without continuing is how a download is refused:
  // CEF abandons it once the callback goes away unused.
  pending.erase(it);
  return true;
}

bool NeutrinoControlDownload(int download_id, int action) {
  auto& active = ActiveDownloads();
  auto it = active.find(download_id);
  if (it == active.end()) {
    return false;
  }

  switch (action) {
    case 1: it->second->Pause();  break;
    case 2: it->second->Resume(); break;
    default: it->second->Cancel(); break;
  }
  return true;
}

bool NeutrinoClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString& suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
  const int download_id = static_cast<int>(download_item->GetId());

  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.download) {
    // No handler: ask the user where to put it, which beats both silently
    // refusing the download and silently writing somewhere they did not pick.
    callback->Continue(CefString(), /*show_dialog=*/true);
    return true;
  }

  // Registered before the call, because the handler may answer synchronously.
  PendingDownloads()[download_id] = callback;

  const std::string info =
      DownloadItemToJson(download_item, suggested_name.ToString());

  if (cb.download(window_id_, download_id, info.c_str(), cb.download_user) == 1) {
    return true;  // the application will call begin or cancel
  }

  // Declined to choose: fall back to prompting, if the handler left it to us.
  auto& pending = PendingDownloads();
  auto it = pending.find(download_id);
  if (it != pending.end()) {
    pending.erase(it);
    callback->Continue(CefString(), /*show_dialog=*/true);
  }
  return true;
}

void NeutrinoClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
  const int download_id = static_cast<int>(download_item->GetId());

  if (download_item->IsInProgress()) {
    ActiveDownloads()[download_id] = callback;
  } else {
    // Finished, cancelled or failed: nothing left to pause or resume.
    ActiveDownloads().erase(download_id);
    PendingDownloads().erase(download_id);
  }

  neutrino::EmitEvent(window_id_, "download-updated",
                      DownloadItemToJson(download_item, std::string()));
}
