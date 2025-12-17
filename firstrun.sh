#!/usr/bin/env bash
# GHUL - Gaming Hardware Using Linux
# First run helper:
# - Non-root mode: check dependencies, show pacman install hints, check logs.
# - Root mode: automatically install missing deps via pacman and generate hardware logs.
#
# All comments in English, terminal output could be localized by the user ;-)
# but we fix that and force locale for this script...

set -euo pipefail

# ----- Force predictable locale (very important for parsing) -----
export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

# ---------- helpers ------------------------------------------------------------

# Get absolute path of this script (GHULbenchmark base dir)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="${BASE}/logs"
OUTDIR="${BASE}/results"
# Create all necessary directories upfront
mkdir -p "${LOGDIR}" "${LOGDIR}/runs" "${LOGDIR}/sensors" "${OUTDIR}"

# If running as root, ensure directories belong to the actual user
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  chown -R "${SUDO_USER}:${SUDO_USER}" "${LOGDIR}" "${OUTDIR}" 2>/dev/null || true
fi

have() { command -v "$1" >/dev/null 2>&1; }

# Small helpers for pretty output
green() { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
red()   { printf '\e[31m%s\e[0m\n' "$*"; }

print_header() {
  echo "== GHUL First Run =="
  echo
}


# ----- is it Arch based or what type of Linux machine we have here?
detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-unknown}"
  else
    DISTRO_ID="unknown"
    DISTRO_LIKE="unknown"
  fi
}

is_arch_like() {
  if command -v pacman >/dev/null 2>&1; then
    [[ "${DISTRO_ID}" =~ (arch|manjaro|endeavouros|cachyos) || "${DISTRO_LIKE}" == *arch* ]]
  else
    return 1
  fi
}

# Check if AUR helper (yay) is available
has_aur_helper() {
  command -v yay >/dev/null 2>&1
}

# Get AUR helper command (yay)
get_aur_helper() {
  if command -v yay >/dev/null 2>&1; then
    echo "yay"
  else
    return 1
  fi
}

# ---------- dependency definitions --------------------------------------------

# Core packages (available via pacman)
CORE_CMDS=(
  "glmark2"
  "vkmark"
  "iperf3"
  "speedtest"
  "sysbench"
  "stress-ng"
  "7z"
  "glxinfo"
  "jq"
  "gamescope"
  "sensors"
  "fio"
  "smartctl"
  "nvme"
  "bc"
)

CORE_PKGS=(
  "glmark2"        # glmark2
  "vkmark"         # vkmark
  "iperf3"         # iperf3
  "speedtest-cli"  # speedtest
  "sysbench"       # sysbench
  "stress-ng"      # stress-ng
  "p7zip"          # 7z
  "mesa-demos"     # glxinfo
  "jq"             # jq
  "gamescope"      # gamescope
  "lm_sensors"     # sensors
  "fio"            # fio
  "smartmontools"  # smartctl
  "nvme-cli"       # nvme (for NVMe temperature reading)
  "bc"             # bc (calculator for floating point math in scripts)
)

# AUR packages (require AUR helper: pamac or yay)
AUR_CMDS=(
  "gputest"
  "mbw"
)

AUR_PKGS=(
  "gputest"        # gputest
  "mbw"            # mbw
)

