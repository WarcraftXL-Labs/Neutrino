#ifndef NEUTRINO_RENDERER_APP_H
#define NEUTRINO_RENDERER_APP_H

#include <string>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/wrapper/cef_message_router.h"

// Renderer-process CefApp, used by neutrinocef_helper.exe.
//
// Responsible for:
//   - registering the same custom scheme as the browser process,
//   - the renderer half of the message router (window.neutrino.invoke),
//   - injecting the window.neutrino bridge into every new V8 context,
//   - evaluating code on behalf of neutrino_window_eval() and returning the
//     JSON-encoded result.
class NeutrinoRendererApp : public CefApp, public CefRenderProcessHandler {
 public:
  NeutrinoRendererApp();

  // --- CefApp ---
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }
  void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override;

  // --- CefRenderProcessHandler ---
  void OnWebKitInitialized() override;
  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override;
  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override;
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override;

 private:
  void HandleEval(CefRefPtr<CefFrame> frame,
                  CefRefPtr<CefProcessMessage> message);

  CefRefPtr<CefMessageRouterRendererSide> renderer_router_;

  IMPLEMENT_REFCOUNTING(NeutrinoRendererApp);
  DISALLOW_COPY_AND_ASSIGN(NeutrinoRendererApp);
};

// Reads the scheme name from the process command line (--neutrino-scheme=...),
// falling back to "neutrino". The helper never runs neutrino_init(), so this is
// how it learns which scheme to register.
std::string NeutrinoSchemeFromCommandLine();

#endif  // NEUTRINO_RENDERER_APP_H
