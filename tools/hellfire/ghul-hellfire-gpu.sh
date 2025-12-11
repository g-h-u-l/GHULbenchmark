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
DEFAULT_DURATION=180  # 3 minutes default
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
  
  yellow "This is no benchmark, we use /msaa=5 extra flag and the FPS will be unlimited."
  yellow "This is brute force! Are you sure you want to burn your GPU, really?"
  echo
  
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
  
  # Export GPU vendor for use in print_test_summary
  export HELLFIRE_GPU_VENDOR="$gpu_vendor"
  
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
    export STRESS_PID="$stress_pid"
    green "  stress-ng GPU stressor started (PID: $stress_pid)"
  elif have gputest; then
    # Fallback: Use GpuTest FurMark for maximum GPU load
    # Note: We run it without /benchmark for permanent stress, and kill it after duration
    yellow "  ⚠️  NOTE: A FurMark window will pop up. Leave it open - it will close automatically when the test completes."
    echo
    gputest /test=fur /width=1920 /height=1080 /gpumon_terminal /msaa=5 \
      > "${LOGDIR}/$(get_timestamp)-${HOST}-gpu-stress.log" 2>&1 &
    stress_pid=$!
    export STRESS_PID="$stress_pid"
    green "  GpuTest FurMark started (PID: $stress_pid)"
    green "  Test will run for ${DURATION} seconds, then be terminated"
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
  
  # For gputest: wait for duration, then kill the process
  # For stress-ng: it will complete on its own with timeout
  if have gputest && ! (have stress-ng && stress-ng --help 2>&1 | grep -q "gpu"); then
    # gputest runs indefinitely, so we need to kill it after duration
    local start_time
    start_time="$(date +%s)"
    local end_time
    end_time=$((start_time + DURATION))
    
    # Wait for duration or until process dies (or safety stop)
    while [[ $(date +%s) -lt $end_time ]]; do
      # Check if safety stop was triggered
      local status_file="${LOGDIR}/.gpu_safety_status_${HELLFIRE_TEST_NAME}"
      if [[ -f "$status_file" ]]; then
        # Safety stop triggered - break immediately
        break
      fi
      if ! kill -0 "$stress_pid" 2>/dev/null; then
        # Process already died
        break
      fi
      sleep 1
    done
    
    # Kill the process if it's still running (more aggressively)
    if kill -0 "$stress_pid" 2>/dev/null; then
      green "  Test duration reached (${DURATION}s), terminating gputest..."
      # First try graceful termination
      kill "$stress_pid" 2>/dev/null || true
      sleep 1
      
      # If still running, try SIGTERM
      if kill -0 "$stress_pid" 2>/dev/null; then
        kill -TERM "$stress_pid" 2>/dev/null || true
        sleep 1
      fi
      
      # If still running, force kill with SIGKILL
      if kill -0 "$stress_pid" 2>/dev/null; then
        yellow "  Force killing gputest process..."
        kill -9 "$stress_pid" 2>/dev/null || true
      fi
      
      # Also kill any child processes (gputest might spawn children)
      pkill -P "$stress_pid" 2>/dev/null || true
      pkill -9 -P "$stress_pid" 2>/dev/null || true
      
      # Wait for process to die
      wait "$stress_pid" 2>/dev/null || true
      
      # Final check: kill by name if still running
      pkill -f "gputest.*fur" 2>/dev/null || true
      sleep 0.5
      pkill -9 -f "gputest.*fur" 2>/dev/null || true
    fi
  else
    # stress-ng will complete on its own
    wait "$stress_pid" 2>/dev/null || true
  fi
  
  # Stop monitoring and wait for it to finish
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  
  # Check test status (read from status file if available, fallback to env var)
  local status_file="${LOGDIR}/.gpu_safety_status_${HELLFIRE_TEST_NAME}"
  if [[ -f "$status_file" ]]; then
    local safety_status
    safety_status="$(cat "$status_file" 2>/dev/null || echo "")"
    if [[ "$safety_status" == "FAILED" ]]; then
      test_status="FAILED"
      if [[ -f "${status_file}.reason" ]]; then
        abort_reason="$(cat "${status_file}.reason" 2>/dev/null || echo "Hellfire Safety Stop triggered")"
      else
        abort_reason="Hellfire Safety Stop triggered"
      fi
      export HELLFIRE_GPU_SAFETY_FAILED=1
      export HELLFIRE_GPU_SAFETY_REASON="$abort_reason"
      red "  Test aborted due to GPU safety stop"
      # Clean up status file
      rm -f "$status_file" "${status_file}.reason" 2>/dev/null || true
    fi
  fi
  
  # Check test status (fallback to env var)
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
