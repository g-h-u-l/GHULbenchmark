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
  echo "Proceeding with GHUL Hellfire Cooler Test…"
  echo "This test will turn your entire system into a furnace."
  echo "All components will be stressed simultaneously."
  echo "May the force be with you."
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
      # Determine GPU resolution for cooler test (lower than GPU-only test)
      local cooler_gpu_width=1920
      local cooler_gpu_height=1080
      if [[ -n "${GHUL_COOLER_GPU_RESOLUTION:-}" ]]; then
        # Parse resolution from format "1920x1080" or "1280x720"
        if [[ "$GHUL_COOLER_GPU_RESOLUTION" =~ ^([0-9]+)x([0-9]+)$ ]]; then
          cooler_gpu_width="${BASH_REMATCH[1]}"
          cooler_gpu_height="${BASH_REMATCH[2]}"
        fi
      fi
      
      green "  Starting GPU stress (moderate, ${cooler_gpu_width}x${cooler_gpu_height}, MSAA=0)..."
      # Use prime-run for NVIDIA hybrid graphics or DRI_PRIME=1 for AMD/Nouveau hybrid graphics
      local gpu_launcher=""
      local gpu_env=""
      if [[ "$gpu_vendor" == "nvidia" ]]; then
        # Check if NVIDIA hybrid graphics (NVIDIA dedicated + Intel integrated)
        if command -v lspci >/dev/null 2>&1; then
          local gpu_list
          gpu_list="$(lspci -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' || true)"
          if echo "$gpu_list" | grep -qi 'NVIDIA' && echo "$gpu_list" | grep -qi 'Intel'; then
            # NVIDIA hybrid detected
            if command -v prime-run >/dev/null 2>&1; then
              # Check if prime-run actually works (nvidia-smi must work)
              if nvidia-smi >/dev/null 2>&1; then
                # prime-run works - use it
                gpu_launcher="prime-run "
              else
                # prime-run exists but doesn't work (GPU deactivated or Nouveau in use)
                # Try to activate GPU and use Nouveau
                local nvidia_pci
                nvidia_pci="$(lspci -nn | grep -iE '3D controller.*nvidia' | head -n1 | awk '{print $1}')"
                if [[ -n "$nvidia_pci" ]] && [[ -f "/sys/bus/pci/devices/0000:${nvidia_pci}/enable" ]]; then
                  local enable_state
                  enable_state="$(cat "/sys/bus/pci/devices/0000:${nvidia_pci}/enable" 2>/dev/null || echo "0")"
                  if [[ "$enable_state" == "0" ]]; then
                    # GPU is deactivated - try to activate it using helper script
                    local helper_script="${SCRIPT_DIR}/../ghul-enable-nvidia-gpu.sh"
                    if [[ -f "$helper_script" ]] && sudo -n "$helper_script" >/dev/null 2>&1; then
                      # Helper script exists and can run without password
                      sudo "$helper_script" >/dev/null 2>&1 || true
                    else
                      # Fallback: try direct activation (requires root, will fail without sudo)
                      echo "1" | sudo tee "/sys/bus/pci/devices/0000:${nvidia_pci}/enable" >/dev/null 2>&1 || true
                      sudo modprobe nouveau 2>/dev/null || true
                    fi
                  fi
                fi
                # For Nouveau, we can't use prime-run, but we can try DRI_PRIME=1
                gpu_env="DRI_PRIME=1"
              fi
            else
              # prime-run not available - try to activate GPU and use Nouveau
              local nvidia_pci
              nvidia_pci="$(lspci -nn | grep -iE '3D controller.*nvidia' | head -n1 | awk '{print $1}')"
              if [[ -n "$nvidia_pci" ]] && [[ -f "/sys/bus/pci/devices/0000:${nvidia_pci}/enable" ]]; then
                local enable_state
                enable_state="$(cat "/sys/bus/pci/devices/0000:${nvidia_pci}/enable" 2>/dev/null || echo "0")"
                if [[ "$enable_state" == "0" ]]; then
                  # GPU is deactivated - try to activate it using helper script
                  local helper_script="${SCRIPT_DIR}/../ghul-enable-nvidia-gpu.sh"
                  if [[ -f "$helper_script" ]] && sudo -n "$helper_script" >/dev/null 2>&1; then
                    # Helper script exists and can run without password
                    sudo "$helper_script" >/dev/null 2>&1 || true
                  else
                    # Fallback: try direct activation (requires root, will fail without sudo)
                    echo "1" | sudo tee "/sys/bus/pci/devices/0000:${nvidia_pci}/enable" >/dev/null 2>&1 || true
                    sudo modprobe nouveau 2>/dev/null || true
                  fi
                fi
              fi
              # Try DRI_PRIME=1 for Nouveau
              gpu_env="DRI_PRIME=1"
            fi
          fi
        fi
      elif [[ "$gpu_vendor" == "amd" ]]; then
        # Check if AMD hybrid graphics (AMD dedicated + Intel integrated)
        if command -v lspci >/dev/null 2>&1; then
          local gpu_list
          gpu_list="$(lspci -nn 2>/dev/null | grep -iE 'VGA compatible controller|3D controller' || true)"
          if echo "$gpu_list" | grep -qi 'AMD\|ATI' && echo "$gpu_list" | grep -qi 'Intel'; then
            gpu_env="DRI_PRIME=1"
          fi
        fi
      fi
      # Use env to set DRI_PRIME if needed, or just use gpu_launcher for prime-run
      # Start in a new process group (setsid) so we can kill the entire group later
      if [[ -n "$gpu_env" ]]; then
        setsid env "$gpu_env" gputest /test=fur /width="$cooler_gpu_width" /height="$cooler_gpu_height" /msaa=0 /gpumon_terminal \
          > "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-gpu.log" 2>&1 &
      else
        setsid ${gpu_launcher}gputest /test=fur /width="$cooler_gpu_width" /height="$cooler_gpu_height" /msaa=0 /gpumon_terminal \
          > "${LOGDIR}/$(get_timestamp)-${HOST}-cooler-gpu.log" 2>&1 &
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
        gpu_pid="$gputest_pid"
        export GPUTEST_PID="$gputest_pid"
        export SETSID_PID="$setsid_pid"  # Keep for process group killing
        green "    GPU stress started (gputest PID: $gputest_pid, setsid PGID: $setsid_pid)"
      else
        # Fallback: use setsid PID (not ideal, but better than nothing)
        gpu_pid="$setsid_pid"
        export GPUTEST_PID="$setsid_pid"
        export SETSID_PID="$setsid_pid"
        yellow "    Warning: Could not find gputest PID, using setsid PID: $setsid_pid"
        green "    GPU stress started (PID: $setsid_pid)"
      fi
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
  local cooler_status_reason=""
  local cooler_failed=0
  
  green "  Test running... (${DURATION} seconds)"
  echo
  
  # Wait for duration or until process dies
  while [[ $(date +%s) -lt $end_time ]]; do
    # Check if safety stop was triggered
    if [[ -f "${LOGDIR}/.cooler_safety_status_${HELLFIRE_TEST_NAME}" ]]; then
      # Safety stop triggered - break immediately
      cooler_failed=1
      break
    fi
    
    # Check if any critical process died (but only if it's truly early, not at timeout)
    elapsed=$(( $(date +%s) - start_time ))
    time_remaining=$((DURATION - elapsed))
    
    # Only mark as "early" if process died with more than 5 seconds remaining
    # stress-ng with --timeout will end exactly at the timeout, so we allow ±2 seconds
    if [[ -n "$cpu_pid" ]] && ! kill -0 "$cpu_pid" 2>/dev/null; then
      if [[ $elapsed -lt $((DURATION - 5)) ]]; then
        yellow "  CPU stress process ended early (${elapsed}s / ${DURATION}s)"
        cooler_failed=1
        cooler_status_reason="CPU stress terminated early at ${elapsed}s (before ${DURATION}s)"
        break
      fi
      # Process ended near timeout - this is normal for stress-ng with --timeout
      # Don't mark as failed, just continue
    fi
    if [[ -n "$ram_pid" ]] && ! kill -0 "$ram_pid" 2>/dev/null; then
      if [[ $elapsed -lt $((DURATION - 5)) ]]; then
        yellow "  RAM stress process ended early (${elapsed}s / ${DURATION}s)"
        cooler_failed=1
        cooler_status_reason="RAM stress terminated early at ${elapsed}s (before ${DURATION}s)"
        break
      fi
      # Process ended near timeout - this is normal for stress-ng with --timeout
      # Don't mark as failed, just continue
    fi
    if [[ -n "$gpu_pid" ]] && ! kill -0 "$gpu_pid" 2>/dev/null; then
      if [[ $elapsed -lt $((DURATION - 5)) ]]; then
        yellow "  GPU stress process ended early (${elapsed}s / ${DURATION}s)"
        cooler_failed=1
        cooler_status_reason="GPU stress (FurMark) terminated early at ${elapsed}s (before ${DURATION}s). Likely window closed or crash; GPU load not sustained."
        break
      fi
      # Process ended near timeout - this is normal
      # Don't mark as failed, just continue
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
  # Use GPUTEST_PID if available (actual gputest process), otherwise use gpu_pid (prime-run wrapper)
  local kill_pid="${GPUTEST_PID:-$gpu_pid}"
  
  if [[ -n "$gpu_pid" ]]; then
    # Kill the actual gputest process first
    if [[ -n "${GPUTEST_PID:-}" ]] && [[ "$GPUTEST_PID" != "$gpu_pid" ]]; then
      kill "$GPUTEST_PID" 2>/dev/null || true
      sleep 0.5
      if kill -0 "$GPUTEST_PID" 2>/dev/null; then
        kill -TERM "$GPUTEST_PID" 2>/dev/null || true
        sleep 0.5
      fi
      if kill -0 "$GPUTEST_PID" 2>/dev/null; then
        kill -9 "$GPUTEST_PID" 2>/dev/null || true
      fi
      pkill -P "$GPUTEST_PID" 2>/dev/null || true
      pkill -9 -P "$GPUTEST_PID" 2>/dev/null || true
      wait "$GPUTEST_PID" 2>/dev/null || true
    fi
    
    # Kill entire process group (important for prime-run wrapper)
    # Use SETSID_PID if available (the process group leader)
    local pgid_to_kill="${SETSID_PID:-$gpu_pid}"
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
      
      # Also kill prime-run wrapper directly
      if kill -0 "$gpu_pid" 2>/dev/null; then
        kill "$gpu_pid" 2>/dev/null || true
        sleep 0.5
        if kill -0 "$gpu_pid" 2>/dev/null; then
          kill -TERM "$gpu_pid" 2>/dev/null || true
          sleep 0.5
        fi
        if kill -0 "$gpu_pid" 2>/dev/null; then
          kill -9 "$gpu_pid" 2>/dev/null || true
        fi
        pkill -P "$gpu_pid" 2>/dev/null || true
        pkill -9 -P "$gpu_pid" 2>/dev/null || true
        wait "$gpu_pid" 2>/dev/null || true
      fi
    fi
    
    # Final fallback: kill by name (catches any remaining gputest processes)
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
  
  # Kill disk stress
  if [[ -n "$disk_pid" ]]; then
    kill "$disk_pid" 2>/dev/null || true
    wait "$disk_pid" 2>/dev/null || true
  fi
  
  # If a process died early and no safety stop was triggered, mark as failed
  # But only if it was truly early (not near timeout)
  if [[ $cooler_failed -eq 1 ]] && [[ -n "$cooler_status_reason" ]]; then
    export HELLFIRE_COOLER_SAFETY_FAILED=1
    export HELLFIRE_COOLER_SAFETY_REASON="${cooler_status_reason}"
    red "  🚨 EARLY TERMINATION: ${cooler_status_reason}"
  fi
  
  # Kill any remaining stress-ng processes
  killall stress-ng 2>/dev/null || true
  
  # Stop monitoring
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  
  # Check test status
  local abort_msg_printed=0
  if [[ -n "${HELLFIRE_USER_ABORTED:-}" ]]; then
    test_status="FAILED"
    abort_reason="User aborted (Ctrl+C)"
    red "  Test aborted by user (Ctrl+C)"
    abort_msg_printed=1
  elif [[ -n "${HELLFIRE_COOLER_SAFETY_FAILED:-}" ]]; then
    test_status="FAILED"
    abort_reason="${HELLFIRE_COOLER_SAFETY_REASON:-Cooler Safety Stop triggered}"
    red "  Test aborted due to safety stop"
    abort_msg_printed=1
  else
    green "  Test completed successfully"
  fi
  
  # Stop sensor monitoring
  stop_sensor_monitor "$HELLFIRE_TEST_NAME"
  
  # Print summary
  print_cooler_summary "$HELLFIRE_TEST_NAME" "$DURATION" "$test_status" "$abort_reason"
  
  # Exit with error code if test failed
  if [[ "$test_status" == "FAILED" || "$test_status" == "ABORTED" || -n "${HELLFIRE_COOLER_SAFETY_FAILED:-}" ]]; then
    exit 1
  fi
}

main "$@"
