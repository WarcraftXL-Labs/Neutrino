#include "session.h"

#include <atomic>
#include <map>
#include <vector>

#include "neutrino_json.h"
#include "neutrino_state.h"

#include "include/base/cef_callback.h"
#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_task.h"
#include "include/internal/cef_time.h"
#include "include/wrapper/cef_closure_task.h"

namespace neutrino {
namespace {

int NextRequestId() {
  static std::atomic<int> next{1};
  return next.fetch_add(1);
}

/// Hands the result of one session operation to Lua.
///
/// Always posted, never called inline. Some of these results come from a CEF
/// completion callback and one comes from a visitor's destructor; running Lua
/// on either stack would re-enter CEF from inside its own teardown. Posting
/// also gives the caller time to register its resolver before the answer
/// arrives, so an operation that fails before ever reaching CEF is delivered
/// exactly like one that succeeds.
void Deliver(int request_id, bool ok, const std::string& json) {
  CefPostTask(TID_UI, base::BindOnce(
                          [](int id, bool succeeded, std::string payload) {
                            Callbacks& cb = GetCallbacks();
                            if (cb.session) {
                              cb.session(id, succeeded ? 1 : 0, payload.c_str(),
                                         cb.session_user);
                            }
                          },
                          request_id, ok, json));
}

/// Reports a failure, whose payload is the message rather than a value.
void Fail(int request_id, const std::string& message) {
  LastError() = message;
  Deliver(request_id, false, JsonQuote(message));
}

// --- Time -------------------------------------------------------------------

/// Converts a CEF base time to seconds since the Unix epoch.
///
/// cef_basetime_t counts microseconds from the Windows epoch, so the conversion
/// goes through CEF's own helpers rather than a hard-coded offset.
double BaseTimeToUnix(const cef_basetime_t& value) {
  cef_time_t broken = {};
  double seconds = 0;
  if (cef_time_from_basetime(value, &broken) &&
      cef_time_to_doublet(&broken, &seconds)) {
    return seconds;
  }
  return 0;
}

void UnixToBaseTime(double seconds, cef_basetime_t* out) {
  cef_time_t broken = {};
  if (cef_time_from_doublet(seconds, &broken)) {
    cef_time_to_basetime(&broken, out);
  }
}

// --- Cookie attributes ------------------------------------------------------

const char* SameSiteName(cef_cookie_same_site_t value) {
  switch (value) {
    case CEF_COOKIE_SAME_SITE_NO_RESTRICTION: return "none";
    case CEF_COOKIE_SAME_SITE_LAX_MODE:       return "lax";
    case CEF_COOKIE_SAME_SITE_STRICT_MODE:    return "strict";
    default:                                  return "unspecified";
  }
}

cef_cookie_same_site_t SameSiteValue(const std::string& name) {
  if (name == "none") {
    return CEF_COOKIE_SAME_SITE_NO_RESTRICTION;
  }
  if (name == "lax") {
    return CEF_COOKIE_SAME_SITE_LAX_MODE;
  }
  if (name == "strict") {
    return CEF_COOKIE_SAME_SITE_STRICT_MODE;
  }
  return CEF_COOKIE_SAME_SITE_UNSPECIFIED;
}

const char* PriorityName(cef_cookie_priority_t value) {
  switch (value) {
    case CEF_COOKIE_PRIORITY_LOW:  return "low";
    case CEF_COOKIE_PRIORITY_HIGH: return "high";
    default:                       return "medium";
  }
}

cef_cookie_priority_t PriorityValue(const std::string& name) {
  if (name == "low") {
    return CEF_COOKIE_PRIORITY_LOW;
  }
  if (name == "high") {
    return CEF_COOKIE_PRIORITY_HIGH;
  }
  return CEF_COOKIE_PRIORITY_MEDIUM;
}

std::string CookieToJson(const CefCookie& cookie) {
  return JsonObject()
      .Str("name", CefString(&cookie.name).ToString())
      .Str("value", CefString(&cookie.value).ToString())
      .Str("domain", CefString(&cookie.domain).ToString())
      .Str("path", CefString(&cookie.path).ToString())
      .Bool("secure", cookie.secure != 0)
      .Bool("httpOnly", cookie.httponly != 0)
      .Bool("hasExpires", cookie.has_expires != 0)
      .Num("expires", cookie.has_expires ? BaseTimeToUnix(cookie.expires) : 0)
      .Num("creation", BaseTimeToUnix(cookie.creation))
      .Num("lastAccess", BaseTimeToUnix(cookie.last_access))
      .Str("sameSite", SameSiteName(cookie.same_site))
      .Str("priority", PriorityName(cookie.priority))
      .Build();
}

std::string DictString(CefRefPtr<CefDictionaryValue> dict, const char* key) {
  return (dict->HasKey(key) && dict->GetType(key) == VTYPE_STRING)
             ? dict->GetString(key).ToString()
             : std::string();
}

bool DictBool(CefRefPtr<CefDictionaryValue> dict, const char* key) {
  return dict->HasKey(key) && dict->GetType(key) == VTYPE_BOOL &&
         dict->GetBool(key);
}

/// Reads a number that may have arrived as either JSON type.
///
/// Both branches are needed: a whole number such as a Unix timestamp parses as
/// an int, and only an expiry past 2038 - too large for the 32 bits Chromium
/// gives an int - comes back as a double.
double DictNumber(CefRefPtr<CefDictionaryValue> dict, const char* key) {
  if (!dict->HasKey(key)) {
    return 0;
  }
  switch (dict->GetType(key)) {
    case VTYPE_INT:    return static_cast<double>(dict->GetInt(key));
    case VTYPE_DOUBLE: return dict->GetDouble(key);
    default:           return 0;
  }
}

// --- Visitors and completion callbacks --------------------------------------

/// Collects every visited cookie, then reports the lot.
///
/// Completion is reported from the destructor because that is the only signal
/// CEF gives: Visit() is not called at all when nothing matches, so a run that
/// legitimately found no cookies would otherwise never answer.
class CookieCollector : public CefCookieVisitor {
 public:
  explicit CookieCollector(int request_id) : request_id_(request_id) {}

