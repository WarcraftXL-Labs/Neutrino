#ifndef NEUTRINO_SCHEME_HANDLER_H
#define NEUTRINO_SCHEME_HANDLER_H

#include <string>

#include "include/cef_scheme.h"

/// Creates one handler per neutrino:// request.
class NeutrinoSchemeHandlerFactory : public CefSchemeHandlerFactory {
 public:
  NeutrinoSchemeHandlerFactory() = default;

  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser,
                                       CefRefPtr<CefFrame> frame,
                                       const CefString& scheme_name,
                                       CefRefPtr<CefRequest> request) override;

 private:
  IMPLEMENT_REFCOUNTING(NeutrinoSchemeHandlerFactory);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoSchemeHandlerFactory);
};

/// Serves a single request from a Lua-produced buffer.
///
/// CEF calls this on the IO thread, but Lua may only be touched from the UI
/// thread, so the request is captured here and dispatched with CefPostTask.
///
/// The reply may arrive either during that dispatch or long after it. Holding
/// the CefCallback lets a Lua route await a file read or a worker job without
/// blocking the loop: the request simply stays open until someone answers.
class NeutrinoResourceHandler : public CefResourceHandler {
 public:
  /// |browser_id| resolves to a window id once we are back on the UI thread,
  /// where the registry may be read. Zero when the request has no browser.
  explicit NeutrinoResourceHandler(int browser_id) : browser_id_(browser_id) {}

  // --- CefResourceHandler ---
  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override;
  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirectUrl) override;
  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override;
  void Cancel() override;

  /// Records the reply and resumes the request. Returns false if the request
  /// was already answered or has been cancelled.
  bool SetResponse(int status,
                   const std::string& mime,
                   const std::string& headers_json,
                   const char* body,
                   int body_len);

 private:
  /// Runs on the UI thread.
  void DispatchToLua(std::string method,
                     std::string url,
                     std::string headers_json,
                     std::string body,
                     CefRefPtr<CefCallback> callback);

  /// Drops this request from the pending registry. UI thread.
  void Forget();

  const int browser_id_;

  /// Held between the dispatch and the reply. Non-null means "still open".
  CefRefPtr<CefCallback> callback_;

  /// Id handed to Lua. An integer rather than a pointer so that a reply
  /// arriving after the request died is a lookup miss instead of a dangling
  /// dereference.
  int response_id_ = 0;

  /// True while the Lua handler is on the stack. A reply made there resumes
  /// the request inline, avoiding a needless trip around the loop.
  bool dispatching_ = false;
  bool responded_ = false;
  bool cancelled_ = false;

  std::string body_;
  std::string mime_ = "text/html";
  std::string headers_json_;
  int status_ = 200;
  size_t offset_ = 0;

  IMPLEMENT_REFCOUNTING(NeutrinoResourceHandler);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoResourceHandler);
};

/// Answers a request that Lua deferred. Returns false for an unknown id, which
/// is what a reply to an abandoned request looks like.
bool NeutrinoSetResponse(int response_id,
                         int status,
                         const std::string& mime,
                         const std::string& headers_json,
                         const char* body,
                         int body_len);

#endif  // NEUTRINO_SCHEME_HANDLER_H
