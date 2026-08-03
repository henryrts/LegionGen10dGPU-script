# Lenovo Legion Gen 10 dGPU switch — Linux v1

Experimental Linux port of the Windows `LegionGen10dGPU-script` for Lenovo
Legion machines exposing the GameZone WMI interface, including the Legion Pro 5
16IAX10H (`83LU`).

## What it does

The kernel module calls the same Lenovo firmware methods as the Windows script:

- method 63: `IsSupportIGPUMode`
- method 64: `GetIGPUModeStatus`
- method 65: `SetIGPUModeStatus`
- method 66: `NotifyDGPUStatus`

The Bash front end then reproduces the known sequence:

```text
Hybrid → Hybrid-iGPU → suspend → resume → RTX disconnected
Hybrid-iGPU → Hybrid → RTX reconnects (no suspend)
```

Everything is plain C and Bash. There is no encoded command, downloaded code,
telemetry, or network access.

## Important status

This implementation was compiled against Linux 6.12 headers and its shell files
were syntax-checked. It has **not yet been hardware-tested on an 83LU under
Linux**, so treat the first run as experimental. Firmware and NVIDIA-driver
behavior may vary.

## Install

Install build tools and headers matching the running kernel first.

```bash
# Debian / Ubuntu
sudo apt install build-essential linux-headers-$(uname -r)

# Fedora
sudo dnf install gcc make kernel-devel-$(uname -r)

# Arch (use the matching package for linux-lts, linux-zen, etc. when applicable)
sudo pacman -S --needed base-devel linux-headers
```

Then, from this directory:

```bash
sudo ./install.sh
```

The installer performs only local actions: compile, copy the module and command,
run `depmod`, and load the module.

## Use

Inspect first:

```bash
sudo legion-gpu-mode status
```

Switch to Hybrid-iGPU and perform the required suspend/resume:

```bash
sudo legion-gpu-mode igpu
```

Wake the laptop normally. The command resumes and verifies whether the NVIDIA
PCI display device disappeared.

Restore Hybrid mode without suspending:

```bash
sudo legion-gpu-mode hybrid
```

Diagnostic mode, which sets mode 1 but deliberately does not suspend:

```bash
sudo legion-gpu-mode igpu --no-suspend
```

`--force` bypasses safety checks for NVIDIA users and NVIDIA-driven external
displays. Do not use it casually.

## Safety checks

Before entering Hybrid-iGPU, the command normally refuses to continue when:

- no Intel or AMD integrated display GPU is present;
- an external display is detected on an NVIDIA DRM connector;
- a process has an NVIDIA or NVIDIA-owned DRM device node open;
- neither `fuser` nor `lsof` is available to perform that process check.

It never kills applications and never unloads the NVIDIA driver automatically.
If the suspend request fails after changing the mode, the command attempts to
restore the previous Lenovo mode before exiting.

## Kernel WMI API note

The bridge currently uses Linux's exported GUID-based WMI API so it can call the
GameZone firmware interface without claiming the same WMI device that the
in-tree `lenovo_wmi_gamezone` driver may already manage. That API is deprecated
upstream, so future kernels may eventually require a different coexistence
mechanism.

## Secure Boot

Locally built kernel modules are commonly rejected when Secure Boot is enabled
unless they are signed with a trusted Machine Owner Key. The installer does not
change Secure Boot or enroll keys. Inspect failures with:

```bash
sudo dmesg | tail -n 80
```

## Kernel updates

This version is intentionally simple and does not register with DKMS. Rerun
`sudo ./install.sh` after booting a newly installed kernel.

## Direct interface

After the module is loaded:

```bash
cat /sys/module/legion_gpu_mode/parameters/support
cat /sys/module/legion_gpu_mode/parameters/mode

# Root only:
echo 1 | sudo tee /sys/module/legion_gpu_mode/parameters/mode
echo 1 | sudo tee /sys/module/legion_gpu_mode/parameters/notify_dgpu
```

Mode values are `0=Hybrid`, `1=Hybrid-iGPU`, `2=Auto`, and `3=dGPU`.

## Uninstall

```bash
sudo ./uninstall.sh
```

## Troubleshooting data

When reporting a result, collect:

```bash
uname -a
cat /sys/class/dmi/id/product_name
cat /sys/class/dmi/id/product_version
sudo legion-gpu-mode status
sudo dmesg | grep -iE 'legion_gpu_mode|wmi|nvidia' | tail -n 100
```

## Technical references

- Linux kernel GameZone documentation: <https://docs.kernel.org/wmi/devices/lenovo-wmi-gamezone.html>
- Linux WMI driver API: <https://docs.kernel.org/driver-api/wmi.html>
- Original Windows repository: <https://github.com/henryrts/LegionGen10dGPU-script>