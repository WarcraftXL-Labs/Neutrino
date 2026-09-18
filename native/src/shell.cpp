#include "shell.h"

#include <windows.h>
#include <shlobj.h>
#include <shellapi.h>

#include <string>
#include <vector>

#include "neutrino_json.h"
#include "neutrino_state.h"

namespace neutrino {
namespace {

// --- UTF-8 <-> UTF-16 -------------------------------------------------------
//
// The Win32 calls below are all the W variants. The A variants would go through
// the process code page, which mangles anything outside it - and a WarcraftXL
// tool deals in paths that routinely have accents in them.

std::wstring ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                       static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      &wide[0], size);
  return wide;
}

std::string ToUtf8(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                       static_cast<int>(wide.size()), nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                      &utf8[0], size, nullptr, nullptr);
  return utf8;
}

bool StartsWithNoCase(const std::string& text, const char* prefix) {
  const size_t length = strlen(prefix);
  if (text.size() < length) {
    return false;
  }
  for (size_t i = 0; i < length; ++i) {
    if (tolower(static_cast<unsigned char>(text[i])) !=
        tolower(static_cast<unsigned char>(prefix[i]))) {
      return false;
    }
  }
  return true;
}

// --- Single instance --------------------------------------------------------

HANDLE g_instance_mutex = nullptr;
HWND g_listener = nullptr;
std::wstring g_listener_class;

// Arbitrary, and only ever matched against our own window class, so it does not
// have to be registered with the system.
constexpr ULONG_PTR kSecondInstanceMessage = 0x4E455554;  // 'NEUT'

/// Receives WM_COPYDATA from a second instance.
///
/// Dispatched by CEF's message loop like every other window message, which is
/// the whole reason this can be a plain hidden window rather than a thread with
/// a pump of its own.
LRESULT CALLBACK ListenerProc(HWND hwnd, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  if (message != WM_COPYDATA) {
    return DefWindowProcW(hwnd, message, wparam, lparam);
  }

  const COPYDATASTRUCT* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (!data || data->dwData != kSecondInstanceMessage || !data->lpData) {
    return FALSE;
  }

  // Length-delimited rather than NUL-terminated: the sender's buffer is not
  // ours to trust, and a missing terminator would read past the end.
  const std::string payload(static_cast<const char*>(data->lpData),
                            data->cbData);

  Callbacks& cb = GetCallbacks();
  if (cb.second_instance) {
    cb.second_instance(payload.c_str(), cb.second_instance_user);
  }
  return TRUE;
}

/// Derives the window class and mutex name from the application's own name, so
/// two different Neutrino applications do not lock each other out.
std::wstring ListenerClassFor(const std::string& name) {
  return L"NeutrinoSingleInstance." + ToWide(name);
}

}  // namespace

// --- Clipboard --------------------------------------------------------------

std::string ClipboardReadText() {
  if (!OpenClipboard(nullptr)) {
    LastError() = "the clipboard is held by another process";
    return std::string();
  }

  std::string result;
  if (HANDLE handle = GetClipboardData(CF_UNICODETEXT)) {
    if (const wchar_t* text = static_cast<const wchar_t*>(GlobalLock(handle))) {
      result = ToUtf8(std::wstring(text));
      GlobalUnlock(handle);
    }
  }

  CloseClipboard();
  return result;
}

bool ClipboardWriteText(const std::string& text) {
  if (!OpenClipboard(nullptr)) {
    LastError() = "the clipboard is held by another process";
    return false;
  }

  EmptyClipboard();

  const std::wstring wide = ToWide(text);
  const size_t bytes = (wide.size() + 1) * sizeof(wchar_t);

  // GMEM_MOVEABLE, because the clipboard takes ownership of the handle and
  // frees it itself. Nothing below may free it once SetClipboardData succeeds.
  HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!handle) {
    CloseClipboard();
    LastError() = "could not allocate clipboard memory";
    return false;
  }

  if (void* target = GlobalLock(handle)) {
    memcpy(target, wide.c_str(), bytes);
    GlobalUnlock(handle);
  }

  const bool ok = SetClipboardData(CF_UNICODETEXT, handle) != nullptr;
  if (!ok) {
    GlobalFree(handle);
    LastError() = "SetClipboardData failed";
  }

  CloseClipboard();
  return ok;
}

// --- System shell -----------------------------------------------------------

