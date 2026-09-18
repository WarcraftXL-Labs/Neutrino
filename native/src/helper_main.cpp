// Entry point for the renderer, GPU and utility processes CEF spawns.
//
// This executable never runs neutrino_init(); it learns which custom scheme to
// register from the --neutrino-scheme switch the browser process appends in
// NeutrinoApp::OnBeforeChildProcessLaunch.

#include <windows.h>

#include "renderer_app.h"

int APIENTRY wWinMain(HINSTANCE hInstance,
                      HINSTANCE hPrevInstance,
                      LPWSTR lpCmdLine,
                      int nCmdShow) {
  CefMainArgs main_args(hInstance);

  CefRefPtr<NeutrinoRendererApp> app = new NeutrinoRendererApp();

  // Returns the child process exit code, or -1 when called from the browser
  // process (which never happens here, since this is a dedicated helper).
  return CefExecuteProcess(main_args, app, nullptr);
}
