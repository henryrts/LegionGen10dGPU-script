#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
	command -v sudo >/dev/null 2>&1 || { echo "Run as root." >&2; exit 1; }
	exec sudo -- "$0" "$@"
fi

modprobe -r legion_gpu_mode 2>/dev/null || true
rm -f "/lib/modules/$(uname -r)/extra/legion_gpu_mode.ko"
rm -f /usr/local/sbin/legion-gpu-mode
depmod -a
printf 'Removed legion_gpu_mode for kernel %s.\n' "$(uname -r)"
