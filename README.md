# 🔄 Pi Ping Monitor — Automatic Network Failover

A Linux-based watchdog (in my case, a Raspberry Pi 4) that monitors your ISP router and automatically fails over to a mobile phone hotspot when the router goes down. Once the connection recovers, the system logs the outage and resets — no manual intervention required.

## Background / Why This Exists

My ISP router periodically drops the connection for about 6 minutes at a time. Even after the ISP replaced the router, the dropouts persisted. To stay continuously connected during these outages and collect detailed downtime statistics to show my ISP, I needed a reliable failover solution.

While the standard approach would be to buy a new home router with built-in 4G/LTE failover capabilities (via a USB modem or SIM slot), I didn't want to incur unnecessary extra expenses. Instead, I built this zero-cost, fully automated failover system using the hardware I already had running in my home network.

## How It Works

```text
                            ┌────────────────┐
                            │   ISP Router   │◀── ISP
                            │ 192.168.100.1  │
                            └───────▲────────┘
                                    │
             ┌──────────────────────┴──────────────────────┐
             │                   Switch                    │
             └───────┬──────────────────────────────┬──────┘
                     │                              │
┌────────────────┐   │                              ▼
│ Video Recorder │◀──┤                     ┌───────────────────────┐
│ 192.168.100.79 │   │ ping                │  User Router          │
└────────────────┘   │ (monitor)           │ WAN: 192.168.100.40   │
                     │                     │ LAN: 192.168.0.1      │
                     │                     └────────┬──────────────┘
                     │                              │
                     │      ┌───────────────────────┴───────────────────────┐
                     │      │                 Local Network                 │
                     │      └──┬────────────────────┬────────────────────┬──┘
                     │         │                    │                    │
             ┌───────┴──────┐  │            ┌───────▼──────┐     ┌───────▼──────┐
             │ Raspberry Pi │◀─┘            │ Android Phone│     │ Mac Computer │
             │ 192.168.0.197│── HTTP ──────▶│ 192.168.0.65 │     │ 192.168.0.173│
             └───────┬──────┘               └───────┬──────┘     └───────┬──────┘
                     │                              │                    │
                     │  SSH (check lid & reconnect) │   enable hotspot   │
                     ├──────────────────────────────┼────────────────────┤
                     │                              ▼                    │
                     │                       ┌──────────────┐            │
                     └──────────────────────▶│ Wi-Fi Hotspot│◀───────────┘
                                             └──────────────┘ connects to
```

### Failover Sequence

1. **Raspberry Pi** continuously pings the ISP router (`192.168.100.1`) every 5 seconds.
2. When the ISP router **stops responding**, the Pi:
   - Checks if the video recorder (`192.168.100.79`) on the same switch is also unreachable. This confirms whether the ISP router went down, or the switch itself lost power.
   - Pings the Mac (`192.168.0.173`) to verify it's online on the local network.
   - SSHs into the Mac to check the lid state (skips failover if the Mac is closed/sleeping).
   - Sends an HTTP trigger to the **Automate** app on the Android phone (`192.168.0.65`).
3. **Automate** (on the phone) disables Wi-Fi and enables the mobile hotspot.
4. The Pi then SSHs into the **Mac** and switches the Mac's Wi-Fi network to the phone's hotspot.
5. The Pi continues monitoring the ISP router every 30 seconds.
6. Once the ISP router responds **3 times consecutively**, the system logs the outage duration, and Automate automatically reverts the connection.

### Recovery (handled by Automate on Android)

The Automate flow on the Android phone monitors the ISP router's public WAN IP. After **60 consecutive successful pings** (~5 minutes), it automatically disables the hotspot and reconnects to the home Wi-Fi network. 

Because the phone's hotspot is no longer available, macOS natively detects the loss of the network and **automatically reconnects** to its default home Wi-Fi network. No additional scripts or commands are required for the Mac's recovery.

### Automate Flow Diagram

