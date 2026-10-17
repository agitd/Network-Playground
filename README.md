# Network Playground

A local network monitor for Linux. Scans your LAN, tracks devices over time, and shows them on an interactive map. No cloud, no accounts, no telemetry — everything stays in a local SQLite database.

<img width="1920" height="1004" alt="изображение" src="https://github.com/user-attachments/assets/f55444cd-5655-4c88-838e-97665c9caba6" />


## Features

- **Device discovery** via `arp-scan` — IP, MAC, hostname, vendor
- **Online/offline tracking** — a device is marked offline only after 2 consecutive missed scans
- **Event history** — appeared, went offline, came back, changed IP
- **Interactive map** — gateway in the center, devices in rings around it; drag, zoom, pan, click to select
- **Automatic monitoring** — scans every 30 seconds in the background
- **Search and filters** — by IP, hostname, MAC or vendor; online/offline/new in 24h
- **Export** — device list and event history to CSV or JSON
- **Notifications and tray** — desktop alerts, tray icon, quiet hours
- **Dark and light themes**
- **Start on login** (optional)
- **One-file installer** — sets up system packages, Python environment, permissions and menu icon in one step

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

## Uninstall

bash install-network-playground.sh --uninstall
Add --purge to also delete the database

Usage

    SCAN NOW — run a scan immediately.

    AUTO 30s — pause or resume the background scan (on by default).

    CLEAR OFFLINE — remove all offline devices and their history.

    RESET LAYOUT — put all nodes back on the default rings.

    FORGET DEVICE (or the Delete key) — remove the selected device and its history.

    SETTINGS — notifications, quiet hours, theme, start on login, quit on close.

    Search box (Ctrl+F, Esc to clear) — matches IP, hostname, MAC and vendor; several words must all match.

    ONLINE / OFFLINE / NEW 24H — filter the device list. ONLINE and OFFLINE are mutually exclusive; NEW 24H combines with either.

    EXPORT — save the device list (as currently filtered) or the full event history to CSV or JSON.

    Map — drag nodes, scroll to zoom, drag the background to pan, double-click the background to fit everything. Click a node to select it in the list and details panel. Dragged positions are saved.

If your phone or other devices are missing

Being on a LAN cable is fine for ARP — the router bridges wired and Wi-Fi onto the same network. If a device doesn't show up, it's usually one of three things:

    Sleeping phones ignore broadcast ARP. The scan sends a targeted unicast check to known devices before counting them as missed, which reaches phones that broadcast doesn't. But a device must have been seen at least once before it can be re-checked this way.

    AP/client isolation or a guest network on the router blocks Wi-Fi devices from reaching wired ones. Nothing in this app can see through that.

    The Wi-Fi is on a different subnet (some mesh systems, extenders, or a second router). ARP only works within one subnet.

The status bar shows the subnet being scanned, e.g. 192.168.0.0/24 via eno1. Compare it with the IP your phone shows in its Wi-Fi settings. If the phone's IP is outside that subnet, it's cause 3. If it's inside but the phone never appears, it's likely cause 2.

If something crashes, you get an error dialog and the details are written to:

~/.local/share/network-playground/last-run.log

Tech

    Python 3, PySide6 (Qt)

    SQLite for devices, event history and saved map positions

    arp-scan for ARP discovery

    map.py — QGraphicsView-based interactive map

    ui.py — main window, settings, tray, search, filters, export

    install-network-playground.sh — self-extracting installer with the whole app embedded
