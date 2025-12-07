#!/usr/bin/env bash
# GHUL sensors helper – runs in background during GHULbench
# Logs one JSON record per second to logs/sensors/<timestamp>-<host>-sensors.jsonl
# Locale MUST be C for stable parsing
#
# v0.2: Enhanced sensor detection with GPU vendor detection, NVIDIA support,
#       fan auto-discovery, and --dump-layout mode

export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

BASE="$(dirname "$(dirname "$0")")"
HOST="$(hostname)"

# sanitize_num: ensures that missing or invalid sensor values are represented as "null"
# in JSON, so that jq never fails on syntactically invalid numeric fields.
sanitize_num() {
  local v="$1"
  # If empty or only whitespace → null
  if [[ -z "$v" ]]; then
    echo "null"
    return
  fi
  # If something is present but doesn't look like a number → null
  if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "null"
    return
  fi
  # Otherwise return the value unchanged
  echo "$v"
}

# ============================================================================
# GPU Vendor Detection via lspci
# ============================================================================
detect_gpu_vendor() {
  if ! command -v lspci >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  
  local lspci_line
  lspci_line="$(lspci -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' | head -n1 || true)"
  
  if [[ -z "$lspci_line" ]]; then
    echo "unknown"
    return
  fi
  
  if echo "$lspci_line" | grep -qi 'NVIDIA'; then
    echo "nvidia"
  elif echo "$lspci_line" | grep -qi 'AMD\|ATI'; then
    echo "amd"
  elif echo "$lspci_line" | grep -qi 'Intel'; then
    echo "intel"
  else
    echo "unknown"
  fi
}

GPU_VENDOR="$(detect_gpu_vendor)"

# ============================================================================
# CPU Temperature Detection (generic via sensors -j)
# ============================================================================
detect_cpu_temp_source() {
  # Use sensors -j to get structured JSON output
  local sensors_json
  sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
  
  # Look for any temp*_input that looks like a CPU temperature
  # Common patterns: coretemp, k10temp, zenpower, etc.
  # Note: sensors -j returns values in degrees (not millidegrees)
  # But some sensors might return millidegrees, so we check the value range
  local temp_value
  temp_value="$(printf '%s' "$sensors_json" | jq -r '
    paths(scalars) as $p |
    if ($p[-1] | test("temp[0-9]+_input")) and
       (getpath($p) | type == "number") and
       (getpath($p) > 0) then
      getpath($p)
    else
      empty
    end
  ' 2>/dev/null | while read -r val; do
    # If value is > 200, assume it's in millidegrees and divide by 1000
    # Otherwise, assume it's already in degrees
    if (( $(echo "$val > 200" | bc -l 2>/dev/null || echo 0) )); then
      echo "$(awk -v v="$val" 'BEGIN {printf "%.1f", v/1000}')"
    else
      echo "$val"
    fi
  done | awk '$1 > 0 && $1 < 200 {print $1; exit}' || echo "")"
  
  if [[ -n "$temp_value" ]]; then
    echo "$temp_value"
  else
    echo "null"
  fi
}

