-- The platform shell: clipboard, opening things, the single-instance lock.
--
-- Needs neutrinocef.dll loaded, but not CEF initialised and no window: none of
-- this is Chromium's, which is the point of it being a separate file.
--
-- The hand-off of arguments between two processes is in single-instance.moon;
-- it needs a second process, and this one is a single process by design.
--
--   Run from dist\:  ..\deps\luajit\bin\luajit.exe tests\shell.lua

Neutrino = require "neutrino"
t = require "harness"

print "Neutrino: platform shell"

t.load_native!
shell = Neutrino.shell

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Clipboard"

-- Non-ASCII deliberately. The Win32 calls behind this are the wide ones; the
-- A variants would go through the process code page and mangle exactly this.
sample = "Neutrino — épée ⚔ #{os.time!}"

written, write_error = shell.write_text sample
t.check "text is written to the clipboard", written, write_error
t.check "and reads back unchanged", shell.read_text! == sample, shell.read_text!

t.check "an empty string is a value, not a failure",
  shell.write_text("") and shell.read_text! == ""

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Opening things"

-- open_external takes urls only, and the restriction is the feature: the same
-- Win32 call handed a path will run an executable, so a url that arrived from
-- a page must not be able to reach it.
opened, refusal = shell.open_external "C:/Windows/System32/cmd.exe"
t.check "open_external refuses an executable", opened == false, "it opened it"

-- The parentheses are load bearing. Without them MoonScript reads the detail
-- argument on the next line as a second argument to match, which is
-- string.match's `init` and has to be a number.
t.check "and points at open_path instead",
  type(refusal) == "string" and (refusal\match "open_path"), refusal

t.check "open_external refuses a file url",
  shell.open_external("file:///C:/Windows/System32/cmd.exe") == false

t.check "show_in_folder refuses a path that is not there",
  shell.show_in_folder("Z:/no/such/place/at/all") == false

-- ═══════════════════════════════════════════════════════════════════════════

t.section "Single instance"

-- Named uniquely per run, so a copy of a demo running alongside cannot make
-- this fail, and a run that crashed earlier cannot leave the name claimed.
lock = "neutrino-shell-#{os.time!}-#{math.random 100000}"

t.check "the lock is claimed", shell.claim_single_instance lock

-- The same process asking again is still the process that holds it.
t.check "claiming it again from the same process succeeds",
  shell.claim_single_instance lock

t.check "notifying a name nobody claimed reports nobody home",
  shell.notify_first_instance("neutrino-shell-nobody", "x") == false

shell.release_single_instance!

t.finish!
