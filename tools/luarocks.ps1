param(
    [Parameter(Mandatory=$false, ValueFromRemainingArguments=$true)]
    [string[]]$LuarocksArgs
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DepsDir = Join-Path $RootDir "deps"
$RocksDir = Join-Path $DepsDir "rocks"

$LuarocksExe = Join-Path $DepsDir "luarocks\bin\luarocks.exe"
$LuaExe = Join-Path $DepsDir "luajit\bin\luajit.exe"

$env:LUA_PATH = "$RocksDir\share\lua\5.1\?.lua;$RocksDir\share\lua\5.1\?\init.lua;;;"
$env:LUA_CPATH = "$RocksDir\lib\lua\5.1\?.dll;;;"

Write-Host "Running LuaRocks..." -ForegroundColor Cyan

if (Test-Path $LuarocksExe) {
    # --lua-version pinned: LuaRocks otherwise looks for the newest Lua it
    # knows about and reports "Could not find Lua 5.4 in PATH".
    & $LuarocksExe --lua-version 5.1 --tree=$RocksDir LUA_BINDIR="$DepsDir\luajit\bin" LUA_INCDIR="$DepsDir\luajit\include\luajit-2.1" LUA_LIBDIR="$DepsDir\luajit\lib" $LuarocksArgs
} else {
    Write-Host "Could not find luarocks.exe" -ForegroundColor Red
}
