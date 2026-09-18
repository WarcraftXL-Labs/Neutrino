# Packages a Neutrino application into a folder that can be handed to someone.
#
# dist/ is a development tree: it assumes luajit.exe, a machine with the repo on
# it, and someone who knows which script to pass. This produces the other thing
# - a folder with one named executable in it, which is what shipping means.
#
# Layout of the result:
#
#   <AppName>/
#     <AppName>.exe        the host; runs app/main.lua
#     lua51.dll            next to the host, because Windows looks there first
#     app/                 the compiled application and the framework
#       main.lua           entry point, required
#       core/ browser/ serve/ system/ util/ ui/
#     static/              assets served over neutrino://
#     rocks/               vendored Lua modules (cjson, and luv if present)
#     bin/                 neutrinocef.dll and the whole CEF runtime
#
# Paths are resolved by the host from its own location, so the folder can be
# moved, renamed or run from a shortcut.
#
#   .\tools\package.ps1 -Name "MPQBrowser" -Entry src\my_app.moon

param(
    # Name of the produced executable and its folder.
    [string]$Name = "NeutrinoApp",

    # The application's entry point, a .moon or .lua file under the repo root.
    [string]$Entry = "",

    # Where to put the result. Defaults to build/<Name>.
    [string]$OutDir = "",

    # Icon for the executable. Optional.
    [string]$Icon = ""
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DepsDir = Join-Path $RootDir "deps"
$RocksDir = Join-Path $DepsDir "rocks"
$SrcDir = Join-Path $RootDir "src"
$NativeBuild = Join-Path $RootDir "native\build\Release"

if (-not $OutDir) { $OutDir = Join-Path $RootDir "build\$Name" }

Write-Host "[Neutrino] Packaging $Name..." -ForegroundColor Cyan

# --- Check what the package needs before deleting anything ------------------
#
# All of it is verified up front: half a package is worse than none, and the
# output directory is about to be wiped.

$HostExe = Join-Path $NativeBuild "neutrino_host.exe"
$CefDll = Join-Path $NativeBuild "neutrinocef.dll"
$HelperExe = Join-Path $NativeBuild "neutrinocef_helper.exe"

foreach ($required in @($HostExe, $CefDll, $HelperExe)) {
    if (-not (Test-Path $required)) {
        Write-Host "Missing $required" -ForegroundColor Red
        Write-Host "Run .\tools\build-native.ps1 first." -ForegroundColor Red
        exit 1
    }
}

$CefRoot = Get-ChildItem -Path (Join-Path $DepsDir "cef") -Directory -Filter "cef_binary_*" |
    Select-Object -First 1
if (-not $CefRoot) {
    Write-Host "No CEF distribution found under deps\cef." -ForegroundColor Red
    exit 1
}
$CefRelease = Join-Path $CefRoot.FullName "Release"
$CefResources = Join-Path $CefRoot.FullName "Resources"

if (-not $Entry) {
    Write-Host "No entry point given. Pass -Entry path\to\app.moon" -ForegroundColor Red
    exit 1
}

$EntryPath = Join-Path $RootDir $Entry
if (-not (Test-Path $EntryPath)) {
    Write-Host "Entry point not found: $EntryPath" -ForegroundColor Red
    exit 1
}

$LuaExe = Join-Path $DepsDir "luajit\bin\luajit.exe"
$MooncFile = Join-Path $RocksDir "lib\luarocks\rocks-5.1\moonscript\0.7.0-1\bin\moonc"

# --- Lay out the folder -----------------------------------------------------

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$AppDir = Join-Path $OutDir "app"
$BinDir = Join-Path $OutDir "bin"
$PkgRocks = Join-Path $OutDir "rocks"
New-Item -ItemType Directory -Path $AppDir, $BinDir -Force | Out-Null

# --- Compile the framework and the application ------------------------------

# moonc needs its own modules on the path, and the vendored tree is the only
# place they are.
$env:LUA_PATH = "$RocksDir\share\lua\5.1\?.lua;$RocksDir\share\lua\5.1\?\init.lua;;;"
$env:LUA_CPATH = "$RocksDir\lib\lua\5.1\?.dll;;;"

Write-Host "  MoonScript: framework" -ForegroundColor DarkGray

# Compiled from inside src/ so moonc does not recreate a src/ level under app/.
# neutrino.moon lands as app/neutrino.lua, which is what `require "neutrino"`
# finds on the path the host sets.
Push-Location $SrcDir
& $LuaExe $MooncFile -t "$AppDir" .
$compileFailed = $LASTEXITCODE -ne 0
Pop-Location
if ($compileFailed) {
    Write-Host "MoonScript compilation failed." -ForegroundColor Red
    exit 1
}

Write-Host "  MoonScript: $Entry" -ForegroundColor DarkGray
$EntryLua = Join-Path $AppDir "main.lua"
if ($Entry -like "*.moon") {
    & $LuaExe $MooncFile $EntryPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Entry point failed to compile." -ForegroundColor Red
        exit 1
    }
    # moonc writes beside the source, so the result is moved into place.
    $Produced = Join-Path (Split-Path $EntryPath) ((Get-Item $EntryPath).BaseName + ".lua")
    Move-Item $Produced $EntryLua -Force
} else {
    Copy-Item $EntryPath $EntryLua
}

