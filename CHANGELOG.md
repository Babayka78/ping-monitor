# Changelog

All notable changes to the Pi Ping Monitor project will be documented in this file.

## [Unreleased]

### Added
- macOS Keychain integration for secure hotspot password storage.

### Changed
- **Security (Keychain):** `HOTSPOT_PASSWORD` is no longer stored in plaintext within the configuration file (`/etc/ping-monitor/config.env`).
- **Installer script (`install.sh`):**
  - Removed hotspot password generation and storage in the config file.
  - Added the `save_hotspot_password_to_mac` function. After SSH keys are set up, this function securely writes the user-provided password directly to the macOS Keychain (`security add-generic-password`).
  - Old Keychain entries are now safely deleted before adding new ones to prevent conflicts (`security delete-generic-password`).
- **Monitor script (`ping-monitor.sh`):**
  - Removed password checks from the local configuration file.
  - During a failover event, the password is fetched dynamically from the Mac's Keychain via an SSH call and passed directly to the `networksetup` utility.
- **General Refactoring:** based on code review, implemented graceful shutdown (signal trapping), `flock` to prevent concurrent script executions, and improved debug log output.
