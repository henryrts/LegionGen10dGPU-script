#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(1, 60)]
    [int]$ReconnectWaitSeconds = 15,

    [ValidateRange(0, 60)]
    [int]$ResumeCheckTimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TargetMode = 0
$ReconnectRetryIntervalSeconds = 3

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdministrator {
    if (-not $PSCommandPath) {
        throw 'Save this script as a .ps1 file before running it.'
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ReconnectWaitSeconds $ReconnectWaitSeconds -ResumeCheckTimeoutSeconds $ResumeCheckTimeoutSeconds"

    Start-Process -FilePath $windowsPowerShell -Verb RunAs -ArgumentList $arguments | Out-Null
    exit
}

function Initialize-LenovoGameZone {
    try {
        $instance = Get-CimInstance -Namespace 'root/WMI' -ClassName 'LENOVO_GAMEZONE_DATA' -ErrorAction Stop |
            Select-Object -First 1

        if ($null -eq $instance) {
            throw 'LENOVO_GAMEZONE_DATA returned no instance.'
        }

        $script:LenovoBackend = 'CIM'
        $script:LenovoGameZone = $instance
        return
    }
    catch {
        $getWmiObject = Get-Command -Name Get-WmiObject -ErrorAction SilentlyContinue
        if ($null -eq $getWmiObject) {
            throw "Could not open Lenovo WMI interface root\WMI:LENOVO_GAMEZONE_DATA. CIM error: $($_.Exception.Message)"
        }

        $instance = Get-WmiObject -Namespace 'root\WMI' -Class 'LENOVO_GAMEZONE_DATA' -ErrorAction Stop |
            Select-Object -First 1

        if ($null -eq $instance) {
            throw 'LENOVO_GAMEZONE_DATA returned no instance.'
        }

        $script:LenovoBackend = 'WMI'
        $script:LenovoGameZone = $instance
    }
}

function Get-LegionIGPUModeStatus {
    if ($script:LenovoBackend -eq 'CIM') {
        $result = Invoke-CimMethod -InputObject $script:LenovoGameZone -MethodName 'GetIGPUModeStatus' -ErrorAction Stop
    }
    else {
        $result = $script:LenovoGameZone.GetIGPUModeStatus()
    }

    if ($null -eq $result -or $null -eq $result.Data) {
        throw 'GetIGPUModeStatus did not return a Data value.'
    }

    return [int]$result.Data
}

function Set-LegionIGPUModeStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 3)]
        [int]$Mode
    )

    if ($script:LenovoBackend -eq 'CIM') {
        $null = Invoke-CimMethod -InputObject $script:LenovoGameZone -MethodName 'SetIGPUModeStatus' `
            -Arguments @{ mode = [uint32]$Mode } -ErrorAction Stop
    }
    else {
        $null = $script:LenovoGameZone.SetIGPUModeStatus($Mode)
    }
}

function Send-LegionDGPUStatusNotification {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(0, 1)]
        [int]$Status
    )

    if ($script:LenovoBackend -eq 'CIM') {
        $null = Invoke-CimMethod -InputObject $script:LenovoGameZone -MethodName 'NotifyDGPUStatus' `
            -Arguments @{ Status = [uint32]$Status } -ErrorAction Stop
    }
    else {
        $null = $script:LenovoGameZone.NotifyDGPUStatus($Status)
    }
}

function Test-NvidiaPresent {
    try {
        $devices = @(Get-PnpDevice -PresentOnly -Class Display -ErrorAction Stop |
            Where-Object { $_.FriendlyName -match 'NVIDIA|GeForce' })
        return $devices.Count -gt 0
    }
    catch {
        $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass='Display'" -ErrorAction Stop |
            Where-Object {
                $_.Name -match 'NVIDIA|GeForce' -and
                ($null -eq $_.ConfigManagerErrorCode -or $_.ConfigManagerErrorCode -eq 0)
            })
        return $devices.Count -gt 0
    }
}

function Wait-NvidiaPresent {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 60)]
        [int]$TimeoutSeconds
    )

    if (Test-NvidiaPresent) {
        return $true
    }

    if ($TimeoutSeconds -eq 0) {
        return $false
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        if (Test-NvidiaPresent) {
            return $true
        }
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Invoke-PnpHardwareScan {
    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'

    if (-not (Test-Path -LiteralPath $pnputil)) {
        Write-Warning "Windows PnP utility was not found at $pnputil."
        return
    }

    Write-Host 'Requesting a Windows Plug and Play hardware scan...'
    & $pnputil /scan-devices | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pnputil.exe /scan-devices returned exit code $LASTEXITCODE."
    }
}

function Request-DGPUReconnect {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int]$Attempt
    )

    Write-Host "dGPU reconnect attempt $Attempt..." -ForegroundColor Cyan

    try {
        Set-LegionIGPUModeStatus -Mode $TargetMode
        Write-Host 'Reasserted Lenovo Hybrid mode (value 0).'
    }
    catch {
        Write-Warning "Could not reassert Hybrid mode: $($_.Exception.Message)"
    }

    try {
        # Experimental: status 1 is retained from the previous PR for this controlled test.
        Send-LegionDGPUStatusNotification -Status 1
        Write-Host 'Sent experimental NotifyDGPUStatus(1).'
    }
    catch {
        Write-Warning "NotifyDGPUStatus(1) failed: $($_.Exception.Message)"
    }

    Invoke-PnpHardwareScan
}

