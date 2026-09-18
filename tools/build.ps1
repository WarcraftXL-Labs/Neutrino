# Builds Neutrino into dist/.
#
# Compiles the MoonScript sources and stages the runtime next to them: the CEF
# binaries come straight from the SDK folder rather than from a hand-curated
# copy, because a partial set fails at runtime in ways that are hard to trace
# (a missing ANGLE or SwiftShader DLL kills the renderer process with no error).

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DepsDir = Join-Path $RootDir "deps"
$RocksDir = Join-Path $DepsDir "rocks"
$SrcDir = Join-Path $RootDir "src"
$DistDir = Join-Path $RootDir "dist"
$BinDir = Join-Path $DistDir "bin"

Write-Host "[Neutrino] Building..." -ForegroundColor Cyan

# --- Locate the CEF distribution -------------------------------------------

$CefRoot = Get-ChildItem -Path (Join-Path $DepsDir "cef") -Directory -Filter "cef_binary_*" |
    Select-Object -First 1
if (-not $CefRoot) {
    Write-Host "No CEF distribution found under deps\cef." -ForegroundColor Red
    exit 1
}
$CefRelease = Join-Path $CefRoot.FullName "Release"
$CefResources = Join-Path $CefRoot.FullName "Resources"

# --- Clean ------------------------------------------------------------------

if (Test-Path $DistDir) { Remove-Item -Recurse -Force "$DistDir\*" }
else { New-Item -ItemType Directory -Path $DistDir | Out-Null }
New-Item -ItemType Directory -Path $BinDir | Out-Null

# --- Compile MoonScript -----------------------------------------------------

$LuaExe = Join-Path $DepsDir "luajit\bin\luajit.exe"
$MooncFile = Join-Path $RocksDir "lib\luarocks\rocks-5.1\moonscript\0.7.0-1\bin\moonc"

$env:LUA_PATH = "$RocksDir\share\lua\5.1\?.lua;$RocksDir\share\lua\5.1\?\init.lua;;;"
$env:LUA_CPATH = "$RocksDir\lib\lua\5.1\?.dll;;;"

Write-Host "  MoonScript: src/" -ForegroundColor Yellow

# Compiling from inside src/ keeps moonc from recreating a src/ level in dist/.
Push-Location $SrcDir
& $LuaExe $MooncFile -t "$DistDir" .
$compileFailed = $LASTEXITCODE -ne 0
Pop-Location
if ($compileFailed) { Write-Host "MoonScript compilation failed." -ForegroundColor Red; exit 1 }

# Suites compile into dist/tests/ rather than beside the framework. A suite in
# dist/ would shadow a package of the same name - dist/browser.lua ahead of
# dist/browser/ - and the failure reads as a mysterious circular require.
Write-Host "  MoonScript: examples and tests" -ForegroundColor Yellow
foreach ($dir in @("examples", "tests")) {
    $from = Join-Path $RootDir $dir
    if (-not (Test-Path $from)) { continue }

    $into = Join-Path $DistDir $dir
    New-Item -ItemType Directory -Force -Path $into | Out-Null

    Get-ChildItem -Path $from -Filter "*.moon" | ForEach-Object {
        # moonc writes beside the source, so the result is moved into place.
        $Produced = Join-Path $from ($_.BaseName + ".lua")
        & $LuaExe $MooncFile $_.FullName
        if (Test-Path $Produced) {
            Move-Item $Produced (Join-Path $into ($_.BaseName + ".lua")) -Force
        } else {
            Write-Host "  $($_.Name) failed to compile." -ForegroundColor Red
            exit 1
        }
    }
}

# --- Static assets ----------------------------------------------------------
#
# static/ is served at runtime rather than compiled, so it is copied as it is.
# The application resolves it against its own root, which is dist/ here and the
# package folder once packaged.

$StaticSrc = Join-Path $RootDir "static"
if (Test-Path $StaticSrc) {
    Write-Host "  Static assets" -ForegroundColor Yellow
    Copy-Item -Recurse -Force -Path $StaticSrc -Destination $DistDir
}

# --- Stage the CEF runtime --------------------------------------------------

Write-Host "  CEF runtime: $($CefRoot.Name)" -ForegroundColor Gray

# Everything in Release/ except the import library and the bootstrap launchers,
# which are only useful to applications that do not ship their own executable.
Get-ChildItem -Path $CefRelease -File |
    Where-Object { $_.Extension -in ".dll", ".bin", ".json" } |
    ForEach-Object { Copy-Item $_.FullName -Destination $BinDir -Force }

Get-ChildItem -Path $CefResources -File |
    ForEach-Object { Copy-Item $_.FullName -Destination $BinDir -Force }

$LocalesSrc = Join-Path $CefResources "locales"
if (Test-Path $LocalesSrc) {
    Copy-Item -Recurse -Path $LocalesSrc -Destination $BinDir -Force
}

# --- Stage the Neutrino native layer ----------------------------------------

$NativeRelease = Join-Path $RootDir "native\build\Release"
foreach ($artifact in @("neutrinocef.dll", "neutrinocef_helper.exe")) {
    $source = Join-Path $NativeRelease $artifact
    if (-not (Test-Path $source)) {
        $source = Join-Path $DepsDir "cef\$artifact"
    }
    if (-not (Test-Path $source)) {
        Write-Host "Missing $artifact. Run .\tools\build-native.ps1 first." -ForegroundColor Red
        exit 1
    }
    Copy-Item $source -Destination $BinDir -Force
}

Write-Host "[Neutrino] Build complete. Run it with .\tools\run.ps1" -ForegroundColor Green
