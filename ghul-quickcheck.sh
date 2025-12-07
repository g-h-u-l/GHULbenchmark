#!/usr/bin/env bash
# GHUL - Gaming Hardware Using Linux
# quickview.sh
# Local summary + rating for a given GHULbenchmark JSON result.
#
# Usage:
#   ./quickview.sh 2025-11-29-13-39-sharkoon.json
#   ./quickview.sh results/2025-11-29-13-39-sharkoon.json
#
# If no path separator ("/") is present, "results/" is prepended.
#
# Comments in English, output in English only.
# Locale is forced to C for predictable parsing.

set -euo pipefail

# Enforce predictable C locale
export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

# ---------- helpers ------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

red()    { printf '\e[31m%s\e[0m\n' "$*"; }
green()  { printf '\e[32m%s\e[0m\n' "$*"; }
yellow() { printf '\e[33m%s\e[0m\n' "$*"; }
cyan()   { printf '\e[36m%s\e[0m\n' "$*"; }
bold()   { printf '\e[1m%s\e[0m' "$*"; }
green_text() { printf '\e[32m%s\e[0m' "$*"; }

headline() {
  echo
  cyan "== $* =="
  echo
}

# Small safe jq wrapper: returns empty string on error
jqr() {
  local filter="$1"
  local file="$2"
  jq -r "$filter" "$file" 2>/dev/null || echo ""
}

# ---------- preflight ----------------------------------------------------------

if [[ ! -d "results" || ! -d "logs" ]]; then
  red "[GHUL] Please run this script from your GHULbenchmark directory."
  echo "[GHUL] Expected ./results and ./logs here."
  exit 1
fi

if ! have jq; then
  red "[GHUL] jq is required for quickview.sh"
  echo "      Install on Arch/Manjaro with: sudo pacman -S jq"
  exit 1
fi

# ---------- result file selection ---------------------------------------------

