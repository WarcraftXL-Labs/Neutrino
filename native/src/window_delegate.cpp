#include "window_delegate.h"

#include "client.h"
#include "neutrino_json.h"
#include "neutrino_state.h"

#include "include/views/cef_display.h"

using neutrino::JsonObject;
using neutrino::Registry;

// --- NeutrinoWindowDelegate -------------------------------------------------

void NeutrinoWindowDelegate::OnWindowCreated(CefRefPtr<CefWindow> window) {
  auto win = Registry::Get(window_id_);
  if (!win) {
    return;
  }

  win->window = window;
  window->AddChildView(win->browser_view);

  if (win->always_on_top) {
    window->SetAlwaysOnTop(true);
  }

  if (win->show_on_create) {
    window->Show();

    // Show() honours GetInitialShowState on some platforms and not others;
    // applying the state explicitly keeps behaviour identical everywhere.
    switch (win->show_state) {
      case CEF_SHOW_STATE_MAXIMIZED:
        window->Maximize();
        break;
      case CEF_SHOW_STATE_MINIMIZED:
        window->Minimize();
        break;
      case CEF_SHOW_STATE_FULLSCREEN:
        window->SetFullscreen(true);
        break;
      default:
        break;
    }
  }
}

void NeutrinoWindowDelegate::OnWindowDestroyed(CefRefPtr<CefWindow> window) {
  neutrino::EmitEvent(window_id_, "closed");

  // Drops the last references to the window, browser view and client.
  Registry::Remove(window_id_);
}

void NeutrinoWindowDelegate::OnWindowBoundsChanged(CefRefPtr<CefWindow> window,
                                                   const CefRect& new_bounds) {
  neutrino::EmitEvent(window_id_, "bounds-changed",
                      JsonObject().Int("x", new_bounds.x)
                          .Int("y", new_bounds.y)
                          .Int("width", new_bounds.width)
                          .Int("height", new_bounds.height)
                          .Build());
}

void NeutrinoWindowDelegate::OnWindowActivationChanged(
    CefRefPtr<CefWindow> window,
    bool active) {
  neutrino::EmitEvent(window_id_, active ? "activate" : "deactivate");
}

CefRect NeutrinoWindowDelegate::GetInitialBounds(CefRefPtr<CefWindow> window) {
  auto win = Registry::Get(window_id_);
  if (!win) {
    return CefRect();
  }

  CefRect bounds = win->initial_bounds;
  if (bounds.width <= 0 || bounds.height <= 0) {
    return CefRect();  // falls back to GetPreferredSize at origin (0,0)
  }

  if (win->centered) {
    // Work area rather than full bounds, so the window does not slide under the
    // taskbar. These are DIP, so this is correct at any display scale.
    CefRefPtr<CefDisplay> display = CefDisplay::GetPrimaryDisplay();
    if (display) {
      const CefRect area = display->GetWorkArea();
      bounds.x = area.x + (area.width - bounds.width) / 2;
      bounds.y = area.y + (area.height - bounds.height) / 2;
    }
  }

  return bounds;
}

cef_show_state_t NeutrinoWindowDelegate::GetInitialShowState(
    CefRefPtr<CefWindow> window) {
  auto win = Registry::Get(window_id_);
  if (!win) {
    return CEF_SHOW_STATE_NORMAL;
  }
  return win->show_on_create ? win->show_state : CEF_SHOW_STATE_HIDDEN;
}

bool NeutrinoWindowDelegate::IsFrameless(CefRefPtr<CefWindow> window) {
  auto win = Registry::Get(window_id_);
  return win && win->frameless;
}

bool NeutrinoWindowDelegate::CanResize(CefRefPtr<CefWindow> window) {
  auto win = Registry::Get(window_id_);
  return !win || win->resizable;
}

bool NeutrinoWindowDelegate::CanMaximize(CefRefPtr<CefWindow> window) {
  auto win = Registry::Get(window_id_);
  return !win || win->maximizable;
}

bool NeutrinoWindowDelegate::CanMinimize(CefRefPtr<CefWindow> window) {
  auto win = Registry::Get(window_id_);
  return !win || win->minimizable;
}

