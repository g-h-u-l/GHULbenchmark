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
    [[ "${DISTRO_ID}" =~ (arch|manjaro|endeavouros) || "${DISTRO_LIKE}" == *arch* ]]
  else
    return 1
  fi
}

# ---------- dependency definitions --------------------------------------------

# Map: command → pacman package
DEP_CMDS=(
  "glmark2"
  "vkmark"
  "gputest"
  "iperf3"
  "speedtest"
  "mbw"
  "sysbench"
  "stress-ng"
  "7z"
  "glxinfo"
  "jq"
  "gamescope"
  "sensors"
  "fio"
  "smartctl"
)

DEP_PKGS=(
  "glmark2"        # glmark2
  "vkmark"         # vkmark
  "gputest"        # gputest
  "iperf3"         # iperf3
  "speedtest-cli"  # speedtest
  "mbw"            # mbw
  "sysbench"       # sysbench
  "stress-ng"      # stress-ng
  "p7zip"          # 7z
  "mesa-demos"     # glxinfo
  "jq"             # jq
  "gamescope"      # gamescope
  "lm_sensors"     # sensors
  "fio"            # fio
  "smartmontools"  # smartctl
)

# Sanity check: arrays must be same length
if [[ ${#DEP_CMDS[@]} -ne ${#DEP_PKGS[@]} ]]; then
  echo "Internal error: DEP_CMDS and DEP_PKGS length mismatch." >&2
  exit 1
fi

# ----- is it Arch based or what type of Linux machine we have here? -----------

# output the info that GHULbench was made for an arch based  rolling release
detect_distro
echo "Detected distro: ${DISTRO_ID} (like: ${DISTRO_LIKE})"
echo

if ! is_arch_like; then
  yellow "[!] GHUL firstrun was developed and tested on Arch-based systems (Manjaro, Arch, ...)."
  echo "    Automatic installation is disabled on this distro."
  echo
  echo "    You need the following tools (package names are Arch-style, but good hints):"
  printf '      - %s\n' "${DEP_PKGS[@]}"
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

  cat > "${HOST_ID_FILE}" <<EOF
{
  "vendor": "${vendor}",
  "product": "${product}",
  "serial": "${serial}",
  "id": "${id}"
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

ensure_host_id_root_mode() {
  echo "[*] GHUL Host ID (mainboard-based, JSON):"
  echo

  # Get current board data
  read_mainboard_fields
  local new_vendor="${MAINBOARD_VENDOR}"
  local new_product="${MAINBOARD_PRODUCT}"
  local new_serial="${MAINBOARD_SERIAL}"

  # If no JSON file exists yet: create a fresh one
  if [[ ! -f "${HOST_ID_FILE}" ]]; then
    local new_id
    new_id="$(generate_host_id_from_board "${new_vendor}" "${new_product}" "${new_serial}")"
    HOST_ID="${new_id}"
    write_host_id_json "${new_vendor}" "${new_product}" "${new_serial}" "${HOST_ID}"

    echo "    Mainboard vendor : ${new_vendor}"
    echo "    Mainboard product: ${new_product}"
    echo "    Mainboard serial : ${new_serial}"
    echo
    green "    → New GHUL Host ID: ${HOST_ID}"
    echo "      (stored in ${HOST_ID_FILE})"
    echo
    return 0
  fi

  # JSON file exists: read old values
  local old_vendor old_product old_serial old_id
  old_vendor="$(json_get_field "vendor"  "${HOST_ID_FILE}")"
  old_product="$(json_get_field "product" "${HOST_ID_FILE}")"
  old_serial="$(json_get_field "serial"  "${HOST_ID_FILE}")"
  old_id="$(json_get_field "id"      "${HOST_ID_FILE}")"

  # If vendor+product are unchanged → keep ID, even if serial changed
  if [[ "${old_vendor}" == "${new_vendor}" && "${old_product}" == "${new_product}" ]]; then
    HOST_ID="${old_id}"

    local serial_msg=""
    if [[ -n "${new_serial}" && "${new_serial}" != "unknown" && "${new_serial}" != "${old_serial}" ]]; then
      # Same board type, but different unit (new identical motherboard)
      write_host_id_json "${new_vendor}" "${new_product}" "${new_serial}" "${HOST_ID}"
      serial_msg="New, identical motherboard detected. ID change NOT needed."
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
    return 0
  fi

  # Otherwise: new board type → new ID
  local new_id
  new_id="$(generate_host_id_from_board "${new_vendor}" "${new_product}" "${new_serial}")"
  HOST_ID="${new_id}"
  write_host_id_json "${new_vendor}" "${new_product}" "${new_serial}" "${HOST_ID}"

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
}
# ---------- non-root dependency check -----------------------------------------

check_deps_user_mode() {
  echo "[*] Checking dependencies (user mode, no automatic install):"
  echo

  local missing_any=0
  local suggest_cmds=()

  for i in "${!DEP_CMDS[@]}"; do
    local cmd="${DEP_CMDS[$i]}"
    local pkg="${DEP_PKGS[$i]}"

    if have "$cmd"; then
      printf "  [\e[32m✓\e[0m] %-10s (command: %s)\n" "$pkg" "$cmd"
    else
      printf "  [ ] %-10s (command: %s)  → install with: sudo pacman -S %s\n" "$pkg" "$cmd" "$pkg"
      missing_any=1
      suggest_cmds+=("$pkg")
    fi
  done

  echo
  if [[ $missing_any -eq 1 ]]; then
    yellow "[!] Some dependencies are missing."
    echo "    Suggested installation command:"
    echo
    echo "      sudo pacman -S ${suggest_cmds[*]}"
    echo
  else
    green "[✓] All dependencies are already installed."
  fi

  echo
}

# ---------- root-mode: install deps -------------------------------------------

install_deps_root_mode() {
  echo "[*] Checking dependencies (root mode, automatic install):"
  echo

  local missing_pkgs=()

  for i in "${!DEP_CMDS[@]}"; do
    local cmd="${DEP_CMDS[$i]}"
    local pkg="${DEP_PKGS[$i]}"

    if have "$cmd"; then
      printf "  [\e[32m✓\e[0m] %-10s (command: %s)\n" "$pkg" "$cmd"
    else
      printf "  [ ] %-10s (command: %s)  → will install\n" "$pkg" "$cmd"
      missing_pkgs+=("$pkg")
    fi
  done

  echo
  if (( ${#missing_pkgs[@]} > 0 )); then
    yellow "[*] Installing missing packages via pacman:"
    echo "    pacman -S --needed ${missing_pkgs[*]}"
    echo
    pacman -S --needed "${missing_pkgs[@]}"
    echo
    green "[✓] Dependency installation complete."
  else
    green "[✓] All dependencies already installed."
  fi

  echo
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

