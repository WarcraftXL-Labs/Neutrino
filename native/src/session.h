/// Request contexts ("partitions") and the cookie store attached to each.
///
/// A partition is Electron's `session`: an isolated set of cookies, cache and
/// local storage. Windows created with the same partition name share all of it;
/// windows in different partitions share none of it, which is what lets one
/// application hold two logins to the same site at once.
///
/// Everything here runs on the CEF UI thread, which is also the Lua thread.
/// CEF 152 visits cookies on the UI thread and fires the completion callbacks
/// there too, so unlike the scheme handler and the request interceptor this
/// file needs no marshalling at all.
///
/// Every operation is asynchronous and answers exactly once through the session
/// callback, including when it fails before reaching CEF. A caller therefore
/// never has to distinguish "failed immediately" from "failed later": it waits
/// for its request id either way.

#ifndef NEUTRINO_SESSION_H
#define NEUTRINO_SESSION_H

#include <stdint.h>

#include <functional>
#include <string>

#include "include/cef_request_context.h"

namespace neutrino {

/// Resolves a partition name to its request context, creating it on first use.
///
/// The naming follows the convention Electron established, because it is the
/// one an application author already knows:
///   ""               the default context, shared by every window
///   "persist:name"   on disk, under <root cache>/partitions/name
///   "name"           in memory, discarded when the process exits
///
/// Returns null for the default partition: that is what CreateBrowserView wants
/// in order to use the global context.
CefRefPtr<CefRequestContext> GetPartition(const std::string& name);

/// Resolves a partition name to a usable context, the global one for "".
CefRefPtr<CefRequestContext> ContextFor(const std::string& name);

/// JSON description of a partition: whether it is the global one, whether it
/// persists, and the cache directory it ended up with.
std::string PartitionInfo(const std::string& name);

/// Creates the partition's context if it does not exist yet, and reports
/// whether it is ready to have a browser created in it.
///
/// A context returned by CefRequestContext::CreateContext initializes
/// asynchronously, and CefBrowserView::CreateBrowserView refuses one that is
/// still coming up. Without this wait the first window in a partition fails
/// while a second one moments later succeeds - the kind of bug that reads as
/// bad luck rather than as a missing wait. The default partition is always
/// ready, so it answers true straight away.
bool PreparePartition(const std::string& name);

/// Queues |ready| to run once the partition's context is initialized.
/// Call only after PreparePartition() has returned false.
void WhenPartitionReady(const std::string& name, std::function<void()> ready);

// --- Cookies ---------------------------------------------------------------
//
// Each of these returns the request id its result will be reported under.

/// Enumerates cookies, filtered by |url| when it is non-empty. Answers with a
/// JSON array of cookie objects.
int SessionGetCookies(const std::string& partition,
                      const std::string& url,
                      bool include_http_only);

/// Writes one cookie described as JSON: name and value are required, the rest
/// (domain, path, secure, httpOnly, expires, sameSite, priority) optional.
/// Answers with true, or false when Chromium rejected the attributes.
int SessionSetCookie(const std::string& partition,
                     const std::string& url,
                     const std::string& cookie_json);

/// Deletes cookies. An empty |url| clears every host, an empty |name| clears
/// every cookie of that host. Answers with the number deleted.
int SessionDeleteCookies(const std::string& partition,
                         const std::string& url,
                         const std::string& name);

/// Writes the cookie store to disk. Answers with true once it is on disk, which
/// is the only point at which a crash would no longer lose the change.
int SessionFlushCookies(const std::string& partition);

// --- Storage ---------------------------------------------------------------

int SessionClearCache(const std::string& partition);
int SessionClearAuth(const std::string& partition);
int SessionCloseConnections(const std::string& partition);

/// Sets the Chrome color scheme for every browser sharing the partition.
/// |variant| is a cef_color_variant_t; |argb| of 0 keeps Chromium's own colour.
/// Applies to Chrome runtime style only, and is synchronous.
bool SessionSetColorScheme(const std::string& partition,
                           int variant,
                           uint32_t argb);

}  // namespace neutrino

#endif  // NEUTRINO_SESSION_H
