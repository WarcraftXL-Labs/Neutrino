# Running commands with the Visual Studio C++ environment set up.
#
# Dot-sourced by the scripts that need a compiler:
#
#   . (Join-Path $PSScriptRoot "vcenv.ps1")
#   Invoke-InVcEnv "installing a rock" "luarocks install ..."
#
# It lives in its own file because get-deps.ps1 and luarocks.ps1 both need it,
# and a copy in each is a copy that drifts. Each of the three oddities handled
# below cost an afternoon to find once.

# Runs an external program without letting its stderr count as a failure.
#
# git, tar, nmake and cl all write progress to stderr, and with
# ErrorActionPreference set to Stop PowerShell turns that into a terminating
# error even when the command succeeded. The exit code is the thing that says.
function Invoke-Native {
    param([string]$What, [scriptblock]$Command)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Command } finally { $ErrorActionPreference = $previous }

    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

# Locates the Visual Studio environment script.
function Find-VcVars {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }

    $install = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $install) { return $null }

    $vcvars = Join-Path $install "VC\Auxiliary\Build\vcvars64.bat"
    # if/else rather than a ternary: Windows PowerShell 5.1 has no ternary, and
    # this has to run on a machine that has only what Windows ships with.
    if (Test-Path $vcvars) { return $vcvars }
    return $null
}

# Runs commands with the Visual Studio environment already set up.
#
# The body goes into a batch file rather than into one long `cmd /c` string.
# cmd strips the first and last quote of its argument, so a command that has to
# quote several paths comes out mangled at both ends - and every path here has
# spaces in it. A file has no such rule.
function Invoke-InVcEnv {
    param([string]$What, [string]$Body, [string]$ScratchDir)

    $vcvars = Find-VcVars
    if (-not $vcvars) {
        throw "Visual Studio C++ build tools not found; $What needs a compiler."
    }

    if (-not $ScratchDir) { $ScratchDir = $env:TEMP }
    New-Item -ItemType Directory -Path $ScratchDir -Force | Out-Null

    $script = Join-Path $ScratchDir "vcenv.bat"
    @(
        "@echo off",
        # Cleared for this shell only. When it is set, cmd will not run a
        # program from the current directory without an explicit path - and
        # vcvars64.bat calls vswhere.exe that way internally, so it half
        # initialises and every later compiler invocation fails with 9009.
        "set NoDefaultCurrentDirectoryInExePath=",
        "call `"$vcvars`" >nul || exit /b 1",
        $Body
    ) | Set-Content -Path $script -Encoding Oem

    # A single quoted argument is the case cmd parses predictably.
    Invoke-Native $What { cmd /c "`"$script`"" }
}
