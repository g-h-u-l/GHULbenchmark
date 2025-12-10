#!/usr/bin/env bash
# GHUL Hellfire - Extreme Combined Stress Test (CPU + GPU + RAM)
# WARNING: This is the ULTIMATE stress test - pushes everything to maximum!
# This will test PSU, VRM, case cooling, and overall system stability
# Use with EXTREME caution and ensure excellent cooling!

set -euo pipefail

# Enforce predictable C locale (important for awk/jq and numeric formatting)
export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hellfire-common.sh
source "${SCRIPT_DIR}/hellfire-common.sh"

# Test configuration
HELLFIRE_TEST_NAME="cooler"
DEFAULT_DURATION=300  # 5 minutes default
DURATION="${1:-${DEFAULT_DURATION}}"

# Validate duration
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 10 ]]; then
  red "Error: Duration must be a positive integer (minimum 10 seconds)"
  echo "Usage: $0 [duration_seconds]"
  exit 1
fi

# Main function
main() {
  print_hellfire_header "COOLER STRESS TEST"
  
  red "🚨 CRITICAL WARNING: This is the ULTIMATE stress test!"
  red "  This test will:"
  yellow "  - Push ALL CPU cores to 100% load"
  yellow "  - Push GPU to 100% load"
  yellow "  - Use maximum available RAM"
  yellow "  - Generate MAXIMUM heat (PSU, VRM, CPU, GPU)"
  yellow "  - Test case cooling to the limit"
  yellow "  - May cause thermal throttling or system instability"
  yellow "  - Duration: ${DURATION} seconds"
  echo
  red "  ⚠ Ensure excellent cooling before proceeding!"
  red "  ⚠ Monitor temperatures closely!"
  echo
  
  echo -n "Are you SURE you want to continue? Type 'HELLFIRE' to confirm: "
  read -r answer
  if [[ "$answer" != "HELLFIRE" ]]; then
    yellow "Test cancelled."
    exit 0
  fi
  
  # Setup cleanup trap
  setup_cleanup_trap
  
  # Check temperatures before starting
  check_temps_before_start
  
  # Countdown
  countdown 10
  
  # Start sensor monitoring
  start_sensor_monitor "$HELLFIRE_TEST_NAME" "$DURATION"
  
  # Get system info
  local cores
  cores="$(nproc)"
  local ram_total_kb
  ram_total_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
  local ram_test_kb
  ram_test_kb="$(awk -v t="$ram_total_kb" 'BEGIN { printf "%.0f", t*0.9 }')"
  local gpu_vendor
  gpu_vendor="$(detect_gpu_vendor 2>/dev/null || echo "unknown")"
  
  green "  System configuration:"
  green "    CPU cores: $cores"
  green "    RAM test: $(awk -v k="$ram_test_kb" 'BEGIN { printf "%.2f", k/1024/1024 }') GiB"
  green "    GPU vendor: $gpu_vendor"
  echo
  
  # Start all stress tests simultaneously
  green "  Starting combined stress test..."
  
  local pids=()
  
  # 1. CPU stress
  if have stress-ng; then
    green "    Starting CPU stress..."
    stress-ng \
      --matrix "$cores" \
      --crypt "$cores" \
      --cpu "$cores" \
      --timeout "${DURATION}s" \
      --metrics-brief \
      --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-cpu.log" &
    pids+=($!)
  fi
  
  # 2. RAM stress
  if have stress-ng; then
    green "    Starting RAM stress..."
    stress-ng \
      --vm "$cores" \
      --vm-bytes "${ram_test_kb}K" \
      --vm-keep \
      --timeout "${DURATION}s" \
      --metrics-brief \
      --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-ram.log" &
    pids+=($!)
  fi
  
  # 3. GPU stress
  if have gputest; then
    green "    Starting GPU stress..."
    gputest /test=fur /width=1920 /height=1080 /gpumon_terminal /benchmark /print_score /run_time="${DURATION}" \
      > "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-gpu.log" 2>&1 &
    pids+=($!)
  else
    yellow "    Warning: gputest not found, GPU stress skipped"
  fi
  
  green "  All stress tests started (${#pids[@]} processes)"
  green "  Monitoring for ${DURATION} seconds..."
  
  # Wait for all processes to complete
  local failed=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid" 2>/dev/null; then
      failed=1
    fi
  done
  
  if [[ $failed -eq 1 ]]; then
    yellow "  Warning: Some stress tests may have failed"
  fi
  
  # Stop sensor monitoring
  stop_sensor_monitor "$HELLFIRE_TEST_NAME"
  
  # Print summary
  print_test_summary "$HELLFIRE_TEST_NAME" "$DURATION"
  
  red "  ⚠ Check temperatures and system stability!"
}

# Detect GPU vendor (from ghul-sensors-helper.sh)
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

main "$@"

