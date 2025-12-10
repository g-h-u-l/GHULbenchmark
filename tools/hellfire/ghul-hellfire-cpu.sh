#!/usr/bin/env bash
# GHUL Hellfire - Extreme CPU Stress Test
# WARNING: This test will push your CPU to 100% load and maximum temperatures
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
HELLFIRE_TEST_NAME="cpu"
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
  # Print extreme warning
  print_hellfire_warning
  
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
  echo "Proceeding with GHUL Hellfire…"
  echo
  echo "This test can kill your CPU in a life-threatening way."
  echo
  echo "Good luck, brave warrior."
  echo
  echo "🔥🔥🔥"
  echo
  
  # Print header
  print_hellfire_header "CPU STRESS TEST"
  
  # Store test info for cleanup handler
  export HELLFIRE_TEST_NAME="$HELLFIRE_TEST_NAME"
  export HELLFIRE_DURATION="$DURATION"
  
  # Setup cleanup trap
  setup_cleanup_trap
  
  # Check temperatures before starting
  check_temps_before_start
  
  # Start sensor monitoring
  start_sensor_monitor "$HELLFIRE_TEST_NAME" "$DURATION"
  
  # Get CPU core count
  local cores
  cores="$(nproc)"
  green "  Detected $cores CPU cores"
  green "  Duration: ${DURATION} seconds"
  echo
  
  # Start CPU stress test
  green "  Starting CPU stress test..."
  
  if have stress-ng; then
    # Use stress-ng for maximum CPU load
    # Matrix stress: CPU-intensive matrix operations
    # Crypt stress: Cryptographic operations
    # CPU stress: Generic CPU stress
    stress-ng \
      --matrix "$cores" \
      --crypt "$cores" \
      --cpu "$cores" \
      --timeout "${DURATION}s" \
      --metrics-brief \
      --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-cpu-stress.log" &
    
    STRESS_PID=$!
    green "  stress-ng started (PID: $STRESS_PID)"
    echo
    
    # Monitor CPU temperature in background
    monitor_cpu_temp "$HELLFIRE_TEST_NAME" "$DURATION" "$STRESS_PID" &
    MONITOR_PID=$!
    
    # Wait for stress test to complete
    wait "$STRESS_PID" 2>/dev/null || true
    
    # Stop temperature monitoring
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    
    # Check if test was aborted due to temperature or user abort
    local test_status="PASS"
    local abort_reason=""
    
    if [[ -n "${HELLFIRE_USER_ABORTED:-}" ]]; then
      # User abort was handled by cleanup handler
      exit 0
    elif [[ -n "${HELLFIRE_TEMP_FAILED:-}" ]]; then
      test_status="ABORTED"
      abort_reason="CPU limit exceeded for 5s (safety shutdown)"
      red "  Test aborted due to critical temperature"
    else
      green "  Test completed successfully"
    fi
  else
    red "  Error: stress-ng not found!"
    red "  Install with: sudo pacman -S stress-ng"
    exit 1
  fi
  
  # Stop sensor monitoring
  stop_sensor_monitor "$HELLFIRE_TEST_NAME"
  
  # Print summary (only if not aborted by user)
  if [[ -z "${HELLFIRE_USER_ABORTED:-}" ]]; then
    print_test_summary "$HELLFIRE_TEST_NAME" "$DURATION" "$test_status" "$abort_reason"
  fi
}

main "$@"

