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
# Get absolute path of this script's directory (tools/)
# Handle both cases: called from base dir (tools/ghul-prep.sh) or from tools/ (./ghul-prep.sh)
if [[ "${BASH_SOURCE[0]}" == *"/"* ]]; then
  # Has path component - use it
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  # No path - assume called from current directory
  SCRIPT_DIR="$(pwd)"
fi
# Get base directory (one level up from tools/)
# If we're in tools/, go up one level. If we're already in base, stay there.
if [[ "$(basename "$SCRIPT_DIR")" == "tools" ]]; then
  BASE="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  BASE="$SCRIPT_DIR"
fi

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

find_nvidia_dkms_package() {
  # Searches for NVIDIA DKMS packages (nvidia-dkms, nvidia-open-dkms, etc.)
  # Returns the first found package name, or empty string if none found
  local found_pkg=""
  
  # Search for packages containing "nvidia" and "dkms" in their name
  # Use pacman -Ss to search, then filter for packages in enabled repos
  # Priority: nvidia-dkms first, then nvidia-open-dkms, then any other nvidia*-dkms
  local search_results
  search_results="$(pacman -Ss 'nvidia.*dkms' 2>/dev/null | grep -E '^extra/|^community/|^multilib/' || true)"
  
  if [[ -n "$search_results" ]]; then
    # Try nvidia-dkms first
    local nvidia_dkms
    nvidia_dkms="$(echo "$search_results" | grep -E '^[^/]+/nvidia-dkms ' | head -n1 || true)"
    if [[ -n "$nvidia_dkms" ]]; then
      found_pkg="$(echo "$nvidia_dkms" | awk '{print $1}' | cut -d'/' -f2)"
    else
      # Try nvidia-open-dkms
      local nvidia_open_dkms
      nvidia_open_dkms="$(echo "$search_results" | grep -E '^[^/]+/nvidia-open-dkms ' | head -n1 || true)"
      if [[ -n "$nvidia_open_dkms" ]]; then
        found_pkg="$(echo "$nvidia_open_dkms" | awk '{print $1}' | cut -d'/' -f2)"
      else
        # Try any other nvidia*-dkms package
        local any_nvidia_dkms
        any_nvidia_dkms="$(echo "$search_results" | grep -E '^[^/]+/nvidia.*-dkms ' | head -n1 || true)"
        if [[ -n "$any_nvidia_dkms" ]]; then
          found_pkg="$(echo "$any_nvidia_dkms" | awk '{print $1}' | cut -d'/' -f2)"
        fi
      fi
    fi
  fi
  
  echo "$found_pkg"
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

extract_nvidia_chipcode() {
  # Extracts NVIDIA GPU chipcode (e.g., GM107M, GP107, TU116, GA102, AD103) from lspci
  # Returns: chipcode string or empty if not found
  if ! command -v lspci >/dev/null 2>&1; then
    echo ""
    return
  fi

  local nvidia_line
  nvidia_line="$(lspci -nn | grep -iE 'VGA compatible controller.*nvidia|3D controller.*nvidia' | head -n1 || true)"

  if [[ -z "$nvidia_line" ]]; then
    echo ""
    return
  fi

  # Extract chipcode using regex: GM|GP|TU|GA|AD followed by 2-3 digits and optional letter
  local chipcode
  chipcode="$(echo "$nvidia_line" | grep -oE '\b(GM|GP|TU|GA|AD|GK|GF)[0-9]{2,3}[A-Z]?\b' | head -n1 || true)"

  echo "$chipcode"
}

choose_nvidia_mode() {
  # Chooses NVIDIA driver mode based on chipcode
  # Returns: open | nouveau
  # Note: As of Dec 2025, Arch removed proprietary nvidia-dkms.
  #       Only nvidia-open-dkms (RTX only) and nouveau are available.
  local chipcode="$1"

  if [[ -z "$chipcode" ]]; then
    # Unknown chipcode - try open first (might be RTX)
    echo "open"
    return
  fi

  # RTX (Turing/Ampere/Ada) → nvidia-open-dkms (only supported by open driver)
  if echo "$chipcode" | grep -qE '^(TU|GA|AD)'; then
    echo "open"
    return
  fi

  # Pascal (GTX 10xx) → nouveau (nvidia-dkms removed from Arch repos as of Dec 2025)
  if echo "$chipcode" | grep -qE '^GP'; then
    echo "nouveau"
    return
  fi

  # Maxwell/Kepler/älter (GM*, GK*, GF*) → nouveau (no proprietary drivers available)
  if echo "$chipcode" | grep -qE '^(GM|GK|GF)'; then
    echo "nouveau"
    return
  fi

  # Unknown chipcode pattern - try open first (might be RTX)
  echo "open"
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
      # Special handling for nvidia-dkms: search for alternatives
      if [[ "$p" == "nvidia-dkms" ]]; then
        local alt_pkg
        alt_pkg="$(find_nvidia_dkms_package)"
        if [[ -n "$alt_pkg" && "$alt_pkg" != "nvidia-dkms" ]]; then
          # Found alternative package
          if pkg_installed "$alt_pkg"; then
            printf "  [\e[32m✓\e[0m] %s (using alternative: %s)\n" "$p" "$alt_pkg"
          elif pkg_exists "$alt_pkg"; then
            printf "  [\e[31m \e[0m] %s (will use alternative: %s)\n" "$p" "$alt_pkg"
            missing_count=1
            missing+=("$alt_pkg")
          else
            printf "  [\e[33m?\e[0m] %s (not in enabled repos, alternative %s also not found)\n" "$p" "$alt_pkg"
          fi
        elif [[ -n "$alt_pkg" && "$alt_pkg" == "nvidia-dkms" ]]; then
          # nvidia-dkms itself exists
          printf "  [\e[31m \e[0m] %s\n" "$p"
          missing_count=1
          missing+=("$p")
        else
          # No alternative found
          printf "  [\e[33m?\e[0m] %s (not in enabled repos)\n" "$p"
        fi
      elif pkg_exists "$p"; then
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
        # Extract chipcode and choose mode
        local chipcode
        chipcode="$(extract_nvidia_chipcode)"
        local mode
        mode="$(choose_nvidia_mode "$chipcode")"
        
        if [[ -n "$chipcode" ]]; then
          echo "  NVIDIA chipcode: $chipcode → mode: $mode"
        else
          echo "  NVIDIA chipcode: not detected → mode: $mode (default)"
        fi
        echo
        
        case "$mode" in
          open)
            local -a open_pkgs=(
              "dkms"
              "nvidia-open-dkms"
              "nvidia-utils"
              "lib32-nvidia-utils"
              "opencl-nvidia"
            )
            if ! check_pkgs_user_mode "nvidia-open" "${open_pkgs[@]}"; then
              any_missing=1
            fi
            ;;
          dkms)
            # Deprecated - nvidia-dkms removed from Arch (Dec 2025)
            echo "  Pascal NVIDIA detected, but nvidia-dkms was removed from Arch repos (Dec 2025)."
            echo "  Falling back to Nouveau (open-source driver)."
            local -a nouveau_pkgs=(
              "mesa"
              "lib32-mesa"
              "vulkan-icd-loader"
              "lib32-vulkan-icd-loader"
              "vulkan-tools"
            )
            if ! check_pkgs_user_mode "nouveau" "${nouveau_pkgs[@]}"; then
              any_missing=1
            fi
            ;;
          nouveau)
            echo "  Non-RTX NVIDIA detected (Pascal/Maxwell/older) → using Nouveau"
            echo "  Note: Arch removed proprietary nvidia-dkms as of Dec 2025."
            echo "  Only nvidia-open-dkms (RTX only) and Nouveau are available."
            local -a nouveau_pkgs=(
              "mesa"
              "lib32-mesa"
              "vulkan-icd-loader"
              "lib32-vulkan-icd-loader"
              "vulkan-tools"
            )
            if ! check_pkgs_user_mode "nouveau" "${nouveau_pkgs[@]}"; then
              any_missing=1
            fi
            ;;
          *)
            # Fallback to dkms
            local -a dkms_pkgs=(
              "dkms"
              "nvidia-dkms"
              "nvidia-utils"
              "lib32-nvidia-utils"
              "opencl-nvidia"
            )
            if ! check_pkgs_user_mode "nvidia-dkms" "${dkms_pkgs[@]}"; then
              any_missing=1
            fi
            ;;
        esac
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
      # Special handling for nvidia-dkms: search for alternatives
      if [[ "$p" == "nvidia-dkms" ]]; then
        local alt_pkg
        alt_pkg="$(find_nvidia_dkms_package)"
        if [[ -n "$alt_pkg" && "$alt_pkg" != "nvidia-dkms" ]]; then
          # Found alternative package (e.g., nvidia-open-dkms)
          if pkg_installed "$alt_pkg"; then
            printf "  [\e[32m✓\e[0m] %s (using alternative: %s, already installed)\n" "$p" "$alt_pkg"
          elif pkg_exists "$alt_pkg"; then
            printf "  [ ] %s  → will install alternative: %s\n" "$p" "$alt_pkg"
            missing+=("$alt_pkg")
          else
            printf "  [\e[33m?\e[0m] %s (not in enabled repos, alternative %s also not found, skipping)\n" "$p" "$alt_pkg"
          fi
        elif [[ -n "$alt_pkg" && "$alt_pkg" == "nvidia-dkms" ]]; then
          # nvidia-dkms itself exists
          if pkg_exists "$p"; then
            printf "  [ ] %s  → will install\n" "$p"
            missing+=("$p")
          else
            printf "  [\e[33m?\e[0m] %s (not in enabled repos, skipping)\n" "$p"
          fi
        else
          # No alternative found
          printf "  [\e[33m?\e[0m] %s (not in enabled repos, no alternative found, skipping)\n" "$p"
        fi
      elif pkg_exists "$p"; then
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

