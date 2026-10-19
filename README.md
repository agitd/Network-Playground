# Network Playground

A local network monitor for Linux. Scans your LAN, tracks devices over time, and shows them on an interactive map. No cloud, no accounts, no telemetry — everything stays in a local SQLite database.

<img width="1920" height="1004" alt="изображение" src="https://github.com/user-attachments/assets/47e46975-6b12-4d51-9617-43e8200628d8" />


## Features

- **Device discovery** via `arp-scan` — IP, MAC, hostname, vendor
- **Online/offline tracking** — a device is marked offline only after 2 consecutive missed scans
- **Event history** — appeared, went offline, came back, changed IP
- **Interactive map** — gateway in the center, devices in rings around it; drag, zoom, pan, click to select
- **Automatic monitoring** — scans every 30 seconds in the background
- **Search and filters** — by IP, hostname, MAC or vendor; online/offline/new in 24h
- **Export** — device list and event history to CSV or JSON
- <img width="152" height="101" alt="изображение" src="https://github.com/user-attachments/assets/33706e38-30e2-407f-82de-84cada5741c6" />

- **Notifications and tray** — desktop alerts, tray icon, quiet hours
- **Dark and light themes**
- **Start on login** (optional)
- **One-file installer** — sets up system packages, Python environment, permissions and menu icon in one step
- **Custom Network Scanning (CIDR / VLAN)**
- <img width="420" height="561" alt="изображение" src="https://github.com/user-attachments/assets/6145798c-34a9-4a9c-97b3-d84bf7208ec3" />

- Added a **SCAN TARGET** field in Settings to manually specify a subnet (e.g., `10.0.20.0/24`) instead of relying solely on the default local network.
- This allows scanning specific VLANs or multiple subnets available on the same physical interface.
- **Security:** Strict IPv4 validation prevents option injection (e.g., `--file=/etc/passwd`) and size limits (max `/20`) prevent endless sweeps.
- The status bar now indicates when a custom range is being scanned.

## Requirements

- Linux (developed and tested on Pop!_OS / Ubuntu 24.04)
- Python 3
- `arp-scan` with raw-socket permission
- A desktop environment (Qt / X11 or Wayland)

The installer handles the system packages and the `arp-scan` permission for you. No manual `setcap` needed.

## Installation

Download `install-network-playground.sh`, then run it once:

```bash
bash install-network-playground.sh
```

Or right-click the file, allow it to execute as a program, and double-click it. The terminal route is safer — downloaded files often lose execute permission.

You'll be asked for your password once. That installs `arp-scan` and the other system packages and sets the `arp-scan` permission in a single step.

When it finishes, **Network Playground** appears in your app menu (press Super and type "network") and a shortcut is copied to your Desktop folder, if you have one. It launches with no console window.

### Update

Run the same installer again with a new version. Your device database and saved map layout are kept.

### Uninstall

To remove the application:

```bash
bash install-network-playground.sh --uninstall
```

Add the `--purge` flag to also delete the database:

```bash
bash install-network-playground.sh --uninstall --purge
```

## Usage

- **SCAN NOW** — run a scan immediately.
- **AUTO 30s** — pause or resume the background scan (on by default).
- **CLEAR OFFLINE** — remove all offline devices and their history.
- **RESET LAYOUT** — put all nodes back on the default rings.
- **FORGET DEVICE** (or the Delete key) — remove the selected device and its history.
- **SETTINGS** — notifications, quiet hours, theme, start on login, quit on close.
- **Search box** (Ctrl+F, Esc to clear) — matches IP, hostname, MAC and vendor; several words must all match.
- **ONLINE / OFFLINE / NEW 24H** — filter the device list. ONLINE and OFFLINE are mutually exclusive; NEW 24H combines with either.
- **EXPORT** — save the device list (as currently filtered) or the full event history to CSV or JSON.
- **Map** — drag nodes, scroll to zoom, drag the background to pan, double-click the background to fit everything. Click a node to select it in the list and details panel. Dragged positions are saved.

## If your phone or other devices are missing

Being on a LAN cable is fine for ARP — the router bridges wired and Wi-Fi onto the same network. If a device doesn't show up, it's usually one of three things:

1. **Sleeping phones ignore broadcast ARP.** The scan sends a targeted unicast check to known devices before counting them as missed, which reaches phones that broadcast doesn't. But a device must have been seen at least once before it can be re-checked this way.
2. **AP/client isolation or a guest network** on the router blocks Wi-Fi devices from reaching wired ones. Nothing in this app can see through that.
3. **The Wi-Fi is on a different subnet** (some mesh systems, extenders, or a second router). ARP only works within one subnet.

The status bar shows the subnet being scanned, e.g. `192.168.0.0/24 via eno1`. Compare it with the IP your phone shows in its Wi-Fi settings. If the phone's IP is outside that subnet, it's cause 3. If it's inside but the phone never appears, it's likely cause 2.

## Logs

If something crashes, you get an error dialog and the details are written to:

```text
~/.local/share/network-playground/last-run.log
```

The device database and saved map layout live in the same folder.

## Tech

- Python 3, PySide6 (Qt)
- SQLite for devices, event history and saved map positions
- `arp-scan` for ARP discovery
- `map.py` — QGraphicsView-based interactive map
- `ui.py` — main window, settings, tray, search, filters, export
- `install-network-playground.sh` — self-extracting installer with the whole app embedded

## License

MIT

Looking for a deep security audit? Check out my other project Sentinel Ultimate
