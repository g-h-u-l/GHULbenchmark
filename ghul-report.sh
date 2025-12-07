#!/usr/bin/env bash
# GHUL - Gaming Hardware Using Linux
# Offline sensor report:
# - Find newest benchmark JSON in results/
# - Derive prefix (YYYY-mm-dd-HH-MM) from filename
# - Find matching sensors JSONL in logs/sensors/ with same prefix
# - Use timeline markers to slice sensor data and print min/max/avg
#
# Comments: English only.
# Output text: English only.
# Locale: enforce C for stable parsing.

set -euo pipefail

# ----- enforce predictable locale -----
export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

# ----- base directories -----
# Get absolute path of GHULbenchmark root (this script's directory)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULT_DIR="${BASE}/results"
SENSOR_DIR="${BASE}/logs/sensors"

have() { command -v "$1" >/dev/null 2>&1; }

die() {
  echo "[GHUL] ERROR: $*" >&2
  exit 1
}

# ----- pre-checks for dirs & tools -----
have jq || die "jq is required (pacman -S jq)."

[[ -d "$RESULT_DIR" ]] || die "results/ directory not found at: $RESULT_DIR"
[[ -d "$SENSOR_DIR" ]] || die "logs/sensors/ directory not found at: $SENSOR_DIR"

###############################################
# 1) Locate newest benchmark JSON
###############################################
BENCH_FILE="$(ls -1t "${RESULT_DIR}"/*.json 2>/dev/null | head -n1 || true)"
[[ -n "$BENCH_FILE" ]] || die "No benchmark JSON files found in ${RESULT_DIR}"
[[ -f "$BENCH_FILE" ]] || die "Benchmark file not found: $BENCH_FILE"

BENCH_NAME="$(basename "$BENCH_FILE")"
# Example: 2025-11-29-17-39-sharkoon.json → 2025-11-29-17-39
BENCH_PREFIX="$(echo "$BENCH_NAME" | cut -d'-' -f1-5)"

###############################################
# 2) Locate matching sensors JSONL by prefix
###############################################
SENS_FILE="$(ls -1t "${SENSOR_DIR}/${BENCH_PREFIX}"*-sensors.jsonl 2>/dev/null | head -n1 || true)"
[[ -n "$SENS_FILE" ]] || die "No matching sensors JSONL log found for prefix ${BENCH_PREFIX}"
[[ -f "$SENS_FILE" ]] || die "Sensors file not found: $SENS_FILE"

# last sensor timestamp from the matching sensors file
SENS_LAST_TS="$(jq -r 'select(.timestamp != null) | .timestamp' "$SENS_FILE" | tail -n1 || true)"
[[ -n "$SENS_LAST_TS" ]] || die "Could not determine last timestamp from sensors file: $SENS_FILE"

# ----- small helpers -----------------------------------------------------------

# Compute min/max/avg from a list of numbers on stdin.
compute_stats() {
  awk '
    BEGIN {
      have=0; min=0; max=0; sum=0; cnt=0;
    }
    {
      if ($1 == "" || $1 == "null") next;
      v = $1 + 0;
      if (!have) {
        min = max = v;
        have = 1;
      } else {
        if (v < min) min = v;
        if (v > max) max = v;
      }
      sum += v;
      cnt++;
    }
    END {
      if (!have || cnt == 0) {
        print "n/a n/a n/a";
      } else {
        avg = sum / cnt;
        printf "%.1f %.1f %.1f\n", min, max, avg;
      }
    }
  '
}

