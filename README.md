# GHUL - Gaming Hardware Using Linux

**G-H-U-L** is a comprehensive benchmarking system for Linux gaming hardware. 
The project aims to build a community database to document 
and compare hardware performance under Linux.

- **GitHub**: https://github.com/g-h-u-l/
- **Project Page**: https://ghul.run

## Why GHUL?

Because it doesn't exist yet – and because we can! 😊

GHUL provides:
- **Comprehensive hardware benchmarks** (CPU, RAM, GPU, Network)
- **Automatic hardware detection** based on mainboard information
- **Comparison tools** for benchmark results
- **Gaming suitability assessment** for your hardware
- **Sensor data logging** during benchmarks
- **JSON-based results** for easy analysis and integration
- **Upload & sharing** (beta, IP whitelist) - upload results to shared.ghul.run
- **Hellfire stress tests** - extreme hardware torture tests (CPU, RAM, GPU, Cooler)

## Project Structure

```
GHULbenchmark/
├── firstrun.sh              # Initialization (Dependencies, Hardware Logs, Host ID)
├── ghul-benchmark.sh        # Main benchmark runner
├── ghul-analyze.sh          # Compare two benchmark results
├── ghul-quickcheck.sh       # Gaming suitability assessment for one result
├── ghul-report.sh           # Sensor data analysis and thermal report
├── .ghul_host_id.json       # Host ID based on mainboard (created by firstrun.sh)
├── db/                      # Database (for future versions)
├── results/                 # JSON benchmark results
├── logs/                    # Hardware logs and sensor data
└── tools/                   # Internal tools (sensor logging helper)
```

## Installation

GHULbenchmark should be cloned into a user directory (e.g., `~/GHULbenchmark`) and all scripts should be run from within that directory. This ensures all scripts know where to find the necessary files and directories.

### Step-by-Step Installation

```bash
# Update your system first:
sudo pacman -Syu

# 1. Install git (if not already installed)
# On Arch/Manjaro:
sudo pacman -S git

# On Debian/Ubuntu:
sudo apt install git

# 2. Clone repository
cd ~/
git clone https://github.com/g-h-u-l/GHULbenchmark.git
cd GHULbenchmark

# 3. Install dependencies (recommended)
sudo ./firstinstall.sh

# Or manually:
sudo pacman -S glmark2 vkmark sysbench mbw stress-ng p7zip mesa-demos jq iperf3 speedtest-cli gamescope lm_sensors
# For mbw (if not in repos):
pamac build mbw   # or: yay -S mbw
```

**Important:** All GHUL scripts must be run from within the `GHULbenchmark` directory. The scripts automatically detect their location and use relative paths for all operations.

## Quick Start

### 1. Initialization

Run `firstrun.sh` to set up the system:

```bash
# As regular user: Checks dependencies and shows installation hints
./firstrun.sh

# As root (sudo): Automatically installs missing dependencies and creates hardware logs
sudo ./firstrun.sh
```

**What happens:**
- Checks/installs required dependencies (glmark2, vkmark, sysbench, etc.)
- Creates hardware logs (CPU, GPU, Mainboard, RAM)
- Generates `.ghul_host_id.json` based on mainboard information
  - The Host ID remains the same as long as the mainboard type is unchanged
  - A new ID is generated when the mainboard is changed
- Creates udev rule for storage temperature access (allows reading storage temps without root)
  - **Important**: Make sure you are in the `disk` group for this to work:
    ```bash
    sudo usermod -aG disk $USER
    ```
    Then log out and back in, or run `newgrp disk` in a new terminal.

### 2. Run Benchmark

```bash
# Standard benchmark
./ghul-benchmark.sh

# With upload (beta, IP whitelist - see below)
./ghul-benchmark.sh --share

# With Hellfire stress tests
./ghul-benchmark.sh --hellfire

# Hellfire in wimp mode (60s per test, reduced intensity)
./ghul-benchmark.sh --hellfire --wimp

# Hellfire in insane mode (maximum intensity, 4K GPU)
./ghul-benchmark.sh --hellfire --insane

# Full workflow: benchmark + hellfire + upload
./ghul-benchmark.sh --share --hellfire --wimp
```

**What is tested:**
- **RAM**: mbw (Memcpy), sysbench (Sequential Write), dmidecode (RAM configuration)
- **CPU**: stress-ng (Matrix + Crypt), 7-Zip compression
- **GPU**: glmark2, vkmark, GpuTest FurMark
- **Network**: iperf3 (TCP/UDP loopback), speedtest-cli (Internet)

**Output:**
- JSON file in `results/YYYY-mm-dd-HH-MM-hostname.json`
- Detailed logs in `logs/runs/`
- Sensor data in `logs/sensors/` (during benchmark)

### 3. Analyze Results

#### Check Gaming Suitability

