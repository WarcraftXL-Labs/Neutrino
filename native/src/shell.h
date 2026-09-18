/// Platform integration that CEF does not provide: the clipboard, the system
/// shell, and the single-instance lock.
///
/// None of this is Chromium's business, so none of it comes with CEF. It is
/// here because an application that cannot copy a string, open a folder or stop
/// itself from running twice is not a desktop application yet.
///
/// Everything runs on the thread that called neutrino_init(), which is both the
/// CEF UI thread and the Lua thread. The single-instance window receives its
/// messages through CEF's own message loop, so nothing here pumps anything.

#ifndef NEUTRINO_SHELL_H
#define NEUTRINO_SHELL_H

#include <string>

namespace neutrino {

// --- Clipboard --------------------------------------------------------------

/// Reads the clipboard as UTF-8. Empty when it holds no text, which is not an
/// error: a clipboard carrying a bitmap simply has no text to give.
std::string ClipboardReadText();

/// Replaces the clipboard contents. Returns false when another process holds
/// the clipboard open, which happens and is worth reporting rather than hiding.
bool ClipboardWriteText(const std::string& text);

// --- System shell -----------------------------------------------------------

/// Opens a URL with the user's default handler.
///
/// Restricted to http, https and mailto on purpose. ShellExecute on an
/// arbitrary string will happily run an executable, so a url that arrived from
/// a page - or from anywhere the application did not write itself - must not
/// reach it. Paths go through OpenPath, which the caller has to choose
/// deliberately.
bool OpenExternal(const std::string& url);

/// Opens a file or folder with its registered application.
///
/// This will run an executable if handed one, exactly as a double click would.
/// That is the point of the separate entry point: the caller is stating that
/// the path is its own, not the page's.
bool OpenPath(const std::string& path);

/// Opens the containing folder with the item selected.
bool ShowInFolder(const std::string& path);

// --- Single instance --------------------------------------------------------

/// Claims |name| for this process.
///
/// Returns true when this is the only instance. Returns false when another
/// process already holds the name, and the caller is expected to exit - having
/// usually called NotifyFirstInstance() first, so the running copy can raise
/// its window and act on the new arguments.
bool AcquireSingleInstance(const std::string& name);

/// Hands |payload| to the instance already holding |name|.
///
/// Returns false when nobody is listening, which is a race rather than a bug:
/// the first instance can exit between the failed claim and this call.
bool NotifyFirstInstance(const std::string& name, const std::string& payload);

/// Releases the lock and destroys the listening window.
void ReleaseSingleInstance();

}  // namespace neutrino

#endif  // NEUTRINO_SHELL_H
