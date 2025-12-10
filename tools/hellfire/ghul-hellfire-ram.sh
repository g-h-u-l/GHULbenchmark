#!/usr/bin/env bash
# GHUL Hellfire - Extreme RAM Stress Test
# WARNING: This test will use maximum available RAM and may cause system slowdown
# Use with caution!

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
HELLFIRE_TEST_NAME="ram"
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
  echo "This test can push your RAM to the absolute limit."
  echo
  echo "Good luck, brave warrior."
  echo
  echo "🔥🔥🔥"
  echo
  
  # Print header
  print_hellfire_header "RAM STRESS TEST"
  
  # Store test info for cleanup handler
  export HELLFIRE_TEST_NAME="$HELLFIRE_TEST_NAME"
  export HELLFIRE_DURATION="$DURATION"
  
  # Setup cleanup trap
  setup_cleanup_trap
  
  # Check temperatures before starting
  check_temps_before_start
  
  # Get available RAM
  local ram_total_kb
  ram_total_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
  local ram_total_gb
  ram_total_gb="$(awk -v k="$ram_total_kb" 'BEGIN { printf "%.2f", k/1024/1024 }')"
  green "  Total RAM: ${ram_total_gb} GiB"
  
  # Use 90% of available RAM (leave some for system)
  local ram_test_kb
  ram_test_kb="$(awk -v t="$ram_total_kb" 'BEGIN { printf "%.0f", t*0.9 }')"
  local ram_test_gb
  ram_test_gb="$(awk -v k="$ram_test_kb" 'BEGIN { printf "%.2f", k/1024/1024 }')"
  green "  Test will use: ${ram_test_gb} GiB (90% of total)"
  green "  Duration: ${DURATION} seconds"
  echo
  
  # Start sensor monitoring
  start_sensor_monitor "$HELLFIRE_TEST_NAME" "$DURATION"
  
  # Start RAM stress test
  green "  Starting RAM stress test..."
  
  if have stress-ng; then
    # Use stress-ng for maximum RAM stress
    # vm stress: Virtual memory stress (allocates and touches memory)
    # vm-bytes: Amount of memory to allocate (in bytes)
    # vm-keep: Keep memory allocated (don't free immediately)
    stress-ng \
      --vm "$(nproc)" \
      --vm-bytes "${ram_test_kb}K" \
      --vm-keep \
      --timeout "${DURATION}s" \
      --metrics-brief \
      --log-file "${LOGDIR}/$(get_timestamp)-${HOST}-ram-stress.log" &
    
    STRESS_PID=$!
    green "  stress-ng started (PID: $STRESS_PID)"
    echo
    
    # Wait for stress test to complete
    wait "$STRESS_PID" 2>/dev/null || true
    
    # Check if test was aborted
    local test_status="PASS"
    local abort_reason=""
    
    if [[ -n "${HELLFIRE_USER_ABORTED:-}" ]]; then
      # User abort was handled by cleanup handler
      exit 0
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

