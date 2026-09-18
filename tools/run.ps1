# Runs a built Neutrino script from dist/.
#
# Sets LUA_PATH and LUA_CPATH explicitly rather than relying on the defaults: a
# machine-wide LUA_PATH (from a system LuaRocks install) otherwise shadows dist/
# and the vendored rocks, and the script fails to find its own modules.
#
#   .\tools\run.ps1 my_app.lua
#
# The test suites have their own runner: .\tools\test.ps1

param(
    [Parameter(Position = 0)]
    [string]$Script = "",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DepsDir = Join-Path $RootDir "deps"
$RocksDir = Join-Path $DepsDir "rocks"
$DistDir = Join-Path $RootDir "dist"
$LuaExe = Join-Path $DepsDir "luajit\bin\luajit.exe"

if (-not (Test-Path $DistDir)) {
    Write-Host "dist/ is missing. Run .\tools\build.ps1 first." -ForegroundColor Red
    exit 1
}

# Named rather than defaulted: there is no example application in the tree yet,
# so any default would be a guess. Listing what is there beats guessing wrong.
if (-not $Script) {
    Write-Host "Which script? Available in dist\:" -ForegroundColor Yellow
    Get-ChildItem -Path $DistDir -Filter "*.lua" |
        ForEach-Object { Write-Host "  $($_.Name)" }
    exit 1
}

$ScriptPath = Join-Path $DistDir $Script
if (-not (Test-Path $ScriptPath)) {
    Write-Host "Not found: $ScriptPath" -ForegroundColor Red
    exit 1
}

$env:LUA_PATH = "$DistDir\?.lua;$DistDir\?\init.lua;$RocksDir\share\lua\5.1\?.lua;$RocksDir\share\lua\5.1\?\init.lua;"
$env:LUA_CPATH = "$RocksDir\lib\lua\5.1\?.dll;"

# Build the argument list by hand: splatting a $null ScriptArgs passes an empty
# argument through to luajit, which rejects it.
$Arguments = @($Script)
if ($ScriptArgs) { $Arguments += $ScriptArgs }

Push-Location $DistDir
try {
    & $LuaExe $Arguments
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

exit $code
