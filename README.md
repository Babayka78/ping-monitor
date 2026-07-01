# 🔄 Pi Ping Monitor — Automatic Network Failover

A Linux watchdog (running on a Raspberry Pi 4 in my case) that monitors your ISP router and automatically fails over to a mobile phone hotspot when the router goes down. Once the connection recovers, the system logs the outage and resets — no manual intervention required.

## Background / Why This Exists

My ISP router periodically drops the connection for about 6 minutes at a time. Even after the ISP replaced the router, the dropouts persisted. To stay continuously connected during these outages and collect detailed downtime statistics to show my ISP, I needed a reliable failover solution.

While the typical approach would be to buy a new home router with built-in 4G/LTE failover capabilities (via a USB modem or SIM slot), I didn't want to incur unnecessary extra expenses. Instead, I built this zero-cost, fully automated failover system using the hardware I already had running in my home network.

## How It Works

```text
                            ┌────────────────────┐
                            │     ISP Router     │◀── ISP
                            │ WAN: Public WAN IP │
                            │ LAN: 192.168.100.1 │
                            └───────▲────────────┘
                                    │
             ┌──────────────────────┴──────────────────────┐
             │                   Switch                    │
             └───────┬──────────────────────────────┬──────┘
                     │                              │
┌────────────────┐   │                              ▼
│  Secondary IP  │◀──┘                     ┌───────────────────────┐
│ 192.168.100.79 │ ping                    │  User Router          │
└────────────────┘ (monitor)               │ WAN: 192.168.100.40   │
                                           │ LAN: 192.168.0.1      │
                                           └────────┬──────────────┘
                                                    │
                            ┌───────────────────────┴───────────────────────┐
                            │                 Local Network                 │
                            └──┬────────────────────┬────────────────────┬──┘
                               │                    │                    │
             ┌──────────────┐  │            ┌───────▼──────┐     ┌───────▼──────┐
             │  Linux Host  │◀─┘            │ Android Phone│     │ Mac Computer │
             │ 192.168.0.197│──── HTTP ────▶│ 192.168.0.65 │     │ 192.168.0.173│
             └───────┬──────┘ enable hotspot│ Wi-Fi Hotspot│     └───────┬──────┘
                     ▼                      └───────┬──────┘             ▲
                     │                              ▲                    │
                     │                              └────────────────────┤
                     │                                                   │
                     │  SSH (check lid & reconnect)                      │
                     └───────────────────────────────────────────────────┘
                                                                         
```

### Failover Sequence

1. The **Linux host** continuously pings the ISP router (`192.168.100.1`) every 5 seconds.
2. When the ISP router **stops responding**, the Linux host:
   - Checks if the **Secondary IP** (`192.168.100.79`) on the same switch is also unreachable. This is an additional check to confirm that the ISP router itself stopped responding, and not that the local networking equipment (like the switch) hung up or lost power. This Secondary IP can be any device in the ISP router's subnet (`192.168.100.x`) that is constantly online (e.g., a video recorder, a LAN printer, or another computer). *(If you don't have such a device, you can leave this field empty during installation to safely skip this check).*
   - Pings the Mac (`192.168.0.173`) to verify it's online on the local network.
   - SSHs into the Mac to check the lid state (skips failover if the Mac is closed/sleeping).
   - Sends an HTTP trigger to the **Automate** app on the Android phone (`192.168.0.65`).
3. **Automate** (on the phone) disables Wi-Fi and enables the mobile hotspot.
4. The Linux host then SSHs into the **Mac** and switches the Mac's Wi-Fi network to the phone's hotspot.
5. The Linux host continues monitoring the ISP router every 30 seconds.
6. Once the ISP router responds **3 times consecutively**, the system logs the outage duration, and Automate automatically reverts the connection.

### Recovery (handled by Automate on Android)

The Automate flow on the Android phone monitors the ISP router's public WAN IP. After **60 consecutive successful pings** (~5 minutes), it automatically disables the hotspot and reconnects to the home Wi-Fi network.

Because the phone's hotspot is no longer available, macOS natively detects the loss of the network and **automatically reconnects** to its preferred home Wi-Fi network. No additional scripts or commands are required for the Mac's recovery.

### Automate Flow Diagram

For those reviewing the project architecture, here is the logical flow executed by the Android phone. You can simply import the provided `.flo` file into the Automate app rather than building this manually. *(The `.flo` file will be added to the repository in a future update.)*