function Invoke-SystemSleep {
    if (-not ('LegionGpuMode.NativePower' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;

namespace LegionGpuMode
{
    public static class NativePower
    {
        [DllImport("powrprof.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetSuspendState(
            [MarshalAs(UnmanagedType.Bool)] bool hibernate,
            [MarshalAs(UnmanagedType.Bool)] bool forceCritical,
            [MarshalAs(UnmanagedType.Bool)] bool disableWakeEvent);
    }
}
'@
    }

    Write-Host 'Entering normal Windows sleep now...' -ForegroundColor Yellow
    $succeeded = [LegionGpuMode.NativePower]::SetSuspendState($false, $false, $false)
    if (-not $succeeded) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Windows sleep request failed. Win32 error: $errorCode"
    }
}

function Show-PresentDisplayAdapters {
    Write-Host ''
    Write-Host 'Present display adapters:' -ForegroundColor Cyan

    try {
        $devices = @(Get-PnpDevice -PresentOnly -Class Display -ErrorAction Stop |
            Select-Object FriendlyName, Status, Problem)

        if ($devices.Count -eq 0) {
            Write-Warning 'No present display adapters were returned.'
            return
        }

        $devices | Format-Table -AutoSize | Out-Host
    }
    catch {
        Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Select-Object Name, Status, PNPDeviceID |
            Format-Table -AutoSize |
            Out-Host
    }
}

try {
    if (-not (Test-IsAdministrator)) {
        Restart-AsAdministrator
    }

    Write-Host 'Lenovo Legion GPU mode switch' -ForegroundColor Cyan
    Write-Host 'Target: Hybrid (value 0)'
    Write-Host 'Fallback: one normal sleep/resume cycle if awake reconnect attempts fail.' -ForegroundColor Yellow
    Write-Host 'Close Legion Space and Lenovo Legion Toolkit before continuing.' -ForegroundColor DarkYellow
    Write-Host ''

    Initialize-LenovoGameZone

    $currentMode = Get-LegionIGPUModeStatus
    Write-Host "Current Lenovo iGPU mode value: $currentMode"

    if ($currentMode -ne $TargetMode) {
        Write-Host 'Setting Lenovo mode to Hybrid...'
        Set-LegionIGPUModeStatus -Mode $TargetMode

        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 500
            $currentMode = Get-LegionIGPUModeStatus
        } while ($currentMode -ne $TargetMode -and (Get-Date) -lt $deadline)
    }

    if ($currentMode -ne $TargetMode) {
        throw "Lenovo did not accept Hybrid mode. Current value is $currentMode; expected 0."
    }

    Write-Host 'Hybrid mode verified (value 0).' -ForegroundColor Green

    $usedSleepFallback = $false
    $nvidiaPresent = Test-NvidiaPresent

    if (-not $nvidiaPresent) {
        Write-Host "NVIDIA is still disconnected. Retrying awake for up to $ReconnectWaitSeconds seconds..." -ForegroundColor Cyan

        $reconnectDeadline = (Get-Date).AddSeconds($ReconnectWaitSeconds)
        $attempt = 0

        do {
            $attempt++
            Request-DGPUReconnect -Attempt $attempt

            $attemptDeadline = (Get-Date).AddSeconds($ReconnectRetryIntervalSeconds)
            if ($attemptDeadline -gt $reconnectDeadline) {
                $attemptDeadline = $reconnectDeadline
            }

            do {
                Start-Sleep -Milliseconds 500
                $nvidiaPresent = Test-NvidiaPresent
            } while (-not $nvidiaPresent -and (Get-Date) -lt $attemptDeadline)
        } while (-not $nvidiaPresent -and (Get-Date) -lt $reconnectDeadline)
    }

    if (-not $nvidiaPresent) {
        $usedSleepFallback = $true
        Write-Host ''
        Write-Host 'Awake reconnect attempts failed. Testing one sleep/resume cycle...' -ForegroundColor Yellow
        Write-Host 'Wake the laptop normally after it enters sleep.' -ForegroundColor Yellow

        # Reassert Hybrid immediately before sleeping so firmware enters the power transition with mode 0 selected.
        Set-LegionIGPUModeStatus -Mode $TargetMode
        Start-Sleep -Milliseconds 1000
        Invoke-SystemSleep

        Write-Host 'Windows resumed. Reopening Lenovo WMI and checking NVIDIA...' -ForegroundColor Cyan
        Initialize-LenovoGameZone

        $modeAfterResume = Get-LegionIGPUModeStatus
        Write-Host "Lenovo mode after resume: $modeAfterResume"

        if ($modeAfterResume -ne $TargetMode) {
            Write-Warning "Lenovo mode changed during sleep. Reapplying Hybrid (value 0)."
            Set-LegionIGPUModeStatus -Mode $TargetMode
        }

        Invoke-PnpHardwareScan
        $nvidiaPresent = Wait-NvidiaPresent -TimeoutSeconds $ResumeCheckTimeoutSeconds
    }

    Show-PresentDisplayAdapters

    if ($nvidiaPresent) {
        if ($usedSleepFallback) {
            Write-Host 'Success: NVIDIA returned after the Hybrid sleep/resume fallback.' -ForegroundColor Green
        }
        else {
            Write-Host 'Success: Hybrid mode is active and NVIDIA returned without sleep.' -ForegroundColor Green
        }
        exit 0
    }

    Write-Warning 'Hybrid mode is selected, but NVIDIA did not return even after one sleep/resume cycle. Legion Space likely performs an additional Lenovo-specific operation that this script does not yet reproduce.'
    exit 2
}
catch {
    Write-Error $_.Exception.Message
    Write-Host ''
    Write-Host 'Hybrid mode was not confirmed.' -ForegroundColor Red
    exit 1
}
