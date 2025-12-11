#!/usr/bin/env bash
# GHUL Hellfire Common Functions
# Shared functions for all Hellfire stress tests

set -euo pipefail

# ---------- Help function (with humor) -----------------------------------------
show_help() {
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║                    GHUL HELLFIRE                              ║"
  echo "║                    LITTLE HELPER                             ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo
  echo "Hello! 👋"
  echo
  echo "I am 'hellfire-common.sh' – a humble little helper."
  echo "I handle the administrative tasks for the other Hellfire scripts."
  echo
  echo "I should NOT be called directly!"
  echo "I am just a library with shared functions."
  echo
  echo "The other Hellfire scripts need me:"
  echo "  • ghul-hellfire-cpu.sh    - Extreme CPU Stress Test"
  echo "  • ghul-hellfire-ram.sh    - Extreme RAM Stress Test"
  echo "  • ghul-hellfire-gpu.sh    - Extreme GPU Stress Test"
  echo "  • ghul-hellfire-cooler.sh - Full System Furnace Test"
  echo
  echo "Call those scripts directly, not me!"
  echo
  echo "I take care of:"
  echo "  • Sensor monitoring"
  echo "  • Safety logic (temperature monitoring)"
  echo "  • Cleanup and process management"
  echo "  • Evaluation and rating calculation"
  echo "  • Pretty output and warnings"
  echo
  echo "So: Let me work in peace and call the others! 😊"
  echo
  exit 0
}

