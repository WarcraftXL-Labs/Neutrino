# Runs the test suites and reports a single verdict.
#
# Both open real windows and drive a real browser, because that is the only way
# to test a framework whose whole job is windows and a browser. Neither needs
# anyone present.
#
#   .\tools\test.ps1
#   .\tools\test.ps1 -Only smoke

param(
    # Run one suite instead of all of them.
    [ValidateSet("all", "units", "shell", "loop", "module", "static", "ui-layer", "widgets", "browser", "session", "single-instance")]
    [string]$Only = "all"
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

# Set explicitly, for the same reason run.ps1 does: a machine-wide LuaRocks
# install puts its own tree on LUA_PATH and shadows this one, and the failure
# looks like a missing module rather than the wrong copy of a present one.
#
# dist\tests is on the path so a suite can require the harness, while the
# working directory stays dist\ and the framework resolves its paths as usual.
$env:LUA_PATH = "$DistDir\?.lua;$DistDir\?\init.lua;$DistDir\tests\?.lua;$RocksDir\share\lua\5.1\?.lua;$RocksDir\share\lua\5.1\?\init.lua;"
$env:LUA_CPATH = "$RocksDir\lib\lua\5.1\?.dll;"

# Cheapest and most local first: when several break at once, the first failure
# is usually the one worth reading.
$suites = @("units", "shell", "loop", "module", "static", "ui-layer", "widgets", "browser", "session", "single-instance")
if ($Only -ne "all") { $suites = @($Only) }

$failed = @()

Push-Location $DistDir
try {
    foreach ($suite in $suites) {
        $script = "tests\$suite.lua"
        if (-not (Test-Path $script)) {
            Write-Host "Missing $script - was it built?" -ForegroundColor Red
            $failed += $suite
            continue
        }

        Write-Host ""
        Write-Host "=== $suite ===" -ForegroundColor Cyan

        # Chromium writes a great deal to stderr that has nothing to do with the
        # tests; the suites report through stdout, so that is what is shown.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try { & $LuaExe $script 2>$null } finally { $ErrorActionPreference = $previous }

        if ($LASTEXITCODE -ne 0) { $failed += $suite }
    }
} finally {
    Pop-Location
}

Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "All suites passed." -ForegroundColor Green