# ============================================================================
# AMD GPU Sensors via sensors -j
# ============================================================================
read_amd_gpu_sensors() {
  local sensors_json
  sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
  
  local edge="null"
  local hotspot="null"
  local mem="null"
  local power="null"
  local fan="null"
  
  # Extract edge temperature (usually amdgpu-pci-* -> edge)
  # Note: sensors -j returns values in degrees, but some might be in millidegrees
  # IMPORTANT: Only match "edge" field under amdgpu paths, not CPU temp*_input fields
  edge="$(printf '%s' "$sensors_json" | jq -r '
    paths(scalars) as $p |
    # Check if path contains "amdgpu" (GPU sensor) and field is "edge"
    if (($p | tostring | test("amdgpu")) and $p[-1] == "edge") and
       (getpath($p) | type == "number") and
       (getpath($p) > 0) then
      getpath($p)
    else
      empty
    end
  ' 2>/dev/null | while read -r val; do
    if (( $(echo "$val > 200" | bc -l 2>/dev/null || echo 0) )); then
      echo "$(awk -v v="$val" 'BEGIN {printf "%.1f", v/1000}')"
    else
      echo "$val"
    fi
  done | head -n1 || echo "")"
  
  # Extract hotspot/junction temperature
  # IMPORTANT: Only match under amdgpu paths
  hotspot="$(printf '%s' "$sensors_json" | jq -r '
    paths(scalars) as $p |
    # Check if path contains "amdgpu" (GPU sensor) and field is "junction" or "hotspot"
    if (($p | tostring | test("amdgpu")) and ($p[-1] == "junction" or $p[-1] == "hotspot")) and
       (getpath($p) | type == "number") and
       (getpath($p) > 0) then
      getpath($p)
    else
      empty
    end
  ' 2>/dev/null | while read -r val; do
    if (( $(echo "$val > 200" | bc -l 2>/dev/null || echo 0) )); then
      echo "$(awk -v v="$val" 'BEGIN {printf "%.1f", v/1000}')"
    else
      echo "$val"
    fi
  done | head -n1 || echo "")"
  
  # Extract memory temperature
  # IMPORTANT: Only match under amdgpu paths
  mem="$(printf '%s' "$sensors_json" | jq -r '
    paths(scalars) as $p |
    # Check if path contains "amdgpu" (GPU sensor) and field is "mem"
    if (($p | tostring | test("amdgpu")) and $p[-1] == "mem") and
       (getpath($p) | type == "number") and
       (getpath($p) > 0) then
      getpath($p)
    else
      empty
    end
  ' 2>/dev/null | while read -r val; do
    if (( $(echo "$val > 200" | bc -l 2>/dev/null || echo 0) )); then
      echo "$(awk -v v="$val" 'BEGIN {printf "%.1f", v/1000}')"
    else
      echo "$val"
    fi
  done | head -n1 || echo "")"
  
  # Extract power (PPT or power1_average)
  # IMPORTANT: Only match under amdgpu paths
  power="$(printf '%s' "$sensors_json" | jq -r '
    paths(scalars) as $p |
    # Check if path contains "amdgpu" (GPU sensor) and field is "PPT" or "power1_average"
    if (($p | tostring | test("amdgpu")) and ($p[-1] == "PPT" or $p[-1] == "power1_average")) and
       (getpath($p) | type == "number") and
       (getpath($p) > 0) then
      getpath($p)
    else
      empty
    end
  ' 2>/dev/null | head -n1 || echo "")"
  
  # Extract GPU fan (usually fan1 under amdgpu)
  # IMPORTANT: Only match under amdgpu paths
  fan="$(printf '%s' "$sensors_json" | jq -r '
    paths(scalars) as $p |
    # Check if path contains "amdgpu" (GPU sensor) and field matches fan*_input
    if (($p | tostring | test("amdgpu")) and ($p[-1] | test("fan[0-9]+_input"))) and
       (getpath($p) | type == "number") and
       (getpath($p) > 0) then
      getpath($p)
    else
      empty
    end
  ' 2>/dev/null | head -n1 || echo "")"
  
  # Fallback: try old sensors text parsing for AMD
  if [[ "$edge" == "null" || -z "$edge" ]]; then
    edge="$(sensors 2>/dev/null | awk '/edge:/ {gsub(/\+/,"",$2); gsub(/°C/,"",$2); print $2; exit}' || echo "")"
  fi
  if [[ "$hotspot" == "null" || -z "$hotspot" ]]; then
    hotspot="$(sensors 2>/dev/null | awk '/junction:/ {gsub(/\+/,"",$2); gsub(/°C/,"",$2); print $2; exit}' || echo "")"
  fi
  if [[ "$mem" == "null" || -z "$mem" ]]; then
    mem="$(sensors 2>/dev/null | awk '/mem:/ {gsub(/\+/,"",$2); gsub(/°C/,"",$2); print $2; exit}' || echo "")"
  fi
  if [[ "$power" == "null" || -z "$power" ]]; then
    power="$(sensors 2>/dev/null | awk '/PPT:/ {gsub(/W/,"",$2); print $2+0; exit}' || echo "")"
  fi
  if [[ "$fan" == "null" || -z "$fan" ]]; then
    fan="$(sensors 2>/dev/null | awk '/fan1:/ {gsub(/RPM/,"",$2); print $2+0; exit}' || echo "")"
  fi
  
  echo "$edge|$hotspot|$mem|$power|$fan"
}

