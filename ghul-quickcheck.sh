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

# Get absolute path of GHULbenchmark root (this script's directory)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_ID_FILE="${BASE}/.ghul_host_id.json"

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

# ---------- help function -----------------------------------------------------

show_help() {
  echo "GHUL Quickcheck - Quick system assessment and rating"
  echo
  echo "Usage:"
  echo "  ./ghul-quickcheck.sh [OPTIONS] [result.json | directory]"
  echo
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo
  echo "Arguments:"
  echo "  (none)       Use newest JSON from results/"
  echo "  result.json  Use specific file (assumes results/ if no path separator)"
  echo "  directory    Use newest JSON from specified directory"
  echo
  echo "Examples:"
  echo "  ./ghul-quickcheck.sh                                    # Use newest JSON"
  echo "  ./ghul-quickcheck.sh 2025-11-29-13-39-sharkoon.json     # Use specific file"
  echo "  ./ghul-quickcheck.sh results/                            # Use newest from directory"
  echo
  echo "Description:"
  echo "  Shows a quick overview of your system's gaming performance with ratings"
  echo "  for CPU, RAM, GPU, Storage, and Network. Includes thermal warnings."
  echo
  echo "Usage:"
  echo "  Called directly: last benchmark gets analyzed."
  echo "  With path like results/<benchmark> you can quickcheck any benchmark there"
  exit 0
}

