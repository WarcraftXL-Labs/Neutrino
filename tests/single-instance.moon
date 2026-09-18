-- Single-instance test. Needs two processes, so it starts the second itself.
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\single-instance.lua
--
-- Kept out of test_smoke because that one is a single process by design. What
-- is checked here cannot be: that a second launch finds the first, hands its
-- arguments over, and exits.

Neutrino = require "neutrino"

shell = Neutrino.shell

-- The shell lives in neutrinocef.dll, so it has to be loaded before any of it
-- is used - in both roles, including the one that only forwards and exits.
loaded, load_error = Neutrino.cef.setup Neutrino.paths.bin
unless loaded
  io.stderr\write "cannot load neutrinocef.dll: #{tostring load_error}\n"
  os.exit 1

-- ═══════════════════════════════════════════════════════════════════════════
-- Second role: forward the arguments and get out of the way
-- ═══════════════════════════════════════════════════════════════════════════

if arg and arg[1] == "second"
  lock = arg[2]

  -- Parenthesised deliberately: MoonScript would otherwise read the separator
  -- as a third argument to notify_first_instance.
  payload = table.concat({ arg[3] or "", arg[4] or "" }, "\t")

  os.exit (shell.notify_first_instance lock, payload) and 0 or 3

-- ═══════════════════════════════════════════════════════════════════════════
-- First role: claim the lock, start a second copy, check what arrives
-- ═══════════════════════════════════════════════════════════════════════════

t = require "harness"
check = t.check

print "Neutrino: single instance"

uv_ok, uv = pcall require, "luv"
unless uv_ok
  print "  SKIP  luv is not installed, so the second process cannot be started"
  os.exit 0

-- Unique per run, so a copy of the demo running alongside cannot interfere and
-- an earlier run that crashed cannot leave the name claimed.
LOCK = "neutrino-instance-#{os.time!}-#{math.random 100000}"
SENT = { "C:\\test\\carte.wdt", "deuxieme argument" }

received = nil
received_raw = nil

claimed = shell.claim_single_instance LOCK, (args, raw) ->
  received = args
  received_raw = raw

check "the first process claims the lock", claimed
os.exit 1 unless claimed

app = Neutrino.App {
  cache_path: Neutrino.paths.root .. "/cache"
  resources_path: Neutrino.paths.bin
  locales_path: Neutrino.paths.bin .. "/locales"
  subprocess_path: Neutrino.paths.bin .. "/neutrinocef_helper.exe"
  quit_on_last_window: false
}

t.expect_completion!

second_exit = nil

app\on "ready", ->
  -- No window anywhere in this test. The listener is a plain Win32
  -- message-only window and CEF's loop dispatches to it, so the hand-off works
  -- with nothing on screen - which is what makes it usable at the point an
  -- application is still deciding whether to start at all.
  handle, spawn_error = uv.spawn uv.exepath!, {
    args: { "tests/single-instance.lua", "second", LOCK, SENT[1], SENT[2] }
    cwd: Neutrino.paths.root
    stdio: { nil, 1, 2 }
  }, (code) -> second_exit = code

  check "the second process starts", handle != nil, spawn_error

  -- luv's exit callback only fires when luv's own loop is turned, and CEF owns
  -- the loop here. core.async does the same thing for its worker pool, but only
  -- while a job is in flight - so anything else built on luv has to pump for
  -- itself. The hand-off below does not depend on this; only the exit code does.
  pump = app\set_timer 25, (-> uv.run "nowait"), 25

  app\set_timer 3000, ->
    app\clear_timer pump

    check "the second process exits", second_exit != nil,
      "still running after 3s"
    check "and reports it delivered its arguments", second_exit == 0,
      "exit code #{tostring second_exit}"

    check "the first process received them", received != nil, "nothing arrived"

    if received
      check "both arguments arrived", #received == 2, "#{#received} arrived"
      check "the first argument is intact", received[1] == SENT[1], received[1]
      check "the second argument is intact", received[2] == SENT[2], received[2]

      -- Tab separated on purpose: a Windows path can contain spaces, quotes and
      -- semicolons, so none of those can be the separator.
      check "the raw payload is tab separated",
        received_raw == table.concat(SENT, "\t"), received_raw

    t.done!
    app\quit!

  -- Hard stop, so a hang fails the run instead of blocking forever.
  app\set_timer 12000, ->
    t.fail "timed out"
    app\quit!

app\run!

t.finish!