bool NeutrinoWindowDelegate::CanClose(CefRefPtr<CefWindow> window) {
  auto win = Registry::Get(window_id_);
  if (!win) {
    return true;
  }

  // Ask Lua once per close attempt. CEF calls back into CanClose during the
  // asynchronous handshake below, and re-running the veto there would both
  // surprise the application and risk an unclosable window.
  if (!win->close_confirmed && !win->force_close) {
    neutrino::Callbacks& cb = neutrino::GetCallbacks();
    if (cb.can_close && cb.can_close(window_id_, cb.can_close_user) == 0) {
      return false;
    }
    win->close_confirmed = true;
  }

  // TryCloseBrowser returns false the first time and starts the asynchronous
  // teardown (beforeunload, then OnBeforeClose). CEF then calls CanClose again,
  // and by that point the browser is gone and we report ready.
  if (win->browser) {
    return win->browser->GetHost()->TryCloseBrowser();
  }
  return true;
}

cef_runtime_style_t NeutrinoWindowDelegate::GetWindowRuntimeStyle() {
  auto win = Registry::Get(window_id_);
  // Alloy gives us the client callbacks an app framework needs (draggable
  // regions, context menu and keyboard control) without any Chrome browser UI.
  return (win && win->chrome_style) ? CEF_RUNTIME_STYLE_CHROME
                                    : CEF_RUNTIME_STYLE_ALLOY;
}

CefSize NeutrinoWindowDelegate::GetPreferredSize(CefRefPtr<CefView> view) {
  auto win = Registry::Get(window_id_);
  if (!win || win->initial_bounds.width <= 0) {
    return CefSize();
  }
  return CefSize(win->initial_bounds.width, win->initial_bounds.height);
}

CefSize NeutrinoWindowDelegate::GetMinimumSize(CefRefPtr<CefView> view) {
  auto win = Registry::Get(window_id_);
  return win ? win->min_size : CefSize();
}

CefSize NeutrinoWindowDelegate::GetMaximumSize(CefRefPtr<CefView> view) {
  auto win = Registry::Get(window_id_);
  return win ? win->max_size : CefSize();
}

// --- NeutrinoBrowserViewDelegate --------------------------------------------

void NeutrinoBrowserViewDelegate::OnBrowserCreated(
    CefRefPtr<CefBrowserView> browser_view,
    CefRefPtr<CefBrowser> browser) {
  if (auto win = Registry::Get(window_id_)) {
    win->browser = browser;
    win->browser_view = browser_view;
  }
}

void NeutrinoBrowserViewDelegate::OnBrowserDestroyed(
    CefRefPtr<CefBrowserView> browser_view,
    CefRefPtr<CefBrowser> browser) {
  if (auto win = Registry::Get(window_id_)) {
    win->browser = nullptr;
  }
}

CefRefPtr<CefBrowserViewDelegate>
NeutrinoBrowserViewDelegate::GetDelegateForPopupBrowserView(
    CefRefPtr<CefBrowserView> browser_view,
    const CefBrowserSettings& settings,
    CefRefPtr<CefClient> client,
    bool is_devtools) {
  // DevTools popups arrive with a null client. CEF gives them a default window
  // and we stay out of the way - but the view still needs a delegate that
  // reports Chrome style, because DevTools is not supported under Alloy.
  if (is_devtools) {
    return new NeutrinoBrowserViewDelegate(window_id_, true);
  }
  if (!client) {
    return this;
  }

  // NeutrinoClient::OnBeforePopup already allocated the registry entry and
  // attached this client to it, so the id travels with the client.
  NeutrinoClient* neutrino_client =
      static_cast<NeutrinoClient*>(client.get());
  return new NeutrinoBrowserViewDelegate(neutrino_client->window_id());
}

bool NeutrinoBrowserViewDelegate::OnPopupBrowserViewCreated(
    CefRefPtr<CefBrowserView> browser_view,
    CefRefPtr<CefBrowserView> popup_browser_view,
    bool is_devtools) {
  if (is_devtools) {
    return false;  // let CEF host DevTools in its own default window
  }

  CefRefPtr<CefBrowser> popup_browser = popup_browser_view->GetBrowser();
  auto win = popup_browser ? Registry::FromBrowser(popup_browser) : nullptr;
  if (!win) {
    return false;  // unknown popup: fall back to CEF's default window
  }

  win->browser_view = popup_browser_view;
  CefWindow::CreateTopLevelWindow(new NeutrinoWindowDelegate(win->id));
  return true;  // we took ownership of the view hierarchy
}

cef_runtime_style_t NeutrinoBrowserViewDelegate::GetBrowserRuntimeStyle() {
  // DevTools only runs under Chrome style; asking for Alloy makes CEF log an
  // error and fall back.
  if (for_devtools_) {
    return CEF_RUNTIME_STYLE_CHROME;
  }

  auto win = Registry::Get(window_id_);
  return (win && win->chrome_style) ? CEF_RUNTIME_STYLE_CHROME
                                    : CEF_RUNTIME_STYLE_ALLOY;
}
