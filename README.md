# GHULbenchmarkmark – Gaming Hardware Using Linux Benchmark Suite

![Linux](https://img.shields.io/badge/OS-Linux-111?logo=linux&logoColor=white)
![Arch Based](https://img.shields.io/badge/Distro-Arch%20Based-0f94d2?logo=arch-linux&logoColor=white)
![Manjaro](https://img.shields.io/badge/Manjaro-Supported-35bf5c?logo=manjaro&logoColor=white)
![Shell](https://img.shields.io/badge/Shell-Bash-4eaa25?logo=gnu-bash&logoColor=white)
![Language](https://img.shields.io/badge/Language-Bash%20%7C%20POSIX-005f91)
![Best on AMD](https://img.shields.io/badge/Best%20Experience-AMDGPU-ea1d22?logo=amd&logoColor=white)
![CPU](https://img.shields.io/badge/CPU-7zip%20%7C%20sysbench%20%7C%20stress--ng-blueviolet)
![GPU](https://img.shields.io/badge/Graphics-Vulkan%20%7C%20OpenGL-6a1bb3)
![RAM](https://img.shields.io/badge/RAM-mbw-lightgrey)
![Network](https://img.shields.io/badge/Network-iperf3-5b5b5b)
![JSON](https://img.shields.io/badge/Output-JSON-orange?logo=json&logoColor=white)
![Open Source](https://img.shields.io/badge/Open%20Source-GPLv3-blue?logo=gnu&logoColor=white)
![CPU](https://img.shields.io/badge/CPU-7zip%20%7C%20sysbench%20%7C%20stress--ng-blueviolet)
![Best on AMD](https://img.shields.io/badge/Best%20Experience-AMDGPU-ea1d22?logo=amd&logoColor=white)
![Purpose](https://img.shields.io/badge/Gaming-Linux%20Benchmarking-8a2be2)

**GHULbenchmarkmark** is a Linux-native benchmark suite for real-world gaming rigs.  
It focuses on transparent, reproducible benchmarking and hardware analysis – built and tested on **Manjaro Linux** (Arch-based), and designed to run on Arch and Arch forks (and other distros, if the required tools are available).

> Goal: provide a 3DMark-like experience for Linux gamers, using scriptable, open tools and machine-readable results.

## ✨ Overview

GHULbenchmark consists of three main components:

- `firstrun.sh` – First-run helper for dependency checking and hardware log generation.
- `ghul-benchmark.sh` – Benchmark runner producing JSON result files plus logs.
- `ghul-analyze.sh` – Compares two GHULbenchmark runs and prints a human-readable analysis.

All scripts:
- enforce `LANG=C` / `LC_ALL=C`,
- are written in Bash,
- and developed on Manjaro Linux.

## 📁 Repository layout

```
GHULbenchmark/
├── firstrun.sh
├── ghul-benchmark.sh
├── ghul-analyze.sh
├── logs/
└── results/
```

## 🧰 Dependencies

- jq
- dmidecode, lspci, lshw
- glmark2, vkmark, glxinfo
- gputest
- iperf3
- speedtest-cli (optional)
- mbw
- sysbench, stress-ng
- 7z (p7zip)

On Arch/Manjaro, `firstrun.sh` can install missing packages automatically when run as root.

## 🚀 Installation

```
git clone https://github.com/g-h-u-l/GHULbenchmark.git
cd GHULbenchmark
chmod +x firstrun.sh ghul-benchmark.sh ghul-analyze.sh
```

## 🧪 First run

User mode:
```
./firstrun.sh
```

Root mode:
```
sudo ./firstrun.sh
```

## 🏃 Benchmark run

```
./ghul-benchmark.sh
```

Produces a JSON result in `results/` plus logs in `logs/`.

## 📊 Compare two runs

```
./ghul-analyze.sh old.json new.json
```

## ⚠️ Notes

Includes stress tests. Ensure proper cooling.

## 🗺️ Roadmap
- More GPU benchmarks / Unigine integration (licensing permitting)
- Proton-based benchmarks
- HTML/markdown report generator
- Extended scoring

## 📜 License

GPLv3 (or your chosen license).

## 👨‍💻 Author

Maintained by: https://github.com/g-h-u-l