```bash
# Automatically use newest result
./ghul-quickcheck.sh results/

# Specific result
./ghul-quickcheck.sh results/2025-11-29-13-39-sharkoon.json
```

Shows a detailed assessment:
- CPU performance category
- **CPU temperature** (with warnings if > 80°C)
- RAM bandwidth and configuration
- GPU performance category
- **GPU temperatures** (Edge, Hotspot, Memory) with warnings
- Network performance
- Storage performance and **storage temperatures** (with warnings if > 55°C)
- Overall assessment for Linux gaming

#### Compare Two Benchmarks

```bash
./ghul-analyze.sh results/old.json results/new.json
```

Shows:
- Hardware changes (CPU, GPU, RAM, Mainboard)
- Performance deltas in percent
- RAM upgrade detection
- Summary score (RAM, CPU, GPU, Network)

#### Sensor Data Report

```bash
./ghul-report.sh
```

Shows min/max/average for:
- CPU temperature (with warnings if > 80°C)
- GPU temperatures (Edge, Hotspot, Memory) with vendor-specific warnings
- GPU power and fan
- Case fans (auto-discovered)
- Storage temperatures (with warnings if > 55°C)

**Temperature Warnings:**
- Warnings are displayed in **yellow** for high temperatures
- CRITICAL warnings are displayed in **red** for dangerous temperatures
- Helps identify thermal issues (e.g., old thermal paste, insufficient cooling)

## System Requirements

- **Distribution**: Arch-based (Manjaro, Arch Linux, EndeavourOS) – other distributions may work, but automatic installation is disabled
  
  **Why Arch?** Rolling release distributions are essential for Linux gaming performance. Strict update cycles are a gamer's worst enemy. For consistent, high-performance Linux gaming, you need a rolling release distro. Arch provides the latest versions of Steam, Proton, MangoHUD, Gamescope, Mesa drivers, and support for current hardware – all critical for modern Linux gaming.
  
  **Recommended Setup:** We explicitly recommend **Manjaro Linux with Cinnamon Desktop** (Community Edition). It provides a painless rolling release experience with lightdm and X11. X11 may be older, but it's ultra-stable, while Wayland (as used in distributions like cachyOS) can cause issues with some games. Most people just want to escape the Windows hell – we want to make the transition to the Linux heaven as pleasant as possible! 😊

- **Root privileges**: For `firstrun.sh` in root mode (hardware logs, dependencies)
- **Dependencies**: Automatically installed (in root mode) or manually:
  ```bash
  sudo pacman -S glmark2 vkmark sysbench mbw stress-ng p7zip mesa-demos jq iperf3 speedtest-cli gamescope lm_sensors
  ```

## Important Files

### `.ghul_host_id.json`

Created when running `firstrun.sh` (as root) for the first time and contains:

```json
{
  "vendor": "ASUS",
  "product": "ROG STRIX B550-F GAMING",
  "serial": "123456789",
  "id": "4d420f0c1ee87533"
}
```

- The **ID** remains the same as long as Vendor + Product remain unchanged
- A new ID is generated when the mainboard is changed
- Stored in all benchmark results

### Benchmark Results (JSON)

Each benchmark result contains:
- **environment**: Hardware info (CPU, GPU, RAM, Mainboard, OS, Kernel)
- **ram**: RAM performance and configuration
- **cpu**: CPU benchmark results
- **gpu**: GPU benchmark results
- **network**: Network performance (loopback + Internet)
- **timeline**: Timestamps for each benchmark phase
- **run_meta**: Start/end timestamps, duration

## Version 0.4.0

This version includes all features from v0.2 plus:

### Upload & Sharing System (Beta)
- ✅ **Session-based upload API** (`--share` flag)
  - Upload benchmark results and sensor data to shared.ghul.run
  - Session tracking with step-by-step progress monitoring
  - Anti-cheat validation (timestamp checks, step order validation)
  - File signing with Ed25519/RSA keys for authenticity
  - **Status**: Currently in beta, IP whitelist active, frontend pending (v0.5.0)

### Hellfire Stress Tests
- ✅ **Extreme hardware stress testing** (`--hellfire` flag)
  - CPU, RAM, GPU, and full-system cooler tests
  - Automatic sensor monitoring during stress tests
  - Thermal safety monitoring with automatic abort on critical temperatures
  - Three intensity modes:
    - **Default**: 300s CPU/RAM, 180s GPU/Cooler
    - **Wimp mode** (`--wimp`): 60s per test, GPU MSAA=2 (reduced intensity)
    - **Insane mode** (`--insane`): 600s per test, 4K GPU resolution, minimal cooldown
- ✅ **Cooldown system** - Automatic cooldown phases between tests (skipped in insane mode)

### Technical Improvements
- ✅ Python 3.13 compatibility (replaced deprecated `cgi` module)
- ✅ Unified timestamp system (all files use benchmark timestamp)
- ✅ Improved error handling and user feedback

