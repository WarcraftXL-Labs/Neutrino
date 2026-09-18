#include "timers.h"

#include <map>

#include "neutrino_state.h"

#include "include/base/cef_callback.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"

namespace neutrino {
namespace {

struct Timer {
  int64_t repeat_ms = 0;
  bool alive = true;
};

/// UI-thread only, so no lock.
std::map<int, Timer>& Timers() {
  static std::map<int, Timer> timers;
  return timers;
}

int NextTimerId() {
  static int next = 1;
  return next++;
}

void Fire(int timer_id) {
  auto& timers = Timers();

  auto it = timers.find(timer_id);
  if (it == timers.end() || !it->second.alive) {
    return;  // stopped while the task was in flight
  }

  const int64_t repeat_ms = it->second.repeat_ms;

  // A one-shot timer is removed before the callback runs, so that code asking
  // whether it is still active during its own callback gets the right answer.
  if (repeat_ms <= 0) {
    timers.erase(it);
  }

  Callbacks& cb = GetCallbacks();
  if (cb.timer) {
    cb.timer(timer_id, cb.timer_user);
  }

  if (repeat_ms <= 0) {
    return;
  }

  // Re-read: the callback may have stopped this timer, or every timer.
  auto again = timers.find(timer_id);
  if (again == timers.end() || !again->second.alive) {
    return;
  }

  CefPostDelayedTask(TID_UI, base::BindOnce(&Fire, timer_id), repeat_ms);
}

}  // namespace

int StartTimer(int64_t delay_ms, int64_t repeat_ms) {
  if (delay_ms < 0) {
    delay_ms = 0;
  }
  if (repeat_ms < 0) {
    repeat_ms = 0;
  }

  const int timer_id = NextTimerId();
  Timers()[timer_id] = Timer{repeat_ms, true};

  CefPostDelayedTask(TID_UI, base::BindOnce(&Fire, timer_id), delay_ms);
  return timer_id;
}

void StopTimer(int timer_id) {
  auto& timers = Timers();
  auto it = timers.find(timer_id);
  if (it == timers.end()) {
    return;
  }

  // Marked rather than erased: a task for this id may already be queued, and
  // Fire() checks the flag before doing anything.
  it->second.alive = false;
  timers.erase(it);
}

void StopAllTimers() {
  Timers().clear();
}

}  // namespace neutrino
