#!/usr/bin/env bash
set -euo pipefail

# GHUL Prep: Make any Arch-based system "gaming ready" using pacman only.
# - User mode: Checks what's installed, shows missing packages
# - Root mode: Automatically installs missing packages
# - Enables multilib automatically (optional) for lib32 Steam/Proton deps
# - Ensures stock + LTS kernels + headers for predictable NVIDIA DKMS builds (optional)
# - Detects GPU vendor and installs matching Vulkan/userspace packages
# - Optional "--full-heroic": installs a "kitchen sink" set of gaming-related packages
#   strictly from pacman repos; packages missing from enabled repos are skipped.

export LANG=C
export LC_ALL=C

SCRIPT_NAME="ghul-prep.sh"

# Color helpers
green() { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
red() { printf '\e[31m%s\e[0m\n' "$*"; }

usage() {
  cat <<'EOF'
GHUL Prep - Arch gaming readiness bootstrap (pacman-only)

This script prepares any Arch-based system for Linux gaming by installing
the essential gaming stack and tools. It works in two modes:

  User mode (default): Checks what's installed and shows what's missing
  Root mode (sudo):    Automatically installs missing packages

Usage:
  ./ghul-prep.sh [options]              # User mode: check only
  sudo ./ghul-prep.sh [options]          # Root mode: install missing packages

Options:
  -h, --help        Show this help and exit
  --no-syu          Skip full system upgrade (pacman -Syu) in root mode
  --no-multilib     Do not auto-enable [multilib] in /etc/pacman.conf
  --no-kernels      Do not install stock+LTS kernels and headers
  --no-vendor       Do not install vendor-specific GPU packages
  --full-heroic     Install the "kitchen sink" gaming stack (pacman-only).
                    Skips packages not found in enabled repos (no AUR).

What gets installed (root mode):
  1) Enables [multilib] (required for lib32 packages like Steam/Proton) unless --no-multilib
  2) Runs pacman -Syu unless --no-syu
  3) Installs stock + LTS kernels and headers unless --no-kernels:
       linux, linux-headers, linux-lts, linux-lts-headers
  4) Installs a common gaming stack:
       steam, mangohud, gamescope, gamemode, vulkan tools, mesa utils, etc.
  5) Detects GPU vendor (NVIDIA/AMD/Intel) and installs matching Vulkan/userspace bits
     unless --no-vendor
  6) If --full-heroic is set, installs additional "everything-you-might-need" packages
     from pacman repos only (best-effort, skips unavailable pkgs).

Notes:
  - NVIDIA DKMS requires: dkms + nvidia-dkms + matching kernel headers.
  - Steam/Proton typically needs multilib lib32 packages.
  - Run with sudo to actually install packages, otherwise it only checks.
EOF
}

die() { echo "[$SCRIPT_NAME] ERROR: $*" >&2; exit 1; }
log() { echo "[$SCRIPT_NAME] $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

pkg_exists() {
  # Checks if a package exists in enabled pacman repositories
  pacman -Si "$1" >/dev/null 2>&1
}

multilib_enabled() {
  # True if /etc/pacman.conf contains an enabled [multilib] section (not commented out)
  grep -Eq '^[[:space:]]*\[multilib\][[:space:]]*$' /etc/pacman.conf
}

enable_multilib() {
  if multilib_enabled; then
    log "multilib already enabled."
    return 0
  fi

  log "Enabling [multilib] in /etc/pacman.conf (creating backup first)..."
  cp -a /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%Y%m%d-%H%M%S)"

  # Uncomment the [multilib] section and its Include line if present but commented.
  sed -i \
    -e 's/^[[:space:]]*#[[:space:]]*\[multilib\][[:space:]]*$/[multilib]/' \
    -e 's/^[[:space:]]*#[[:space:]]*Include[[:space:]]*=[[:space:]]*\/etc\/pacman\.d\/mirrorlist[[:space:]]*$/Include = \/etc\/pacman.d\/mirrorlist/' \
    /etc/pacman.conf

  if ! multilib_enabled; then
    die "Failed to enable multilib automatically. Please enable it manually in /etc/pacman.conf."
  fi

  log "Refreshing package databases (pacman -Sy) after enabling multilib..."
  pacman -Sy --noconfirm
}

detect_gpu_vendor() {
  # Returns: nvidia | amd | intel | unknown
  if ! command -v lspci >/dev/null 2>&1; then
    echo "unknown"
    return
  fi

  local vga
  vga="$(lspci -nn | grep -Ei 'VGA compatible controller|3D controller' || true)"

  if echo "$vga" | grep -qi nvidia; then
    echo "nvidia"
  elif echo "$vga" | grep -Eqi 'AMD|ATI'; then
    echo "amd"
  elif echo "$vga" | grep -qi intel; then
    echo "intel"
  else
    echo "unknown"
  fi
}