# Print one metric line (min/max/avg) for a given JSON field and time window.
metric_stats() {
  local label="$1"
  local field="$2"
  local start_epoch="$3"
  local end_epoch="$4"
  local values
  local warning=""

  # Extract values for the specific field - ensure we use the correct field name
  # This explicitly uses the field parameter to avoid any confusion
  values="$(jq -r --argjson s "$start_epoch" --argjson e "$end_epoch" --arg f "$field" '
    select(.timestamp >= $s and .timestamp <= $e)
    | .[$f] // empty
    | select(. != null and . != "")
  ' "$SENS_FILE" 2>/dev/null || true)"

  if [[ -z "$values" ]]; then
    echo "  ${label}: n/a"
    return
  fi

  # shellcheck disable=SC2086
  read -r min max avg <<<"$(printf '%s\n' $values | compute_stats)"
  
  # Temperature warnings based on field type
  if [[ "$field" == "cpu_temp_c" ]]; then
    # CPU: > 100°C = CRITICAL, > 80°C = WARNING
    if (( $(echo "$max >= 100.0" | bc -l) )); then
      warning=" ⚠ CRITICAL: CPU overheating! Check thermal paste and cooling immediately!"
    elif (( $(echo "$max > 80.0" | bc -l) )); then
      warning=" ⚠ WARNING: CPU temp high, check cooling"
    fi
  elif [[ "$field" == "gpu_temp_c" ]]; then
    # GPU Edge: > 95°C = CRITICAL, > 85°C = WARNING
    if (( $(echo "$max >= 95.0" | bc -l) )); then
      warning=" ⚠ CRITICAL: GPU overheating! Check thermal paste and cooling immediately!"
    elif (( $(echo "$max > 85.0" | bc -l) )); then
      warning=" ⚠ WARNING: GPU temp high, check cooling"
    fi
  elif [[ "$field" == "gpu_hotspot_c" ]]; then
    # GPU Hotspot: > 110°C = CRITICAL, > 100°C = WARNING
    if (( $(echo "$max >= 110.0" | bc -l) )); then
      warning=" ⚠ CRITICAL: GPU hotspot overheating! Check thermal paste and cooling immediately!"
    elif (( $(echo "$max > 100.0" | bc -l) )); then
      warning=" ⚠ WARNING: GPU hotspot temp high, check cooling"
    fi
  elif [[ "$field" == "gpu_memtemp_c" ]]; then
    # GPU Memory: > 100°C = CRITICAL, > 90°C = WARNING
    if (( $(echo "$max >= 100.0" | bc -l) )); then
      warning=" ⚠ CRITICAL: GPU memory overheating! Check cooling immediately!"
    elif (( $(echo "$max > 90.0" | bc -l) )); then
      warning=" ⚠ WARNING: GPU memory temp high, check cooling"
    fi
  fi
  
  echo "  ${label}: min=${min}, max=${max}, avg=${avg}${warning}"
}

# Get storage device label (mount point or model) for display
get_storage_label() {
  local device="$1"
  local mount_point
  local model
  local label

  # Extract base device (sda1 -> sda, nvme0n1p1 -> nvme0n1)
  local base_device
  if [[ "$device" =~ ^nvme ]]; then
    base_device="$(echo "$device" | sed -E 's/(nvme[0-9]+n[0-9]+).*/\1/')"
  else
    base_device="$(echo "$device" | sed -E 's/([a-z]+)([0-9]+).*/\1/')"
  fi

  # Try to get mount point from partitions on this device (most descriptive)
  # Check all partitions of the base device
  mount_point="$(df -T 2>/dev/null | awk -v base="/dev/${base_device}" '
    $1 ~ "^" base "[0-9]+" {
      mp = $NF
      # Prefer non-root, non-boot mount points
      if (mp != "/" && mp !~ /\/boot/) {
        print mp
        exit
      }
      # Keep root as fallback
      if (mp == "/") {
        root_mp = mp
      }
    }
    END {
      if (root_mp) print root_mp
    }
  ' | head -n1)"
  
  # If no mount point found, try lsblk
  if [[ -z "$mount_point" ]]; then
    mount_point="$(lsblk -o NAME,MOUNTPOINT -n 2>/dev/null | awk -v base="$base_device" '$1 ~ "^" base "[0-9]+" && $2 != "" && $2 != "/" {print $2; exit}')"
  fi

  # Get model name
  model="$(lsblk -o NAME,MODEL -d -n 2>/dev/null | awk -v dev="$base_device" '$1 == dev {for(i=2;i<=NF;i++) printf "%s ", $i; print ""; exit}' | sed 's/[[:space:]]*$//')"

  # Build label: prefer mount point, fallback to model
  if [[ -n "$mount_point" && "$mount_point" != "/" ]]; then
    # Use basename of mount point for cleaner display
    label="$(basename "$mount_point")"
  elif [[ -n "$model" ]]; then
    label="$model"
  else
    label=""
  fi

  if [[ -n "$label" ]]; then
    echo " (${label})"
  else
    echo ""
  fi
}