# Check for help flag (if someone tries to call me directly)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Script is being called directly (not sourced)
  if [[ $# -ge 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
  else
    echo "⚠️  This script should not be called directly!" >&2
    echo "   It is a library for other Hellfire scripts." >&2
    echo "   Use -h or --help for more information." >&2
    exit 1
  fi
fi

# Set locale to C to avoid decimal separator issues
export LC_ALL=C

# ============================================================================
# Configuration and Paths
# ============================================================================

# Determine base directory (parent of tools/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLFIRE_DIR="$SCRIPT_DIR"
LOGDIR="${BASE}/logs/hellfire"
HOST="$(hostname)"

# Ensure log directory exists
mkdir -p "$LOGDIR"

# ============================================================================
# Color Output Functions
# ============================================================================

red() {
  printf '\033[31m%s\033[0m\n' "$*"
}

green() {
  printf '\033[32m%s\033[0m\n' "$*"
}

yellow() {
  printf '\033[33m%s\033[0m\n' "$*"
}

blue() {
  printf '\033[34m%s\033[0m\n' "$*"
}

bold() {
  printf '\033[1m%s\033[0m\n' "$*"
}

# ============================================================================
# Utility Functions
# ============================================================================

have() {
  command -v "$1" >/dev/null 2>&1
}

get_timestamp() {
  date +"%Y-%m-%d-%H-%M-%S"
}

# ============================================================================
# Warning and Header Functions
# ============================================================================

print_hellfire_warning() {
  echo
  printf '\033[41;97;1m%s\033[0m\n' "======================================================================"
  printf '\033[41;97;1m%s\033[0m\n' "   ⚠️  GHUL HELLFIRE – EXTREME HARDWARE TORTURE MODE ACTIVATED ⚠️       "
  printf '\033[41;97;1m%s\033[0m\n' "======================================================================"
  echo
  echo "This is NOT a benchmark. This is NOT a stress test."
  echo "This is a *hardware torture procedure* designed to push your CPU / GPU / RAM / PSU"
  echo "far beyond any real-world workload."
  echo
  echo "Heat levels will reach extreme values."
  echo "Your room will heat up."
  echo "Your fans will scream."
  echo "Your PSU will beg for mercy."
  echo
  printf '\033[41;97;1m%s\033[0m\n' "Warning: the name says it all."
  echo
  echo "If cooling, power delivery, thermal paste, mounting pressure or airflow are"
  echo "inadequate, permanent hardware damage is possible."
  echo
  printf '\033[97;41;1m%s\033[0m\n' "To continue, type YES exactly. Anything else aborts."
  echo
}

print_hellfire_header() {
  local test_name="$1"
  # Box width is 65 characters, left part "║                    " is 21 chars, right "║" is 1 char
  # So padding = 65 - 21 - ${#test_name} - 1 = 43 - ${#test_name}
  local padding_len=$((43 - ${#test_name}))
  local padding=""
  if [[ $padding_len -gt 0 ]]; then
    padding="$(printf '%*s' "$padding_len" '')"
  fi
  echo
  red "╔═══════════════════════════════════════════════════════════════╗"
  red "║                    GHUL HELLFIRE                              ║"
  red "║                    ${test_name}${padding}║"
  red "╚═══════════════════════════════════════════════════════════════╝"
  echo
}

# ============================================================================
# Sensor Monitoring Functions
# ============================================================================

start_sensor_monitor() {
  local test_name="$1"
  local duration="${2:-0}"
  local ts
  ts="$(get_timestamp)"
  local sensor_log="${LOGDIR}/${ts}-${HOST}-${test_name}-sensors.jsonl"
  
  local helper_script="${BASE}/tools/ghul-sensors-helper.sh"
  if [[ ! -f "$helper_script" ]]; then
    yellow "  Warning: ghul-sensors-helper.sh not found, sensor monitoring disabled"
    return 1
  fi
  
  # Start sensor helper in background
  "$helper_script" "$sensor_log" >/dev/null 2>&1 &
  local pid=$!
  
  # Store PID for cleanup
  local pid_file="${LOGDIR}/.sensor-helper-${test_name}.pid"
  echo "$pid" > "$pid_file"
  
  green "  Sensor monitoring started (PID: $pid)"
  green "  Sensor log: $sensor_log"
  echo
  
  return 0
}

stop_sensor_monitor() {
  local test_name="$1"
  local pid_file="${LOGDIR}/.sensor-helper-${test_name}.pid"
  
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi
}

# ============================================================================
# CPU Temperature Functions
# ============================================================================

read_cpu_temp() {
  local cpu_temp="null"
  
  # Method 1: Try /sys/class/hwmon (coretemp)
  for hwmon in /sys/class/hwmon/hwmon*; do
    local hwmon_name
    hwmon_name="$(cat "$hwmon/name" 2>/dev/null || echo "")"
    
    if [[ "$hwmon_name" == "coretemp" ]]; then
      # Try Package id 0 temp1_input
      if [[ -f "$hwmon/temp1_input" ]]; then
        local temp_raw
        temp_raw="$(cat "$hwmon/temp1_input" 2>/dev/null || echo "")"
        if [[ -n "$temp_raw" ]] && [[ "$temp_raw" =~ ^[0-9]+$ ]]; then
          cpu_temp="$(awk -v t="$temp_raw" 'BEGIN {printf "%.1f", t/1000}')"
          break
        fi
      fi
    fi
  done
  
  # Method 2: Try sensors -j (JSON)
  if [[ "$cpu_temp" == "null" ]] && have sensors && have jq; then
    local sensors_json
    sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
    cpu_temp="$(printf '%s' "$sensors_json" | jq -r '
      ."coretemp-isa-0000" // ."coretemp-isa-0001" // empty |
      ."Package id 0" // ."Package id 1" // ."Tctl" // ."Tdie" // empty |
      .temp1_input // empty |
      select(. != null and . > 0 and . < 200)
    ' 2>/dev/null | head -n1 || echo "")"
  fi
  
  # Method 3: Fallback to sensors text
  if [[ "$cpu_temp" == "null" || -z "$cpu_temp" ]] && have sensors; then
    cpu_temp="$(sensors 2>/dev/null | awk '/Package id 0:/,/^$/ {if(/temp1:/) {gsub(/\+/,"",$2); gsub(/°C/,"",$2); print $2; exit}}' || echo "")"
  fi
  
  # Return null if still empty
  if [[ -z "$cpu_temp" || "$cpu_temp" == "null" ]]; then
    echo "null"
  else
    echo "$cpu_temp"
  fi
}

monitor_cpu_temp() {
  local test_name="$1"
  local duration="$2"
  local stress_pid="$3"
  local cpu_limit=100.0
  local over_limit_start=0
  local over_limit_duration=0
  
  local start_time
  start_time="$(date +%s)"
  local end_time
  end_time=$((start_time + duration))
  
  while [[ $(date +%s) -lt $end_time ]]; do
    # Check if stress process is still running
    if ! kill -0 "$stress_pid" 2>/dev/null; then
      break
    fi
    
    local current_temp
    current_temp="$(read_cpu_temp)"
    
    if [[ "$current_temp" != "null" ]]; then
      # Check if over limit
      if (( $(echo "$current_temp > $cpu_limit" | bc -l 2>/dev/null || echo 0) )); then
        if [[ $over_limit_start -eq 0 ]]; then
          over_limit_start="$(date +%s)"
        fi
        
        over_limit_duration=$(( $(date +%s) - over_limit_start ))
        
        if [[ $over_limit_duration -ge 5 ]]; then
          export HELLFIRE_TEMP_FAILED=1
          red "  🚨 CRITICAL: CPU temperature ${current_temp}°C > ${cpu_limit}°C for ${over_limit_duration}s"
          kill "$stress_pid" 2>/dev/null || true
          break
        fi
      else
        over_limit_start=0
        over_limit_duration=0
      fi
    fi
    
    sleep 1
  done
}

# ============================================================================
# GPU Functions
# ============================================================================

detect_gpu_vendor() {
  local lspci_line
  lspci_line="$(lspci -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' | head -n1 || true)"
  
  if [[ -z "$lspci_line" ]]; then
    echo "unknown"
    return
  fi
  
  # Check NVIDIA first (to avoid matching "ati" in "Corporation")
  if echo "$lspci_line" | grep -qiE "nvidia|geforce"; then
    echo "nvidia"
  elif echo "$lspci_line" | grep -qiE "amd|ati|radeon"; then
    echo "amd"
  elif echo "$lspci_line" | grep -qi "intel"; then
    echo "intel"
  else
    echo "unknown"
  fi
}

read_amd_gpu_sensors() {
  local sensors_json
  sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
  
  local edge="null"
  local hotspot="null"
  local mem="null"
  local power="null"
  local fan="null"
  
  # Extract edge temperature (simplified jq query)
  edge="$(printf '%s' "$sensors_json" | jq -r '
    [paths(scalars) as $p | 
     select(($p | tostring | test("amdgpu")) and ($p[-1] == "edge")) |
     getpath($p)] |
    select(length > 0) |
    .[0] |
    select(. != null and . > 0 and . < 200)
  ' 2>/dev/null | head -n1 || echo "")"
  
  # Extract hotspot/junction
  hotspot="$(printf '%s' "$sensors_json" | jq -r '
    [paths(scalars) as $p |
     select(($p | tostring | test("amdgpu")) and (($p[-1] == "junction" or $p[-1] == "hotspot"))) |
     getpath($p)] |
    select(length > 0) |
    .[0] |
    select(. != null and . > 0 and . < 200)
  ' 2>/dev/null | head -n1 || echo "")"
  
  # Extract memory temperature
  mem="$(printf '%s' "$sensors_json" | jq -r '
    [paths(scalars) as $p |
     select(($p | tostring | test("amdgpu")) and ($p[-1] == "mem")) |
     getpath($p)] |
    select(length > 0) |
    .[0] |
    select(. != null and . > 0 and . < 200)
  ' 2>/dev/null | head -n1 || echo "")"
  
  # Extract power (PPT)
  power="$(printf '%s' "$sensors_json" | jq -r '
    [paths(scalars) as $p |
     select(($p | tostring | test("amdgpu")) and (($p[-1] == "PPT" or $p[-1] == "power1_average"))) |
     getpath($p)] |
    select(length > 0) |
    .[0] |
    select(. != null and . > 0)
  ' 2>/dev/null | head -n1 || echo "")"
  
  # Extract GPU fan
  fan="$(printf '%s' "$sensors_json" | jq -r '
    [paths(scalars) as $p |
     select(($p | tostring | test("amdgpu")) and (($p[-1] | test("fan[0-9]+_input")))) |
     getpath($p)] |
    select(length > 0) |
    .[0] |
    select(. != null and . > 0)
  ' 2>/dev/null | head -n1 || echo "")"
  
  # Fallback: try old sensors text parsing
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
  
  # Convert empty strings to null
  [[ -z "$edge" ]] && edge="null"
  [[ -z "$hotspot" ]] && hotspot="null"
  [[ -z "$mem" ]] && mem="null"
  [[ -z "$power" ]] && power="null"
  [[ -z "$fan" ]] && fan="null"
  
  echo "${edge}|${hotspot}|${mem}|${power}|${fan}"
}

read_nvidia_gpu_sensors() {
  if ! have nvidia-smi; then
    echo "null|null|null|null|null"
    return
  fi
  
  # Query GPU temperature, memory temperature (if available), fan speed, and power
  local nvidia_output
  nvidia_output="$(nvidia-smi --query-gpu=temperature.gpu,temperature.memory,fan.speed,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n1 || echo "")"
  
  local edge="null"
  local hotspot="null"  # NVIDIA doesn't expose hotspot separately
  local vram="null"
  local fan="null"
  local power="null"
  
  if [[ -n "$nvidia_output" ]]; then
    edge="$(echo "$nvidia_output" | cut -d',' -f1 | xargs || echo "")"
    vram="$(echo "$nvidia_output" | cut -d',' -f2 | xargs || echo "")"
    fan="$(echo "$nvidia_output" | cut -d',' -f3 | xargs || echo "")"
    power="$(echo "$nvidia_output" | cut -d',' -f4 | xargs || echo "")"
    
    # Remove % from fan speed
    if [[ -n "$fan" && "$fan" != "null" ]]; then
      fan="$(echo "$fan" | sed 's/%//' | xargs || echo "")"
    fi
    
    # Handle "N/A" for memory temperature (older GPUs don't have VRAM sensors)
    if [[ "$vram" == "N/A" || "$vram" == "n/a" || -z "$vram" ]]; then
      vram="null"
    fi
    
    # Convert empty strings to null
    [[ -z "$edge" ]] && edge="null"
    [[ -z "$vram" ]] && vram="null"
    [[ -z "$fan" ]] && fan="null"
    [[ -z "$power" ]] && power="null"
  fi
  
  # Return format: edge|hotspot|vram|power|fan (matches read_amd_gpu_sensors format)
  echo "${edge}|${hotspot}|${vram}|${power}|${fan}"
}

get_gpu_power_limit() {
  local gpu_vendor="$1"
  local power_limit="null"
  
  if [[ "$gpu_vendor" == "nvidia" ]]; then
    if have nvidia-smi; then
      power_limit="$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | head -n1 | xargs || echo "")"
      # Remove "W" suffix if present
      power_limit="$(echo "$power_limit" | sed 's/W//' | xargs || echo "")"
    fi
  elif [[ "$gpu_vendor" == "amd" ]]; then
    # Try to read from sensors -j (PPT)
    local sensors_json
    sensors_json="$(sensors -j 2>/dev/null || echo '{}')"
    power_limit="$(printf '%s' "$sensors_json" | jq -r '
      [paths(scalars) as $p |
       select(($p | tostring | test("amdgpu")) and ($p[-1] == "PPT")) |
       getpath($p)] |
      select(length > 0) |
      .[0] |
      select(. != null and . > 0)
    ' 2>/dev/null | head -n1 || echo "")"
  fi
  
  [[ -z "$power_limit" ]] && power_limit="null"
  echo "$power_limit"
}

read_gpu_sensors() {
  local gpu_vendor="$1"
  
  if [[ "$gpu_vendor" == "amd" ]]; then
    read_amd_gpu_sensors
  elif [[ "$gpu_vendor" == "nvidia" ]]; then
    read_nvidia_gpu_sensors
  else
    echo "null|null|null|null|null"
  fi
}

monitor_gpu_safety() {
  local test_name="$1"
  local duration="$2"
  local stress_pid="$3"
  local gpu_vendor="$4"
  
  local vram_critical=90.0
  local fan_critical=20.0
  local fan_delay=5
  local power_limit_mult=1.10
  local hotspot_critical=100.0
  local hotspot_warning=95.0
  local vram_warning=85.0
  
  local fan_fail_start=0
  local hotspot_over_start=0
  local last_warning_time=0
  
  # Status file for communication with main process
  local status_file="${LOGDIR}/.gpu_safety_status_${test_name}"
  rm -f "$status_file"
  
  # Get power limit
  local power_limit
  power_limit="$(get_gpu_power_limit "$gpu_vendor")"
  
  green "  GPU safety monitoring active"
  echo
  
  local start_time
  start_time="$(date +%s)"
  local end_time
  end_time=$((start_time + duration))
  
  while [[ $(date +%s) -lt $end_time ]]; do
    if ! kill -0 "$stress_pid" 2>/dev/null; then
      break
    fi
    
    # Read current GPU sensors
    local gpu_sensors
    gpu_sensors="$(read_gpu_sensors "$gpu_vendor")"
    IFS='|' read -r edge hotspot vram power fan <<< "$gpu_sensors"
    
    local current_time
    current_time="$(date +%s)"
    
    # Immediate stops (no delay)
    # VRAM > 90°C
    if [[ "$vram" != "null" && -n "$vram" ]] && (( $(echo "$vram > $vram_critical" | bc -l 2>/dev/null || echo 0) )); then
      export HELLFIRE_GPU_SAFETY_FAILED=1
      export HELLFIRE_GPU_SAFETY_REASON="VRAM temperature ${vram}°C exceeded ${vram_critical}°C"
      # Write to status file for main process
      echo "FAILED" > "$status_file"
      echo "${HELLFIRE_GPU_SAFETY_REASON}" > "${status_file}.reason"
      red "  🚨 IMMEDIATE STOP: VRAM ${vram}°C > ${vram_critical}°C"
      kill "$stress_pid" 2>/dev/null || true
      break
    fi
    
    # Fan check: only fail if GPU is warm AND fan is low
    if [[ "$fan" != "null" && -n "$fan" ]] && [[ "$edge" != "null" && -n "$edge" ]] && [[ "$hotspot" != "null" && -n "$hotspot" ]]; then
      local fan_num
      fan_num="$(echo "$fan" | awk '{print $1+0}')"
      local edge_num
      edge_num="$(echo "$edge" | awk '{print $1+0}')"
      local hotspot_num
      hotspot_num="$(echo "$hotspot" | awk '{print $1+0}')"
      
      if (( $(echo "$edge_num >= 65 || $hotspot_num >= 70" | bc -l 2>/dev/null || echo 0) )); then
        if (( $(echo "$fan_num < $fan_critical" | bc -l 2>/dev/null || echo 0) )); then
          if [[ $fan_fail_start -eq 0 ]]; then
            fan_fail_start=$current_time
          fi
          
          local fan_fail_duration
          fan_fail_duration=$((current_time - fan_fail_start))
          
          if [[ $fan_fail_duration -ge $fan_delay ]]; then
            export HELLFIRE_GPU_SAFETY_FAILED=1
            export HELLFIRE_GPU_SAFETY_REASON="GPU fan speed ${fan}% < ${fan_critical}% while GPU was above safe temperature - Edge: ${edge}°C, Hotspot: ${hotspot}°C"
            # Write to status file for main process
            echo "FAILED" > "$status_file"
            echo "${HELLFIRE_GPU_SAFETY_REASON}" > "${status_file}.reason"
            red "  🚨 DELAYED STOP: GPU fan speed ${fan}% < ${fan_critical}% for ${fan_fail_duration}s while GPU was warm"
            kill "$stress_pid" 2>/dev/null || true
            break
          fi
        else
          fan_fail_start=0
        fi
      else
        fan_fail_start=0
      fi
    fi
    
    # Power > 110% of limit
    if [[ "$power" != "null" && -n "$power" && "$power_limit" != "null" && -n "$power_limit" ]]; then
      local power_limit_max
      power_limit_max="$(echo "$power_limit $power_limit_mult" | awk '{printf "%.1f", $1 * $2}')"
      if (( $(echo "$power > $power_limit_max" | bc -l 2>/dev/null || echo 0) )); then
        export HELLFIRE_GPU_SAFETY_FAILED=1
        export HELLFIRE_GPU_SAFETY_REASON="GPU power draw ${power}W exceeded ${power_limit_max}W (${power_limit_mult}x limit)"
        # Write to status file for main process
        echo "FAILED" > "$status_file"
        echo "${HELLFIRE_GPU_SAFETY_REASON}" > "${status_file}.reason"
        red "  🚨 IMMEDIATE STOP: GPU power ${power}W > ${power_limit_max}W"
        kill "$stress_pid" 2>/dev/null || true
        break
      fi
    fi
    
    # Delayed stop: Hotspot > 100°C for 2 seconds
    if [[ "$hotspot" != "null" && -n "$hotspot" ]]; then
      if (( $(echo "$hotspot > $hotspot_critical" | bc -l 2>/dev/null || echo 0) )); then
        if [[ $hotspot_over_start -eq 0 ]]; then
          hotspot_over_start=$current_time
        fi
        
        local hotspot_duration
        hotspot_duration=$((current_time - hotspot_over_start))
        
          if [[ $hotspot_duration -ge 2 ]]; then
            export HELLFIRE_GPU_SAFETY_FAILED=1
            export HELLFIRE_GPU_SAFETY_REASON="Hotspot temperature exceeded ${hotspot_critical}°C for ${hotspot_duration}s - current: ${hotspot}°C"
            # Write to status file for main process
            echo "FAILED" > "$status_file"
            echo "${HELLFIRE_GPU_SAFETY_REASON}" > "${status_file}.reason"
            red "  🚨 DELAYED STOP: Hotspot ${hotspot}°C > ${hotspot_critical}°C for ${hotspot_duration}s"
            kill "$stress_pid" 2>/dev/null || true
            break
          fi
      else
        hotspot_over_start=0
      fi
    fi
    
    # Warnings (no stop, just output)
    if [[ $((current_time - last_warning_time)) -ge 5 ]]; then
      if [[ "$hotspot" != "null" && -n "$hotspot" ]] && (( $(echo "$hotspot > $hotspot_warning" | bc -l 2>/dev/null || echo 0) )); then
        yellow "  ⚠️  WARNING: Hotspot temperature ${hotspot}°C > ${hotspot_warning}°C"
        last_warning_time=$current_time
      fi
      if [[ "$vram" != "null" && -n "$vram" ]] && (( $(echo "$vram > $vram_warning" | bc -l 2>/dev/null || echo 0) )); then
        yellow "  ⚠️  WARNING: VRAM temperature ${vram}°C > ${vram_warning}°C"
        last_warning_time=$current_time
      fi
    fi
    
    sleep 1
  done
}

# ============================================================================
# Pre-test Checks
# ============================================================================

check_temps_before_start() {
  local cpu_temp
  cpu_temp="$(read_cpu_temp)"
  
  if [[ "$cpu_temp" != "null" ]]; then
    if (( $(echo "$cpu_temp > 70" | bc -l 2>/dev/null || echo 0) )); then
      yellow "  Warning: CPU temperature is already ${cpu_temp}°C"
      yellow "  Consider waiting for system to cool down before starting test"
      echo
    fi
  fi
}

# ============================================================================
# Cleanup and Trap Functions
# ============================================================================

cleanup_hellfire() {
  # Prevent multiple cleanup runs
  if [[ -n "${HELLFIRE_CLEANUP_DONE:-}" ]]; then
    return 0
  fi
  export HELLFIRE_CLEANUP_DONE=1
  
  local signal="$1"
  
  # Set abort status
  if [[ "$signal" == "INT" || "$signal" == "TERM" ]]; then
    export HELLFIRE_USER_ABORTED=1
    if [[ -n "${HELLFIRE_START_TIME:-}" ]]; then
      local current_time
      current_time="$(date +%s)"
      local elapsed
      elapsed=$((current_time - HELLFIRE_START_TIME))
      export HELLFIRE_ABORT_TIME="$elapsed"
    fi
    
    # Print funny abort comment based on test type
    echo
    local test_name="${HELLFIRE_TEST_NAME:-unknown}"
    if [[ "$test_name" == "ram" ]]; then
      yellow "  Abort acknowledged. RAM integrity preserved."
    elif [[ "$test_name" == "gpu" ]]; then
      yellow "  Hellfire run aborted: no guts today — no RMA tomorrow."
      yellow "  Your GPU thanks you."
    elif [[ "$test_name" == "cooler" ]]; then
      yellow "  Bailed out? No courage today?"
      echo
      yellow "  Probably smart — RMA isn't a subscription service."
      echo
      yellow "  Understandable: Hellfire Cooler has ended careers!"
      echo
      yellow "  Your local hardware dealer shakes its head in quiet disappointment..."
    else
      # CPU or unknown
      yellow "  Hellfire run aborted: no guts today — no RMA tomorrow."
      yellow "  Your CPU thanks you."
    fi
    echo
    
    # Silent cleanup for user aborts (no output)
    # Stop sensor monitor
    if [[ -n "${HELLFIRE_TEST_NAME:-}" ]]; then
      stop_sensor_monitor "${HELLFIRE_TEST_NAME}" >/dev/null 2>&1 || true
    fi
    
    # Kill stress processes
    if [[ -n "${STRESS_PID:-}" ]]; then
      kill "$STRESS_PID" 2>/dev/null || true
      wait "$STRESS_PID" 2>/dev/null || true
    fi
    
    # For GPU tests: also kill gputest/furmark processes explicitly
    if [[ "$test_name" == "gpu" ]]; then
      # Kill gputest processes
      pkill -f "gputest" 2>/dev/null || true
      pkill -f "furmark" 2>/dev/null || true
      # Wait a bit and verify they're really dead
      sleep 0.5
      if pgrep -f "gputest" >/dev/null 2>&1; then
        pkill -9 -f "gputest" 2>/dev/null || true
      fi
      if pgrep -f "furmark" >/dev/null 2>&1; then
        pkill -9 -f "furmark" 2>/dev/null || true
      fi
    fi
    
    # Exit immediately after user abort - no summary, no cleanup messages
    exit 0
  fi
  
  # Normal cleanup (EXIT signal)
  yellow "  Cleaning up..."
  
  # Stop sensor monitor
  if [[ -n "${HELLFIRE_TEST_NAME:-}" ]]; then
    stop_sensor_monitor "${HELLFIRE_TEST_NAME}"
  fi
  
  # Kill stress processes
  if [[ -n "${STRESS_PID:-}" ]]; then
    kill "$STRESS_PID" 2>/dev/null || true
    wait "$STRESS_PID" 2>/dev/null || true
  fi
  
  # For GPU/cooler tests: also kill gputest/furmark processes explicitly
  local test_name="${HELLFIRE_TEST_NAME:-unknown}"
  if [[ "$test_name" == "gpu" || "$test_name" == "cooler" ]]; then
    # Kill gputest processes
    pkill -f "gputest" 2>/dev/null || true
    pkill -f "furmark" 2>/dev/null || true
    # Wait a bit and verify they're really dead
    sleep 0.5
    if pgrep -f "gputest" >/dev/null 2>&1; then
      pkill -9 -f "gputest" 2>/dev/null || true
    fi
    if pgrep -f "furmark" >/dev/null 2>&1; then
      pkill -9 -f "furmark" 2>/dev/null || true
    fi
  fi
  
  # For cooler tests: also kill all stress-ng processes
  if [[ "$test_name" == "cooler" ]]; then
    killall stress-ng 2>/dev/null || true
  fi
  
  echo
  echo "Cleanup complete"
}

setup_cleanup_trap() {
  export HELLFIRE_START_TIME="$(date +%s)"
  trap 'cleanup_hellfire INT' INT
  trap 'cleanup_hellfire TERM' TERM
  trap 'cleanup_hellfire EXIT' EXIT
}

# ============================================================================
# Countdown Function
# ============================================================================

countdown() {
  local seconds="${1:-5}"
  yellow "  Starting in $seconds seconds..."
  for ((i=seconds; i>0; i--)); do
    printf "\r  %d... " "$i"
    sleep 1
  done
  printf "\r  Starting now!    \n"
  echo
}

# ============================================================================
# Sensor Log Parsing
# ============================================================================

parse_sensor_log() {
  local log_file="$1"
  
  if [[ ! -f "$log_file" ]]; then
    return 1
  fi
  
  local cpu_temps
  cpu_temps="$(jq -r '.cpu_temp_c // empty' "$log_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' || true)"
  
  local gpu_temps
  gpu_temps="$(jq -r '.gpu_temp_c // empty' "$log_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' || true)"
  
  local gpu_hotspot
  gpu_hotspot="$(jq -r '.gpu_hotspot_c // empty' "$log_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' || true)"
  
  local gpu_vram
  gpu_vram="$(jq -r '.gpu_memtemp_c // empty' "$log_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' || true)"
  
  local gpu_power
  gpu_power="$(jq -r '.gpu_power_w // empty' "$log_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' || true)"
  
  local gpu_fan
  gpu_fan="$(jq -r '.gpu_fan_rpm // empty' "$log_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' || true)"
  
  local nvme_temp
  nvme_temp="$(jq -r '.nvme_temp_c // empty' "$log_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' || true)"
  
  local cpu_power
  cpu_power="$(jq -r '.cpu_pkg_power_w // empty' "$log_file" 2>/dev/null | grep -v '^null$' | grep -v '^$' || true)"
  
  # Calculate statistics for CPU
  if [[ -n "$cpu_temps" ]]; then
    local cpu_min cpu_avg cpu_max cpu_count
    cpu_min="$(echo "$cpu_temps" | awk 'BEGIN {min=999} {if($1<min) min=$1} END {print min}')"
    cpu_max="$(echo "$cpu_temps" | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')"
    cpu_avg="$(echo "$cpu_temps" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')"
    cpu_count="$(echo "$cpu_temps" | wc -l)"
    
    echo "CPU_TEMP_MIN=$cpu_min"
    echo "CPU_TEMP_AVG=$cpu_avg"
    echo "CPU_TEMP_MAX=$cpu_max"
    echo "CPU_TEMP_COUNT=$cpu_count"
  fi
  
  # Calculate statistics for GPU edge
  if [[ -n "$gpu_temps" ]]; then
    local gpu_min gpu_avg gpu_max gpu_count
    gpu_min="$(echo "$gpu_temps" | awk 'BEGIN {min=999} {if($1<min) min=$1} END {print min}')"
    gpu_max="$(echo "$gpu_temps" | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')"
    gpu_avg="$(echo "$gpu_temps" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')"
    gpu_count="$(echo "$gpu_temps" | wc -l)"
    
    echo "GPU_TEMP_MIN=$gpu_min"
    echo "GPU_TEMP_AVG=$gpu_avg"
    echo "GPU_TEMP_MAX=$gpu_max"
    echo "GPU_TEMP_COUNT=$gpu_count"
  fi
  
  # Calculate statistics for GPU hotspot
  if [[ -n "$gpu_hotspot" ]]; then
    local hotspot_min hotspot_avg hotspot_max hotspot_count
    hotspot_min="$(echo "$gpu_hotspot" | awk 'BEGIN {min=999} {if($1<min) min=$1} END {print min}')"
    hotspot_max="$(echo "$gpu_hotspot" | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')"
    hotspot_avg="$(echo "$gpu_hotspot" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')"
    hotspot_count="$(echo "$gpu_hotspot" | wc -l)"
    
    echo "GPU_HOTSPOT_MIN=$hotspot_min"
    echo "GPU_HOTSPOT_AVG=$hotspot_avg"
    echo "GPU_HOTSPOT_MAX=$hotspot_max"
    echo "GPU_HOTSPOT_COUNT=$hotspot_count"
  fi
  
  # Calculate statistics for GPU VRAM
  if [[ -n "$gpu_vram" ]]; then
    local vram_min vram_avg vram_max vram_count
    vram_min="$(echo "$gpu_vram" | awk 'BEGIN {min=999} {if($1<min) min=$1} END {print min}')"
    vram_max="$(echo "$gpu_vram" | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')"
    vram_avg="$(echo "$gpu_vram" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')"
    vram_count="$(echo "$gpu_vram" | wc -l)"
    
    echo "GPU_VRAM_MIN=$vram_min"
    echo "GPU_VRAM_AVG=$vram_avg"
    echo "GPU_VRAM_MAX=$vram_max"
    echo "GPU_VRAM_COUNT=$vram_count"
  fi
  
  # Calculate statistics for GPU power
  if [[ -n "$gpu_power" ]]; then
    local power_min power_avg power_max power_count
    power_min="$(echo "$gpu_power" | awk 'BEGIN {min=999} {if($1<min) min=$1} END {print min}')"
    power_max="$(echo "$gpu_power" | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')"
    power_avg="$(echo "$gpu_power" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')"
    power_count="$(echo "$gpu_power" | wc -l)"
    
    echo "GPU_POWER_MIN=$power_min"
    echo "GPU_POWER_AVG=$power_avg"
    echo "GPU_POWER_MAX=$power_max"
    echo "GPU_POWER_COUNT=$power_count"
  fi
  
  # Calculate statistics for GPU fan
  if [[ -n "$gpu_fan" ]]; then
    local fan_min fan_avg fan_max fan_count
    fan_min="$(echo "$gpu_fan" | awk 'BEGIN {min=999} {if($1<min) min=$1} END {print min}')"
    fan_max="$(echo "$gpu_fan" | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')"
    fan_avg="$(echo "$gpu_fan" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')"
    fan_count="$(echo "$gpu_fan" | wc -l)"
    
    echo "GPU_FAN_MIN=$fan_min"
    echo "GPU_FAN_AVG=$fan_avg"
    echo "GPU_FAN_MAX=$fan_max"
    echo "GPU_FAN_COUNT=$fan_count"
  fi
  
  # Calculate statistics for NVMe temperature
  if [[ -n "$nvme_temp" ]]; then
    local nvme_min nvme_avg nvme_max nvme_count
    nvme_min="$(echo "$nvme_temp" | awk 'BEGIN {min=999} {if($1<min) min=$1} END {print min}')"
    nvme_max="$(echo "$nvme_temp" | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')"
    nvme_avg="$(echo "$nvme_temp" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')"
    nvme_count="$(echo "$nvme_temp" | wc -l)"
    
    echo "NVME_TEMP_MIN=$nvme_min"
    echo "NVME_TEMP_AVG=$nvme_avg"
    echo "NVME_TEMP_MAX=$nvme_max"
    echo "NVME_TEMP_COUNT=$nvme_count"
  fi
  
  # Calculate statistics for CPU power
  if [[ -n "$cpu_power" ]]; then
    local cpu_power_min cpu_power_avg cpu_power_max cpu_power_count
    cpu_power_min="$(echo "$cpu_power" | awk 'BEGIN {min=999} {if($1<min) min=$1} END {print min}')"
    cpu_power_max="$(echo "$cpu_power" | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')"
    cpu_power_avg="$(echo "$cpu_power" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count; else print "0"}')"
    cpu_power_count="$(echo "$cpu_power" | wc -l)"
    
    echo "CPU_PKG_POWER_MIN=$cpu_power_min"
    echo "CPU_PKG_POWER_AVG=$cpu_power_avg"
    echo "CPU_PKG_POWER_MAX=$cpu_power_max"
    echo "CPU_PKG_POWER_COUNT=$cpu_power_count"
  fi
}

# ============================================================================
# Thermal Status Functions
# ============================================================================

get_thermal_status() {
  local max_temp="$1"
  local limit="$2"
  local was_aborted="$3"
  local component="${4:-CPU}"
  
  if [[ "$max_temp" == "null" || -z "$max_temp" ]]; then
    echo "UNKNOWN"
    return
  fi
  
  if [[ "$was_aborted" == "1" ]]; then
    echo "INSUFFICIENT"
    return
  fi
  
  # Compare as floating point
  if [[ "$component" == "RAM" ]]; then
    if (( $(echo "$max_temp < 65" | bc -l 2>/dev/null || echo 0) )); then
      echo "EXCELLENT"
    elif (( $(echo "$max_temp < 75" | bc -l 2>/dev/null || echo 0) )); then
      echo "OK"
    elif (( $(echo "$max_temp < 85" | bc -l 2>/dev/null || echo 0) )); then
      echo "WARM"
    else
      echo "CRITICAL"
    fi
  else
    # CPU/GPU thresholds
    if (( $(echo "$max_temp < 70" | bc -l 2>/dev/null || echo 0) )); then
      echo "EXCELLENT"
    elif (( $(echo "$max_temp < 85" | bc -l 2>/dev/null || echo 0) )); then
      echo "OK"
    elif (( $(echo "$max_temp < 95" | bc -l 2>/dev/null || echo 0) )); then
      echo "WARM"
    else
      echo "CRITICAL"
    fi
  fi
}

print_thermal_status() {
  local status="$1"
  local max_temp="$2"
  local limit="$3"
  local test_status="${4:-PASS}"
  
  if [[ "$test_status" == "FAILED" ]]; then
    return
  fi
  
  case "$status" in
    EXCELLENT)
      green "  Overall Thermal Status: ✅ COOLING EXCELLENT"
      ;;
    OK)
      green "  Overall Thermal Status: ✅ COOLING OK"
      ;;
    WARM)
      yellow "  Overall Thermal Status: ⚠️ COOLING WARM"
      ;;
    CRITICAL)
      red "  Overall Thermal Status: 🚨 COOLING CRITICAL"
      ;;
    INSUFFICIENT)
      red "  Overall Thermal Status: ❌ COOLING INSUFFICIENT - or user abort"
      ;;
    *)
      yellow "  Overall Thermal Status: ? UNKNOWN – temperature data not available."
      ;;
  esac
}

