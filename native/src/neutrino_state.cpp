#include "neutrino_state.h"

#include <chrono>

namespace neutrino {

// --- Registry ---------------------------------------------------------------

std::map<int, WindowPtr>& Registry::Map() {
  static std::map<int, WindowPtr> map;
  return map;
}

WindowPtr Registry::Create() {
  static int next_id = 1;
  auto win = std::make_shared<Window>();
  win->id = next_id++;
  Map()[win->id] = win;
  return win;
}

WindowPtr Registry::Get(int id) {
  auto it = Map().find(id);
  return it == Map().end() ? nullptr : it->second;
}

WindowPtr Registry::FromBrowser(CefRefPtr<CefBrowser> browser) {
  return browser ? FromBrowserId(browser->GetIdentifier()) : nullptr;
}

WindowPtr Registry::FromBrowserId(int browser_id) {
  for (auto& entry : Map()) {
    auto& win = entry.second;
    if (win->browser && win->browser->GetIdentifier() == browser_id) {
      return win;
    }
  }
  return nullptr;
}

void Registry::Remove(int id) {
  Map().erase(id);
}

size_t Registry::Count() {
  return Map().size();
}

std::vector<WindowPtr> Registry::All() {
  std::vector<WindowPtr> out;
  out.reserve(Map().size());
  for (auto& entry : Map()) {
    out.push_back(entry.second);
  }
  return out;
}

// --- Callbacks --------------------------------------------------------------

Callbacks& GetCallbacks() {
  static Callbacks callbacks;
  return callbacks;
}

void EmitEvent(int window_id, const char* event, const std::string& json) {
  Callbacks& cb = GetCallbacks();
  if (cb.event) {
    cb.event(window_id, event, json.c_str(), cb.event_user);
  }
}

// --- Global configuration ---------------------------------------------------

static std::string& SchemeStorage() {
  static std::string scheme = "neutrino";
  return scheme;
}

const std::string& SchemeName() {
  return SchemeStorage();
}

void SetSchemeName(const std::string& name) {
  if (!name.empty()) {
    SchemeStorage() = name;
  }
}

std::string NativePath(std::string path) {
#if defined(_WIN32)
  for (char& c : path) {
    if (c == '/') {
      c = '\\';
    }
  }
#endif
  return path;
}

static std::string& RootCacheStorage() {
  static std::string path;
  return path;
}

const std::string& RootCachePath() {
  return RootCacheStorage();
}

void SetRootCachePath(const std::string& path) {
  RootCacheStorage() = path;
}

std::string& LastError() {
  static std::string error;
  return error;
}

// --- Message pump -----------------------------------------------------------

int64_t NowMs() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(steady_clock::now().time_since_epoch())
      .count();
}

}  // namespace neutrino
