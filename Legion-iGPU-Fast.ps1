#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(0, 5000)]
    [int]$PreSleepDelayMilliseconds = 1000,

    [ValidateRange(0, 15)]
    [int]$ResumeCheckTimeoutSeconds = 3,

    [switch]$NoSleep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TargetMode = 1
$TargetModeName = 'Hybrid-iGPU'
$ExpectedNvidiaPresentAfterResume = $false

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
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -PreSleepDelayMilliseconds $PreSleepDelayMilliseconds -ResumeCheckTimeoutSeconds $ResumeCheckTimeoutSeconds"
    if ($NoSleep) {
        $arguments += ' -NoSleep'
    }

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
            throw "Could not open Lenovo WMI interface root\\WMI:LENOVO_GAMEZONE_DATA. CIM error: $($_.Exception.Message)"
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

function Get-ModeName {
    param([int]$Mode)

    switch ($Mode) {
        0 { return 'Hybrid / Default' }
        1 { return 'Hybrid-iGPU / iGPU-only request' }
        2 { return 'Auto' }
        3 { return 'dGPU mode' }
        default { return "Unknown ($Mode)" }
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

    Write-Host 'Entering Windows sleep now...' -ForegroundColor Yellow
    $succeeded = [LegionGpuMode.NativePower]::SetSuspendState($false, $false, $false)
    if (-not $succeeded) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Windows sleep request failed. Win32 error: $errorCode"
    }
}

try {
    if (-not (Test-IsAdministrator)) {
        Restart-AsAdministrator
    }

    Write-Host 'Lenovo Legion GPU mode switch' -ForegroundColor Cyan
    Write-Host "Target: $TargetModeName (value $TargetMode)"
    Write-Host 'Close Legion Space and Lenovo Legion Toolkit before continuing.' -ForegroundColor DarkYellow
    Write-Host ''

    Initialize-LenovoGameZone

    $currentMode = Get-LegionIGPUModeStatus
    Write-Host ("Current Lenovo mode: {0} (value {1})" -f (Get-ModeName $currentMode), $currentMode)

    if ($currentMode -eq $TargetMode -and -not (Test-NvidiaPresent)) {
        Write-Host 'Already in Hybrid-iGPU mode and NVIDIA is already disconnected.' -ForegroundColor Green
        Show-PresentDisplayAdapters
        exit 0
    }

    if ($currentMode -ne $TargetMode) {
        Write-Host "Setting Lenovo mode to $TargetModeName..."
        Set-LegionIGPUModeStatus -Mode $TargetMode

        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 500
            $currentMode = Get-LegionIGPUModeStatus
        } while ($currentMode -ne $TargetMode -and (Get-Date) -lt $deadline)
    }

    if ($currentMode -ne $TargetMode) {
        throw "Lenovo did not accept the requested mode. Current value is $currentMode; expected $TargetMode."
    }

    Write-Host ("Lenovo mode verified: {0} (value {1})" -f (Get-ModeName $currentMode), $currentMode) -ForegroundColor Green

    if ($PreSleepDelayMilliseconds -gt 0) {
        Write-Host "Waiting $PreSleepDelayMilliseconds ms for Lenovo firmware..."
        Start-Sleep -Milliseconds $PreSleepDelayMilliseconds
    }

    $nvidiaPresentBeforeSleep = Test-NvidiaPresent
    $notificationValue = 0
    if ($nvidiaPresentBeforeSleep) {
        $notificationValue = 1
    }

    Write-Host "NVIDIA physically present before sleep: $nvidiaPresentBeforeSleep"
    try {
        Send-LegionDGPUStatusNotification -Status $notificationValue
        Write-Host "Sent NotifyDGPUStatus($notificationValue)."
    }
    catch {
        Write-Warning "NotifyDGPUStatus failed, but the mode was set successfully: $($_.Exception.Message)"
    }

    if ($NoSleep) {
        Write-Host 'NoSleep was requested; not suspending Windows.' -ForegroundColor Yellow
        Show-PresentDisplayAdapters
        exit 0
    }

    Invoke-SystemSleep

    Write-Host 'Windows resumed. Checking the GPU immediately...' -ForegroundColor Cyan

    $modeAfterResume = Get-LegionIGPUModeStatus
    $nvidiaPresentAfterResume = Test-NvidiaPresent

    if ($nvidiaPresentAfterResume -and $ResumeCheckTimeoutSeconds -gt 0) {
        $resumeDeadline = (Get-Date).AddSeconds($ResumeCheckTimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 250
            $nvidiaPresentAfterResume = Test-NvidiaPresent
        } while ($nvidiaPresentAfterResume -and (Get-Date) -lt $resumeDeadline)
    }

    Write-Host ("Lenovo mode after resume: {0} (value {1})" -f (Get-ModeName $modeAfterResume), $modeAfterResume)
    Write-Host "NVIDIA physically present after resume: $nvidiaPresentAfterResume"
    Show-PresentDisplayAdapters

    if ($nvidiaPresentAfterResume -eq $ExpectedNvidiaPresentAfterResume) {
        Write-Host 'Success: NVIDIA is absent from the present-device list.' -ForegroundColor Green
        exit 0
    }

    Write-Warning 'The Lenovo mode is set to Hybrid-iGPU, but NVIDIA is still present. Disconnect NVIDIA-wired external displays, close GPU-using apps, and run the script again.'
    exit 2
}
catch {
    Write-Error $_.Exception.Message
    Write-Host ''
    Write-Host 'No GPU mode change was reported as successful.' -ForegroundColor Red
    exit 1
}