print_ram_thermal_status() {
  local status="$1"
  local max_temp="$2"
  local limit="$3"
  
  case "$status" in
    EXCELLENT)
      green "  RAM Thermal Status:      🟩 EXCELLENT"
      ;;
    OK)
      green "  RAM Thermal Status:      🟩 OK"
      ;;
    WARM)
      yellow "  RAM Thermal Status:      🟨 WARM"
      ;;
    CRITICAL)
      red "  RAM Thermal Status:      🟥 CRITICAL"
      ;;
    *)
      yellow "  RAM Thermal Status:      ? UNKNOWN"
      ;;
  esac
}

get_gpu_thermal_status() {
  local max_hotspot="$1"
  local max_vram="$2"
  local was_aborted="$3"
  
  if [[ "$max_hotspot" == "null" || -z "$max_hotspot" ]]; then
    echo "UNKNOWN"
    return
  fi
  
  if [[ "$was_aborted" == "1" ]]; then
    echo "CRITICAL"
    return
  fi
  
  local hotspot_num
  hotspot_num="$(echo "$max_hotspot" | awk '{print $1+0}')"
  local vram_num
  vram_num="$(echo "$max_vram" | awk '{print $1+0}')"
  
  # EXCELLENT: Hotspot < 80°C AND VRAM < 70°C
  if (( $(echo "$hotspot_num < 80 && ($vram_num == 0 || $vram_num < 70)" | bc -l 2>/dev/null || echo 0) )); then
    echo "EXCELLENT"
  # OK: Hotspot 80–90°C AND VRAM < 85°C
  elif (( $(echo "$hotspot_num < 90 && ($vram_num == 0 || $vram_num < 85)" | bc -l 2>/dev/null || echo 0) )); then
    echo "OK"
  # WARM: Hotspot 90–95°C OR VRAM 85–90°C
  elif (( $(echo "$hotspot_num < 95 && ($vram_num == 0 || $vram_num < 90)" | bc -l 2>/dev/null || echo 0) )); then
    echo "WARM"
  # CRITICAL: Hotspot ≥ 95°C OR VRAM ≥ 90°C
  else
    echo "CRITICAL"
  fi
}

