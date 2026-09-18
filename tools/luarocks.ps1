# Runs LuaRocks against the vendored tree.
#
#   .\tools\luarocks.ps1 install inspect
#   .\tools\luarocks.ps1 install lsqlite3complete
#   .\tools\luarocks.ps1 list
#
# Inside the Visual Studio environment, because a rock with C in it needs a
# compiler and finding that out from the error message is not obvious.
#
# A rock installed this way is gone the next time someone clones the repository.
# Add it to $Rocks in get-deps.ps1 once it is meant to stay.

param(
    [Parameter(Mandatory=$false, ValueFromRemainingArguments=$true)]
    [string[]]$LuarocksArgs
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "vcenv.ps1")

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DepsDir = Join-Path $RootDir "deps"
$RocksDir = Join-Path $DepsDir "rocks"
$TempDir = Join-Path $DepsDir ".download"

$LuarocksExe = Join-Path $DepsDir "luarocks\bin\luarocks.exe"

if (-not (Test-Path $LuarocksExe)) {
    Write-Host "Could not find luarocks.exe. Run .\tools\get-deps.ps1 first." -ForegroundColor Red
    exit 1
}

if (-not $LuarocksArgs) {
    Write-Host "Nothing to do. Try: .\tools\luarocks.ps1 install <rock>" -ForegroundColor Yellow
    exit 1
}

Write-Host "Running LuaRocks..." -ForegroundColor Cyan

# --lua-version pinned: LuaRocks otherwise looks for the newest Lua it knows
# about and reports "Could not find Lua 5.4 in PATH".
# LUALIB named explicitly: deps\luajit\lib holds both luajit.lib and
# lua51.lib, LuaRocks picks the first and then refuses it for not
# matching Lua 5.1. lua51.lib is the one that does.
$command = "`"$LuarocksExe`" --lua-version 5.1 --tree=`"$RocksDir`" " +
    "LUA_BINDIR=`"$DepsDir\luajit\bin`" " +
    "LUA_INCDIR=`"$DepsDir\luajit\include\luajit-2.1`" " +
    "LUA_LIBDIR=`"$DepsDir\luajit\lib`" LUALIB=lua51.lib " +
    ($LuarocksArgs -join " ")

Invoke-InVcEnv "luarocks $($LuarocksArgs -join ' ')" $command $TempDir
