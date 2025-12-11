#!/usr/bin/env bash
# GHUL - Gaming Hardware Using Linux
# Local benchmark runner — writes ONE JSON file per run (no database).
# Outputs: results/YYYY-mm-dd-hh-mm-hostname.json
# Logs:    logs/runs/*.log / *.json
#
# Requires (install beforehand): jq, iperf3, mbw, sysbench, glmark2, vkmark, glxinfo (mesa-demos)
# On Manjaro:
#   sudo pacman -Syu glmark2 sysbench vkmark mesa-demos jq iperf3
#   pamac build mbw   # or: yay -S mbw
# 
#
# Design:
# - Set -euo pipefail for strictness, but wrap optional tools via `cap` helper to avoid aborts.
# - Always produce a valid JSON file, even if some tools are missing.
# - Use --arg (strings) + `| tonumber? // 0` instead of --argjson to avoid jq parse errors.

set -euo pipefail

# GHUL version
GHUL_VERSION="0.2"
GHUL_REPO="g-h-u-l/GHULbenchmark"
GHUL_REPO_URL="https://github.com/${GHUL_REPO}"

# Enforce predictable C locale (important for awk/jq and numeric formatting)
export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

# give me some hint why the crash happened
trap 'echo "[GHUL] aborted on line $LINENO (exit=$?)" >&2' ERR

# Ensure we are run inside the GHULbenchmark directory
if [[ ! -d "logs" || ! -d "results" ]]; then
  echo "[GHUL] Please run this script from your GHULbenchmark directory." >&2
  echo "[GHUL] Expected to find ./logs and ./results here." >&2
  exit 1
fi

# ---------- Update check ----------------------------------------------------------
check_for_updates() {
  # Skip update check if GHUL_NO_UPDATE_CHECK is set
  [[ -n "${GHUL_NO_UPDATE_CHECK:-}" ]] && return 0
  
  # Check if we have internet and curl/wget
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    return 0  # No way to check, skip silently
  fi
  
  # Get latest release tag from GitHub API
  local latest_version=""
  if command -v curl >/dev/null 2>&1; then
    latest_version="$(curl -s "https://api.github.com/repos/${GHUL_REPO}/releases/latest" 2>/dev/null | \
      grep -o '"tag_name": "[^"]*' | cut -d'"' -f4 | sed 's/^v//' || echo "")"
  elif command -v wget >/dev/null 2>&1; then
    latest_version="$(wget -qO- "https://api.github.com/repos/${GHUL_REPO}/releases/latest" 2>/dev/null | \
      grep -o '"tag_name": "[^"]*' | cut -d'"' -f4 | sed 's/^v//' || echo "")"
  fi
  
  # If no release found, try to get version from main branch (fallback)
  if [[ -z "$latest_version" ]]; then
    if command -v curl >/dev/null 2>&1; then
      latest_version="$(curl -s "https://raw.githubusercontent.com/${GHUL_REPO}/main/ghul-benchmark.sh" 2>/dev/null | \
        grep -m1 '^GHUL_VERSION=' | cut -d'"' -f2 || echo "")"
    elif command -v wget >/dev/null 2>&1; then
      latest_version="$(wget -qO- "https://raw.githubusercontent.com/${GHUL_REPO}/main/ghul-benchmark.sh" 2>/dev/null | \
        grep -m1 '^GHUL_VERSION=' | cut -d'"' -f2 || echo "")"
    fi
  fi
  
  # Compare versions (semantic versioning comparison)
  # Only show update message if latest_version is actually newer than current
  if [[ -n "$latest_version" && "$latest_version" != "$GHUL_VERSION" ]]; then
    # Simple version comparison: split by dots and compare numerically
    local current_major current_minor latest_major latest_minor
    IFS='.' read -r current_major current_minor <<< "$GHUL_VERSION"
    IFS='.' read -r latest_major latest_minor <<< "$latest_version"
    
    # Check if latest version is actually newer
    local is_newer=0
    if [[ "$latest_major" -gt "$current_major" ]] || \
       ([[ "$latest_major" -eq "$current_major" ]] && [[ "$latest_minor" -gt "$current_minor" ]]); then
      is_newer=1
    fi
    
    if [[ $is_newer -eq 1 ]]; then
      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  ⚠  GHUL Update Available!"
      echo ""
      echo "  Current version: ${GHUL_VERSION}"
      echo "  Latest version:   ${latest_version}"
      echo ""
      echo "  Update with:"
      echo "    cd $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      echo "    git pull origin main"
      echo ""
      echo "  Or visit: ${GHUL_REPO_URL}/releases"
      echo ""
      read -p "  Continue with benchmark anyway? [Y/n] " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ -n "$REPLY" ]]; then
        echo "  Benchmark cancelled."
        exit 0
      fi
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
    fi
  fi
}

# Run update check (non-blocking, continues on error)
check_for_updates || true

# --------- paths ----------------------------------------------------------------
# Get absolute path of this script (GHULbenchmark base dir)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${BASE}/results"
LOGDIR="${BASE}/logs/runs"
SENSORSDIR="${BASE}/logs/sensors"
# Create all necessary directories upfront
mkdir -p "${OUTDIR}" "${LOGDIR}" "${SENSORSDIR}"

TS="$(date +%Y-%m-%d-%H-%M)"
HOST="$(hostname)"
OUTFILE="${OUTDIR}/${TS}-${HOST}.json"

echo "== GHUL Benchmark (${HOST} @ ${TS}) =="

# --------- GHUL Host ID (optional, from .ghul_host_id.json) --------------------
HOST_ID_FILE="${BASE}/.ghul_host_id.json"
GHUL_HOST_ID="missing"
GHUL_HOST_VENDOR="missing"
GHUL_HOST_PRODUCT="missing"
GHUL_HOST_SERIAL="missing"

