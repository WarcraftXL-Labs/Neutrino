#include "scheme_handler.h"

#include <algorithm>
#include <cstring>
#include <map>

#include "neutrino_json.h"
#include "neutrino_state.h"

#include "include/base/cef_callback.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"

using neutrino::JsonObject;
using neutrino::Registry;

namespace {

/// Requests waiting for a Lua reply, keyed by the id handed to Lua.
///
/// UI-thread only, so no lock. Holding a reference here also keeps the handler
/// alive for as long as Lua might answer.
std::map<int, CefRefPtr<NeutrinoResourceHandler>>& PendingResponses() {
  static std::map<int, CefRefPtr<NeutrinoResourceHandler>> pending;
  return pending;
}

int NextResponseId() {
  static int next = 1;
  return next++;
}

/// Encodes the request headers as a flat JSON object for the Lua router.
std::string HeadersToJson(CefRefPtr<CefRequest> request) {
  CefRequest::HeaderMap headers;
  request->GetHeaderMap(headers);

  JsonObject obj;
  for (const auto& entry : headers) {
    obj.Str(entry.first.ToString().c_str(), entry.second.ToString());
  }
  return obj.Build();
}

/// Reads the POST body, if any, preserving binary content.
std::string ReadPostBody(CefRefPtr<CefRequest> request) {
  CefRefPtr<CefPostData> post_data = request->GetPostData();
  if (!post_data) {
    return std::string();
  }

  CefPostData::ElementVector elements;
  post_data->GetElements(elements);

  std::string body;
  for (const auto& element : elements) {
    if (element->GetType() != PDE_TYPE_BYTES) {
      continue;
    }
    const size_t size = element->GetBytesCount();
    if (size == 0) {
      continue;
    }
    const size_t start = body.size();
    body.resize(start + size);
    element->GetBytes(size, &body[start]);
  }
  return body;
}

}  // namespace

bool NeutrinoSetResponse(int response_id,
                         int status,
                         const std::string& mime,
                         const std::string& headers_json,
                         const char* body,
                         int body_len) {
  auto& pending = PendingResponses();
  auto it = pending.find(response_id);
  if (it == pending.end()) {
    return false;
  }

  // Copy the reference: SetResponse may erase the entry as it resumes.
  CefRefPtr<NeutrinoResourceHandler> handler = it->second;
  return handler->SetResponse(status, mime, headers_json, body, body_len);
}

// --- Factory ----------------------------------------------------------------

CefRefPtr<CefResourceHandler> NeutrinoSchemeHandlerFactory::Create(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& scheme_name,
    CefRefPtr<CefRequest> request) {
  // CefBrowser accessors are safe from any thread; the id is turned back into a
  // window on the UI thread, where the registry lives.
  return new NeutrinoResourceHandler(browser ? browser->GetIdentifier() : 0);
}

// --- Handler ----------------------------------------------------------------

bool NeutrinoResourceHandler::Open(CefRefPtr<CefRequest> request,
                                   bool& handle_request,
                                   CefRefPtr<CefCallback> callback) {
  // Everything below runs on the IO thread, so the request has to be copied out
  // before hopping: CefRequest is not valid on the UI thread.
  const std::string method = request->GetMethod().ToString();
  const std::string url = request->GetURL().ToString();
  const std::string headers_json = HeadersToJson(request);
  const std::string body = ReadPostBody(request);

  handle_request = false;  // continue asynchronously
  CefPostTask(TID_UI,
              base::BindOnce(&NeutrinoResourceHandler::DispatchToLua,
                             CefRefPtr<NeutrinoResourceHandler>(this), method,
                             url, headers_json, body, callback));
  return true;
}

void NeutrinoResourceHandler::DispatchToLua(std::string method,
                                            std::string url,
                                            std::string headers_json,
                                            std::string body,
                                            CefRefPtr<CefCallback> callback) {
  if (cancelled_) {
    return;
  }

  neutrino::Callbacks& cb = neutrino::GetCallbacks();
  if (!cb.request) {
    status_ = 503;
    mime_ = "text/plain";
    body_ = "Neutrino: no request handler registered";
    callback->Continue();
    return;
  }

  callback_ = callback;
  response_id_ = NextResponseId();
  PendingResponses()[response_id_] = this;

  // Requests without a browser (service workers, prefetch) report window 0.
  auto win = browser_id_ ? Registry::FromBrowserId(browser_id_) : nullptr;
  const int window_id = win ? win->id : 0;

  dispatching_ = true;
  cb.request(window_id, response_id_, method.c_str(), url.c_str(),
             headers_json.c_str(), body.data(), static_cast<int>(body.size()),
             cb.request_user);
  dispatching_ = false;

  if (responded_) {
    // Answered inline, the common case. Resume now rather than next turn.
    callback_->Continue();
    callback_ = nullptr;
    Forget();
  }
  // Otherwise the route deferred: the request stays open until SetResponse.
}

