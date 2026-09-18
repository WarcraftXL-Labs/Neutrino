#include "resource_interceptor.h"

#include <atomic>
#include <map>

#include "neutrino_json.h"
#include "neutrino_state.h"

#include "include/base/cef_callback.h"
#include "include/base/cef_lock.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"

using neutrino::JsonObject;

namespace {

/// Requests waiting on an application decision, keyed by the id handed to Lua.
///
/// Touched from both threads - registered on the IO thread, resolved from the
/// UI thread - so unlike the framework's other registries this one is locked.
std::map<int, CefRefPtr<NeutrinoResourceInterceptor>>& PendingRequests() {
  static std::map<int, CefRefPtr<NeutrinoResourceInterceptor>> pending;
  return pending;
}

base::Lock& PendingLock() {
  static base::Lock lock;
  return lock;
}

int NextRequestId() {
  static std::atomic<int> next{1};
  return next.fetch_add(1);
}

/// Describes a request for the application to judge.
std::string RequestToJson(CefRefPtr<CefRequest> request, int request_id) {
  CefRequest::HeaderMap headers;
  request->GetHeaderMap(headers);

  JsonObject header_obj;
  for (const auto& entry : headers) {
    header_obj.Str(entry.first.ToString().c_str(), entry.second.ToString());
  }

  return JsonObject()
      .Int("requestId", request_id)
      .Str("url", request->GetURL().ToString())
      .Str("method", request->GetMethod().ToString())
      .Str("referrer", request->GetReferrerURL().ToString())
      .Int("resourceType", request->GetResourceType())
      .Int("transitionType", request->GetTransitionType())
      .Raw("headers", header_obj.Build())
      .Build();
}

}  // namespace

bool NeutrinoResolveResourceRequest(int request_id,
                                    const std::string& decision_json) {
  CefRefPtr<NeutrinoResourceInterceptor> interceptor;
  {
    base::AutoLock lock(PendingLock());
    auto& pending = PendingRequests();
    auto it = pending.find(request_id);
    if (it == pending.end()) {
      return false;
    }
    interceptor = it->second;
    pending.erase(it);
  }

  // The request belongs to the IO thread, so the decision is applied there.
  if (CefCurrentlyOn(TID_IO)) {
    return interceptor->Apply(decision_json);
  }

  CefPostTask(TID_IO,
              base::BindOnce(
                  [](CefRefPtr<NeutrinoResourceInterceptor> target,
                     std::string decision) { target->Apply(decision); },
                  interceptor, decision_json));
  return true;
}

CefResourceRequestHandler::ReturnValue
NeutrinoResourceInterceptor::OnBeforeResourceLoad(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    CefRefPtr<CefCallback> callback) {
  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.resource) {
    return RV_CONTINUE;
  }

  request_ = request;
  callback_ = callback;
  request_id_ = NextRequestId();

  {
    base::AutoLock lock(PendingLock());
    PendingRequests()[request_id_] = this;
  }

  const std::string json = RequestToJson(request, request_id_);
  CefPostTask(TID_UI,
              base::BindOnce(&NeutrinoResourceInterceptor::AskApplication,
                             CefRefPtr<NeutrinoResourceInterceptor>(this),
                             request_id_, json));

  // The request is held open until Apply() runs. Every path out of
  // AskApplication resolves it, including a missing or failing handler.
  return RV_CONTINUE_ASYNC;
}

void NeutrinoResourceInterceptor::AskApplication(int request_id,
                                                 std::string request_json) {
  neutrino::Callbacks& cb = neutrino::GetCallbacks();

  const char* decision =
      cb.resource
          ? cb.resource(window_id_, request_json.c_str(), cb.resource_user)
          : nullptr;

  // A handler that answers nothing means "no opinion", not "block".
  NeutrinoResolveResourceRequest(
      request_id, decision ? std::string(decision) : std::string("{}"));
}

bool NeutrinoResourceInterceptor::Apply(const std::string& decision_json) {
  if (settled_ || !callback_) {
    return false;
  }
  settled_ = true;

  CefRefPtr<CefValue> parsed = CefParseJSON(decision_json, JSON_PARSER_RFC);
  CefRefPtr<CefDictionaryValue> decision =
      (parsed && parsed->GetType() == VTYPE_DICTIONARY) ? parsed->GetDictionary()
                                                        : nullptr;

  const std::string action =
      (decision && decision->HasKey("action"))
          ? decision->GetString("action").ToString()
          : "continue";

  if (action == "cancel") {
    callback_->Cancel();
    callback_ = nullptr;
    request_ = nullptr;
    return true;
  }

  if (decision && request_) {
    // Changing the URL is how CEF expresses a redirect.
    if (action == "redirect" && decision->HasKey("url")) {
      const CefString url = decision->GetString("url");
      if (!url.empty()) {
        request_->SetURL(url);
      }
    }

    if (decision->HasKey("headers") &&
        decision->GetType("headers") == VTYPE_DICTIONARY) {
      CefRefPtr<CefDictionaryValue> overrides = decision->GetDictionary("headers");

      CefRequest::HeaderMap headers;
      request_->GetHeaderMap(headers);

      CefDictionaryValue::KeyList names;
      overrides->GetKeys(names);
      for (const auto& name : names) {
        headers.erase(name);
        // A null value removes the header rather than setting it to nothing.
        if (overrides->GetType(name) != VTYPE_NULL) {
          headers.insert(std::make_pair(name, overrides->GetString(name)));
        }
      }
      request_->SetHeaderMap(headers);
    }
  }

  callback_->Continue();
  callback_ = nullptr;
  request_ = nullptr;
  return true;
}

void NeutrinoResourceInterceptor::OnResourceLoadComplete(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefRequest> request,
    CefRefPtr<CefResponse> response,
    CefResourceRequestHandler::URLRequestStatus status,
    int64_t received_content_length) {
  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.event) {
    return;
  }

  const std::string json = JsonObject()
                               .Str("url", request->GetURL().ToString())
                               .Int("status", response ? response->GetStatus() : 0)
                               .Int("urlRequestStatus", status)
                               .Int("bytes", received_content_length)
                               .Build();

  // Emitted from the IO thread, so it has to reach the UI thread first.
  const int window_id = window_id_;
  CefPostTask(TID_UI, base::BindOnce(
                          [](int id, std::string payload) {
                            neutrino::EmitEvent(id, "resource-loaded", payload);
                          },
                          window_id, json));
}