  ~CookieCollector() override {
    if (delivered_) {
      return;
    }
    delivered_ = true;
    Deliver(request_id_, true, "[" + body_ + "]");
  }

  bool Visit(const CefCookie& cookie,
             int count,
             int total,
             bool& deleteCookie) override {
    if (!body_.empty()) {
      body_ += ",";
    }
    body_ += CookieToJson(cookie);
    return true;
  }

  /// Reports a failure instead of a result, for a visit that never started.
  /// Disarms the destructor, so the caller must still hold a reference when it
  /// calls this - otherwise CEF has already turned the failure into an empty
  /// result that looks like success.
  void Abort(const std::string& message) {
    if (delivered_) {
      return;
    }
    delivered_ = true;
    Fail(request_id_, message);
  }

 private:
  const int request_id_;
  std::string body_;
  bool delivered_ = false;

  IMPLEMENT_REFCOUNTING(CookieCollector);
  DISALLOW_COPY_AND_ASSIGN(CookieCollector);
};

class SetCookieCallback : public CefSetCookieCallback {
 public:
  explicit SetCookieCallback(int request_id) : request_id_(request_id) {}

  void OnComplete(bool success) override {
    // A refused cookie is a failure with a reason, not the value false: the
    // caller should be able to print what went wrong rather than infer it.
    if (success) {
      Deliver(request_id_, true, "true");
    } else {
      Fail(request_id_,
           "Chromium refused the cookie: check the url, the domain and the "
           "characters in the value");
    }
  }

 private:
  const int request_id_;

  IMPLEMENT_REFCOUNTING(SetCookieCallback);
  DISALLOW_COPY_AND_ASSIGN(SetCookieCallback);
};

class DeleteCookiesCallback : public CefDeleteCookiesCallback {
 public:
  explicit DeleteCookiesCallback(int request_id) : request_id_(request_id) {}

  void OnComplete(int num_deleted) override {
    Deliver(request_id_, true, std::to_string(num_deleted));
  }

 private:
  const int request_id_;

  IMPLEMENT_REFCOUNTING(DeleteCookiesCallback);
  DISALLOW_COPY_AND_ASSIGN(DeleteCookiesCallback);
};

/// Answers true once whatever it was attached to has finished.
class DoneCallback : public CefCompletionCallback {
 public:
  explicit DoneCallback(int request_id) : request_id_(request_id) {}

  void OnComplete() override { Deliver(request_id_, true, "true"); }

 private:
  const int request_id_;

  IMPLEMENT_REFCOUNTING(DoneCallback);
  DISALLOW_COPY_AND_ASSIGN(DoneCallback);
};

// --- Partitions -------------------------------------------------------------

std::map<std::string, CefRefPtr<CefRequestContext>>& Partitions() {
  static std::map<std::string, CefRefPtr<CefRequestContext>> partitions;
  return partitions;
}

/// Partitions whose context has finished initializing.
std::map<std::string, bool>& PartitionsReady() {
  static std::map<std::string, bool> ready;
  return ready;
}

/// Work parked until a partition's context comes up.
std::map<std::string, std::vector<std::function<void()>>>& PartitionWaiters() {
  static std::map<std::string, std::vector<std::function<void()>>> waiters;
  return waiters;
}

/// Marks a partition ready and runs whatever was waiting on it.
///
/// The queue is moved out before it is drained: a waiter is free to create
/// another window in the same partition, which would otherwise append to the
/// vector being iterated.
void MarkPartitionReady(const std::string& name) {
  PartitionsReady()[name] = true;

  auto& waiters = PartitionWaiters();
  auto it = waiters.find(name);
  if (it == waiters.end()) {
    return;
  }

  std::vector<std::function<void()>> pending = std::move(it->second);
  waiters.erase(it);
  for (auto& ready : pending) {
    ready();
  }
}

/// Reports a partition's context as usable once CEF says it is.
class NeutrinoContextHandler : public CefRequestContextHandler {
 public:
  explicit NeutrinoContextHandler(const std::string& name) : name_(name) {}

  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> request_context) override {
    MarkPartitionReady(name_);
  }