# Print storage temperature stats for a given device and time window.
storage_temp_stats() {
  local device="$1"
  local start_epoch="$2"
  local end_epoch="$3"
  local values
  local label
  local warning=""

  values="$(jq -r --argjson s "$start_epoch" --argjson e "$end_epoch" --arg dev "$device" '
    select(.timestamp >= $s and .timestamp <= $e)
    | .storage_temps[$dev] // empty
    | select(. != null)
  ' "$SENS_FILE" || true)"

  if [[ -z "$values" ]]; then
    return 1
  fi

  # shellcheck disable=SC2086
  read -r min max avg <<<"$(printf '%s\n' $values | compute_stats)"
  
  # Get label for device
  label="$(get_storage_label "$device")"
  
  # Check for high temperature warning
  # Storage: >= 70°C = CRITICAL, > 55°C = WARNING
  if (( $(echo "$max >= 70.0" | bc -l) )); then
    warning=" ⚠ CRITICAL: Storage overheating! Check airflow immediately!"
  elif (( $(echo "$max > 55.0" | bc -l) )); then
    warning=" ⚠ WARNING: Storage temp high, check airflow"
  fi
  
  echo "  Storage ${device}${label} temp (°C): min=${min}, max=${max}, avg=${avg}${warning}"
  return 0
}

# Print all storage temperature stats for a time window.
all_storage_temp_stats() {
  local start_epoch="$1"
  local end_epoch="$2"
  local devices
  local device
  local found=0

  # Get all unique storage device names from the sensor log
  devices="$(jq -r --argjson s "$start_epoch" --argjson e "$end_epoch" '
    select(.timestamp >= $s and .timestamp <= $e)
    | .storage_temps // {}
    | keys[]
  ' "$SENS_FILE" 2>/dev/null | sort -u || true)"

  if [[ -z "$devices" ]]; then
    return 0
  fi

  while IFS= read -r device; do
    [[ -z "$device" ]] && continue
    if storage_temp_stats "$device" "$start_epoch" "$end_epoch"; then
      found=1
    fi
  done <<<"$devices"

  return $found
}

