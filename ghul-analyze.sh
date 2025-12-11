#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# GHUL Analyze - Compare two GHULbench results
# Colors + clear diff + summary score + RAM upgrade detection
# Locale forced to C for predictable parsing.
###############################################################################

export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

# ANSI color codes (must use $'' to create real ESC, not literal "\033")
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
NC=$'\033[0m'

# add bold text properly in bash

bold=$(tput bold 2>/dev/null || echo "")
normal=$(tput sgr0 2>/dev/null || echo "")

###############################################################################
# Helper: num_or_zero
###############################################################################
num_or_zero() {
    printf "%s" "$1" | awk '
        /^[+-]?[0-9]*([.][0-9]+)?$/ { print $0; next }
        { print 0 }'
}

###############################################################################
# Check args and find result files
###############################################################################

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${BASE}/results"
HOST_ID_FILE="${BASE}/.ghul_host_id.json"

###############################################
# Help function
###############################################
show_help() {
  echo "GHUL Analyze - Compare two benchmark runs"
  echo
  echo "Usage:"
  echo "  ./ghul-analyze.sh [OPTIONS] [old.json new.json]"
  echo
  echo "Options:"
  echo "  -h, --help    Show this help message"
  echo
  echo "Arguments:"
  echo "  (none)              Compare last 2 runs automatically"
  echo "  old.json new.json   Compare specific files (assumes results/ if no path separator)"
  echo
  echo "Examples:"
  echo "  ./ghul-analyze.sh                                                      # Compare last 2 runs"
  echo "  ./ghul-analyze.sh 2025-11-29-13-39-sharkoon.json 2025-11-30-10-56-sharkoon.json"
  echo "  ./ghul-analyze.sh results/old.json results/new.json                    # With full paths"
  echo
  echo "Description:"
  echo "  Compares two GHULbenchmark runs and shows performance differences."
  echo "  Highlights changes in CPU, RAM, GPU, Network performance and thermals."
  echo "  Detects RAM upgrades and thermal degradation."
  exit 0
}

