#!/usr/bin/env bash
# GHUL Hellfire - Extreme GPU Stress Test
# WARNING: This test will push your GPU to 100% load and maximum temperatures
# Use with caution and ensure adequate cooling!

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
HELLFIRE_TEST_NAME="gpu"
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
  print_hellfire_warning
  
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
  
  echo
  echo "🔥 You have been warned."
  echo
  echo "Proceeding with GHUL Hellfire…"
  echo
  echo "This test can kill your GPU in a life-threatening way."
  echo
  echo "Good luck, brave warrior."
  echo
  echo "🔥🔥🔥"
  echo
  
  print_hellfire_header "GPU STRESS TEST"
  
  export HELLFIRE_TEST_NAME="$HELLFIRE_TEST_NAME"
  export HELLFIRE_DURATION="$DURATION"
  
  setup_cleanup_trap
  
  check_temps_before_start
  
  # Detect GPU vendor
  local gpu_vendor
  gpu_vendor="$(detect_gpu_vendor 2>/dev/null || echo "unknown")"
  green "  Detected GPU vendor: $gpu_vendor"
  
  if [[ "$gpu_vendor" == "unknown" ]]; then
    red "  Error: Could not detect GPU vendor!"
    red "  This test requires a supported GPU (AMD or NVIDIA)"
    exit 1
  fi
  
  green "  Duration: ${DURATION} seconds"
  echo
  
  countdown 5
  
  start_sensor_monitor "$HELLFIRE_TEST_NAME" "$DURATION"
  
  green "  Starting GPU stress test..."
  
  local stress_pid=""
  local monitor_pid=""
  local test_status="PASS"
  local abort_reason=""
  
  # Try to start GPU stress test
  if have stress-ng && stress-ng --help 2>&1 | grep -q "gpu"; then
    # Use stress-ng GPU stressor (compute workload)
    stress-ng \
      --gpu 1 \
      --timeout "${DURATION}s" \
      --metrics-brief \
      --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-gpu-stress.log" &
    stress_pid=$!
    green "  stress-ng GPU stressor started (PID: $stress_pid)"
  elif have gputest; then
    # Fallback: Use GpuTest FurMark for maximum GPU load
    gputest /test=fur /width=1920 /height=1080 /gpumon_terminal /benchmark /print_score /run_time="${DURATION}" \
      > "${LOGDIR}/$(get_timestamp)-${HOST}-gpu-stress.log" 2>&1 &
    stress_pid=$!
    green "  GpuTest FurMark started (PID: $stress_pid)"
  else
    red "  Error: No GPU stress test tool found!"
    red "  Install one of:"
    red "     - stress-ng (pacman -S stress-ng)"
    red "     - gputest (pamac install gputest - AUR)"
    stop_sensor_monitor "$HELLFIRE_TEST_NAME"
    exit 1
  fi
  
  # Start GPU safety monitoring
  monitor_gpu_safety "$HELLFIRE_TEST_NAME" "$DURATION" "$stress_pid" "$gpu_vendor" &
  monitor_pid=$!
  
  # Wait for stress test to complete
  wait "$stress_pid" 2>/dev/null || true
  
  # Stop monitoring
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  
  # Check test status
  if [[ -n "${HELLFIRE_USER_ABORTED:-}" ]]; then
    exit 0  # Handled by cleanup trap
  elif [[ -n "${HELLFIRE_GPU_SAFETY_FAILED:-}" ]]; then
    test_status="FAILED"
    abort_reason="${HELLFIRE_GPU_SAFETY_REASON:-Hellfire Safety Stop triggered}"
    red "  Test aborted due to GPU safety stop"
    # Don't show "Test completed successfully" for safety stops
  else
    green "  Test completed successfully"
  fi
  
  stop_sensor_monitor "$HELLFIRE_TEST_NAME"
  
  if [[ -z "${HELLFIRE_USER_ABORTED:-}" ]]; then
    print_test_summary "$HELLFIRE_TEST_NAME" "$DURATION" "$test_status" "$abort_reason"
  fi
}

main "$@"