bool OpenExternal(const std::string& url) {
  if (!StartsWithNoCase(url, "http://") && !StartsWithNoCase(url, "https://") &&
      !StartsWithNoCase(url, "mailto:")) {
    LastError() =
        "open_external accepts http, https and mailto only; use open_path for "
        "a file or folder";
    return false;
  }

  const HINSTANCE result = ShellExecuteW(nullptr, L"open", ToWide(url).c_str(),
                                         nullptr, nullptr, SW_SHOWNORMAL);
  // ShellExecuteW returns a fake HINSTANCE; anything at or below 32 is an error
  // code rather than a handle.
  if (reinterpret_cast<INT_PTR>(result) <= 32) {
    LastError() = "no handler for that url";
    return false;
  }
  return true;
}

bool OpenPath(const std::string& path) {
  if (path.empty()) {
    LastError() = "open_path needs a path";
    return false;
  }

  const HINSTANCE result = ShellExecuteW(nullptr, L"open", ToWide(path).c_str(),
                                         nullptr, nullptr, SW_SHOWNORMAL);
  if (reinterpret_cast<INT_PTR>(result) <= 32) {
    LastError() = "could not open that path";
    return false;
  }
  return true;
}

bool ShowInFolder(const std::string& path) {
  if (path.empty()) {
    LastError() = "show_in_folder needs a path";
    return false;
  }

  PIDLIST_ABSOLUTE item = ILCreateFromPathW(ToWide(path).c_str());
  if (!item) {
    LastError() = "no such path";
    return false;
  }

  // Explorer is a COM server, so the thread has to be in an apartment. The
  // framework does not initialise COM anywhere else, and CEF's own use of it
  // is on its own threads, so it is done and undone here.
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const HRESULT opened = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
  if (SUCCEEDED(com)) {
    CoUninitialize();
  }
  ILFree(item);

  if (FAILED(opened)) {
    LastError() = "Explorer refused to show that path";
    return false;
  }
  return true;
}

// --- Single instance --------------------------------------------------------

bool AcquireSingleInstance(const std::string& name) {
  if (g_instance_mutex) {
    return true;  // already held by this process
  }

  const std::wstring mutex_name = L"Local\\" + ListenerClassFor(name);

  // Created before the check, and deliberately not closed on failure: holding
  // the handle is what keeps the name claimed, and releasing it here would let
  // a third instance believe it is the first.
  g_instance_mutex = CreateMutexW(nullptr, TRUE, mutex_name.c_str());
  if (!g_instance_mutex) {
    LastError() = "could not create the single-instance lock";
    return false;
  }

  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
    return false;
  }

  // This instance owns the name, so it is the one that listens.
  g_listener_class = ListenerClassFor(name);

  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = ListenerProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = g_listener_class.c_str();
  RegisterClassExW(&window_class);

  // HWND_MESSAGE: a message-only window. It has no position, is never painted
  // and never appears in the task bar, but FindWindowEx can still find it.
  g_listener = CreateWindowExW(0, g_listener_class.c_str(), g_listener_class.c_str(),
                               0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                               GetModuleHandleW(nullptr), nullptr);

  if (!g_listener) {
    // The lock still works; only the hand-off of arguments is lost.
    LastError() = "single-instance lock held, but the listener window failed";
  }
  return true;
}

bool NotifyFirstInstance(const std::string& name, const std::string& payload) {
  const std::wstring class_name = ListenerClassFor(name);

  HWND target = FindWindowExW(HWND_MESSAGE, nullptr, class_name.c_str(), nullptr);
  if (!target) {
    LastError() = "no running instance is listening";
    return false;
  }

  COPYDATASTRUCT data = {};
  data.dwData = kSecondInstanceMessage;
  data.cbData = static_cast<DWORD>(payload.size());
  data.lpData = const_cast<char*>(payload.data());

  // Synchronous on purpose: the receiving process copies the buffer during the
  // call, and this one is usually about to exit.
  return SendMessageW(target, WM_COPYDATA, 0,
                      reinterpret_cast<LPARAM>(&data)) != 0;
}

void ReleaseSingleInstance() {
  if (g_listener) {
    DestroyWindow(g_listener);
    g_listener = nullptr;
  }
  if (!g_listener_class.empty()) {
    UnregisterClassW(g_listener_class.c_str(), GetModuleHandleW(nullptr));
    g_listener_class.clear();
  }
  if (g_instance_mutex) {
    ReleaseMutex(g_instance_mutex);
    CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
  }
}

}  // namespace neutrino