```text
       ┌────────────────────────┐
       │     Flow Beginning     │
       └───────────┬────────────┘
                   │◀────────────────────────────────────┐
                   ▼                                     │
          /──────────────────\                           │
          │ Is Wi-Fi enabled?│─── NO ──▶┌──────────┐     │
          \──────────────────/          │ Delay 5s │─────┤
                   │ YES                └──────────┘     │
                   ▼                                     │
          /──────────────────\                           │
          │ Is Wi-Fi         │─── NO ──▶┌──────────┐     │
          │ connected?       │          │ Delay 5s │─────┘
          \──────────────────/          └──────────┘
                   │ YES
                   ▼
       ┌────────────────────────┐
       │      HTTP accept       │
       │ '/failover_a7b8c9x2k4' │
       └───────────┬────────────┘
                   ▼
       ┌────────────────────────┐
       │     HTTP response OK   │
       └───────────┬────────────┘
                   │◀───────────────────────┐
                   ▼                        │
       ┌────────────────────────┐           │
       │     Disable Wi-Fi      │           │
       └───────────┬────────────┘           │
                   ▼                        │
       ┌────────────────────────┐           │
       │  Enable Wi-Fi hotspot  │           │
       └───────────┬────────────┘           │
                   ▼                        │
       ┌────────────────────────┐           │
       │        Delay 2s        │           │
       └───────────┬────────────┘           │
                   ▼                        │
          /──────────────────\              │
          │ Is Wi-Fi hotspot │─── NO ───────┘
          │     enabled?     │
          \──────────────────/
                   │ YES
                   ▼
       ┌────────────────────────┐
       │       Play sound       │
       └───────────┬────────────┘
                   │
                   │◀─────────────────────────┐
                   ▼                          │
       ┌────────────────────────┐             │
       │        Delay 5s        │             │
       └───────────┬────────────┘             │
                   ▼                          │
       ┌────────────────────────┐             │
       │ Set ping_count to 0    │             │
       └───────────┬────────────┘             │
                   ▼                          │
                   │◀──────────────────────┐  │
                   ▼                       │  │
          /────────────────────\           │  │
          │ Ping ISP public WAN│── NO ─────┼──┘
          │ IP XXX.XXX.XXX.XXX │           │
          \────────────────────/           │
                   │ YES                   │
                   ▼                       │
       ┌────────────────────────┐          │
       │        Delay 5s        │          │
       └───────────┬────────────┘          │
                   ▼                       │
       ┌────────────────────────┐          │
       │ ping_count =           │          │
       │     ping_count + 1     │          │
       └───────────┬────────────┘          │
                   ▼                       │
          /──────────────────\             │
          │ ping_count >= 60?│─── NO ──────┘
          \──────────────────/
                   │ YES
                   ▼
       ┌────────────────────────┐
       │        Delay 2m        │
       └───────────┬────────────┘
                   ▼
       ┌────────────────────────┐
       │ Disable Wi-Fi hotspot  │
       └───────────┬────────────┘
                   ▼
       ┌────────────────────────┐
       │        Delay 2s        │
       └───────────┬────────────┘
                   ▼
       ┌────────────────────────┐
       │      Enable Wi-Fi      │
       └───────────┬────────────┘
                   ▼
       ┌────────────────────────┐
       │        Delay 2s        │
       └───────────┬────────────┘
                   │
                   └───────────────────────────▶ (Loop to Start)
```

## Limitations

> **This is not a universal failover solution.** It is designed for a specific failure mode and network topology.