# Segment report for a named timeline marker.
segment_report() {
  local marker_name="$1"
  local label="$2"

  local i
  local start_epoch=""
  local end_epoch=""

  for i in "${!TL_NAMES[@]}"; do
    if [[ "${TL_NAMES[$i]}" == "$marker_name" ]]; then
      start_epoch="${TL_EPOCHS[$i]}"
      local next_index=$(( i + 1 ))
      if (( next_index < ${#TL_EPOCHS[@]} )); then
        end_epoch="${TL_EPOCHS[$next_index]}"
      else
        end_epoch="${SENS_LAST_TS}"
      fi
      break
    fi
  done

  echo
  echo "== Segment: ${label} =="

  if [[ -z "$start_epoch" ]]; then
    echo "  No timeline marker '${marker_name}' found in benchmark JSON."
    return
  fi

  echo "  Window: ${start_epoch} – ${end_epoch}"

  metric_stats "CPU temp (°C)"          "cpu_temp_c"      "$start_epoch" "$end_epoch"
  metric_stats "GPU edge temp (°C)"     "gpu_temp_c"      "$start_epoch" "$end_epoch"
  metric_stats "GPU hotspot temp (°C)"  "gpu_hotspot_c"   "$start_epoch" "$end_epoch"
  metric_stats "GPU memory temp (°C)"   "gpu_memtemp_c"   "$start_epoch" "$end_epoch"
  metric_stats "GPU power (W)"          "gpu_power_w"     "$start_epoch" "$end_epoch"
  # GPU fan: For NVIDIA, this is actually % (0-100), not RPM
  metric_stats "GPU fan (RPM/%)"        "gpu_fan_rpm"     "$start_epoch" "$end_epoch"
  metric_stats "Case fan1 (RPM)"        "fan1_rpm"        "$start_epoch" "$end_epoch"
  metric_stats "Case fan2 (RPM)"        "fan2_rpm"        "$start_epoch" "$end_epoch"
  metric_stats "Case fan3 (RPM)"        "fan3_rpm"        "$start_epoch" "$end_epoch"
  metric_stats "Case fan4 (RPM)"        "fan4_rpm"        "$start_epoch" "$end_epoch"
  metric_stats "Case fan5 (RPM)"        "fan5_rpm"        "$start_epoch" "$end_epoch"
  all_storage_temp_stats "$start_epoch" "$end_epoch"
}

# ----- basic info from benchmark JSON -----------------------------------------

HOSTNAME="$(jq -r '.environment.hostname // "unknown"' "$BENCH_FILE")"
BTIME="$(jq -r '.environment.timestamp // "unknown"' "$BENCH_FILE")"
OS_STR="$(jq -r '.environment.os // "unknown"' "$BENCH_FILE")"
KERNEL_STR="$(jq -r '.environment.kernel // "unknown"' "$BENCH_FILE")"
CPU_STR="$(jq -r '.environment.cpu // "unknown"' "$BENCH_FILE")"
GPU_STR="$(jq -r '.environment.gpu_model // "unknown"' "$BENCH_FILE")"
RAM_KIB="$(jq -r '.environment.mem_total_kib // 0' "$BENCH_FILE")"
RAM_GIB="$(awk "BEGIN{printf \"%.1f\", ${RAM_KIB}/1024/1024}")"

RUN_START_EPOCH="$(jq -r '.timeline[]? | select(.name=="run_start") | .epoch' "$BENCH_FILE" | head -n1 || true)"
RUN_END_EPOCH="$(jq -r '.timeline[]? | select(.name=="run_end")   | .epoch' "$BENCH_FILE" | head -n1 || true)"

if [[ -z "$RUN_START_EPOCH" ]]; then
  RUN_START_EPOCH="$(jq -r '.timeline[0].epoch // empty' "$BENCH_FILE" || true)"
fi
[[ -n "$RUN_START_EPOCH" ]] || die "Could not determine run_start epoch from timeline."

if [[ -z "$RUN_END_EPOCH" ]]; then
  RUN_END_EPOCH="$SENS_LAST_TS"
fi

RUN_DURATION=$(( RUN_END_EPOCH - RUN_START_EPOCH ))

# ---- load whole timeline into bash arrays ------------------------------------

mapfile -t TL_NAMES  < <(jq -r '.timeline[]? | .name'  "$BENCH_FILE")
mapfile -t TL_EPOCHS < <(jq -r '.timeline[]? | .epoch' "$BENCH_FILE")

# ----- print report -----------------------------------------------------------

echo "== GHUL sensor report =="
echo
echo "[GHUL] Using benchmark JSON: $BENCH_FILE"
echo "[GHUL] Using sensors log:    $SENS_FILE"
echo
echo "== System profile =="
echo "Host:        ${HOSTNAME}"
echo "Benchmark:   ${BTIME}"
echo "OS / Kernel: ${OS_STR} / ${KERNEL_STR}"
echo "CPU:         ${CPU_STR}"
echo "GPU:         ${GPU_STR}"
echo "RAM total:   ${RAM_GIB} GiB"
echo
echo "== Run timing =="
echo "run_start epoch: ${RUN_START_EPOCH}"
echo "run_end epoch:   ${RUN_END_EPOCH}"
echo "last sensor ts:  ${SENS_LAST_TS}"
echo "run duration:    ${RUN_DURATION} seconds"
echo
echo "== Full run (run_start → last sensor entry) =="
metric_stats "CPU temp (°C)"          "cpu_temp_c"      "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "GPU edge temp (°C)"     "gpu_temp_c"      "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "GPU hotspot temp (°C)"  "gpu_hotspot_c"   "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "GPU memory temp (°C)"   "gpu_memtemp_c"   "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "GPU power (W)"          "gpu_power_w"     "$RUN_START_EPOCH" "$SENS_LAST_TS"
  # GPU fan: For NVIDIA, this is actually % (0-100), not RPM
  metric_stats "GPU fan (RPM/%)"        "gpu_fan_rpm"     "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "Case fan1 (RPM)"        "fan1_rpm"        "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "Case fan2 (RPM)"        "fan2_rpm"        "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "Case fan3 (RPM)"        "fan3_rpm"        "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "Case fan4 (RPM)"        "fan4_rpm"        "$RUN_START_EPOCH" "$SENS_LAST_TS"
metric_stats "Case fan5 (RPM)"        "fan5_rpm"        "$RUN_START_EPOCH" "$SENS_LAST_TS"
all_storage_temp_stats "$RUN_START_EPOCH" "$SENS_LAST_TS"

segment_report "storage_start" "Storage tests"
segment_report "gpu_glmark2_start" "GPU: glmark2"
segment_report "gpu_vkmark_start"  "GPU: vkmark"
segment_report "gpu_gputest_start" "GPU: GpuTest FurMark"

echo
echo "== GHUL sensor report complete =="
echo "You can use this output to tune fan curves and power limits."