if [[ -f "${HOST_ID_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  # Safely read fields from JSON; fall back to "missing" if something is odd
  GHUL_HOST_ID="$(jq -r '.id      // "missing"' "${HOST_ID_FILE}" 2>/dev/null || echo "missing")"
  GHUL_HOST_VENDOR="$(jq -r '.vendor  // "missing"' "${HOST_ID_FILE}" 2>/dev/null || echo "missing")"
  GHUL_HOST_PRODUCT="$(jq -r '.product // "missing"' "${HOST_ID_FILE}" 2>/dev/null || echo "missing")"
  GHUL_HOST_SERIAL="$(jq -r '.serial  // "missing"' "${HOST_ID_FILE}" 2>/dev/null || echo "missing")"
fi

# --------- helpers --------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }          # true if command exists
cap()  { "$@" 2>/dev/null || true; }                 # run command, never fail

# JSON accumulator
JSON='{}'
add_obj() { JSON="$(printf '%s' "$JSON" | jq --arg k "$1" --argjson v "$2" '. + {($k): $v}')" ; }
add_kv()  { JSON="$(printf '%s' "$JSON" | jq --arg k "$1" --arg v "$2"     '. + {($k): $v}')" ; }

# Timeline accumulator: marks start timestamps of each major phase
TIMELINE_JSON='[]'

mark_event() {
  local name="$1"
  local ts_epoch="${2:-$(date +%s)}"  # Allow passing epoch as second argument
  TIMELINE_JSON="$(printf '%s' "$TIMELINE_JSON" \
    | jq --arg n "$name" --argjson t "$ts_epoch" '. + [{name:$n, epoch:$t}]')"
}

# --------- Start sensor watch (synchronized with run_start) --------------------
# Set run start epoch RIGHT BEFORE starting sensor helper for perfect sync
RUN_START_EPOCH="$(date +%s)"
RUN_START_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

SENSORS_HELPER="${BASE}/tools/ghul-sensors-helper.sh"
SENSORS_PIDFILE="${SENSORSDIR}/.ghul_sensors.pid"
# Directory already created above, but ensure it exists
mkdir -p "${SENSORSDIR}"

echo "[GHUL] Starting sensors helper..."

# Pass run timestamp and pidfile path into helper
export GHUL_RUN_TS="$TS"
export GHUL_SENSORS_PIDFILE="$SENSORS_PIDFILE"

# Start sensor helper in background
bash "$SENSORS_HELPER" &
SENSORS_PID=$!
# Give sensor helper a moment to initialize (but don't wait too long)
sleep 0.5

# Mark run_start with the SAME epoch we used for sensor helper
mark_event "run_start" "$RUN_START_EPOCH"

# Safe numeric merge: pass string, cast inside jq
jq_num_set() { # $1=json, $2=key, $3=value
  printf '%s' "$1" | jq --arg k "$2" --arg v "${3:-0}" '. + {($k): ($v|tonumber? // 0)}'
}

# --------- environment capture --------------------------------------------------
mark_event "env_start"
echo "-- Capturing environment..."

# Kernel & OS
kernel="$(uname -r)"
os="$(cap grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')"
os="${os:-unknown}"

# CPU model (robust for English/German lscpu; fallback /proc/cpuinfo)
cpu_model="$(cap lscpu 2>/dev/null | awk -F: '
  /Model name|Modellname/ {
    gsub(/^[ \t]+|[ \t]+$/, "", $2);
    print $2;
    exit
  }')"
if [[ -z "${cpu_model}" ]]; then
  cpu_model="$(awk -F: '
    /model name|Modellname/ {
      gsub(/^[ \t]+|[ \t]+$/, "", $2);
      print $2;
      exit
    }' /proc/cpuinfo 2>/dev/null || true)"
fi
cpu_model="${cpu_model:-unknown}"

threads="$(cap nproc)"; threads="${threads:-0}"
mem_total_kib="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"; mem_total_kib="${mem_total_kib:-0}"

# ---- GPU manufacturer + model extraction ----
gpu_man="unknown"
gpu_model="unknown"
gpu_vendor="unknown"  # v0.2: lowercase vendor for sensor detection (amd/nvidia/intel/unknown)

# Method 1: Try nvidia-smi first (most reliable for NVIDIA GPUs)
if have nvidia-smi; then
  gpu_model="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 | xargs || echo "")"
  if [[ -n "$gpu_model" && "$gpu_model" != "" ]]; then
    gpu_man="NVIDIA"
    gpu_vendor="nvidia"
    # gpu_model is already set from nvidia-smi
  fi
fi

# Method 2: Fallback to lspci if nvidia-smi didn't work or for non-NVIDIA GPUs
if [[ "$gpu_model" == "unknown" || -z "$gpu_model" ]]; then
  if have lspci; then
    # First VGA/3D card
    l="$(LC_ALL=C lspci -nn | grep -Ei 'VGA compatible controller|3D controller' | head -n1 || true)"
    if [[ -n "$l" ]]; then
      # Hersteller
      if echo "$l" | grep -qi 'NVIDIA'; then
        gpu_man="NVIDIA"
        gpu_vendor="nvidia"
      elif echo "$l" | grep -qi 'AMD\|ATI'; then
        gpu_man="AMD"
        gpu_vendor="amd"
      elif echo "$l" | grep -qi 'Intel'; then
        gpu_man="Intel"
        gpu_vendor="intel"
      fi

      # try to fetch model in square brackets (Radeon ...)
      gpu_model="$(echo "$l" | sed -n 's/.*\[\(Radeon[^]]*\)\].*/\1/p')"

      # Fallback: text after "controller:" without brackets
      if [[ -z "$gpu_model" ]]; then
        gpu_model="$(echo "$l" \
          | sed -n 's/.*controller:[[:space:]]*\(.*\)/\1/p' \
          | sed 's/\[[^]]*\]//g' \
          | sed 's/(.*)//' \
          | xargs)"
      fi

      [[ -z "$gpu_model" ]] && gpu_model="unknown"
    fi
  fi
fi

# Final fallback: if still unknown, set to "unknown"
[[ -z "$gpu_model" || "$gpu_model" == "" ]] && gpu_model="unknown"

# OpenGL info (optional)
# gpu_renderer should match gpu_model (clean GPU name without /PCIe/SSE2 suffixes)
gpu_renderer="$gpu_model"
opengl_version="missing"
if have glxinfo; then
  # If gpu_model is still unknown, try to extract from OpenGL renderer string
  if [[ "$gpu_renderer" == "unknown" || -z "$gpu_renderer" ]]; then
    # Extract GPU renderer name (remove /PCIe/SSE2 etc. suffixes)
    gpu_renderer="$(cap glxinfo | awk -F: '
      /OpenGL renderer/ {
        sub(/^ /,"",$2);
        # Remove everything after first "/" (e.g. "/PCIe/SSE2")
        gsub(/\/.*$/,"",$2);
        print $2;
        exit
      }')"
    [[ -z "$gpu_renderer" ]] && gpu_renderer="unknown"
  fi
  
  opengl_version="$(cap glxinfo | awk -F: '
    /OpenGL version/  {sub(/^ /,"",$2); print $2; exit}')"
fi


# --- capturing Mainboard Information (robust, multi-source) ---

mb_man="unknown"
mb_prod="unknown"
mb_ver="unknown"

# /sys/dmi/id → works without sudo
if [[ -r /sys/devices/virtual/dmi/id/board_vendor ]]; then
  mb_man="$(cat /sys/devices/virtual/dmi/id/board_vendor)"
fi
if [[ -r /sys/devices/virtual/dmi/id/board_name ]]; then
  mb_prod="$(cat /sys/devices/virtual/dmi/id/board_name)"
fi
if [[ -r /sys/devices/virtual/dmi/id/board_version ]]; then
  mb_ver="$(cat /sys/devices/virtual/dmi/id/board_version)"
fi


# lshw (optional if installed)
if [[ "$mb_prod" == "unknown" ]] && have lshw; then
  tmp="$(lshw -quiet -C bus 2>/dev/null || true)"
  if [[ -n "$tmp" ]]; then
    mb_man2="$(echo "$tmp" | awk -F: '/vendor:/ {print $2}' | xargs || true)"
    mb_prod2="$(echo "$tmp" | awk -F: '/product:/ {print $2}' | xargs || true)"
    [[ -n "$mb_man2"  ]] && mb_man="$mb_man2"
    [[ -n "$mb_prod2" ]] && mb_prod="$mb_prod2"
  fi
fi

# writing captured environment info as json

ENV_JSON="$(jq -n \
  --arg host     "$HOST" \
  --arg time     "$TS" \
  --arg kernel   "$kernel" \
  --arg os       "$os" \
  --arg cpu      "$cpu_model" \
  --arg gpu_rend "$gpu_renderer" \
  --arg gl       "$opengl_version" \
  --arg mb_man   "$mb_man" \
  --arg mb_prod  "$mb_prod" \
  --arg mb_ver   "$mb_ver" \
  --arg gpu_man  "$gpu_man" \
  --arg gpu_model "$gpu_model" \
  --arg gpu_vend "$gpu_vendor" \
  --arg gh_id    "$GHUL_HOST_ID" \
  --arg gh_vend  "$GHUL_HOST_VENDOR" \
  --arg gh_prod  "$GHUL_HOST_PRODUCT" \
  --arg gh_ser   "$GHUL_HOST_SERIAL" \
  --argjson threads "${threads:-0}" \
  --argjson mem_kib "${mem_total_kib:-0}" \
  '{
     hostname:        $host,
     timestamp:       $time,
     kernel:          $kernel,
     os:              $os,
     cpu:             $cpu,
     threads:         $threads,
     mem_total_kib:   $mem_kib,
     mainboard: {
       manufacturer:  $mb_man,
       product:       $mb_prod,
       version:       $mb_ver
     },
     gpu_manufacturer: $gpu_man,
     gpu_model:        $gpu_model,
     gpu_vendor:       $gpu_vend,
     gpu_renderer:     $gpu_rend,
     opengl_version:   $gl,
     ghul_host: {
       id:      $gh_id,
       vendor:  $gh_vend,
       product: $gh_prod,
       serial:  $gh_ser
     }
   }')"


add_obj "environment" "$ENV_JSON"


# --------- RAM tests ------------------------------------------------------------
mark_event "ram_start"
echo "-- RAM tests..."
RAM_JSON='{}'

###############################################
# DMI PARSER – parse_dmidecode_memory()
###############################################
parse_dmidecode_memory() {
  local file="$1"
  local json="[]"
  local current="{}"
  local in_block=0

  while IFS= read -r line; do
    # Start of a DIMM block
    if [[ "$line" =~ ^Handle.*DMI\ type\ 17 ]]; then
      if [[ $in_block -eq 1 ]]; then
        json=$(printf '%s' "$json" | jq --argjson obj "$current" '. + [$obj]')
      fi
      in_block=1
      current="{}"
      continue
    fi

    # Inside a DIMM block
    if [[ $in_block -eq 1 ]]; then
      key=$(echo "$line" | cut -d: -f1 | sed 's/^[ \t]*//;s/[ \t]*$//;s/ /_/g' | tr 'A-Z' 'a-z')
      val=$(echo "$line" | cut -d: -f2- | sed 's/^[ \t]*//;s/[ \t]*$//')

      if [[ -n "$key" && -n "$val" ]]; then
        current=$(printf '%s' "$current" \
          | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
      fi
    fi
  done <"$file"

  # Append last block
  if [[ $in_block -eq 1 ]]; then
    json=$(printf '%s' "$json" | jq --argjson obj "$current" '. + [$obj]')
  fi

  echo "$json"
}

###############################################
# mbw (Memcpy)
###############################################
echo "   mbw (Memcpy)"

if have mbw; then
  mbw_log="${LOGDIR}/ram_mbw_${TS}.log"
  LC_ALL=C LANG=C mbw -n 3 1024 | tee "$mbw_log" >/dev/null || true

  mbw_val="$(grep -i 'Copy:' "$mbw_log" | tail -1 | sed -nE 's/.*Copy:[[:space:]]*([0-9]+(\.[0-9]+)?)\s*MiB\/s.*/\1/p')"
  mbw_val="${mbw_val:-0}"

  # MiB/s to JSON
  RAM_JSON="$(printf '%s' "$RAM_JSON" | jq --arg v "$mbw_val" \
    '. + {mbw_memcpy_mib_s: ($v|tonumber? // 0)}')"

  # additionally: GiB/s (human readable)
  # 1 GiB/s = 1024 MiB/s
  mbw_gib="$(awk "BEGIN{printf \"%.3f\", ${mbw_val}/1024}")"
  RAM_JSON="$(printf '%s' "$RAM_JSON" | jq --arg v "$mbw_gib" \
    '. + {mbw_memcpy_gib_s: ($v|tonumber? // 0)}')"
else
  RAM_JSON="$(printf '%s' "$RAM_JSON" | jq \
    '. + {mbw_memcpy_mib_s:"missing", mbw_memcpy_gib_s:"missing"}')"
fi

###############################################
# sysbench (seq write)
###############################################
if have sysbench; then
  sys_log="${LOGDIR}/ram_sysbench_${TS}.log"
  LC_ALL=C LANG=C sysbench memory \
    --memory-oper=write \
    --memory-access-mode=seq \
    --memory-total-size=2G \
    --memory-block-size=1M \
    --threads=1 \
    --time=10 run \
    | tee "$sys_log" >/dev/null || true

  sys_val="$(sed -nE 's/.*\(([0-9]+(\.[0-9]+)?) MiB\/sec\).*/\1/p' "$sys_log" | tail -1)"
  sys_val="${sys_val:-0}"

  RAM_JSON=$(printf '%s' "$RAM_JSON" | jq \
    --arg v "$sys_val" '. + {sysbench_seq_write_mib_s: ($v|tonumber? // 0)}')
else
  RAM_JSON=$(printf '%s' "$RAM_JSON" | jq '. + {sysbench_seq_write_mib_s:"missing"}')
fi

###############################################
# dmidecode: only read logs/dmidecode.log
###############################################
if [[ -f logs/dmidecode.log ]]; then
  dimm_json="$(parse_dmidecode_memory logs/dmidecode.log)"

  RAM_JSON="$(printf '%s' "$RAM_JSON" \
    | jq --argjson arr "$dimm_json" '
      . + {
        dmidecode_status: "ok",
        memory_devices:   $arr
      }
      # Derive RAM speed from memory_devices:
      # Take the max numerical value from "speed" / "configured_memory_speed".
      | (
          [ $arr[]
            | (.speed // .configured_memory_speed // empty)
            | gsub("[^0-9]"; "")          # strip everything except digits
            | select(length > 0)
            | tonumber
          ] | max?
        ) as $spd
      | if $spd == null then
          . + { ram_speed_mhz: 0, ram_speed_mts: 0 }
        else
          . + {
            ram_speed_mts: $spd,
            ram_speed_mhz: ($spd / 2 | floor)
          }
        end
    ')"
else
  RAM_JSON="$(printf '%s' "$RAM_JSON" \
    | jq '. + {
         dmidecode_status:"missing",
         memory_devices:[],
         ram_speed_mhz: 0,
         ram_speed_mts: 0
       }')"
fi


# --- fix RAM manufacturer using part_number patterns (best effort) ---
RAM_JSON="$(printf '%s' "$RAM_JSON" | jq '
  # map common RAM part-number prefixes to vendors
  def vendor_from_part(p):
    if   (p | startswith("F4-"))         then "G.Skill"
    elif (p | startswith("CM"))          then "Corsair"
    elif (p | startswith("CMT"))         then "Corsair"
    elif (p | startswith("CMK"))         then "Corsair"
    elif (p | startswith("CMW"))         then "Corsair"
    elif (p | startswith("KHX"))         then "Kingston"
    elif (p | startswith("HX"))          then "Kingston"
    elif (p | startswith("KVR"))         then "Kingston"
    elif (p | startswith("CT"))          then "Crucial"
    elif (p | startswith("BLS"))         then "Crucial Ballistix"
    else null
    end;

  if has("memory_devices") then
    .memory_devices |= (
      map(
        if
          (.manufacturer == "Unknown"
           or .manufacturer == "unknown"
           or .manufacturer == "UNKNOWN")
          and (.part_number // "" | length > 0)
        then
          .manufacturer = (vendor_from_part(.part_number) // .manufacturer)
        else
          .
        end
      )
    )
  else
    .
  end
')"


# Add to master JSON
add_obj "ram" "$RAM_JSON"

# --------- Storage tests -------------------------------------------------------
mark_event "storage_start"
echo "-- Storage tests..."
STORAGE_JSON='[]'

if have fio; then
  # Test on mounted filesystems (works without root, more realistic for gaming)
  # Find all mounted filesystems, skip system mounts like /proc, /sys, /dev
  # df -T output: Filesystem Type 1K-blocks Used Available Use% Mounted on
  while IFS= read -r line; do
    # Skip header line and empty lines
    [[ "$line" =~ ^(Filesystem|Dateisystem) ]] && continue
    [[ -z "$line" ]] && continue
    
    device="$(echo "$line" | awk '{print $1}')"
    fstype="$(echo "$line" | awk '{print $2}')"
    mount_point="$(echo "$line" | awk '{print $NF}')"  # Last field is mount point
    device_name="$(basename "$device")"
    
    # Skip if device is not a real block device (skip tmpfs, devtmpfs, etc.)
    [[ ! "$device" =~ ^/dev/ ]] && continue
    
    # Skip system filesystems (but allow root / and /home)
    [[ "$mount_point" =~ ^/(proc|sys|dev|run|boot/efi) ]] && continue
    [[ "$fstype" =~ ^(proc|sysfs|devtmpfs|tmpfs|devpts|cgroup|pstore|bpf|tracefs|debugfs|securityfs|hugetlbfs|mqueue|overlay|efivarfs) ]] && continue
    
    # Special handling for root partition: if not writable, use $HOME instead
    if [[ "$mount_point" == "/" ]]; then
      if [[ ! -w "/" ]]; then
        # Root not writable, use $HOME instead (which is on the same partition)
        mount_point="${HOME}"
        echo "   Note: Root partition not writable, testing $HOME instead"
      fi
    fi
    
    # Skip if mount point doesn't exist
    [[ ! -d "$mount_point" ]] && continue
    
    # Skip if not writable (except we already handled root above)
    if [[ "$mount_point" != "${HOME}" ]] && [[ ! -w "$mount_point" ]]; then
      continue
    fi
    
    # Get device info from lsblk
    # Extract base device name (sda1 -> sda, sdb2 -> sdb, nvme0n1p1 -> nvme0n1)
    # For regular devices: remove partition number (sda1 -> sda)
    # For NVMe: extract up to n1 (nvme0n1p1 -> nvme0n1)
    if [[ "$device_name" =~ ^nvme ]]; then
      base_device="$(echo "$device_name" | sed -E 's/(nvme[0-9]+n[0-9]+).*/\1/')"
    else
      base_device="$(echo "$device_name" | sed -E 's/([a-z]+)([0-9]+).*/\1/')"
    fi
    device_info="$(lsblk -d -n -o NAME,SIZE,MODEL "/dev/${base_device}" 2>/dev/null || true)"
    device_size="$(echo "$device_info" | awk '{print $2}')"
    device_model="$(echo "$device_info" | awk -F' ' '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')"
    
    echo "   Testing: ${device_name} @ ${mount_point} (${device_model:-unknown}, ${device_size:-unknown})"
    
    # Create temporary test file on this filesystem
    test_file="${mount_point}/.ghul_fio_test_${TS}.tmp"
    storage_log="${LOGDIR}/storage_fio_${device_name}_${TS}.json"
    
    # Run fio tests on filesystem (no --direct, works without root)
    # Sequential Read/Write and Random 4K Read/Write
    cap fio --output-format=json --output="$storage_log" \
      --name=seq_read --filename="$test_file" --rw=read --bs=1M --size=1G --iodepth=1 --runtime=30 \
      --name=seq_write --filename="$test_file" --rw=write --bs=1M --size=1G --iodepth=1 --runtime=30 \
      --name=rand4k_read --filename="$test_file" --rw=randread --bs=4k --size=1G --iodepth=32 --runtime=30 \
      --name=rand4k_write --filename="$test_file" --rw=randwrite --bs=4k --size=1G --iodepth=32 --runtime=30 \
      >/dev/null 2>&1 || true
    
    # Clean up test file
    rm -f "$test_file" 2>/dev/null || true
    
    # Parse fio JSON output
    if [[ -f "$storage_log" ]]; then
      # Extract results for each job
      seq_read_bw="$(jq -r '.jobs[] | select(.jobname=="seq_read") | .read.bw // 0' "$storage_log" 2>/dev/null || echo 0)"
      seq_read_iops="$(jq -r '.jobs[] | select(.jobname=="seq_read") | .read.iops // 0' "$storage_log" 2>/dev/null || echo 0)"
      seq_write_bw="$(jq -r '.jobs[] | select(.jobname=="seq_write") | .write.bw // 0' "$storage_log" 2>/dev/null || echo 0)"
      seq_write_iops="$(jq -r '.jobs[] | select(.jobname=="seq_write") | .write.iops // 0' "$storage_log" 2>/dev/null || echo 0)"
      rand4k_read_bw="$(jq -r '.jobs[] | select(.jobname=="rand4k_read") | .read.bw // 0' "$storage_log" 2>/dev/null || echo 0)"
      rand4k_read_iops="$(jq -r '.jobs[] | select(.jobname=="rand4k_read") | .read.iops // 0' "$storage_log" 2>/dev/null || echo 0)"
      rand4k_write_bw="$(jq -r '.jobs[] | select(.jobname=="rand4k_write") | .write.bw // 0' "$storage_log" 2>/dev/null || echo 0)"
      rand4k_write_iops="$(jq -r '.jobs[] | select(.jobname=="rand4k_write") | .write.iops // 0' "$storage_log" 2>/dev/null || echo 0)"
      
      # Convert bandwidth from KiB/s to MB/s
      seq_read_mbps="$(awk "BEGIN{printf \"%.2f\", ${seq_read_bw}/1024}")"
      seq_write_mbps="$(awk "BEGIN{printf \"%.2f\", ${seq_write_bw}/1024}")"
      rand4k_read_mbps="$(awk "BEGIN{printf \"%.2f\", ${rand4k_read_bw}/1024}")"
      rand4k_write_mbps="$(awk "BEGIN{printf \"%.2f\", ${rand4k_write_bw}/1024}")"
      
      # Create device JSON object
      device_json="$(jq -n \
        --arg dev "$device_name" \
        --arg mount "$mount_point" \
        --arg model "${device_model:-unknown}" \
        --arg size "${device_size:-unknown}" \
        --argjson seq_read_mbps "$seq_read_mbps" \
        --argjson seq_read_iops "$seq_read_iops" \
        --argjson seq_write_mbps "$seq_write_mbps" \
        --argjson seq_write_iops "$seq_write_iops" \
        --argjson rand4k_read_mbps "$rand4k_read_mbps" \
        --argjson rand4k_read_iops "$rand4k_read_iops" \
        --argjson rand4k_write_mbps "$rand4k_write_mbps" \
        --argjson rand4k_write_iops "$rand4k_write_iops" \
        '{
          device: $dev,
          mount_point: $mount,
          model: $model,
          size: $size,
          sequential_read_mbps: $seq_read_mbps,
          sequential_read_iops: $seq_read_iops,
          sequential_write_mbps: $seq_write_mbps,
          sequential_write_iops: $seq_write_iops,
          random_4k_read_mbps: $rand4k_read_mbps,
          random_4k_read_iops: $rand4k_read_iops,
          random_4k_write_mbps: $rand4k_write_mbps,
          random_4k_write_iops: $rand4k_write_iops
        }')"
      
      STORAGE_JSON="$(printf '%s' "$STORAGE_JSON" | jq --argjson dev "$device_json" '. + [$dev]')"
    fi
  done < <(df -T 2>/dev/null | tail -n +2 || true)
  
  if [[ "$STORAGE_JSON" == "[]" ]]; then
    STORAGE_JSON='{"status":"no_filesystems_found"}'
  fi
else
  STORAGE_JSON='{"status":"fio_missing"}'
fi

add_obj "storage" "$STORAGE_JSON"

# --------- CPU tests -----------------------------------------------------------
mark_event "cpu_start"
echo "-- CPU tests..."
CPU_JSON='{}'

# --- stress-ng: matrix + crypt -------------------------------------------------
if have stress-ng; then
  echo "   stress-ng"
  cpu_stress_log="${LOGDIR}/cpu_stressng_${TS}.log"

  # Run stress-ng with matrix + crypt, all CPUs, fixed time, metrics summary
  env LANG=C LC_ALL=C LC_NUMERIC=C \
    stress-ng --matrix 0 --crypt 0 --timeout 20 --metrics-brief \
    >"$cpu_stress_log" 2>&1 || true

  # Parse bogo-ops from the metrics lines:
  # Example:
  # stress-ng: metrc: [13331] matrix           451795 ...
  # stress-ng: metrc: [13331] crypt            203030 ...
  m_bogo="$(
    awk '
      /metrc:/ && $4 == "matrix" {
        print $5;
        found=1;
      }
      END {
        if (!found) print "";
      }
    ' "$cpu_stress_log"
  )"

  c_bogo="$(
    awk '
      /metrc:/ && $4 == "crypt" {
        print $5;
        found=1;
      }
      END {
        if (!found) print "";
      }
    ' "$cpu_stress_log"
  )"

  [[ -z "$m_bogo" ]] && m_bogo=0
  [[ -z "$c_bogo" ]] && c_bogo=0

  CPU_JSON="$(printf '%s' "$CPU_JSON" | jq --arg v "$m_bogo" \
      '. + {stressng_matrix_bogo_ops: ($v|tonumber? // 0)}')"
  CPU_JSON="$(printf '%s' "$CPU_JSON" | jq --arg v "$c_bogo" \
      '. + {stressng_crypt_bogo_ops: ($v|tonumber? // 0)}')"
else
  CPU_JSON="$(printf '%s' "$CPU_JSON" | jq \
      '. + {stressng_matrix_bogo_ops:"missing", stressng_crypt_bogo_ops:"missing"}')"
fi


# --- 7-Zip benchmark -----------------------------------------------------------
if have 7z; then
  echo "   7-zip kompressor"
  cpu_7z_log="${LOGDIR}/cpu_7z_${TS}.log"

  # 7-Zip built-in CPU benchmark
  # This can run a bit longer, but is a well-known synthetic CPU test.
  env LANG=C LC_ALL=C 7z b >"$cpu_7z_log" 2>&1 || true

  # In the summary there is typically a 'Tot:' line with overall MIPS.
  # We grab the last field from the last 'Tot:' line.
  p7_tot="$(grep -E '^Tot:' "$cpu_7z_log" | awk '{print $NF}' | tail -1)"
  [[ -z "$p7_tot" ]] && p7_tot=0

  CPU_JSON="$(printf '%s' "$CPU_JSON" | jq --arg v "$p7_tot" \
      '. + {p7zip_tot_mips: ($v|tonumber? // 0)}')"
else
  CPU_JSON="$(printf '%s' "$CPU_JSON" | jq '. + {p7zip_tot_mips:"missing"}')"
fi

# Attach CPU section to global JSON
add_obj "cpu" "$CPU_JSON"


# --------- Network (loopback TCP/UDP) ------------------------------------------
mark_event "net_local_start"
echo "-- Local network tests (loopback)..."
NET_JSON='{}'

if have iperf3 && have jq; then
  # TCP
  tcp_log="${LOGDIR}/net_tcp_${TS}.json"
  # Kill any existing iperf3 servers on port 5201
  pkill -f "iperf3.*5201" 2>/dev/null || true
  sleep 0.1
  ( cap iperf3 -s -1 -B 127.0.0.1 -p 5201 >/dev/null 2>&1 & ); sleep 0.3
  LC_ALL=C LANG=C iperf3 -J -c 127.0.0.1 -t 5 -P 4 -p 5201 | tee "$tcp_log" >/dev/null || true
  # Kill TCP server
  pkill -f "iperf3.*5201" 2>/dev/null || true
  sleep 0.1
  tcp_bps="$(jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // 0' "$tcp_log" 2>/dev/null || echo 0)"
  tcp_mbps="$(awk "BEGIN{print ${tcp_bps:-0}/1e6}")"
  NET_JSON="$(printf '%s' "$NET_JSON" | jq --arg v "$tcp_mbps" '. + {tcp_mbps: ($v|tonumber? // 0)}')"

  # --- UDP test (client sends, server receives) ---
  udp_log="${LOGDIR}/net_udp_${TS}.json"
  # Kill any existing iperf3 servers on port 5202
  pkill -f "iperf3.*5202" 2>/dev/null || true
  sleep 0.3
  # Start UDP server in background using timeout (more reliable than -1 flag)
  # Use timeout to ensure server doesn't hang, but runs long enough for test
  # Note: -u (UDP) is specified on client side, server just listens on port
  timeout 15 iperf3 -s -p 5202 >/dev/null 2>&1 &
  UDP_SERVER_PID=$!
  # Wait for server to be ready (check if process is running)
  sleep 1.0
  # Verify server is running before starting client
  if ! kill -0 "$UDP_SERVER_PID" 2>/dev/null; then
    echo "   [!] UDP server failed to start, skipping UDP test"
    udp_mbps=0
    udp_jitter=0
    udp_loss=0
  else
    # Run UDP test (normal mode: client sends, server receives)
    # Note: We test client->server direction, which is more relevant for gaming (client upload)
    LC_ALL=C LANG=C iperf3 -J -u -b 200M -l 1200 -t 5 -c 127.0.0.1 -p 5202 \
      | tee "$udp_log" >/dev/null || true
    # Kill UDP server
    kill "$UDP_SERVER_PID" 2>/dev/null || true
    pkill -f "iperf3.*5202" 2>/dev/null || true
    
    # Parse UDP results
    udp_bps="$(jq -r '
       .end.sum_sent.bits_per_second
    // .end.sum_received.bits_per_second
    // .end.sum.bits_per_second
    // .intervals[-1].sum.bits_per_second
    // 0' "$udp_log" 2>/dev/null || echo 0)"
    udp_mbps="$(awk "BEGIN{print ${udp_bps:-0}/1e6}")"

    udp_jitter="$(jq -r '
       .end.sum_sent.jitter_ms
    // .end.sum_received.jitter_ms
    // .end.sum.jitter_ms
    // 0' "$udp_log" 2>/dev/null || echo 0)"

    udp_loss="$(jq -r '
       .end.sum_sent.lost_percent
    // .end.sum_received.lost_percent
    // .end.sum.lost_percent
    // 0' "$udp_log" 2>/dev/null || echo 0)"
  fi

NET_JSON="$(printf '%s' "$NET_JSON" | jq --arg v "$udp_mbps" '. + {udp_mbps: ($v|tonumber? // 0)}')"
NET_JSON="$(printf '%s' "$NET_JSON" | jq --arg v "$udp_jitter" '. + {udp_jitter_ms: ($v|tonumber? // 0)}')"
NET_JSON="$(printf '%s' "$NET_JSON" | jq --arg v "$udp_loss" '. + {udp_loss_percent: ($v|tonumber? // 0)}')"


else
  NET_JSON="$(printf '%s' "$NET_JSON" | jq '. + {tcp_mbps:"missing", udp_mbps:"missing", udp_jitter_ms:"missing", udp_loss_percent:"missing"}')"
fi

# --- Optional Internet speed test using speedtest-cli ---
mark_event "net_inet_start"
echo "-- Internet speed test..."

if command -v speedtest >/dev/null 2>&1; then
  speed_log="${LOGDIR}/net_speedtest_${TS}.json"
  # Run once in JSON mode; use timeout to prevent hanging
  timeout 90 speedtest --json > "$speed_log" 2>/dev/null || true

  # Parse basic values (bits/sec to Mbit/sec)
  dl="$(jq -r '.download // 0' "$speed_log" 2>/dev/null)"
  ul="$(jq -r '.upload // 0' "$speed_log" 2>/dev/null)"
  ping="$(jq -r '.ping // 0' "$speed_log" 2>/dev/null)"
  isp="$(jq -r '.client.isp // "unknown"' "$speed_log" 2>/dev/null)"
  srv="$(jq -r '.server.name // "unknown"' "$speed_log" 2>/dev/null)"
  country="$(jq -r '.server.country // "unknown"' "$speed_log" 2>/dev/null)"

  dl_mbps="$(awk "BEGIN{print ${dl:-0}/1e6}")"
  ul_mbps="$(awk "BEGIN{print ${ul:-0}/1e6}")"

  # Add to NET_JSON
  NET_JSON="$(printf '%s' "$NET_JSON" | jq \
    --arg dl "$dl_mbps" \
    --arg ul "$ul_mbps" \
    --arg p "$ping" \
    --arg i "$isp" \
    --arg s "$srv" \
    --arg c "$country" \
    '. + {
      internet_download_mbps: ($dl|tonumber? // 0),
      internet_upload_mbps: ($ul|tonumber? // 0),
      internet_ping_ms: ($p|tonumber? // 0),
      internet_isp: $i,
      internet_server: $s,
      internet_country: $c
    }')"
else
  echo "[!] speedtest-cli not found."
  echo "    → Install it with: pamac install speedtest-cli"
  NET_JSON="$(printf '%s' "$NET_JSON" | jq '. + {
    internet_download_mbps: "missing",
    internet_upload_mbps: "missing",
    internet_ping_ms: "missing"
  }')"
fi


add_obj "network" "$NET_JSON"

# --------- GPU tests -----------------------------------------------------------
mark_event "gpu_glmark2_start"
echo "-- GPU tests..."
echo "   glmark2"
GPU_JSON='{}'

# glmark2
if have glmark2; then
  gl_log="${LOGDIR}/glmark2_${TS}.log"

  # Run glmark2 in fullscreen at 1920x1080, neutral locale for parsing
  env LANG=C LC_ALL=C \
    glmark2 --fullscreen --size 1920x1080 >"$gl_log" 2>&1

  # Parse the final glmark2 Score line
  score="$(awk -F: '/glmark2 Score/ { gsub(/[[:space:]]+/,"",$2); print $2 }' "$gl_log" | tail -1)"
  score="${score:-0}"

  GPU_JSON="$(printf '%s' "$GPU_JSON" | jq --arg s "${score}" '. + {glmark2_score: ($s|tonumber? // 0)}')"
else
  GPU_JSON="$(printf '%s' "$GPU_JSON" | jq '. + {glmark2_score:"missing"}')"
fi

# --- vkmark: single run via gamescope, XCB winsys ---
mark_event "gpu_vkmark_start"
echo "   vkmark"

if have vkmark; then
  vk_log="${LOGDIR}/vkmark_${TS}.log"
  tmp_log="${LOGDIR}/vkmark_${TS}_run1.log"

  # Detect primary output and toggle VRR off during run (best-effort)
  primary_out="$(xrandr --query 2>/dev/null | awk '/ primary /{print $1; exit}')"
  [[ -z "$primary_out" ]] && primary_out="$(xrandr --query 2>/dev/null | awk '/ connected/{print $1; exit}')"
  vrr_supported=0
  old_vrr=""

  if [[ -n "$primary_out" ]] && xrandr --props 2>/dev/null | grep -q 'Variable Refresh Rate'; then
    vrr_supported=1
    old_vrr="$(xrandr --props | awk -v o="$primary_out" '
      $0 ~ "^"o" " { inout=1 }
      inout && /Variable Refresh Rate/ { print $NF; exit }')"
    xrandr --output "$primary_out" --set "Variable Refresh Rate" 0 >/dev/null 2>&1 || true
  fi

  : >"$tmp_log"

  # needs some tweaks to get rid of a shell error message during the vkmark run
  # so we run this script in a subshell and forbid error messaging

  # Silence bash abort messages
  set +o notify
  trap "" SIGABRT

  if command -v gamescope >/dev/null 2>&1; then
    {
      setsid bash -c '
        env LANG=C LC_ALL=C XDG_SESSION_TYPE=x11 \
          gamescope -f -w 1920 -h 1080 -- \
          vkmark --winsys=xcb > "'"$tmp_log"'" 2>&1
      '
    } >/dev/null 2>&1 || true
  else
    {
      setsid bash -c '
        env LANG=C LC_ALL=C XDG_SESSION_TYPE=x11 \
          vkmark --winsys=xcb > "'"$tmp_log"'" 2>&1
      '
    } >/dev/null 2>&1 || true
  fi

  # Restore trap
  trap - SIGABRT


  # Parse overall score
  score="$(awk -F: '/[Vv][Kk]mark[[:space:]]+Score/ { gsub(/[[:space:]]+/,"",$2); print $2 }' "$tmp_log" | tail -1)"
  score="${score:-0}"

  # Parse per-scene FPS, normalize key names
  SCENES_JSON='{}'
  while IFS= read -r line; do
    if printf '%s\n' "$line" | awk 'tolower($0) ~ /^\[[^]]+\]/ && tolower($0) ~ /fps:/' >/dev/null; then
      fps="$(printf '%s\n' "$line" | awk '{ if (match($0,/FPS:[[:space:]]*([0-9]+(\.[0-9]+)?)/,m)) print m[1] }')"
      key="$(printf '%s\n' "$line" | awk '{
               scene="unknown"; opt="default";
               if (match($0, /\[([^]]+)\]/, m)) scene=m[1];
               if (match($0, /\]([^:]+):[[:space:]]*FPS:/, n)) { opt=n[1]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", opt); }
               k=scene"_"opt; print k;
             }' | tr ' <>:=' '_' | tr -s '_' )"
      [[ -n "$key" && -n "$fps" ]] && SCENES_JSON="$(printf '%s' "$SCENES_JSON" | jq --arg k "$key" --arg v "$fps" '. + {($k): ($v|tonumber? // 0)}')"
    fi
  done <"$tmp_log"

  cat "$tmp_log" >"$vk_log"
  
  # v0.2: Handle NVIDIA vkmark limitation (proprietary driver)
  # Only set to null if the run actually failed (score = 0 AND no scenes found)
  # With newer kernels (6.17+) and Mesa, vkmark can work on NVIDIA
  scenes_count="$(printf '%s' "$SCENES_JSON" | jq 'length' 2>/dev/null || echo 0)"
  
  if [[ "$gpu_vendor" == "nvidia" && "$score" == "0" && "$scenes_count" == "0" ]]; then
    # Run failed: no score and no scenes = driver limitation or error
    GPU_JSON="$(printf '%s' "$GPU_JSON" | jq '. + {vkmark_score: null, vkmark_note: "Skipped on NVIDIA (proprietary driver limitation)", vkmark_scenes: {}}')"
  else
    # Run succeeded (or score > 0): use the actual score
    GPU_JSON="$(printf '%s' "$GPU_JSON" | jq --arg s "${score}" '. + {vkmark_score: ($s|tonumber? // 0)}')"
    GPU_JSON="$(printf '%s' "$GPU_JSON" | jq --argjson obj "$SCENES_JSON" '. + {vkmark_scenes: $obj}')"
  fi
