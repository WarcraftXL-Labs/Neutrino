// Contract shared by the browser and renderer processes.
//
// Header-only on purpose: the helper executable builds only a subset of the
// sources, and both sides must agree on these names exactly or IPC silently
// stops working.

#ifndef NEUTRINO_IPC_H
#define NEUTRINO_IPC_H

#include "include/wrapper/cef_message_router.h"

namespace neutrino_msg {

// browser -> renderer: [int request_id, string code]
inline constexpr char kEvalRequest[] = "neutrino.eval";

// renderer -> browser: [int request_id, bool ok, string json_or_error]
inline constexpr char kEvalResponse[] = "neutrino.eval.result";

}  // namespace neutrino_msg

// The JS function names the message router installs. Renaming these breaks the
// bridge in renderer_app.cpp, which calls window.neutrinoQuery directly.
inline CefMessageRouterConfig NeutrinoRouterConfig() {
  CefMessageRouterConfig config;
  config.js_query_function = "neutrinoQuery";
  config.js_cancel_function = "neutrinoQueryCancel";
  return config;
}

#endif  // NEUTRINO_IPC_H