For those reviewing the project architecture, here is the logical flow executed by the Android phone. You can simply import the provided `.flo` file into the Automate app rather than building this manually.

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
       │ '/fallover_a7b8c9x2k4' │
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
       │ Set ping_count to null │             │
       └───────────┬────────────┘             │
                   ▼                          │
                   │◀──────────────────────┐  │
                   ▼                       │  │
          /───────────────────\            │  │
          │ Ping ISP public   │─── NO ─────┼──┘
          │ IP XXX.XXX.XXX.XXX│            │
          \───────────────────/            │
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
| **Static (white) IP required** | The ISP connection must have a public static IP address for the Automate recovery flow to ping it from the mobile network. |
| **Mac must be awake** | The Mac's lid must be open (not in clamshell mode). The Pi checks `AppleClamshellState` via SSH before triggering failover. |
| **Automate app required** | The Android phone must be running the [Automate](https://llamalab.com/automate/) app with the failover flow active and connected to the home Wi-Fi. |
| **Single-network topology** | All devices (Pi, Mac, phone) must be on the same local network and reachable before the outage occurs. |

## Prerequisites

| Component | Purpose |
|---|---|
| **Raspberry Pi** (any model) | Runs the monitoring script as a systemd service |
| **Android phone** with [Automate](https://llamalab.com/automate/) | Receives HTTP triggers and manages hotspot on/off |
| **Mac computer** | Automatically switches Wi-Fi to the phone hotspot |
| **SSH key pair** | Passwordless SSH from the Pi to the Mac |
| **Nginx** | Serves a simple web dashboard for viewing outage logs |

## Installation

> [!NOTE]
> All of the following installation steps and commands must be executed on your Linux system (e.g., your Raspberry Pi).

### 1. Clone the repository

```bash
git clone https://github.com/YOUR_USERNAME/pi_ping_monitor.git
cd pi_ping_monitor
```

### 2. Run the interactive installer

*(If you copied the files from Windows and the script lost its executable permissions, `bash` will run it anyway).*

```bash
sudo bash install.sh
```

The installer is fully interactive and will automatically guide you through:
- Detecting your network environment and suggesting default IP addresses.
- Prompting you for the remaining settings (Hotspot SSID, Automate token, etc.).
- Generating a dedicated SSH key and helping you copy it to your Mac (`ssh-copy-id`).
- Installing the systemd service.
- Installing and configuring Nginx for the web dashboard (on a dynamically selected port).

### 3. Verify

At the end of the installation, the script will output a summary containing your Automate flow settings and the URL for your new dashboard.

You can check the service status with:
```bash
systemctl status ping-monitor.service
```

## Configuration

The installer automatically creates `/etc/ping-monitor/config.env` for you. If you ever need to change settings later, edit this file and restart the service:

```bash
sudo nano /etc/ping-monitor/config.env
sudo systemctl restart ping-monitor.service
```

| Variable | Description | Example |
|---|---|---|
| `TARGET_MAIN` | ISP router IP to monitor | `192.168.100.1` |
| `TARGET_SIDE` | Secondary device on the same switch (for cross-check) | `192.168.100.79` |
| `TARGET_MAC` | Mac computer IP on local network | `192.168.0.173` |
| `HOTSPOT_SSID` | Phone hotspot Wi-Fi name | `MyHotspot` |
| `HOTSPOT_PASSWORD` | Phone hotspot Wi-Fi password | `secretpass` |
| `AUTOMATE_HOST` | Android phone IP | `192.168.0.65` |
| `AUTOMATE_PORT` | Automate HTTP server port | `7801` |
| `AUTOMATE_ENDPOINT` | Secret endpoint path for the trigger | `failover_abc123` |
| `SSH_USER` | Username for SSH into the Mac | `john` |
| `SSH_KEY_PATH` | Path to the SSH private key | `/home/pi/.ssh/id_ed25519_mac` |
| `MAIN_INTERVAL` | Ping interval when router is up (seconds) | `5` |
| `SIDE_INTERVAL` | Ping interval when router is down (seconds) | `30` |
| `DEBUG` | Enable debug logging | `true` |
| `WEB_PORT` | Port for the Nginx dashboard | `8080` |

## Web Dashboard

The included nginx config serves a beautiful web UI showing the outage log. The installer will display the exact URL (e.g. `http://192.168.0.197:8080/`) at the end of the setup. Each log entry records:

```
DDMMYY HH:MM:SS - HH:MM:SS [optional: secondary device IP if also down]
```

- **Start timestamp** — when the router went down
- **End timestamp** — when it recovered
- If the secondary device was also unreachable, its IP is appended

## Project Structure

```
pi_ping_monitor/
├── ping-monitor.sh        # Main monitoring script (runs as a daemon)
├── ping-monitor.service   # systemd unit file
├── ping-monitor.conf      # nginx config for the web dashboard
├── install.sh             # Automated installer
├── config.env.example     # Configuration template (copy to config.env)
├── .gitignore
└── README.md
```

## Outage Logging

The system automatically records the duration of each outage to `/var/log/ping-monitor/outages.log`. A new entry is written only after the connection is fully restored and confirmed. 

There are two possible formats for a log entry, depending on the severity of the failure:

1. **Only the ISP router failed:**
   If the ISP router goes down but the secondary device (`TARGET_SIDE`) remains pingable, it indicates a partial failure (e.g., just the router hanging).
   **Format:** `DDMMYY HH:MM:SS - HH:MM:SS`
   *Example:* `200625 14:32:10 - 14:35:47`

2. **Both ISP router and secondary device failed:**
   If the ISP router goes down and the secondary device is also unreachable, it usually indicates a power loss or a failure of the switch connecting them. In this case, the IP of the unreachable secondary device is appended to the log entry.
   **Format:** `DDMMYY HH:MM:SS - HH:MM:SS <TARGET_SIDE_IP>`
   *Example:* `200625 19:01:33 - 19:02:15 192.168.100.79`

## License

This project is provided as-is for educational and personal use.
