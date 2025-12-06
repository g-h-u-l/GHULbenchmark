#!/usr/bin/env bash
set -euo pipefail

# Enforce predictable C locale (important for parsing)
export LANG=C
export LC_ALL=C
export LC_NUMERIC=C

# === GHUL paths ===
# Assume this script lives in:  ~/GHULbenchmark/tools/
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GHUL_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

LOG_DIR="${GHUL_ROOT}/logs/gpu"
mkdir -p "${LOG_DIR}"

RUN_ID="$(date -u +'%Y-%m-%dT%H-%M-%SZ')"
MAIN_LOG="${LOG_DIR}/${RUN_ID}-gpu-samples.log"
KERNEL_LOG="${LOG_DIR}/${RUN_ID}-gpu-kernel.log"
INTERVAL_SEC=2

log_msg() {
    # Status messages to stderr so stdout stays clean
    printf '[GHUL] %s\n' "$*" >&2
}

log_msg "GHUL GPU diagnostic started."
log_msg "GHUL root: ${GHUL_ROOT}"
log_msg "Logging to:"
log_msg "  ${MAIN_LOG}"
log_msg "  ${KERNEL_LOG}"

# === Find AMD GPU card ===
AMD_CARD=""
for dev in /sys/class/drm/card*/device; do
    if [[ -f "${dev}/vendor" ]]; then
        vendor_hex=$(<"${dev}/vendor")
        if [[ "${vendor_hex}" == "0x1002" ]]; then
            AMD_CARD="$(basename "$(dirname "${dev}")")"
            break
        fi
    fi
done

if [[ -z "${AMD_CARD}" ]]; then
    log_msg "No AMD GPU found under /sys/class/drm/card*/device (vendor 0x1002)."
    log_msg "Will only log amdgpu kernel messages."
else
    log_msg "Detected AMD GPU: ${AMD_CARD}"
fi

# === Find hwmon for this AMD GPU ===
HWMON_DIR=""
if [[ -n "${AMD_CARD}" ]]; then
    dev_path="/sys/class/drm/${AMD_CARD}/device"
    if [[ -d "${dev_path}/hwmon" ]]; then
        for h in "${dev_path}"/hwmon/hwmon*; do
            if [[ -d "${h}" ]]; then
                HWMON_DIR="${h}"
                break
            fi
        done
    fi
fi

if [[ -n "${HWMON_DIR}" ]]; then
    log_msg "Using hwmon directory: ${HWMON_DIR}"
else
    log_msg "No hwmon directory found for ${AMD_CARD:-<none>}. Temperature/power readings may be missing."
fi

# === Start background kernel log follower ===
log_msg "Starting kernel log follower (journalctl -k -f)..."
journalctl -k -f -o short-iso \
    | grep -iE "amdgpu|gpu|ring|reset|timeout|parser" \
    >> "${KERNEL_LOG}" 2>&1 &
KERNEL_FOLLOW_PID=$!

cleanup() {
    log_msg "Stopping kernel log follower (PID ${KERNEL_FOLLOW_PID})..."
    if kill -0 "${KERNEL_FOLLOW_PID}" 2>/dev/null; then
        kill "${KERNEL_FOLLOW_PID}" || true
    fi
}
trap cleanup INT TERM EXIT

log_msg "Starting main sampling loop (interval: ${INTERVAL_SEC}s)..."
log_msg "Press Ctrl+C to stop."

while true; do
    now_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

    gpu_temp="N/A"
    vram_temp="N/A"
    power_w="N/A"

    if [[ -n "${HWMON_DIR}" ]]; then
        for tfile in "${HWMON_DIR}"/temp*_input; do
            [[ -e "${tfile}" ]] || continue
            label_file="${tfile%_input}_label"
            label="temp"
            if [[ -f "${label_file}" ]]; then
                label=$(<"${label_file}")
            fi
            value_mdeg=$(<"${tfile}")
            value_c=$(awk -v v="${value_mdeg}" 'BEGIN { printf("%.1f", v / 1000.0) }')
            case "${label,,}" in
                *edge*|*gpu*)
                    gpu_temp="${value_c}"
                    ;;
                *junction*|*hotspot*)
                    vram_temp="${value_c}"
                    ;;
            esac
        done

        if [[ -f "${HWMON_DIR}/power1_input" ]]; then
            p_uw=$(<"${HWMON_DIR}/power1_input")
            power_w=$(awk -v p="${p_uw}" 'BEGIN { printf("%.1f", p / 1000000.0) }')
        fi
    fi

    gpu_clock="N/A"
    vram_clock="N/A"

    if [[ -n "${AMD_CARD}" ]]; then
        dev_path="/sys/class/drm/${AMD_CARD}/device"

        if [[ -f "${dev_path}/pp_dpm_sclk" ]]; then
            current_line=$(grep '\*' "${dev_path}/pp_dpm_sclk" || true)
            if [[ -n "${current_line}" ]]; then
                gpu_clock=$(awk '{print $2}' <<< "${current_line}")
            fi
        fi

        if [[ -f "${dev_path}/pp_dpm_mclk" ]]; then
            current_line=$(grep '\*' "${dev_path}/pp_dpm_mclk" || true)
            if [[ -n "${current_line}" ]]; then
                vram_clock=$(awk '{print $2}' <<< "${current_line}")
            fi
        fi
    fi

    {
        printf '%s ' "${now_utc}"
        printf 'gpu_clock=%s ' "${gpu_clock}"
        printf 'vram_clock=%s ' "${vram_clock}"
        printf 'gpu_temp_C=%s ' "${gpu_temp}"
        printf 'vram_hotspot_C=%s ' "${vram_temp}"
        printf 'power_W=%s\n' "${power_w}"
    } >> "${MAIN_LOG}"

    sleep "${INTERVAL_SEC}"
done
