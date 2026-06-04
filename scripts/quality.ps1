param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]] $Phase = @("all"),
  [switch] $Help
)

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

function Show-Usage {
  Write-Output "Usage: scripts/quality.ps1 [all|fmt|lint|test]..."
  Write-Output ""
  Write-Output "Runs Deckhand's standard local quality gates. With no phase, runs all."
}

function Invoke-Checked {
  param(
    [string] $Command,
    [string[]] $Arguments = @(),
    [string] $WorkingDirectory = $RepoRoot
  )

  Push-Location $WorkingDirectory
  try {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } finally {
    Pop-Location
  }
}

function Get-FlutterCoverageFloor {
  param([string] $Package)
  switch ($Package) {
    "packages/deckhand_core" { 70; return }
    "packages/deckhand_ui" { 60; return }
    "packages/deckhand_profile_script" { 80; return }
    "packages/deckhand_profile_lint" { 80; return }
    "packages/deckhand_profiles" { 40; return }
    "packages/deckhand_ssh" { 20; return }
    "packages/deckhand_flash" { 30; return }
    "packages/deckhand_discovery" { 30; return }
    "packages/deckhand_hitl" { 40; return }
    default { 0; return }
  }
}

function Test-FlutterCoverage {
  param([string] $Package)
  $lcov = Join-Path $RepoRoot "$Package/coverage/lcov.info"
  if (-not (Test-Path $lcov)) { return }

  $hit = 0
  $found = 0
  foreach ($line in Get-Content $lcov) {
    if ($line -match "^LH:(\d+)") { $hit += [int] $Matches[1] }
    if ($line -match "^LF:(\d+)") { $found += [int] $Matches[1] }
  }
  if ($found -eq 0) {
    Write-Output "No lines covered in $Package; skipping floor"
    return
  }

  $floor = Get-FlutterCoverageFloor $Package
  $pct = [math]::Round(($hit * 100.0) / $found, 1)
  Write-Output "$Package coverage: $pct% (floor $floor%)"
  if ($pct -lt $floor) {
    throw "$Package coverage $pct% below $floor% floor"
  }
}

function Test-SidecarCoverage {
  $report = & go tool cover -func=coverage.out
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  $totalLine = $report | Where-Object { $_ -match "^total:" } | Select-Object -Last 1
  if ($totalLine -notmatch "([0-9.]+)%") {
    throw "Could not parse sidecar total coverage"
  }
  $total = [double] $Matches[1]
  Write-Output "Sidecar coverage (total): $total%"
  if ($total -lt 55) {
    throw "Sidecar total coverage $total% below 55% floor"
  }

  $floors = @{
    "internal/rpc" = 85
    "internal/logging" = 80
    "internal/hash" = 80
    "internal/doctor" = 70
    "internal/disks" = 70
  }
  foreach ($pkg in $floors.Keys) {
    $values = @()
    foreach ($line in $report) {
      if ($line -like "*$pkg/*" -and $line -match "([0-9.]+)%$") {
        $values += [double] $Matches[1]
      }
    }
    $actual = 0
    if ($values.Count -gt 0) {
      $actual = [math]::Round((($values | Measure-Object -Average).Average), 1)
    }
    $floor = $floors[$pkg]
    Write-Output "$pkg coverage: $actual% (floor $floor%)"
    if ($actual -lt $floor) {
      throw "$pkg coverage $actual% below $floor% floor"
    }
  }
}

function Invoke-FlutterPubGet {
  foreach ($package in $FlutterPackages) {
    Invoke-Checked flutter @("pub", "get") (Join-Path $RepoRoot $package)
  }
}

function Invoke-Fmt {
  foreach ($package in $FlutterPackages) {
    Invoke-Checked dart @("format", "--output=none", "--set-exit-if-changed", ".") (Join-Path $RepoRoot $package)
  }
}

function Invoke-GoLint {
  $sidecar = Join-Path $RepoRoot "sidecar"
  Invoke-Checked go @("mod", "download") $sidecar
  Invoke-Checked go @("vet", "./...") $sidecar
  Invoke-Checked go @("build", "./...") $sidecar

  $golangci = Get-Command golangci-lint -ErrorAction SilentlyContinue
  if ($null -ne $golangci) {
    Invoke-Checked $golangci.Source @("run", "--timeout=5m") $sidecar
  } else {
    Invoke-Checked go @("run", "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.1.6", "run", "--timeout=5m") $sidecar
  }

  Invoke-Checked go @("run", "./cmd/deckhand-ipc-docs", "--check") $sidecar
}

function Get-PythonCommand {
  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($null -ne $python) { return $python.Source }
  $python3 = Get-Command python3 -ErrorAction SilentlyContinue
  if ($null -ne $python3) { return $python3.Source }
  throw "python or python3 is required"
}

function Invoke-Lint {
  Invoke-GoLint
  Invoke-FlutterPubGet
  foreach ($package in $FlutterPackages) {
    Invoke-Checked flutter @("analyze", "--fatal-infos") (Join-Path $RepoRoot $package)
  }
}

function Invoke-SidecarTests {
  $sidecar = Join-Path $RepoRoot "sidecar"
  if ($IsMacOS) {
    Invoke-Checked go @("test", "-count=1", "./...") $sidecar
  } else {
    Invoke-Checked go @("test", "-race", "-count=1", "-coverprofile=coverage.out", "./...") $sidecar
    Push-Location $sidecar
    try {
      Test-SidecarCoverage
    } finally {
      Pop-Location
    }
  }
}

function Invoke-FlutterTests {
  Invoke-FlutterPubGet
  foreach ($package in $FlutterPackages) {
    $packageRoot = Join-Path $RepoRoot $package
    if (Test-Path (Join-Path $packageRoot "test")) {
      Invoke-Checked flutter @("test", "--coverage", "--reporter=expanded") $packageRoot
      Test-FlutterCoverage $package
    } else {
      Write-Output "No test/ directory in $package; skipping."
    }
  }
}

function Invoke-ProfileLint {
  $ref = if ($env:DECKHAND_PROFILES_REF) { $env:DECKHAND_PROFILES_REF } else { "main" }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("deckhand-profiles-" + [guid]::NewGuid())
  try {
    Invoke-Checked git @("clone", "--depth=1", "--branch", $ref, "https://github.com/CepheusLabs/deckhand-profiles.git", $tmp)
    $packageRoot = Join-Path $RepoRoot "packages/deckhand_profile_lint"
    Invoke-Checked dart @("pub", "get") $packageRoot
    Invoke-Checked dart @("run", "bin/deckhand_profile_lint.dart", "--root", $tmp, "--schema", (Join-Path $tmp "schema/profile.schema.json"), "--strict") $packageRoot
  } finally {
    if (Test-Path $tmp) {
      Remove-Item -LiteralPath $tmp -Recurse -Force
    }
  }
}

function Invoke-Test {
  Invoke-SidecarTests
  Invoke-FlutterTests
  Invoke-Checked (Get-PythonCommand) @("-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py", "-v")
  Invoke-ProfileLint
}

if ($Help) {
  Show-Usage
  exit 0
}

foreach ($item in $Phase) {
  switch ($item) {
    "all" {
      Invoke-Fmt
      Invoke-Lint
      Invoke-Test
    }
    "fmt" { Invoke-Fmt }
    "lint" { Invoke-Lint }
    "test" { Invoke-Test }
    { $_ -in @("-h", "--help", "help") } { Show-Usage }
    default {
      Write-Error "Unknown quality phase: $item"
      Show-Usage
      exit 2
    }
  }
}
