// Neutrino host - the executable a packaged application actually ships as.
//
// Development runs luajit.exe against a script in dist/. That is fine for
// development and useless for shipping: the window's process is called
// "luajit", the task manager shows an interpreter, and the user has to be told
// which script to pass. This host exists so a packaged tool is one executable
// with its own name, launched by double clicking it.
//
// It does as little as possible: point Lua at the folders next to the
// executable, run app/main.lua, report anything that goes wrong somewhere the
// user can see it.

#include <windows.h>

#include <string>
#include <vector>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

namespace {

/// Directory holding this executable, with forward slashes and no trailing one.
///
/// Everything is resolved from here rather than from the working directory: a
/// shortcut, a file association or a drag-and-drop each start the process
/// somewhere else entirely, and all three are normal ways to launch a tool.
std::string ExecutableDir() {
  std::wstring buffer(MAX_PATH, L'\0');
  DWORD length = GetModuleFileNameW(nullptr, &buffer[0],
                                    static_cast<DWORD>(buffer.size()));

  // A path can exceed MAX_PATH; grow until it fits rather than truncating.
  while (length == buffer.size()) {
    buffer.resize(buffer.size() * 2, L'\0');
    length = GetModuleFileNameW(nullptr, &buffer[0],
                                static_cast<DWORD>(buffer.size()));
  }
  buffer.resize(length);

  const int size = WideCharToMultiByte(CP_UTF8, 0, buffer.c_str(), length,
                                       nullptr, 0, nullptr, nullptr);
  std::string path(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, buffer.c_str(), length, &path[0], size,
                      nullptr, nullptr);

  for (char& c : path) {
    if (c == '\\') {
      c = '/';
    }
  }
  const size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? std::string(".") : path.substr(0, slash);
}

/// Reports a failure the packaged user can actually read.
///
/// A console box is the wrong place: the host is a GUI subsystem binary, so
/// there is no console attached and anything written to stderr goes nowhere.
void ReportFailure(const std::string& message) {
  const int size = MultiByteToWideChar(CP_UTF8, 0, message.c_str(), -1, nullptr, 0);
  std::wstring wide(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, message.c_str(), -1, &wide[0], size);
  MessageBoxW(nullptr, wide.c_str(), L"Neutrino", MB_OK | MB_ICONERROR);
}

/// Builds the `arg` table the way a stand-alone Lua interpreter does, so a
/// script can read its command line without knowing it is not running under
/// luajit.exe.
void PushArgTable(lua_State* lua, const std::string& exe_path) {
  int count = 0;
  LPWSTR* wide_args = CommandLineToArgvW(GetCommandLineW(), &count);

  lua_newtable(lua);

  lua_pushstring(lua, exe_path.c_str());
  lua_rawseti(lua, -2, 0);

  for (int i = 1; i < count; ++i) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, wide_args[i], -1, nullptr,
                                         0, nullptr, nullptr);
    std::string argument(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide_args[i], -1, &argument[0], size,
                        nullptr, nullptr);
    argument.resize(strlen(argument.c_str()));  // drop the encoded terminator

    lua_pushstring(lua, argument.c_str());
    lua_rawseti(lua, -2, i);
  }

  if (wide_args) {
    LocalFree(wide_args);
  }
  lua_setglobal(lua, "arg");
}

/// Points package.path and package.cpath at the folders beside the executable.
///
/// Set here rather than through the environment so the application is not at
/// the mercy of a machine-wide LUA_PATH, which is exactly the shadowing that
/// tools/run.ps1 already has to work around during development.
void SetSearchPaths(lua_State* lua, const std::string& root) {
  const std::string path =
      root + "/app/?.lua;" + root + "/app/?/init.lua;" +
      root + "/rocks/share/lua/5.1/?.lua;" +
      root + "/rocks/share/lua/5.1/?/init.lua";
  const std::string cpath = root + "/rocks/lib/lua/5.1/?.dll";

  lua_getglobal(lua, "package");

  lua_pushstring(lua, path.c_str());
  lua_setfield(lua, -2, "path");

  lua_pushstring(lua, cpath.c_str());
  lua_setfield(lua, -2, "cpath");

  lua_pop(lua, 1);
}

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
  const std::string root = ExecutableDir();

  lua_State* lua = luaL_newstate();
  if (!lua) {
    ReportFailure("Could not create the Lua state.");
    return 1;
  }
  luaL_openlibs(lua);

  SetSearchPaths(lua, root);
  PushArgTable(lua, root);

  // The bin directory holds neutrinocef.dll and the CEF runtime beside it.
  // Lua reads this to find them, which keeps the layout in one place - here -
  // rather than duplicated in every application's entry point.
  lua_pushstring(lua, (root + "/bin").c_str());
  lua_setglobal(lua, "NEUTRINO_BIN");

  lua_pushstring(lua, root.c_str());
  lua_setglobal(lua, "NEUTRINO_ROOT");

  const std::string entry = root + "/app/main.lua";
  if (luaL_dofile(lua, entry.c_str()) != 0) {
    const char* message = lua_tostring(lua, -1);
    ReportFailure(std::string("Failed to run ") + entry + "\n\n" +
                  (message ? message : "unknown error"));
    lua_close(lua);
    return 1;
  }

  lua_close(lua);
  return 0;
}
