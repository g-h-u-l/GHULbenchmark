# GHUL Benchmark v0.4.0 Release Notes

**Release Date:** 2025-12-12

## 🎉 Major Features

### Upload & Sharing System
- **Session-based upload API** (`--share` flag)
  - Upload benchmark results and sensor data to shared.ghul.run
  - Session tracking with step-by-step progress monitoring
  - Anti-cheat validation (timestamp checks, step order validation)
  - File signing with Ed25519/RSA keys for authenticity

### Hellfire Stress Tests
- **Extreme hardware stress testing** (`--hellfire` flag)
  - CPU, RAM, GPU, and full-system cooler tests
  - Automatic sensor monitoring during stress tests
  - Thermal safety monitoring with automatic abort on critical temperatures
  - Three intensity modes:
    - **Default**: 300s CPU/RAM, 180s GPU/Cooler
    - **Wimp mode** (`--wimp`): 60s per test, GPU MSAA=2 (reduced intensity)
    - **Insane mode** (`--insane`): 600s per test, 4K GPU resolution, minimal cooldown

### Cooldown System
- Automatic cooldown phases between tests
  - 180 seconds before Hellfire tests (after benchmark)
  - 300 seconds between GPU and Cooler tests
  - Skipped in `--insane` mode ("You requested insane, you get insane")

## ⚠️ Important Notes

### Upload Feature Status
**The upload feature (`--share`) is currently in beta and not yet publicly available.**

- Uploads are restricted via IP whitelist
- The web frontend for viewing shared results is still under development
- Public access will be enabled in v0.5.0 (once the frontend is complete)

If you try to use `--share` and receive an "access-denied" message, this is expected behavior. The feature will be fully enabled in v0.5.0.

## 🔧 Technical Improvements

- Python 3.13 compatibility (replaced deprecated `cgi` module)
- Unified timestamp system (all files use benchmark timestamp)
- Improved error handling and user feedback
- Help text updated with `firstinstall.sh` recommendation

## 📝 Usage Examples

```bash
# Standard benchmark
./ghul-benchmark.sh

# Benchmark with upload (if whitelisted)
./ghul-benchmark.sh --share

# Benchmark + Hellfire stress tests
./ghul-benchmark.sh --hellfire

# Hellfire in wimp mode (60s per test)
./ghul-benchmark.sh --hellfire --wimp

# Hellfire in insane mode (maximum intensity)
./ghul-benchmark.sh --hellfire --insane

# Full workflow: benchmark + hellfire + upload
./ghul-benchmark.sh --share --hellfire --wimp
```

## 🐛 Bug Fixes

- Fixed `local` variable usage outside functions
- Fixed session finalization timing (now after all uploads)
- Fixed step sequence to include "storage" phase
- Fixed Ed25519 signing compatibility with OpenSSL 3.x

## 📦 Installation

See `README.md` for full installation instructions.

Quick install (Manjaro/Arch):
```bash
sudo ./firstinstall.sh
```

## 🔗 Links

- **GitHub**: https://github.com/g-h-u-l/GHULbenchmark
- **Project Page**: https://ghul.run

---

**Note:** This release includes significant new features. Please test thoroughly before using in production environments.

