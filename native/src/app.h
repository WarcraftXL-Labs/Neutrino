#ifndef NEUTRINO_APP_H
#define NEUTRINO_APP_H

#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"

/// Browser-process CefApp.
///
/// Owns what has to happen before any window exists: registering the custom
/// scheme and installing its handler factory.
class NeutrinoApp : public CefApp, public CefBrowserProcessHandler {
 public:
  NeutrinoApp();

  // --- CefApp ---
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override;
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override;

  // --- CefBrowserProcessHandler ---
  void OnContextInitialized() override;
  void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) override;

  // Set from neutrino_init(); applied in OnBeforeCommandLineProcessing.
  void set_disable_gpu(bool disable) { disable_gpu_ = disable; }

 private:
  bool disable_gpu_ = false;

  IMPLEMENT_REFCOUNTING(NeutrinoApp);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoApp);
};

#endif  // NEUTRINO_APP_H
