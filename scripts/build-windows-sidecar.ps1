[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

    [string]$Version = $env:DECKHAND_VERSION
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

$repoRoot = Split-Path -Parent $PSScriptRoot
$sidecarDir = Join-Path $repoRoot 'sidecar'
$helperDir = Join-Path $sidecarDir 'cmd\deckhand-elevated-helper'
$helperSyso = Join-Path $helperDir 'rsrc_windows.syso'

if ([string]::IsNullOrWhiteSpace($Version)) {
    try {
        $count = (& git -C $repoRoot rev-list --count HEAD).Trim()
        $sha = (& git -C $repoRoot rev-parse --short HEAD).Trim()
        $Version = "dev-$count-$sha"
    } catch {
        $Version = 'dev'
    }
}

$go = (Get-Command go.exe -ErrorAction Stop).Source
$windres = (Get-Command windres.exe -ErrorAction Stop).Source

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Push-Location $helperDir
try {
    Invoke-Checked $windres @(
        '-i', 'resource_windows.rc',
        '-O', 'coff',
        '-o', 'rsrc_windows.syso'
    )
} finally {
    Pop-Location
}

try {
    $sidecarOut = Join-Path $OutputDir 'deckhand-sidecar.exe'
    $helperOut = Join-Path $OutputDir 'deckhand-elevated-helper.exe'

    Invoke-Checked $go @(
        '-C', $sidecarDir,
        'build',
        '-trimpath',
        '-ldflags', "-s -w -X main.Version=$Version",
        '-o', $sidecarOut,
        './cmd/deckhand-sidecar'
    )

    Invoke-Checked $go @(
        '-C', $sidecarDir,
        'build',
        '-trimpath',
        '-ldflags', "-s -w -X main.Version=$Version -H windowsgui",
        '-o', $helperOut,
        './cmd/deckhand-elevated-helper'
    )
} finally {
    Remove-Item -LiteralPath $helperSyso -Force -ErrorAction SilentlyContinue
}

Get-ChildItem -LiteralPath $OutputDir -File |
    Where-Object { $_.Name -in @('deckhand-sidecar.exe', 'deckhand-elevated-helper.exe') } |
    Select-Object Name, Length, LastWriteTime