**See [RELEASE_v0.4.0.md](RELEASE_v0.4.0.md) for full details.**

## Version 0.2

This version includes all features from v0.1 plus:

### Enhanced Sensor Detection
- ✅ **GPU Vendor Detection**: Automatic detection of AMD, NVIDIA, or Intel GPUs via `lspci`
- ✅ **NVIDIA GPU Support**: Full sensor support via `nvidia-smi` (temperature, fan, power)
- ✅ **AMD GPU Sensors**: Enhanced detection via `sensors -j` (edge, hotspot, memory, power, fan)
- ✅ **Fan Auto-Discovery**: Automatically detects up to 5 case fans from sensor data
- ✅ **Generic CPU Temperature**: Improved CPU temperature detection via `sensors -j`
- ✅ **Sensor Discovery Mode**: New `--dump-layout` mode for hardware analysis
  ```bash
  ./tools/ghul-sensors-helper.sh --dump-layout
  ```

### Temperature Warnings
- ✅ **CPU Temperature Warnings**: 
  - WARNING: > 80°C
  - CRITICAL: ≥ 100°C
- ✅ **GPU Temperature Warnings**:
  - Edge: WARNING > 85°C, CRITICAL ≥ 95°C
  - Hotspot: WARNING > 100°C, CRITICAL ≥ 110°C
  - Memory: WARNING > 90°C, CRITICAL ≥ 100°C
- ✅ **Storage Temperature Warnings**:
  - WARNING: > 55°C
  - CRITICAL: ≥ 70°C
- ✅ Warnings displayed in both `ghul-quickcheck.sh` and `ghul-report.sh`

### vkmark Handling
- ✅ **NVIDIA vkmark Support**: With newer kernels (6.17+) and Mesa, vkmark can work on NVIDIA GPUs
- ✅ **Automatic Fallback**: If vkmark fails on NVIDIA (score = 0 and no scenes found), score is set to `null` with explanatory note

### Improved JSON Output
- ✅ All sensor values properly sanitized (missing values = `null`)
- ✅ Valid JSON output guaranteed even with missing sensors

## Version 0.1

This version focused on:
- ✅ Local benchmark results (JSON files)
- ✅ Hardware detection and Host ID
- ✅ Comparison tools for two results
- ✅ Gaming suitability assessment
- ✅ Sensor data logging during benchmarks

**Not included (future versions):**
- Database integration (`db/` is planned for later)
- Web interface for viewing shared results (planned for v0.5.0)

## Tools

### `tools/ghul-sensors-helper.sh`

Automatically started by `ghul-benchmark.sh` and logs sensor data during the benchmark:
- CPU temperature (generic detection via `sensors -j`)
- GPU temperatures (vendor-specific):
  - **AMD**: Edge, Hotspot, Memory via `sensors -j`
  - **NVIDIA**: Temperature via `nvidia-smi`
  - **Intel/Unknown**: Not supported (values set to `null`)
- GPU power and fan
- Case fans (auto-discovered, up to 5 fans)

Output: `logs/sensors/YYYY-mm-dd-HH-MM-hostname-sensors.jsonl`

**Sensor Discovery Mode:**
```bash
./tools/ghul-sensors-helper.sh --dump-layout
```
Shows a human-readable overview of all detected sensor sources (no JSON output, for debugging/analysis only).

### `ghul-report.sh`

Analyzes sensor data for a benchmark result and shows min/max/average per phase.

Usage:
```bash
./ghul-report.sh [result.json]
```

If no file is specified, it automatically uses the newest result in `results/`.

## Benchmarks

### Official Benchmarks (ghul-benchmark.sh)

`ghul-benchmark.sh` uses only freely available software that can be downloaded from distribution repositories:
- **glmark2** – OpenGL benchmark
- **vkmark** – Vulkan benchmark
- **GpuTest FurMark** – GPU stress test and benchmark

These benchmarks are fully automated and will be part of the official community uploads.

### Unigine Benchmarks

The project supports Unigine benchmarks for manual execution:
- **Sanctuary**
- **Tropics**
- **Heaven**
- **Valley**
- **Superposition**

These are stored in `benchmarks/` and can be downloaded and run manually to compare with your setup.

**Note:** To make Unigine benchmark results readable and the engine scriptable, a Pro license is required, which is currently not available. If Unigine finds this project interesting, we'd be happy to receive a license! 😊

Unigine benchmarks will **not** be part of the official community uploads – glmark2, vkmark, and FurMark are sufficient for that purpose.

## License & Community

GHUL is a community project. The goal is to build a comprehensive database of Linux gaming hardware performance.

## Contributing

Feedback, bug reports, and improvement suggestions are welcome!

---

**G-H-U-L** – Gaming Hardware Using Linux  
*Because it doesn't exist yet – and because we can!* 🚀