else
  GPU_JSON="$(printf '%s' "$GPU_JSON" | jq '. + {vkmark_score:"missing", vkmark_scenes:{}}')"
fi


# runs sweet on bash: gputest /test=fur /width=1920 /height=1080 /gpumon_terminal /benchmark /print_score

# --- GpuTest FurMark stress test (fully scriptable, uses /print_score) ---
mark_event "gpu_gputest_start"
echo "   gputest (fur)"
echo "      (NOTE: A GpuTest window with results will appear, when FurMark ends."
echo "      - close it when the score is shown, to end GHULbench properly.)"

if have gputest; then
  gputest_log="${LOGDIR}/gputest_fur_${TS}.log"

  # Run GpuTest with forced score output on stdout
  # /print_score ensures a machine-readable summary
  set +e
  gputest /test=fur /width=1920 /height=1080 /gpumon_terminal /benchmark /print_score \
      >"$gputest_log" 2>&1
  exitcode=$?
  set -e

  # Extract the summary line containing "Score" and "FPS"
  gputest_line="$(grep -i 'Score:' "$gputest_log" | head -1 || true)"

  # Defaults
  gputest_score=null
  gputest_fps=null
  gputest_res=null
  gputest_dur_ms=null

  if [[ -n "$gputest_line" ]]; then
    # Parse score: "Score: 13993 ..."
    tmp="$(printf '%s\n' "$gputest_line" | sed -n 's/.*Score:[[:space:]]*\([0-9]\+\).*/\1/p')"
    [[ -n "$tmp" ]] && gputest_score="$tmp"

    # Parse FPS: "FPS: 233"
    tmp="$(printf '%s\n' "$gputest_line" | sed -n 's/.*FPS:[[:space:]]*\([0-9]\+\).*/\1/p')"
    [[ -n "$tmp" ]] && gputest_fps="$tmp"
  fi

  # Parse resolution: "1920x1080"
  tmp="$(grep -o '[0-9]\{3,5\}x[0-9]\{3,5\}' "$gputest_log" | head -1)"
  [[ -n "$tmp" ]] && gputest_res="$tmp"

  # Parse duration: "duration: 60000 ms"
  tmp="$(grep -i 'duration:' "$gputest_log" \
        | sed -n 's/.*duration:[[:space:]]*\([0-9]\+\).*/\1/p' \
        | head -1)"
  [[ -n "$tmp" ]] && gputest_dur_ms="$tmp"

  # Add to JSON
  GPU_JSON="$(printf '%s' "$GPU_JSON" | jq \
    --arg score "$gputest_score" \
    --arg fps   "$gputest_fps" \
    --arg res   "$gputest_res" \
    --arg dur   "$gputest_dur_ms" \
    '. + {gputest_fur:{
        score: ($score|tonumber?),
        fps: ($fps|tonumber?),
        resolution: $res,
        duration_ms: ($dur|tonumber?)
    }}')"

