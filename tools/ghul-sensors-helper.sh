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
# CPU Power Detection
# ============================================================================
read_cpu_power() {
  local power="null"
  local sensors_json
  sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
  
  # Try to find CPU power from sensors -j (PPT, TDP, power1_average, etc.)
  # Look for CPU-related power sensors (coretemp, k10temp, zenpower, etc.)
  power="$(printf '%s' "$sensors_json" | jq -r '
    paths(scalars) as $p |
    # Check if path contains CPU sensor (coretemp, k10temp, zenpower) and field is power-related
    if (($p | tostring | test("coretemp|k10temp|zenpower|intel")) and 
        ($p[-1] | test("PPT|TDP|power[0-9]+_average|Package.*power"))) and
       (getpath($p) | type == "number") and
       (getpath($p) > 0) then
      getpath($p)
    else
      empty
    end
  ' 2>/dev/null | head -n1 || echo "")"
  
  # Fallback: try sensors text output
  if [[ "$power" == "null" || -z "$power" ]]; then
    power="$(sensors 2>/dev/null | awk '/Package id 0:/,/^$/ {if(/power/) {gsub(/W/,"",$2); print $2+0; exit}}' || echo "")"
  fi
  
  # Convert empty strings to null
  [[ -z "$power" || "$power" == "" ]] && power="null"
  echo "$power"
}

# ============================================================================
# CPU Clock Detection
# ============================================================================
read_cpu_clock() {
  local clock="null"
  
  # Read CPU frequency from /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq (in kHz)
  if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]]; then
    local freq_khz
    freq_khz="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "")"
    if [[ -n "$freq_khz" && "$freq_khz" =~ ^[0-9]+$ ]]; then
      # Convert kHz to MHz
      clock="$(awk -v k="$freq_khz" 'BEGIN { printf "%.0f", k/1000 }')"
    fi
  fi
  
  # Fallback: try /proc/cpuinfo
  if [[ "$clock" == "null" || -z "$clock" ]]; then
    clock="$(awk '/cpu MHz/ {print $4+0; exit}' /proc/cpuinfo 2>/dev/null | awk '{printf "%.0f", $1}' || echo "")"
  fi
  
  # Convert empty strings to null
  [[ -z "$clock" || "$clock" == "" ]] && clock="null"
  echo "$clock"
}

