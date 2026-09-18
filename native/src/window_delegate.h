#ifndef NEUTRINO_WINDOW_DELEGATE_H
#define NEUTRINO_WINDOW_DELEGATE_H

#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window_delegate.h"

// Views delegate for a managed top-level window.
//
// Bound to a registry id rather than to a CefWindow pointer, so it stays valid
// across the whole window lifetime and never keeps the registry entry alive.
class NeutrinoWindowDelegate : public CefWindowDelegate {
 public:
  explicit NeutrinoWindowDelegate(int window_id) : window_id_(window_id) {}

  // --- CefWindowDelegate ---
  void OnWindowCreated(CefRefPtr<CefWindow> window) override;
  void OnWindowDestroyed(CefRefPtr<CefWindow> window) override;
  void OnWindowBoundsChanged(CefRefPtr<CefWindow> window,
                             const CefRect& new_bounds) override;
  void OnWindowActivationChanged(CefRefPtr<CefWindow> window,
                                 bool active) override;

  CefRect GetInitialBounds(CefRefPtr<CefWindow> window) override;
  cef_show_state_t GetInitialShowState(CefRefPtr<CefWindow> window) override;
  bool IsFrameless(CefRefPtr<CefWindow> window) override;
  bool CanResize(CefRefPtr<CefWindow> window) override;
  bool CanMaximize(CefRefPtr<CefWindow> window) override;
  bool CanMinimize(CefRefPtr<CefWindow> window) override;
  bool CanClose(CefRefPtr<CefWindow> window) override;
  cef_runtime_style_t GetWindowRuntimeStyle() override;

  // --- CefViewDelegate ---
  CefSize GetPreferredSize(CefRefPtr<CefView> view) override;
  CefSize GetMinimumSize(CefRefPtr<CefView> view) override;
  CefSize GetMaximumSize(CefRefPtr<CefView> view) override;

 private:
  const int window_id_;

  IMPLEMENT_REFCOUNTING(NeutrinoWindowDelegate);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoWindowDelegate);
};

// Views delegate for the BrowserView hosted inside a managed window.
//
// Also the place where popups are adopted: a popup gets its own registry entry
// and its own top-level window, so nothing escapes the framework.
class NeutrinoBrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  /// |for_devtools| marks the delegate as belonging to a DevTools popup, which
  /// CEF only supports in Chrome runtime style.
  explicit NeutrinoBrowserViewDelegate(int window_id, bool for_devtools = false)
      : window_id_(window_id), for_devtools_(for_devtools) {}

  void OnBrowserCreated(CefRefPtr<CefBrowserView> browser_view,
                        CefRefPtr<CefBrowser> browser) override;
  void OnBrowserDestroyed(CefRefPtr<CefBrowserView> browser_view,
                          CefRefPtr<CefBrowser> browser) override;

  CefRefPtr<CefBrowserViewDelegate> GetDelegateForPopupBrowserView(
      CefRefPtr<CefBrowserView> browser_view,
      const CefBrowserSettings& settings,
      CefRefPtr<CefClient> client,
      bool is_devtools) override;

  bool OnPopupBrowserViewCreated(CefRefPtr<CefBrowserView> browser_view,
                                 CefRefPtr<CefBrowserView> popup_browser_view,
                                 bool is_devtools) override;

  ChromeToolbarType GetChromeToolbarType(
      CefRefPtr<CefBrowserView> browser_view) override {
    return CEF_CTT_NONE;
  }

  cef_runtime_style_t GetBrowserRuntimeStyle() override;

 private:
  const int window_id_;
  const bool for_devtools_;

  IMPLEMENT_REFCOUNTING(NeutrinoBrowserViewDelegate);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoBrowserViewDelegate);
};

#endif  // NEUTRINO_WINDOW_DELEGATE_H