# Sanity check: arrays must be same length
if [[ ${#CORE_CMDS[@]} -ne ${#CORE_PKGS[@]} ]]; then
  echo "Internal error: CORE_CMDS and CORE_PKGS length mismatch." >&2
  exit 1
fi

if [[ ${#AUR_CMDS[@]} -ne ${#AUR_PKGS[@]} ]]; then
  echo "Internal error: AUR_CMDS and AUR_PKGS length mismatch." >&2
  exit 1
fi

# ----- GPU Hybrid Graphics Detection ------------------------------------------

check_hybrid_graphics() {
  echo "[*] Checking for hybrid graphics setup:"
  echo
  
  local gpu_count=0
  local has_nvidia=0
  local has_amd=0
  local has_intel=0
  local gpu_list=""
  
  if command -v lspci >/dev/null 2>&1; then
    gpu_list="$(lspci -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' || true)"
    gpu_count="$(echo "$gpu_list" | grep -c . || echo 0)"
    
    if echo "$gpu_list" | grep -qi 'NVIDIA'; then
      has_nvidia=1
    fi
    # Check for AMD/ATI GPUs (be more specific to avoid false matches like "Corporation")
    # Match AMD/ATI/Radeon as separate words, not as part of other words
    if echo "$gpu_list" | grep -qiE '\bAMD\b.*\[|ATI\b.*\[|\bRadeon\b'; then
      has_amd=1
    fi
    if echo "$gpu_list" | grep -qi 'Intel'; then
      has_intel=1
    fi
  fi
  
  if [[ $gpu_count -le 1 ]]; then
    echo "    Single GPU detected (no hybrid graphics)"
    echo
    return 0
  fi
  
  echo "    Multiple GPUs detected: ${gpu_count}"
  echo "$gpu_list" | while IFS= read -r line; do
    [[ -n "$line" ]] && echo "      - $line"
  done
  echo
  
  # Check for NVIDIA Optimus (prime-run)
  if [[ $has_nvidia -eq 1 ]]; then
    if command -v prime-run >/dev/null 2>&1; then
      green "    ✓ prime-run available (NVIDIA Optimus support)"
      echo "      GPU benchmarks will automatically use the NVIDIA GPU"
    else
      yellow "    ⚠ prime-run not found (NVIDIA Optimus)"
      echo "      Install: pacman -S nvidia-prime"
      echo "      Without prime-run, GPU tests may run on the integrated GPU"
    fi
    echo
  fi
  
  # Check for AMD hybrid (DRI_PRIME)
  # Only check if we actually have both AMD and Intel GPUs
  if [[ $has_amd -eq 1 && $has_intel -eq 1 ]]; then
    # First verify AMD GPU is actually present in lspci output
    # Use word boundaries to avoid false matches like "Corporation" containing "ATI"
    local amd_in_lspci=0
    if echo "$gpu_list" | grep -qiE '\bAMD\b|\bATI\b|\bRadeon\b'; then
      amd_in_lspci=1
    fi
    
    if [[ $amd_in_lspci -eq 1 ]]; then
      # Check if DRI_PRIME would work (check for AMD card in /sys/class/drm)
      local amd_card_found=0
      if [[ -d /sys/class/drm ]]; then
        for card in /sys/class/drm/card*/device/vendor; do
          if [[ -r "$card" ]]; then
            vendor_hex="$(cat "$card" 2>/dev/null || echo "")"
            # AMD vendor ID is 0x1002
            if [[ "$vendor_hex" == "0x1002" ]]; then
              amd_card_found=1
              break
            fi
          fi
        done
      fi
      
      if [[ $amd_card_found -eq 1 ]]; then
        green "    ✓ AMD hybrid graphics detected"
        echo "      GPU benchmarks will automatically use DRI_PRIME=1 for AMD GPU"
      else
        yellow "    ⚠ AMD GPU detected but not accessible via /sys/class/drm"
        echo "      DRI_PRIME=1 may not work correctly"
      fi
      echo
    fi
  fi
  
  if [[ $has_nvidia -eq 0 && $has_amd -eq 0 ]]; then
    echo "    Multiple GPUs detected but no dedicated GPU found"
    echo "    (likely multiple integrated GPUs or unknown configuration)"
    echo
  fi
}

# ----- is it Arch based or what type of Linux machine we have here? -----------

# output the info that GHULbench was made for an arch based  rolling release
detect_distro
echo "Detected distro: ${DISTRO_ID} (like: ${DISTRO_LIKE})"
echo

# Check for hybrid graphics (before dependency check, no root needed)
check_hybrid_graphics

if ! is_arch_like; then
  yellow "[!] GHUL firstrun was developed and tested on Arch-based systems (Manjaro, Arch, ...)."
  echo "    Automatic installation is disabled on this distro."
  echo
  echo "    You need the following tools (package names are Arch-style, but good hints):"
  echo
  echo "    Core packages (via pacman):"
  printf '      - %s\n' "${CORE_PKGS[@]}"
  echo
  echo "    AUR packages (via pamac/yay):"
  printf '      - %s\n' "${AUR_PKGS[@]}"
  echo
  exit 1
fi

# ---------- GHUL host ID (root mode, mainboard-based, JSON) -------------------

# We store a small JSON file with the board identity and a stable GHUL Host ID:
# {
#   "vendor": "...",
#   "product": "...",
#   "serial": "...",
#   "id": "4d420f0c1ee87533"
# }
#
# Rules:
#   - New ID is generated from (vendor, product, serial).
#   - If vendor+product are unchanged, we KEEP the old ID even if serial changed.
#     → "New, identical motherboard detected. ID change NOT needed."
#   - If vendor or product changed, we generate a NEW ID.

HOST_ID_FILE="${BASE}/.ghul_host_id.json"

read_mainboard_fields() {
  # Requires root (dmidecode). We assume firstrun root mode here.
  local vendor product serial

  if ! have dmidecode; then
    vendor="unknown"
    product="unknown"
    serial="unknown"
  else
    vendor="$(dmidecode -s baseboard-manufacturer 2>/dev/null || echo unknown)"
    product="$(dmidecode -s baseboard-product-name 2>/dev/null || echo unknown)"
    serial="$(dmidecode -s baseboard-serial-number 2>/dev/null || echo unknown)"
  fi

  MAINBOARD_VENDOR="${vendor}"
  MAINBOARD_PRODUCT="${product}"
  MAINBOARD_SERIAL="${serial}"
}

read_cpu_socket() {
  # Requires root (dmidecode). We assume firstrun root mode here.
  # Extracts CPU socket type from dmidecode -t processor
  local socket="unknown"

  if have dmidecode; then
    # Try Socket Designation first
    socket="$(dmidecode -t processor 2>/dev/null | awk -F: '
      /Socket Designation/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2);
        print $2;
        exit
      }' || echo "unknown")"
    
    # Fallback: try Upgrade field if Socket Designation is empty
    if [[ -z "$socket" || "$socket" == "unknown" ]]; then
      socket="$(dmidecode -t processor 2>/dev/null | awk -F: '
        /Upgrade/ {
          gsub(/^[ \t]+|[ \t]+$/, "", $2);
          # Remove "Socket " prefix if present
          sub(/^Socket[ \t]+/, "", $2);
          print $2;
          exit
        }' || echo "unknown")"
    fi
  fi

  CPU_SOCKET="${socket}"
}

json_get_field() {
  # Very small ad-hoc JSON parser for our simple one-line JSON.
  # Usage: json_get_field KEY FILE
  local key="$1"
  local file="$2"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n1
}

write_host_id_json() {
  local vendor="$1"
  local product="$2"
  local serial="$3"
  local id="$4"
  local fan_status="${5:-unknown}"
  local cpu_socket="${6:-unknown}"

  cat > "${HOST_ID_FILE}" <<EOF
{
  "vendor": "${vendor}",
  "product": "${product}",
  "serial": "${serial}",
  "id": "${id}",
  "fan_status": "${fan_status}",
  "cpu_socket": "${cpu_socket}"
}
EOF
}

generate_host_id_from_board() {
  # ID uses vendor + product + serial → different real machines get different IDs,
  # but we will NOT regenerate it on serial changes if the JSON already exists.
  local vendor="$1"
  local product="$2"
  local serial="$3"
  printf '%s\n' "${vendor}|${product}|${serial}" | sha256sum | awk '{print $1}' | cut -c1-16
}

# ---------- Fan availability check ---------------------------------------------

check_fan_availability() {
  # Check if any case/motherboard fans are detectable via sensors or /sys/class/hwmon
  # Returns: "available" if fans found, "unattainable" if no fans detected
  # This helps identify systems where SuperIO chips cannot be read (e.g., ACPI-controlled)
  
  local fan_found=0
  
  # Method 1: Check /sys/class/hwmon for fan*_input files (exclude GPU fans)
  for hwmon in /sys/class/hwmon/hwmon*; do
    local hwmon_name
    hwmon_name="$(cat "$hwmon/name" 2>/dev/null || echo "")"
    
    # Skip GPU-related hwmon (amdgpu, nvidia)
    if [[ "$hwmon_name" =~ (amdgpu|nvidia) ]]; then
      continue
    fi
    
    # Check for fan*_input files
    for fan_file in "$hwmon"/fan*_input; do
      if [[ -r "$fan_file" ]]; then
        local fan_rpm
        fan_rpm="$(cat "$fan_file" 2>/dev/null || echo 0)"
        if [[ "$fan_rpm" != "0" && -n "$fan_rpm" && "$fan_rpm" =~ ^[0-9]+$ ]]; then
          fan_found=1
          break 2
        fi
      fi
    done
  done
  
  # Method 2: Check sensors -j (if jq available)
  if [[ $fan_found -eq 0 ]] && command -v jq >/dev/null 2>&1 && command -v sensors >/dev/null 2>&1; then
    local sensors_json
    sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
    
    # Check if any fan*_input values exist (excluding GPU fans)
    local fan_count
    fan_count="$(printf '%s' "$sensors_json" | jq -r '
      paths(scalars) as $p |
      # Match fan*_input but exclude GPU-related paths (amdgpu, nvidia)
      if (($p | tostring | test("amdgpu|nvidia") | not) and
          ($p[-1] | test("fan[0-9]+_input")) and
          (getpath($p) | type == "number") and
          (getpath($p) > 0)) then
        1
      else
        empty
      end
    ' 2>/dev/null | wc -l || echo 0)"
    
    if [[ "$fan_count" -gt 0 ]]; then
      fan_found=1
    fi
  fi
  
  # Method 3: Check sensors text output (fallback)
  if [[ $fan_found -eq 0 ]] && command -v sensors >/dev/null 2>&1; then
    local fan_num=1
    while [[ $fan_num -le 5 ]]; do
      local fan_val
      fan_val="$(sensors 2>/dev/null | awk -v fn="$fan_num" '/fan'$fan_num':/ {gsub(/RPM/,"",$2); print $2+0; exit}' || echo "")"
      if [[ -n "$fan_val" && "$fan_val" != "0" ]]; then
        fan_found=1
        break
      fi
      ((fan_num++))
    done
  fi
  
  if [[ $fan_found -eq 1 ]]; then
    echo "available"
  else
    echo "unattainable"
  fi
}

ensure_host_id_root_mode() {
  echo "[*] GHUL Host ID (mainboard-based, JSON):"
  echo

  # Get current board data
  read_mainboard_fields
  local new_vendor="${MAINBOARD_VENDOR}"
  local new_product="${MAINBOARD_PRODUCT}"
  local new_serial="${MAINBOARD_SERIAL}"

  # Get CPU socket information
  read_cpu_socket
  local new_cpu_socket="${CPU_SOCKET}"

  # Check fan availability
  local fan_status
  fan_status="$(check_fan_availability)"

  # If no JSON file exists yet: create a fresh one
  if [[ ! -f "${HOST_ID_FILE}" ]]; then
    local new_id
    new_id="$(generate_host_id_from_board "${new_vendor}" "${new_product}" "${new_serial}")"
    HOST_ID="${new_id}"
    write_host_id_json "${new_vendor}" "${new_product}" "${new_serial}" "${HOST_ID}" "${fan_status}" "${new_cpu_socket}"

    echo "    Mainboard vendor : ${new_vendor}"
    echo "    Mainboard product: ${new_product}"
    echo "    Mainboard serial : ${new_serial}"
    echo
    green "    → New GHUL Host ID: ${HOST_ID}"
    echo "      (stored in ${HOST_ID_FILE})"
    echo
    
    # Show fan status warning if unattainable
    if [[ "$fan_status" == "unattainable" ]]; then
      yellow "    ⚠ Fan monitoring: NOT AVAILABLE"
      echo "      The SuperIO chip on this mainboard cannot be accessed by Linux."
      echo "      This is likely due to proprietary ACPI control that only works on Microsoft Windows."
      echo "      Fan RPM values will show as 'n/a' in sensor reports, but fans are still working."
      echo
    fi
    
    return 0
  fi

  # JSON file exists: read old values
  local old_vendor old_product old_serial old_id old_fan_status old_cpu_socket
  old_vendor="$(json_get_field "vendor"  "${HOST_ID_FILE}")"
  old_product="$(json_get_field "product" "${HOST_ID_FILE}")"
  old_serial="$(json_get_field "serial"  "${HOST_ID_FILE}")"
  old_id="$(json_get_field "id"      "${HOST_ID_FILE}")"
  old_fan_status="$(json_get_field "fan_status" "${HOST_ID_FILE}" || echo "unknown")"
  old_cpu_socket="$(json_get_field "cpu_socket" "${HOST_ID_FILE}" || echo "unknown")"
  
  # Use new socket if available, otherwise keep old one
  local cpu_socket_to_use="${new_cpu_socket}"
  if [[ "$cpu_socket_to_use" == "unknown" && "$old_cpu_socket" != "unknown" ]]; then
    cpu_socket_to_use="${old_cpu_socket}"
  fi

  # If vendor+product are unchanged → keep ID, even if serial changed
  if [[ "${old_vendor}" == "${new_vendor}" && "${old_product}" == "${new_product}" ]]; then
    HOST_ID="${old_id}"
    # Update fan_status if it changed or was missing
    if [[ "$old_fan_status" != "$fan_status" ]]; then
      fan_status="$fan_status"  # Use new status
    else
      fan_status="$old_fan_status"  # Keep old status
    fi

    local serial_msg=""
    if [[ -n "${new_serial}" && "${new_serial}" != "unknown" && "${new_serial}" != "${old_serial}" ]]; then
      # Same board type, but different unit (new identical motherboard)
      write_host_id_json "${new_vendor}" "${new_product}" "${new_serial}" "${HOST_ID}" "${fan_status}" "${cpu_socket_to_use}"
      serial_msg="New, identical motherboard detected. ID change NOT needed."
    else
      # Update fan_status and cpu_socket in existing file if they changed
      write_host_id_json "${new_vendor}" "${new_product}" "${new_serial}" "${HOST_ID}" "${fan_status}" "${cpu_socket_to_use}"
    fi

    echo "    Mainboard vendor : ${new_vendor}"
    echo "    Mainboard product: ${new_product}"
    echo "    Mainboard serial : ${new_serial}"
    if [[ -n "${serial_msg}" ]]; then
      yellow "    → ${serial_msg}"
    fi
    echo
    green "    → Existing GHUL Host ID kept: ${HOST_ID}"
    echo "      (stored in ${HOST_ID_FILE})"
    echo
    
    # Show fan status warning if unattainable
    if [[ "$fan_status" == "unattainable" ]]; then
      yellow "    ⚠ Fan monitoring: NOT AVAILABLE"
      echo "      The SuperIO chip on this mainboard cannot be accessed by Linux."
      echo "      This is likely due to proprietary ACPI control that only works on Microsoft Windows."
      echo "      Fan RPM values will show as 'n/a' in sensor reports, but fans are still working."
      echo
    fi
    
    return 0
  fi

  # Otherwise: new board type → new ID
  local new_id
  new_id="$(generate_host_id_from_board "${new_vendor}" "${new_product}" "${new_serial}")"
  HOST_ID="${new_id}"
  write_host_id_json "${new_vendor}" "${new_product}" "${new_serial}" "${HOST_ID}" "${fan_status}" "${new_cpu_socket}"

  echo "    Previous board:"
  echo "      vendor : ${old_vendor}"
  echo "      product: ${old_product}"
  echo "      serial : ${old_serial}"
  echo
  echo "    New board detected:"
  echo "      vendor : ${new_vendor}"
  echo "      product: ${new_product}"
  echo "      serial : ${new_serial}"
  echo
  yellow "    → Mainboard change detected – new GHUL Host ID generated."
  green  "      New ID: ${HOST_ID}"
  echo "      (stored in ${HOST_ID_FILE})"
  echo
  
  # Show fan status warning if unattainable
  if [[ "$fan_status" == "unattainable" ]]; then
    yellow "    ⚠ Fan monitoring: NOT AVAILABLE"
    echo "      The SuperIO chip on this mainboard cannot be accessed by Linux."
    echo "      This is likely due to proprietary ACPI control that only works on Microsoft Windows."
    echo "      Fan RPM values will show as 'n/a' in sensor reports, but fans are still working."
    echo
  fi
}
# ---------- non-root dependency check -----------------------------------------

check_deps_user_mode() {
  echo "[*] Checking dependencies (user mode, no automatic install):"
  echo

  local missing_core=0
  local missing_aur=0
  local suggest_core=()
  local suggest_aur=()

  # Check core packages
  for i in "${!CORE_CMDS[@]}"; do
    local cmd="${CORE_CMDS[$i]}"
    local pkg="${CORE_PKGS[$i]}"

    if have "$cmd"; then
      printf "  [\e[32m✓\e[0m] %-10s (command: %s)\n" "$pkg" "$cmd"
    else
      printf "  [ ] %-10s (command: %s)  → install with: sudo pacman -S %s\n" "$pkg" "$cmd" "$pkg"
      missing_core=1
      suggest_core+=("$pkg")
    fi
  done

  # Check AUR packages
  for i in "${!AUR_CMDS[@]}"; do
    local cmd="${AUR_CMDS[$i]}"
    local pkg="${AUR_PKGS[$i]}"

    if have "$cmd"; then
      printf "  [\e[32m✓\e[0m] %-10s (command: %s) [AUR]\n" "$pkg" "$cmd"
    else
      printf "  [ ] %-10s (command: %s)  → install with: yay -S %s [AUR]\n" "$pkg" "$cmd" "$pkg"
      missing_aur=1
      suggest_aur+=("$pkg")
    fi
  done

  echo
  if [[ $missing_core -eq 1 ]]; then
    yellow "[!] Some core dependencies are missing."
    echo "    Suggested installation command:"
    echo
    echo "      sudo pacman -S ${suggest_core[*]}"
    echo
  fi

  if [[ $missing_aur -eq 1 ]]; then
    yellow "[!] Some AUR dependencies are missing."
    echo "    Suggested installation steps:"
    echo
    if ! has_aur_helper; then
      echo "      1. Install AUR helper:"
      echo "         pacman -S yay"
      echo
    fi
    echo "      2. Install AUR packages:"
    echo "         yay -S ${suggest_aur[*]}"
    echo
  fi

  if [[ $missing_core -eq 0 && $missing_aur -eq 0 ]]; then
    green "[✓] All dependencies are already installed."
  fi

  echo
}

# ---------- root-mode: install deps -------------------------------------------

install_deps_root_mode() {
  echo "[*] Checking dependencies (root mode, automatic install):"
  echo

  local missing_core=()
  local missing_aur=()

  # Check core packages
  for i in "${!CORE_CMDS[@]}"; do
    local cmd="${CORE_CMDS[$i]}"
    local pkg="${CORE_PKGS[$i]}"

    if have "$cmd"; then
      printf "  [\e[32m✓\e[0m] %-10s (command: %s)\n" "$pkg" "$cmd"
    else
      printf "  [ ] %-10s (command: %s)  → will install\n" "$pkg" "$cmd"
      missing_core+=("$pkg")
    fi
  done

  # Check AUR packages
  for i in "${!AUR_CMDS[@]}"; do
    local cmd="${AUR_CMDS[$i]}"
    local pkg="${AUR_PKGS[$i]}"

    if have "$cmd"; then
      printf "  [\e[32m✓\e[0m] %-10s (command: %s) [AUR]\n" "$pkg" "$cmd"
    else
      printf "  [ ] %-10s (command: %s)  → optional [AUR]\n" "$pkg" "$cmd"
      missing_aur+=("$pkg")
    fi
  done

  echo

  # Install core packages automatically (no prompt)
  if (( ${#missing_core[@]} > 0 )); then
    yellow "[*] Installing missing core packages via pacman (no confirmation needed):"
    echo "    pacman -S --noconfirm --needed ${missing_core[*]}"
    echo
    pacman -S --noconfirm --needed "${missing_core[@]}"
    echo
    green "[✓] Core dependency installation complete."
  else
    green "[✓] All core dependencies already installed."
  fi

  echo

  # Handle AUR packages (install helper if needed, then packages)
  if (( ${#missing_aur[@]} > 0 )); then
    yellow "[*] AUR packages available for installation: ${missing_aur[*]}"
    echo "    These require an AUR helper (yay)."
    echo
    echo -n "    Install AUR packages? [y/N]: "
    read -r answer
    if [[ "${answer,,}" =~ ^y(es)?$ ]]; then
      # Check if AUR helper is already available
      if has_aur_helper; then
        green "    → AUR helper (yay) found"
      else
        # No AUR helper found - install yay (available via pacman)
        yellow "    → No AUR helper found. Installing yay..."
        echo "    → This will allow installation of AUR packages."
        echo
        if pacman -S --noconfirm --needed yay 2>&1 && command -v yay >/dev/null 2>&1; then
          green "    → yay installed successfully."
        else
          yellow "    → Warning: Could not install yay (may not be available on this distro)."
          echo "    → You may need to install yay manually:"
          echo "      pacman -S yay"
          echo "    → Skipping AUR package installation."
          echo
          return 0
        fi
      fi
      
      echo
      yellow "    Installing AUR packages via yay..."
      yay -S --noconfirm "${missing_aur[@]}" 2>&1 || {
        yellow "    → Warning: AUR installation may have failed or requires manual intervention."
      }
      echo
      green "[✓] AUR dependency installation attempted."
    else
      yellow "    → Skipping AUR package installation."
      echo "    → You can install them manually later:"
      if has_aur_helper; then
        echo "      yay -S ${missing_aur[*]}"
      else
        echo "      # First install AUR helper:"
        echo "      pacman -S yay"
        echo "      # Then install AUR packages:"
        echo "      yay -S ${missing_aur[*]}"
      fi
    fi
    echo
  fi
}

# ---------- hardware logs (root mode) -----------------------------------------

generate_dmidecode_log() {
  echo "[*] Generating dmidecode.log (memory)..."
  dmidecode -t memory > "${LOGDIR}/dmidecode.log"
  green "    → ${LOGDIR}/dmidecode.log"
  echo
}

generate_mainboard_log() {
  echo "[*] Generating mainboard.log (baseboard + BIOS)..."
  {
    echo "# dmidecode -t baseboard"
    dmidecode -t baseboard
    echo
    echo "# dmidecode -t bios"
    dmidecode -t bios
  } > "${LOGDIR}/mainboard.log"
  green "    → ${LOGDIR}/mainboard.log"
  echo
}

generate_cpuinfo_log() {
  echo "[*] Generating cpuinfo.log (lscpu + /proc/cpuinfo model)..."
  {
    echo "# lscpu"
    lscpu
    echo
    echo "# /proc/cpuinfo (model name lines)"
    grep -iE 'model name|Modellname' /proc/cpuinfo || true
  } > "${LOGDIR}/cpuinfo.log"
  green "    → ${LOGDIR}/cpuinfo.log"
  echo
}

generate_processor_log() {
  echo "[*] Generating processor.log (dmidecode -t processor)..."
  if have dmidecode; then
    dmidecode -t processor > "${LOGDIR}/processor.log" 2>/dev/null || true
    green "    → ${LOGDIR}/processor.log"
  else
    yellow "    → dmidecode not available, skipping processor.log"
  fi
  echo
}

generate_gpuinfo_log() {
  echo "[*] Generating gpuinfo.log (lspci + glxinfo -B if available)..."
  {
    echo "# lspci -nn | grep -Ei 'vga|3d|display'"
    lspci -nn | grep -Ei 'vga|3d|display' || true
    echo
    if have glxinfo; then
      echo "# glxinfo -B"
      glxinfo -B 2>/dev/null || true
    else
      echo "# glxinfo not installed, only PCI info available."
    fi
  } > "${LOGDIR}/gpuinfo.log"
  green "    → ${LOGDIR}/gpuinfo.log"
  echo
}

generate_all_logs_root_mode() {
  echo "[*] Generating hardware logs (root mode)..."
  echo
  generate_dmidecode_log
  generate_mainboard_log
  generate_cpuinfo_log
  generate_processor_log
  generate_gpuinfo_log
  green "[✓] All hardware logs generated."
  echo
}

# ---------- udev rule for storage temperature access (root mode) ------------

setup_storage_temp_access() {
  echo "[*] Setting up storage temperature access (no root required)..."
  echo "    (This enables safe, non-root storage temperature monitoring)"
  echo

  # Determine target user
  if [[ -n "${SUDO_USER:-}" ]]; then
    TARGET_USER="${SUDO_USER}"
  else
    # Fallback if SUDO_USER not set (shouldn't happen in root mode, but safety)
    TARGET_USER="$(whoami)"
  fi

  # Check if user is already in disk group (in /etc/group)
  if groups "$TARGET_USER" 2>/dev/null | grep -q "\bdisk\b"; then
    green "    → User '${TARGET_USER}' is already in 'disk' group."
    echo "      (nothing to do)"
    echo
    # User was already in group - no need to show warning
    STORAGE_TEMP_USER_ALREADY_IN_GROUP=1
    return 0
  fi

  # User is NOT in disk group - need to set things up
  yellow "    → User '${TARGET_USER}' is not in 'disk' group."
  echo "      Setting up storage temperature access..."
  echo

  UDEV_RULE_FILE="/etc/udev/rules.d/99-ghul-storage-temp.rules"
  
  # Create udev rule if it doesn't exist
  if [[ -f "$UDEV_RULE_FILE" ]]; then
    yellow "    → udev rule already exists: ${UDEV_RULE_FILE}"
  else
    # Create udev rule: ensure disk group has read access to block devices
    cat > "$UDEV_RULE_FILE" <<'EOF'
# GHUL - Ensure disk group members can read block devices for smartctl
# This enables storage temperature monitoring without root privileges
KERNEL=="sd[a-z]*", GROUP="disk", MODE="0664"
KERNEL=="nvme[0-9]*", GROUP="disk", MODE="0664"
EOF

    green "    → Created udev rule: ${UDEV_RULE_FILE}"
  fi

  # Reload udev rules (no reboot needed for udev rules)
  udevadm control --reload-rules >/dev/null 2>&1 && udevadm trigger >/dev/null 2>&1
  green "    → Reloaded udev rules (no reboot needed)"

  # Set CAP_SYS_RAWIO capability on smartctl (required for IOCTL operations)
  # This is the "hack" that allows smartctl to read storage temperatures without root:
  # - smartctl needs SG_IO ioctl() operations to communicate with storage devices
  # - These operations are normally restricted to root (CAP_SYS_RAWIO capability)
  # - By granting CAP_SYS_RAWIO to smartctl specifically (not the user), we enable
  #   storage temperature monitoring without giving the user full root privileges
  # - This is safe because smartctl is a read-only diagnostic tool and cannot modify
  #   the storage device (unlike giving the user root or CAP_SYS_RAWIO directly)
  # - Combined with the udev rule (disk group + 0664 permissions), this allows
  #   non-root users in the disk group to monitor storage temperatures safely
  if command -v smartctl >/dev/null 2>&1; then
    SMARTCTL_PATH="$(command -v smartctl)"
    if getcap "$SMARTCTL_PATH" 2>/dev/null | grep -q "cap_sys_rawio"; then
      yellow "    → smartctl already has CAP_SYS_RAWIO capability"
    else
      setcap cap_sys_rawio+ep "$SMARTCTL_PATH" 2>/dev/null && \
        green "    → Set CAP_SYS_RAWIO capability on smartctl" || \
        yellow "    → Warning: Could not set CAP_SYS_RAWIO on smartctl (may need manual setup)"
    fi
  fi

  # Add user to disk group
  yellow "    → Adding user '${TARGET_USER}' to 'disk' group..."
  usermod -aG disk "$TARGET_USER"
  green "    → User '${TARGET_USER}' added to 'disk' group."
  echo
  
  # Set flag that user was just added
  STORAGE_TEMP_USER_JUST_ADDED=1
}

# ---------- log existence check (user + root) ---------------------------------

check_logs_presence() {
  echo "[*] Checking hardware logs in '${LOGDIR}':"
  echo

  local files=(
    "dmidecode.log"
    "mainboard.log"
    "cpuinfo.log"
    "processor.log"
    "gpuinfo.log"
  )

  local missing_any=0

  for f in "${files[@]}"; do
    if [[ -s "${LOGDIR}/${f}" ]]; then
      printf "  [\e[32m✓\e[0m] %s\n" "$f"
    else
      printf "  [!] %s missing or empty\n" "$f"
      missing_any=1
    fi
  done

  echo
  if [[ $missing_any -eq 1 ]]; then
    yellow "[!] Some hardware logs are missing."
    echo "    → Run this script with sudo to generate them:"
    echo
    echo "      sudo ./firstrun.sh"
    echo
  else
    green "[✓] All hardware logs are present."
    echo
  fi
}

# ---------- check disk group membership (user mode) ---------------------------

check_disk_group() {
  local current_user
  current_user="$(whoami)"

  echo "[*] Checking storage temperature access:"
  echo

  if groups "$current_user" 2>/dev/null | grep -q "\bdisk\b"; then
    green "  [✓] User '${current_user}' is in 'disk' group."
    echo "      Storage temperature monitoring will work without root."
    echo
  else
    yellow "  [!] User '${current_user}' is NOT in 'disk' group."
    echo "      Storage temperature monitoring requires root privileges."
    echo
    echo "      → Run this script with sudo to set up storage temperature access:"
    echo
    echo "        sudo ./firstrun.sh"
    echo
    echo "      This will:"
    echo "      - Create udev rule for storage access"
    echo "      - Add you to the 'disk' group"
    echo "      - Allow storage temperature reading without root"
    echo
  fi
}

# ---------- main --------------------------------------------------------------

print_header

if [[ $EUID -eq 0 ]]; then
  yellow "[*] Running in ROOT mode."
  echo
  ensure_host_id_root_mode
  install_deps_root_mode
  generate_all_logs_root_mode
  setup_storage_temp_access
  green "== All done! You can now run ./ghul-benchmark.sh =="
  echo
  
  # Only show warning if user was JUST added (not if they were already in group)
  if [[ -n "${STORAGE_TEMP_USER_JUST_ADDED:-}" ]]; then
    yellow "[!] Important: You were just added to the 'disk' group."
    echo "    For storage temperature monitoring to work without root, you need to:"
    echo "    - Log out and back in, OR"
    echo "    - Reboot your system"
    echo "    (This activates the new group membership)"
    echo
  fi
else
  echo "[*] Running in USER mode."
  echo
  check_deps_user_mode
  check_logs_presence
  check_disk_group
  green "You can already run ./ghul-benchmark.sh,"
  echo "but for full hardware details in JSON and storage temperature access,"
  echo "consider running: sudo ./firstrun.sh"
  echo
fi

