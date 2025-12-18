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

# ---------- Help function -----------------------------------------------------
show_help() {
  echo "GHUL Hellfire - Extreme GPU Stress Test"
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
  echo "  Extreme GPU stress test using FurMark with high resolution (thermal load focus)."
  echo "  Monitors GPU edge, hotspot, and VRAM temperatures. Triggers safety stops"
  echo "  if critical thresholds are exceeded (VRAM > 90°C, Hotspot > 100°C)."
  echo
  echo "WARNING:"
  echo "  This is NOT a benchmark. This is hardware torture."
  echo "  Uses high resolution (2K/4K) and unlimited FPS - this is brute force!"
  echo "  Your GPU will reach maximum temperatures. Ensure adequate cooling!"
  exit 0
}

# Check for help flag
if [[ $# -ge 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_help
fi

# Test configuration
HELLFIRE_TEST_NAME="gpu"
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
  print_hellfire_warning
  
  yellow "This is no benchmark, we use high resolution and unlimited FPS."
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
  echo "Proceeding with GHUL Hellfire…"
  echo "This test can kill your GPU in a life-threatening way."
  echo "May the force be with you."
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
    
    # Check for insane mode resolution override
    local gpu_width=1920
    local gpu_height=1080
    if [[ -n "${GHUL_GPU_RESOLUTION:-}" ]]; then
      # Parse resolution from format "3840x2160" or "1920x1080"
      if [[ "$GHUL_GPU_RESOLUTION" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        gpu_width="${BASH_REMATCH[1]}"
        gpu_height="${BASH_REMATCH[2]}"
      fi
    fi
    
    # Use MSAA from environment variable (default to 0 - focus on thermal load, not driver stress)
    local msaa="${GHUL_GPU_MSAA:-0}"
    # Use prime-run for NVIDIA hybrid graphics or DRI_PRIME=1 for AMD hybrid graphics
    local gpu_launcher=""
    local gpu_env=""
    if [[ "$gpu_vendor" == "nvidia" ]] && command -v prime-run >/dev/null 2>&1; then
      gpu_launcher="prime-run "
      yellow "  Using prime-run for NVIDIA GPU"
    elif [[ "$gpu_vendor" == "amd" ]]; then
      # Check if AMD hybrid graphics (AMD dedicated + Intel integrated)
      if command -v lspci >/dev/null 2>&1; then
        local gpu_list
        gpu_list="$(lspci -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' || true)"
        if echo "$gpu_list" | grep -qi 'AMD\|ATI' && echo "$gpu_list" | grep -qi 'Intel'; then
          gpu_env="DRI_PRIME=1"
          yellow "  Using DRI_PRIME=1 for AMD GPU"
        fi
      fi
    fi
    # Use env to set DRI_PRIME if needed, or just use gpu_launcher for prime-run
    # Start in a new process group (setsid) so we can kill the entire group later
    if [[ -n "$gpu_env" ]]; then
      setsid env "$gpu_env" gputest /test=fur /width="$gpu_width" /height="$gpu_height" /gpumon_terminal /msaa="$msaa" \
        > "${LOGDIR}/$(get_timestamp)-${HOST}-gpu-stress.log" 2>&1 &
    else
      setsid ${gpu_launcher}gputest /test=fur /width="$gpu_width" /height="$gpu_height" /gpumon_terminal /msaa="$msaa" \
        > "${LOGDIR}/$(get_timestamp)-${HOST}-gpu-stress.log" 2>&1 &
    fi
    local setsid_pid=$!
    
    # Wait for gputest to actually start (setsid returns immediately)
    sleep 2
    
    # Find the actual gputest process (setsid/prime-run are just wrappers)
    local gputest_pid
    # Method 1: Find by name pattern (most reliable)
    gputest_pid="$(pgrep -f "gputest.*fur" 2>/dev/null | head -1 || true)"
    # Method 2: Find any gputest process
    if [[ -z "$gputest_pid" ]]; then
      gputest_pid="$(pgrep -f "gputest" 2>/dev/null | head -1 || true)"
    fi
    # Method 3: Find in process tree
    if [[ -z "$gputest_pid" ]]; then
      gputest_pid="$(ps aux 2>/dev/null | grep -E "[g]putest.*fur" | awk '{print $2}' | head -1 || true)"
    fi
    
    # Use the actual gputest PID for monitoring, but keep setsid_pid for killing the process group
    if [[ -n "$gputest_pid" ]]; then
      stress_pid="$gputest_pid"
      export STRESS_PID="$gputest_pid"
      export GPUTEST_PID="$gputest_pid"
      export SETSID_PID="$setsid_pid"  # Keep for process group killing
      green "  GpuTest FurMark started (gputest PID: $gputest_pid, setsid PGID: $setsid_pid)"
    else
      # Fallback: use setsid PID (not ideal, but better than nothing)
      stress_pid="$setsid_pid"
      export STRESS_PID="$setsid_pid"
      export GPUTEST_PID="$setsid_pid"
      export SETSID_PID="$setsid_pid"
      yellow "  Warning: Could not find gputest PID, using setsid PID: $setsid_pid"
      green "  GpuTest FurMark started (PID: $setsid_pid)"
    fi
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
    local status_file="${LOGDIR}/.gpu_safety_status_${HELLFIRE_TEST_NAME}"
    local early_exit_detected=0
    
    # Wait for duration or until process dies (or safety stop)
    while [[ $(date +%s) -lt $end_time ]]; do
      # Check if safety stop was triggered
      if [[ -f "$status_file" ]]; then
        # Safety stop triggered - break immediately
        break
      fi
      if ! kill -0 "$stress_pid" 2>/dev/null; then
        # Process already died (user closed window or crash)
        early_exit_detected=1
        break
      fi
      sleep 1
    done
    
    # If process ended before duration without a safety file, mark as failed/user abort
    if [[ $early_exit_detected -eq 1 ]] && [[ ! -f "$status_file" ]]; then
      local elapsed
      elapsed=$(( $(date +%s) - start_time ))
      export HELLFIRE_GPU_SAFETY_FAILED=1
      export HELLFIRE_GPU_SAFETY_REASON="GpuTest (FurMark) terminated early at ${elapsed}s (< ${DURATION}s). Likely window closed or crash; GPU load not sustained."
      echo "FAILED" > "$status_file"
      echo "${HELLFIRE_GPU_SAFETY_REASON}" > "${status_file}.reason"
      red "  🚨 EARLY TERMINATION: FurMark stopped after ${elapsed}s (< ${DURATION}s)."
    fi
    
    # Kill the process if it's still running (more aggressively)
    # Use GPUTEST_PID if available (actual gputest process), otherwise use stress_pid (prime-run wrapper)
    local kill_pid="${GPUTEST_PID:-$stress_pid}"
    
    if kill -0 "$kill_pid" 2>/dev/null || kill -0 "$stress_pid" 2>/dev/null; then
      green "  Test duration reached (${DURATION}s), terminating gputest..."
      
      # Kill the actual gputest process first
      if [[ -n "${GPUTEST_PID:-}" ]] && [[ "$GPUTEST_PID" != "$stress_pid" ]]; then
        kill "$GPUTEST_PID" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$GPUTEST_PID" 2>/dev/null; then
          kill -TERM "$GPUTEST_PID" 2>/dev/null || true
          sleep 0.5
        fi
        if kill -0 "$GPUTEST_PID" 2>/dev/null; then
          kill -9 "$GPUTEST_PID" 2>/dev/null || true
        fi
      fi
      
      # Kill prime-run wrapper if it's still running
      if kill -0 "$stress_pid" 2>/dev/null; then
        kill "$stress_pid" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$stress_pid" 2>/dev/null; then
          kill -TERM "$stress_pid" 2>/dev/null || true
          sleep 0.5
        fi
        if kill -0 "$stress_pid" 2>/dev/null; then
          kill -9 "$stress_pid" 2>/dev/null || true
        fi
      fi
      
      # Kill entire process group (important for prime-run wrapper)
      # Use SETSID_PID if available (the process group leader)
      local pgid_to_kill="${SETSID_PID:-$stress_pid}"
      if [[ -n "$pgid_to_kill" ]]; then
        # Kill the entire process group (setsid makes PID = PGID)
        kill -TERM -"$pgid_to_kill" 2>/dev/null || true
        sleep 0.5
        kill -9 -"$pgid_to_kill" 2>/dev/null || true
        # Also try to get PGID from process (fallback)
        local pgid
        pgid="$(ps -o pgid= -p "$pgid_to_kill" 2>/dev/null | tr -d ' ' || true)"
        if [[ -n "$pgid" ]] && [[ "$pgid" != "$pgid_to_kill" ]]; then
          kill -TERM -"$pgid" 2>/dev/null || true
          sleep 0.5
          kill -9 -"$pgid" 2>/dev/null || true
        fi
      fi
      
      # Also kill any child processes (gputest might spawn children)
      if [[ -n "${GPUTEST_PID:-}" ]]; then
        pkill -P "$GPUTEST_PID" 2>/dev/null || true
        pkill -9 -P "$GPUTEST_PID" 2>/dev/null || true
      fi
      pkill -P "$stress_pid" 2>/dev/null || true
      pkill -9 -P "$stress_pid" 2>/dev/null || true
      
      # Wait for processes to die
      wait "$stress_pid" 2>/dev/null || true
      if [[ -n "${GPUTEST_PID:-}" ]] && [[ "$GPUTEST_PID" != "$stress_pid" ]]; then
        wait "$GPUTEST_PID" 2>/dev/null || true
      fi
      
      # Final check: kill by name if still running (fallback - most aggressive)
      pkill -f "gputest" 2>/dev/null || true
      sleep 0.5
      pkill -9 -f "gputest" 2>/dev/null || true
      # Also kill prime-run if still running
      pkill -f "prime-run.*gputest" 2>/dev/null || true
      sleep 0.5
      pkill -9 -f "prime-run.*gputest" 2>/dev/null || true
      
      # Final fallback: Try to close X11 window if process is dead but window still open
      # Wait a moment to see if window closes on its own
      sleep 1
      # Check if any gputest processes are still running
      if ! pgrep -f "gputest" >/dev/null 2>&1; then
        # Process is dead, but window might still be open
        # Try to find and close FurMark window
        if command -v xdotool >/dev/null 2>&1; then
          xdotool search --name "FurMark" windowclose 2>/dev/null || true
          xdotool search --name "GpuTest" windowclose 2>/dev/null || true
        elif command -v wmctrl >/dev/null 2>&1; then
          wmctrl -c "FurMark" 2>/dev/null || true
          wmctrl -c "GpuTest" 2>/dev/null || true
        elif command -v xwininfo >/dev/null 2>&1; then
          # Try to find window by name and close it via xkill
          local win_id
          win_id="$(xwininfo -root -tree 2>/dev/null | grep -i "furmark\|gputest" | head -1 | awk '{print $1}' || true)"
          if [[ -n "$win_id" ]] && [[ "$win_id" =~ ^0x[0-9a-f]+$ ]]; then
            # Send close window message via xdotool or xkill
            xkill -id "$win_id" 2>/dev/null || true
          fi
        fi
        
        # If we still can't close it, warn user
        if pgrep -f "gputest" >/dev/null 2>&1 || (command -v xwininfo >/dev/null 2>&1 && xwininfo -root -tree 2>/dev/null | grep -qi "furmark\|gputest"); then
          yellow "  ⚠️  Warning: gputest process terminated, but FurMark window may still be visible."
          yellow "  Please close the window manually if it remains open."
        fi
      fi
    fi
  else
    # stress-ng will complete on its own
    wait "$stress_pid" 2>/dev/null || true
  fi
  
  # Stop monitoring and wait for it to finish
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  
  # Check test status (read from status file if available, fallback to env var)
  local abort_msg_printed=0
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
      abort_msg_printed=1
      # Clean up status file
      rm -f "$status_file" "${status_file}.reason" 2>/dev/null || true
    fi
  fi
  
  # Check test status (fallback to env var)
  if [[ -n "${HELLFIRE_USER_ABORTED:-}" ]]; then
    test_status="FAILED"
    abort_reason="User aborted (Ctrl+C)"
    red "  Test aborted by user (Ctrl+C)"
  elif [[ -n "${HELLFIRE_GPU_SAFETY_FAILED:-}" ]]; then
    test_status="FAILED"
    abort_reason="${HELLFIRE_GPU_SAFETY_REASON:-Hellfire Safety Stop triggered}"
    if [[ $abort_msg_printed -eq 0 ]]; then
      red "  Test aborted due to GPU safety stop"
    fi
    # Don't show "Test completed successfully" for safety stops
  else
    green "  Test completed successfully"
  fi
  
  stop_sensor_monitor "$HELLFIRE_TEST_NAME"
  
  print_test_summary "$HELLFIRE_TEST_NAME" "$DURATION" "$test_status" "$abort_reason"
  
  # Exit with error code if test failed
  if [[ "$test_status" == "FAILED" || "$test_status" == "ABORTED" || -n "${HELLFIRE_GPU_SAFETY_FAILED:-}" ]]; then
    exit 1
  fi
}

main "$@"
