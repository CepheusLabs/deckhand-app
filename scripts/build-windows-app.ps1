[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Profile', 'Release')]
    [string]$Configuration = 'Debug',

    [switch]$LocalSmokeRelease,

    [switch]$ForceReconfigure,

    [string]$VisualStudioPath = $env:DECKHAND_VISUAL_STUDIO_PATH,

    [string]$CMakePath = $env:DECKHAND_CMAKE_PATH,

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

function Resolve-FirstExistingPath {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }
    return $null
}

function Resolve-VisualStudioPath {
    if (-not [string]::IsNullOrWhiteSpace($VisualStudioPath)) {
        if (-not (Test-Path -LiteralPath $VisualStudioPath)) {
            throw "DECKHAND_VISUAL_STUDIO_PATH does not exist: $VisualStudioPath"
        }
        return (Resolve-Path -LiteralPath $VisualStudioPath).Path
    }

    $vswherePath = Resolve-FirstExistingPath @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe')
    )
    if (-not [string]::IsNullOrWhiteSpace($vswherePath)) {
        $detected = & $vswherePath -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($detected) -and (Test-Path -LiteralPath $detected)) {
            return (Resolve-Path -LiteralPath $detected).Path
        }
    }

    $fallback = Resolve-FirstExistingPath @(
        'D:\Program Files\Microsoft',
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2026\Community'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2026\Professional'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2026\Enterprise'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Community'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Professional'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\Enterprise')
    )
    if (-not [string]::IsNullOrWhiteSpace($fallback)) {
        return $fallback
    }

    throw "Unable to find Visual Studio with MSBuild. Install the Flutter-supported Windows desktop workload, or set DECKHAND_VISUAL_STUDIO_PATH."
}

function Resolve-CMakePath {
    if (-not [string]::IsNullOrWhiteSpace($CMakePath)) {
        if (-not (Test-Path -LiteralPath $CMakePath)) {
            throw "DECKHAND_CMAKE_PATH does not exist: $CMakePath"
        }
        return (Resolve-Path -LiteralPath $CMakePath).Path
    }

    $vsPath = Resolve-VisualStudioPath
    $vsCMake = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (Test-Path -LiteralPath $vsCMake) {
        return (Resolve-Path -LiteralPath $vsCMake).Path
    }

    throw "Visual Studio was found at $vsPath, but its bundled CMake was not found at $vsCMake."
}

function Get-CMakeHelpText {
    param([Parameter(Mandatory = $true)][string]$ResolvedCMakePath)

    $helpText = & $ResolvedCMakePath --help
    if ($LASTEXITCODE -ne 0) {
        throw "$ResolvedCMakePath --help failed with exit code $LASTEXITCODE"
    }
    return $helpText
}

function Test-CMakeGenerator {
    param(
        [Parameter(Mandatory = $true)][string[]]$HelpText,
        [Parameter(Mandatory = $true)][string]$Generator
    )

    $escaped = [regex]::Escape($Generator)
    return [bool]($HelpText | Where-Object { $_ -match "^\s*\*?\s*$escaped\s*=" })
}

function Resolve-CMakeGenerator {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedCMakePath,
        [string]$RequestedGenerator
    )

    $helpText = Get-CMakeHelpText $ResolvedCMakePath
    if (-not [string]::IsNullOrWhiteSpace($RequestedGenerator)) {
        if (-not (Test-CMakeGenerator $helpText $RequestedGenerator)) {
            throw "CMake at $ResolvedCMakePath does not support generator '$RequestedGenerator'."
        }
        return $RequestedGenerator
    }

    $visualStudioGenerators = $helpText |
        ForEach-Object {
            if ($_ -match '^\s*\*?\s*(Visual Studio \d+ \d{4})\s*=') {
                $Matches[1]
            }
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $generator = $visualStudioGenerators | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($generator)) {
        throw "CMake at $ResolvedCMakePath does not advertise a Visual Studio generator."
    }
    return $generator
}

function Assert-CMakeCacheMatches {
    param(
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][string]$ExpectedGenerator,
        [Parameter(Mandatory = $true)][string]$ExpectedInstance
    )

    if (-not (Test-Path -LiteralPath $CachePath)) {
        return
    }
    $generatorLine = Get-Content -LiteralPath $CachePath |
        Where-Object { $_ -like 'CMAKE_GENERATOR:INTERNAL=*' } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($generatorLine)) {
        return
    }
    $existingGenerator = $generatorLine.Substring('CMAKE_GENERATOR:INTERNAL='.Length)
    if ($existingGenerator -ne $ExpectedGenerator) {
        throw "Existing Windows build tree uses '$existingGenerator', expected '$ExpectedGenerator'. Rerun with -ForceReconfigure."
    }
    $instanceLine = Get-Content -LiteralPath $CachePath |
        Where-Object { $_ -like 'CMAKE_GENERATOR_INSTANCE:INTERNAL=*' } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($instanceLine)) {
        return
    }
    $existingInstance = $instanceLine.Substring('CMAKE_GENERATOR_INSTANCE:INTERNAL='.Length)
    if ($existingInstance -ne $ExpectedInstance) {
        throw "Existing Windows build tree uses Visual Studio instance '$existingInstance', expected '$ExpectedInstance'. Rerun with -ForceReconfigure."
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

# Keep the MSBuild invocation deterministic when Flutter shells out through
# CMake. File tracking is not used by release artifacts and can leave stale
# compiler helper processes on partially interrupted builds.
$env:TrackFileAccess = 'false'
$env:UseMultiToolTask = 'false'
$env:PreferredToolArchitecture = 'x64'

$resolvedVisualStudioPath = Resolve-VisualStudioPath
$cmake = Resolve-CMakePath
$resolvedCMakeGenerator = Resolve-CMakeGenerator $cmake $CMakeGenerator
$cachePath = Join-Path $buildDir 'CMakeCache.txt'

if ($ForceReconfigure) {
    Remove-BuildTree $buildDir
}

Assert-CMakeCacheMatches $cachePath $resolvedCMakeGenerator $resolvedVisualStudioPath

if (-not (Test-Path $cachePath)) {
    $cmakeArgs = @(
        '-S', $windowsDir,
        '-B', $buildDir,
        '-G', $resolvedCMakeGenerator,
        "-DCMAKE_GENERATOR_INSTANCE=$resolvedVisualStudioPath"
    )
    if (-not [string]::IsNullOrWhiteSpace($CMakeArchitecture)) {
        $cmakeArgs += @('-A', $CMakeArchitecture)
    }
    Write-Host "Using CMake: $cmake"
    Write-Host "Using CMake generator: $resolvedCMakeGenerator"
    Write-Host "Using Visual Studio: $resolvedVisualStudioPath"
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
