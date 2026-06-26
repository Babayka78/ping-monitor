# Changelog

All notable changes to the Pi Ping Monitor project will be documented in this file.

## [Unreleased]

### Added
- Added a restricted macOS helper script (`ping-monitor-helper.sh`) that is deployed to the Mac and used for all supported remote actions.
- Added dedicated ED25519 SSH key generation and deployment for monitor-to-Mac communication.
- Added reusable installer UI helpers for cleaner interactive output.
- Added typed installer prompts with validation for IPv4 addresses, ports, non-empty values, and passwords.
- Added retry logic for Mac Wi-Fi switching to handle cases where the Android hotspot takes a few seconds to appear.
- Added automatic dashboard port fallback when the default HTTP port is already occupied.
- Added explicit SSH timeout and keepalive safeguards for remote calls to the Mac.

### Changed
- Reworked the overall project architecture to use a restricted Mac-side helper instead of arbitrary remote command execution.
- Reworked the installer flow to distinguish first-time installation from re-installation.
- Re-installation now loads current defaults from `/etc/ping-monitor/config.env` instead of reusing the local project `config.env`.
- Values loaded from the local project `./config.env` are marked only during the initial installation flow.
- Re-installation prompts no longer mark every field individually and now explain that existing values are loaded from the installed system configuration.
- Renamed `TARGET_SIDE` to `CROSS_CHECK` to better describe the purpose of the secondary reachability check.
- Redesigned hotspot handling so hotspot-related settings are treated separately during re-installation.
- The hotspot password is no longer shown in installer summaries and must be entered again when hotspot settings are changed during re-installation.
- Updated installer summaries and prompts to better distinguish visible defaults, hidden values, and existing installed settings.
- Reworked README documentation to match the current architecture, installation flow, failover logic, recovery behavior, and limitations.
- Cleaned up `config.env.example` and simplified its formatting.

### Security
- Removed plaintext hotspot password storage from the Linux host.
- The hotspot password is now transferred to the Mac during installation in obfuscated form and decoded only at runtime by the Mac helper.
- SSH access to the Mac is now restricted through a forced-command entry in `authorized_keys`.
- Disabled interactive shell access, PTY allocation, port forwarding, X11 forwarding, and agent forwarding for the monitor SSH key.
- Replaced direct shell sourcing of the runtime state file with a safer text parsing approach.
- Added early configuration validation in `ping-monitor.sh` to reject invalid host, port, and integer values before the monitor loop starts.

### Fixed
- Prevented the monitoring loop from hanging indefinitely when SSH connectivity becomes unresponsive.
- Improved handling of expected non-zero exit codes from the Android Automate HTTP trigger during failover.
- Improved Mac hotspot switching reliability by retrying the Wi-Fi change instead of failing immediately.
- Reduced re-installation UX confusion around prefilled values, hidden secrets, and hotspot password handling.
- Improved coexistence with existing web servers by avoiding hard failure when the default dashboard port is already in use.