 private:
  const std::string name_;

  IMPLEMENT_REFCOUNTING(NeutrinoContextHandler);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoContextHandler);
};

/// Reduces a partition name to something usable as a directory name.
std::string SanitizeName(const std::string& name) {
  std::string out;
  out.reserve(name.size());
  for (char c : name) {
    const bool safe = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                      (c >= '0' && c <= '9') || c == '-' || c == '_';
    out.push_back(safe ? c : '_');
  }
  return out.empty() ? std::string("default") : out;
}

CefRefPtr<CefCookieManager> ManagerFor(const std::string& partition) {
  CefRefPtr<CefRequestContext> context = ContextFor(partition);
  return context ? context->GetCookieManager(nullptr) : nullptr;
}

}  // namespace

CefRefPtr<CefRequestContext> GetPartition(const std::string& name) {
  if (name.empty()) {
    return nullptr;
  }

  auto& partitions = Partitions();
  auto it = partitions.find(name);
  if (it != partitions.end()) {
    return it->second;
  }

  CefRequestContextSettings settings;

  if (name.compare(0, 8, "persist:") == 0) {
    const std::string& root = RootCachePath();
    if (root.empty()) {
      // Nothing to persist into. The context is still created, in memory, so
      // the application keeps its isolation and loses only the durability.
      LastError() = "partition '" + name +
                    "' cannot persist: the app has no cache_path or "
                    "root_cache_path to put it under";
    } else {
      // A direct child of the root, not a nested "partitions/name": Chromium
      // creates a profile only in an immediate subdirectory of its user data
      // directory, and refuses a grandchild. The prefix keeps a partition from
      // colliding with a directory Chromium keeps there itself.
      CefString(&settings.cache_path)
          .FromString(NativePath(root + "/partition-" +
                                 SanitizeName(name.substr(8))));
    }
  }

  CefRefPtr<CefRequestContext> context =
      CefRequestContext::CreateContext(settings, new NeutrinoContextHandler(name));
  if (!context) {
    LastError() = "CefRequestContext::CreateContext failed for '" + name + "'";
    return nullptr;
  }

  partitions[name] = context;
  PartitionsReady()[name] = false;
  return context;
}

bool PreparePartition(const std::string& name) {
  // The global context is up before any of this can be reached.
  if (name.empty()) {
    return true;
  }
  if (!GetPartition(name)) {
    // Creation failed outright; treating it as ready lets the caller fail now
    // with a message rather than wait for an event that will never come.
    return true;
  }
  return PartitionsReady()[name];
}

void WhenPartitionReady(const std::string& name, std::function<void()> ready) {
  if (PreparePartition(name)) {
    ready();
    return;
  }
  PartitionWaiters()[name].push_back(std::move(ready));
}

CefRefPtr<CefRequestContext> ContextFor(const std::string& name) {
  if (name.empty()) {
    return CefRequestContext::GetGlobalContext();
  }
  return GetPartition(name);
}

std::string PartitionInfo(const std::string& name) {
  CefRefPtr<CefRequestContext> context = ContextFor(name);
  if (!context) {
    return "{}";
  }

  const std::string cache_path = context->GetCachePath().ToString();
  return JsonObject()
      .Str("partition", name)
      .Bool("global", context->IsGlobal())
      .Bool("persistent", !cache_path.empty())
      .Str("cachePath", cache_path)
      .Build();
}

// --- Cookies ----------------------------------------------------------------

int SessionGetCookies(const std::string& partition,
                      const std::string& url,
                      bool include_http_only) {
  const int request_id = NextRequestId();

  CefRefPtr<CefCookieManager> manager = ManagerFor(partition);
  if (!manager) {
    Fail(request_id, "no cookie manager for partition '" + partition + "'");
    return request_id;
  }

  // The local reference is what makes Abort() possible: without it CEF would
  // already have dropped the visitor, and its destructor would have reported
  // the empty result as a success.
  CefRefPtr<CookieCollector> collector = new CookieCollector(request_id);

  const bool started =
      url.empty()
          ? manager->VisitAllCookies(collector)
          : manager->VisitUrlCookies(url, include_http_only, collector);

  if (!started) {
    collector->Abort("cookies could not be read");
  }
  return request_id;
}