bool NeutrinoResourceHandler::SetResponse(int status,
                                          const std::string& mime,
                                          const std::string& headers_json,
                                          const char* body,
                                          int body_len) {
  if (responded_ || cancelled_) {
    return false;  // first reply wins; a late one is ignored
  }

  status_ = status > 0 ? status : 200;
  if (!mime.empty()) {
    mime_ = mime;
  }
  headers_json_ = headers_json;

  // Copy: the Lua buffer is only valid for the duration of the call.
  if (body && body_len > 0) {
    body_.assign(body, static_cast<size_t>(body_len));
  } else {
    body_.clear();
  }

  responded_ = true;

  // While dispatching, DispatchToLua resumes the request once Lua returns.
  if (!dispatching_ && callback_) {
    callback_->Continue();
    callback_ = nullptr;
    Forget();
  }
  return true;
}

void NeutrinoResourceHandler::Forget() {
  if (response_id_) {
    PendingResponses().erase(response_id_);
    response_id_ = 0;
  }
}

void NeutrinoResourceHandler::GetResponseHeaders(
    CefRefPtr<CefResponse> response,
    int64_t& response_length,
    CefString& redirectUrl) {
  response->SetStatus(status_);

  // SetMimeType wants a bare type: handing it a full Content-Type such as
  // "text/html; charset=utf-8" makes Chromium fail to recognise it and fall
  // back to text/plain, which renders the page as escaped source. Split the
  // parameters off and pass the charset through its own setter.
  const size_t separator = mime_.find(';');
  if (separator == std::string::npos) {
    response->SetMimeType(mime_);
  } else {
    std::string type = mime_.substr(0, separator);
    while (!type.empty() && type.back() == ' ') {
      type.pop_back();
    }
    response->SetMimeType(type);

    const size_t charset_at = mime_.find("charset=", separator);
    if (charset_at != std::string::npos) {
      std::string charset = mime_.substr(charset_at + 8);
      const size_t end = charset.find(';');
      if (end != std::string::npos) {
        charset = charset.substr(0, end);
      }
      while (!charset.empty() && (charset.front() == ' ' || charset.front() == '"')) {
        charset.erase(charset.begin());
      }
      while (!charset.empty() && (charset.back() == ' ' || charset.back() == '"')) {
        charset.pop_back();
      }
      if (!charset.empty()) {
        response->SetCharset(charset);
      }
    }
  }

  if (!headers_json_.empty()) {
    CefRefPtr<CefValue> parsed = CefParseJSON(headers_json_, JSON_PARSER_RFC);
    if (parsed && parsed->GetType() == VTYPE_DICTIONARY) {
      CefRefPtr<CefDictionaryValue> dict = parsed->GetDictionary();
      CefResponse::HeaderMap header_map;

      CefDictionaryValue::KeyList keys;
      dict->GetKeys(keys);
      for (const auto& key : keys) {
        const std::string name = key.ToString();
        // A Location header only redirects if CEF is told about it here.
        if (_stricmp(name.c_str(), "location") == 0) {
          redirectUrl = dict->GetString(key);
          continue;
        }
        header_map.insert(std::make_pair(key, dict->GetString(key)));
      }
      response->SetHeaderMap(header_map);
    }
  }

  response_length = static_cast<int64_t>(body_.size());
}

bool NeutrinoResourceHandler::Read(void* data_out,
                                   int bytes_to_read,
                                   int& bytes_read,
                                   CefRefPtr<CefResourceReadCallback> callback) {
  bytes_read = 0;

  if (offset_ >= body_.size()) {
    return false;  // complete
  }

  const size_t remaining = body_.size() - offset_;
  const int transfer =
      static_cast<int>(std::min(static_cast<size_t>(bytes_to_read), remaining));
  std::memcpy(data_out, body_.data() + offset_, transfer);
  offset_ += transfer;
  bytes_read = transfer;
  return true;
}

void NeutrinoResourceHandler::Cancel() {
  // Called on the IO thread. Dropping the registry entry has to happen on the
  // UI thread, so hop; a Lua reply arriving in between is discarded by the
  // cancelled_ check in SetResponse.
  cancelled_ = true;
  CefPostTask(TID_UI, base::BindOnce(&NeutrinoResourceHandler::Forget,
                                     CefRefPtr<NeutrinoResourceHandler>(this)));
}