print_gpu_thermal_status() {
  local status="$1"
  local max_hotspot="$2"
  local max_vram="$3"
  
  case "$status" in
    EXCELLENT)
      green "  GPU Thermal Status:      ✅ EXCELLENT"
      ;;
    OK)
      green "  GPU Thermal Status:      ✅ OK"
      ;;
    WARM)
      yellow "  GPU Thermal Status:      ⚠️ WARM"
      ;;
    CRITICAL)
      red "  GPU Thermal Status:      🚨 CRITICAL"
      ;;
    *)
      yellow "  GPU Thermal Status:      ? UNKNOWN"
      ;;
  esac
}

# ============================================================================
# GHUL Rating Functions
# ============================================================================

get_ghul_rating() {
  local max_temp="$1"
  local was_aborted="$2"
  local test_status="${3:-PASS}"
  local component="${4:-CPU}"
  
  if [[ "$test_status" == "FAILED" || "$was_aborted" == "1" ]]; then
    echo "ABORTED"
    return
  fi
  
  if [[ "$max_temp" == "null" || -z "$max_temp" ]]; then
    echo "UNKNOWN"
    return
  fi
  
  # Compare as floating point (different thresholds for RAM)
  if [[ "$component" == "RAM" ]]; then
    if (( $(echo "$max_temp < 65" | bc -l 2>/dev/null || echo 0) )); then
      echo "EXCELLENT"
    elif (( $(echo "$max_temp < 75" | bc -l 2>/dev/null || echo 0) )); then
      echo "OK"
    elif (( $(echo "$max_temp < 85" | bc -l 2>/dev/null || echo 0) )); then
      echo "WARM"
    else
      echo "CRITICAL"
    fi
  else
    # CPU thresholds
    if (( $(echo "$max_temp < 65" | bc -l 2>/dev/null || echo 0) )); then
      echo "EXCELLENT"
    elif (( $(echo "$max_temp < 75" | bc -l 2>/dev/null || echo 0) )); then
      echo "OK"
    elif (( $(echo "$max_temp < 90" | bc -l 2>/dev/null || echo 0) )); then
      echo "WARM"
    else
      echo "CRITICAL"
    fi
  fi
}

get_gpu_ghul_rating() {
  local max_hotspot="$1"
  local was_aborted="$2"
  local test_status="${3:-PASS}"
  
  if [[ "$test_status" == "FAILED" || "$was_aborted" == "1" ]]; then
    echo "ABORTED"
    return
  fi
  
  if [[ "$max_hotspot" == "null" || -z "$max_hotspot" ]]; then
    echo "UNKNOWN"
    return
  fi
  
  local hotspot_num
  hotspot_num="$(echo "$max_hotspot" | awk '{print $1+0}')"
  
  # EXCELLENT: Hotspot < 80°C
  if (( $(echo "$hotspot_num < 80" | bc -l 2>/dev/null || echo 0) )); then
    echo "EXCELLENT"
  # OK: 80–90°C
  elif (( $(echo "$hotspot_num < 90" | bc -l 2>/dev/null || echo 0) )); then
    echo "OK"
  # WARM: 90–95°C
  elif (( $(echo "$hotspot_num < 95" | bc -l 2>/dev/null || echo 0) )); then
    echo "WARM"
  # CRITICAL: >= 95°C
  else
    echo "CRITICAL"
  fi
}

