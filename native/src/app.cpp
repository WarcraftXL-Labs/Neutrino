#include "app.h"

#include "neutrino_state.h"
#include "scheme_handler.h"

#include "include/cef_scheme.h"

NeutrinoApp::NeutrinoApp() = default;

void NeutrinoApp::OnRegisterCustomSchemes(
    CefRawPtr<CefSchemeRegistrar> registrar) {
  // Standard schemes behave like http/https: they have a real origin, so the
  // page gets localStorage, fetch, modules and the rest. SECURE keeps Chromium
  // from treating the app as mixed content.
  const int options = CEF_SCHEME_OPTION_STANDARD | CEF_SCHEME_OPTION_SECURE |
                      CEF_SCHEME_OPTION_CORS_ENABLED |
                      CEF_SCHEME_OPTION_FETCH_ENABLED;

  registrar->AddCustomScheme(neutrino::SchemeName(), options);
}

void NeutrinoApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {
  // Only adjust the browser process; child processes inherit what we append in
  // OnBeforeChildProcessLaunch.
  if (!process_type.empty()) {
    return;
  }

  if (disable_gpu_) {
    command_line->AppendSwitch("disable-gpu");
    command_line->AppendSwitch("disable-gpu-compositing");
  }

  // Which backend ANGLE translates GL to. Chromium picks D3D11 on Windows,
  // and where that fails it fails hard: the GPU process hits a breakpoint on
  // startup, is retried three times, and the page ends up with no WebGL
  // context at all - not a slow one, none. Naming "gl" there gets a real
  // context on the same hardware.
  //
  // Left empty by default, because the default is right on most machines and
  // this is not the framework's call to make for an application.
  if (!angle_backend_.empty()) {
    command_line->AppendSwitchWithValue("use-angle", angle_backend_);
  }
}

void NeutrinoApp::OnContextInitialized() {
  // An empty domain registers the factory for every host under the scheme, so
  // neutrino://app/, neutrino://mpq/ and so on all reach the Lua router. That
  // is what lets separate modules own their own origin.
  CefRegisterSchemeHandlerFactory(neutrino::SchemeName(), CefString(),
                                  new NeutrinoSchemeHandlerFactory());
}

void NeutrinoApp::OnBeforeChildProcessLaunch(
    CefRefPtr<CefCommandLine> command_line) {
  // The helper process has to register the exact same scheme, but it never runs
  // neutrino_init(), so it learns the name from its command line.
  command_line->AppendSwitchWithValue("neutrino-scheme",
                                      neutrino::SchemeName());
}