# ============================================================================
# CPU Temperature Detection (improved: prefer Package temp, fallback to sensors -j)
# ============================================================================
detect_cpu_temp_source() {
  local temp_value="null"
  
  # Method 1: Try /sys/class/hwmon for coretemp Package temperature (most reliable)
  # Look for coretemp hwmon and get temp1_input (Package temperature)
  for hwmon in /sys/class/hwmon/hwmon*; do
    local hwmon_name
    hwmon_name="$(cat "$hwmon/name" 2>/dev/null || echo "")"
    
    # Check if this is a coretemp sensor
    if [[ "$hwmon_name" == "coretemp" ]]; then
      # Try temp1_input (Package temperature) first
      if [[ -r "$hwmon/temp1_input" ]]; then
        local temp_mdeg
        temp_mdeg="$(cat "$hwmon/temp1_input" 2>/dev/null || echo 0)"
        if [[ "$temp_mdeg" != "0" && -n "$temp_mdeg" ]]; then
          temp_value="$(awk -v t="$temp_mdeg" 'BEGIN { printf "%.1f", t/1000 }')"
          break
        fi
      fi
    fi
  done
  
  # Method 2: Fallback to sensors -j (prefer Package temp from coretemp)
  if [[ "$temp_value" == "null" ]]; then
    local sensors_json
    sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
    
    # First try: Package temperature from coretemp (temp1_input under "Package id 0" or similar)
    temp_value="$(printf '%s' "$sensors_json" | jq -r '
      # Look for coretemp and get Package temperature (temp1_input)
      ."coretemp-isa-0000" // ."coretemp-isa-0001" // empty |
      ."Package id 0" // ."Package id 1" // ."Tctl" // ."Tdie" // empty |
      .temp1_input // .temp2_input // empty |
      select(. != null and . > 0 and . < 200)
    ' 2>/dev/null | head -n1 || echo "")"
    
    # Second try: Any CPU temperature from coretemp, k10temp, zenpower, etc.
    if [[ -z "$temp_value" || "$temp_value" == "null" ]]; then
      temp_value="$(printf '%s' "$sensors_json" | jq -r '
        paths(scalars) as $p |
        # Match coretemp, k10temp, zenpower, etc. but exclude GPU sensors
        if (($p | tostring | test("coretemp|k10temp|zenpower|k8temp") and
             ($p | tostring | test("amdgpu|nvidia") | not)) and
            ($p[-1] | test("temp[0-9]+_input")) and
            (getpath($p) | type == "number") and
            (getpath($p) > 0) and
            (getpath($p) < 200)) then
          getpath($p)
        else
          empty
        end
      ' 2>/dev/null | head -n1 || echo "")"
    fi
  fi
  
  if [[ -n "$temp_value" && "$temp_value" != "null" ]]; then
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
  
  # Try to read GPU clocks from sysfs (AMD)
  local clock_core="null"
  local clock_mem="null"
  local amd_card_path=""
  for path in /sys/class/drm/card*/device; do
    if [[ -f "$path/pp_dpm_sclk" ]] && [[ -f "$path/pp_dpm_mclk" ]]; then
      amd_card_path="$path"
      break
    fi
  done
  
  if [[ -n "$amd_card_path" ]]; then
    # Read current GPU core clock (marked with *)
    local sclk_line
    sclk_line="$(grep '\*' "${amd_card_path}/pp_dpm_sclk" 2>/dev/null | head -n1 || echo "")"
    if [[ -n "$sclk_line" ]]; then
      clock_core="$(echo "$sclk_line" | awk '{print $2}' | sed 's/MHz//' | xargs || echo "")"
    fi
    
    # Read current GPU memory clock (marked with *)
    local mclk_line
    mclk_line="$(grep '\*' "${amd_card_path}/pp_dpm_mclk" 2>/dev/null | head -n1 || echo "")"
    if [[ -n "$mclk_line" ]]; then
      clock_mem="$(echo "$mclk_line" | awk '{print $2}' | sed 's/MHz//' | xargs || echo "")"
    fi
  fi
  
  # Convert empty strings to null
  [[ -z "$clock_core" || "$clock_core" == "" ]] && clock_core="null"
  [[ -z "$clock_mem" || "$clock_mem" == "" ]] && clock_mem="null"
  
  echo "$edge|$hotspot|$mem|$power|$fan|$clock_core|$clock_mem"
}

# ============================================================================
# NVIDIA GPU Sensors via nvidia-smi
# ============================================================================
read_nvidia_gpu_sensors() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "null|null|null|null|null"
    return
  fi
  
  local temp="null"
  local fan="null"
  local power="null"
  local clock_core="null"
  local clock_mem="null"
  
  # nvidia-smi --query-gpu=temperature.gpu,fan.speed,power.draw,clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits
  local nvidia_output
  nvidia_output="$(nvidia-smi --query-gpu=temperature.gpu,fan.speed,power.draw,clocks.current.graphics,clocks.current.memory --format=csv,noheader,nounits 2>/dev/null | head -n1 || echo "")"
  
  if [[ -n "$nvidia_output" ]]; then
    # Parse CSV output: temperature,fan_speed,power_draw,clock_core,clock_mem
    # Note: nvidia-smi may include spaces, so we use xargs to trim
    temp="$(echo "$nvidia_output" | cut -d',' -f1 | xargs || echo "")"
    fan="$(echo "$nvidia_output" | cut -d',' -f2 | xargs || echo "")"
    power="$(echo "$nvidia_output" | cut -d',' -f3 | xargs || echo "")"
    clock_core="$(echo "$nvidia_output" | cut -d',' -f4 | xargs || echo "")"
    clock_mem="$(echo "$nvidia_output" | cut -d',' -f5 | xargs || echo "")"
    
    # Sanitize: remove % from fan speed, ensure values are valid
    if [[ -n "$fan" && "$fan" != "null" ]]; then
      fan="$(echo "$fan" | sed 's/%//' | xargs || echo "")"
    fi
    
    # Convert empty strings to null
    [[ -z "$temp" || "$temp" == "" ]] && temp="null"
    [[ -z "$fan" || "$fan" == "" ]] && fan="null"
    [[ -z "$power" || "$power" == "" ]] && power="null"
    [[ -z "$clock_core" || "$clock_core" == "" ]] && clock_core="null"
    [[ -z "$clock_mem" || "$clock_mem" == "" ]] && clock_mem="null"
  fi
  
  echo "$temp|$fan|$power|$clock_core|$clock_mem"
}

