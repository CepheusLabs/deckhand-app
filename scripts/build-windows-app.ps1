[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Profile', 'Release')]
    [string]$Configuration = 'Debug',

    [switch]$ForceReconfigure
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @()
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Remove-BuildTree {
    param([Parameter(Mandatory = $true)][string]$Path)

    $repoRootResolved = (Resolve-Path $repoRoot).Path
    $resolved = Resolve-Path $Path -ErrorAction SilentlyContinue
    if ($resolved -eq $null) {
        return
    }
    if (-not $resolved.Path.StartsWith($repoRootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove build tree outside repo: $($resolved.Path)"
    }
    Remove-Item -LiteralPath $resolved.Path -Recurse -Force
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$appDir = Join-Path $repoRoot 'app'
$buildDir = Join-Path $appDir 'build\windows\x64'
$windowsDir = Join-Path $appDir 'windows'

# MSBuild's C++ file-tracking wrapper can orphan cl.exe at 0% CPU on this
# workstation/toolchain combination. Disabling tracking makes both CMake's
# compiler-id probe and Flutter's INSTALL target complete reliably.
$env:TrackFileAccess = 'false'
$env:UseMultiToolTask = 'false'
$env:PreferredToolArchitecture = 'x64'

if ($ForceReconfigure) {
    Remove-BuildTree $buildDir
}

if (-not (Test-Path (Join-Path $buildDir 'CMakeCache.txt'))) {
    $cmake = (Get-Command cmake.exe -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($cmake)) {
        $cmake = 'D:\Program Files\Microsoft\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    }
    Invoke-Checked $cmake @(
        '-S', $windowsDir,
        '-B', $buildDir,
        '-G', 'Visual Studio 18 2026',
        '-A', 'x64'
    )
}

$flutterMode = switch ($Configuration) {
    'Debug' { '--debug' }
    'Profile' { '--profile' }
    'Release' { '--release' }
}

Push-Location $appDir
try {
    Invoke-Checked 'flutter' @('build', 'windows', $flutterMode)
} finally {
    Pop-Location
}