if [[ $# -lt 1 ]]; then
  red "[GHUL] No benchmark JSON file specified."
  echo
  echo "Usage:"
  echo "  ./ghul-quickcheck.sh <result.json | directory>"
  echo
  echo "Examples:"
  echo "  ./ghul-quickcheck.sh 2025-11-29-13-39-sharkoon.json"
  echo "  ./ghul-quickcheck.sh results/"
  echo "  ./ghul-quickcheck.sh results"
  echo
  echo "Notes:"
  echo "  - If you pass a filename without '/', quickcheck assumes it is inside 'results/'."
  echo "  - If you pass a directory, quickcheck will automatically pick the newest JSON inside it."
  exit 1
fi

ARG="$1"

# Case 1: argument is a directory → pick newest JSON inside it
if [[ -d "$ARG" ]]; then
  # normalize directory (remove trailing slash for ls, but doesn't matter here)
  dir="$ARG"
  RESULT_FILE=$(ls -1 "$dir"/*.json 2>/dev/null | sort | tail -n1 || true)

  if [[ -z "$RESULT_FILE" ]]; then
    red "[GHUL] No JSON files found in directory:"
    echo "       $dir"
    exit 1
  fi

  echo "[GHUL] Using newest JSON from directory:"
  echo "       $RESULT_FILE"

else
  # Case 2: argument contains "/" → treat as explicit file path
  if [[ "$ARG" == */* ]]; then
    RESULT_FILE="$ARG"
  else
    # Case 3: plain filename → assume inside results/
    RESULT_FILE="results/$ARG"
  fi

  if [[ ! -f "$RESULT_FILE" ]]; then
    red "[GHUL] Result file not found:"
    echo "       $RESULT_FILE"
    echo
    echo "Make sure you pass an existing JSON file or a directory containing JSON results."
    exit 1
  fi

  echo "[GHUL] Using result file:"
  echo "       $RESULT_FILE"
fi


# ---------- extract core info --------------------------------------------------

# Read Json
host="$(jqr '.environment.hostname // "unknown"' "$RESULT_FILE")"
ts="$(jqr '.environment.timestamp // "unknown"' "$RESULT_FILE")"
os="$(jqr '.environment.os // "unknown"' "$RESULT_FILE")"
kernel="$(jqr '.environment.kernel // "unknown"' "$RESULT_FILE")"
cpu_model="$(jqr '.environment.cpu // "unknown"' "$RESULT_FILE")"
threads="$(jqr '.environment.threads // 0' "$RESULT_FILE")"
mem_kib="$(jqr '.environment.mem_total_kib // 0' "$RESULT_FILE")"
gpu_man="$(jqr '.environment.gpu_manufacturer // "unknown"' "$RESULT_FILE")"
gpu_model="$(jqr '.environment.gpu_model // "unknown"' "$RESULT_FILE")"

# GPU assessment
glmark2="$(jqr '.gpu.glmark2_score // 0' "$RESULT_FILE")"
vkmark="$(jq -r '.gpu.vkmark_score // empty' "$RESULT_FILE")"
vkmark_note="$(jq -r '.gpu.vkmark_note // empty' "$RESULT_FILE")"
gputest_score="$(jqr '.gpu.gputest_fur.score // 0' "$RESULT_FILE")"
gputest_fps="$(jqr '.gpu.gputest_fur.fps // 0' "$RESULT_FILE")"

# CPU assesment
p7_mips="$(jqr '.cpu.p7zip_tot_mips // 0' "$RESULT_FILE")"
stress_matrix="$(jqr '.cpu.stressng_matrix_bogo_ops // 0' "$RESULT_FILE")"
stress_crypt="$(jqr '.cpu.stressng_crypt_bogo_ops // 0' "$RESULT_FILE")"

# RAM assesment
mbw_gib="$(jqr '.ram.mbw_memcpy_gib_s // 0' "$RESULT_FILE")"
sysbench_mib="$(jqr '.ram.sysbench_seq_write_mib_s // 0' "$RESULT_FILE")"
# Added RAM speed information
ram_speed_mhz=$(jq '.ram.ram_speed_mhz // 0' "$RESULT_FILE")
ram_speed_mts=$(jq '.ram.ram_speed_mts // 0' "$RESULT_FILE")
# fix 0 RAM 
if (( $(printf "%.0f" "$ram_speed_mts") == 0 )); then
  ram_speed_str="n/a"
else
  ram_speed_str="${ram_speed_mts} MT/s (${ram_speed_mhz} MHz)"
fi


# NET assessment
tcp_mbps="$(jqr '.network.tcp_mbps // 0' "$RESULT_FILE")"
udp_mbps="$(jqr '.network.udp_mbps // 0' "$RESULT_FILE")"
net_dl="$(jqr '.network.internet_download_mbps // 0' "$RESULT_FILE")"
net_ul="$(jqr '.network.internet_upload_mbps // 0' "$RESULT_FILE")"

# STORAGE assessment - get sensor log for temperatures
BENCH_NAME="$(basename "$RESULT_FILE")"
BENCH_PREFIX="$(echo "$BENCH_NAME" | cut -d'-' -f1-5)"
SENS_FILE="$(ls -1t "logs/sensors/${BENCH_PREFIX}"*-sensors.jsonl 2>/dev/null | head -n1 || true)"

# machine identificatiion
host_id="$(jqr '.environment.ghul_host.id // "missing"' "$RESULT_FILE")"
host_mb_vendor="$(jqr '.environment.ghul_host.vendor // "missing"' "$RESULT_FILE")"
host_mb_product="$(jqr '.environment.ghul_host.product // "missing"' "$RESULT_FILE")"

# Derived values
mem_gib=$(awk "BEGIN{printf \"%.1f\", ${mem_kib}/1048576}" 2>/dev/null || echo "0.0")

# numeric helpers (for thresholds)
n_glmark2=$(printf "%.0f" "${glmark2:-0}" 2>/dev/null || echo 0)
# Handle vkmark: if null or empty, treat as 0 for rating purposes
if [[ -z "$vkmark" || "$vkmark" == "null" ]]; then
  n_vkmark=0
else
  n_vkmark=$(printf "%.0f" "${vkmark:-0}" 2>/dev/null || echo 0)
fi
n_gputest_fps=$(printf "%.0f" "${gputest_fps:-0}" 2>/dev/null || echo 0)
n_p7=$(printf "%.0f" "${p7_mips:-0}" 2>/dev/null || echo 0)
n_mbw=$(awk "BEGIN{printf \"%.1f\", ${mbw_gib}}" 2>/dev/null || echo 0)
n_tcp=$(awk "BEGIN{printf \"%.1f\", ${tcp_mbps}}" 2>/dev/null || echo 0)
n_dl=$(awk "BEGIN{printf \"%.1f\", ${net_dl}}" 2>/dev/null || echo 0)

# ---------- rating logic (rough heuristics) ------------------------------------

rate_cpu="unknown"
if (( n_p7 >= 80000 )); then
  rate_cpu="High-end CPU – ready for heavy 144 Hz gaming and streaming."
elif (( n_p7 >= 50000 )); then
  rate_cpu="Upper midrange – very good for 1080p/1440p gaming."
elif (( n_p7 >= 30000 )); then
  rate_cpu="Solid midrange – 1080p gaming with slightly reduced details."
elif (( n_p7 > 0 )); then
  rate_cpu="Entry-level / older CPU – playable, but can bottleneck modern GPUs."
else
  rate_cpu="No CPU benchmark data available."
fi

rate_gpu="unknown"
if (( n_glmark2 >= 15000 || n_gputest_fps >= 250 )); then
  rate_gpu="Strong GPU – 1080p/1440p high settings are absolutely fine."
elif (( n_glmark2 >= 8000 || n_gputest_fps >= 150 )); then
  rate_gpu="Good midrange GPU – 1080p high/ultra is usually no problem."
elif (( n_glmark2 >= 4000 || n_gputest_fps >= 80 )); then
  rate_gpu="Decent entry/mid GPU – 1080p medium/high is realistic."
elif (( n_glmark2 > 0 || n_gputest_fps > 0 )); then
  rate_gpu="Weaker GPU – focus on eSports/older titles or reduced settings."
else
  rate_gpu="No GPU benchmark data available."
fi

rate_ram="unknown"
ram_bw="$(printf '%.1f' "$mbw_gib" 2>/dev/null || echo 0)"
if (( $(printf "%.0f" "$ram_bw") >= 35 )); then
  rate_ram="Very high RAM bandwidth – tuned DDR4 or modern DDR5-level."
elif (( $(printf "%.0f" "$ram_bw") >= 20 )); then
  rate_ram="Good RAM bandwidth – absolutely fine for current gaming."
elif (( $(printf "%.0f" "$ram_bw") >= 10 )); then
  rate_ram="Decent RAM bandwidth – fine for gaming, but faster kits or tuning could improve 1% lows."
elif (( $(printf "%.0f" "$ram_bw") >= 6 )); then
  rate_ram="Moderate RAM bandwidth – still okay for gaming but could be improved."
elif (( $(printf "%.0f" "$ram_bw") > 0 )); then
  rate_ram="Low RAM bandwidth – configuration or RAM speed may significantly limit modern GPUs."
else
  rate_ram="No RAM bandwidth data available."
fi


rate_net="unknown"
if (( $(printf "%.0f" "$n_tcp") >= 50000 )); then
  rate_net="Loopback performance is very strong – network stack and NIC look healthy."
elif (( $(printf "%.0f" "$n_tcp") >= 10000 )); then
  rate_net="Loopback performance is fine – no obvious bottlenecks."
elif (( $(printf "%.0f" "$n_tcp") > 0 )); then
  rate_net="Loopback performance is rather low – check stack/firewall/offloading."
else
  rate_net="No local network data available."
fi

rate_inet="unknown"
if (( $(printf "%.0f" "$n_dl") >= 200 )); then
  rate_inet="Very fast internet connection – downloads will not be a problem."
elif (( $(printf "%.0f" "$n_dl") >= 50 )); then
  rate_inet="Good internet connection – online gaming and downloads are relaxed."
elif (( $(printf "%.0f" "$n_dl") >= 16 )); then
  rate_inet="Sufficient connection – online gaming is fine, big downloads take some time."
elif (( $(printf "%.0f" "$n_dl") > 0 )); then
  rate_inet="Slow connection – online gaming is possible but sensitive to spikes."
else
  rate_inet="No internet speed test data available."
fi

# ---------- output -------------------------------------------------------------

headline "GHUL quickview – system profile"

echo "Host:           $host"
echo "$(bold "GHUL Host ID:")   $(green_text "$host_id")"
echo "Timestamp:      $ts"
echo "OS / Kernel:    $os  /  $kernel"
echo "CPU:            $cpu_model  (${threads} threads)"
echo "RAM (physical): ${mem_gib} GiB"
echo "GPU:            ${gpu_man} ${gpu_model}"
echo "Mainboard:      ${host_mb_vendor} / ${host_mb_product}"

headline "CPU assessment"

echo "7-Zip MIPS:          $p7_mips"
echo "stress-ng matrix:    $stress_matrix bogo-ops"
echo "stress-ng crypt:     $stress_crypt bogo-ops"
echo
echo "CPU rating:          $rate_cpu"

# CPU temperature warnings
if [[ -n "$SENS_FILE" && -f "$SENS_FILE" ]]; then
  RUN_START_EPOCH="$(jq -r '.timeline[]? | select(.name=="run_start") | .epoch' "$RESULT_FILE" | head -n1 || jq -r '.timeline[0].epoch // empty' "$RESULT_FILE" || echo "")"
  SENS_LAST_TS="$(jq -r 'select(.timestamp != null) | .timestamp' "$SENS_FILE" | tail -n1 || echo "")"
  
  if [[ -n "$RUN_START_EPOCH" && -n "$SENS_LAST_TS" ]]; then
    cpu_temps=$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" '
      select(.timestamp >= $s and .timestamp <= $e)
      | .cpu_temp_c // empty
      | select(. != null)
    ' "$SENS_FILE" 2>/dev/null || true)
    
    if [[ -n "$cpu_temps" ]]; then
      cpu_max=$(echo "$cpu_temps" | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}')
      cpu_avg=$(echo "$cpu_temps" | awk '{sum+=$1; cnt++} END{if(cnt>0) printf "%.1f", sum/cnt; else print "0"}')
      
      if (( $(echo "$cpu_max >= 100.0" | bc -l) )); then
        echo "$(red "CPU temperature:     max=${cpu_max}°C, avg=${cpu_avg}°C")"
        echo "$(red "                     ⚠ CRITICAL: CPU overheating! Check thermal paste and cooling immediately!")"
      elif (( $(echo "$cpu_max > 80.0" | bc -l) )); then
        echo "$(yellow "CPU temperature:     max=${cpu_max}°C, avg=${cpu_avg}°C")"
        echo "$(yellow "                     ⚠ WARNING: CPU temp high, check cooling")"
      else
        echo "CPU temperature:     max=${cpu_max}°C, avg=${cpu_avg}°C"
      fi
      echo
    fi
  fi
fi

headline "RAM assessment"

echo "mbw memcpy:          ${mbw_gib} GiB/s"
echo "sysbench seq write:  ${sysbench_mib} MiB/s"
echo "RAM speed:           ${ram_speed_str}"
echo

############################################
# RAM layout / channels / per-module info
############################################

# Count populated modules (size contains "GB")
ram_module_count=$(jq '[.ram.memory_devices[]
                         | select(.size // "" | test("No Module Installed") | not)
                       ] | length' "$RESULT_FILE")

# Count distinct channels from bank_locator, e.g. "P0 CHANNEL A" -> "A"
ram_channel_count=$(jq '[.ram.memory_devices[]
                         | select(.size // "" | test("No Module Installed") | not)
                         | (.bank_locator // "" | split(" ") | last)
                       ] | unique | length' "$RESULT_FILE")

dual_info="Unknown RAM layout"

if (( ram_module_count == 0 )); then
  dual_info="No populated DIMM slots reported."
elif (( ram_module_count == 1 )); then
  dual_info="Single-module configuration – effectively single-channel."
elif (( ram_channel_count >= 3 )); then
  dual_info="${ram_module_count} modules across ${ram_channel_count} channels – multi-channel (3+), very likely optimal."
elif (( ram_channel_count == 2 )); then
  dual_info="${ram_module_count} modules across 2 channels – dual-channel very likely active."
else
  dual_info="${ram_module_count} modules – layout is mixed, dual-channel status unclear."
fi

echo "RAM layout:         ${dual_info}"
echo "RAM modules:"
jq -r '
  .ram.memory_devices
  | map(select(.size // "" | test("No Module Installed") | not))
  | if length == 0 then
      "  (no active modules reported)"
    else
      (
        .[]
        | "  - " +
          (.locator        // "DIMM ?") + " | " +
          (.bank_locator   // "Bank ?") + " | " +
          (.size           // "unknown size") + " | " +
          (.type           // "unknown type") + " | " +
          (.speed          // .configured_memory_speed // "unknown speed") + " | " +
          (.manufacturer   // "unknown vendor") + " " +
          (.part_number    // "")
      )
    end
' "$RESULT_FILE"
echo
echo "RAM rating:          $rate_ram"

headline "GPU assessment"

echo "glmark2 score:       $glmark2"
if [[ -z "$vkmark" || "$vkmark" == "null" ]]; then
  if [[ -n "$vkmark_note" && "$vkmark_note" != "null" ]]; then
    echo "vkmark score:        null ($vkmark_note)"
  else
    echo "vkmark score:        null (not available)"
  fi
else
  echo "vkmark score:        $vkmark"
fi
echo "GpuTest FurMark:     score=$gputest_score, FPS=$gputest_fps"
echo
echo "GPU rating:          $rate_gpu"

# GPU temperature warnings
if [[ -n "$SENS_FILE" && -f "$SENS_FILE" ]]; then
  RUN_START_EPOCH="$(jq -r '.timeline[]? | select(.name=="run_start") | .epoch' "$RESULT_FILE" | head -n1 || jq -r '.timeline[0].epoch // empty' "$RESULT_FILE" || echo "")"
  SENS_LAST_TS="$(jq -r 'select(.timestamp != null) | .timestamp' "$SENS_FILE" | tail -n1 || echo "")"
  
  if [[ -n "$RUN_START_EPOCH" && -n "$SENS_LAST_TS" ]]; then
    # GPU Edge temperature
    gpu_temps=$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" '
      select(.timestamp >= $s and .timestamp <= $e)
      | .gpu_temp_c // empty
      | select(. != null)
    ' "$SENS_FILE" 2>/dev/null || true)
    
    if [[ -n "$gpu_temps" ]]; then
      gpu_max=$(echo "$gpu_temps" | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}')
      gpu_avg=$(echo "$gpu_temps" | awk '{sum+=$1; cnt++} END{if(cnt>0) printf "%.1f", sum/cnt; else print "0"}')
      
      if (( $(echo "$gpu_max >= 95.0" | bc -l) )); then
        echo "$(red "GPU edge temp:        max=${gpu_max}°C, avg=${gpu_avg}°C")"
        echo "$(red "                     ⚠ CRITICAL: GPU overheating! Check thermal paste and cooling immediately!")"
      elif (( $(echo "$gpu_max > 85.0" | bc -l) )); then
        echo "$(yellow "GPU edge temp:        max=${gpu_max}°C, avg=${gpu_avg}°C")"
        echo "$(yellow "                     ⚠ WARNING: GPU temp high, check cooling")"
      else
        echo "GPU edge temp:        max=${gpu_max}°C, avg=${gpu_avg}°C"
      fi
    fi
    
    # GPU Hotspot temperature
    gpu_hotspot_temps=$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" '
      select(.timestamp >= $s and .timestamp <= $e)
      | .gpu_hotspot_c // empty
      | select(. != null)
    ' "$SENS_FILE" 2>/dev/null || true)
    
    if [[ -n "$gpu_hotspot_temps" ]]; then
      hotspot_max=$(echo "$gpu_hotspot_temps" | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}')
      hotspot_avg=$(echo "$gpu_hotspot_temps" | awk '{sum+=$1; cnt++} END{if(cnt>0) printf "%.1f", sum/cnt; else print "0"}')
      
      if (( $(echo "$hotspot_max >= 110.0" | bc -l) )); then
        echo "$(red "GPU hotspot temp:     max=${hotspot_max}°C, avg=${hotspot_avg}°C")"
        echo "$(red "                     ⚠ CRITICAL: GPU hotspot overheating! Check thermal paste and cooling immediately!")"
      elif (( $(echo "$hotspot_max > 100.0" | bc -l) )); then
        echo "$(yellow "GPU hotspot temp:     max=${hotspot_max}°C, avg=${hotspot_avg}°C")"
        echo "$(yellow "                     ⚠ WARNING: GPU hotspot temp high, check cooling")"
      else
        echo "GPU hotspot temp:     max=${hotspot_max}°C, avg=${hotspot_avg}°C"
      fi
    fi
    
    # GPU Memory temperature
    gpu_mem_temps=$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" '
      select(.timestamp >= $s and .timestamp <= $e)
      | .gpu_memtemp_c // empty
      | select(. != null)
    ' "$SENS_FILE" 2>/dev/null || true)
    
    if [[ -n "$gpu_mem_temps" ]]; then
      mem_max=$(echo "$gpu_mem_temps" | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}')
      mem_avg=$(echo "$gpu_mem_temps" | awk '{sum+=$1; cnt++} END{if(cnt>0) printf "%.1f", sum/cnt; else print "0"}')
      
      if (( $(echo "$mem_max >= 100.0" | bc -l) )); then
        echo "$(red "GPU memory temp:      max=${mem_max}°C, avg=${mem_avg}°C")"
        echo "$(red "                     ⚠ CRITICAL: GPU memory overheating! Check cooling immediately!")"
      elif (( $(echo "$mem_max > 90.0" | bc -l) )); then
        echo "$(yellow "GPU memory temp:      max=${mem_max}°C, avg=${mem_avg}°C")"
        echo "$(yellow "                     ⚠ WARNING: GPU memory temp high, check cooling")"
      else
        echo "GPU memory temp:      max=${mem_max}°C, avg=${mem_avg}°C"
      fi
    fi
    
    echo
  fi
fi

headline "Network"

echo "Loopback TCP:        ${tcp_mbps} Mbit/s"
echo "Loopback UDP:        ${udp_mbps} Mbit/s"
echo "Internet download:   ${net_dl} Mbit/s"
echo "Internet upload:     ${net_ul} Mbit/s"
echo
echo "Local network:       $rate_net"
echo "Internet connection: $rate_inet"

headline "Storage assessment"

# Initialize storage rating
rate_storage="No storage benchmark data available."

# Check if storage data exists
storage_count=$(jq '[.storage[]?] | length' "$RESULT_FILE" 2>/dev/null || echo 0)

if (( storage_count == 0 )); then
  yellow "No storage benchmark data available."
else
  # Display storage devices with performance metrics
  jq -r '
    .storage[]?
    | "Device:             \(.device // "unknown")"
    + " (\(.model // "unknown model"))"
    + "\n  Mount point:        \(.mount_point // "n/a")"
    + "\n  Sequential read:    \(.sequential_read_mbps // 0) MB/s"
    + "\n  Sequential write:   \(.sequential_write_mbps // 0) MB/s"
    + "\n  Random 4K read:      \(.random_4k_read_mbps // 0) MB/s"
    + "\n  Random 4K write:     \(.random_4k_write_mbps // 0) MB/s"
  ' "$RESULT_FILE"
  
  echo
  
  # Get storage temperatures from sensor log if available
  if [[ -n "$SENS_FILE" && -f "$SENS_FILE" ]]; then
    # Get timeline from benchmark JSON
    RUN_START_EPOCH="$(jq -r '.timeline[]? | select(.name=="run_start") | .epoch' "$RESULT_FILE" | head -n1 || jq -r '.timeline[0].epoch // empty' "$RESULT_FILE" || echo "")"
    SENS_LAST_TS="$(jq -r 'select(.timestamp != null) | .timestamp' "$SENS_FILE" | tail -n1 || echo "")"
    
    if [[ -n "$RUN_START_EPOCH" && -n "$SENS_LAST_TS" ]]; then
      # Get all storage devices from sensor log
      storage_devices=$(jq -r '
        select(.timestamp >= ($start | tonumber) and .timestamp <= ($end | tonumber))
        | .storage_temps // {}
        | keys[]
      ' --arg start "$RUN_START_EPOCH" --arg end "$SENS_LAST_TS" "$SENS_FILE" 2>/dev/null | sort -u || true)
      
      if [[ -n "$storage_devices" ]]; then
        echo "Storage temperatures:"
        while IFS= read -r device; do
          [[ -z "$device" ]] && continue
          
          # Get min/max/avg for this device
          values=$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" --arg dev "$device" '
            select(.timestamp >= $s and .timestamp <= $e)
            | .storage_temps[$dev] // empty
            | select(. != null)
          ' "$SENS_FILE" 2>/dev/null || true)
          
          if [[ -n "$values" ]]; then
            # Calculate stats
            min=$(echo "$values" | awk 'BEGIN{min=999} {if($1<min) min=$1} END{print min}')
            max=$(echo "$values" | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}')
            avg=$(echo "$values" | awk '{sum+=$1; cnt++} END{if(cnt>0) printf "%.1f", sum/cnt; else print "0"}')
            
            # Get label for device
            label=""
            mount_point=$(df -T 2>/dev/null | awk -v base="/dev/${device}" '$1 ~ "^" base "[0-9]+" && $NF != "/" && $NF !~ /\/boot/ {print $NF; exit}')
            if [[ -z "$mount_point" ]]; then
              base_device=$(echo "$device" | sed -E 's/([a-z]+)([0-9]+).*/\1/')
              model=$(lsblk -o NAME,MODEL -d -n 2>/dev/null | awk -v dev="$base_device" '$1 == dev {for(i=2;i<=NF;i++) printf "%s ", $i; print ""; exit}' | sed 's/[[:space:]]*$//')
              if [[ -n "$model" ]]; then
                label=" ($model)"
              fi
            else
              label=" ($(basename "$mount_point"))"
            fi
            
            # Temperature rating
            temp_rating=""
            temp_warning=""
            if (( $(echo "$max >= 70.0" | bc -l) )); then
              temp_rating="$(red "CRITICAL")"
              temp_warning=" – ⚠ CRITICAL: Storage overheating! Check airflow immediately!"
            elif (( $(echo "$max > 55.0" | bc -l) )); then
              temp_rating="$(yellow "WARNING")"
              temp_warning=" – ⚠ WARNING: Storage temp high, check airflow"
            else
              temp_rating="$(green "Good")"
            fi
            
            echo "  ${device}${label}: min=${min}°C, avg=${avg}°C, max=${max}°C ${temp_rating}${temp_warning}"
          fi
        done <<<"$storage_devices"
        echo
      fi
    fi
  fi
  
  # Storage performance rating (based on sequential read/write)
  # Get best performing device for overall rating
  best_seq_read=$(jq '[.storage[]? | .sequential_read_mbps // 0] | max' "$RESULT_FILE" 2>/dev/null || echo 0)
  best_seq_write=$(jq '[.storage[]? | .sequential_write_mbps // 0] | max' "$RESULT_FILE" 2>/dev/null || echo 0)
  best_rand4k_read=$(jq '[.storage[]? | .random_4k_read_mbps // 0] | max' "$RESULT_FILE" 2>/dev/null || echo 0)
  
  n_seq_read=$(printf "%.0f" "${best_seq_read:-0}" 2>/dev/null || echo 0)
  n_seq_write=$(printf "%.0f" "${best_seq_write:-0}" 2>/dev/null || echo 0)
  n_rand4k_read=$(printf "%.0f" "${best_rand4k_read:-0}" 2>/dev/null || echo 0)
  
  rate_storage="unknown"
  if (( n_seq_read >= 3000 && n_seq_write >= 2000 )); then
    rate_storage="Excellent storage performance – NVMe-level speeds, perfect for gaming and large file operations."
  elif (( n_seq_read >= 500 && n_seq_write >= 400 )); then
    rate_storage="Very good storage performance – modern SATA SSD-level, excellent for gaming."
  elif (( n_seq_read >= 200 && n_seq_write >= 150 )); then
    rate_storage="Good storage performance – decent SATA SSD, fine for gaming but loading times may be noticeable."
  elif (( n_seq_read >= 100 && n_seq_write >= 80 )); then
    rate_storage="Moderate storage performance – older SSD or fast HDD, acceptable for gaming but consider upgrade."
  elif (( n_seq_read > 0 || n_seq_write > 0 )); then
    rate_storage="Low storage performance – likely HDD or very old SSD, will significantly impact loading times."
  else
    rate_storage="No storage benchmark data available."
  fi
  
  echo "Storage rating:      $rate_storage"
fi

headline "GHUL overall impression"

echo "Summary:"
echo "- CPU:     $rate_cpu"
echo "- RAM:     $rate_ram"
echo "- GPU:     $rate_gpu"
if [[ -n "${rate_storage:-}" && "$rate_storage" != "No storage benchmark data available." ]]; then
  echo "- Storage: $rate_storage"
fi
echo "- NET:     $rate_net / $rate_inet"
echo
green "GHUL verdict: This machine is ready for Linux gaming – see details above for tuning ideas."
echo "You can compare multiple JSON files over time to see the impact of upgrades and tweaks."
echo
