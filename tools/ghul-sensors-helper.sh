#!/usr/bin/env bash
# GHUL sensors helper – runs in background during GHULbench
# Logs one JSON record per second to logs/sensors/<timestamp>-<host>-sensors.jsonl
# Locale MUST be C for stable parsing

export LANG=C
export LC_ALL=C

BASE="$(dirname "$(dirname "$0")")"
HOST="$(hostname)"

# Ensure log folder exists
SENSLOG_DIR="${BASE}/logs/sensors"
mkdir -p "$SENSLOG_DIR"

# Use run timestamp from ghul-benchmark if provided, else fallback.
# Format: YYYY-mm-dd-HH-MM (no seconds)
TS_RUN="${GHUL_RUN_TS:-$(date +%Y-%m-%d-%H-%M)}"
OUTFILE="${SENSLOG_DIR}/${TS_RUN}-${HOST}-sensors.jsonl"

echo "[GHUL] Sensors helper writing to: $OUTFILE" >&2

# Optionally write PID file (so ghul-benchmark can stop us cleanly)
if [[ -n "${GHUL_SENSORS_PIDFILE:-}" ]]; then
  echo "$$" > "$GHUL_SENSORS_PIDFILE"
fi

# Detect CPU sensor source
detect_cpu_sensor() {
  if sensors 2>/dev/null | grep -q "k10temp"; then
    echo "k10temp"
  elif sensors 2>/dev/null | grep -q "Package id 0"; then
    echo "coretemp"
  else
    echo "unknown"
  fi
}

CPU_SENSOR="$(detect_cpu_sensor)"

# Detect AMD GPU via amdgpu sensors
has_amdgpu=0
if sensors 2>/dev/null | grep -q "amdgpu"; then
  has_amdgpu=1
fi

# NVIDIA can come later
has_nvidia=0
if command -v nvidia-smi >/dev/null 2>&1; then
  has_nvidia=1
fi

# Detect storage devices and check if smartctl is available
has_smartctl=0
if command -v smartctl >/dev/null 2>&1; then
  has_smartctl=1
  # Detect all block devices (disks, NVMe, etc.) once at startup
  STORAGE_DEVICES=()
  while IFS= read -r line; do
    device="$(echo "$line" | awk '{print $1}')"
    [[ -z "$device" ]] && continue
    [[ "$device" =~ ^loop ]] && continue
    if [[ "$device" =~ ^(sd|hd|vd)[a-z][0-9]+$ ]]; then
      continue  # Skip partitions
    fi
    dev_path="/dev/${device}"
    [[ -b "$dev_path" ]] && STORAGE_DEVICES+=("$device")
  done < <(lsblk -d -n -o NAME 2>/dev/null || true)
fi