# Check for help flag
if [[ $# -ge 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_help
fi

# ---------- result file selection ---------------------------------------------

# If no argument provided, use newest JSON from results/
if [[ $# -lt 1 ]]; then
  RESULT_FILE=$(ls -1t "${BASE}/results"/*.json 2>/dev/null | head -n1 || true)
  
  if [[ -z "$RESULT_FILE" ]]; then
    red "[GHUL] No benchmark JSON file specified and no JSON files found in results/."
    echo
    echo "Usage:"
    echo "  ./ghul-quickcheck.sh [result.json | directory]"
    echo
    echo "Examples:"
    echo "  ./ghul-quickcheck.sh                                    # Use newest JSON from results/"
    echo "  ./ghul-quickcheck.sh 2025-11-29-13-39-sharkoon.json     # Use specific file"
    echo "  ./ghul-quickcheck.sh results/                            # Use newest from directory"
    echo
    echo "Notes:"
    echo "  - If no argument is provided, quickcheck uses the newest JSON from results/."
    echo "  - If you pass a filename without '/', quickcheck assumes it is inside 'results/'."
    echo "  - If you pass a directory, quickcheck will automatically pick the newest JSON inside it."
    exit 1
  fi
  
  echo "[GHUL] No file specified, using newest JSON from results/:"
  echo "       $RESULT_FILE"
  echo
else
  ARG="$1"

  # Case 1: argument is a directory → pick newest JSON inside it
  if [[ -d "$ARG" ]]; then
    # normalize directory (remove trailing slash for ls, but doesn't matter here)
    dir="$ARG"
    RESULT_FILE=$(ls -1t "$dir"/*.json 2>/dev/null | head -n1 || true)

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
gpu_renderer="$(jqr '.environment.gpu_renderer // "unknown"' "$RESULT_FILE")"

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

# Count RAM modules and channels (needed for rating)
ram_module_count=$(jq '[.ram.memory_devices[]
                         | select(.size // "" | test("No Module Installed") | not)
                       ] | length' "$RESULT_FILE")

# Extract channels from locator (e.g. "ChannelA-DIMM0" -> "A", "ChannelB-DIMM1" -> "B")
ram_channel_count=$(jq '[.ram.memory_devices[]
                         | select(.size // "" | test("No Module Installed") | not)
                         | (.locator // "")
                         | match("Channel([A-Z])") | .captures[0].string
                       ] | unique | length' "$RESULT_FILE" 2>/dev/null || echo "0")

# Fallback: if no channels found in locator, try bank_locator
if [[ "$ram_channel_count" == "0" || -z "$ram_channel_count" ]]; then
  ram_channel_count=$(jq '[.ram.memory_devices[]
                           | select(.size // "" | test("No Module Installed") | not)
                           | (.bank_locator // "" | split(" ") | last)
                         ] | unique | length' "$RESULT_FILE" 2>/dev/null || echo "0")
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

# Check if fully populated dual-channel (4 DIMMs in 2 channels)
is_fully_populated_dual=0
if (( ram_module_count == 4 && ram_channel_count == 2 )); then
  is_fully_populated_dual=1
fi

if (( $(printf "%.0f" "$ram_bw") >= 35 )); then
  if (( is_fully_populated_dual == 1 )); then
    rate_ram="Very high RAM bandwidth – tuned DDR4 or modern DDR5-level. Fully populated dual-channel configuration is optimal."
  else
    rate_ram="Very high RAM bandwidth – tuned DDR4 or modern DDR5-level."
  fi
elif (( $(printf "%.0f" "$ram_bw") >= 20 )); then
  if (( is_fully_populated_dual == 1 )); then
    rate_ram="Good RAM bandwidth – fully populated dual-channel configuration is optimal for gaming."
  else
    rate_ram="Good RAM bandwidth – absolutely fine for current gaming."
  fi
elif (( $(printf "%.0f" "$ram_bw") >= 10 )); then
  if (( is_fully_populated_dual == 1 )); then
    rate_ram="Decent RAM bandwidth – fully populated dual-channel is good, but faster RAM speed or better timings could improve 1% lows."
  else
    rate_ram="Decent RAM bandwidth – fine for gaming, but faster kits or tuning could improve 1% lows."
  fi
elif (( $(printf "%.0f" "$ram_bw") >= 6 )); then
  if (( is_fully_populated_dual == 1 )); then
    rate_ram="Moderate RAM bandwidth – fully populated dual-channel is good, but RAM speed or timings could be improved."
  else
    rate_ram="Moderate RAM bandwidth – still okay for gaming but could be improved."
  fi
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
echo "Kernel:         ${kernel}"
# Check if gpu_model already contains the manufacturer name to avoid duplication
gpu_display=""
if [[ "$gpu_model" != "unknown" && -n "$gpu_model" ]]; then
  # If gpu_model already starts with the manufacturer name, use only gpu_model
  if [[ "$gpu_man" != "unknown" && -n "$gpu_man" ]] && echo "$gpu_model" | grep -qi "^${gpu_man}"; then
    gpu_display="$gpu_model"
  else
    # Otherwise combine manufacturer and model
    gpu_display="${gpu_man} ${gpu_model}"
  fi
else
  # Fallback if model is unknown
  gpu_display="${gpu_man} ${gpu_model}"
fi
echo "GPU:            ${gpu_display}"
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
        echo "$(red "                     ⚠ CRITICAL: CPU overheating (≥100°C)! Check thermal paste and cooling immediately!")"
        echo "$(red "                     ⚠ CPU THROTTLING LIKELY OCCURRED - Performance degraded!")"
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
# Note: ram_module_count and ram_channel_count are already calculated above for rating

dual_info="Unknown RAM layout"

if (( ram_module_count == 0 )); then
  dual_info="No populated DIMM slots reported."
elif (( ram_module_count == 1 )); then
  dual_info="Single-module configuration – effectively single-channel."
elif (( ram_channel_count >= 3 )); then
  dual_info="${ram_module_count} modules across ${ram_channel_count} channels – multi-channel (3+), very likely optimal."
elif (( ram_channel_count == 2 )); then
  # Special case: 4 DIMMs in 2 channels = fully populated dual-channel
  if (( ram_module_count == 4 )); then
    dual_info="4 DIMMs in 2 channels (dual-channel fully populated)"
  else
    dual_info="${ram_module_count} modules across 2 channels – dual-channel very likely active."
  fi
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

# Check if Nouveau driver is being used (Nouveau renderer codes start with "NV" followed by numbers)
if [[ "$gpu_man" == "NVIDIA" ]] && echo "$gpu_renderer" | grep -qiE '^NV[0-9]'; then
  echo
  yellow "⚠ NVIDIA Nouveau Driver Detected"
  yellow "   Nouveau is not a suitable driver for gaming."
  yellow "   The graphics card is too old for modern proprietary NVIDIA drivers."
  yellow "   This is not a Linux problem, but a manufacturer problem with"
  yellow "   proprietary driver philosophy. NVIDIA causes headaches."
  echo
fi

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
        echo "$(red "                     ⚠ CRITICAL: GPU overheating (≥95°C)! Check thermal paste and cooling immediately!")"
        echo "$(red "                     ⚠ GPU THROTTLING LIKELY OCCURRED - Performance degraded!")"
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
        echo "$(red "                     ⚠ CRITICAL: GPU hotspot overheating (≥110°C)! Check thermal paste and cooling immediately!")"
        echo "$(red "                     ⚠ GPU THERMAL THROTTLING LIKELY OCCURRED!")"
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

# Check if storage data exists
storage_count=$(jq '[.storage[]?] | length' "$RESULT_FILE" 2>/dev/null || echo 0)

if (( storage_count == 0 )); then
  yellow "No storage benchmark data available."
else
  # Check for NVMe and SATA devices
  has_nvme=0
  has_sata=0
  
  # Check if any device is NVMe (device name starts with "nvme")
  if jq -e '[.storage[]? | select(.device // "" | test("^nvme"))] | length > 0' "$RESULT_FILE" >/dev/null 2>&1; then
    has_nvme=1
  fi
  
  # Check if any device is SATA (device name starts with "sd" or "hd")
  if jq -e '[.storage[]? | select(.device // "" | test("^(sd|hd)"))] | length > 0' "$RESULT_FILE" >/dev/null 2>&1; then
    has_sata=1
  fi
  
  # Get timeline for temperature lookup
  RUN_START_EPOCH="$(jq -r '.timeline[]? | select(.name=="run_start") | .epoch' "$RESULT_FILE" | head -n1 || jq -r '.timeline[0].epoch // empty' "$RESULT_FILE" || echo "")"
  SENS_LAST_TS=""
  if [[ -n "$SENS_FILE" && -f "$SENS_FILE" ]]; then
    SENS_LAST_TS="$(jq -r 'select(.timestamp != null) | .timestamp' "$SENS_FILE" | tail -n1 || echo "")"
  fi
  
  # Display each storage device with performance + temperature
  # Use jq -c to output compact JSON, one object per line
  jq -c '.storage[]?' "$RESULT_FILE" | while IFS= read -r storage_json; do
    device="$(echo "$storage_json" | jq -r '.device // "unknown"')"
    model="$(echo "$storage_json" | jq -r '.model // "unknown model"')"
    mount_point="$(echo "$storage_json" | jq -r '.mount_point // "n/a"')"
    seq_read="$(echo "$storage_json" | jq -r '.sequential_read_mbps // 0')"
    seq_write="$(echo "$storage_json" | jq -r '.sequential_write_mbps // 0')"
    rand4k_read="$(echo "$storage_json" | jq -r '.random_4k_read_mbps // 0')"
    rand4k_write="$(echo "$storage_json" | jq -r '.random_4k_write_mbps // 0')"
    
    # Determine device type
    device_type=""
    if echo "$device" | grep -qE '^nvme'; then
      device_type="NVMe"
    elif echo "$device" | grep -qE '^(sd|hd)'; then
      device_type="SATA"
    else
      device_type="Storage"
    fi
    
    # Get base device name for temperature lookup (nvme0n1p2 -> nvme0n1, sda1 -> sda)
    base_device=""
    if echo "$device" | grep -qE '^nvme'; then
      base_device="$(echo "$device" | sed -E 's/(nvme[0-9]+n[0-9]+).*/\1/')"
    else
      base_device="$(echo "$device" | sed -E 's/([a-z]+)([0-9]+).*/\1/')"
    fi
    
    echo "Device:             ${device} (${model})"
    echo "  Type:             ${device_type}"
    echo "  Mount point:      ${mount_point}"
    echo "  Sequential read:  ${seq_read} MB/s"
    echo "  Sequential write: ${seq_write} MB/s"
    echo "  Random 4K read:   ${rand4k_read} MB/s"
    echo "  Random 4K write:  ${rand4k_write} MB/s"
    
    # Get temperature if available
    if [[ -n "$SENS_FILE" && -f "$SENS_FILE" && -n "$RUN_START_EPOCH" && -n "$SENS_LAST_TS" && -n "$base_device" ]]; then
      temp_values=$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" --arg dev "$base_device" '
        select(.timestamp >= $s and .timestamp <= $e)
        | .storage_temps[$dev] // empty
        | select(. != null)
      ' "$SENS_FILE" 2>/dev/null || true)
      
      if [[ -n "$temp_values" ]]; then
        temp_min=$(echo "$temp_values" | awk 'BEGIN{min=999} {if($1<min) min=$1} END{print min}')
        temp_max=$(echo "$temp_values" | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}')
        temp_avg=$(echo "$temp_values" | awk '{sum+=$1; cnt++} END{if(cnt>0) printf "%.1f", sum/cnt; else print "0"}')
        
        temp_warning=""
        if (( $(echo "$temp_max >= 70.0" | bc -l) )); then
          temp_warning=" $(red "⚠ CRITICAL: ≥70°C!")"
        elif (( $(echo "$temp_max > 55.0" | bc -l) )); then
          temp_warning=" $(yellow "⚠ WARNING: >55°C")"
        fi
        
        echo "  Temperature:       min=${temp_min}°C, avg=${temp_avg}°C, max=${temp_max}°C${temp_warning}"
      else
        echo "  Temperature:       n/a"
      fi
    else
      echo "  Temperature:       n/a"
    fi
    
    echo
  done
  
  # Overall storage rating
  echo "Storage rating:"
  if (( has_nvme == 1 )); then
    echo "  System drive:      NVMe-class performance – excellent."
  fi
  if (( has_sata == 1 )); then
    echo "  Game library drive: SATA SSD-class performance – still very good for gaming."
  fi
  if (( has_nvme == 0 && has_sata == 0 )); then
    echo "  Storage:           Performance data available, see device details above."
  fi
fi

headline "GHUL overall impression"

echo "Summary:"
echo "- CPU:     $rate_cpu"
echo "- RAM:     $rate_ram"
echo "- GPU:     $rate_gpu"
# Storage summary is already shown in Storage assessment section
if (( storage_count > 0 )); then
  if (( has_nvme == 1 )); then
    echo "- Storage: NVMe-class (excellent)"
  elif (( has_sata == 1 )); then
    echo "- Storage: SATA SSD-class (very good)"
  else
    echo "- Storage: See device details above"
  fi
fi
echo "- NET:     $rate_net / $rate_inet"
echo

# Check for critical thermal issues and throttling
if [[ -n "$SENS_FILE" && -f "$SENS_FILE" ]]; then
  RUN_START_EPOCH="$(jq -r '.timeline[]? | select(.name=="run_start") | .epoch' "$RESULT_FILE" | head -n1 || jq -r '.timeline[0].epoch // empty' "$RESULT_FILE" || echo "")"
  SENS_LAST_TS="$(jq -r 'select(.timestamp != null) | .timestamp' "$SENS_FILE" | tail -n1 || echo "")"
  
  if [[ -n "$RUN_START_EPOCH" && -n "$SENS_LAST_TS" ]]; then
    cpu_max_check="$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" '
      select(.timestamp >= $s and .timestamp <= $e)
      | .cpu_temp_c // empty
      | select(. != null)
    ' "$SENS_FILE" 2>/dev/null | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}' || echo "0")"
    
    gpu_max_check="$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" '
      select(.timestamp >= $s and .timestamp <= $e)
      | .gpu_temp_c // empty
      | select(. != null)
    ' "$SENS_FILE" 2>/dev/null | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}' || echo "0")"
    
    gpu_hotspot_check="$(jq -r --argjson s "$RUN_START_EPOCH" --argjson e "$SENS_LAST_TS" '
      select(.timestamp >= $s and .timestamp <= $e)
      | .gpu_hotspot_c // empty
      | select(. != null)
    ' "$SENS_FILE" 2>/dev/null | awk 'BEGIN{max=0} {if($1>max) max=$1} END{print max}' || echo "0")"
    
    has_critical=0
    if (( $(echo "$cpu_max_check >= 100.0" | bc -l 2>/dev/null || echo 0) )); then
      has_critical=1
    fi
    if (( $(echo "$gpu_max_check >= 95.0" | bc -l 2>/dev/null || echo 0) )); then
      has_critical=1
    fi
    if (( $(echo "$gpu_hotspot_check >= 110.0" | bc -l 2>/dev/null || echo 0) )); then
      has_critical=1
    fi
    
    if [[ $has_critical -eq 1 ]]; then
      echo
      red "⚠ CRITICAL THERMAL ISSUES DETECTED!"
      red "  → CPU and/or GPU temperatures exceeded safe limits"
      red "  → Thermal throttling likely occurred - performance degraded"
      red "  → Check cooling, thermal paste, and cooler mounting immediately!"
      echo
    fi
  fi
fi

# Check fan_status from .ghul_host_id.json and show warning if unattainable
FAN_STATUS="$(jq -r '.fan_status // "unknown"' "$HOST_ID_FILE" 2>/dev/null || echo "unknown")"
if [[ "$FAN_STATUS" == "unattainable" ]]; then
  echo
  yellow "⚠ Fan monitoring: NOT AVAILABLE"
  yellow "  The SuperIO chip on this mainboard cannot be accessed by Linux."
  yellow "  This is likely due to proprietary ACPI control that only works on Microsoft Windows."
  yellow "  Fan RPM values are not available, but fans are still working normally."
  echo
fi

# Check if Nouveau driver is being used and adjust verdict accordingly
if [[ "$gpu_man" == "NVIDIA" ]] && echo "$gpu_renderer" | grep -qiE '^NV[0-9]'; then
  yellow "GHUL verdict: This machine is NOT suitable for gaming due to Nouveau driver limitations."
  yellow "  The system is still usable for office work, web browsing, and CPU-based video editing,"
  yellow "  but gaming performance is severely limited. This is not a Linux problem, but a"
  yellow "  manufacturer issue: NVIDIA no longer provides driver support for this graphics card."
else
  green "GHUL verdict: This machine is ready for Linux gaming – see details above for tuning ideas."
fi
echo "You can compare multiple JSON files over time to see the impact of upgrades and tweaks."
echo
