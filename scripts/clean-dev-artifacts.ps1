param([switch] $Help)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$FlutterPackages = @(
  "packages/deckhand_core",
  "packages/deckhand_profiles",
  "packages/deckhand_ssh",
  "packages/deckhand_flash",
  "packages/deckhand_discovery",
  "packages/deckhand_hitl",
  "packages/deckhand_ui",
  "packages/deckhand_profile_script",
  "packages/deckhand_profile_lint",
  "packages/deckhand_lints",
  "app"
)

if ($Help) {
  Write-Output "Usage: scripts/clean-dev-artifacts.ps1"
  Write-Output "Cleans generated Flutter/Dart, Go, and script test artifacts."
  exit 0
}

foreach ($package in $FlutterPackages) {
  $packageRoot = Join-Path $RepoRoot $package
  Write-Output "Cleaning Flutter/Dart artifacts in $package..."
  $pubspec = Get-Content (Join-Path $packageRoot "pubspec.yaml") -Raw
  if ($pubspec -match "(?m)^\s*flutter:" -or $pubspec -match "sdk:\s*flutter" -or $pubspec -match "flutter_test:") {
    Push-Location $packageRoot
    try {
      & flutter clean
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally {
      Pop-Location
    }
  } else {
    foreach ($relative in @(".dart_tool", "build", "coverage")) {
      $path = Join-Path $packageRoot $relative
      if (Test-Path $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
      }
    }
  }
}

Write-Output "Removing Go and script test artifacts..."
$sidecarCoverage = Join-Path $RepoRoot "sidecar/coverage.out"
if (Test-Path $sidecarCoverage) {
  Remove-Item -LiteralPath $sidecarCoverage -Force
}
Get-ChildItem -LiteralPath (Join-Path $RepoRoot "sidecar") -Recurse -File -Include "*.test", "*.out" |
  Remove-Item -Force
foreach ($root in @("sidecar", "scripts")) {
  Get-ChildItem -LiteralPath (Join-Path $RepoRoot $root) -Recurse -Directory -Filter "__pycache__" |
    Remove-Item -Recurse -Force
}

Write-Output "Done."