# Poll every second until parent script kills this process
while true; do
  now_ts="$(date +%s)"

  cpu_temp="null"
  if [[ "$CPU_SENSOR" == "k10temp" ]]; then
    cpu_temp="$(sensors 2>/dev/null | awk '/Tctl/ {print $2+0; exit}' | tr -d '+°C' || echo null)"
  elif [[ "$CPU_SENSOR" == "coretemp" ]]; then
    cpu_temp="$(sensors 2>/dev/null | awk '/Package id 0/ {print $4+0; exit}' | tr -d '+°C' || echo null)"
  fi

  gpu_temp="null"
  gpu_hotspot="null"
  gpu_memtemp="null"
  gpu_power="null"
  gpu_fan="null"

  if [[ "$has_amdgpu" -eq 1 ]]; then
    # example lines:
    # edge: +52.0°C
    # junction: +64.0°C
    # mem: +60.0°C
    # PPT: 34.00 W
    gpu_temp="$(sensors 2>/dev/null | awk '/edge:/     {gsub(/\+/,"",$2); gsub(/°C/,"",$2); print $2; exit}' )"
    gpu_hotspot="$(sensors 2>/dev/null | awk '/junction:/ {gsub(/\+/,"",$2); gsub(/°C/,"",$2); print $2; exit}' )"
    gpu_memtemp="$(sensors 2>/dev/null | awk '/mem:/      {gsub(/\+/,"",$2); gsub(/°C/,"",$2); print $2; exit}' )"
    gpu_power="$(sensors 2>/dev/null | awk '/PPT:/      {gsub(/W/,"",$2); print $2+0; exit}' )"
    gpu_fan="$(sensors 2>/dev/null | awk '/fan1:/     {gsub(/RPM/,"",$2); print $2+0; exit}' )"

    [[ -z "$gpu_temp" ]] && gpu_temp="null"
    [[ -z "$gpu_hotspot" ]] && gpu_hotspot="null"
    [[ -z "$gpu_memtemp" ]] && gpu_memtemp="null"
    [[ -z "$gpu_power" ]] && gpu_power="null"
    [[ -z "$gpu_fan" ]] && gpu_fan="null"
  fi

  # (NVIDIA later – placeholder)
  if [[ "$has_nvidia" -eq 1 ]]; then
    :
  fi

  # Motherboard + fan list (fan1..fan5)
  fan1="$(sensors 2>/dev/null | awk '/fan1:/ {gsub(/RPM/,"",$2); print $2+0; exit}' || echo null)"
  fan2="$(sensors 2>/dev/null | awk '/fan2:/ {gsub(/RPM/,"",$2); print $2+0; exit}' || echo null)"
  fan3="$(sensors 2>/dev/null | awk '/fan3:/ {gsub(/RPM/,"",$2); print $2+0; exit}' || echo null)"
  fan4="$(sensors 2>/dev/null | awk '/fan4:/ {gsub(/RPM/,"",$2); print $2+0; exit}' || echo null)"
  fan5="$(sensors 2>/dev/null | awk '/fan5:/ {gsub(/RPM/,"",$2); print $2+0; exit}' || echo null)"

  # Storage temperatures
  # Try multiple methods: /sys for NVMe (no root), smartctl for others (may need root)
  storage_temps_json="{}"
  if [[ ${#STORAGE_DEVICES[@]} -gt 0 ]]; then
    for device in "${STORAGE_DEVICES[@]}"; do
      temp="null"
      
      # Method 1: Try /sys for NVMe (works without root)
      if [[ "$device" =~ ^nvme ]]; then
        if [[ -r "/sys/block/${device}/device/hwmon" ]]; then
          for hwmon in /sys/block/${device}/device/hwmon/hwmon*/temp*_input; do
            if [[ -r "$hwmon" ]]; then
              temp_mdeg="$(cat "$hwmon" 2>/dev/null || echo 0)"
              if [[ "$temp_mdeg" != "0" ]]; then
                temp="$(awk -v t="$temp_mdeg" 'BEGIN { printf "%.1f", t/1000 }')"
                break
              fi
            fi
          done
        fi
      fi
      
      # Method 2: Try smartctl (may need root, but try anyway)
      if [[ "$temp" == "null" || "$temp" == "0" ]]; then
        if [[ "$has_smartctl" -eq 1 ]]; then
          dev_path="/dev/${device}"
          # Try smartctl with different device types (sat, ata, auto)
          # Look for Airflow_Temperature_Cel (Samsung SSDs) or Temperature_Celsius
          for dev_type in "sat" "ata" ""; do
            if [[ -z "$dev_type" ]]; then
              smartctl_cmd="smartctl -A \"$dev_path\""
            else
              smartctl_cmd="smartctl -d $dev_type -A \"$dev_path\""
            fi
            temp="$(eval "$smartctl_cmd" 2>/dev/null | awk '
              /Airflow_Temperature_Cel/ { print $10; exit }
              /Temperature_Celsius/ { print $10; exit }
              /Temperature:/ { print $2; exit }
              /^[0-9][0-9][0-9][[:space:]]+194/ { print $10; exit }
              /^[0-9][0-9][0-9][[:space:]]+190/ { print $10; exit }
            ' | head -n1)"
            # If we got a valid temperature, break
            if [[ -n "$temp" && "$temp" != "0" && "$temp" != "null" ]]; then
              break
            fi
          done
        fi
      fi
      
      # Only add if we got a valid temperature
      if [[ -n "$temp" && "$temp" != "0" && "$temp" != "null" ]]; then
        storage_temps_json="$(printf '%s' "$storage_temps_json" | jq --arg dev "$device" --arg t "$temp" '. + {($dev): ($t|tonumber? // 0)}' 2>/dev/null || echo "$storage_temps_json")"
      fi
    done
  fi

  # Convert storage_temps_json to a compact string for printf (or use jq to merge)
  # For simplicity, we'll add it as a JSON object in the output
  storage_temps_str="$(printf '%s' "$storage_temps_json" | jq -c '.' 2>/dev/null || echo "{}")"

  # Write JSONL entry (add storage_temps as JSON object)
  printf '{ "timestamp": %s, "cpu_temp_c": %s, "gpu_temp_c": %s, "gpu_hotspot_c": %s, "gpu_memtemp_c": %s, "gpu_power_w": %s, "gpu_fan_rpm": %s, "fan1_rpm": %s, "fan2_rpm": %s, "fan3_rpm": %s, "fan4_rpm": %s, "fan5_rpm": %s, "storage_temps": %s }\n' \
    "$now_ts" \
    "$cpu_temp" \
    "$gpu_temp" \
    "$gpu_hotspot" \
    "$gpu_memtemp" \
    "$gpu_power" \
    "$gpu_fan" \
    "$fan1" "$fan2" "$fan3" "$fan4" "$fan5" \
    "$storage_temps_str" \
    >> "$OUTFILE"

  sleep 1
done