else
  GPU_JSON="$(printf '%s' "$GPU_JSON" | jq '. + {gputest_fur:{score:"missing"}}')"
fi

# --- add all gpu Benchmarks to JSON result -------------------------------------

add_obj "gpu" "$GPU_JSON"

# --------- run timing metadata (for sensor correlation) ------------------------

RUN_END_EPOCH="$(date +%s)"
RUN_END_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RUN_DURATION=$(( RUN_END_EPOCH - RUN_START_EPOCH ))

RUN_META_JSON="$(jq -n \
  --arg start_ts  "$TS" \
  --arg start_iso "$RUN_START_ISO" \
  --arg end_iso   "$RUN_END_ISO" \
  --argjson start_epoch "$RUN_START_EPOCH" \
  --argjson end_epoch   "$RUN_END_EPOCH" \
  --argjson duration    "$RUN_DURATION" \
  '{
     start_timestamp_local: $start_ts,
     start_timestamp_utc:   $start_iso,
     end_timestamp_utc:     $end_iso,
     start_epoch:           $start_epoch,
     end_epoch:             $end_epoch,
     duration_sec:          $duration
   }'
)"

add_obj "run_meta" "$RUN_META_JSON"

# Add timestamps for the end
RUN_END_EPOCH="$(date +%s)"
mark_event "run_end" "$RUN_END_EPOCH"