# ---------- User mode: check packages -----------------------------------------

check_pkgs_user_mode() {
  local category="$1"
  shift
  local -a pkgs=("$@")

  local missing_count=0
  local -a missing=()

  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then
      printf "  [\e[32m✓\e[0m] %s\n" "$p"
    else
      if pkg_exists "$p"; then
        printf "  [\e[31m \e[0m] %s\n" "$p"
        missing_count=1
        missing+=("$p")
      else
        printf "  [\e[33m?\e[0m] %s (not in enabled repos)\n" "$p"
      fi
    fi
  done

  if [[ $missing_count -eq 1 ]]; then
    return 1
  fi
  return 0
}

check_all_user_mode() {
  echo "[*] Checking gaming packages (user mode, no automatic install):"
  echo

  local any_missing=0

  # Core packages
  echo "Core packages:"
  if ! check_pkgs_user_mode "core" "${CORE_PKGS[@]}"; then
    any_missing=1
  fi
  echo

  # Kernels
  if [[ "$DO_KERNELS" -eq 1 ]]; then
    echo "Kernels and headers:"
    if ! check_pkgs_user_mode "kernels" "${KERNEL_PKGS[@]}"; then
      any_missing=1
    fi
    echo
  fi

  # Gaming packages
  echo "Gaming packages:"
  if ! check_pkgs_user_mode "gaming" "${GAMING_PKGS[@]}"; then
    any_missing=1
  fi
  echo

  # Vulkan layers
  echo "Vulkan/Mesa layers:"
  if ! check_pkgs_user_mode "vulkan" "${VULKAN_LAYERS[@]}"; then
    any_missing=1
  fi
  echo

  # Vendor packages
  if [[ "$DO_VENDOR" -eq 1 ]]; then
    local gpu
    gpu="$(detect_gpu_vendor)"
    echo "GPU vendor-specific packages (detected: $gpu):"
    case "$gpu" in
      nvidia)
        if ! check_pkgs_user_mode "nvidia" "${NVIDIA_PKGS[@]}"; then
          any_missing=1
        fi
        ;;
      amd)
        if ! check_pkgs_user_mode "amd" "${AMD_PKGS[@]}"; then
          any_missing=1
        fi
        ;;
      intel)
        if ! check_pkgs_user_mode "intel" "${INTEL_PKGS[@]}"; then
          any_missing=1
        fi
        ;;
      *)
        echo "  GPU vendor unknown, skipping vendor-specific packages."
        ;;
    esac
    echo
  fi

  # Full heroic
  if [[ "$DO_FULL_HEROIC" -eq 1 ]]; then
    echo "Full Heroic mode packages:"
    if ! check_pkgs_user_mode "heroic" "${FULL_HEROIC_PKGS[@]}"; then
      any_missing=1
    fi
    echo
  fi

  if [[ $any_missing -eq 1 ]]; then
    yellow "[!] Some packages are missing."
    echo "    To install missing packages, run this script with sudo:"
    echo
    echo "      sudo ./ghul-prep.sh"
    echo
  else
    green "[✓] All checked packages are already installed."
    echo
  fi
}

# ---------- Root mode: install packages ---------------------------------------

install_pkgs_root_mode() {
  local category="$1"
  shift
  local -a pkgs=("$@")

  local -a missing=()

  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then
      printf "  [\e[32m✓\e[0m] %s\n" "$p"
    else
      if pkg_exists "$p"; then
        printf "  [ ] %s  → will install\n" "$p"
        missing+=("$p")
      else
        printf "  [\e[33m?\e[0m] %s (not in enabled repos, skipping)\n" "$p"
      fi
    fi
  done

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  log "Installing (${#missing[@]}) packages via pacman..."
  pacman -S --needed --noconfirm "${missing[@]}"
}

