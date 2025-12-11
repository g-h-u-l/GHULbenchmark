#!/usr/bin/env bash
# GHUL Hellfire - Full System Furnace Test (Cooler/PSU Test)
# WARNING: This test will push CPU, RAM, GPU and Storage simultaneously
# Use with caution and ensure adequate cooling and PSU capacity!

set -euo pipefail

# Enforce predictable C locale (important for awk/jq and numeric formatting)
export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hellfire-common.sh
source "${SCRIPT_DIR}/hellfire-common.sh"

# ---------- Help function -----------------------------------------------------
show_help() {
  echo "GHUL Hellfire - Full System Furnace Test (Cooler/PSU Test)"
  echo
  echo "Usage:"
  echo "  $0 [OPTIONS] [duration_seconds]"
  echo
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo
  echo "Arguments:"
  echo "  duration_seconds    Test duration in seconds (default: 180, minimum: 10)"
  echo
  echo "Examples:"
  echo "  $0                  # Run for 180 seconds (3 minutes)"
  echo "  $0 300              # Run for 300 seconds (5 minutes)"
  echo "  $0 60               # Run for 60 seconds (1 minute)"
  echo
  echo "Description:"
  echo "  Full system stress test that loads CPU, RAM, and GPU simultaneously."
  echo "  Tests case airflow, cooling solution, and PSU under extreme combined load."
  echo "  Calculates a Cooler Score (0-100) and Tier Rating (S/A/B/C/D) based on"
  echo "  thermal efficiency (W/°C). Monitors all components and triggers safety"
  echo "  stops if critical thresholds are exceeded."
  echo
  echo "WARNING:"
  echo "  This is NOT a benchmark. This is hardware torture."
  echo "  Your entire system will become a furnace. All components will be stressed"
  echo "  simultaneously. Ensure adequate cooling and PSU capacity!"
  exit 0
}

# Check for help flag
if [[ $# -ge 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_help
fi

# Test configuration
HELLFIRE_TEST_NAME="cooler"
DEFAULT_DURATION=180  # 3 minutes default
DURATION="${1:-${DEFAULT_DURATION}}"

# Validate duration
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 10 ]]; then
  red "Error: Duration must be a positive integer (minimum 10 seconds)"
  echo "Usage: $0 [duration_seconds]"
  echo "Use -h or --help for more information."
  exit 1
fi

