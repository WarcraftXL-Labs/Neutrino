/// Timers built on CEF's task runner.
///
/// With CefRunMessageLoop() owning the loop, a delayed task posted to TID_UI is
/// already a timer: it fires on the Lua thread, and Chromium handles the
/// scheduling. That removes any need for a second event loop just to get
/// timers, and with it the problem of keeping two loops in step.
///
/// Timers are addressed by integer id rather than by pointer, so a callback for
/// a timer that has since been stopped is a lookup miss rather than a call into
/// freed memory.

#ifndef NEUTRINO_TIMERS_H
#define NEUTRINO_TIMERS_H

#include <stdint.h>

namespace neutrino {

/// Starts a timer. |repeat_ms| of 0 makes it one-shot.
/// Returns the id used to stop it.
int StartTimer(int64_t delay_ms, int64_t repeat_ms);

/// Stops a timer. Safe to call from inside the timer's own callback, and safe
/// for an id that has already fired or been stopped.
void StopTimer(int timer_id);

/// Stops every timer. Called during shutdown so no task outlives CEF.
void StopAllTimers();

}  // namespace neutrino

#endif  // NEUTRINO_TIMERS_H
