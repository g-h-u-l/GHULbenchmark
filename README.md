# GHULbench – Gaming Hardware Using Linux Benchmark Suite

**GHULbench** is a Linux-native benchmark suite for real-world gaming rigs.  
It focuses on transparent, reproducible benchmarking and hardware analysis – built and tested on **Manjaro Linux** (Arch-based), and designed to run on Arch and Arch forks (and other distros, if the required tools are available).

> Goal: provide a 3DMark-like experience for Linux gamers, using scriptable, open tools and machine-readable results.

## ✨ Overview

GHULbench consists of three main components:

- `firstrun.sh` – First-run helper for dependency checking and hardware log generation.
- `ghul-benchmark.sh` – Benchmark runner producing JSON result files plus logs.
- `ghul-analyze.sh` – Compares two GHULbench runs and prints a human-readable analysis.

All scripts:
- enforce `LANG=C` / `LC_ALL=C`,
- are written in Bash,
- and developed on Manjaro Linux.

## 📁 Repository layout

```
GHULbench/
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
git clone https://github.com/g-h-u-l/GHULbench.git
cd GHULbench
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
