# Contributing to GHULbenchmark

Thank you for your interest in contributing to GHULbenchmark!

## How to Contribute

### Reporting Issues

If you find a bug or have a feature request, please open an issue on GitHub:
- Describe the problem or feature clearly
- Include your system information (OS, kernel, hardware)
- For bugs: include steps to reproduce

### Pull Requests

We welcome pull requests! Here's how to contribute:

1. **Fork the repository** on GitHub
2. **Create a feature branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes** following the coding style:
   - All comments in English
   - Use `set -euo pipefail` for scripts
   - Enforce `LANG=C` / `LC_ALL=C` for predictable parsing
   - Test your changes on Manjaro/Arch Linux
4. **Commit your changes** with clear messages:
   ```bash
   git commit -m "Add feature: description"
   ```
5. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```
6. **Open a Pull Request** on GitHub

### Code Style

- **Bash scripts**: Follow existing patterns, use `cap` helper for optional tools
- **Comments**: English only
- **Output**: Can be localized, but scripts enforce `LANG=C` for parsing
- **Error handling**: Use `set -euo pipefail`, wrap optional tools with `cap`

### Testing

Before submitting a PR:
- Test on Manjaro Linux (primary platform)
- Ensure all scripts run without errors
- Check that JSON output is valid
- Verify sensor logging works correctly

### License

By contributing, you agree that your contributions will be licensed under the GPL-3.0 license.

## Development Setup

```bash
# Create directory and clone repository
mkdir ~/GHULbenchmark
cd ~/GHULbenchmark
git clone https://github.com/g-h-u-l/GHULbenchmark.git .
chmod +x *.sh tools/*.sh
./firstrun.sh  # Check dependencies
```

## Questions?

Open an issue or discussion on GitHub if you have questions about contributing.