remove_nvidia_packages() {
  # Removes NVIDIA packages if they are installed
  # Note: Some packages may have dependencies (nvidia-prime, steam) - we try to remove what we can
  local -a to_remove=(
    "nvidia-open-dkms"
    "nvidia-dkms"
    "opencl-nvidia"
  )
  
  # These might have dependencies, try to remove but don't fail if they can't be removed
  local -a optional_remove=(
    "nvidia-utils"
    "lib32-nvidia-utils"
  )

  local -a installed=()
  for pkg in "${to_remove[@]}"; do
    if pkg_installed "$pkg"; then
      installed+=("$pkg")
    fi
  done

  if ((${#installed[@]} > 0)); then
    log "Removing NVIDIA driver packages: ${installed[*]}"
    pacman -R --noconfirm "${installed[@]}" 2>&1 || {
      yellow "    → Warning: Some NVIDIA driver packages could not be removed"
    }
  fi
  
  # Try to remove optional packages (may fail due to dependencies)
  local -a optional_installed=()
  for pkg in "${optional_remove[@]}"; do
    if pkg_installed "$pkg"; then
      optional_installed+=("$pkg")
    fi
  done
  
  if ((${#optional_installed[@]} > 0)); then
    log "Attempting to remove NVIDIA utility packages: ${optional_installed[*]}"
    log "    (These may be kept due to dependencies like nvidia-prime or steam)"
    if pacman -R --noconfirm "${optional_installed[@]}" 2>&1; then
      green "    → NVIDIA utility packages removed successfully"
    else
      yellow "    → NVIDIA utility packages kept (required by other packages)"
      yellow "    → This is OK - they won't interfere with Nouveau"
    fi
  fi
  
  if ((${#installed[@]} == 0 && ${#optional_installed[@]} == 0)); then
    log "No NVIDIA packages found to remove"
  fi
}

install_nvidia_mode_open() {
  # Installs nvidia-open-dkms stack (for RTX Turing/Ampere/Ada only)
  # Note: As of Dec 2025, Arch removed proprietary nvidia-dkms.
  #       Only nvidia-open-dkms is available, and it only supports RTX cards.
  log "Installing NVIDIA open-dkms stack (RTX/Turing/Ampere/Ada only)..."
  yellow "    → Note: nvidia-open-dkms only supports RTX cards (Turing/Ampere/Ada)."
  yellow "    → Arch removed proprietary nvidia-dkms as of Dec 2025."
  
  # Ensure kernels are installed first
  if [[ "$DO_KERNELS" -eq 1 ]]; then
    log "Ensuring kernels and headers are installed..."
    install_pkgs_root_mode "kernels" "${KERNEL_PKGS[@]}"
  fi

  # Remove conflicting nvidia-dkms if present (legacy, shouldn't exist anymore)
  if pkg_installed "nvidia-dkms"; then
    log "Removing conflicting nvidia-dkms package (no longer in Arch repos)..."
    pacman -R --noconfirm nvidia-dkms 2>&1 || true
  fi

  # Install open-dkms stack
  local -a open_pkgs=(
    "dkms"
    "nvidia-open-dkms"
    "nvidia-utils"
    "lib32-nvidia-utils"
    "opencl-nvidia"
  )
  install_pkgs_root_mode "nvidia-open" "${open_pkgs[@]}"
  
  # Regenerate initramfs
  if command -v mkinitcpio >/dev/null 2>&1; then
    log "Regenerating initramfs..."
    mkinitcpio -P 2>&1 || yellow "    → Warning: mkinitcpio failed (may need manual intervention)"
  fi
  
  log "Note: reboot recommended after NVIDIA open-dkms install/updates."
}

install_nvidia_mode_dkms() {
  # This function is deprecated - nvidia-dkms was removed from Arch repos (Dec 2025)
  # Fallback to nouveau for Pascal/Maxwell cards
  log "NVIDIA dkms stack requested, but nvidia-dkms was removed from Arch repos (Dec 2025)."
  yellow "    → Falling back to Nouveau (open-source driver)."
  yellow "    → Proprietary NVIDIA drivers are no longer available for Pascal/Maxwell."
  install_nvidia_mode_nouveau
}

install_nvidia_mode_nouveau() {
  # Removes NVIDIA packages and ensures Mesa/Vulkan base for non-RTX GPUs
  # Note: As of Dec 2025, Arch removed proprietary nvidia-dkms.
  #       Only nvidia-open-dkms (RTX only) and Nouveau are available.
  log "Non-RTX NVIDIA detected (Pascal/Maxwell/older) → using Nouveau; skipping NVIDIA packages."
  yellow "    → Note: Arch removed proprietary nvidia-dkms as of Dec 2025."
  yellow "    → Only nvidia-open-dkms (RTX only) and Nouveau are available."
  
  # Remove all NVIDIA packages
  remove_nvidia_packages
  
  # Ensure Mesa/Vulkan base is installed
  log "Ensuring Mesa/Vulkan base packages for Nouveau..."
  local -a nouveau_pkgs=(
    "mesa"
    "lib32-mesa"
    "vulkan-icd-loader"
    "lib32-vulkan-icd-loader"
    "vulkan-tools"
  )
  install_pkgs_root_mode "nouveau" "${nouveau_pkgs[@]}"
  
  log "Note: Using open-source Nouveau driver (proprietary drivers no longer available)."
  log "      For RTX cards, nvidia-open-dkms is available. For older cards, Nouveau is the only option."
  
  # Setup GPU activation helper (for passwordless GPU activation)
  setup_nvidia_gpu_helper
}

setup_nvidia_gpu_helper() {
  # Sets up helper script and sudoers rule for passwordless GPU activation
  log "Setting up NVIDIA GPU activation helper (for passwordless GPU activation)..."
  
  local helper_script="${BASE}/tools/ghul-enable-nvidia-gpu.sh"
  local sudoers_file="/etc/sudoers.d/ghul-gpu"
  
  # Ensure helper script exists and is executable
  if [[ -f "$helper_script" ]]; then
    chmod +x "$helper_script"
    green "    → Helper script ready: $helper_script"
  else
    yellow "    → Warning: Helper script not found: $helper_script"
    return 0
  fi
  
  # Create sudoers rule for passwordless execution
  if [[ -f "$sudoers_file" ]]; then
    yellow "    → Sudoers rule already exists: $sudoers_file"
  else
    # Determine target user
    local target_user="${SUDO_USER:-}"
    if [[ -z "$target_user" ]]; then
      yellow "    → Warning: SUDO_USER not set, skipping sudoers setup"
      return 0
    fi
    
    # Create sudoers rule
    cat > "$sudoers_file" <<EOF
# GHUL - Allow passwordless execution of GPU activation helper
# This allows users in the wheel group to enable NVIDIA GPU without password
%wheel ALL=(ALL) NOPASSWD: ${helper_script}
EOF
    
    chmod 0440 "$sudoers_file"
    green "    → Created sudoers rule: $sudoers_file"
    green "    → Users in 'wheel' group can now run: sudo $helper_script"
  fi
  
  log "    → GPU can now be activated without password using: sudo $helper_script"
}

install_all_root_mode() {
  log "Installing packages (root mode, automatic install):"
  echo

  # Core packages
  log "Installing core packages..."
  install_pkgs_root_mode "core" "${CORE_PKGS[@]}"
  echo

  # Kernels (install early, needed for DKMS)
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
        # Extract chipcode and choose mode
        local chipcode
        chipcode="$(extract_nvidia_chipcode)"
        local mode
        mode="$(choose_nvidia_mode "$chipcode")"
        
        if [[ -n "$chipcode" ]]; then
          log "Detected NVIDIA chipcode: $chipcode"
        else
          log "NVIDIA chipcode not detected, using default mode"
        fi
        log "Selected NVIDIA driver mode: $mode"
        echo
        
        case "$mode" in
          open)
            install_nvidia_mode_open
            ;;
          dkms)
            # Deprecated - nvidia-dkms removed from Arch (Dec 2025)
            install_nvidia_mode_dkms
            ;;
          nouveau)
            install_nvidia_mode_nouveau
            ;;
          *)
            yellow "    → Unknown NVIDIA mode: $mode, defaulting to nouveau"
            install_nvidia_mode_nouveau
            ;;
        esac
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
  log "If you installed/updated kernel(s) or NVIDIA drivers: reboot is recommended."
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
