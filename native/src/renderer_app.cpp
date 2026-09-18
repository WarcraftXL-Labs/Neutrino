#include "renderer_app.h"

#include <windows.h>

#include "neutrino_ipc.h"

#include "include/base/cef_logging.h"
#include "include/cef_command_line.h"
#include "include/cef_scheme.h"
#include "include/cef_v8.h"

namespace {

// The window.neutrino bridge, evaluated in every new V8 context.
//
// Evaluated synchronously from OnContextCreated, which puts it in place before
// any page script runs - the guarantee an Electron preload script gives.
const char kBridgeSource[] = R"JS(
(function () {
  var n = window.neutrino = window.neutrino || {};
  var handlers = Object.create(null);

  // Calls a Lua handler and resolves with its reply. Objects are JSON-encoded
  // on the way out; the reply is parsed when it is valid JSON.
  n.invoke = function (channel, payload) {
    var body = (payload === undefined || payload === null)
      ? ''
      : (typeof payload === 'string' ? payload : JSON.stringify(payload));

    return new Promise(function (resolve, reject) {
      window.neutrinoQuery({
        request: channel + '' + body,
        onSuccess: function (response) {
          try { resolve(JSON.parse(response)); }
          catch (e) { resolve(response); }
        },
        onFailure: function (code, message) {
          var err = new Error(message);
          err.code = code;
          reject(err);
        }
      });
    });
  };

  n.on = function (channel, callback) {
    (handlers[channel] || (handlers[channel] = [])).push(callback);
    return n;
  };

  n.off = function (channel, callback) {
    var list = handlers[channel];
    if (list) {
      var i = list.indexOf(callback);
      if (i !== -1) { list.splice(i, 1); }
    }
    return n;
  };

  n.once = function (channel, callback) {
    var wrapper = function (payload) { n.off(channel, wrapper); callback(payload); };
    return n.on(channel, wrapper);
  };

  // Invoked from the Lua side via neutrino_window_send().
  n._emit = function (channel, payload) {
    var list = handlers[channel];
    if (!list) { return; }
    var parsed = payload;
    try { parsed = JSON.parse(payload); } catch (e) { /* plain string */ }
    list.slice().forEach(function (callback) {
      try { callback(parsed); }
      catch (e) { console.error('[neutrino] handler for "' + channel + '" threw', e); }
    });
  };
})();
)JS";

// Enters a V8 context for the duration of a scope.
//
// Most CefV8Value operations - reading globals, calling functions - are only
// valid while their context is entered. Evaluating without entering gets you
// either a null result or, worse, evaluation against whatever context happened
// to be current.
class ScopedContext {
 public:
  explicit ScopedContext(CefRefPtr<CefV8Context> context)
      : context_(context), entered_(context && context->Enter()) {}

  ~ScopedContext() {
    if (entered_) {
      context_->Exit();
    }
  }

  bool entered() const { return entered_; }

  ScopedContext(const ScopedContext&) = delete;
  ScopedContext& operator=(const ScopedContext&) = delete;

 private:
  CefRefPtr<CefV8Context> context_;
  const bool entered_;
};

// Serialises a V8 value with the page's own JSON.stringify, so objects, arrays
// and Dates come back the way the page sees them.
bool StringifyV8(CefRefPtr<CefV8Context> context,
                 CefRefPtr<CefV8Value> value,
                 std::string& out) {
  if (!value || value->IsUndefined() || value->IsNull()) {
    out = "null";
    return true;
  }

  CefRefPtr<CefV8Value> global = context->GetGlobal();
  CefRefPtr<CefV8Value> json = global->GetValue("JSON");
  if (!json || !json->IsObject()) {
    return false;
  }

  CefRefPtr<CefV8Value> stringify = json->GetValue("stringify");
  if (!stringify || !stringify->IsFunction()) {
    return false;
  }

  CefV8ValueList args;
  args.push_back(value);

  // WithContext, because Eval has already returned and we are no longer inside
  // the V8 context; plain ExecuteFunction would just return null here.
  CefRefPtr<CefV8Value> result =
      stringify->ExecuteFunctionWithContext(context, json, args);
  if (!result || !result->IsString()) {
    // stringify yields undefined for functions, symbols and circular values.
    out = "null";
    return true;
  }

  out = result->GetStringValue().ToString();
  return true;
}

}  // namespace

