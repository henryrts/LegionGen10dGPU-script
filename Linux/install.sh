#!/usr/bin/env bash
# Builds and installs the transparent Legion GPU-mode Linux bridge.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KERNEL_RELEASE=$(uname -r)
KERNEL_BUILD="/lib/modules/${KERNEL_RELEASE}/build"
MODULE_DEST="/lib/modules/${KERNEL_RELEASE}/extra/legion_gpu_mode.ko"
COMMAND_DEST="/usr/local/sbin/legion-gpu-mode"

log() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
	command -v sudo >/dev/null 2>&1 || die "Run this installer as root."
	exec sudo -- "$0" "$@"
fi

[[ $(uname -s) == Linux ]] || die "This installer only supports Linux."
command -v make >/dev/null 2>&1 || die "make is missing. Install your distribution's build tools."
[[ -d ${KERNEL_BUILD} ]] || {
	cat >&2 <<MSG
Error: Kernel headers for ${KERNEL_RELEASE} are missing.

Examples:
  Debian/Ubuntu: sudo apt install build-essential linux-headers-\$(uname -r)
  Fedora:        sudo dnf install gcc make kernel-devel-\$(uname -r)
  Arch:          sudo pacman -S --needed base-devel linux-headers

Use the header package matching your installed kernel, then rerun this script.
MSG
	exit 1
}

log "Building legion_gpu_mode for ${KERNEL_RELEASE}..."
make -C "${SCRIPT_DIR}" clean >/dev/null 2>&1 || true
make -C "${SCRIPT_DIR}"

install -D -m 0644 "${SCRIPT_DIR}/legion_gpu_mode.ko" "${MODULE_DEST}"
install -D -m 0755 "${SCRIPT_DIR}/legion-gpu-mode" "${COMMAND_DEST}"
depmod -a "${KERNEL_RELEASE}"

if lsmod | awk '{print $1}' | grep -qx legion_gpu_mode; then
	modprobe -r legion_gpu_mode
fi

if ! modprobe legion_gpu_mode; then
	cat >&2 <<'MSG'
The module was installed but could not be loaded.
Inspect the exact reason with:
  sudo dmesg | tail -n 80

If Secure Boot reports "Key was rejected by service", sign the module with a
Machine Owner Key or disable Secure Boot. This installer does not modify Secure
Boot settings.
MSG
	exit 1
fi

log "Installed successfully."
log "Run: sudo legion-gpu-mode status"
log "Note: rerun install.sh after installing a new kernel."
