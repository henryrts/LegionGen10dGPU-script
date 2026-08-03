# Lenovo Legion Gen 10 dGPU switch — Linux v1

Experimental Linux port of the Windows `LegionGen10dGPU-script` for Lenovo
Legion machines exposing the GameZone WMI interface, including the Legion Pro 5
16IAX10H (`83LU`).

## Important status

This implementation compiles and its shell behavior has been tested with
simulated hardware. It has **not yet been hardware-tested on an 83LU under
Linux**, so treat the first real run as experimental. Firmware, suspend, and
NVIDIA-driver behavior may vary.

The expected sequence is:

```text
Hybrid → Hybrid-iGPU → suspend → resume → RTX disconnected
Hybrid-iGPU → Hybrid → RTX reconnects (no suspend)
```

Everything is plain C and Bash. There is no encoded command, downloaded code,
telemetry, or network access in the installed program.

## Get the source

Clone the repository and enter the Linux directory:

```bash
git clone https://github.com/henryrts/LegionGen10dGPU-script.git
cd LegionGen10dGPU-script/Linux
```

## CachyOS installed system

Install the build tools, Git, process-inspection tool, and headers matching the
running CachyOS kernel:

```bash
sudo pacman -Syu --needed base-devel git psmisc linux-cachyos-headers
```

Then verify that the running kernel has a matching build directory:

```bash
uname -r
ls -ld "/lib/modules/$(uname -r)/build"
```

If that path exists, install the bridge:

```bash
sudo ./install.sh
```

If you booted CachyOS's LTS kernel instead, install
`linux-cachyos-lts-headers` rather than `linux-cachyos-headers`.

## CachyOS live USB

A live USB can test the real Lenovo firmware without installing CachyOS, but
there is an extra limitation: CachyOS is rolling-release, and its official live
image does not necessarily contain headers matching the kernel currently
running from the ISO.

After booting the live desktop, connect to the internet, open Konsole, and run:

```bash
uname -r
ls -ld "/lib/modules/$(uname -r)/build"
```

- If the path exists, clone the repository and continue with `install.sh`.
- If the path does not exist, do **not** install the newest headers blindly and
  assume they match. A newer header package cannot build a module for the older
  kernel that is still running from the live ISO.

For that mismatch, use one of these options:

1. boot a newer CachyOS ISO whose kernel matches the repository headers;
2. install the exact matching archived CachyOS header package for `uname -r`;
3. use Fedora or Ubuntu Live for the hardware test instead.

The official CachyOS live package list includes the stable and LTS kernels but
not their header packages, so the missing-header case is expected on some ISO
releases.

## Other distributions

Install build tools and headers matching the running kernel first.

```bash
# Debian / Ubuntu
sudo apt install build-essential git psmisc linux-headers-$(uname -r)

# Fedora
sudo dnf install gcc make git psmisc kernel-devel-$(uname -r)

# Arch with the standard Arch kernel
sudo pacman -Syu --needed base-devel git psmisc linux-headers
```

Always verify before building:

```bash
ls -ld "/lib/modules/$(uname -r)/build"
```

Then, from the `Linux` directory:

```bash
sudo ./install.sh
```

The installer performs only local actions: compile, copy the module and command,
run `depmod`, and load the module.

## First test

Inspect the current state before changing anything:

```bash
sudo legion-gpu-mode status
```

Perform the safer no-suspend test first. This asks firmware to select
Hybrid-iGPU but deliberately does not suspend or disconnect the RTX:

```bash
sudo legion-gpu-mode igpu --no-suspend
```

Restore Hybrid immediately afterward:

```bash
sudo legion-gpu-mode hybrid
```

If both commands succeed and mode readback is correct, perform the real test:

```bash
sudo legion-gpu-mode igpu
```

The computer should suspend. Wake it normally. The command continues after
resume and reports whether the NVIDIA PCI display device disappeared.

Before leaving the live session or returning to Windows, restore Hybrid:

```bash
sudo legion-gpu-mode hybrid
sudo legion-gpu-mode status
```

Confirm that the reported Lenovo mode is `0 (Hybrid)`.

## Commands

```bash
sudo legion-gpu-mode status
sudo legion-gpu-mode igpu --no-suspend
sudo legion-gpu-mode igpu
sudo legion-gpu-mode hybrid
```

`--force` bypasses safety checks for active NVIDIA users and NVIDIA-driven
external displays. Do not use it for the first hardware test.

Modes reported by firmware are `0=Hybrid`, `1=Hybrid-iGPU`, `2=Auto`, and
`3=dGPU`.

## Safety checks

Before entering Hybrid-iGPU, the command normally refuses to continue when:

- no Intel or AMD integrated display GPU is present;
- an external display is detected on an NVIDIA DRM connector;
- a process has an NVIDIA or NVIDIA-owned DRM device node open;
- neither `fuser` nor `lsof` is available to perform that process check.

It never kills applications and never unloads the NVIDIA driver automatically.
If the suspend request fails after changing the mode, the command attempts to
restore the previous Lenovo mode before exiting.

## Secure Boot

Locally built kernel modules are commonly rejected when Secure Boot is enabled
unless they are signed with a trusted key. The installer does not disable Secure
Boot, enroll keys, or modify the boot configuration.

Inspect a module-load failure with:

```bash
sudo dmesg | tail -n 80
```

Save the Windows BitLocker or Device Encryption recovery key before changing
Secure Boot settings.

## Kernel WMI API note

The bridge currently uses Linux's exported GUID-based WMI API so it can call the
GameZone firmware interface without claiming the same WMI device that the
in-tree `lenovo_wmi_gamezone` driver may already manage. That API is deprecated
upstream, so future kernels may eventually require a different coexistence
mechanism.

## Kernel updates

This version intentionally does not register with DKMS. Rerun
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
- CachyOS live ISO package list: <https://github.com/CachyOS/CachyOS-Live-ISO/blob/master/archiso/packages_desktop.x86_64>
- CachyOS package archive: <https://archive.cachyos.org/archive/>
- Original Windows repository: <https://github.com/henryrts/LegionGen10dGPU-script>