# ============================================================================
# NVIDIA GPU Sensors via nvidia-smi
# ============================================================================
read_nvidia_gpu_sensors() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "null|null|null"
    return
  fi
  
  local temp="null"
  local fan="null"
  local power="null"
  
  # nvidia-smi --query-gpu=temperature.gpu,fan.speed,power.draw --format=csv,noheader,nounits
  local nvidia_output
  nvidia_output="$(nvidia-smi --query-gpu=temperature.gpu,fan.speed,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n1 || echo "")"
  
  if [[ -n "$nvidia_output" ]]; then
    # Parse CSV output: temperature,fan_speed,power_draw
    # Note: nvidia-smi may include spaces, so we use xargs to trim
    temp="$(echo "$nvidia_output" | cut -d',' -f1 | xargs || echo "")"
    fan="$(echo "$nvidia_output" | cut -d',' -f2 | xargs || echo "")"
    power="$(echo "$nvidia_output" | cut -d',' -f3 | xargs || echo "")"
    
    # Sanitize: remove % from fan speed, ensure values are valid
    if [[ -n "$fan" && "$fan" != "null" ]]; then
      fan="$(echo "$fan" | sed 's/%//' | xargs || echo "")"
    fi
    
    # Convert empty strings to null
    [[ -z "$temp" || "$temp" == "" ]] && temp="null"
    [[ -z "$fan" || "$fan" == "" ]] && fan="null"
    [[ -z "$power" || "$power" == "" ]] && power="null"
  fi
  
  echo "$temp|$fan|$power"
}