print_ghul_rating() {
  local rating="$1"
  local max_temp="$2"
  local test_status="${3:-PASS}"
  local component="${4:-CPU}"
  
  echo "  🥇 GHUL Hellfire Cooling Rating v1.0"
  echo
  
  case "$rating" in
    EXCELLENT)
      if [[ "$component" == "GPU" ]]; then
        green "  EXCELLENT"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  max Temp < 65°C - your max: ${max_temp}°C"
        else
          echo "  max Temp < 65°C"
        fi
        echo "  This is an illegal level of cooling performance. Your cooler laughs at Hellfire. Your RIG is born to overclock."
      elif [[ "$component" == "RAM" ]]; then
        green "  EXCELLENT"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  max Temp < 65°C - your max: ${max_temp}°C"
        else
          echo "  max Temp < 65°C"
        fi
        echo "  Your DIMMs are chilling. Maximum stability achieved. Maybe you should consider a frequency boost and higher voltage?"
      else
        green "  EXCELLENT"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  max Temp < 65°C - your max: ${max_temp}°C"
        else
          echo "  max Temp < 65°C"
        fi
        echo "  This cooling performance is sick. You were born to overclock."
      fi
      ;;
    OK)
      if [[ "$component" == "GPU" ]]; then
        green "  OK"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  65–75°C - your max: ${max_temp}°C"
        else
          echo "  65–75°C"
        fi
        echo "  This cooler can handle raids, boss fights and your bad decisions relaxed."
      elif [[ "$component" == "RAM" ]]; then
        green "  OK"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  65–75°C - your max: ${max_temp}°C"
        else
          echo "  65–75°C"
        fi
        echo "  Not cold, not hot — just right for battle."
      else
        green "  OK"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  65–75°C - your max: ${max_temp}°C"
        else
          echo "  65–75°C"
        fi
        echo "  Solid. Gaming workout 24h daily, no sweat."
      fi
      ;;
    WARM)
      if [[ "$component" == "GPU" ]]; then
        yellow "  WARM"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  75–90°C - your max: ${max_temp}°C"
        else
          echo "  75–90°C"
        fi
        echo "  Your GPU is preheating the room. Might be time for a cleaning?"
      elif [[ "$component" == "RAM" ]]; then
        yellow "  WARM"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  75–85°C - your max: ${max_temp}°C"
        else
          echo "  75–85°C"
        fi
        echo "  This is the 'I can continue, but I won't like it' zone:"
        echo "     Thermal paste won't fix this - airflow might..."
      else
        yellow "  WARM"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  75–90°C - your max: ${max_temp}°C"
        else
          echo "  75–90°C"
        fi
        echo "  You are hot: Check airflow, paste, dust, fan curves."
      fi
      ;;
    CRITICAL)
      if [[ "$component" == "GPU" ]]; then
        red "  CRITICAL"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  ≥90°C oder Safety-Stop - your max: ${max_temp}°C"
        else
          echo "  ≥90°C oder Safety-Stop"
        fi
        echo "  Your GPU is forging a new planet core. Stop the run... NOW!"
      elif [[ "$component" == "RAM" ]]; then
        red "  CRITICAL"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  ≥85°C - your max: ${max_temp}°C"
        else
          echo "  ≥85°C"
        fi
        echo "  Memory meltdown detected. These bits are going places they shouldn't."
        echo "     The GHUL Hellfire has revealed weaknesses in your memory… and your cooling."
      else
        red "  CRITICAL"
        if [[ -n "$max_temp" && "$max_temp" != "null" ]]; then
          echo "  ≥90°C oder Safety-Stop - your max: ${max_temp}°C"
        else
          echo "  ≥90°C oder Safety-Stop"
        fi
        echo "  Cooling insufficient for Hellfire. This rig will die sooner rather than later."
      fi
      ;;
    ABORTED)
      yellow "  ABORTED"
      if [[ "$component" == "RAM" ]]; then
        echo "  Abort acknowledged. RAM integrity preserved."
      else
        echo "  Hellfire run aborted: no guts today — no RMA tomorrow."
        echo "  Your CPU thanks you."
      fi
      ;;
    *)
      yellow "  UNKNOWN"
      echo "  Temperature data not available."
      ;;
  esac
  
  # Bonus flavor text for RAM (if test passed)
  if [[ "$component" == "RAM" && "$test_status" == "PASS" && "$rating" != "ABORTED" ]]; then
    echo
    green "  Bonus Flavor:"
    echo "  0 errors detected — your RAM has a PhD in stability."
    echo "  Corrected 0, uncorrectable 0 - your DIMMs meditate under pressure."
    echo "  Memory controller behaved impeccably."
    echo "  Unlike most humans."
    echo
    green "  Temperature OK, errors zero — proceed to GPU sacrifice"
  fi
  
  echo
}

print_gpu_ghul_rating() {
  local rating="$1"
  local max_hotspot="$2"
  local max_vram="$3"
  local test_status="${4:-PASS}"
  local show_header="${5:-1}"  # Default: show header
  
  if [[ "$show_header" == "1" ]]; then
    echo "  🥇 GHUL Hellfire GPU Rating v1.0"
    echo
  fi
  
  case "$rating" in
    EXCELLENT)
      green "  EXCELLENT"
      if [[ -n "$max_hotspot" && "$max_hotspot" != "null" ]]; then
        echo "  Hotspot Band: < 80°C - your max hotspot: ${max_hotspot}°C"
      else
        echo "  Hotspot Band: < 80°C"
      fi
      if [[ -n "$max_vram" && "$max_vram" != "null" ]]; then
        echo "  VRAM Status: ${max_vram}°C"
      else
        echo "  VRAM Status: N/A"
      fi
      echo "  This is an illegal level of cooling performance. Your cooler laughs at Hellfire. Your RIG is born to overclock."
      ;;
    OK)
      green "  OK"
      if [[ -n "$max_hotspot" && "$max_hotspot" != "null" ]]; then
        echo "  Hotspot Band: 80–90°C - your max hotspot: ${max_hotspot}°C"
      else
        echo "  Hotspot Band: 80–90°C"
      fi
      if [[ -n "$max_vram" && "$max_vram" != "null" ]]; then
        echo "  VRAM Status: ${max_vram}°C"
      else
        echo "  VRAM Status: N/A"
      fi
      echo "  This cooler can handle raids, boss fights and your bad decisions relaxed."
      echo
      ;;
    WARM)
      yellow "  WARM"
      if [[ -n "$max_hotspot" && "$max_hotspot" != "null" ]]; then
        echo "  Hotspot Band: 90–95°C - your max hotspot: ${max_hotspot}°C"
      else
        echo "  Hotspot Band: 90–95°C"
      fi
      if [[ -n "$max_vram" && "$max_vram" != "null" ]]; then
        echo "  VRAM Status: ${max_vram}°C"
      else
        echo "  VRAM Status: N/A"
      fi
      echo "  Your GPU is preheating the room. Might be time for a cleaning?"
      ;;
    CRITICAL)
      red "  CRITICAL"
      if [[ -n "$max_hotspot" && "$max_hotspot" != "null" ]]; then
        echo "  Hotspot Band: ≥ 95°C - your max hotspot: ${max_hotspot}°C"
      else
        echo "  Hotspot Band: ≥ 95°C"
      fi
      if [[ -n "$max_vram" && "$max_vram" != "null" ]]; then
        echo "  VRAM Status: ${max_vram}°C"
      else
        echo "  VRAM Status: N/A"
      fi
      echo "  Your GPU is forging a new planet core. Stop the run... NOW!"
      ;;
    ABORTED)
      yellow "  ABORTED"
      echo "  Hellfire run aborted: no guts today — no RMA tomorrow."
      echo "  Your GPU thanks you."
      ;;
    *)
      yellow "  UNKNOWN"
      echo "  Temperature data not available."
      ;;
  esac
}

# ============================================================================
# Test Summary Function
# ============================================================================

