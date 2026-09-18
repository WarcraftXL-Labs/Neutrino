/// Request interception for every request, not just the custom scheme.
///
/// `CefResourceRequestHandler` runs on the IO thread, so each decision is
/// marshalled to the UI thread and back, exactly as the scheme handler is. That
/// round trip is why the handler is only attached when the application has
/// actually registered an interceptor: `GetResourceRequestHandler` returning
/// null costs nothing, and an application that does not intercept should pay
/// nothing.

#ifndef NEUTRINO_RESOURCE_INTERCEPTOR_H
#define NEUTRINO_RESOURCE_INTERCEPTOR_H

#include <string>

#include "include/cef_resource_request_handler.h"

/// Applies an interception decision to a request that is waiting on the IO
/// thread. |decision_json| is what the application returned:
///   {"action":"continue"}                      let it through
///   {"action":"cancel"}                        block it
///   {"action":"redirect","url":"..."}          send it elsewhere
///   {"action":"continue","headers":{"K":"V"}}  rewrite request headers
/// Returns false when the request is gone, which a late decision must tolerate.
bool NeutrinoResolveResourceRequest(int request_id,
                                    const std::string& decision_json);

/// Intercepts one request. One instance per request, as CEF expects.
class NeutrinoResourceInterceptor : public CefResourceRequestHandler {
 public:
  explicit NeutrinoResourceInterceptor(int window_id) : window_id_(window_id) {}

  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override;

  void OnResourceLoadComplete(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefRequest> request,
                              CefRefPtr<CefResponse> response,
                              URLRequestStatus status,
                              int64_t received_content_length) override;

  /// Applies a decision. Runs on the IO thread, where the request lives.
  bool Apply(const std::string& decision_json);

 private:
  /// Runs on the UI thread: hands the request to Lua.
  void AskApplication(int request_id, std::string request_json);

  const int window_id_;

  CefRefPtr<CefRequest> request_;
  CefRefPtr<CefCallback> callback_;
  int request_id_ = 0;
  bool settled_ = false;

  IMPLEMENT_REFCOUNTING(NeutrinoResourceInterceptor);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoResourceInterceptor);
};

#endif  // NEUTRINO_RESOURCE_INTERCEPTOR_H