# Attach timeline (phase markers) to JSON
add_obj "timeline" "$TIMELINE_JSON"

# --------- write JSON ----------------------------------------------------------
echo "-- Writing result → ${OUTFILE}"
echo "   Run duration: ${RUN_DURATION} seconds"
printf '%s\n' "$JSON" | jq -S '.' > "$OUTFILE"

# --------- quit sensor logging -------------------------------------------------
# Try PID from this process first, then from pidfile as fallback
if [[ -n "${SENSORS_PID:-}" ]]; then
  echo "[GHUL] Stopping sensors helper (PID ${SENSORS_PID})"
  kill "${SENSORS_PID}" 2>/dev/null || true
elif [[ -f "$SENSORS_PIDFILE" ]]; then
  pid="$(cat "$SENSORS_PIDFILE" 2>/dev/null || echo "")"
  if [[ -n "$pid" ]]; then
    echo "[GHUL] Stopping sensors helper (PID ${pid}) via pidfile"
    kill "$pid" 2>/dev/null || true
  fi
fi

rm -f "$SENSORS_PIDFILE" 2>/dev/null || true

echo "== GHUL run complete =="
echo "Result saved to: $OUTFILE"
echo "Logs: $LOGDIR"
SENSORS_FILE="${SENSORSDIR}/${TS}-${HOST}-sensors.jsonl"
if [[ -f "$SENSORS_FILE" ]]; then
  echo "Sensor data: $SENSORS_FILE"
fi
echo ""
echo "[GHUL] To see thermals: ./ghul-report.sh $OUTFILE"
