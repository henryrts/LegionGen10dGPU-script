# Lenovo Legion GPU mode scripts

For Lenovo Legion Pro 5 16IAX10H (`83LU`), but can be used for all Legion 5 Gen 10 machines.

## Launchers

- `Start-iGPU-Fast.cmd` — switches Hybrid → Hybrid-iGPU, then sleeps.
- `Start-Hybrid.cmd` — switches Hybrid-iGPU → Hybrid without sleeping.

Both launchers request administrator rights immediately and then run the matching readable PowerShell file.

## Usage

1. Close Legion Space and Lenovo Legion Toolkit.
2. Disconnect any display connected through an NVIDIA-wired port.
3. Double-click `Start-iGPU-Fast.cmd`.
4. Approve the single UAC prompt.
5. Wake the laptop normally.
6. Double-click `Start-Hybrid.cmd` when you want the RTX back; that direction does not sleep.

## Transparency and security

There is no `-EncodedCommand`, Base64 payload, `Invoke-Expression`, downloaded code, or network access.

Each `.cmd` launcher performs only these steps:

1. Defines explicit paths to Windows' own `fltmc.exe` and `powershell.exe` under `%SystemRoot%\System32`, preventing executable lookup from the current folder.
2. Runs `fltmc.exe` with its output hidden to check whether the launcher already has administrator rights.
3. If it is not elevated, asks Windows to restart that same `.cmd` file through `Start-Process -Verb RunAs`.
4. Runs the matching `.ps1` file from the same folder.

The launchers use `-ExecutionPolicy Bypass` only for the PowerShell process they start. It does not modify the machine or user execution-policy setting. This is included because Windows can otherwise block unsigned scripts extracted from a downloaded ZIP.

The PowerShell scripts are plain text. They only:

- access Lenovo's local `root/WMI:LENOVO_GAMEZONE_DATA` interface;
- read or set `IGPUModeStatus`;
- send Lenovo's local `NotifyDGPUStatus` notification;
- inspect locally present display adapters;
- request normal Windows sleep with the hibernate argument explicitly set to `false` in the iGPU script;
- print the detected state and result.

## Optional tuning

The iGPU PowerShell script accepts:

```powershell
-PreSleepDelayMilliseconds 1000
-ResumeCheckTimeoutSeconds 3
```

If the 1-second firmware delay ever proves unreliable, increase it to `2000` or restore `5000`.

## Administrator rights

Elevation is kept for reliability because the Lenovo WMI provider may enforce its own method permissions, and the sleep request uses a Windows power-management API. Reading the status alone generally needs less access than changing the mode. The exact Lenovo provider permission policy is firmware/provider-specific.
