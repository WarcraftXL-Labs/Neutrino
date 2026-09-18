# Builds the C++ layer: neutrinocef.dll and neutrinocef_helper.exe.
#
# Artifacts land in native\build\Release and are copied to deps\cef so that
# build.ps1 can stage them even when native\build has been cleaned away.

param(
    # Force a specific CMake generator. Left empty, CMake picks the newest
    # Visual Studio it can find, which is what you want on a normal machine.
    [string]$Generator = "",

    # Reconfigure from scratch; use after changing CMakeLists.txt in ways an
    # incremental configure does not pick up.
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$NativeDir = Join-Path $RootDir "native"
$BuildDir = Join-Path $NativeDir "build"

if (-not (Get-Command "cmake" -ErrorAction SilentlyContinue)) {
    Write-Host "CMake is not on PATH." -ForegroundColor Red
    exit 1
}

if ($Clean -and (Test-Path $BuildDir)) {
    Write-Host "Removing $BuildDir" -ForegroundColor Yellow
    Remove-Item -Recurse -Force $BuildDir
}

if (-not (Test-Path $BuildDir)) {
    New-Item -ItemType Directory -Path $BuildDir | Out-Null
}

Push-Location $BuildDir
try {
    Write-Host "Configuring..." -ForegroundColor Cyan
    if ($Generator) {
        & cmake -G $Generator -A x64 ..
    } else {
        & cmake -A x64 ..
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "CMake configuration failed." -ForegroundColor Red
        exit 1
    }

    Write-Host "Building (Release)..." -ForegroundColor Cyan
    & cmake --build . --config Release
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed." -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}

# CMake's post-build step already copies both artifacts into deps\cef; verify
# rather than copying again, so a silent failure there does not go unnoticed.
foreach ($artifact in @("neutrinocef.dll", "neutrinocef_helper.exe")) {
    $path = Join-Path $BuildDir "Release\$artifact"
    if (-not (Test-Path $path)) {
        Write-Host "Missing build output: $artifact" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Native layer built. Run .\tools\build.ps1 next." -ForegroundColor Green
