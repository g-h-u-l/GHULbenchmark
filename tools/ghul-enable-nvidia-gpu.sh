#!/usr/bin/env bash
# GHUL - Enable NVIDIA GPU for Nouveau (without sudo password)
# This script enables the NVIDIA GPU and loads Nouveau driver
# Requires: sudoers rule for passwordless execution

# Don't use strict mode - we want to handle errors gracefully
set -uo pipefail

export LANG=C
export LC_ALL=C

# Find NVIDIA GPU PCI device
find_nvidia_pci() {
  if ! command -v lspci >/dev/null 2>&1; then
    return 1
  fi
  
  local nvidia_pci
  nvidia_pci="$(lspci -nn | grep -iE '3D controller.*nvidia' | head -n1 | awk '{print $1}')"
  
  if [[ -z "$nvidia_pci" ]]; then
    return 1
  fi
  
  echo "$nvidia_pci"
}

# Enable GPU and load Nouveau
enable_nvidia_gpu() {
  local nvidia_pci
  nvidia_pci="$(find_nvidia_pci)"
  
  if [[ -z "$nvidia_pci" ]]; then
    echo "ERROR: NVIDIA GPU not found" >&2
    return 1
  fi
  
  local enable_file="/sys/bus/pci/devices/0000:${nvidia_pci}/enable"
  
  if [[ ! -f "$enable_file" ]]; then
    echo "ERROR: GPU enable file not found: $enable_file" >&2
    return 1
  fi
  
  # Check current state
  local current_state
  current_state="$(cat "$enable_file" 2>/dev/null || echo "0")"
  
  if [[ "$current_state" == "1" ]]; then
    echo "GPU already enabled"
    # Still try to load nouveau if not loaded
    modprobe nouveau 2>/dev/null || true
    return 0
  fi
  
  # Enable GPU (requires root)
  # Check if we're running as root
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (use sudo)" >&2
    echo "       sudo $0" >&2
    return 1
  fi
  
  # Enable GPU using tee to ensure proper permissions
  if echo "1" | tee "$enable_file" >/dev/null 2>&1; then
    echo "GPU enabled successfully"
    # Load nouveau driver
    modprobe nouveau 2>/dev/null || {
      echo "WARNING: Could not load nouveau module" >&2
      return 1
    }
    echo "Nouveau driver loaded"
    return 0
  else
    echo "ERROR: Failed to enable GPU" >&2
    return 1
  fi
}

# Main
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
GHUL - Enable NVIDIA GPU for Nouveau

This script enables the NVIDIA GPU and loads the Nouveau driver.
It requires root privileges, but can be configured to run without password
via sudoers.

Usage:
  sudo ./ghul-enable-nvidia-gpu.sh
  # Or configure sudoers for passwordless execution

To configure passwordless execution, add to /etc/sudoers.d/ghul-gpu:
  %wheel ALL=(ALL) NOPASSWD: /path/to/ghul-enable-nvidia-gpu.sh

Then users in the wheel group can run:
  sudo ./ghul-enable-nvidia-gpu.sh

EOF
  exit 0
fi

enable_nvidia_gpu