| Limitation | Explanation |
|---|---|
| **Router failure only** | The system activates only when the ISP router itself stops responding. If the router is up but the ISP's upstream connection is down, failover will **not** trigger. |
| **Static (public) IP required** | The ISP connection must have a public static IP address for the Automate recovery flow to ping it from the mobile network. |
| **Mac must be awake** | The Mac's lid must be open (not in clamshell mode). The Linux host checks `AppleClamshellState` via SSH before triggering failover. |
| **Automate app required** | The Android phone must be running the [Automate](https://llamalab.com/automate/) app with the failover flow active and connected to the home Wi-Fi. |
| **Single-network topology** | All devices (Linux host, Mac, phone) must be on the same local network and reachable before the outage occurs. |
| **Dashboard Security** | The Nginx web dashboard has no built-in rate limiting or authentication. It is intended for secure local networks only. |

## Prerequisites

| Component | Purpose |
|---|---|
| **Linux host** | Runs the monitoring script as a systemd service |
| **Android phone** with [Automate](https://llamalab.com/automate/) | Receives HTTP triggers and manages hotspot on/off |
| **Mac computer** | Automatically switches Wi-Fi to the phone hotspot |
| **SSH key pair** | Passwordless SSH from the Linux host to the Mac |
| **Nginx** | Serves a simple web dashboard for viewing outage logs |

## Installation

> [!NOTE]
> All of the following installation steps and commands must be executed on your Linux host.

### 1. Clone the repository

```bash
git clone https://github.com/Babayka78/pi_ping_monitor.git
cd pi_ping_monitor
```

### 2. Run the interactive installer


```bash
sudo bash install.sh
```

**Optional: Pre-filled Installation**
If you want to skip typing credentials manually, you can create a `config.env` file in the project root directory *before* running `install.sh`. The installer will load these values as defaults.

> [!NOTE]
> During the interactive prompts, any default value that was successfully loaded from a local `./config.env` file will be marked with an asterisk `*` (e.g., `Mac Computer IP (TARGET_MAC)                [192.168.0.173*]: `). This helps you distinguish your previously saved pre-fill settings from dynamically generated script defaults.
> 
> **Re-installations:** If an existing system configuration is detected (`/etc/ping-monitor/config.env`), the installer will use it instead of the local file. The asterisk markers are hidden during re-installations to keep the interface clean. Furthermore, because the Linux host never stores the Mac's hotspot password locally, you will always be required to re-enter it when re-installing.

> [!WARNING]
> This local file is used **only** to pre-fill the installer. It is not used by the running systemd service. If you put your `HOTSPOT_PASSWORD` in this file, remember that it is stored in plain text here, so you should delete this file after installation.

The installer is fully interactive and will automatically guide you through:
- Detecting your network environment and suggesting default IP addresses.
- Prompting you for the remaining settings (Hotspot SSID, Automate token, etc.).
- Generating a dedicated SSH key and helping you copy it to your Mac (`ssh-copy-id`).
- Deploying the restricted SSH helper script (`ping-monitor-helper.sh`) to the Mac and locking the SSH key to it.
- Installing and configuring Nginx for the web dashboard (on a dynamically selected port).
- Installing the systemd service.

### 3. Post-install self-tests

At the end of the installation, the installer automatically runs a self-test suite that verifies:
- The `ping-monitor` systemd service is active and running.
- The Nginx web dashboard is reachable (HTTP 200) on the configured port.
- The SSH helper on the Mac is responsive (`check_lid` returns `Yes`, `No`, or `Unknown`).

A summary of test results is printed to the console. You can always re-check the service status manually:

```bash
systemctl status ping-monitor.service
```

## Uninstallation

To fully remove the monitor from your system (including the Mac helper), run:

```bash
sudo bash uninstall.sh
```

The uninstaller will interactively:
1. **Stop and disable** the `ping-monitor.service`.
2. **Connect to the Mac** via SSH (using your Mac password) to:
   - Remove the `ping-monitor` entry from `~/.ssh/authorized_keys`.
   - Remove the `~/.ping-monitor/` directory (config and helper script).
   - Remove the Linux host's key from `~/.ssh/known_hosts` on the Mac.
3. **Remove all Linux components**: systemd unit, binary, logs (`/var/log/ping-monitor`), state (`/var/lib/ping-monitor`), config (`/etc/ping-monitor`), and generated SSH keys.
4. **Remove the Nginx config** and optionally uninstall Nginx entirely if it was only used for the dashboard.

## Configuration

The installer automatically creates `/etc/ping-monitor/config.env` for you. If you ever need to change settings later, edit this file and restart the service:

```bash
sudo nano /etc/ping-monitor/config.env
sudo systemctl restart ping-monitor.service
```

| Variable | Description | Example |
|---|---|---|
| `TARGET_MAIN` | ISP router IP to monitor (Mandatory) | `192.168.100.1` |
| `CROSS_CHECK` | Secondary device on the same switch (Optional, leave empty to skip) | `192.168.100.79` |
| `TARGET_MAC` | Mac computer IP on local network (Mandatory) | `192.168.0.173` |
| `HOTSPOT_SSID` | Phone hotspot Wi-Fi name | `MyHotspot` |
| `HOTSPOT_PASSWORD` | *(Not stored on Linux host!)* See Security section | N/A |
| `AUTOMATE_HOST` | Android phone IP (Mandatory) | `192.168.0.65` |
| `AUTOMATE_PORT` | Automate HTTP server port | `7801` |
| `AUTOMATE_ENDPOINT` | Secret endpoint path for the trigger | `failover_abc123` |
| `SSH_USER` | Username for SSH into the Mac | `john` |
| `SSH_KEY_PATH` | Path to the SSH private key | `/home/username/.ssh/id_ed25519_mac` |
| `MAIN_INTERVAL` | Ping interval when router is up (seconds) | `5` |
| `SIDE_INTERVAL` | Ping interval when router is down (seconds) | `30` |
| `DEBUG` | Enable debug logging to `/var/log/ping-monitor/debug.log` | `true` |
| `WEB_PORT` | Port for the Nginx dashboard | `8080` |

## Web Dashboard

The included Nginx config serves a web UI showing the outage log. The installer will display the exact URL (e.g., `http://192.168.0.197:8080/`) at the end of the setup. Each log entry records:

```
DDMMYY HH:MM:SS - HH:MM:SS [optional: secondary device IP if also down]
```

- **Start timestamp** — when the router went down
- **End timestamp** — when it recovered
- If the secondary device was also unreachable, its IP is appended

## Security

### Restricted SSH Access

The installer deploys a restricted helper script (`ping-monitor-helper.sh`) to the Mac at `~/.ping-monitor/ping-monitor-helper.sh`. The SSH key used by the Linux host is locked to this helper via a `command=` forced-command restriction in `~/.ssh/authorized_keys`. This means the Linux host can **only** execute two specific commands on the Mac:

| Command | Effect |
|---|---|
| `check_lid` | Returns the current lid state (`Yes` / `No` / `Unknown`) |
| `switch_wifi` | Switches the Mac's active Wi-Fi to the configured hotspot |

Any other SSH command is denied with `Access Denied`. Port forwarding, X11, and agent forwarding are also explicitly disabled using `no-port-forwarding,no-X11-forwarding,no-agent-forwarding` options in the key restriction.

### Password Storage

For maximum security, the hotspot password is **never stored on the Linux host**. It is pushed directly to the Mac during installation.
On the Mac side, it lives in `~/.ping-monitor/config.env` (mode `600`) in an obfuscated form — it is **not** stored in plaintext. The helper script decodes it at runtime, immediately before passing it to `networksetup`. If the Linux host is ever compromised, the attacker cannot recover the Wi-Fi password from it.

## Testing / Simulating a Failure

You can simulate an ISP router outage on the Linux host using `iptables` — no need to physically unplug anything:

```bash
# Block the ISP router (simulate outage)
sudo iptables -A OUTPUT -d 192.168.100.1 -j DROP

# Restore the ISP router (simulate recovery)
sudo iptables -D OUTPUT -d 192.168.100.1 -j DROP

# List current OUTPUT rules
sudo iptables -L OUTPUT -v -n
```

After blocking the route, the monitor will detect the failure within one `MAIN_INTERVAL` cycle (default: 5 seconds), trigger the Automate flow on the phone, and switch the Mac to the hotspot. After restoring the route, the monitor will confirm recovery after 3 consecutive successful pings.

> [!NOTE]
> When the phone activates the hotspot, it immediately drops Wi-Fi — so the `curl` call from the Linux host may time out (exit codes 28 or 52). This is expected behaviour, not an error. The Automate flow's immediate responsiveness is a deliberate trade-off against Android sleep-timer quirks.

## Project Structure

```
pi_ping_monitor/
├── ping-monitor.sh            # Main monitoring script (runs as a systemd daemon)
├── ping-monitor-helper.sh     # Restricted SSH helper deployed to the Mac
├── ping-monitor.service       # systemd unit file
├── ping-monitor.conf          # Nginx config template for the web dashboard
├── ping-monitor.conf.example  # Nginx config example (reference copy)
├── install.sh                 # Interactive installer
├── uninstall.sh               # Interactive uninstaller
├── config.env.example         # Configuration template
├── CHANGELOG.md               # Project change history
├── .gitignore
└── README.md
```

## Outage Logging

The system automatically records the duration of each outage to `/var/log/ping-monitor/outages.log`. Outage entries are written only after the connection is fully restored and confirmed.

There are three possible types of log entries:

1. **Service Lifecycle Events:**
   The monitor records its own startup and shutdown events. This ensures a complete operational history and prevents the web dashboard from rendering an empty page on fresh installs.
   **Format:** `YYYY-MM-DD HH:MM:SS - ping-monitor started|stopped`
   *Example:* `2026-07-01 10:18:25 - ping-monitor started`

2. **Only the ISP router failed:**
   If the ISP router goes down but the secondary device (`CROSS_CHECK`) remains pingable, it indicates a partial failure (e.g., just the router hanging).
   **Format:** `DDMMYY HH:MM:SS - HH:MM:SS`
   *Example:* `200625 14:32:10 - 14:35:47`

3. **Both ISP router and secondary device failed:**
   If the ISP router goes down and the secondary device is also unreachable, it usually indicates a power loss or a failure of the switch connecting them. In this case, the IP of the unreachable secondary device is appended to the log entry.
   **Format:** `DDMMYY HH:MM:SS - HH:MM:SS <CROSS_CHECK>`
   *Example:* `200625 19:01:33 - 19:02:15 192.168.100.79`

## License

This project is provided as-is for educational and personal use.
