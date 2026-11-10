# Locates the MoonScript compiler in the vendored LuaRocks tree.
# LuaRocks includes its own rock revision in the directory name (for example,
# 0.8.0-1), so callers should not pin a specific MoonScript release.

function Get-MooncFile {
    param([Parameter(Mandatory = $true)][string]$RocksDir)

    $MoonscriptDir = Join-Path $RocksDir "lib\luarocks\rocks-5.1\moonscript"
    if (-not (Test-Path $MoonscriptDir)) {
        throw "MoonScript is missing from $MoonscriptDir. Run .\tools\get-deps.ps1 -Only rocks first."
    }

    $Candidates = @(Get-ChildItem -Path $MoonscriptDir -Directory | ForEach-Object {
        $Compiler = Join-Path $_.FullName "bin\moonc"
        if (Test-Path $Compiler) {
            $Release = $_.Name -replace '-[^-]+$', ''
            $ParsedVersion = [version]::Zero
            if ([version]::TryParse($Release, [ref]$ParsedVersion)) {
                [pscustomobject]@{ Version = $ParsedVersion; Path = $Compiler }
            }
        }
    } | Sort-Object Version -Descending)

    if ($Candidates.Count -eq 0) {
        throw "No MoonScript compiler (moonc) found under $MoonscriptDir. Reinstall the moonscript rock."
    }

    return $Candidates[0].Path
}
