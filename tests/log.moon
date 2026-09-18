-- Logging: levels, rotation, and catching what was already being written.
--
-- No browser and no native library. The interesting half is `capture`, which
-- has to be turned on and off around a narrow block - while it is on, this
-- suite's own output would go into the log instead of the console.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\log.lua

Neutrino = require "neutrino"
t = require "harness"

fs = Neutrino.fs
log = Neutrino.log

print "Neutrino: logging"

DIR = "#{Neutrino.paths.root}/log-test"
FILE = "#{DIR}/app.log"

--- The whole log file as a string.
contents = (path = FILE) ->
  handle = io.open path, "rb"
  return "" unless handle
  data = handle\read "*a"
  handle\close!
  data

fs.make_dir DIR
os.remove FILE
os.remove "#{FILE}.1"

t.section "Writing"

opened, err = log.open FILE, { truncate: true, console: false, level: "info" }
t.check "a log file opens", opened, err
t.check "and knows where it is", log.path! == Neutrino.paths.resolve(FILE),
  tostring log.path!

log.info "plain message"
log.warn "formatted %d and %s", 42, "text"
log.debug "this one is below the level"

written = contents!

t.check "a message is written", written\match("plain message") != nil, written
t.check "with its level", written\match("INFO  plain message") != nil
t.check "and a timestamp",
  written\match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d%d%d ") != nil,
  written\sub 1, 30
t.check "arguments are formatted",
  written\match("formatted 42 and text") != nil, written
t.check "at the level given", written\match("WARN  formatted") != nil
t.check "and a message below the level is dropped",
  written\match("below the level") == nil

-- A format string that does not match its arguments must not take the caller
-- down; losing a log line is a nuisance, raising inside a handler is a bug.
log.info "%d apples", "not a number"
t.check "a bad format falls back to the message",
  (contents!)\match("%%d apples") != nil, contents!

t.section "Catching what was already written"

-- The point of the module. Every one of these lines exists in the framework
-- today and vanishes in a packaged build.
log.capture!
print "a print from application code"
io.stderr\write "[neutrino] a framework diagnostic\n"
io.stderr\write "written ", "in ", "three pieces\n"
io.stderr\write "no newline yet"
log.restore!

t.check "capture is off again", not log.is_capturing!

after = contents!
t.check "print lands in the log",
  after\match("INFO  a print from application code") != nil, after
t.check "so does a framework diagnostic",
  after\match("WARN  %[neutrino%] a framework diagnostic") != nil, after
t.check "pieces of a line are joined into one",
  after\match("WARN  written in three pieces") != nil, after
t.check "and a line with no newline waits rather than being cut",
  after\match("no newline yet") == nil, after

-- If restore did not work, this line would disappear into the log instead.
t.check "print is itself again", after\match("print is itself") == nil

t.section "Rotation"

log.close!
os.remove FILE
os.remove "#{FILE}.1"

log.open FILE, { truncate: true, console: false, max_bytes: 400 }
for index = 1, 40
  log.info "line %d padded out to make the file grow quickly", index
log.close!

current = contents!
backup = contents "#{FILE}.1"

t.check "the file was rotated", fs.is_file "#{FILE}.1"
t.check "the current one starts again", #current < 400 * 3, "#{#current} bytes"
t.check "and the backup is not empty", #backup > 0, "#{#backup} bytes"

-- One backup, and rotation happened several times over forty lines, so what
-- survives is the end of the run. Saying which is the whole policy: a log that
-- grows without bound is worse than one that forgets the beginning.
t.check "the newest line survived", current\match("line 40 padded") != nil,
  current
t.check "and the oldest is gone from both",
  current\match("line 1 padded") == nil and backup\match("line 1 padded") == nil

t.section "Where a packaged application writes"

data_dir = Neutrino.paths.data_dir "ProbeApp"
t.check "app data is outside the install directory",
  data_dir\match("ProbeApp$") != nil and data_dir != Neutrino.paths.root,
  data_dir
t.check "and the default log sits in it",
  (log.app_data_path "ProbeApp")\match("ProbeApp/ProbeApp%.log$") != nil,
  log.app_data_path "ProbeApp"

os.remove FILE
os.remove "#{FILE}.1"

t.finish!