# ============================================================================
# Fan Auto-Discovery via sensors -j
# ============================================================================
discover_fans() {
  local sensors_json
  sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
  
  local fan_array=()
  
  # Collect all fan*_input values from sensors -j
  while IFS= read -r fan_value; do
    if [[ -n "$fan_value" && "$fan_value" != "null" && "$fan_value" != "0" ]]; then
      fan_array+=("$fan_value")
      # Limit to 5 fans
      [[ ${#fan_array[@]} -ge 5 ]] && break
    fi
  done < <(printf '%s' "$sensors_json" | jq -r '
    paths(scalars) as $p |
    if ($p[-1] | test("fan[0-9]+_input")) and
       (getpath($p) | type == "number") and
       (getpath($p) > 0) then
      getpath($p)
    else
      empty
    end
  ' 2>/dev/null || echo "")
  
  # Fallback: try old sensors text parsing
  if [[ ${#fan_array[@]} -eq 0 ]]; then
    local fan_num=1
    while [[ $fan_num -le 5 ]]; do
      local fan_val
      fan_val="$(sensors 2>/dev/null | awk -v fn="$fan_num" '/fan'$fan_num':/ {gsub(/RPM/,"",$2); print $2+0; exit}' || echo "")"
      if [[ -n "$fan_val" && "$fan_val" != "0" ]]; then
        fan_array+=("$fan_val")
      fi
      ((fan_num++))
    done
  fi
  
  # Output as pipe-separated values (up to 5)
  local result=""
  local i=0
  while [[ $i -lt 5 ]]; do
    if [[ $i -lt ${#fan_array[@]} ]]; then
      result="${result}${fan_array[$i]}"
    else
      result="${result}null"
    fi
    [[ $i -lt 4 ]] && result="${result}|"
    ((i++))
  done
  
  echo "$result"
}

# ============================================================================
# Storage Temperature Detection (unchanged from v0.1)
# ============================================================================
detect_storage_devices() {
  local devices=()
  if command -v lsblk >/dev/null 2>&1; then
    while IFS= read -r line; do
      local device
      device="$(echo "$line" | awk '{print $1}')"
      [[ -z "$device" ]] && continue
      [[ "$device" =~ ^loop ]] && continue
      if [[ "$device" =~ ^(sd|hd|vd)[a-z][0-9]+$ ]]; then
        continue  # Skip partitions
      fi
      local dev_path="/dev/${device}"
      [[ -b "$dev_path" ]] && devices+=("$device")
    done < <(lsblk -d -n -o NAME 2>/dev/null || true)
  fi
  printf '%s\n' "${devices[@]}"
}

read_storage_temp() {
  local device="$1"
  local temp="null"
  
  # Method 1: Try /sys for NVMe (works without root)
  if [[ "$device" =~ ^nvme ]]; then
    if [[ -r "/sys/block/${device}/device/hwmon" ]]; then
      for hwmon in /sys/block/${device}/device/hwmon/hwmon*/temp*_input; do
        if [[ -r "$hwmon" ]]; then
          local temp_mdeg
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
    if command -v smartctl >/dev/null 2>&1; then
      local dev_path="/dev/${device}"
      # Try smartctl with different device types (sat, ata, auto)
      for dev_type in "sat" "ata" ""; do
        local smartctl_cmd
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
  
  echo "$temp"
}

# ============================================================================
# --dump-layout Mode: Sensor Discovery (no JSON, human-readable)
# ============================================================================
dump_sensor_layout() {
  echo "== GHUL Sensor Discovery =="
  echo
  
  # GPU Vendor
  echo "GPU vendor:      ${GPU_VENDOR^^}"
  
  # GPU Sources
  if [[ "$GPU_VENDOR" == "amd" ]]; then
    echo "GPU sources:     sensors -j (edge, hotspot, mem, power, fan)"
  elif [[ "$GPU_VENDOR" == "nvidia" ]]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
      echo "GPU sources:     nvidia-smi (temp, fan, power)"
    else
      echo "GPU sources:     nvidia-smi (NOT AVAILABLE)"
    fi
  elif [[ "$GPU_VENDOR" == "intel" ]]; then
    echo "GPU sources:     (Intel GPU - sensors not implemented)"
  else
    echo "GPU sources:     (unknown GPU vendor)"
  fi
  echo
  
  # CPU Sensors
  local cpu_temp
  cpu_temp="$(detect_cpu_temp_source)"
  if [[ "$cpu_temp" != "null" && -n "$cpu_temp" ]]; then
    echo "CPU sensors:     sensors -j (temp=${cpu_temp}°C)"
  else
    echo "CPU sensors:     (no CPU temperature found)"
  fi
  echo
  
  # Fan Sensors
  local fans
  fans="$(discover_fans)"
  IFS='|' read -r fan1 fan2 fan3 fan4 fan5 <<< "$fans"
  local fan_count=0
  [[ "$fan1" != "null" && -n "$fan1" ]] && ((fan_count++))
  [[ "$fan2" != "null" && -n "$fan2" ]] && ((fan_count++))
  [[ "$fan3" != "null" && -n "$fan3" ]] && ((fan_count++))
  [[ "$fan4" != "null" && -n "$fan4" ]] && ((fan_count++))
  [[ "$fan5" != "null" && -n "$fan5" ]] && ((fan_count++))
  
  if [[ $fan_count -gt 0 ]]; then
    echo "Fan sensors:     $fan_count fan(s) detected"
    [[ "$fan1" != "null" && -n "$fan1" ]] && echo "                 fan1=${fan1} RPM"
    [[ "$fan2" != "null" && -n "$fan2" ]] && echo "                 fan2=${fan2} RPM"
    [[ "$fan3" != "null" && -n "$fan3" ]] && echo "                 fan3=${fan3} RPM"
    [[ "$fan4" != "null" && -n "$fan4" ]] && echo "                 fan4=${fan4} RPM"
    [[ "$fan5" != "null" && -n "$fan5" ]] && echo "                 fan5=${fan5} RPM"
  else
    echo "Fan sensors:     (no fans detected)"
  fi
  echo
  
  # Storage Sensors
  local storage_devices
  storage_devices=($(detect_storage_devices))
  if [[ ${#storage_devices[@]} -gt 0 ]]; then
    echo "Storage sensors:"
    for device in "${storage_devices[@]}"; do
      local temp
      temp="$(read_storage_temp "$device")"
      if [[ "$temp" != "null" && -n "$temp" ]]; then
        echo "                 ${device}=OK (${temp}°C)"
      else
        echo "                 ${device}=NOT_AVAILABLE"
      fi
    done
  else
    echo "Storage sensors: (no storage devices detected)"
  fi
  echo
  
  exit 0
}

# ============================================================================
# Main: Check for --dump-layout mode
# ============================================================================
if [[ "${1:-}" == "--dump-layout" ]]; then
  dump_sensor_layout
fi

# ============================================================================
# Normal Mode: Sensor Logging
# ============================================================================

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

# Detect storage devices once at startup
STORAGE_DEVICES=($(detect_storage_devices))

# Poll every second until parent script kills this process
while true; do
  now_ts="$(date +%s)"
  
  # CPU Temperature (generic via sensors -j)
  cpu_temp="$(detect_cpu_temp_source)"
  
  # GPU Sensors (vendor-specific)
  gpu_temp="null"
  gpu_hotspot="null"
  gpu_memtemp="null"
  gpu_power="null"
  gpu_fan="null"
  
  if [[ "$GPU_VENDOR" == "amd" ]]; then
    IFS='|' read -r gpu_temp gpu_hotspot gpu_memtemp gpu_power gpu_fan <<< "$(read_amd_gpu_sensors)"
  elif [[ "$GPU_VENDOR" == "nvidia" ]]; then
    IFS='|' read -r gpu_temp gpu_fan gpu_power <<< "$(read_nvidia_gpu_sensors)"
    # NVIDIA doesn't have hotspot/memtemp in nvidia-smi
    gpu_hotspot="null"
    gpu_memtemp="null"
  else
    # Intel or unknown: all GPU values null
    :
  fi
  
  # Fan Auto-Discovery
  IFS='|' read -r fan1 fan2 fan3 fan4 fan5 <<< "$(discover_fans)"
  
  # Storage temperatures
  storage_temps_json="{}"
  if [[ ${#STORAGE_DEVICES[@]} -gt 0 ]]; then
    for device in "${STORAGE_DEVICES[@]}"; do
      temp="$(read_storage_temp "$device")"
      
      # Only add if we got a valid temperature
      if [[ -n "$temp" && "$temp" != "0" && "$temp" != "null" ]]; then
        storage_temps_json="$(printf '%s' "$storage_temps_json" | jq --arg dev "$device" --arg t "$temp" '. + {($dev): ($t|tonumber? // 0)}' 2>/dev/null || echo "$storage_temps_json")"
      fi
    done
  fi
  
  # Convert storage_temps_json to a compact string
  storage_temps_str="$(printf '%s' "$storage_temps_json" | jq -c '.' 2>/dev/null || echo "{}")"
  
  # Sanitize all numeric sensor values to ensure valid JSON (null instead of empty/invalid)
  cpu_temp="$(sanitize_num "$cpu_temp")"
  gpu_temp="$(sanitize_num "$gpu_temp")"
  gpu_hotspot="$(sanitize_num "$gpu_hotspot")"
  gpu_memtemp="$(sanitize_num "$gpu_memtemp")"
  gpu_power="$(sanitize_num "$gpu_power")"
  gpu_fan="$(sanitize_num "$gpu_fan")"
  fan1="$(sanitize_num "$fan1")"
  fan2="$(sanitize_num "$fan2")"
  fan3="$(sanitize_num "$fan3")"
  fan4="$(sanitize_num "$fan4")"
  fan5="$(sanitize_num "$fan5")"
  
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
