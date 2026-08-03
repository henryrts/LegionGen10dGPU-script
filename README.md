# Lenovo Legion GPU mode scripts

For Lenovo Legion Pro 5 16IAX10H (`83LU`), but can be used for all Legion 5 Gen 10 machines

## Launchers

Recommended, with no initial console window:

- `Start-iGPU-Fast.cmd` — switches Hybrid → Hybrid-iGPU, then sleeps.
- `Start-Hybrid.cmd` — switches Hybrid-iGPU → Hybrid without sleeping.

All launchers request administrator rights immediately and launch the PowerShell process directly.

## Usage

1. Close Legion Space and Lenovo Legion Toolkit.
2. Disconnect any display connected through an NVIDIA-wired port.
3. Double-click `Start-iGPU-Fast.vbs`.
4. Approve the single UAC prompt.
5. Wake the laptop normally.
6. Double-click `Start-Hybrid.vbs` when you want the RTX back; that direction does not sleep.

## Optional tuning

The iGPU PowerShell script accepts:

```powershell
-PreSleepDelayMilliseconds 1000
-ResumeCheckTimeoutSeconds 3
```

If the 1-second firmware delay ever proves unreliable, increase it to `2000` or restore `5000`.

## Administrator rights

Elevation is kept for reliability because the Lenovo WMI provider may enforce its own method permissions, and Windows sleep uses a power-management privilege. Reading the status alone generally needs less access than changing the mode. The exact Lenovo provider permission policy is firmware/provider-specific.
