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

        [string[]]$Arguments = @(),

        [string]$OutputPath
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $owners = @(Get-WindowsFileLockOwners -Path $OutputPath)
            if ($owners.Count -gt 0) {
                throw "$FilePath failed with exit code $LASTEXITCODE while writing $OutputPath.`nThe output file is locked by:`n$(Format-FileLockOwners -Owners $owners)"
            }
        }
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Get-WindowsFileLockOwners {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    if (-not ('Deckhand.Build.RestartManager' -as [type])) {
        $source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Deckhand.Build {
    public static class RestartManager {
        [StructLayout(LayoutKind.Sequential)]
        public struct RM_UNIQUE_PROCESS {
            public int dwProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
        }

        public enum RM_APP_TYPE {
            RmUnknownApp = 0,
            RmMainWindow = 1,
            RmOtherWindow = 2,
            RmService = 3,
            RmExplorer = 4,
            RmConsole = 5,
            RmCritical = 1000
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct RM_PROCESS_INFO {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
            public string strServiceShortName;
            public RM_APP_TYPE ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        public static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        public static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, IntPtr rgApplications, uint nServices, string[] rgsServiceNames);

        [DllImport("rstrtmgr.dll")]
        public static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

        [DllImport("rstrtmgr.dll")]
        public static extern int RmEndSession(uint pSessionHandle);
    }
}
'@
        try {
            Add-Type -TypeDefinition $source
        } catch {
            return @()
        }
    }

    [uint32]$session = 0
    $key = New-Object System.Text.StringBuilder 64
    $result = [Deckhand.Build.RestartManager]::RmStartSession([ref]$session, 0, $key)
    if ($result -ne 0) {
        return @()
    }

    try {
        $result = [Deckhand.Build.RestartManager]::RmRegisterResources(
            $session,
            1,
            [string[]]@((Resolve-Path -LiteralPath $Path).Path),
            0,
            [IntPtr]::Zero,
            0,
            $null
        )
        if ($result -ne 0) {
            return @()
        }

        [uint32]$needed = 0
        [uint32]$count = 0
        [uint32]$reasons = 0
        $empty = New-Object Deckhand.Build.RestartManager+RM_PROCESS_INFO[] 0
        $result = [Deckhand.Build.RestartManager]::RmGetList(
            $session,
            [ref]$needed,
            [ref]$count,
            $empty,
            [ref]$reasons
        )
        if ($result -ne 234 -or $needed -eq 0) {
            return @()
        }

        $count = $needed
        $buffer = New-Object Deckhand.Build.RestartManager+RM_PROCESS_INFO[] $count
        $result = [Deckhand.Build.RestartManager]::RmGetList(
            $session,
            [ref]$needed,
            [ref]$count,
            $buffer,
            [ref]$reasons
        )
        if ($result -ne 0) {
            return @()
        }

        $owners = @()
        for ($i = 0; $i -lt $count; $i++) {
            $entry = $buffer[$i]
            $ownerPid = $entry.Process.dwProcessId
            $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            $owners += [pscustomobject]@{
                Pid = $ownerPid
                AppName = $entry.strAppName
                Service = $entry.strServiceShortName
                Type = $entry.ApplicationType
                ProcessName = $process.ProcessName
                Path = $process.Path
            }
        }
        return $owners
    } finally {
        [void][Deckhand.Build.RestartManager]::RmEndSession($session)
    }
}

function Format-FileLockOwners {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Owners
    )

    return ($Owners | ForEach-Object {
        $name = $_.ProcessName
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = $_.AppName
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = 'unknown'
        }

        $parts = @("PID $($_.Pid)", $name, "type=$($_.Type)")
        if (-not [string]::IsNullOrWhiteSpace($_.Service)) {
            $parts += "service=$($_.Service)"
        }
        if (-not [string]::IsNullOrWhiteSpace($_.Path)) {
            $parts += "path=$($_.Path)"
        }
        "  - $($parts -join ' ')"
    }) -join [Environment]::NewLine
}

function Assert-OutputReplaceable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $owners = @(Get-WindowsFileLockOwners -Path $Path)
    if ($owners.Count -gt 0) {
        throw "Output file is locked: $Path`nLocked by:`n$(Format-FileLockOwners -Owners $owners)"
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

    Assert-OutputReplaceable -Path $sidecarOut
    Assert-OutputReplaceable -Path $helperOut

    Invoke-Checked $go @(
        '-C', $sidecarDir,
        'build',
        '-trimpath',
        '-ldflags', "-s -w -X main.Version=$Version",
        '-o', $sidecarOut,
        './cmd/deckhand-sidecar'
    ) -OutputPath $sidecarOut

    Invoke-Checked $go @(
        '-C', $sidecarDir,
        'build',
        '-trimpath',
        '-ldflags', "-s -w -X main.Version=$Version -H windowsgui",
        '-o', $helperOut,
        './cmd/deckhand-elevated-helper'
    ) -OutputPath $helperOut
} finally {
    Remove-Item -LiteralPath $helperSyso -Force -ErrorAction SilentlyContinue
}

Get-ChildItem -LiteralPath $OutputDir -File |
    Where-Object { $_.Name -in @('deckhand-sidecar.exe', 'deckhand-elevated-helper.exe') } |
    Select-Object Name, Length, LastWriteTime