print_test_summary() {
  local test_name="$1"
  local duration="$2"
  local test_status="${3:-PASS}"
  local abort_reason="${4:-}"
  local sensor_log_pattern="${LOGDIR}/*-${HOST}-${test_name}-sensors.jsonl"
  local cpu_limit=100.0
  local gpu_limit=100.0
  
  # Check if test actually started (sensor log exists)
  local log_file=""
  if ls ${sensor_log_pattern} 2>/dev/null | head -1 | grep -q .; then
    log_file="$(ls -t ${sensor_log_pattern} 2>/dev/null | head -1)"
  fi
  
  # For user aborts: if no sensor log exists, test didn't start - skip summary completely
  if [[ "$test_status" == "ABORTED" ]] && [[ -n "${HELLFIRE_USER_ABORTED:-}" ]] && [[ -z "$log_file" ]]; then
    # Test was aborted before it started - don't show any summary
    return 0
  fi
  
  echo
  green "  Test: $test_name"
  
  # Only show duration if test actually ran (sensor log exists or test ran for more than a few seconds)
  if [[ -n "$log_file" ]] || [[ "${HELLFIRE_ABORT_TIME:-0}" -gt 5 ]]; then
    green "  Duration: $duration seconds"
  fi
  
  # Find sensor log file (if not already found)
  local show_temp_stats=1
  
  # Skip temperature statistics and ratings for user aborts and safety stops
  if [[ "$test_status" == "ABORTED" ]] && [[ -n "${HELLFIRE_USER_ABORTED:-}" ]]; then
    # User abort - skip all temperature statistics and ratings
    show_temp_stats=0
  elif [[ "$test_status" == "FAILED" ]]; then
    # Safety stop - skip temperature statistics and ratings, show only essential info
    show_temp_stats=0
  fi
  
  if [[ $show_temp_stats -eq 1 ]]; then
    if [[ -z "$log_file" ]]; then
      # Try to find sensor log file
      if ls ${sensor_log_pattern} 2>/dev/null | head -1 | grep -q .; then
        log_file="$(ls -t ${sensor_log_pattern} 2>/dev/null | head -1)"
        green "  Sensor log: $log_file"
        echo
      elif [[ "$test_status" == "FAILED" ]] && [[ -n "${HELLFIRE_GPU_SAFETY_FAILED:-}" ]]; then
        yellow "  Sensor log: Not available"
        yellow "  Run aborted by safety guard before logging phase."
        echo
        log_file=""
      fi
    else
      # Log file already found
      green "  Sensor log: $log_file"
      echo
    fi
  fi
  
  if [[ -n "$log_file" ]] && [[ $show_temp_stats -eq 1 ]]; then
    # Parse sensor log and display temperature statistics
    local temp_stats
    temp_stats="$(parse_sensor_log "$log_file")"
    
    if [[ -n "$temp_stats" ]]; then
      # Source the stats as variables
      eval "$temp_stats"
      
      echo "  Temperature Statistics:"
      echo
      
      # CPU temperatures
      if [[ -n "${CPU_TEMP_MIN:-}" ]]; then
        printf '    CPU Temperature:     min=%.1f°C  avg=%.1f°C  max=%.1f°C  - limit: %.0f°C, samples: %d\n' "$CPU_TEMP_MIN" "$CPU_TEMP_AVG" "$CPU_TEMP_MAX" "$cpu_limit" "$CPU_TEMP_COUNT"
      else
        echo "    CPU Temperature:     n/a"
      fi
      
      # GPU edge temperatures
      if [[ -n "${GPU_TEMP_MIN:-}" ]]; then
        printf '    GPU Edge Temperature: min=%.1f°C  avg=%.1f°C  max=%.1f°C  - limit: %.0f°C, samples: %d\n' "$GPU_TEMP_MIN" "$GPU_TEMP_AVG" "$GPU_TEMP_MAX" "$gpu_limit" "$GPU_TEMP_COUNT"
      else
        echo "    GPU Edge Temperature: n/a"
      fi
      
      # GPU hotspot temperatures
      if [[ -n "${GPU_HOTSPOT_MIN:-}" ]]; then
        printf '    GPU Hotspot Temp:     min=%.1f°C  avg=%.1f°C  max=%.1f°C  - limit: %.0f°C, samples: %d\n' "$GPU_HOTSPOT_MIN" "$GPU_HOTSPOT_AVG" "$GPU_HOTSPOT_MAX" "$gpu_limit" "$GPU_HOTSPOT_COUNT"
      else
        echo "    GPU Hotspot Temperature: n/a"
      fi
      
      echo
      
      # Determine component from test name
      local component="CPU"
      if [[ "$test_name" == "ram" ]]; then
        component="RAM"
      elif [[ "$test_name" == "gpu" ]]; then
        component="GPU"
      fi
      
      # GPU-specific output
      if [[ "$component" == "GPU" ]]; then
        local was_aborted=0
        if [[ "$test_status" == "ABORTED" || "$test_status" == "FAILED" ]]; then
          was_aborted=1
        fi
        
        # GPU VRAM temperature display
        if [[ -n "${GPU_VRAM_MIN:-}" ]]; then
          printf '    GPU VRAM Temperature:  min=%.1f°C  avg=%.1f°C  max=%.1f°C  - limit: 90°C, samples: %d\n' "$GPU_VRAM_MIN" "$GPU_VRAM_AVG" "$GPU_VRAM_MAX" "$GPU_VRAM_COUNT"
        else
          echo "    GPU VRAM Temperature:  n/a"
        fi
        
        # GPU Power display
        if [[ -n "${GPU_POWER_MIN:-}" ]]; then
          printf '    GPU Power Draw:        min=%.1fW  avg=%.1fW  max=%.1fW  - samples: %d\n' "$GPU_POWER_MIN" "$GPU_POWER_AVG" "$GPU_POWER_MAX" "$GPU_POWER_COUNT"
        else
          echo "    GPU Power Draw:        n/a"
        fi
        
        # GPU Fan display (AMD = RPM, NVIDIA = %)
        if [[ -n "${GPU_FAN_MIN:-}" ]]; then
          local gpu_vendor_display
          # Use exported GPU vendor if available (from GPU test), otherwise detect
          if [[ -n "${HELLFIRE_GPU_VENDOR:-}" ]]; then
            gpu_vendor_display="${HELLFIRE_GPU_VENDOR}"
          else
            gpu_vendor_display="$(detect_gpu_vendor 2>/dev/null || echo "unknown")"
          fi
          if [[ "$gpu_vendor_display" == "nvidia" ]]; then
            printf '    GPU Fan Speed:         min=%.0f%%  avg=%.0f%%  max=%.0f%%  - samples: %d\n' "$GPU_FAN_MIN" "$GPU_FAN_AVG" "$GPU_FAN_MAX" "$GPU_FAN_COUNT"
          else
            printf '    GPU Fan Speed:         min=%.0f RPM  avg=%.0f RPM  max=%.0f RPM  - samples: %d\n' "$GPU_FAN_MIN" "$GPU_FAN_AVG" "$GPU_FAN_MAX" "$GPU_FAN_COUNT"
          fi
        else
          echo "    GPU Fan Speed:         n/a"
        fi
        
        echo
        
        # Overall Thermal Status
        if [[ "$test_status" != "FAILED" ]] && [[ -n "${CPU_TEMP_MAX:-}" ]]; then
          local thermal_status
          thermal_status="$(get_thermal_status "$CPU_TEMP_MAX" "$cpu_limit" "$was_aborted" "CPU")"
          print_thermal_status "$thermal_status" "$CPU_TEMP_MAX" "$cpu_limit" "$test_status"
        fi
        
        # GPU Thermal Status
        if [[ "$test_status" != "FAILED" ]] && [[ -n "${GPU_HOTSPOT_MAX:-}" ]]; then
          local gpu_thermal_status
          gpu_thermal_status="$(get_gpu_thermal_status "${GPU_HOTSPOT_MAX:-null}" "${GPU_VRAM_MAX:-null}" "$was_aborted")"
          print_gpu_thermal_status "$gpu_thermal_status" "${GPU_HOTSPOT_MAX:-null}" "${GPU_VRAM_MAX:-null}"
        fi
        
        echo
        
        # GHUL Hellfire GPU Rating (only show if not FAILED)
        if [[ "$test_status" != "FAILED" ]]; then
          echo "  🥇 GHUL Hellfire GPU Rating v1.0"
          echo
          
          if [[ "$test_status" == "ABORTED" ]]; then
            # User abort - show ABORTED rating (no header, already printed)
            print_gpu_ghul_rating "ABORTED" "${GPU_HOTSPOT_MAX:-null}" "${GPU_VRAM_MAX:-null}" "$test_status" "0"
          elif [[ -n "${GPU_HOTSPOT_MAX:-}" ]]; then
            local gpu_ghul_rating
            gpu_ghul_rating="$(get_gpu_ghul_rating "${GPU_HOTSPOT_MAX:-null}" "$was_aborted" "$test_status")"
            print_gpu_ghul_rating "$gpu_ghul_rating" "${GPU_HOTSPOT_MAX:-null}" "${GPU_VRAM_MAX:-null}" "$test_status" "0"
          fi
        fi
      else
        # CPU/RAM output
        if [[ "$test_status" == "ABORTED" ]]; then
          # User abort - show ABORTED rating only
          echo
          echo "  🥇 GHUL Hellfire Cooling Rating v1.0"
          echo
          print_ghul_rating "ABORTED" "" "$test_status" "$component"
        elif [[ "$test_status" != "FAILED" ]] && [[ -n "${CPU_TEMP_MAX:-}" ]]; then
          local was_aborted=0
          if [[ "$test_status" == "ABORTED" ]]; then
            was_aborted=1
          fi
          local thermal_status
          thermal_status="$(get_thermal_status "$CPU_TEMP_MAX" "$cpu_limit" "$was_aborted" "CPU")"
          print_thermal_status "$thermal_status" "$CPU_TEMP_MAX" "$cpu_limit" "$test_status"
          
          # RAM Thermal Status (only for RAM tests)
          if [[ "$component" == "RAM" ]]; then
            local ram_thermal_status
            ram_thermal_status="$(get_thermal_status "$CPU_TEMP_MAX" "$cpu_limit" "$was_aborted" "RAM")"
            print_ram_thermal_status "$ram_thermal_status" "$CPU_TEMP_MAX" "$cpu_limit"
          fi
          
          echo
          
          # GHUL Hellfire Cooling Rating (header is printed by print_ghul_rating)
          local ghul_rating
          ghul_rating="$(get_ghul_rating "$CPU_TEMP_MAX" "$was_aborted" "$test_status" "$component")"
          print_ghul_rating "$ghul_rating" "$CPU_TEMP_MAX" "$test_status" "$component"
        elif [[ "$test_status" == "FAILED" ]]; then
          print_thermal_status "INSUFFICIENT" "" "" "$test_status"
          echo
          # GHUL Hellfire Cooling Rating (header is printed by print_ghul_rating)
          print_ghul_rating "ABORTED" "" "$test_status" "$component"
        fi
      fi
    else
      # Only show warning if it wasn't a safety stop
      if [[ "$test_status" != "FAILED" ]] || [[ -z "${HELLFIRE_GPU_SAFETY_FAILED:-}" ]]; then
        yellow "    Warning: Could not parse sensor log or no temperature data found"
        echo
      fi
    fi
  elif [[ -z "$log_file" ]] && [[ $show_temp_stats -eq 1 ]] && [[ "$test_status" != "FAILED" || -z "${HELLFIRE_GPU_SAFETY_FAILED:-}" ]]; then
    yellow "  Warning: Sensor log not found"
    echo
  fi
  
  # Test result (skip for user aborts)
  if [[ "$test_status" == "ABORTED" ]] && [[ -n "${HELLFIRE_USER_ABORTED:-}" ]]; then
    # User abort - don't show result
    :
  elif [[ "$test_status" == "PASS" ]]; then
    green "  Result: PASS – no thermal limit reached, no abort triggered."
  elif [[ "$test_status" == "ABORTED" ]]; then
    red "  Result: ABORTED"
    if [[ -n "$abort_reason" ]]; then
      red "         $abort_reason"
    fi
  elif [[ "$test_status" == "FAILED" ]]; then
    # For FAILED tests, show only essential info (no temperature stats, no rating)
    red "  ⚠️  Test was aborted immediately to prevent hardware damage."
    echo
    echo "  Congratulations. You almost forged a new planet core."
    echo
    red "  Result: FAILED"
    if [[ -n "$abort_reason" ]]; then
      red "  Reason: $abort_reason"
    elif [[ -n "${HELLFIRE_GPU_SAFETY_REASON:-}" ]]; then
      red "  Reason: ${HELLFIRE_GPU_SAFETY_REASON}"
    else
      red "  Reason: Hellfire Safety Stop triggered"
    fi
  fi
  
  echo
}

# ============================================================================
# Cooler Test Functions
# ============================================================================