int SessionSetCookie(const std::string& partition,
                     const std::string& url,
                     const std::string& cookie_json) {
  const int request_id = NextRequestId();

  CefRefPtr<CefCookieManager> manager = ManagerFor(partition);
  if (!manager) {
    Fail(request_id, "no cookie manager for partition '" + partition + "'");
    return request_id;
  }

  CefRefPtr<CefValue> parsed = CefParseJSON(cookie_json, JSON_PARSER_RFC);
  if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) {
    Fail(request_id, "a cookie must be a JSON object");
    return request_id;
  }
  CefRefPtr<CefDictionaryValue> dict = parsed->GetDictionary();

  CefCookie cookie;
  CefString(&cookie.name).FromString(DictString(dict, "name"));
  CefString(&cookie.value).FromString(DictString(dict, "value"));
  CefString(&cookie.domain).FromString(DictString(dict, "domain"));
  CefString(&cookie.path).FromString(DictString(dict, "path"));
  cookie.secure = DictBool(dict, "secure") ? 1 : 0;
  cookie.httponly = DictBool(dict, "httpOnly") ? 1 : 0;
  cookie.same_site = SameSiteValue(DictString(dict, "sameSite"));
  cookie.priority = PriorityValue(DictString(dict, "priority"));

  // An absent or zero expiry makes a session cookie, which is what a browser
  // does with a Set-Cookie header that carries no Expires attribute.
  const double expires = DictNumber(dict, "expires");
  if (expires > 0) {
    cookie.has_expires = 1;
    UnixToBaseTime(expires, &cookie.expires);
  }

  if (!manager->SetCookie(url, cookie, new SetCookieCallback(request_id))) {
    Fail(request_id, "cookie rejected: invalid url or unusable cookie store");
  }
  return request_id;
}

int SessionDeleteCookies(const std::string& partition,
                         const std::string& url,
                         const std::string& name) {
  const int request_id = NextRequestId();

  CefRefPtr<CefCookieManager> manager = ManagerFor(partition);
  if (!manager) {
    Fail(request_id, "no cookie manager for partition '" + partition + "'");
    return request_id;
  }

  if (!manager->DeleteCookies(url, name,
                              new DeleteCookiesCallback(request_id))) {
    Fail(request_id, "cookies could not be deleted");
  }
  return request_id;
}

int SessionFlushCookies(const std::string& partition) {
  const int request_id = NextRequestId();

  CefRefPtr<CefCookieManager> manager = ManagerFor(partition);
  if (!manager) {
    Fail(request_id, "no cookie manager for partition '" + partition + "'");
    return request_id;
  }

  if (!manager->FlushStore(new DoneCallback(request_id))) {
    Fail(request_id, "cookie store could not be flushed");
  }
  return request_id;
}

// --- Storage ----------------------------------------------------------------

int SessionClearCache(const std::string& partition) {
  const int request_id = NextRequestId();

  CefRefPtr<CefRequestContext> context = ContextFor(partition);
  if (!context) {
    Fail(request_id, "no context for partition '" + partition + "'");
    return request_id;
  }

  context->ClearHttpCache(new DoneCallback(request_id));
  return request_id;
}

int SessionClearAuth(const std::string& partition) {
  const int request_id = NextRequestId();

  CefRefPtr<CefRequestContext> context = ContextFor(partition);
  if (!context) {
    Fail(request_id, "no context for partition '" + partition + "'");
    return request_id;
  }

  context->ClearHttpAuthCredentials(new DoneCallback(request_id));
  return request_id;
}

int SessionCloseConnections(const std::string& partition) {
  const int request_id = NextRequestId();

  CefRefPtr<CefRequestContext> context = ContextFor(partition);
  if (!context) {
    Fail(request_id, "no context for partition '" + partition + "'");
    return request_id;
  }

  context->CloseAllConnections(new DoneCallback(request_id));
  return request_id;
}

bool SessionSetColorScheme(const std::string& partition,
                           int variant,
                           uint32_t argb) {
  CefRefPtr<CefRequestContext> context = ContextFor(partition);
  if (!context) {
    LastError() = "no context for partition '" + partition + "'";
    return false;
  }

  if (variant < 0 || variant >= CEF_COLOR_VARIANT_NUM_VALUES) {
    LastError() = "unknown colour variant";
    return false;
  }

  context->SetChromeColorScheme(static_cast<cef_color_variant_t>(variant),
                                static_cast<cef_color_t>(argb));
  return true;
}

}  // namespace neutrino
