-- libuv, serviced from CEF's loop.
--
-- Everything here used to register successfully and then never call back. That
-- is what makes these checks worth having: a broken pump produces no error and
-- no output, only silence, and a suite that merely called the functions would
-- pass on it.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\loop.lua

Neutrino = require "neutrino"
t = require "harness"

async = Neutrino.async
fs = Neutrino.fs
uv = Neutrino.uv

print "Neutrino: libuv"

t.load_native!

t.check "luv is installed", uv.luv! != nil
t.check "and nothing is being pumped before anything asks", not uv.is_pumping!

WATCHED = "#{Neutrino.paths.root}/loop-test"
TOUCHED = "#{WATCHED}/touched.txt"

app = Neutrino.App t.app_options { quit_on_last_window: false }
t.expect_completion!

app\on "ready", ->
  t.deadline app

  t.task "loop suite", ->
    t.section "Running a program"

    -- The plainest thing that can go wrong: spawn returns a handle whatever
    -- happens, so only the exit code proves the callback ever fired.
    code = async.await (resolve) ->
      handle, err = uv.spawn "cmd.exe", { args: { "/c", "exit 7" } },
        (exit_code) -> resolve exit_code
      resolve nil, err unless handle

    t.check "a child process reports its exit code", code == 7, tostring code
    t.check "and the loop let go of it afterwards", uv.retained! == 0,
      tostring uv.retained!

    t.section "Watching a directory"

    fs.make_dir WATCHED
    os.remove TOUCHED

    seen = nil
    watcher, watch_err = uv.watch WATCHED, (filename) -> seen or= filename or true
    t.check "a watcher starts", watcher != nil, watch_err

    if watcher
      -- A moment for the watch to be armed before the write it should see.
      async.sleep 60
      fs.write TOUCHED, "hello"

      t.check "and reports a file appearing",
        (t.wait_until -> seen != nil), tostring seen

      watcher\stop!
      watcher\close!

    t.section "Worker threads"

    -- The worker pool is the one caller that has to hold the loop open itself:
    -- a job on another thread is not something libuv reports as pending.
    -- Named rather than passed inline: a trailing ", argument" after an
    -- indented function body does not parse inside a block.
    measure = (path) ->
      file = io.open path, "rb"
      return -1 unless file
      data = file\read "*a"
      file\close!
      #data

    size = async.work measure, TOUCHED

    t.check "a worker returns its result", size == 5, tostring size
    t.check "and releases the loop when it is done", uv.retained! == 0,
      tostring uv.retained!

    t.section "Idling"

    -- The other half of the promise: an application that stops using libuv
    -- stops paying for it. Without this the pump would be a permanent timer.
    t.check "the pump stops once there is nothing left to do",
      (t.wait_until -> not uv.is_pumping!), "still pumping"

    t.check "and starts again when asked", uv.wake! and uv.is_pumping!

    -- Left running otherwise, since nothing has work for it.
    t.check "then stops again on its own",
      (t.wait_until -> not uv.is_pumping!), "still pumping"

    os.remove TOUCHED

    t.done!
    app\quit!

app\run!
t.finish!