std::string NeutrinoSchemeFromCommandLine() {
  // Parsed from the OS command line rather than read from
  // CefCommandLine::GetGlobalCommandLine(). OnRegisterCustomSchemes runs before
  // CEF has finished initialising the process, and the global command line is
  // not reliably available that early.
  CefRefPtr<CefCommandLine> command_line = CefCommandLine::CreateCommandLine();
  if (!command_line) {
    return "neutrino";
  }

  command_line->InitFromString(::GetCommandLineW());
  if (command_line->HasSwitch("neutrino-scheme")) {
    const std::string value =
        command_line->GetSwitchValue("neutrino-scheme").ToString();
    if (!value.empty()) {
      return value;
    }
  }
  return "neutrino";
}

NeutrinoRendererApp::NeutrinoRendererApp() = default;

void NeutrinoRendererApp::OnRegisterCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar) {
  // Must match the browser-side registration exactly or the renderer will treat
  // neutrino:// as an unknown, opaque-origin scheme.
  const int options = CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
                      CEF_SCHEME_OPTION_CORS_ENABLED |
                      CEF_SCHEME_OPTION_FETCH_ENABLED;

  registrar->AddCustomScheme(NeutrinoSchemeFromCommandLine(), options);
}

void NeutrinoRendererApp::OnWebKitInitialized() {
  renderer_router_ = CefMessageRouterRendererSide::Create(NeutrinoRouterConfig());
}

void NeutrinoRendererApp::OnContextCreated(CefRefPtr<CefBrowser> browser,
                                           CefRefPtr<CefFrame> frame,
                                           CefRefPtr<CefV8Context> context) {
  // Registers window.neutrinoQuery, which the bridge below builds on.
  if (renderer_router_) {
    renderer_router_->OnContextCreated(browser, frame, context);
  }

  ScopedContext scope(context);
  if (!scope.entered()) {
    LOG(ERROR) << "Neutrino bridge injection failed: could not enter context";
    return;
  }

  CefRefPtr<CefV8Value> retval;
  CefRefPtr<CefV8Exception> exception;
  if (!context->Eval(kBridgeSource, frame->GetURL(), 0, retval, exception) &&
      exception) {
    LOG(ERROR) << "Neutrino bridge injection failed: "
               << exception->GetMessage().ToString();
  }
}

void NeutrinoRendererApp::OnContextReleased(CefRefPtr<CefBrowser> browser,
                                            CefRefPtr<CefFrame> frame,
                                            CefRefPtr<CefV8Context> context) {
  if (renderer_router_) {
    renderer_router_->OnContextReleased(browser, frame, context);
  }
}

bool NeutrinoRendererApp::OnProcessMessageReceived(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefProcessId source_process,
    CefRefPtr<CefProcessMessage> message) {
  if (message->GetName() == neutrino_msg::kEvalRequest) {
    HandleEval(frame, message);
    return true;
  }

  if (renderer_router_) {
    return renderer_router_->OnProcessMessageReceived(browser, frame,
                                                      source_process, message);
  }
  return false;
}

void NeutrinoRendererApp::HandleEval(CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefProcessMessage> message) {
  CefRefPtr<CefListValue> args = message->GetArgumentList();
  const int request_id = args->GetInt(0);
  const CefString code = args->GetString(1);

  CefRefPtr<CefProcessMessage> reply =
      CefProcessMessage::Create(neutrino_msg::kEvalResponse);
  CefRefPtr<CefListValue> reply_args = reply->GetArgumentList();
  reply_args->SetInt(0, request_id);

  CefRefPtr<CefV8Context> context = frame->GetV8Context();
  if (!context) {
    reply_args->SetBool(1, false);
    reply_args->SetString(2, "No V8 context for frame");
    frame->SendProcessMessage(PID_BROWSER, reply);
    return;
  }

  ScopedContext scope(context);
  if (!scope.entered()) {
    reply_args->SetBool(1, false);
    reply_args->SetString(2, "Could not enter the frame's V8 context");
    frame->SendProcessMessage(PID_BROWSER, reply);
    return;
  }

  CefRefPtr<CefV8Value> retval;
  CefRefPtr<CefV8Exception> exception;

  if (!context->Eval(code, frame->GetURL(), 0, retval, exception)) {
    reply_args->SetBool(1, false);
    reply_args->SetString(
        2, exception ? exception->GetMessage() : CefString("Evaluation failed"));
  } else {
    std::string json;
    if (StringifyV8(context, retval, json)) {
      reply_args->SetBool(1, true);
      reply_args->SetString(2, json);
    } else {
      reply_args->SetBool(1, false);
      reply_args->SetString(2, "Result could not be serialised to JSON");
    }
  }

  frame->SendProcessMessage(PID_BROWSER, reply);
}
