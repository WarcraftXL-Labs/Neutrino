# Fetches everything under deps/, none of which is in the repository.
#
# CEF is a gigabyte, LuaJIT has no official Windows binaries, and committing
# .exe and .dll files to a public repository is a good way to make people
# reasonably suspicious of it. So deps/ is built here instead, from sources
# anyone can check.
#
#   .\tools\get-deps.ps1              # everything that is missing
#   .\tools\get-deps.ps1 -Force       # re-fetch even what is already there
#   .\tools\get-deps.ps1 -Only cef    # one component: cef, luajit, luarocks, rocks
#
# Needs: git, CMake and a C++ toolchain (Visual Studio Build Tools).
# Everything else it downloads.

param(
    # Re-fetch components that are already present.
    [switch]$Force,

    # Fetch only one component, for when a single one needs redoing.
    [ValidateSet("all", "cef", "luajit", "luarocks", "rocks")]
    [string]$Only = "all"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # the progress bar makes downloads slower

# Pinned rather than floating. A framework that builds against whatever CEF
# happened to be current today is one that stops building tomorrow; when this
# moves, it moves deliberately and the version in the C++ shows up in the diff.
$CefVersion = "152.0.6+g708dc14+chromium-152.0.7977.83"
$CefPlatform = "windows64"
$CefFlavour = "minimal"

$LuaJitBranch = "v2.1"
$LuaRocksVersion = "3.11.1"

$Rocks = @(
    "lua-cjson",          # JSON, in C
    "luv",                # libuv: worker threads, processes, watchers
    "moonscript",         # the compiler, and lpeg/lfs/argparse with it
    "etlua",              # templates for widgets
    "penlight",           # paths, directories, files
    "inspect",            # readable tables, for logs
    "lsqlite3complete"    # SQLite, amalgamation included
)

$RootDir = Resolve-Path (Join-Path $PSScriptRoot "..")
$DepsDir = Join-Path $RootDir "deps"
$TempDir = Join-Path $DepsDir ".download"

New-Item -ItemType Directory -Path $DepsDir, $TempDir -Force | Out-Null

function Step($message) { Write-Host "[deps] $message" -ForegroundColor Cyan }

# The compiler helpers live in vcenv.ps1: get-deps and luarocks both need
# them, and a copy in each is a copy that drifts.
. (Join-Path $PSScriptRoot "vcenv.ps1")

function Note($message) { Write-Host "       $message" -ForegroundColor DarkGray }

function Want($component) {
    return $Only -eq "all" -or $Only -eq $component
}

# --- CEF --------------------------------------------------------------------

if (Want "cef") {
    $CefDir = Join-Path $DepsDir "cef"
    $CefName = "cef_binary_${CefVersion}_${CefPlatform}_${CefFlavour}"
    $CefTarget = Join-Path $CefDir $CefName

    if ((Test-Path $CefTarget) -and -not $Force) {
        Note "CEF $CefVersion already present"
    } else {
        Step "CEF $CefVersion ($CefFlavour, about 1 GB)"
        New-Item -ItemType Directory -Path $CefDir -Force | Out-Null

        # The '+' characters in the version are literal in the file name and
        # have to survive the URL, where they would otherwise mean a space.
        $encoded = [uri]::EscapeDataString("$CefName.tar.bz2")
        $url = "https://cef-builds.spotifycdn.com/$encoded"
        $archive = Join-Path $TempDir "$CefName.tar.bz2"

        if ((Test-Path $archive) -and -not $Force) {
            Note "using the archive already in deps\.download"
        } else {
            Note $url
            Invoke-WebRequest -Uri $url -OutFile $archive
        }

        Step "Extracting CEF"
        # bsdtar ships with Windows 10 1803 and later, and reads .tar.bz2
        # directly, so this needs no third-party archiver.
        Invoke-Native "extracting CEF" { tar -xf $archive -C $CefDir }

        if (-not (Test-Path $CefTarget)) {
            throw "CEF extracted, but $CefName is not there. Check the version."
        }
    }
}

# --- LuaJIT -----------------------------------------------------------------
#
# Built from source: LuaJIT publishes no Windows binaries, and the ones floating
# around are of unknown provenance. msvcbuild.bat is LuaJIT's own script.

if (Want "luajit") {
    $LuaJitDir = Join-Path $DepsDir "luajit"

    if ((Test-Path (Join-Path $LuaJitDir "bin\luajit.exe")) -and -not $Force) {
        Note "LuaJIT already built"
    } else {
        Step "LuaJIT ($LuaJitBranch, from source)"
        $checkout = Join-Path $TempDir "LuaJIT"
        if (Test-Path $checkout) { Remove-Item -Recurse -Force $checkout }

        Invoke-Native "cloning LuaJIT" {
            git clone --depth 1 --branch $LuaJitBranch `
                https://github.com/LuaJIT/LuaJIT.git $checkout
        }

        Step "Building LuaJIT"
        $srcDir = Join-Path $checkout "src"
        # ".\msvcbuild.bat", not "msvcbuild.bat": when
        # NoDefaultCurrentDirectoryInExePath is set - and it is, on a machine
        # hardened by policy - cmd will not run a script from the current
        # directory unless the path says so. It reports the file as not found,
        # which sends you looking for a file that is sitting right there.
        Invoke-InVcEnv "building LuaJIT" "cd /d `"$srcDir`" && call `".\msvcbuild.bat`"" $TempDir

        # Laid out the way LuaRocks and the CMake host target expect to find it.
        $bin = Join-Path $LuaJitDir "bin"
        $lib = Join-Path $LuaJitDir "lib"
        $inc = Join-Path $LuaJitDir "include\luajit-2.1"
        $jit = Join-Path $LuaJitDir "share\luajit-2.1\jit"
        New-Item -ItemType Directory -Path $bin, $lib, $inc, $jit -Force | Out-Null

        Copy-Item (Join-Path $srcDir "luajit.exe") $bin -Force
        Copy-Item (Join-Path $srcDir "lua51.dll") $bin -Force
        Copy-Item (Join-Path $srcDir "lua51.lib") $lib -Force
        if (Test-Path (Join-Path $srcDir "luajit.lib")) {
            Copy-Item (Join-Path $srcDir "luajit.lib") $lib -Force
        }

        foreach ($header in @("lua.h", "lualib.h", "lauxlib.h", "luaconf.h", "luajit.h")) {
            Copy-Item (Join-Path $srcDir $header) $inc -Force
        }

        # The jit/*.lua modules are what luajit.exe loads for -jdump and friends;
        # without them the interpreter runs but its tooling does not.
        Copy-Item (Join-Path $srcDir "jit\*.lua") $jit -Force

        Note "LuaJIT built into deps\luajit"
    }
}

# --- LuaRocks ---------------------------------------------------------------

if (Want "luarocks") {
    $LuaRocksDir = Join-Path $DepsDir "luarocks"

    if ((Test-Path (Join-Path $LuaRocksDir "bin\luarocks.exe")) -and -not $Force) {
        Note "LuaRocks already present"
    } else {
        Step "LuaRocks $LuaRocksVersion"
        $name = "luarocks-$LuaRocksVersion-windows-64"
        $url = "https://luarocks.github.io/luarocks/releases/$name.zip"
        $archive = Join-Path $TempDir "$name.zip"

        Note $url
        Invoke-WebRequest -Uri $url -OutFile $archive

        $unpacked = Join-Path $TempDir "luarocks-unpacked"
        if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
        Expand-Archive -Path $archive -DestinationPath $unpacked -Force

        $bin = Join-Path $LuaRocksDir "bin"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null

        # The zip holds a single versioned directory; take what is inside it.
        $inner = Get-ChildItem -Path $unpacked -Directory | Select-Object -First 1
        $from = if ($inner) { $inner.FullName } else { $unpacked }
        Copy-Item -Path (Join-Path $from "*") -Destination $bin -Recurse -Force

        Note "LuaRocks in deps\luarocks\bin"
    }
}

# --- Rocks ------------------------------------------------------------------

if (Want "rocks") {
    $RocksDir = Join-Path $DepsDir "rocks"
    $LuarocksExe = Join-Path $DepsDir "luarocks\bin\luarocks.exe"

    if (-not (Test-Path $LuarocksExe)) {
        throw "LuaRocks is missing; run without -Only, or with -Only luarocks first."
    }

    foreach ($rock in $Rocks) {
        Step "Rock: $rock"

        # Inside the Visual Studio environment, because lua-cjson and luv are C
        # and need a compiler. luarocks.ps1 does the same for a one-off install.
            # LUALIB named explicitly: deps\luajit\lib holds both luajit.lib and
    # lua51.lib, LuaRocks picks the first and then refuses it for not
    # matching Lua 5.1. lua51.lib is the one that does.
    $command = "`"$LuarocksExe`" --lua-version 5.1 --tree=`"$RocksDir`" " +
            "LUA_BINDIR=`"$DepsDir\luajit\bin`" " +
            "LUA_INCDIR=`"$DepsDir\luajit\include\luajit-2.1`" " +
            "LUA_LIBDIR=`"$DepsDir\luajit\lib`" LUALIB=lua51.lib install $rock"

        $failed = $false
        try { Invoke-InVcEnv "installing $rock" $command $TempDir } catch { $failed = $true }

        if ($failed) {
            # Not fatal: luv is optional, and one rock failing should not stop
            # the others. The summary below reports what is actually missing.
            Write-Host "       $rock failed to install." -ForegroundColor Yellow
        }
    }
}

# --- Report -----------------------------------------------------------------

Write-Host ""
$missing = @()
foreach ($check in @(
    @{ Name = "CEF";       Path = (Join-Path $DepsDir "cef") ; Glob = "cef_binary_*" },
    @{ Name = "LuaJIT";    Path = (Join-Path $DepsDir "luajit\bin\luajit.exe") },
    @{ Name = "LuaRocks";  Path = (Join-Path $DepsDir "luarocks\bin\luarocks.exe") },
    @{ Name = "cjson";     Path = (Join-Path $DepsDir "rocks\lib\lua\5.1\cjson.dll") },
    @{ Name = "moonc";     Path = (Join-Path $DepsDir "rocks\lib\luarocks\rocks-5.1\moonscript") }
)) {
    $present = if ($check.Glob) {
        (Get-ChildItem -Path $check.Path -Directory -Filter $check.Glob -ErrorAction SilentlyContinue).Count -gt 0
    } else {
        Test-Path $check.Path
    }

    if ($present) {
        Write-Host "  ok      $($check.Name)" -ForegroundColor Green
    } else {
        Write-Host "  missing $($check.Name)" -ForegroundColor Red
        $missing += $check.Name
    }
}

Write-Host ""
if ($missing.Count -gt 0) {
    Write-Host "[deps] Incomplete: $($missing -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "[deps] Ready. Next: .\tools\build-native.ps1" -ForegroundColor Green
Write-Host "       deps\.download can be deleted; it only holds the archives."
