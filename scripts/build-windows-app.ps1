[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Profile', 'Release')]
    [string]$Configuration = 'Debug',

    [switch]$LocalSmokeRelease,

    [switch]$ForceReconfigure,

    [string]$CMakeGenerator = $env:DECKHAND_CMAKE_GENERATOR,

    [string]$CMakeArchitecture = 'x64'
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
$keyringPath = Join-Path $appDir 'assets\keyring.asc'
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
    $cmakeArgs = @(
        '-S', $windowsDir,
        '-B', $buildDir
    )
    if (-not [string]::IsNullOrWhiteSpace($CMakeGenerator)) {
        $cmakeArgs += @('-G', $CMakeGenerator)
    }
    if (-not [string]::IsNullOrWhiteSpace($CMakeArchitecture)) {
        $cmakeArgs += @('-A', $CMakeArchitecture)
    }
    Invoke-Checked $cmake $cmakeArgs
}

$flutterMode = switch ($Configuration) {
    'Debug' { '--debug' }
    'Profile' { '--profile' }
    'Release' { '--release' }
}

$flutterArgs = @('build', 'windows', $flutterMode)
if ($Configuration -eq 'Release') {
    if (-not (Test-Path -LiteralPath $keyringPath)) {
        throw "Profile trust keyring is missing at $keyringPath"
    }
    $keyringText = Get-Content -LiteralPath $keyringPath -Raw
    $isPlaceholderKeyring = $keyringText -match 'BEGIN DECKHAND PROFILE TRUST PLACEHOLDER'
    if ($isPlaceholderKeyring -and -not $LocalSmokeRelease) {
        throw @"
Refusing to build a production Release with the placeholder profile-trust keyring.

Replace app\assets\keyring.asc with production profile-signing public keys, or rerun:
  .\scripts\build-windows-app.ps1 -Configuration Release -LocalSmokeRelease

Local smoke releases are optimized test artifacts only. They are marked with
DECKHAND_LOCAL_SMOKE_RELEASE and must not be packaged or shipped.
"@
    }
    if ($LocalSmokeRelease) {
        $flutterArgs += '--dart-define=DECKHAND_LOCAL_SMOKE_RELEASE=true'
        if (-not $env:DECKHAND_PROFILES_LOCAL) {
            Write-Warning "Local smoke release has no DECKHAND_PROFILES_LOCAL override; remote profile fetches may still be rejected without a production keyring."
        }
    }
}

Push-Location $appDir
try {
    Invoke-Checked 'flutter' $flutterArgs
} finally {
    Pop-Location
}