# Check for help flag
if [[ $# -ge 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_help
fi

# If no arguments: find the last two runs automatically
if [[ $# -eq 0 ]]; then
    # Find all JSON files in results/, sort by modification time (newest first)
    JSON_FILES=($(ls -1t "${RESULTS_DIR}"/*.json 2>/dev/null | head -n2 || true))
    
    if [[ ${#JSON_FILES[@]} -lt 2 ]]; then
        echo "Error: Need at least 2 benchmark runs to compare." >&2
        echo "Found ${#JSON_FILES[@]} run(s) in ${RESULTS_DIR}/" >&2
        echo >&2
        echo "Usage:" >&2
        echo "  $0                    # Compare last 2 runs automatically" >&2
        echo "  $0 <old.json> <new.json>  # Compare specific files" >&2
        echo "  $0 results/old.json results/new.json  # With paths" >&2
        exit 1
    fi
    
    OLD="${JSON_FILES[1]}"  # Second newest (older)
    NEW="${JSON_FILES[0]}"  # Newest
    
    echo "[GHUL] Auto-selected last 2 runs:"
    echo "  Old: $(basename "$OLD")"
    echo "  New: $(basename "$NEW")"
    echo

# If 2 arguments: use them as file paths
elif [[ $# -eq 2 ]]; then
    OLD="$1"
    NEW="$2"
    
    # If paths don't contain "/", assume they're in results/
    if [[ "$OLD" != */* ]]; then
        OLD="${RESULTS_DIR}/${OLD}"
    fi
    if [[ "$NEW" != */* ]]; then
        NEW="${RESULTS_DIR}/${NEW}"
    fi
    
    # Check if files exist
    if [[ ! -f "$OLD" ]]; then
        echo "Error: Old file not found: $OLD" >&2
        exit 1
    fi
    if [[ ! -f "$NEW" ]]; then
        echo "Error: New file not found: $NEW" >&2
        exit 1
    fi
else
    echo "Usage: $0 [<old.json> <new.json>]" >&2
    echo >&2
    echo "Without arguments: Compare the last 2 runs from results/" >&2
    echo "With arguments:    Compare specific JSON files" >&2
    echo >&2
    echo "Examples:" >&2
    echo "  $0" >&2
    echo "  $0 2025-11-29-13-39-sharkoon.json 2025-11-30-10-56-sharkoon.json" >&2
    echo "  $0 results/old.json results/new.json" >&2
    exit 1
fi

echo "== GHUL Analyze =="
echo
echo -e "Old: ${OLD}"
echo -e "New: ${NEW}"
echo

###############################################################################
# Read JSON helpers
###############################################################################
jqo() { jq -r "$1 // empty" "$OLD"; }
jqn() { jq -r "$1 // empty" "$NEW"; }

###############################################################################
# Environment compare function
###############################################################################
compare_field() {
    local name="$1"
    local oldv="$2"
    local newv="$3"

    if [[ "$oldv" == "$newv" ]]; then
        printf "    %-12s ${BLUE}unchanged: %s${NC}\n" "$name" "$oldv"
    else
        printf "    %-12s ${RED}old: %s${NC}\n" "$name" "$oldv"
        printf "                 ${GREEN}new: %s${NC}\n" "$newv"
    fi
}

###############################################################################
# Extract environment info
###############################################################################

CPU_OLD="$(jqo '.environment.cpu')"
CPU_NEW="$(jqn '.environment.cpu')"

MB_MAN_OLD="$(jqo '.environment.mainboard.manufacturer')"
MB_MAN_NEW="$(jqn '.environment.mainboard.manufacturer')"
MB_PROD_OLD="$(jqo '.environment.mainboard.product')"
MB_PROD_NEW="$(jqn '.environment.mainboard.product')"
MB_VER_OLD="$(jqo '.environment.mainboard.version')"
MB_VER_NEW="$(jqn '.environment.mainboard.version')"

GPU_MODEL_OLD="$(jqo '.environment.gpu_model')"
GPU_MODEL_NEW="$(jqn '.environment.gpu_model')"

GPU_REND_OLD="$(jqo '.environment.gpu_renderer')"
GPU_REND_NEW="$(jqn '.environment.gpu_renderer')"

RAM_TOTAL_OLD="$(jqo '.environment.mem_total_kib')"
RAM_TOTAL_NEW="$(jqn '.environment.mem_total_kib')"

RAM_TOTAL_OLD_GIB="$(awk -v v="$RAM_TOTAL_OLD" 'BEGIN { printf "%.2f GiB", v/1048576 }')"
RAM_TOTAL_NEW_GIB="$(awk -v v="$RAM_TOTAL_NEW" 'BEGIN { printf "%.2f GiB", v/1048576 }')"

KERNEL_OLD="$(jqo '.environment.kernel')"
KERNEL_NEW="$(jqn '.environment.kernel')"

###############################################################################
# RAM config extraction
###############################################################################

extract_ram_cfg() {
    local file="$1"
    local speed="$(jq -r '.ram.memory_devices[] | select(.size != "No Module Installed") | .configured_memory_speed' "$file" | head -n1)"
    local type="$(jq -r '.ram.memory_devices[] | select(.size != "No Module Installed") | .type' "$file" | head -n1)"
    local size_count="$(jq -r '.ram.memory_devices[] | select(.size != "No Module Installed") | .size' "$file" | wc -l)"
    local single_size="$(jq -r '.ram.memory_devices[] | select(.size != "No Module Installed") | .size' "$file" | head -n1 | awk "{print \$1}" )"
    local total_gib="$(jq -r '.environment.mem_total_kib' "$file" | awk '{ printf "%.2f GiB", $1/1048576 }')"
    local part="$(jq -r '.ram.memory_devices[] | select(.size != "No Module Installed") | .part_number' "$file" | head -n1)"
    local manuf="$(jq -r '.ram.memory_devices[] | select(.size != "No Module Installed") | .manufacturer' "$file" | head -n1)"

    echo "            $manuf $part"
    echo "            ${size_count}x${single_size} ${type} @ ${speed} dual-channel"
    echo "            total ${total_gib}"
}

RAMCFG_OLD="$(extract_ram_cfg "$OLD")"
RAMCFG_NEW="$(extract_ram_cfg "$NEW")"

###############################################################################
# Begin output
###############################################################################

echo "-- ${bold}Environment${normal} --"

# Only show changed fields, or show unchanged fields once
if [[ "$CPU_OLD" == "$CPU_NEW" ]]; then
    printf "    %-12s ${BLUE}%s${NC}\n" "CPU:" "$CPU_OLD"
else
    printf "    %-12s ${RED}old: %s${NC}\n" "CPU:" "$CPU_OLD"
    printf "                 ${GREEN}new: %s${NC}\n" "$CPU_NEW"
fi

MB_OLD_STR="${MB_MAN_OLD} ${MB_PROD_OLD} (rev ${MB_VER_OLD})"
MB_NEW_STR="${MB_MAN_NEW} ${MB_PROD_NEW} (rev ${MB_VER_NEW})"
if [[ "$MB_OLD_STR" == "$MB_NEW_STR" ]]; then
    printf "    %-12s ${BLUE}%s${NC}\n" "Mainboard:" "$MB_OLD_STR"
else
    printf "    %-12s ${RED}old: %s${NC}\n" "Mainboard:" "$MB_OLD_STR"
    printf "                 ${GREEN}new: %s${NC}\n" "$MB_NEW_STR"
fi

if [[ "$GPU_MODEL_OLD" == "$GPU_MODEL_NEW" ]]; then
    printf "    %-12s ${BLUE}%s${NC}\n" "GPU model:" "$GPU_MODEL_OLD"
else
    printf "    %-12s ${RED}old: %s${NC}\n" "GPU model:" "$GPU_MODEL_OLD"
    printf "                 ${GREEN}new: %s${NC}\n" "$GPU_MODEL_NEW"
fi

if [[ "$GPU_REND_OLD" == "$GPU_REND_NEW" ]]; then
    printf "    %-12s ${BLUE}%s${NC}\n" "GPU renderer:" "$GPU_REND_OLD"
else
    printf "    %-12s ${RED}old: %s${NC}\n" "GPU renderer:" "$GPU_REND_OLD"
    printf "                 ${GREEN}new: %s${NC}\n" "$GPU_REND_NEW"
fi

if [[ "$RAM_TOTAL_OLD_GIB" == "$RAM_TOTAL_NEW_GIB" ]]; then
    printf "    %-12s ${BLUE}%s${NC}\n" "RAM total:" "$RAM_TOTAL_OLD_GIB"
else
    printf "    %-12s ${RED}old: %s${NC}\n" "RAM total:" "$RAM_TOTAL_OLD_GIB"
    printf "                 ${GREEN}new: %s${NC}\n" "$RAM_TOTAL_NEW_GIB"
fi

# RAM config: only show once if unchanged, or show both if changed
if [[ "$RAMCFG_OLD" == "$RAMCFG_NEW" ]]; then
    echo "    RAM config:"
    echo "$RAMCFG_OLD" | sed 's/^/      /'
else
    echo "    RAM config:"
    echo "      old:"
    echo "$RAMCFG_OLD" | sed 's/^/        /'
    echo "      new:"
    echo "$RAMCFG_NEW" | sed 's/^/        /'
fi

# Kernel: show in blue if same, red/green if different
if [[ "$KERNEL_OLD" == "$KERNEL_NEW" ]]; then
    printf "    %-12s ${BLUE}%s${NC}\n" "Kernel:" "$KERNEL_OLD"
else
    printf "    %-12s ${RED}old: %s${NC}\n" "Kernel:" "$KERNEL_OLD"
    printf "                 ${GREEN}new: %s${NC}\n" "$KERNEL_NEW"
fi
echo

###############################################################################
# RAM Performance
###############################################################################

MBW_GIB_OLD="$(jqo '.ram.mbw_memcpy_gib_s')"
MBW_GIB_NEW="$(jqn '.ram.mbw_memcpy_gib_s')"

MBW_MIB_OLD="$(jqo '.ram.mbw_memcpy_mib_s')"
MBW_MIB_NEW="$(jqn '.ram.mbw_memcpy_mib_s')"

SYSW_OLD="$(jqo '.ram.sysbench_seq_write_mib_s')"
SYSW_NEW="$(jqn '.ram.sysbench_seq_write_mib_s')"

echo "-- ${bold}RAM performance${normal} --"

ram_delta() {
    local name="$1" old="$2" new="$3"

    # Handle null, empty, or "0" values
    if [[ "$old" == "" || "$old" == "null" || "$old" == "0" ]]; then
        local old_display="${old:-null}"
        local new_display="${new:-null}"
        printf "  %-20s %10s  ->  %10s  (Δ=   n/a)\n" "$name" "$old_display" "$new_display"
        return
    fi

    # If new is null/empty/0, show n/a for delta
    if [[ "$new" == "" || "$new" == "null" || "$new" == "0" ]]; then
        printf "  %-20s %10.3f  ->  %10s  (Δ=   n/a)\n" "$name" "$old" "${new:-null}"
        return
    fi

    local delta
    delta="$(awk -v o="$old" -v n="$new" 'BEGIN { printf "%.1f", (n-o)/o*100.0 }')"

    local color="$GREEN"
    (( $(echo "$delta < 0" | bc -l) )) && color="$RED"

    printf "  %-20s %10.3f  ->  %10.3f  (Δ=%s%6.1f%%%s)\n" \
        "$name" "$old" "$new" "$color" "$delta" "$NC"
}

ram_delta "mbw memcpy (MiB/s)" "$MBW_MIB_OLD" "$MBW_MIB_NEW"
ram_delta "mbw memcpy (GiB/s)" "$MBW_GIB_OLD" "$MBW_GIB_NEW"
ram_delta "sysbench seq write" "$SYSW_OLD" "$SYSW_NEW"

echo

# DIMM speed display - only show if changed
DIMM_OLD="$(jqo '.ram.memory_devices[] | select(.size != "No Module Installed") | .configured_memory_speed' | head -n1)"
DIMM_NEW="$(jqn '.ram.memory_devices[] | select(.size != "No Module Installed") | .configured_memory_speed' | head -n1)"

DIMM_R_OLD="$(jqo '.ram.memory_devices[] | select(.size != "No Module Installed") | .speed' | head -n1)"
DIMM_R_NEW="$(jqn '.ram.memory_devices[] | select(.size != "No Module Installed") | .speed' | head -n1)"

# Only show DIMM speed if it changed
if [[ "$DIMM_OLD" != "$DIMM_NEW" || "$DIMM_R_OLD" != "$DIMM_R_NEW" ]]; then
    if [[ "$DIMM_OLD" != "$DIMM_NEW" ]]; then
        echo "  ${bold}DIMM[0]${normal} configured speed:"
        echo -e "    old: ${RED}${DIMM_OLD}${NC}"
        echo -e "    new: ${GREEN}${DIMM_NEW}${NC}"
        echo
    fi
    if [[ "$DIMM_R_OLD" != "$DIMM_R_NEW" ]]; then
        echo "  ${bold}DIMM[0]${normal} reported speed:"
        echo -e "    old: ${RED}${DIMM_R_OLD}${NC}"
        echo -e "    new: ${GREEN}${DIMM_R_NEW}${NC}"
        echo
    fi
fi

# Check if RAM performance improved significantly
RAM_GAIN="$(awk -v o="$MBW_GIB_OLD" -v n="$MBW_GIB_NEW" \
    'BEGIN { if (o==0 || o=="") print "0"; else printf "%.1f", (n-o)/o*100.0 }')"

RAM_GAIN_NUM="$(num_or_zero "$RAM_GAIN")"

# If RAM speed changed, show upgrade message
if [[ "$DIMM_OLD" != "$DIMM_NEW" ]]; then
    echo -e "${YELLOW}*** RAM UPGRADE DETECTED ***${NC}"
    echo "  Base clock:   $DIMM_OLD"
    echo "  New clock:    $DIMM_NEW"
    if [[ "$RAM_GAIN_NUM" != "0" ]]; then
        echo "  Effective gain:"
        echo "    mbw memcpy: ${RAM_GAIN}%"
    fi
    echo
# If RAM performance improved significantly but speed didn't change, likely OC timing improvement
elif (( $(echo "$RAM_GAIN_NUM > 5" | bc -l) )); then
    echo -e "${GREEN}*** RAM PERFORMANCE IMPROVED ***${NC}"
    echo "  Bandwidth gain: ${RAM_GAIN}%"
    echo "  ${YELLOW}→ Likely due to improved OC timings. Congrats!${NC}"
    echo
fi

###############################################################################
# CPU Performance
###############################################################################

P7_OLD="$(jqo '.cpu.p7zip_tot_mips')"
P7_NEW="$(jqn '.cpu.p7zip_tot_mips')"

MATRIX_OLD="$(jqo '.cpu.stressng_matrix_bogo_ops')"
MATRIX_NEW="$(jqn '.cpu.stressng_matrix_bogo_ops')"

CRYPT_OLD="$(jqo '.cpu.stressng_crypt_bogo_ops')"
CRYPT_NEW="$(jqn '.cpu.stressng_crypt_bogo_ops')"

echo "-- ${bold}CPU performance${normal} --"

ram_delta "7-zip total MIPS" "$P7_OLD" "$P7_NEW"
ram_delta "stress-ng matrix:" "$MATRIX_OLD" "$MATRIX_NEW"
ram_delta "stress-ng crypt:" "$CRYPT_OLD" "$CRYPT_NEW"

echo

###############################################################################
# GPU Performance
###############################################################################

GLMARK_OLD="$(jqo '.gpu.glmark2_score')"
GLMARK_NEW="$(jqn '.gpu.glmark2_score')"
VK_OLD="$(jqo '.gpu.vkmark_score')"
VK_NEW="$(jqn '.gpu.vkmark_score')"
FUR_OLD="$(jqo '.gpu.gputest_fur.score')"
FUR_NEW="$(jqn '.gpu.gputest_fur.score')"
FPS_OLD="$(jqo '.gpu.gputest_fur.fps')"
FPS_NEW="$(jqn '.gpu.gputest_fur.fps')"

echo "-- ${bold}GPU performance${normal} --"

ram_delta "glmark2 score" "$GLMARK_OLD" "$GLMARK_NEW"
ram_delta "vkmark score" "$VK_OLD" "$VK_NEW"
ram_delta "FurMark score" "$FUR_OLD" "$FUR_NEW"
ram_delta "FurMark FPS" "$FPS_OLD" "$FPS_NEW"

echo

###############################################################################
# Network Performance
###############################################################################

DL_OLD="$(jqo '.network.internet_download_mbps')"
DL_NEW="$(jqn '.network.internet_download_mbps')"
UP_OLD="$(jqo '.network.internet_upload_mbps')"
UP_NEW="$(jqn '.network.internet_upload_mbps')"
TCP_OLD="$(jqo '.network.tcp_mbps')"
TCP_NEW="$(jqn '.network.tcp_mbps')"

echo "-- ${bold}Network${normal} --"
ram_delta "Internet download  (Mbit/s)" "$DL_OLD" "$DL_NEW"
ram_delta "Internet upload    (Mbit/s)" "$UP_OLD" "$UP_NEW"
ram_delta "TCP local loopback (Mbit/s)" "$TCP_OLD" "$TCP_NEW"

echo

###############################################################################
# Summary Score
###############################################################################
echo "#########################"
echo "#     ${bold}Summary Score${normal}     #"
echo "#########################"
# RAM score
RS="0.0"
if [[ "$MBW_GIB_OLD" != "0" && "$MBW_GIB_OLD" != "" ]]; then
    RS="$(awk -v o="$MBW_GIB_OLD" -v n="$MBW_GIB_NEW" \
        'BEGIN { printf "%.1f", (n-o)/o*100.0 }')"
fi

# CPU score
CS="0.0"
if [[ "$P7_OLD" != "0" && "$P7_OLD" != "" ]]; then
    CS="$(awk -v o="$P7_OLD" -v n="$P7_NEW" \
        'BEGIN { printf "%.1f", (n-o)/o*100.0 }')"
fi

# GPU score
GS="0.0"
if [[ "$GLMARK_OLD" != "0" && "$GLMARK_OLD" != "" ]]; then
    GS="$(awk -v o="$GLMARK_OLD" -v n="$GLMARK_NEW" \
        'BEGIN { printf "%.1f", (n-o)/o*100.0 }')"
fi

# Network score
NS="0.0"
if [[ "$TCP_OLD" != "0" && "$TCP_OLD" != "" ]]; then
    NS="$(awk -v o="$TCP_OLD" -v n="$TCP_NEW" \
        'BEGIN { printf "%.1f", (n-o)/o*100.0 }')"
fi

# Convert safely
RS_NUM="$(num_or_zero "$RS")"
CS_NUM="$(num_or_zero "$CS")"
GS_NUM="$(num_or_zero "$GS")"
NS_NUM="$(num_or_zero "$NS")"

OVERALL="$(awk -v r="$RS_NUM" -v c="$CS_NUM" -v g="$GS_NUM" -v n="$NS_NUM" \
  'BEGIN { printf "%.1f", (r + c + g + n) / 4.0 }')"

printf "  RAM:        %7.1f %%\n" "$RS_NUM"
printf "  CPU:        %7.1f %%\n" "$CS_NUM"
printf "  GPU:        %7.1f %%\n" "$GS_NUM"
printf "  NETWORK:    %7.1f %%\n" "$NS_NUM"
printf "  OVERALL:    %7.1f %%\n" "$OVERALL"

###############################################################################
# Thermal Analysis (compare sensor data between runs)
###############################################################################
echo "-- ${bold}Thermal Analysis${normal} --"

# Helper to find sensor file for a benchmark JSON
find_sensor_file() {
    local bench_file="$1"
    local bench_name
    bench_name="$(basename "$bench_file")"
    local bench_prefix
    bench_prefix="$(echo "$bench_name" | cut -d'-' -f1-5)"
    local sensor_dir="${BASE}/logs/sensors"
    ls -1t "${sensor_dir}/${bench_prefix}"*-sensors.jsonl 2>/dev/null | head -n1 || echo ""
}

# Helper to extract max temperature from sensor file
extract_max_temp() {
    local sensor_file="$1"
    local field="$2"
    local start_epoch="$3"
    local end_epoch="$4"
    
    if [[ ! -f "$sensor_file" || -z "$start_epoch" || -z "$end_epoch" ]]; then
        echo "null"
        return
    fi
    
    local max_temp
    max_temp="$(jq -r --argjson s "$start_epoch" --argjson e "$end_epoch" --arg f "$field" '
        select(.timestamp >= $s and .timestamp <= $e)
        | .[$f] // empty
        | select(. != null and . != "" and . != "null")
    ' "$sensor_file" 2>/dev/null | awk 'BEGIN{max=0} {if($1>max) max=$1} END{if(max>0) printf "%.1f", max; else print "null"}' || echo "null")"
    
    echo "$max_temp"
}

SENS_FILE_OLD="$(find_sensor_file "$OLD")"
SENS_FILE_NEW="$(find_sensor_file "$NEW")"

RUN_START_OLD="$(jq -r '.timeline[]? | select(.name=="run_start") | .epoch' "$OLD" | head -n1 || jq -r '.timeline[0].epoch // empty' "$OLD" || echo "")"
RUN_END_OLD="$(jq -r '.timeline[]? | select(.name=="run_end") | .epoch' "$OLD" | head -n1 || jq -r '.run_meta.end_epoch // empty' "$OLD" || echo "")"
RUN_START_NEW="$(jq -r '.timeline[]? | select(.name=="run_start") | .epoch' "$NEW" | head -n1 || jq -r '.timeline[0].epoch // empty' "$NEW" || echo "")"
RUN_END_NEW="$(jq -r '.timeline[]? | select(.name=="run_end") | .epoch' "$NEW" | head -n1 || jq -r '.run_meta.end_epoch // empty' "$NEW" || echo "")"

# If we have sensor files and timeline data, compare temperatures
if [[ -f "$SENS_FILE_OLD" && -f "$SENS_FILE_NEW" && -n "$RUN_START_OLD" && -n "$RUN_END_OLD" && -n "$RUN_START_NEW" && -n "$RUN_END_NEW" ]]; then
    # CPU Temperature
    CPU_TEMP_OLD="$(extract_max_temp "$SENS_FILE_OLD" "cpu_temp_c" "$RUN_START_OLD" "$RUN_END_OLD")"
    CPU_TEMP_NEW="$(extract_max_temp "$SENS_FILE_NEW" "cpu_temp_c" "$RUN_START_NEW" "$RUN_END_NEW")"
    
    if [[ "$CPU_TEMP_OLD" != "null" && "$CPU_TEMP_NEW" != "null" ]]; then
        cpu_delta="$(awk -v o="$CPU_TEMP_OLD" -v n="$CPU_TEMP_NEW" 'BEGIN { printf "%.1f", n-o }')"
        cpu_color="$GREEN"
        cpu_warning=""
        
        # Check for critical temperatures
        if (( $(echo "$CPU_TEMP_NEW >= 100.0" | bc -l) )); then
            cpu_color="$RED"
            cpu_warning=" ⚠ CRITICAL: CPU overheating! Check thermal paste and cooling immediately!"
        elif (( $(echo "$CPU_TEMP_NEW > 80.0" | bc -l) )); then
            cpu_color="$YELLOW"
            cpu_warning=" ⚠ WARNING: CPU temp high"
        fi
        
        # Check for thermal degradation
        if (( $(echo "$cpu_delta > 5.0" | bc -l) )); then
            cpu_color="$RED"
            cpu_warning="${cpu_warning} ⚠ THERMAL DEGRADATION DETECTED!"
        elif (( $(echo "$cpu_delta < -5.0" | bc -l) )); then
            cpu_color="$GREEN"
            cpu_warning=" ✓ Thermal improvement"
        fi
        
        printf "  CPU max temp:      %6.1f°C  ->  %6.1f°C  (Δ=%s%6.1f°C%s)%s\n" \
            "$CPU_TEMP_OLD" "$CPU_TEMP_NEW" "$cpu_color" "$cpu_delta" "$NC" "$cpu_warning"
    fi
    
    # GPU Temperature
    GPU_TEMP_OLD="$(extract_max_temp "$SENS_FILE_OLD" "gpu_temp_c" "$RUN_START_OLD" "$RUN_END_OLD")"
    GPU_TEMP_NEW="$(extract_max_temp "$SENS_FILE_NEW" "gpu_temp_c" "$RUN_START_NEW" "$RUN_END_NEW")"
    
    if [[ "$GPU_TEMP_OLD" != "null" && "$GPU_TEMP_NEW" != "null" ]]; then
        gpu_delta="$(awk -v o="$GPU_TEMP_OLD" -v n="$GPU_TEMP_NEW" 'BEGIN { printf "%.1f", n-o }')"
        gpu_color="$GREEN"
        gpu_warning=""
        
        # Check for critical temperatures
        if (( $(echo "$GPU_TEMP_NEW >= 95.0" | bc -l) )); then
            gpu_color="$RED"
            gpu_warning=" ⚠ CRITICAL: GPU overheating! Check thermal paste and cooling immediately!"
        elif (( $(echo "$GPU_TEMP_NEW > 85.0" | bc -l) )); then
            gpu_color="$YELLOW"
            gpu_warning=" ⚠ WARNING: GPU temp high"
        fi
        
        # Check for thermal degradation
        if (( $(echo "$gpu_delta > 5.0" | bc -l) )); then
            gpu_color="$RED"
            gpu_warning="${gpu_warning} ⚠ THERMAL DEGRADATION DETECTED!"
        elif (( $(echo "$gpu_delta < -5.0" | bc -l) )); then
            gpu_color="$GREEN"
            gpu_warning=" ✓ Thermal improvement"
        fi
        
        printf "  GPU max temp:      %6.1f°C  ->  %6.1f°C  (Δ=%s%6.1f°C%s)%s\n" \
            "$GPU_TEMP_OLD" "$GPU_TEMP_NEW" "$gpu_color" "$gpu_delta" "$NC" "$gpu_warning"
    fi
    
    # GPU Hotspot (if available)
    GPU_HOTSPOT_OLD="$(extract_max_temp "$SENS_FILE_OLD" "gpu_hotspot_c" "$RUN_START_OLD" "$RUN_END_OLD")"
    GPU_HOTSPOT_NEW="$(extract_max_temp "$SENS_FILE_NEW" "gpu_hotspot_c" "$RUN_START_NEW" "$RUN_END_NEW")"
    
    if [[ "$GPU_HOTSPOT_OLD" != "null" && "$GPU_HOTSPOT_NEW" != "null" ]]; then
        hotspot_delta="$(awk -v o="$GPU_HOTSPOT_OLD" -v n="$GPU_HOTSPOT_NEW" 'BEGIN { printf "%.1f", n-o }')"
        hotspot_color="$GREEN"
        hotspot_warning=""
        
        # Check for critical temperatures
        if (( $(echo "$GPU_HOTSPOT_NEW >= 110.0" | bc -l) )); then
            hotspot_color="$RED"
            hotspot_warning=" ⚠ CRITICAL: GPU hotspot overheating!"
        elif (( $(echo "$GPU_HOTSPOT_NEW > 100.0" | bc -l) )); then
            hotspot_color="$YELLOW"
            hotspot_warning=" ⚠ WARNING: GPU hotspot temp high"
        fi
        
        if (( $(echo "$hotspot_delta > 5.0" | bc -l) )); then
            hotspot_color="$RED"
            hotspot_warning="${hotspot_warning} ⚠ THERMAL DEGRADATION!"
        elif (( $(echo "$hotspot_delta < -5.0" | bc -l) )); then
            hotspot_color="$GREEN"
            hotspot_warning=" ✓ Thermal improvement"
        fi
        
        printf "  GPU hotspot:       %6.1f°C  ->  %6.1f°C  (Δ=%s%6.1f°C%s)%s\n" \
            "$GPU_HOTSPOT_OLD" "$GPU_HOTSPOT_NEW" "$hotspot_color" "$hotspot_delta" "$NC" "$hotspot_warning"
    fi
    
    echo
    echo "  ${bold}Thermal Assessment:${normal}"
    if [[ "$CPU_TEMP_NEW" != "null" && -n "$CPU_TEMP_NEW" ]]; then
        if (( $(echo "$CPU_TEMP_NEW >= 100.0" | bc -l) )); then
            echo -e "    ${RED}⚠ CRITICAL: CPU temperatures ≥ 100°C detected!${NC}"
            echo -e "    ${RED}   → Check CPU cooler mounting and thermal paste immediately!${NC}"
            echo -e "    ${RED}   → CPU throttling likely occurred, performance degraded!${NC}"
        elif (( $(echo "$CPU_TEMP_NEW > 80.0" | bc -l) )); then
            echo -e "    ${YELLOW}⚠ WARNING: CPU temperatures > 80°C - consider improving cooling${NC}"
        fi
    fi
    
    if [[ "$GPU_TEMP_NEW" != "null" && -n "$GPU_TEMP_NEW" ]]; then
        if (( $(echo "$GPU_TEMP_NEW >= 95.0" | bc -l) )); then
            echo -e "    ${RED}⚠ CRITICAL: GPU temperatures ≥ 95°C detected!${NC}"
            echo -e "    ${RED}   → Check GPU cooler and thermal paste immediately!${NC}"
            echo -e "    ${RED}   → GPU throttling likely occurred, performance degraded!${NC}"
        elif (( $(echo "$GPU_TEMP_NEW > 85.0" | bc -l) )); then
            echo -e "    ${YELLOW}⚠ WARNING: GPU temperatures > 85°C - consider improving cooling${NC}"
        fi
    fi
    
    if [[ "$GPU_HOTSPOT_NEW" != "null" && -n "$GPU_HOTSPOT_NEW" ]]; then
        if (( $(echo "$GPU_HOTSPOT_NEW >= 110.0" | bc -l) )); then
            echo -e "    ${RED}⚠ CRITICAL: GPU hotspot ≥ 110°C detected!${NC}"
            echo -e "    ${RED}   → GPU thermal throttling likely occurred!${NC}"
        fi
    fi
    
    echo
else
    echo "  (Sensor data not available for thermal comparison)"
    echo
fi

# Check fan_status from .ghul_host_id.json and show warning if unattainable
FAN_STATUS="$(jq -r '.fan_status // "unknown"' "$HOST_ID_FILE" 2>/dev/null || echo "unknown")"
if [[ "$FAN_STATUS" == "unattainable" ]]; then
    echo
    echo -e "${YELLOW}⚠ Fan monitoring: NOT AVAILABLE${NC}"
    echo -e "${YELLOW}  The SuperIO chip on this mainboard cannot be accessed by Linux.${NC}"
    echo -e "${YELLOW}  This is likely due to proprietary ACPI control that only works on Microsoft Windows.${NC}"
    echo -e "${YELLOW}  Fan RPM values are not available, but fans are still working normally.${NC}"
    echo
fi

echo
echo "== Done =="