install_all_root_mode() {
  log "Installing packages (root mode, automatic install):"
  echo

  # Core packages
  log "Installing core packages..."
  install_pkgs_root_mode "core" "${CORE_PKGS[@]}"
  echo

  # Kernels
  if [[ "$DO_KERNELS" -eq 1 ]]; then
    log "Ensuring stock + LTS kernels and headers (for DKMS predictability)..."
    install_pkgs_root_mode "kernels" "${KERNEL_PKGS[@]}"
    echo
  fi

  # Gaming packages
  log "Installing gaming packages..."
  install_pkgs_root_mode "gaming" "${GAMING_PKGS[@]}"
  echo

  # Vulkan layers
  log "Installing Vulkan/Mesa layer packages..."
  install_pkgs_root_mode "vulkan" "${VULKAN_LAYERS[@]}"
  echo

  # Vendor packages
  if [[ "$DO_VENDOR" -eq 1 ]]; then
    local gpu
    gpu="$(detect_gpu_vendor)"
    log "Detected GPU vendor: $gpu"

    case "$gpu" in
      nvidia)
        log "Installing NVIDIA DKMS stack..."
        install_pkgs_root_mode "nvidia" "${NVIDIA_PKGS[@]}"
        log "Note: reboot recommended after NVIDIA DKMS install/updates."
        ;;
      amd)
        log "Installing AMD Vulkan packages..."
        install_pkgs_root_mode "amd" "${AMD_PKGS[@]}"
        ;;
      intel)
        log "Installing Intel Vulkan/media packages..."
        install_pkgs_root_mode "intel" "${INTEL_PKGS[@]}"
        ;;
      unknown)
        log "GPU vendor unknown. Skipping vendor-specific packages."
        ;;
    esac
    echo
  fi

  # Full heroic
  if [[ "$DO_FULL_HEROIC" -eq 1 ]]; then
    log "FULL HEROIC mode enabled: installing kitchen-sink gaming stack (pacman-only)."
    log "Packages not present in enabled repos will be skipped."
    install_pkgs_root_mode "heroic" "${FULL_HEROIC_PKGS[@]}"
    echo
  fi

  green "[✓] Package installation complete."
  log "If you installed/updated kernel(s) or NVIDIA DKMS: reboot is recommended."
}

# ---------- Main --------------------------------------------------------------

main() {
  local DO_SYU=1
  local DO_MULTILIB=1
  local DO_KERNELS=1
  local DO_VENDOR=1
  local DO_FULL_HEROIC=0

  while ((${#@})); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --no-syu) DO_SYU=0; shift ;;
      --no-multilib) DO_MULTILIB=0; shift ;;
      --no-kernels) DO_KERNELS=0; shift ;;
      --no-vendor) DO_VENDOR=0; shift ;;
      --full-heroic) DO_FULL_HEROIC=1; shift ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
  done

  need_cmd pacman

  # Define package arrays
  CORE_PKGS=(
    base-devel
    git
    curl
    wget
    unzip
    tar
    rsync
    jq
    pciutils
    usbutils
    lm_sensors
    mesa-utils
    vulkan-tools
  )

  KERNEL_PKGS=(
    linux
    linux-headers
    linux-lts
    linux-lts-headers
  )

  GAMING_PKGS=(
    steam
    mangohud
    gamescope
    gamemode
    lib32-gamemode
    vulkan-icd-loader
    lib32-vulkan-icd-loader
    pipewire
    pipewire-pulse
    wireplumber
    steam-devices
  )

  VULKAN_LAYERS=(
    vulkan-mesa-layers
    lib32-vulkan-mesa-layers
  )

  NVIDIA_PKGS=(
    dkms
    nvidia-dkms
    nvidia-utils
    lib32-nvidia-utils
    opencl-nvidia
  )

  AMD_PKGS=(
    mesa
    lib32-mesa
    vulkan-radeon
    lib32-vulkan-radeon
  )

  INTEL_PKGS=(
    mesa
    lib32-mesa
    vulkan-intel
    lib32-vulkan-intel
    intel-media-driver
    libva
    lib32-libva
  )

  FULL_HEROIC_PKGS=(
    lutris
    wine
    winetricks
    obs-studio
    goverlay
    vkbasalt
    dxvk
    vkd3d
    vkd3d-proton
    mesa-demos
    lib32-mesa-demos
    vulkan-validation-layers
    lib32-vulkan-validation-layers
    ffmpeg
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-libav
    p7zip
    unrar
    unarchiver
    zip
    xboxdrv
    bluez
    bluez-utils
    openssl
    ca-certificates
  )

  # Check if running as root
  if [[ $EUID -eq 0 ]]; then
    yellow "[*] Running in ROOT mode."
    echo

    # Multilib first, otherwise lib32 packages will fail.
    if [[ "$DO_MULTILIB" -eq 1 ]]; then
      enable_multilib
    else
      log "Skipping multilib enable due to --no-multilib"
    fi

    if [[ "$DO_SYU" -eq 1 ]]; then
      log "Running full system upgrade (pacman -Syu)..."
      pacman -Syu --noconfirm
      echo
    else
      log "Skipping pacman -Syu due to --no-syu"
      echo
    fi

    install_all_root_mode

  else
    echo "[*] Running in USER mode."
    echo
    check_all_user_mode
  fi
}

main "$@"
