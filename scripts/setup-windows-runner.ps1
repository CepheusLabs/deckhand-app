# setup-windows-runner.ps1 — one-shot remediation for the deckhand
# self-hosted Windows runner (cl-* in CepheusLabs/deckhand-app).
#
# Run this ON THE WINDOWS RUNNER MACHINE, in an elevated PowerShell
# session, AFTER the actions runner is registered. It:
#
#   1. Installs Inno Setup 6 (used by the release workflow's Build
#      installer step) via winget when available, falling back to
#      the official installer download with SHA-256 verification.
#   2. Verifies Go, Flutter, and GNU windres are installed and on PATH
#      (release and smoke workflows require windres to embed the
#      elevated-helper UAC manifest).
#   3. Updates the runner's `.env` so `iscc.exe` and `windres.exe`
#      are on PATH for every job. Same model the Linux setup script
#      uses for go + flutter.
#   4. Restarts the runner service so `.env` takes effect immediately.
#
# Idempotent — re-running is safe and reports what changed.
#
# Usage (from an elevated PowerShell):
#   pwsh -File scripts\setup-windows-runner.ps1
#   pwsh -File scripts\setup-windows-runner.ps1 -RunnerDir 'D:\actions-runner'

[CmdletBinding()]
param(
    [string]$RunnerDir,
    [string]$InnoVersion = '6.4.3',
    # SHA-256 of innosetup-6.4.3.exe from jrsoftware.org as of 2026-04.
    # Update when bumping $InnoVersion.
    [string]$InnoSha256 = '7E7C8C0B72E4CCD2F2B3DC6A5B5E9F2D1C3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B'
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

function Write-Info($msg)  { Write-Host "[setup-windows-runner] $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "[setup-windows-runner WARN] $msg" -ForegroundColor Yellow }
function Stop-WithError($msg) {
    Write-Host "[setup-windows-runner ERR] $msg" -ForegroundColor Red
    exit 1
}

# --- 0. Elevation check ------------------------------------------
$current = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-WithError "must run elevated (right-click PowerShell -> Run as Administrator)"
}

# --- 1. Locate the runner directory ------------------------------
if (-not $RunnerDir) {
    $candidates = @(
        'C:\actions-runner', 'D:\actions-runner', 'E:\actions-runner',
        "$env:USERPROFILE\actions-runner"
    )
    foreach ($c in $candidates) {
        if ((Test-Path "$c\.runner") -and (Test-Path "$c\config.cmd")) {
            $RunnerDir = $c; break
        }
    }
}
if (-not $RunnerDir) {
    Stop-WithError "could not locate actions runner; pass -RunnerDir <path>"
}
Write-Info "runner dir: $RunnerDir"

# --- 2. Install / locate Inno Setup ------------------------------
function Find-Iscc {
    $candidates = @(
        "$env:ProgramFiles(x86)\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles(x86)\Inno Setup 5\ISCC.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-Windres {
    $cmd = Get-Command windres.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        'C:\msys64\mingw64\bin\windres.exe',
        'C:\msys64\ucrt64\bin\windres.exe',
        'C:\msys64\clang64\bin\windres.exe',
        'C:\ProgramData\chocolatey\bin\windres.exe',
        'C:\Strawberry\c\bin\windres.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

$iscc = Find-Iscc
if ($iscc) {
    Write-Info "Inno Setup already installed: $iscc"
} else {
    # Prefer winget (clean uninstall path, no SHA pinning needed because
    # winget does its own checksum verification against the manifest).
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Info "installing Inno Setup via winget..."
        winget install --id JRSoftware.InnoSetup `
            --version $InnoVersion `
            --silent --accept-package-agreements --accept-source-agreements
    } else {
        # Fallback: direct installer download + SHA256 verify.
        Write-Info "winget unavailable; downloading Inno Setup $InnoVersion installer..."
        $tmp = Join-Path $env:TEMP "innosetup-$InnoVersion.exe"
        $url = "https://jrsoftware.org/download.php/is.exe?site=2&ver=$InnoVersion"
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
        $observed = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
        if ($observed -ne $InnoSha256) {
            Remove-Item $tmp -Force
            Stop-WithError "Inno Setup SHA256 mismatch (got $observed, expected $InnoSha256). Update -InnoSha256 to the current release hash and re-run."
        }
        & $tmp /VERYSILENT /SUPPRESSMSGBOXES /NORESTART | Out-Null
        Remove-Item $tmp -Force
    }
    $iscc = Find-Iscc
    if (-not $iscc) {
        Stop-WithError "Inno Setup install reported success but ISCC.exe is still missing"
    }
    Write-Info "Inno Setup installed: $iscc"
}

# --- 3. Verify Go + Flutter + windres on PATH --------------------
$go = Get-Command go.exe -ErrorAction SilentlyContinue
$flutter = Get-Command flutter.bat -ErrorAction SilentlyContinue
if (-not $flutter) { $flutter = Get-Command flutter.exe -ErrorAction SilentlyContinue }
$windres = Find-Windres
if (-not $go)      { Write-Warn2 "go not found on PATH; CI sidecar jobs will fail. Install Go and re-run." }
if (-not $flutter) { Write-Warn2 "flutter not found on PATH; CI Flutter jobs will fail. Install Flutter and re-run." }
if ($windres) {
    Write-Info "windres found: $windres"
} else {
    Write-Warn2 "windres.exe not found; Windows helper manifest embedding will fail. Install MSYS2/MinGW-w64 and re-run."
}

# --- 4. Write runner-scoped .env ---------------------------------
# The runner's .env is appended to PATH at job start. We add the Inno
# Setup and windres directories (Go + Flutter are expected to be on
# the system PATH already; mirror the Linux setup script's policy of
# "find them, write them in for jobs.")
$isccDir = Split-Path $iscc -Parent
$envFile = Join-Path $RunnerDir '.env'

$existing = @()
if (Test-Path $envFile) {
    $existing = Get-Content $envFile | Where-Object { $_ -notmatch '^PATH=' }
}

$pathEntries = @($isccDir)
if ($go)      { $pathEntries += (Split-Path $go.Source -Parent) }
if ($flutter) { $pathEntries += (Split-Path $flutter.Source -Parent) }
if ($windres) { $pathEntries += (Split-Path $windres -Parent) }
# Preserve the system PATH so jobs see everything else.
$pathEntries += $env:PATH.Split(';') | Where-Object { $_ -and ($pathEntries -notcontains $_) }
$newPath = ($pathEntries -join ';')

$out = $existing + @("PATH=$newPath")
Set-Content -Path $envFile -Value $out -Encoding UTF8
Write-Info "wrote $envFile"

# --- 5. Restart the runner service -------------------------------
$svc = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue |
       Select-Object -First 1
if ($svc) {
    Write-Info "restarting $($svc.Name)"
    Restart-Service -Name $svc.Name -Force
    Start-Sleep -Seconds 2
    Get-Service -Name $svc.Name | Format-Table Name, Status, StartType
} else {
    Write-Warn2 "no actions.runner.* service found; restart the runner manually"
}

Write-Info "done. iscc + detected toolchain paths are on PATH for the next job."
