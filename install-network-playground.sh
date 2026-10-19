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
Hj4Pn/+fff4/X+yIaQC4AQA=