# Monitor safety for cooler test (CPU + GPU combined)
monitor_cooler_safety() {
  local test_name="$1"
  local duration="$2"
  local cpu_pid="$3"
  local gpu_pid="$4"
  local gpu_vendor="$5"
  
  local cpu_critical=100.0
  local cpu_warning=85.0
  local gpu_hotspot_critical=100.0
  local gpu_hotspot_warning=90.0
  local vram_critical=90.0
  local vram_warning=85.0
  
  local cpu_over_start=0
  local gpu_hotspot_over_start=0
  local last_warning_time=0
  local vram_warning_85_shown=0
  local vram_warning_90_shown=0
  
  green "  Cooler safety monitoring active"
  green "    CPU critical: ${cpu_critical}°C"
  green "    GPU hotspot critical: ${gpu_hotspot_critical}°C"
  green "    VRAM critical: ${vram_critical}°C"
  echo
  
  local start_time
  start_time="$(date +%s)"
  local end_time
  end_time=$((start_time + duration))
  
  while [[ $(date +%s) -lt $end_time ]]; do
    # Check if processes are still running
    local processes_running=0
    if [[ -n "$cpu_pid" ]] && kill -0 "$cpu_pid" 2>/dev/null; then
      processes_running=1
    fi
    if [[ -n "$gpu_pid" ]] && kill -0 "$gpu_pid" 2>/dev/null; then
      processes_running=1
    fi
    
    if [[ $processes_running -eq 0 ]]; then
      break
    fi
    
    local current_time
    current_time="$(date +%s)"
    
    # Check CPU temperature
    local cpu_temp
    cpu_temp="$(read_cpu_temp)"
    if [[ "$cpu_temp" != "null" ]]; then
      # Immediate stop: CPU > 100°C for 5 seconds
      if (( $(echo "$cpu_temp > $cpu_critical" | bc -l 2>/dev/null || echo 0) )); then
        if [[ $cpu_over_start -eq 0 ]]; then
          cpu_over_start=$current_time
        fi
        
        local cpu_over_duration
        cpu_over_duration=$((current_time - cpu_over_start))
        
        if [[ $cpu_over_duration -ge 5 ]]; then
          export HELLFIRE_COOLER_SAFETY_FAILED=1
          export HELLFIRE_COOLER_SAFETY_REASON="CPU temperature ${cpu_temp}°C exceeded ${cpu_critical}°C for ${cpu_over_duration}s"
          red "  🚨 IMMEDIATE STOP: CPU ${cpu_temp}°C > ${cpu_critical}°C for ${cpu_over_duration}s"
          if [[ -n "$cpu_pid" ]]; then
            kill "$cpu_pid" 2>/dev/null || true
          fi
          if [[ -n "$gpu_pid" ]]; then
            kill "$gpu_pid" 2>/dev/null || true
          fi
          return
        fi
      else
        cpu_over_start=0
      fi
      
      # Warnings
      if [[ $((current_time - last_warning_time)) -ge 5 ]]; then
        if (( $(echo "$cpu_temp > $cpu_warning" | bc -l 2>/dev/null || echo 0) )); then
          yellow "  ⚠️  WARNING: CPU temperature ${cpu_temp}°C > ${cpu_warning}°C"
          last_warning_time=$current_time
        fi
      fi
    fi
    
    # Check GPU sensors
    if [[ -n "$gpu_pid" ]] && [[ "$gpu_vendor" != "unknown" ]]; then
      local gpu_sensors
      gpu_sensors="$(read_gpu_sensors "$gpu_vendor")"
      IFS='|' read -r edge hotspot vram power fan <<< "$gpu_sensors"
      
      # Immediate stop: VRAM > 90°C
      if [[ "$vram" != "null" && -n "$vram" ]] && (( $(echo "$vram > $vram_critical" | bc -l 2>/dev/null || echo 0) )); then
        export HELLFIRE_COOLER_SAFETY_FAILED=1
        export HELLFIRE_COOLER_SAFETY_REASON="VRAM temperature ${vram}°C exceeded ${vram_critical}°C"
        red "  🚨 IMMEDIATE STOP: VRAM ${vram}°C > ${vram_critical}°C"
        if [[ -n "$cpu_pid" ]]; then
          kill "$cpu_pid" 2>/dev/null || true
        fi
        if [[ -n "$gpu_pid" ]]; then
          kill "$gpu_pid" 2>/dev/null || true
        fi
        return
      fi
      
      # Delayed stop: GPU Hotspot > 100°C for 2 seconds
      if [[ "$hotspot" != "null" && -n "$hotspot" ]]; then
        if (( $(echo "$hotspot > $gpu_hotspot_critical" | bc -l 2>/dev/null || echo 0) )); then
          if [[ $gpu_hotspot_over_start -eq 0 ]]; then
            gpu_hotspot_over_start=$current_time
          fi
          
          local hotspot_duration
          hotspot_duration=$((current_time - gpu_hotspot_over_start))
          
          if [[ $hotspot_duration -ge 2 ]]; then
            export HELLFIRE_COOLER_SAFETY_FAILED=1
            export HELLFIRE_COOLER_SAFETY_REASON="GPU hotspot temperature ${hotspot}°C exceeded ${gpu_hotspot_critical}°C for ${hotspot_duration}s"
            red "  🚨 DELAYED STOP: GPU hotspot ${hotspot}°C > ${gpu_hotspot_critical}°C for ${hotspot_duration}s"
            if [[ -n "$cpu_pid" ]]; then
              kill "$cpu_pid" 2>/dev/null || true
            fi
            if [[ -n "$gpu_pid" ]]; then
              kill "$gpu_pid" 2>/dev/null || true
            fi
            return
          fi
        else
          gpu_hotspot_over_start=0
        fi
        
        # Warnings (reduced spam for VRAM)
        if [[ $((current_time - last_warning_time)) -ge 5 ]]; then
          if (( $(echo "$hotspot > $gpu_hotspot_warning" | bc -l 2>/dev/null || echo 0) )); then
            yellow "  ⚠️  WARNING: GPU hotspot temperature ${hotspot}°C > ${gpu_hotspot_warning}°C"
            last_warning_time=$current_time
          fi
        fi
        
        # VRAM warnings: only once at 85°C and once at 90°C
        if [[ "$vram" != "null" && -n "$vram" ]]; then
          local vram_num
          vram_num="$(echo "$vram" | awk '{print $1+0}')"
          
          # Warning at 85°C (only once)
          if [[ $vram_warning_85_shown -eq 0 ]] && (( $(echo "$vram_num >= 85" | bc -l 2>/dev/null || echo 0) )); then
            yellow "  ⚠️  WARNING: VRAM crossed 85°C (current: ${vram}°C)"
            vram_warning_85_shown=1
          fi
          
          # Warning at 90°C (only once, before critical stop)
          if [[ $vram_warning_90_shown -eq 0 ]] && (( $(echo "$vram_num >= 90" | bc -l 2>/dev/null || echo 0) )); then
            yellow "  ⚠️  WARNING: VRAM reached 90°C (at the GHUL safety limit)"
            vram_warning_90_shown=1
          fi
        fi
      fi
    fi
    
    sleep 1
  done
}

# Calculate cooler score (0-100)
calculate_cooler_score() {
  local cpu_temp_max="$1"
  local gpu_hotspot_max="$2"
  local gpu_vram_max="$3"
  local nvme_temp_max="$4"
  local gpu_power_avg="$5"
  local cpu_power_avg="${6:-0}"  # Optional, default to 0 if not available
  
  # Calculate worst temperature
  local worst_temp_max=0
  
  if [[ "$cpu_temp_max" != "null" && -n "$cpu_temp_max" ]]; then
    worst_temp_max="$(echo "$cpu_temp_max" | awk '{print $1+0}')"
  fi
  
  if [[ "$gpu_hotspot_max" != "null" && -n "$gpu_hotspot_max" ]]; then
    local gpu_hotspot_num
    gpu_hotspot_num="$(echo "$gpu_hotspot_max" | awk '{print $1+0}')"
    if (( $(echo "$gpu_hotspot_num > $worst_temp_max" | bc -l 2>/dev/null || echo 0) )); then
      worst_temp_max="$gpu_hotspot_num"
    fi
  fi
  
  if [[ "$gpu_vram_max" != "null" && -n "$gpu_vram_max" ]]; then
    local gpu_vram_num
    gpu_vram_num="$(echo "$gpu_vram_max" | awk '{print $1+0}')"
    if (( $(echo "$gpu_vram_num > $worst_temp_max" | bc -l 2>/dev/null || echo 0) )); then
      worst_temp_max="$gpu_vram_num"
    fi
  fi
  
  if [[ "$nvme_temp_max" != "null" && -n "$nvme_temp_max" ]]; then
    local nvme_temp_num
    nvme_temp_num="$(echo "$nvme_temp_max" | awk '{print $1+0}')"
    if (( $(echo "$nvme_temp_num > $worst_temp_max" | bc -l 2>/dev/null || echo 0) )); then
      worst_temp_max="$nvme_temp_num"
    fi
  fi
  
  # If no temperatures available, return 0
  if (( $(echo "$worst_temp_max == 0" | bc -l 2>/dev/null || echo 1) )); then
    echo "0"
    return
  fi
  
  # Calculate total power
  local total_power=0
  if [[ "$gpu_power_avg" != "null" && -n "$gpu_power_avg" ]]; then
    total_power="$(echo "$gpu_power_avg" | awk '{print $1+0}')"
  fi
  if [[ "$cpu_power_avg" != "null" && -n "$cpu_power_avg" ]] && (( $(echo "$cpu_power_avg > 0" | bc -l 2>/dev/null || echo 0) )); then
    local cpu_power_num
    cpu_power_num="$(echo "$cpu_power_avg" | awk '{print $1+0}')"
    total_power="$(echo "$total_power $cpu_power_num" | awk '{printf "%.1f", $1 + $2}')"
  fi
  
  # If no power data, return 0
  if (( $(echo "$total_power == 0" | bc -l 2>/dev/null || echo 1) )); then
    echo "0"
    return
  fi
  
  # Calculate efficiency (W/°C)
  local efficiency
  efficiency="$(echo "$total_power $worst_temp_max" | awk '{if($2>0) printf "%.2f", $1/$2; else print "0"}')"
  
  # Calculate raw score
  local score_raw
  score_raw="$(echo "$efficiency 30" | awk '{printf "%.1f", $1 * $2}')"
  
  local cooler_score
  cooler_score="$(echo "$score_raw" | awk '{printf "%.0f", $1}')"
  
  # Apply penalties
  if (( $(echo "$worst_temp_max >= 95" | bc -l 2>/dev/null || echo 0) )); then
    cooler_score=20
  fi
  
  if [[ "$gpu_vram_max" != "null" && -n "$gpu_vram_max" ]]; then
    local gpu_vram_num
    gpu_vram_num="$(echo "$gpu_vram_max" | awk '{print $1+0}')"
    if (( $(echo "$gpu_vram_num >= 90" | bc -l 2>/dev/null || echo 0) )); then
      cooler_score=$((cooler_score - 10))
    fi
  fi
  
  if [[ "$nvme_temp_max" != "null" && -n "$nvme_temp_max" ]]; then
    local nvme_temp_num
    nvme_temp_num="$(echo "$nvme_temp_max" | awk '{print $1+0}')"
    if (( $(echo "$nvme_temp_num >= 85" | bc -l 2>/dev/null || echo 0) )); then
      cooler_score=$((cooler_score - 10))
    fi
  fi
  
  # Clamp to 0-100
  if [[ $cooler_score -lt 0 ]]; then
    cooler_score=0
  elif [[ $cooler_score -gt 100 ]]; then
    cooler_score=100
  fi
  
  echo "$cooler_score"
}

# Get cooler tier from worst temperature and safety stop
get_cooler_tier() {
  local worst_temp="$1"
  local safety_stop="${2:-0}"  # 1 if safety stop triggered, 0 otherwise
  
  # Safety stop always = D-TIER
  if [[ "$safety_stop" == "1" ]]; then
    echo "D-TIER"
    return
  fi
  
  # Convert worst_temp to number
  local worst_temp_num
  worst_temp_num="$(echo "$worst_temp" | awk '{print $1+0}')"
  
  # Tier based on worst temperature
  if (( $(echo "$worst_temp_num >= 95" | bc -l 2>/dev/null || echo 0) )); then
    echo "D-TIER"  # CRITICAL
  elif (( $(echo "$worst_temp_num >= 90" | bc -l 2>/dev/null || echo 0) )); then
    echo "C-TIER"  # HOT
  elif (( $(echo "$worst_temp_num >= 80" | bc -l 2>/dev/null || echo 0) )); then
    echo "B-TIER"  # WARM
  elif (( $(echo "$worst_temp_num >= 70" | bc -l 2>/dev/null || echo 0) )); then
    echo "A-TIER"  # GOOD
  else
    echo "S-TIER"  # EXCELLENT
  fi
}