# ============================================================================
# Fan Auto-Discovery (improved: check /sys/class/hwmon directly, then sensors -j)
# ============================================================================
discover_fans() {
  local fan_array=()
  
  # Method 1: Direct /sys/class/hwmon access (most reliable)
  # Look for fan*_input files in hwmon directories, exclude GPU fans
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
          fan_array+=("$fan_rpm")
          # Limit to 5 fans
          [[ ${#fan_array[@]} -ge 5 ]] && break 2
        fi
      fi
    done
  done
  
  # Method 2: Fallback to sensors -j
  if [[ ${#fan_array[@]} -eq 0 ]]; then
    local sensors_json
    sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
    
    # Collect all fan*_input values from sensors -j
    # Exclude GPU fans (amdgpu, nvidia) - only collect case/motherboard fans
    while IFS= read -r fan_value; do
      if [[ -n "$fan_value" && "$fan_value" != "null" && "$fan_value" != "0" ]]; then
        fan_array+=("$fan_value")
        # Limit to 5 fans
        [[ ${#fan_array[@]} -ge 5 ]] && break
      fi
    done < <(printf '%s' "$sensors_json" | jq -r '
      paths(scalars) as $p |
      # Match fan*_input but exclude GPU-related paths (amdgpu, nvidia)
      if (($p | tostring | test("amdgpu|nvidia") | not) and
          ($p[-1] | test("fan[0-9]+_input")) and
          (getpath($p) | type == "number") and
          (getpath($p) > 0)) then
        getpath($p)
      else
        empty
      end
    ' 2>/dev/null || echo "")
  fi
  
  # Method 3: Fallback to sensors text parsing
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
  
  # Method 1: Try sensors -j for NVMe (works without root, most reliable)
  if [[ "$device" =~ ^nvme ]]; then
    local sensors_json
    sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
    
    # Look for nvme-pci-* sensors and get temp1_input (Composite temperature)
    # The key in sensors -j is like "nvme-pci-0c00", and temp1_input is under "Composite"
    temp="$(printf '%s' "$sensors_json" | jq -r '
      # Find all keys that match nvme-pci-*
      keys[] |
      select(test("nvme-pci")) as $nvme_key |
      .[$nvme_key] |
      .Composite.temp1_input // .Composite.temp2_input // empty |
      select(. != null and . > 0 and . < 200)
    ' 2>/dev/null | head -n1 || echo "")"
    
    # Alternative: search in paths if the above doesn't work
    if [[ -z "$temp" || "$temp" == "null" ]]; then
      temp="$(printf '%s' "$sensors_json" | jq -r '
        paths(scalars) as $p |
        # Match nvme-pci-* in the path (key name) and temp1_input or temp2_input
        if (($p[0] | tostring | test("nvme-pci")) and
            ($p[-1] == "temp1_input" or $p[-1] == "temp2_input")) and
           (getpath($p) | type == "number") and
           (getpath($p) > 0) and
           (getpath($p) < 200) then
          getpath($p)
        else
          empty
        end
      ' 2>/dev/null | head -n1 || echo "")"
    fi
  fi
  
  # Method 2: Try /sys/class/hwmon for NVMe (direct hwmon access)
  if [[ "$device" =~ ^nvme && ("$temp" == "null" || "$temp" == "0" || -z "$temp") ]]; then
    # Find hwmon with "nvme" in name
    for hwmon in /sys/class/hwmon/hwmon*; do
      local hwmon_name
      hwmon_name="$(cat "$hwmon/name" 2>/dev/null || echo "")"
      
      if [[ "$hwmon_name" == "nvme" ]]; then
        # Try temp1_input (Composite temperature)
        if [[ -r "$hwmon/temp1_input" ]]; then
          local temp_mdeg
          temp_mdeg="$(cat "$hwmon/temp1_input" 2>/dev/null || echo 0)"
          if [[ "$temp_mdeg" != "0" && -n "$temp_mdeg" ]]; then
            temp="$(awk -v t="$temp_mdeg" 'BEGIN { printf "%.1f", t/1000 }')"
            break
          fi
        fi
      fi
    done
  fi
  
  # Method 3: Try /sys/block for NVMe (legacy path)
  if [[ "$device" =~ ^nvme && ("$temp" == "null" || "$temp" == "0" || -z "$temp") ]]; then
    if [[ -r "/sys/block/${device}/device/hwmon" ]]; then
      for hwmon in /sys/block/${device}/device/hwmon/hwmon*/temp*_input; do
        if [[ -r "$hwmon" ]]; then
          local temp_mdeg
          temp_mdeg="$(cat "$hwmon" 2>/dev/null || echo 0)"
          if [[ "$temp_mdeg" != "0" && -n "$temp_mdeg" ]]; then
            temp="$(awk -v t="$temp_mdeg" 'BEGIN { printf "%.1f", t/1000 }')"
            break
          fi
        fi
      done
    fi
  fi
  
  # Method 4: Try smartctl (may need root, but try anyway)
  if [[ "$temp" == "null" || "$temp" == "0" || -z "$temp" ]]; then
    if command -v smartctl >/dev/null 2>&1; then
      local dev_path="/dev/${device}"
      # For NVMe, try nvme device type first
      if [[ "$device" =~ ^nvme ]]; then
        local nvme_base
        nvme_base="$(echo "$device" | sed 's/p[0-9]*$//')"  # nvme0n1p2 -> nvme0n1
        temp="$(smartctl -A "/dev/${nvme_base}" 2>/dev/null | awk '
          /Temperature:/ { print $2; exit }
          /^[0-9][0-9][0-9][[:space:]]+194/ { print $10; exit }
          /^[0-9][0-9][0-9][[:space:]]+190/ { print $10; exit }
        ' | head -n1)"
      fi
      # If still no temperature, try different device types (sat, ata, auto)
      if [[ "$temp" == "null" || "$temp" == "0" || -z "$temp" ]]; then
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
  
  # GPU Sources (with live values)
  if [[ "$GPU_VENDOR" == "amd" ]]; then
    local gpu_sensors
    gpu_sensors="$(read_amd_gpu_sensors)"
    IFS='|' read -r gpu_temp gpu_hotspot gpu_memtemp gpu_power gpu_fan <<< "$gpu_sensors"
    echo "GPU sources:     sensors -j"
    [[ "$gpu_temp" != "null" && -n "$gpu_temp" ]] && echo "                 edge temp:     ${gpu_temp}°C"
    [[ "$gpu_hotspot" != "null" && -n "$gpu_hotspot" ]] && echo "                 hotspot temp:  ${gpu_hotspot}°C"
    [[ "$gpu_memtemp" != "null" && -n "$gpu_memtemp" ]] && echo "                 memory temp:   ${gpu_memtemp}°C"
    [[ "$gpu_power" != "null" && -n "$gpu_power" ]] && echo "                 power:         ${gpu_power}W"
    [[ "$gpu_fan" != "null" && -n "$gpu_fan" ]] && echo "                 fan:           ${gpu_fan} RPM"
  elif [[ "$GPU_VENDOR" == "nvidia" ]]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
      local gpu_sensors
      gpu_sensors="$(read_nvidia_gpu_sensors)"
      IFS='|' read -r gpu_temp gpu_fan gpu_power <<< "$gpu_sensors"
      echo "GPU sources:     nvidia-smi"
      [[ "$gpu_temp" != "null" && -n "$gpu_temp" ]] && echo "                 temp:          ${gpu_temp}°C"
      [[ "$gpu_fan" != "null" && -n "$gpu_fan" ]] && echo "                 fan:           ${gpu_fan}%"
      [[ "$gpu_power" != "null" && -n "$gpu_power" ]] && echo "                 power:         ${gpu_power}W"
    else
      echo "GPU sources:     nvidia-smi (NOT AVAILABLE)"
    fi
  elif [[ "$GPU_VENDOR" == "intel" ]]; then
    echo "GPU sources:     (Intel GPU - sensors not implemented)"
  else
    echo "GPU sources:     (unknown GPU vendor)"
  fi
  echo
  
  # CPU Sensors (with source info)
  local cpu_temp
  cpu_temp="$(detect_cpu_temp_source)"
  if [[ "$cpu_temp" != "null" && -n "$cpu_temp" ]]; then
    echo "CPU sensors:     Package temperature: ${cpu_temp}°C"
    # Show source
    if [[ -r /sys/class/hwmon/hwmon*/name ]]; then
      for hwmon in /sys/class/hwmon/hwmon*; do
        local hwmon_name
        hwmon_name="$(cat "$hwmon/name" 2>/dev/null || echo "")"
        if [[ "$hwmon_name" == "coretemp" && -r "$hwmon/temp1_input" ]]; then
          echo "                 source:        /sys/class/hwmon/$(basename $hwmon)/temp1_input"
          break
        fi
      done
    fi
    if ! [[ -r /sys/class/hwmon/hwmon*/name ]] || ! grep -q "coretemp" /sys/class/hwmon/hwmon*/name 2>/dev/null; then
      echo "                 source:        sensors -j (coretemp)"
    fi
  else
    echo "CPU sensors:     (no CPU temperature found)"
    echo "                 checked:       /sys/class/hwmon, sensors -j"
  fi
  echo
  
  # Fan Sensors (with detailed info)
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
    [[ "$fan1" != "null" && -n "$fan1" ]] && echo "                 fan1:          ${fan1} RPM"
    [[ "$fan2" != "null" && -n "$fan2" ]] && echo "                 fan2:          ${fan2} RPM"
    [[ "$fan3" != "null" && -n "$fan3" ]] && echo "                 fan3:          ${fan3} RPM"
    [[ "$fan4" != "null" && -n "$fan4" ]] && echo "                 fan4:          ${fan4} RPM"
    [[ "$fan5" != "null" && -n "$fan5" ]] && echo "                 fan5:          ${fan5} RPM"
    echo "                 source:        /sys/class/hwmon, sensors -j"
  else
    echo "Fan sensors:     (no fans detected)"
    echo "                 checked:       /sys/class/hwmon/*/fan*_input"
    echo "                                sensors -j (excluding GPU fans)"
    echo "                                sensors (text output)"
    echo "                 note:          Some systems don't expose fan sensors"
    echo "                                via standard interfaces"
  fi
  echo
  
  # Storage Sensors (with detailed info)
  local storage_devices
  storage_devices=($(detect_storage_devices))
  if [[ ${#storage_devices[@]} -gt 0 ]]; then
    echo "Storage sensors:"
    for device in "${storage_devices[@]}"; do
      local temp
      local source_info=""
      temp="$(read_storage_temp "$device")"
      
      # Determine source (check in order of preference)
      if [[ "$device" =~ ^nvme ]]; then
        # Check if found via sensors -j (most reliable)
        local sensors_json
        sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
        local nvme_key
        nvme_key="$(printf '%s' "$sensors_json" | jq -r 'keys[] | select(test("nvme-pci"))' 2>/dev/null | head -n1 || echo "")"
        if [[ -n "$nvme_key" ]]; then
          local temp_from_sensors
          temp_from_sensors="$(printf '%s' "$sensors_json" | jq -r --arg k "$nvme_key" '.[$k].Composite.temp1_input // .[$k].Composite.temp2_input // empty' 2>/dev/null || echo "")"
          if [[ -n "$temp_from_sensors" && "$temp_from_sensors" != "null" && "$temp_from_sensors" != "0" ]]; then
            source_info="sensors -j (${nvme_key})"
          elif [[ -r /sys/class/hwmon/hwmon*/name ]] && grep -q "nvme" /sys/class/hwmon/hwmon*/name 2>/dev/null; then
            for hwmon in /sys/class/hwmon/hwmon*; do
              if [[ "$(cat "$hwmon/name" 2>/dev/null)" == "nvme" && -r "$hwmon/temp1_input" ]]; then
                source_info="/sys/class/hwmon/$(basename $hwmon)/temp1_input"
                break
              fi
            done
          else
            source_info="smartctl or /sys/block"
          fi
        elif [[ -r /sys/class/hwmon/hwmon*/name ]] && grep -q "nvme" /sys/class/hwmon/hwmon*/name 2>/dev/null; then
          for hwmon in /sys/class/hwmon/hwmon*; do
            if [[ "$(cat "$hwmon/name" 2>/dev/null)" == "nvme" && -r "$hwmon/temp1_input" ]]; then
              source_info="/sys/class/hwmon/$(basename $hwmon)/temp1_input"
              break
            fi
          done
        else
          source_info="smartctl or /sys/block"
        fi
      else
        source_info="smartctl"
      fi
      
      if [[ "$temp" != "null" && -n "$temp" ]]; then
        echo "                 ${device}:        ${temp}°C (source: ${source_info})"
      else
        echo "                 ${device}:        NOT_AVAILABLE"
        echo "                                checked:       ${source_info}"
      fi
    done
  else
    echo "Storage sensors: (no storage devices detected)"
  fi
  echo
  
  # Summary of all hwmon devices
  echo "All hwmon devices:"
  for hwmon in /sys/class/hwmon/hwmon*; do
    local hwmon_name
    hwmon_name="$(cat "$hwmon/name" 2>/dev/null || echo "unknown")"
    echo "                 $(basename $hwmon): $hwmon_name"
  done
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

# Check if output file is provided as argument (for hellfire tests)
if [[ -n "${1:-}" && "$1" != "--dump-layout" && "$1" =~ \.jsonl$ ]]; then
  # Output file provided as argument (for hellfire)
  OUTFILE="$1"
  mkdir -p "$(dirname "$OUTFILE")"
  echo "[GHUL] Sensors helper writing to: $OUTFILE" >&2
else
  # Normal mode: use default location
  SENSLOG_DIR="${BASE}/logs/sensors"
  mkdir -p "$SENSLOG_DIR"
  
  # Use run timestamp from ghul-benchmark if provided, else fallback.
  # Format: YYYY-mm-dd-HH-MM (no seconds)
  TS_RUN="${GHUL_RUN_TS:-$(date +%Y-%m-%d-%H-%M)}"
  OUTFILE="${SENSLOG_DIR}/${TS_RUN}-${HOST}-sensors.jsonl"
  
  echo "[GHUL] Sensors helper writing to: $OUTFILE" >&2
fi

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
    IFS='|' read -r gpu_temp gpu_hotspot gpu_memtemp gpu_power gpu_fan gpu_clock_core gpu_clock_mem <<< "$(read_amd_gpu_sensors)"
  elif [[ "$GPU_VENDOR" == "nvidia" ]]; then
    IFS='|' read -r gpu_temp gpu_fan gpu_power gpu_clock_core gpu_clock_mem <<< "$(read_nvidia_gpu_sensors)"
    # NVIDIA doesn't have hotspot/memtemp in nvidia-smi
    gpu_hotspot="null"
    gpu_memtemp="null"
  else
    # Intel or unknown: all GPU values null
    gpu_clock_core="null"
    gpu_clock_mem="null"
  fi
  
  # CPU Power and Clock
  cpu_power="$(read_cpu_power)"
  cpu_clock="$(read_cpu_clock)"
  
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
  cpu_power="$(sanitize_num "$cpu_power")"
  cpu_clock="$(sanitize_num "$cpu_clock")"
  gpu_temp="$(sanitize_num "$gpu_temp")"
  gpu_hotspot="$(sanitize_num "$gpu_hotspot")"
  gpu_memtemp="$(sanitize_num "$gpu_memtemp")"
  gpu_power="$(sanitize_num "$gpu_power")"
  gpu_fan="$(sanitize_num "$gpu_fan")"
  gpu_clock_core="$(sanitize_num "$gpu_clock_core")"
  gpu_clock_mem="$(sanitize_num "$gpu_clock_mem")"
  fan1="$(sanitize_num "$fan1")"
  fan2="$(sanitize_num "$fan2")"
  fan3="$(sanitize_num "$fan3")"
  fan4="$(sanitize_num "$fan4")"
  fan5="$(sanitize_num "$fan5")"
  
  # Write JSONL entry (add storage_temps as JSON object)
  printf '{ "timestamp": %s, "cpu_temp_c": %s, "cpu_power_w": %s, "cpu_clock": %s, "gpu_temp_c": %s, "gpu_hotspot_c": %s, "gpu_memtemp_c": %s, "gpu_power_w": %s, "gpu_fan_rpm": %s, "gpu_clock_core": %s, "gpu_clock_mem": %s, "fan1_rpm": %s, "fan2_rpm": %s, "fan3_rpm": %s, "fan4_rpm": %s, "fan5_rpm": %s, "storage_temps": %s }\n' \
    "$now_ts" \
    "$cpu_temp" \
    "$cpu_power" \
    "$cpu_clock" \
    "$gpu_temp" \
    "$gpu_hotspot" \
    "$gpu_memtemp" \
    "$gpu_power" \
    "$gpu_fan" \
    "$gpu_clock_core" \
    "$gpu_clock_mem" \
    "$fan1" "$fan2" "$fan3" "$fan4" "$fan5" \
    "$storage_temps_str" \
    >> "$OUTFILE"
  
  sleep 1
done