# Main function
main() {
  # Print extreme warning
  print_hellfire_warning
  
  yellow "This is a FULL SYSTEM FURNACE TEST - CPU, RAM, GPU and Storage will be stressed simultaneously."
  yellow "This tests your case airflow, cooling solution and PSU under extreme combined load."
  echo
  
  # Get confirmation (must be exactly "YES")
  echo -n "> "
  read -r answer
  
  if [[ "$answer" != "YES" ]]; then
    echo
    echo "Aborted."
    echo
    echo "Wise decision, traveler."
    echo
    exit 0
  fi
  
  # Print start message
  echo
  echo "🔥 You have been warned."
  echo
  echo "Proceeding with GHUL Hellfire Cooler Test…"
  echo
  echo "This test will turn your entire system into a furnace."
  echo "All components will be stressed simultaneously."
  echo
  echo "Good luck, brave warrior."
  echo
  echo "🔥🔥🔥"
  echo
  
  # Print header
  print_hellfire_header "COOLER FURNACE TEST"
  
  # Store test info for cleanup handler
  export HELLFIRE_TEST_NAME="$HELLFIRE_TEST_NAME"
  export HELLFIRE_DURATION="$DURATION"
  
  # Setup cleanup trap
  setup_cleanup_trap
  
  # Check temperatures before starting
  check_temps_before_start
  
  # Get system info
  local cores
  cores="$(nproc)"
  green "  Detected $cores CPU cores"
  
  local ram_total_kb
  ram_total_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
  local ram_total_gb
  ram_total_gb="$(awk -v k="$ram_total_kb" 'BEGIN { printf "%.2f", k/1024/1024 }')"
  green "  Total RAM: ${ram_total_gb} GiB"
  
  # Detect GPU vendor
  local gpu_vendor
  gpu_vendor="$(detect_gpu_vendor 2>/dev/null || echo "unknown")"
  if [[ "$gpu_vendor" != "unknown" ]]; then
    green "  Detected GPU vendor: $gpu_vendor"
  else
    yellow "  Warning: Could not detect GPU vendor - GPU stress may not work"
  fi
  
  green "  Duration: ${DURATION} seconds"
  echo
  
  countdown 5
  
  # Start sensor monitoring
  start_sensor_monitor "$HELLFIRE_TEST_NAME" "$DURATION"
  
  green "  Starting parallel stress loads..."
  echo
  
  local cpu_pid=""
  local ram_pid=""
  local gpu_pid=""
  local disk_pid=""
  local monitor_pid=""
  local test_status="PASS"
  local abort_reason=""
  
  # Start CPU stress
  if have stress-ng; then
    green "  Starting CPU stress (${cores} cores)..."
    stress-ng \
      --matrix "$cores" \
      --crypt "$cores" \
      --cpu "$cores" \
      --timeout "${DURATION}s" \
      --metrics-brief \
      --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-cpu.log" \
      >/dev/null 2>&1 &
    cpu_pid=$!
    export STRESS_PID="$cpu_pid"
    green "    CPU stress started (PID: $cpu_pid)"
  else
    red "  Error: stress-ng not found!"
    red "  Install with: sudo pacman -S stress-ng"
    stop_sensor_monitor "$HELLFIRE_TEST_NAME"
    exit 1
  fi
  
  # Start RAM stress (70% of RAM, min(8, cores) workers)
  local vm_workers
  vm_workers=$((cores < 8 ? cores : 8))
  local ram_test_kb
  ram_test_kb="$(awk -v t="$ram_total_kb" 'BEGIN { printf "%.0f", t*0.7 }')"
  local ram_test_gb
  ram_test_gb="$(awk -v k="$ram_test_kb" 'BEGIN { printf "%.2f", k/1024/1024 }')"
  
  green "  Starting RAM stress (${ram_test_gb} GiB, ${vm_workers} workers)..."
  stress-ng \
    --vm "$vm_workers" \
    --vm-bytes "${ram_test_kb}K" \
    --vm-method all \
    --vm-keep \
    --timeout "${DURATION}s" \
    --metrics-brief \
    --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-ram.log" \
    >/dev/null 2>&1 &
  ram_pid=$!
  green "    RAM stress started (PID: $ram_pid)"
  
  # Start GPU stress (moderate, msaa=2)
  if [[ "$gpu_vendor" != "unknown" ]]; then
    if have gputest; then
      green "  Starting GPU stress (moderate, msaa=2, 1280x720)..."
      gputest /test=fur /width=1280 /height=720 /msaa=2 /gpumon_terminal \
        > "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-gpu.log" 2>&1 &
      gpu_pid=$!
      export GPUTEST_PID="$gpu_pid"
      green "    GPU stress started (PID: $gpu_pid)"
    elif have stress-ng && stress-ng --help 2>&1 | grep -q "gpu"; then
      green "  Starting GPU stress (stress-ng)..."
      stress-ng \
        --gpu 1 \
        --timeout "${DURATION}s" \
        --metrics-brief \
        --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-gpu.log" \
        >/dev/null 2>&1 &
      gpu_pid=$!
      green "    GPU stress started (PID: $gpu_pid)"
    else
      yellow "  Warning: No GPU stress tool found - skipping GPU load"
    fi
  fi
  
  # Optional: Start disk stress (disabled for now - hdd-opts needs correct syntax)
  # if have stress-ng; then
  #   green "  Starting disk stress (optional)..."
  #   stress-ng \
  #     --hdd 2 \
  #     --hdd-opts wr-seq \
  #     --timeout "${DURATION}s" \
  #     --metrics-brief \
  #     --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-disk.log" &
  #   disk_pid=$!
  #   green "    Disk stress started (PID: $disk_pid)"
  # fi
  
  echo
  
  # Start combined safety monitoring
  monitor_cooler_safety "$HELLFIRE_TEST_NAME" "$DURATION" "$cpu_pid" "$gpu_pid" "$gpu_vendor" &
  monitor_pid=$!
  
  # Wait for duration
  local start_time
  start_time="$(date +%s)"
  local end_time
  end_time=$((start_time + DURATION))
  
  green "  Test running... (${DURATION} seconds)"
  echo
  
  # Wait for duration or until process dies
  while [[ $(date +%s) -lt $end_time ]]; do
    # Check if any critical process died
    if [[ -n "$cpu_pid" ]] && ! kill -0 "$cpu_pid" 2>/dev/null; then
      yellow "  CPU stress process ended early"
      break
    fi
    if [[ -n "$ram_pid" ]] && ! kill -0 "$ram_pid" 2>/dev/null; then
      yellow "  RAM stress process ended early"
      break
    fi
    if [[ -n "$gpu_pid" ]] && ! kill -0 "$gpu_pid" 2>/dev/null; then
      yellow "  GPU stress process ended early"
      break
    fi
    sleep 1
  done
  
  # Kill all stress processes
  green "  Test duration reached, terminating stress processes..."
  
  # Kill CPU/RAM (stress-ng will exit cleanly with timeout, but kill anyway)
  if [[ -n "$cpu_pid" ]]; then
    kill "$cpu_pid" 2>/dev/null || true
    wait "$cpu_pid" 2>/dev/null || true
  fi
  if [[ -n "$ram_pid" ]]; then
    kill "$ram_pid" 2>/dev/null || true
    wait "$ram_pid" 2>/dev/null || true
  fi
  
  # Kill GPU (gputest needs aggressive kill)
  if [[ -n "$gpu_pid" ]]; then
    kill "$gpu_pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$gpu_pid" 2>/dev/null; then
      kill -TERM "$gpu_pid" 2>/dev/null || true
      sleep 1
    fi
    if kill -0 "$gpu_pid" 2>/dev/null; then
      kill -9 "$gpu_pid" 2>/dev/null || true
    fi
    pkill -P "$gpu_pid" 2>/dev/null || true
    pkill -9 -P "$gpu_pid" 2>/dev/null || true
    pkill -f "gputest.*fur" 2>/dev/null || true
    sleep 0.5
    pkill -9 -f "gputest.*fur" 2>/dev/null || true
    wait "$gpu_pid" 2>/dev/null || true
  fi
  
  # Kill disk stress
  if [[ -n "$disk_pid" ]]; then
    kill "$disk_pid" 2>/dev/null || true
    wait "$disk_pid" 2>/dev/null || true
  fi
  
  # Kill any remaining stress-ng processes
  killall stress-ng 2>/dev/null || true
  
  # Stop monitoring
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  
  # Check test status
  if [[ -n "${HELLFIRE_USER_ABORTED:-}" ]]; then
    exit 0  # Handled by cleanup trap
  elif [[ -n "${HELLFIRE_COOLER_SAFETY_FAILED:-}" ]]; then
    test_status="FAILED"
    abort_reason="${HELLFIRE_COOLER_SAFETY_REASON:-Cooler Safety Stop triggered}"
    red "  Test aborted due to safety stop"
  else
    green "  Test completed successfully"
  fi
  
  # Stop sensor monitoring
  stop_sensor_monitor "$HELLFIRE_TEST_NAME"
  
  # Print summary (only if not aborted by user)
  if [[ -z "${HELLFIRE_USER_ABORTED:-}" ]]; then
    print_cooler_summary "$HELLFIRE_TEST_NAME" "$DURATION" "$test_status" "$abort_reason"
  fi
}

main "$@"