# Get cooler tier description
get_cooler_tier_desc() {
  local tier="$1"
  
  case "$tier" in
    S-TIER)
      echo "EXCELLENT"
      ;;
    A-TIER)
      echo "GOOD"
      ;;
    B-TIER)
      echo "WARM"
      ;;
    C-TIER)
      echo "HOT"
      ;;
    D-TIER)
      echo "CRITICAL"
      ;;
    *)
      echo "UNKNOWN"
      ;;
  esac
}

# Get funny comment for cooler tier
get_cooler_comment() {
  local tier="$1"
  
  case "$tier" in
    S-TIER)
      echo "Your case is basically a wind tunnel with RGB. Illegal level. Your rig is ready for desert LAN parties."
      ;;
    A-TIER)
      echo "Strong cooling performance. Your PSU just did a CrossFit session and asked for more. This is how grown-up builds look."
      ;;
    B-TIER)
      echo "Hot but manageable. Good for gaming, maybe not for overvolting everything - summer heatwaves might start a negotiation."
      ;;
    C-TIER)
      echo "Airflow is more suggestion than reality. Consider adding fans or cleaning filters. Your PSU survived, but it will remember this day."
      ;;
    D-TIER)
      echo "Congrats, you accidentally built an Easy-Bake Oven. Consider gaming in the fridge and PSU choice - if your rig had a union, the fans would be on strike now."
      ;;
    *)
      echo "Temperature data not available."
      ;;
  esac
}

# Print cooler summary
print_cooler_summary() {
  local test_name="$1"
  local duration="$2"
  local test_status="${3:-PASS}"
  local abort_reason="${4:-}"
  local sensor_log_pattern="${LOGDIR}/*-${HOST}-${test_name}-sensors.jsonl"
  
  echo
  green "╔═══════════════════════════════════════════════════════════════╗"
  green "║                    TEST COMPLETE – COOLER                     ║"
  green "╚═══════════════════════════════════════════════════════════════╝"
  echo
  green "  Test: $test_name"
  green "  Duration: $duration seconds"
  
  # Find sensor log file
  local log_file=""
  if ls ${sensor_log_pattern} 2>/dev/null | head -1 | grep -q .; then
    log_file="$(ls -t ${sensor_log_pattern} 2>/dev/null | head -1)"
    green "  Sensor log: $log_file"
    echo
  fi
  
  if [[ -n "$log_file" ]]; then
    # Parse sensor log
    local temp_stats
    temp_stats="$(parse_sensor_log "$log_file")"
    
    if [[ -n "$temp_stats" ]]; then
      # Source the stats as variables
      eval "$temp_stats"
      
      echo "  Temperature Peaks:"
      echo
      
      if [[ -n "${CPU_TEMP_MAX:-}" ]]; then
        printf '    CPU max:         %.1f°C\n' "$CPU_TEMP_MAX"
      else
        echo "    CPU max:         n/a"
      fi
      
      if [[ -n "${GPU_HOTSPOT_MAX:-}" ]]; then
        printf '    GPU hotspot max: %.1f°C\n' "$GPU_HOTSPOT_MAX"
      else
        echo "    GPU hotspot max: n/a"
      fi
      
      if [[ -n "${GPU_VRAM_MAX:-}" ]]; then
        printf '    GPU VRAM max:    %.1f°C\n' "$GPU_VRAM_MAX"
      else
        echo "    GPU VRAM max:    n/a"
      fi
      
      # NVMe temperature (if available in sensor log)
      if [[ -n "${NVME_TEMP_MAX:-}" ]]; then
        printf '    NVMe max:        %.1f°C\n' "$NVME_TEMP_MAX"
      else
        echo "    NVMe max:        n/a"
      fi
      
      echo
      echo "  Power Averages:"
      echo
      
      if [[ -n "${GPU_POWER_AVG:-}" ]]; then
        printf '    GPU avg power:   %.1f W\n' "$GPU_POWER_AVG"
      else
        echo "    GPU avg power:   n/a"
      fi
      
      # CPU power (if available)
      local cpu_power_available=0
      if [[ -n "${CPU_PKG_POWER_AVG:-}" ]]; then
        local cpu_power_num
        cpu_power_num="$(echo "$CPU_PKG_POWER_AVG" | awk '{print $1+0}')"
        if (( $(echo "$cpu_power_num > 0" | bc -l 2>/dev/null || echo 0) )); then
          printf '    CPU avg power:   %.1f W\n' "$CPU_PKG_POWER_AVG"
          cpu_power_available=1
        else
          echo "    CPU avg power:   n/a (no CPU power sensors available on this hardware)"
        fi
      else
        echo "    CPU avg power:   n/a (no CPU power sensors available on this hardware)"
      fi
      
      # Calculate total power
      local total_power=0
      local total_power_text=""
      if [[ -n "${GPU_POWER_AVG:-}" ]]; then
        total_power="$(echo "$GPU_POWER_AVG" | awk '{print $1+0}')"
      fi
      
      if [[ $cpu_power_available -eq 1 ]] && [[ -n "${CPU_PKG_POWER_AVG:-}" ]]; then
        local cpu_power
        cpu_power="$(echo "$CPU_PKG_POWER_AVG" | awk '{print $1+0}')"
        total_power="$(echo "$total_power $cpu_power" | awk '{printf "%.1f", $1 + $2}')"
        total_power_text="$(printf '%.1f W' "$total_power")"
      elif (( $(echo "$total_power > 0" | bc -l 2>/dev/null || echo 0) )); then
        total_power_text="$(printf '%.1f W (CPU power not measurable on this system)' "$total_power")"
      else
        total_power_text="n/a"
      fi
      
      echo "    Total approx:    $total_power_text"
      
      echo
      
      # Calculate worst temperature (max of CPU, GPU hotspot, VRAM)
      local worst_temp=0
      if [[ -n "${CPU_TEMP_MAX:-}" ]]; then
        worst_temp="$(echo "$CPU_TEMP_MAX" | awk '{print $1+0}')"
      fi
      if [[ -n "${GPU_HOTSPOT_MAX:-}" ]]; then
        local gpu_hotspot_num
        gpu_hotspot_num="$(echo "$GPU_HOTSPOT_MAX" | awk '{print $1+0}')"
        if (( $(echo "$gpu_hotspot_num > $worst_temp" | bc -l 2>/dev/null || echo 0) )); then
          worst_temp="$gpu_hotspot_num"
        fi
      fi
      if [[ -n "${GPU_VRAM_MAX:-}" ]]; then
        local gpu_vram_num
        gpu_vram_num="$(echo "$GPU_VRAM_MAX" | awk '{print $1+0}')"
        if (( $(echo "$gpu_vram_num > $worst_temp" | bc -l 2>/dev/null || echo 0) )); then
          worst_temp="$gpu_vram_num"
        fi
      fi
      
      local thermal_status="OK"
      if (( $(echo "$worst_temp >= 95" | bc -l 2>/dev/null || echo 0) )); then
        thermal_status="CRITICAL"
      elif (( $(echo "$worst_temp >= 85" | bc -l 2>/dev/null || echo 0) )); then
        thermal_status="WARM"
      fi
      
      case "$thermal_status" in
        OK)
          green "  Overall Thermal Status: ✅ OK"
          ;;
        WARM)
          yellow "  Overall Thermal Status: ⚠️ WARM"
          ;;
        CRITICAL)
          red "  Overall Thermal Status: 🚨 CRITICAL"
          ;;
      esac
      
      echo
      
      # Calculate and display cooler score (only if not failed)
      if [[ "$test_status" != "FAILED" ]]; then
        # Check if safety stop was triggered
        local safety_stop=0
        if [[ -n "${HELLFIRE_COOLER_SAFETY_FAILED:-}" ]]; then
          safety_stop=1
        fi
        
        # Calculate cooler score
        local cooler_score
        cooler_score="$(calculate_cooler_score \
          "${CPU_TEMP_MAX:-null}" \
          "${GPU_HOTSPOT_MAX:-null}" \
          "${GPU_VRAM_MAX:-null}" \
          "${NVME_TEMP_MAX:-null}" \
          "${GPU_POWER_AVG:-null}" \
          "${CPU_PKG_POWER_AVG:-null}")"
        
        # Apply minimum score for 88-90°C range without safety stop
        if [[ $safety_stop -eq 0 ]] && (( $(echo "$worst_temp >= 88 && $worst_temp <= 90" | bc -l 2>/dev/null || echo 0) )); then
          local score_num
          score_num="$(echo "$cooler_score" | awk '{print $1+0}')"
          if [[ $score_num -lt 45 ]]; then
            cooler_score=45
          fi
        fi
        
        # Get tier based on worst_temp and safety_stop (not score)
        local cooler_tier
        cooler_tier="$(get_cooler_tier "$worst_temp" "$safety_stop")"
        local cooler_tier_desc
        cooler_tier_desc="$(get_cooler_tier_desc "$cooler_tier")"
        local cooler_comment
        cooler_comment="$(get_cooler_comment "$cooler_tier")"
        
        echo "  🥇 GHUL Hellfire Cooler Rating v1.0"
        echo
        echo "  Score: $cooler_score / 100"
        echo "  Tier:  $cooler_tier  ($cooler_tier_desc)"
        echo
        echo "  Comment:"
        echo "    $cooler_comment"
        echo
      fi
    else
      yellow "    Warning: Could not parse sensor log or no temperature data found"
      echo
    fi
  elif [[ -z "$log_file" ]]; then
    yellow "  Warning: Sensor log not found"
    echo
  fi
  
  # Test result
  if [[ "$test_status" == "PASS" ]]; then
    green "  Result: PASS – no thermal limit reached, no abort triggered."
  elif [[ "$test_status" == "FAILED" ]]; then
    red "  Result: FAILED"
    if [[ -n "$abort_reason" ]]; then
      red "         $abort_reason"
      echo
      # Add funny comment for safety stop
      if echo "$abort_reason" | grep -qi "VRAM"; then
        red "  Comment: Your VRAM tried to escape the case. Cooler test aborted for safety."
      elif echo "$abort_reason" | grep -qi "hotspot"; then
        red "  Comment: GPU hotspot reached critical levels. Cooler test aborted for safety."
      elif echo "$abort_reason" | grep -qi "CPU"; then
        red "  Comment: CPU temperature exceeded safety limits. Cooler test aborted for safety."
      else
        red "  Comment: Hellfire Safety Stop triggered. Cooler test aborted for safety."
      fi
    fi
  fi
  
  echo
}
