#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Network Playground - one-file installer for Pop!_OS / Ubuntu 24.04
#
#   Install / update :  bash install-network-playground.sh
#                       (or right-click > Run as a Program / Allow Executing)
#   Remove           :  bash install-network-playground.sh --uninstall
#   Remove + wipe DB :  bash install-network-playground.sh --uninstall --purge
#   Start on login   :  bash install-network-playground.sh --autostart
#                       (off by default; can also be switched in the app's Settings)
#
# The whole application is embedded at the end of this file.
# ----------------------------------------------------------------------------
set -u
trap '' PIPE

APP_NAME="Network Playground"
ID="network-playground"
DATA="$HOME/.local/share/$ID"
APP="$DATA/app"
VENV="$DATA/venv"
APPS_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
ICON="$ICON_DIR/$ID.svg"
DESKTOP_FILE="$APPS_DIR/$ID.desktop"
DESK="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[ -z "$DESK" ] && DESK="$HOME/Desktop"
AUTOSTART_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/$ID.desktop"

usage() {
    cat <<'USAGE'
Usage: bash install-network-playground.sh [--autostart] | [--uninstall [--purge]]
  (no option)   install or update
  --autostart   also start Network Playground on login (minimized to the tray)
  --uninstall   remove the app, menu entry, shortcut and autostart entry (keeps the device database)
  --purge       with --uninstall: also delete the device database and settings
USAGE
}

UNINSTALL=0; PURGE=0; AUTOSTART=0
for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=1 ;;
        --purge)     PURGE=1 ;;
        --autostart) AUTOSTART=1 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done
if [ "$PURGE" = 1 ] && [ "$UNINSTALL" = 0 ]; then
    echo "--purge only works together with --uninstall" >&2; exit 2
fi
if [ "$UNINSTALL" = 1 ] && [ "$AUTOSTART" = 1 ]; then
    echo "--autostart cannot be combined with --uninstall" >&2; exit 2
fi