# Checked rather than assumed: an empty app/ is the difference between a package
# that runs and one that opens an error box on the user's machine.
if (-not (Test-Path $EntryLua)) {
    Write-Host "Entry point did not produce app\main.lua" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path (Join-Path $AppDir "neutrino.lua"))) {
    Write-Host "Framework did not compile into app\." -ForegroundColor Red
    exit 1
}
foreach ($package in @("core", "browser", "serve", "system", "util", "ui")) {
    $packageDir = Join-Path $AppDir $package
    $found = Get-ChildItem -Path $packageDir -Filter "*.lua" -Recurse -ErrorAction SilentlyContinue
    if (-not $found) {
        Write-Host "app\$package is empty." -ForegroundColor Red
        exit 1
    }
}

# --- Vendored Lua modules ---------------------------------------------------

Write-Host "  Rocks" -ForegroundColor DarkGray
foreach ($sub in @("share\lua\5.1", "lib\lua\5.1")) {
    $from = Join-Path $RocksDir $sub
    if (Test-Path $from) {
        $to = Join-Path $PkgRocks $sub
        New-Item -ItemType Directory -Path $to -Force | Out-Null
        Copy-Item -Recurse -Force -Path (Join-Path $from "*") -Destination $to
    }
}

# --- Static assets ----------------------------------------------------------

$StaticSrc = Join-Path $RootDir "static"
if (Test-Path $StaticSrc) {
    Write-Host "  Static assets" -ForegroundColor DarkGray
    Copy-Item -Recurse -Force -Path $StaticSrc -Destination $OutDir
}

# --- The executable ---------------------------------------------------------

Write-Host "  Host: $Name.exe" -ForegroundColor DarkGray
Copy-Item $HostExe (Join-Path $OutDir "$Name.exe")

# Beside the executable rather than in bin\: Windows searches the directory the
# process was loaded from, and the host links lua51 at load time - before any
# code of ours could point it anywhere else.
Copy-Item (Join-Path $DepsDir "luajit\bin\lua51.dll") $OutDir

if ($Icon) {
    if (Test-Path $Icon) {
        Write-Host "  Icon: not applied (needs a resource editor)" -ForegroundColor Yellow
    } else {
        Write-Host "  Icon not found: $Icon" -ForegroundColor Yellow
    }
}

# --- CEF runtime ------------------------------------------------------------
#
# Copied wholesale from the SDK rather than from a hand-picked list. A partial
# CEF runtime does not fail at startup: it fails later, in the renderer, with no
# message worth reading.

Write-Host "  CEF runtime" -ForegroundColor DarkGray
Copy-Item -Recurse -Force -Path (Join-Path $CefRelease "*") -Destination $BinDir
Copy-Item -Recurse -Force -Path (Join-Path $CefResources "*") -Destination $BinDir

Copy-Item $CefDll $BinDir
Copy-Item $HelperExe $BinDir

# The import libraries and the debug symbols are build inputs, not runtime.
Get-ChildItem -Path $BinDir -Include "*.lib", "*.pdb", "*.exp" -Recurse |
    Remove-Item -Force -ErrorAction SilentlyContinue

# --- Report -----------------------------------------------------------------

$size = (Get-ChildItem -Recurse -File $OutDir | Measure-Object -Property Length -Sum).Sum
$mb = [math]::Round($size / 1MB, 1)

Write-Host ""
Write-Host "[Neutrino] Packaged to $OutDir ($mb MB)" -ForegroundColor Green
Write-Host "           Run it with `"$OutDir\$Name.exe`""