# ---- feedback: terminal text, or a small progress window when double-clicked ----
GUI=""
if [ ! -t 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
    exec 3> >(zenity --progress --pulsate --no-cancel --auto-close --width=420 \
                     --title="$APP_NAME" --text="Starting..." 2>/dev/null)
    GUI=1
fi

say() {
    echo "==> $*"
    if [ -n "$GUI" ]; then
        echo "# $*" >&3 2>/dev/null
    elif [ ! -t 1 ] && command -v notify-send >/dev/null 2>&1; then
        notify-send -t 4000 "$APP_NAME" "$*" 2>/dev/null
    fi
    return 0
}

end_progress() {
    if [ -n "$GUI" ]; then
        echo 100 >&3 2>/dev/null
        exec 3>&-
        GUI=""
    fi
}

msg_box() {  # kind (info|error), text
    if [ -t 1 ]; then
        echo "$2"
    elif command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        zenity "--$1" --width=440 --title="$APP_NAME" --text="$2" 2>/dev/null
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "$APP_NAME" "$2" 2>/dev/null
    fi
}

fail() {
    echo "ERROR: $*" >&2
    end_progress
    msg_box error "$*"
    exit 1
}

# ---- uninstall ----------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
    say "Removing $APP_NAME..."
    rm -rf "$APP" "$VENV"
    rm -f "$DESKTOP_FILE" "$ICON" "$DESK/$ID.desktop" "$AUTOSTART_FILE"
    if [ "$PURGE" = 1 ]; then
        rm -rf "$DATA"
        say "Removed everything, including the device database and settings."
    else
        say "Removed. Your device database was kept in $DATA (use --purge to delete it)."
    fi
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null
    end_progress
    exit 0
fi

# ---- 1. system packages + arp-scan permission (one password prompt, only if needed) ----
command -v python3 >/dev/null 2>&1 || fail "Python 3 is not installed on this system."

if [ -z "${NP_TEST:-}" ]; then
    need_priv=0
    for pkg in arp-scan python3-venv libxcb-cursor0 libcap2-bin; do
        dpkg -s "$pkg" >/dev/null 2>&1 || need_priv=1
    done
    ARP="$(command -v arp-scan || true)"
    if [ -n "$ARP" ]; then
        getcap "$(readlink -f "$ARP")" 2>/dev/null | grep -q cap_net_raw || need_priv=1
    else
        need_priv=1
    fi

    if [ "$need_priv" = 1 ]; then
        say "Installing system packages - you may be asked for your password..."
        PRIV_CMD='export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y arp-scan python3-venv libxcb-cursor0 libcap2-bin &&
setcap cap_net_raw,cap_net_admin+eip "$(readlink -f "$(command -v arp-scan)")"'
        if command -v pkexec >/dev/null 2>&1; then
            pkexec /bin/bash -c "$PRIV_CMD" \
                || fail "Could not install the required system packages (password cancelled, or another package manager is busy). Please run the installer again."
        elif [ -t 0 ]; then
            sudo /bin/bash -c "$PRIV_CMD" || fail "Could not install the required system packages."
        else
            fail "Could not ask for administrator permission. Open a terminal and run: bash install-network-playground.sh"
        fi
    fi
fi

# ---- 2. application files (embedded below) ------------------------------------------
say "Installing application files..."
rm -rf "$APP"
mkdir -p "$APP" "$APPS_DIR" "$ICON_DIR" || fail "Could not create $DATA"
sed '1,/^__PAYLOAD_BELOW__$/d' "$0" | base64 -d | tar xz -C "$APP" \
    || fail "Could not unpack the application. The installer file may be damaged - please download it again."

# ---- 3. Python environment with Qt ---------------------------------------------------
if [ -z "${NP_TEST:-}" ]; then
    if [ ! -x "$VENV/bin/python" ]; then
        say "Creating Python environment..."
        python3 -m venv "$VENV" || fail "Could not create the Python environment."
    fi
    say "Installing the Qt libraries - this can take a minute or two..."
    "$VENV/bin/pip" install --quiet --disable-pip-version-check PySide6-Essentials \
        || fail "Could not download the Qt libraries. Check your internet connection and run the installer again."
    "$VENV/bin/python" -c "import PySide6.QtWidgets" 2>/dev/null \
        || fail "The Qt libraries were installed but do not load. Please run the installer again."
fi

# ---- 4. icon, menu entry, desktop shortcut ----------------------------------------------
cat > "$ICON" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128">
  <rect x="4" y="4" width="120" height="120" rx="26" fill="#0a0a0b" stroke="#26262b" stroke-width="3"/>
  <g stroke="#a8121a" stroke-width="3" stroke-linecap="round">
    <line x1="64" y1="64" x2="64" y2="26"/>
    <line x1="64" y1="64" x2="100.1" y2="52.3"/>
    <line x1="64" y1="64" x2="86.3" y2="94.7"/>
    <line x1="64" y1="64" x2="41.7" y2="94.7"/>
    <line x1="64" y1="64" x2="27.9" y2="52.3"/>
  </g>
  <g fill="#111113" stroke="#a8121a" stroke-width="3">
    <circle cx="64" cy="26" r="7"/>
    <circle cx="100.1" cy="52.3" r="7"/>
    <circle cx="86.3" cy="94.7" r="7"/>
    <circle cx="41.7" cy="94.7" r="7"/>
    <circle cx="27.9" cy="52.3" r="7"/>
  </g>
  <circle cx="64" cy="64" r="12" fill="#e0222d"/>
</svg>
SVG

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
GenericName=Network Monitor
Comment=Monitor devices on your local network
Exec="$VENV/bin/python" "$APP/main.py"
Icon=$ICON
Terminal=false
Categories=Network;Monitor;System;
Keywords=network;lan;scanner;devices;arp;
StartupWMClass=$ID
EOF
chmod +x "$DESKTOP_FILE"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null

if [ -d "$DESK" ]; then
    cp "$DESKTOP_FILE" "$DESK/$ID.desktop"
    chmod +x "$DESK/$ID.desktop"
    gio set "$DESK/$ID.desktop" metadata::trusted true 2>/dev/null || true
fi

# ---- optional: start on login (same file the Settings checkbox writes) ----------------
if [ "$AUTOSTART" = 1 ]; then
    say "Enabling start on login..."
    mkdir -p "$(dirname "$AUTOSTART_FILE")" || fail "Could not create $(dirname "$AUTOSTART_FILE")"
    cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_NAME
Comment=Monitor devices on your local network
Exec="$VENV/bin/python" "$APP/main.py" --hidden
Icon=$ICON
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    chmod +x "$AUTOSTART_FILE"
    gio set "$AUTOSTART_FILE" metadata::trusted true 2>/dev/null || true
fi

# ---- 5. done: open it ------------------------------------------------------------------
say "Done. Opening $APP_NAME - next time use the app menu icon."
end_progress
if [ -z "${NP_TEST:-}" ]; then
    nohup "$VENV/bin/python" "$APP/main.py" >/dev/null 2>&1 &
    disown 2>/dev/null || true
fi
exit 0
__PAYLOAD_BELOW__
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
z+8//3///F8MQiODAGgBAA==
