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
H4sIAAAAAAAAA+w87XbbNpb9rafAsGdPyVZmJNlOZjWrySq2nHgqy7YkN+06PgpNQhJqimRJKrKa
5px9mn2wfZK9F18kJMp220nnx5ZtbAkELi7u970AvPBY5CbrLz7n04Dn+cEB/m6+OHghfh82eDu+
au7vf9E8bD0/eL5/sH/Q+qLRbL7Yf/EFaXxWrOSzzHIvJeQLP/SWAX2g3+0yypd/BEZ/6PPlX54t
s/TZLYue0egDSdb5PI72a5ZlDWi+itM7chF661kaL6OA7BEa5emaJDGLcrdWI/CIEWQh5IiUnihO
F15IkL55Vde9vTkLAhrBG96HLFjEFuxnGpA8Jvmckjz11sReZtByuybWiPcCCGE8Y5HlIJa1Glsk
MTZn6lO21h8BgE9vPf+uNk3jBUm8fB6yWyLfXsDXWu24O+5Ojk+HpMMb3Hm8oLZDnhHLDWPfCy38
mM29lPJPkSDLXqLJYtX6568nJ6f9HoDQ0KBr6GX5XrqMAM4MOx19W9XLSxKc6A6WUgvolEyg9ySP
J1MWAh5tTjlYKF88EIIvxCMLGi0J84EYQKiUEpYBvQl8z+KQ1kkWkztKE+KFIYmXebLMCYtgGMAm
CNhF0iFkNkV6uVke0DQVUHIyiCNKPGB48cplmZfna4UQPinNlylw70vBvgK3nKbASi9sk5B6H6hC
wAsBLB8NMlSAUbRwF3cBS+0ECB3lWWecLmEd9J5l+SS+418dPWYaABHjzI0TGtmK+nVsOZ+8HZ4P
+j+QX8S3o2GvO1ZfxsOrwVGdNGKwRgUweBUsk5Y9DeqkWd3cMpr9MM4otBeNkk6wUMQLkWrWibWy
6uR2OZ3SlEWzDrTwgdOgc+KFGd0ajQyQo1tPHE3vfZrk5HzUS9M4LWiaeFkG4mSKUk0owcV6xAL6
3L3Mj2IUHKELl30QwRPoh/yM4p+8NukdNFqbQ96yYEbzTI/qJknIfC9ncVQnl2c0y7wZfRXfb0AR
YKJk5gZa+4693Lv1ssoJsWdG8xxWrucaqe87+oMeLPRysnwd0mxOab6r+5Kpvmdgj96yKIhXm1hP
snm8iiYUiZsBbwAlJKNQU0H7eRzf2fBxkq8TLq9+neS3hdoOtFKiUUupFxAJDjHhioqToBYvhIoG
zEMttePIpyShKTRksHA/FwMdrbo5vUdxsyz3R7DHtrZ17hQNby4RBM5U4Oc8rPztCtl0VynLqY2z
6tEcBcDaJFScGoLhsggMBKwGrCrMYcIXRoR/NYC4XhCU5iqJlusDHgA6tDUQBAkaU+2xEJxVL0yH
NQIDn89BlMgKLA1ZpXE0a7+L3kUfcb7rvWar0WjffHoXnSzBegIv2uSjsjGfJCQlBejLlE2U3gw4
ojybhbRBCnrp7APvA8YeOpSpY197BBgGjC/1Rdp65C9lUDeOAoCaUQIw8MBfVbmlXQOOWYa9xLht
mpnjjml2l8cJWobdE6HegMT5c5pxv+0GYhR3NeDj0E9xoF+Styyfo4tAz67cF1kJ7QPhiKNwrQi5
msMPbvSCv5GfloyrP3bywpW3zkCWcUkMApESvpfQ7zzqg+cVKn3Ex9slm4k0LnQXuFHS5JrE8hzR
QCfoxxCoeDlizBa0TWDtEtuMZL4XRYgSekpUDvyMy8mAUCRQ5m0VL8MA1uFlc4Hpr3V4GByg0CgL
bWd5autoolBlVF7s64J7xb42yHHJXZdViEXCRqD86Q4PalJJg7hlq9A1zhm0cGsCQQ9Sxn0X9ZHG
KN8MvQYynAmeAxtyMHlcEOA1NgWIfGkiZ8NKkIbgD/iQjnYftuSq8g4d7Sjs4NYQ5RH6hBH6BLtw
D7YaKPyHw2U5g6glINKhZDg+ZBiD0il6zJLEcm5lAitogskLZwLT1zVaBpNsKeBcbiAWnnvZBOng
tHFyHRZzXVh4d6BUGY1QklAhdLgnlQi8ypQh9dEQa4IhWDSnkjp+HFBADglB76kvW4NbGcoUcuYu
I/wlWyTZcTTYO8B+MolAticT0gHTNJmg9ZtMrHZJr1huC5vo1P7Vqc2fzxMeCIWefe45MMl/cXi4
K//HR+T/Lxr7hwcNzP9bTcj/Dz83Yvj8P8//kf+TCSTe+WTyuepAj9R/Cv4fANubz4H/+/utxp/1
nz/iQf6DH/isFcCH+d9EvZf1v9aLwwOwE80WhC5/8v+PeLCydNmHxA5S5jiF8LBNAvqB+RB0YHhC
P2CKNGf4cu3WamOIfe7omlfgfBKyD9AP4p738W1G0w8QSbxvkymlPBxZzXngjGEyRFQr4t1ifQSj
ajFDzRNhyzKBWFlmDuINSSG2wrcp9eM04BEYBS49w5iIRZhSxNOp+FRjycSfe9GMSmwzl/QBXopV
qRmAtXmcTtM6WcRg5iCDJj8C04mPtbES4q5RTsx+CoEo+7qQCNH/QzXEV7+zgggALrrjNxjXvlKF
QeiHXdzgFtA6Ox2NJuM3w97ozXn/GPq1MFbE0gL1lznwgSxYhoVSXG2mQlVPERTixYWX3sF7Sbha
bXT0pnfW5QUEq8bLZD0y7r7q98jpCRmcj0nv+9PReKTFQSQKLNA5wOlg3HvdG5KL4elZd/gD+bb3
A+lejc9PBwDtrDcYi0gexUU+4973Yw56cNXvk6vB6eVVrw7te3vkrHsk4tu7KF5FdRJjnLtiEPWe
XnAwC88vgxGwWUK2G+dxlmOYajSCZASQZpg9pTSVF6OxO+6ddK/6Y9IQXTl1s8e68qXsYgqHM2Up
5HcZhZUCyfsaiJgFK8bipfm25vztIRYJud/i0BMZlGdqQAVGgvsTALq17GHvpDfsDY56WkZsFjiS
6ZiSbPO8XkohgVJCrYE+vyhW/KIV+xdSKLbEJPdYqEA+QpEFdJb0EPLH0SgRQkqFFy7pJrzTwXHv
+w14LLifCCpPgFznA0lyG74c90ZHMJgbjxqm+ZnOTdsScUycRIgF6WY4rXMj0pE675TLtvlcGhEb
PxcJMFbq8lQ08rpQe0EXYJLbVjFaQXBFReHX1NOx4kGLimx8+yP1c158zOeY0belPUTZjuAVAxEn
CPgrsJRo2AK3qBjCCl3shwVTYUVdOczWa3C2u7tg9CdTz0dPUxo6jFcVfTGLXYLT8FOW5LYwZeXl
nLFZyssbvPagajEZ8WE1udhO4u6BNJ+1iB3F5L1Q8PewwnC5iJxiPdCAVYWP6bWFVsW64SBTXq7b
xMe2Lobd12BVYb4QtCaaxrbUDcdyPpXZaYkJLV4RYBGfxuRlBfRufwwaKARe2eXu8TE5Ou9fnQ2U
kdptoCxDoixhFP+pKEg7iyplVTHZjxcLxqvoglF78PDiGYDZ++1PoWhcMaWaaeNV5wapLm1IR1S5
QCnwQ0n/tpdrFr1OB6PecIz0Pdc2N892zuOQ77r9KzCP9ss6/8/ZqKKh+cDaFwQXLv6wnd2wymUx
vVoVvYjlsqSOblIuT7lB+VUYWGkGBJc2lw8mbMgDLh6kZWw25yVNm1enpSfz59S/c8BK69hC7gPj
M+T1IixNhWBmsJOIH3EhGZlRiMJQ+8AMuTOXXFvK/ls3bhkJ/RlCAdC8Enn0G4wGOvgTIqwVTXFn
YcobaQj2a6A2GvGREtlRH+B/4z36Bw4K37BEt0sGd8j1TbHClGNUoRajXr93NCZfk5Ph+ZlWjLdv
wEPKGV5adWLDx7rjuFOa+3NAQumBVMhUFMHNHRL5DnVU8NB8xbESdTqJMW5iwUcIgDGQYHkdx/L9
Dr4DhQw2IPjLtHJNW9MY8q/DQlwSkk/In5I6JWNK8OqlyKdexDmOtT3LptbAf80q7cHn0dlBhPgP
xxzrbJs5aTmAGi6iB7xAHSxkFFZgfWTJJ0vA22EntX2r4E9Z4Au+AyExvOog968thu9KbK9iuZAU
6JuAM+JJVCKyJd0IEQJLtuWkvE4xLSywCLPEEhHKVyz56uYT2fs72bVifGS6hYuKArsMyKmSXo6e
WI9180TkZHfB3acgIQfsYs9u2b66OMbgT4n1qDeGOTsvhUU9Ou/2Iczr2eK7U68SW21wy71Vo6ON
bvmtaKoGJw12sy7deqdR0pvOS2lbWNB5WaUXIBIYpSiJkDqyQz8EuXeqCNrUagn8tdwUsT2ws4TY
k7gqB253rDDFFZyUtGwYRCMKscpodEuRDSNbuGBhUCfIo+2oA6PnbB6HQcfM302n2xU1koAFPJ6m
uMUEbkC6V/I6hlWotMibYmnjvQb8XgV9/OwAkNUtO9CSuxLQbI2cEQmWHA+KzSPaqsxZYagkDtKG
ycj2hnxDmuVZZK+/dwq6VISbhdAoKlbJzWMK/pAUaI16uSEPornEQee3mXmF702FXD2E4G9A63GB
VeELCitkLjOaT6QsbIjrg4GwdQwBDqDLwxsZaAgs9XitU5JvlVhWwjPDpd8Dief9OuoScKZWEmft
jxoc+LOHCbhJLslOTi9Tc49pSCErxmhrrVVUltxEdTPTxVMdHeNxn4UXrckKd3JTyOM/QP5cVlsW
8LgzFeHAg/mmjDshgKigpBJ4yykkke/FIzCYpEL7TAlhW9IU0siGkWb+li2wlgoEfyYKKrhgSuwZ
BPsrPOcBvjteRVjjQz+UEOAH4zUEhxjJG86MHJSSCQDLxw0fDLzFxDtlYDvu3lgX0JqDAHKjPSzl
ERq7bAu7upj2YcWRQfP5kAx7F/3uUU/Ez6JCVQJSCnsJxrrGy6fJq6ZrhaiO+JkGg/ptUihFm9j3
dbJ2PhmCKA40fvxkSM8jolhgXcUO0j/9tke+Qo38t68sx5RA41yoehAt9CyaQW6WhLBuq14RDgDC
1wy8B/SGyayb64P2jXMDw+1pGHu5fQ9xmPi03rDt8ijldzjHxmlK9cByISFe0k3ZgUkLHvghRPiT
nZz4VfZrg1hPLadgxe53VVMKjVSF3Y1VyIU/Vi+pTorPh8e9IXn1g6r5YgEVA/xC7KSiglEpS/ej
XmsnVg9m51XuZitBx/llyVfMHzKge6fVaJRQ2Son/RSi5FXShLpfw0gXwvTuiBvIwNX7FtBSBOqB
i6UJaMJfZp5glZ0xJf84Px3otQVYpAb4mFhSt6jil4isP3npTNY5VAubFquqPheq1vdNh1iCjuVZ
OuTlBq44hwrnK2JQBUrLBnVlaR2LRQARP4I6nJ2OyUurVgWVc2TLrm8LA0xV5wOrpUyciNqpterA
1L963/af9eD+PziFz3oA4JH9/xfNw6a+/9NqHuD+//7hwZ/7/3/EA97+NIKU0vP5fqXcm8Y4oc03
5FUMl/Hzm+Lopo+3gGhd25qUH4KVh0DxXtBZvBTHFSkawJ9jPOgepN6M4PF0eVq0QxIvks0eGBh+
QBFDYTwSYPNpQDNpWsPDmOJwgHKqDt6FYP5dMQ70EzessNYZxMvbkO6JDsZ8U4Z3UEJzn3/B9+8f
uhhxgZedTurkcghT4G+YZMRmkRduDntd3Cm4fJUuszl0PopDLLNcnkDsAL8uPIbUxk80euRyhXAc
l69TL5kzP+uFIUsyeppToKZu3fjaB4e60TQCdtG6CWsEU4R0TO/zjc7fMbqq19RVEfNOhY9LyWq1
N1evJsPu8enVCI8hPK8Nzo97RUPzsDY8HbyevOqO8KZT898b4vto3LvA7/uN2uioN4AR6AY7kqz2
3l/Rle49x59N8ROPL6vLFsjniUDA9lVNubhlYU9ZCFYdAjHeLg/U46C/qSSI1zaYFKTQ8ymWH2ha
ZCno46ZcVNY0d8oXpGScsuPuAvGvLY7eMuJnF/C2TYiFLWjHCwWTgC1kJaCinrsBQ7wug1AlmFpV
b5FxGt116UFQDv55yzDXAanNooDel66VhbDs97zxPV6t8/HaCag387laZ0qvC71vk2aDkzbD+haN
gF110mrVietqouFQQMfDyw7IygZvXc3xOgCfC4tA8Lqgg2jd460FcdCwQFhQVJEQJDQ85w1eNAtR
+/cWfNebkWekRb6Bf18T1fK1BPxMjBQQvyYNd/9QIOoFbInBTyGzupMW2zLp5QA5gx9nNscCTJL5
JmORfKNEeAoWQF0Vwc8o+ye8TTfhKfUTb8FCBiH3tfUPmr9KwWBk5CyOYohRrWP6o/fdkoy8UtsV
d0zi640Ji594f4P5EJ/JxT5ZArJvduMWbsR+pvZfjXPf+F6faRgAx+0qY+TsPOXwAY0JUdVfQZ9i
Pyj0bmmIh7I+4F45SEs53lomuKnnaoB7arT+gFze/ryRIyEGkxQw63BkzJd640V8MF9SMMXwytgp
FOXJJKVZhvqEDBTOobyNZ1givF1SbbpMoHg4YZLwy0PoGGzhNmxlz4wLiHxAhqIBHsa+lL/EAJzc
2SwWIIcBpjHRdpf/4pmvva92ayRfRCGkZVSLJeF25wUS5NEyzQCpy9zlZAKteuNFgWg1AMq5qqGc
hN7MNvydiz9OszMlOeZZlieMHUG+kL2meA8sXR/xPatMgdFw5PW6HT7TluLLEwVjDJ8X9Vpq/Pbb
Ks5JZyHKT9LhcNIbXqTM2xQjno4Aeos2GuiLvtTenvACzNQe9ndXLMjn/GxiS1usb8hBKf9hsDhB
EqnFYk9vu9QFeIpXeBlkm8YX0uG88bIjeTyT3yjWyvWw+GAXRB0DGhtcSEOQ2gW9A7twjyclSt/X
tri4M1/e8qsxOfdXccpmpTsxKiOUtqW0UHOJBS0WGMdeoL73SqdKeMK9mRxWmoUCQ2fLtG3CFlDL
1C0bqYeJpcyczMBHPBqmgUuxNlQCs7m0IXQEg/Dg4sroGv2fjHDBd04K3JzeINnjSzrjNfLN9Twq
E4X3EnnNmZfYRqyrnVeZbniHjAf4ECzJFZawMN7KaqL8VaKv4Qof8mwblniSYbhu2B1ssE07U+rK
/Tx+4LpfhNbbFr4AJIduFhRhVumnrMBL7zYLjmi5dD5VZcMElGsLEjsamsZKARiC5aWpCElkLuR2
wTV4IfMgZJptjziGBPHMiD2Qb+7IT+MwRH+CHbaHYSfMWq744fIKAHi51+y0DWScQqClb0p2I3+O
7swAIxqvcFU8690G8gbM0M/gCbxQ4PzKSy9iyE7X6Bh1U5ffaT2fbjIZl0JTft/5twzn0Udm1vCl
BBTCXhHkQK4s3vGLs+YeCE8KpbngRxvMfYYVy/05JPchBRAuOcKtIRyGhzBB+/kG9srDU/38OFKC
UsDNNUfV2H7YFEs+2+8XynKtHLHCcy7oDbJiN+o/sxx47uNF8TgolJo7fRvsDssm4Gv47w0FR8+9
XU0V/U07x3vqIw6vu+Pe2+4PJaUz3gfyZA8kttbLUicsFGMIe22pkrF5fghbH5iWD4duuK2Hnx3y
H5DTt0TogQ3X7VYTN/Kt//3v/zFPj8qlP7Sma36O4eLoxiqHLdwLW+8i+XcL+BDHFDEuK+VCP4Rn
Mk+fYLEcX034iRa90VInSqIrtrKlqeR7M1sW9ykqUoJdRIjAUdwo3dQgoE2Bq0meYkQEoZltB+J4
MhbWVDEN42vJa4irCkDg3Pj2gnFgUMHbGR5IJsGEt3Ec2opuDvfJcvS1BS1iOvV+E2m+xEApvR6H
u9N1UtSD6mIW/V7VLpztA0oGoYVayWEiEC9US6eI4g+fQEDaETpddYaP8/LaQBB3/6BBd94+zbS1
QHFitrwueS9eKum7yDarRdYTkCwLohcEPImAmXncKioreGAWDeGC10141FtiN78Rw/8KSYx/bGen
8ChhkERw+E51J/QWt4FHgjaXrqB8gIafCMAqSV0Ao9FywQ/q2mLKjU1auR+rFc+d0dxWQNE+7Sg5
GUBkhiPFMiiJytPF9//a+9btNo4kzfnNp6gpj5cFGQTBiygZariHJimJa4qUSMoaH0mDLgIFASMA
hUYBpDgc7gvsj/057zdPsnHLa2WBlNruObuHcLcIVOU9IyMjIyO+6IUI18kuh/iSdlQOFHThXcqg
zsv2QVxtIvi+o5rqn9TcREoPB+O/UUn+/MGNHLb03hFpGd1C4d1+WgzwlX9hLW2Vg/tGaDm41IY5
au4Iif7cov2eWtaWWtcobez1CtugEHt5qfISDq9UrFOdSstTQG9l4vDPnb3CDNWsoGeYwIRgDNxE
CO1wLYweSbV8nhmCnFcMLxBAiagOl5YtI4VsaEqWYZ5QhaPjGtCoBrj2MLgVqp3HbIfB/c1sVSFt
VqCfRqjx33kCDTEZOW4RuSjrDx5hOkcXicckjJao3faaWLar0ARRseo4Jy2lLX8RlJi5XyB9N2ov
e9TxjBldZIP0cpgvZu7Q9+Wk6ZgXkMLFpkHq+8+O8gXoEt1LYcLWHuONxjb8g1+2m95WADUcTvAM
kWDBeK/U+CXLprvFFH6e4omjTIxzdSDBE/nGBpDkT9FG4zHhhvRytB69GOVX0WKKtx8g64yuo2w8
nSOMyLRMkHD8ts44IZIt4NgBrKXxuI7VhIwhMzzCnUzszYood5Bf3UetYNKV1Qm/70rDVtGN5LJm
sfsZXlM1Nh5jGyhBgxT5+9kIDzCoV4BRbzJ73ojWKa3d7mZj8zGK0RUz9kjVAkm2Gs2Q0pNGnVPV
JbWvutmna849vOVc1iHNxYBQd2WQG3pjrjXmOamqUH0WdDwJjHJ5yTk6olLDZGL/uy+6Hz7BD9p/
wEIb9q//OBOQO+w/tjZ3nmj7j40nhP+xsbn5YP/x9/iQETODtREZCEZcobZ9tGQWZ4yVleMcdikx
ByhaBqL1Ih2NcoT2QhORf2NBJC2iv/ThOZpgJPPhHC9qLvLeNQItrAAvHaLNNLCRjUb0FybAtSKb
9P6iwUSvECnuNcJhRgn7s10gNBXf4L94e0guupuN6LAfWfkJ6WBYFHIBTQ4VWGAdTyYIT1VwwemE
kQGjhDwaEbFCbgqmORqE1ep8FGPMtOgT+mDMc9Olv0SIaohwjokeBoI3k7GA1q2cLkaouFDwYSA3
TWc5HNMK4qaPIgTTIK844KBdfN5fjNgVBD0n0+4AcdQYBmw6G47FCoanKZu1EPBV2lfwCQPBJLGz
CogO0QZ56PrQpl4RXecL7r7xREOkCXVYaVCzCPzOdtzMJijT91jwE5g1yEub/ITzHIuHIYw+PY16
C7pF/+timMFRFMSrAi0s6WAYbW61ms215lP49xlIJtdRMYU+j4e9Cbqc1rjEVwy1Bi9enJ68fd1h
2z8xdsz75KJKKAPk+ILzPcp48C6ybj7O2Id1MR6nCFxim/ygrpfwPOT3YD4eadiPwWI+NL8WFzJj
bA+Daim6T8i0kY5+tLLyy+HxPlrAJLbPoOW7YpzZXFe53devO8e7r9BaJgS8t2L3H0SGlZXzw/Oj
A6zphmbdVNfCAq7UsgVivEa5Vmy6xEtMN6iF5gSUkGAwdTsl1cRLhEQfqR5wGqsXJp3CYjl8Dclu
V14fvT3dPeosa/LN5BbaeKWVGHe3G3Oo1Msbb6e8swd2Yq8bKyv/bGZaQB4oJck4LA4hNbYQpsFI
Rt8RFQK1Em1QquGU0tB3VNdyDkRhkRzG9BeEN7IoorT5qNeRvCr1d6y6cWEy2LHPpBPzk+GkQ2ux
Q2sxIbc/YYyQwdgDocBMyK6wQJAxX/0F1zTyDFhn760cjQgvX0Zo/kf357SICQ5TLWT26WZobzgF
InMeZ2i5AnyL+QKIjcO852BRW6lLRlJ8F+Gk/FMwobxrkwM5JVmx3uLDn9qSiLzdVCKx1OkRrsRF
BqKrDAydBBo0XX5d/fhGXt1GCX4dTm9rsZVLJiScDxJzLk6lcmpfwwb7ccZiWybkqaHCgdfO5qaZ
JhvZkeOO55cQWwY9so8YTYBrvqN4fT16RODT3c9txTob+gsR0tVg2B20mXc26EdA4zXFrbxtWGqD
9vY67ZqCUaA21yAug4Xwqb56F0UClMp/rTXIMglZs+CCmWeI2elkpTZDVvrrvqJmk74T/rqvaL9v
87Yf2RUSjgsuTXxDU8Gb4sW1Lap46gDpOxqqqq9UGJrBYtsdIcprI0oH+rbOaghvhQUdg8V1dF4l
dHgaI5wlvsdy+/Y+kXmzm/MRVtNwNFK4r46WZQrnwWHX1a4oOcg6tBbuNSIzF2qtu+f3gUaLgWAq
Gac6TOiMkBaNoD9w5i1dK7KYF9Q38HAGDsJ6nEmtYL8uu8RepRNWQbxnqiO9mXQFGUNDCS8sNmgb
CY1Hi2r1fsz00rnh9Le2J580WSrKZzJxzOYniP16p9uuGiKl1bpYDEe9hEt0LwisocVGq5wh/90e
C/dhepVGqPz2td+k18GlGfJdkzFZE2z0i8V8nk9a0fDTBKTEwpEyUzFWJRpfI4FwtrACHlC/i08o
pynBCwSyc6jYOQBFa955CAVeFEcQ1ti3jNBdfgQllx1w4eFH20lvNAr08TRLp4a47RONLJaseEac
geUYO0LGUFZGOhx5jqS0KjuyKt1LaZxULLnuT621/N3ZFRBhfOOvHiFHShHUI5Uao+6Ik1IbShpe
VfA/tqNmoFRq7qLIOsHTZgVXc9risCuySZkAH3U5lrWsvLmzOYezeGPOIqcn39exJNPwECn5Si1J
XSIXRrJW2XvVk+7MdogqPgEWsmQ3S/nPK76CD1v8waMch3m5HcNjy/QuvgcSHv796FMQjiQVcA/v
S8mCpguUhWwXrMNSuQjdnooq7D5rAuWjy3tqrroAQ9JKstr9LiPSMY0gnvvY4kGJbTWvQe9bVuu9
m1Aq/wssdyjJ6vGa3eFShlJfnNMYd0miRSSTtim2RkAw1PBbYqg3VPVtNAZ2G9fu4OYVtjM8Zpfu
ygH5VNGDcxgLLRUjaeNmt8rnr9XbVoSP+XhEL/68eht9WGxu/LgZiYgd+w12RHxrNSg+zuvB5iOm
RdmXTC1OEheT2GLWrokMJPVY6Jglgi8o7MZrazAvawQZc6P2IgTbgReL2ads0r1ucwwlfpZ9mQ5n
2Rqu5/bTZrMZl1aPlkoDq2fcU1SAFZPQfaPT33qu1NjOH6ChqBppwFClUy1+/nWRz8XKAcjEToDj
5L53Gxj07kaGrIaTROwE6kZm1Rs6h4X9g18NKOXyDwfiCWWOOJJJ4FXQF7wUVkc3GrUATobgyre2
nHtvd/ixYqKYYqp3OEO+TpplNKxoRZ80Kg2IgpPm5A1vt9YwHqg4NOGBxJ03dWUvGCTYMsfRGHF6
Rfc7y9LPOuTGw23S7/XB+x8BSP7DLoDuuP95vPN4R+N/bz9B/O+tzcdbD/c/f4+PFeivNyy6OSHZ
XA5TOO9M+fSU7J6+pksINP+IWC8uyxAvOfB7R1S1SU3d0fTpOAqFYQDADHaYXkGxrgh0ezhXkeIw
kwaZbawcqtU+zxc6mJACb32G+egyZCZnfgIYh4dFegUNeTe4JvmELw3wQIQNRw7TiqaI5cBnQ7Jp
i94N154Pjca5P0ekRDpNrjy6mOVpr5sW80dUAnstQq4hdKk7I0xFwuPC8GxzUXykk+IqQ5/TR4vJ
UOddQdUDamJT1IfKmQ2KYV3eq929RnSWW3oZXXMEpWXTugALsRJYtPpz7DTQ7DWqQKBlUAE5DacR
0DF8g8fSBMbqVFDgQ0Q8R/9OIOOVtBBET/dmZDhNez10ylAPZlnFxQhMcjavuiZBH9LFjDCI+wuY
KnNbck4T/TrPRweExoD2DVfpcH6P6xVKMb+e0i0TvzyhXSUdrawcHZLXA8LEZIiJMsUwSbP4X5MP
vZuN+tZt8ufWh4Z8r93A/z8UPyTvm2s/pmv93bXnH282MUnLfVK7eYwJHyWNR7V/AgFp5fXBKcK4
HZ4cd14eHp9rbI9Yr5VJlvVQIX61xiOEGm66jcxRVUWXed2s9WHCAmmMphO9HNWZ6J0K/8eFBGe8
q7r6nvbGw8kPGUi2/5SwklLVVYtXjHvLGTwgWSXRm63s9hIJsHR78VLbhdsXEuO0a36UbhLwobqd
aOnRfw/vPyob6EBN2LbTrFiMpD4sAZYkIcSGP9/phUkIphIkTEETYDS70aJH3IGsy1UAqFG/Q9bu
pmXYSdU0LJYyIHkscMUl1rQh08EWFQjZpV1tLDPucHdp/FBh0E+7VUOCaaTt4RTSZ8LEjeHU0tjY
edpoNprrm9uorRe9BEUS0IOAyNLfiPDDNwezhUjaeJxAcflxDd0goFk8S47cpz3ntNisswOh4grv
cIxPsftEv0P1VYqXvzUJk7liyYeJyNl1u4Iz/ZXelVF+9M2WMjeGk+vcDpia6ImxfQdqyshaXUZT
NkEkTlazSb6xWo9WzTRsrBosAIbDorEjE308lpEP9to2/ktF4RfU9uNfqUNZNYvJM6RiCCvyfEhq
75tsSoyP57PhFHZRsi2TStlfYIYGjekMjpuz+MMFPEMO9uHsBzQ9Nw7FuHH7aeEZpe39gCzQ+sfN
KsOK4DwN0gIkGzUx4zRgaOjTnTqvsUb9uqYvG2XkO7ifJEP8ak0MgiSgF8fh68ttET4YUXoSWXOG
thlcJxV930nAGt05uET4WCxTpmHsDREMwbxihNYTGSckXXWnR97RJXo0Ta1cP2M9cnWz1TaGUy0+
9eMbk+Z2Xf/YrKFaAImjOw+Efw1hlpVb5U8N8HpnZpwWk5EIHcf78XpxXawTL1+Hhq7fUKbbdWl/
XENTn35YY9PA7R7NPJmuNVi3jcFdddi2emC4oGbZ38b7fC6IkfM6UGYHy1S8QxQ81m1monf42KEC
R78DQh4sA7MTG6lADtcUBnWEKvoPE9n5gXmqx5FXhbrL/aJmrjNNZ4hMRfyzZu2lRjuLUjdDlUxE
C+IwGkuxC3lEZmpQ4E7ywlLT5PrmuzOr0dQVbW7p2fW1UZy0QXrnAgkqiZO3cgtdK+sCdMmxixxG
fVT6E9zRk+G0bS8lBGg2K0XRmMZbFoxlZ1SpTBlXPf2klfN41c+uRK42j6sBBvTlLRk2LVgWmj3Z
Kr54bY3SwHtW4U1H6XDCX/m00VtMC/49QyyC9hb/ULvmttbyocMdCRl6bJSODstSi1pzuvKKVoq2
v2EP/7HpsB2rqHNOcUAayt591sScblKRQuNagA0gT1mytvrxHkVVJaBiEKtVsagLRl2mGjK6q+I5
D1whccBtUsmpGMhoKRGXKXpEOMoYBFmoy14h6eQ6ucIlh6lwCdKPBMSBnKadzgBoj65/0IGANqnF
sBfX/Jshr7PesaNWOSrSgb4ZZTR4VKaUNAA33ojcutxGeIwaEdr1hPuAhIwX0YiJaBaKjjlhVsxb
OXzi0dk++abm1PtMn+BTOocQcc/lDF1UrSRr7QTXylNYK6xVh7PBHHen9g207PZvWECW0hwkxz9k
TW26a+rbZGG9lyL1DSggd3kiHe3vgFAl2xz3gnxB0U6oXQ4boBjmil8dk4VQBU2tQxdAfb0hxXUz
pIEHYEc3wXqi94kiIsKQ+kiGsukMt8qRIRVkuy9puyMNCBNL5hiPITcw9ZZGSTbJ7AsacJQUEck4
/dJhfVTRFhwkpb0gKmzAjCD+hLUSMJ5SeSmIVR79oLA6ukncgB7l7KC5UQrlSSUWSTxWJNFAIaSH
Q4sptWspxlIfdSSfFclJ9ZM8e+DckXBT+uQhmrNvofXO0vl/NBKWOuD/bQCylowF9eWjywxX0JKj
JalL8Noc67+45nPDFM9GXyEkMh4/VdfR/SC/dmt4txpNQ5LPUXkHw4OUZQBY8VAzQ50AsNf947O6
TZF1sR+PBumsx2aShDzqEyKrObyG3psAN3Z8CryxKFD6WKdVW2vBktcLn6q9vRedqSO55hyaUCyH
KM70vv/RjE7bIqKvJlS67bmAFZHDpOOGOcrzzyAEGQJEV+jraIpuSb8TCToqamJVbGCICg9fOwWz
SClaZbak42JKkHNBw9SB3pMFBkjCgVRMbpatMZ8zp1c+XPgHDyEcW1dBnpyOZsOouSgYimiC2uHT
tt7v+HRun6RNORxFKXQk9LIbIHR94rBoLiRB8yYDe4qg/UCb1RmF0ThveAvyCZf3Xc0x3bONxVRZ
mMDd46OzsdHhnGM5SUquUH5bruK+cZNnXYJlKWXbV12O4sjZh3v5itxMBVpT6sDgZbZqCQWih5Nh
JiuCr0wmfH8hJYSuW78KwdyMtL6hVlRfs+b7h/Z9dvr3ra3NjyJ8V7BheauVtY4ita8oRVtDuvNk
51IHQb0e8BRoYEF0LB53Y8FHSU03kfYOwwEMUje1tc0bR7n6tv5mXhoNY1u+mnd6gbV5yPQLmcU2
hkWcKEWYRXhG70ZZ/ggnSrr/VTZm/y3xvzeaTQv/eWMH479vbW8+ebj//Xt88MRWUKw4sa5PKHhH
z9/dVguOTUBm9DVtZZuC5MKOFMSkfB/BCHhVRhe/cv14kZH5vZxJUZWb4r0zxTle6qSVF4HbRvXk
ulgSmxktqw4xYnIw8DJIHQd0ySoDoMO2yObbIOQRz++NRygtongjXo+bcWNFImxaHk6EkoVeRQSl
Zge+lc938ir6jyge4SlZLgXF4tvykKITo/PS+EIF3innJ5bCnHeOv5P93jVVdYrlVzTJ2B1y3ou9
bOQ+RQ591ps5NKVDePm6Mqf77KxA/hqF8li8ArkIhMLBEO/3hnPbzJnLpfI6A2CpHfKpKBX9HUM/
TthQLoodxwRF1VherFw1V25Xzl8evDpg3z2ZLpkSpf6g43RnMBiPEzzEG1cVc5RYpZFZRaFSe8eQ
7e3mFmIjPEM9kThJTi7T0bCHKVUxWj50RIpBnTS1uD1grTUV+aRVxtNyq0SX/gHeMsDfcc3VMBj5
oB6dX0+zCp2Capm5Y5YlYFzF0CVsDiXAYp4huc4iNB+JehcNFcgnWsdfKnAOdVLutEreRr0L3+Gn
h6hMvQuTA42qObEbGUhd5bVVoNuz95DgI9LCL9k16xNZLGepEV4SDnE0XcymuWV+PUtNuDTTCYzD
4yj8MFnQyl3NBbfHzjIsSM0/oQhs9JaxssJG4dSONnIXf1bgjYOUtiwWEboPZtdK5lRDE9I1qlEq
9dRqtjO0wcZzzB9qNqn/6SffZDZjf2o1UXCUIyRxFemIkv4z8HigqPm17q2BHbTqlQMpFUo298x2
S8uD0qFkRX8nkSx4bh0teTOstqV92U8jsezocQtwFh7zBVzjyknD8nWOyDu8R1uqG6VPrl6d0bQ4
jumdzYsxVnCAz3hYa0uKIXNlv5CnXhk16+5N7/V/+7F8/+Dsl/OT153zg1evjzAMHl77xO8VFMEB
ChMfV5A9tXfRfZ4NQ1d+zWaoOm9vNJorxxTbuOQvvbKXj8cgjLRf5cBeNIiBcSt2DClWUPvSvsHY
MLcrh2QUTfbQK+eop5+ko3afHDT+Ze3F8cmrg7VdNQZrsle25+gKFmtrBD1IHRRG4NAjAZiNIyk+
Ch8pSYsg4d8xFcI0xxh2pj/8JNoDx87YTp8XjWxyOZzlE57if9l/0dk7OX5++KLzEhoe050rpmxg
yYlTtKM9pELhpe4IIgT04xsWo24bPZ4i3d/ptIMjFu4uRReRW0/2huyjMV0yTnsZekPiXqyuRWe1
uroXRqCeid6zxVawgMkj//Ks+5nujWQFTe0h83rJ3aQZX6c49evYiGJ9MCREUbR8Jd/KdehG4XW0
uPzkOONS7Ho6nk0b2Re0FVKGGpb2saN0NkhR6sZ1nA5hfK5VOzsYryHrdGoNpRqtNWCZEjIP/cFG
Yx44jzkt6K/GNyDrSiQjbPdtHMU3Ujx8X1sDwamXTVbZm4l/tMTT2RJ9yJKTRS3VbiBjOFDjJJqp
I5In/8IigtPRpEsAhGPgljCblCHrPUM96HgE0jiNxRUK/I3oZ3Sny/qw6c7Dko13ZeKwrPfxpyEZ
dBR0bUrjju2CJ7hhIPtstaR6TIYrMP7osr1v8QGwbKFs/kfr7ptuZ8T2zmULwjdKS0XmOMA/aprc
pDDcOnW6RAqsR7pEupbodnTYEzOj72bDOa0RjjoZ/a914QHrurz18ilJrXmJ9G673JKnM61W3Qyz
gOFgR88a0SmKGYW+3EU+kA5HCyAV1TJeylhaOzgGtmpdqjIDXdLDYb7GAg9Cn23kKp7F57D6jvP5
c+xaQE/mOHf4F2xUsCzW8efeEEkTfxRyrUcz1ck/W7cylOUKB76DQnzib33KActqJmxJegZxtjyu
YmmWcMcqs2Bi9vq4ezUkKBJWIVlt6g7GeS9p5k8ey4WTzQRsmsQHDx4X/39+UP9HMvMfGAHuDv3f
xuOdptH/bVP8tyfNjQf939/jA6wXwTZBLhbEduNB/wb9DK5hax9k2Vx4vw3Ezixo7SeVE/h9F0O3
zTK8ny8oDOkaOmzIjZMuS2WHrG/OzsiuEcU84FlvLGFfBzA6ozyw+f0F8xEejWjOkMuxnsbSrpBI
hsewQh/CMLWoF/d3T38xSrqLT6i4+q6Zwn8XSnXFSPH4fAM/W87zTjqa87sd+C9V7y7yGUgV9GJz
B/7ThVFQF3zcfQr/de3HFNIFX+1kO9mTHfUq7SKoJr1In25smjr4RediRj3G91lzc3OzV0Y9+m6r
n+7sXASQk7wir9LZhB73fky3tzfUYwFcxRd9+tj6y+90cCMxhtPYs4hbTSC7VEgpnhmN2uZWc6Mf
1+0kdhAzGkCcjZ6TxgmtRuU8hf90B21YZiph+3F3q+u+tcZgO4Ux2GFcp6PDFy/PSwTR34H/npQJ
Qo1GiCAy+PSbAYLobcF/T0sEsZHCfxUEke6kTza/gSC620CU/QBBbPaf9Lb7X0EQP0ITNpoBgnCb
HZzk3mNY+d3lk9zf7u2YQQlPcrYF/z2pmmRYTUAnlZPcu0i30ic8ya93jw7Ozxl/jFlHK0JGoNW8
rYjoQBTB5IiNieeL6ShLVG4lfts80JHdVUI6gTOEF9aixXaPAXLeYHgL7fEOLOtRdMPEieGk1voY
Hu4aOvj1weEQnVvivz0zBRbDf8eQfpvTL88Mh29FNzog1e2zldvblTevoK53dGSsR2/2CYcFvnDI
SmihFWpzzSoC1hMUEEEBK2+OEDX8O/IWVl2yUrrEjLX6TXysmkgPrzJM2Iou8lGPH9MmNFvDDsI+
0Iq2VHq8jacn29MvEXUUO8TNKRj0+iVQbDYLNMvE3gq0qKlq8KveLFW9w1Wr/ztNmKfzRfFzitVX
VW0KwgKgHzKmz2dAM98RI1KND0+EhD+RTjB3gh5AYQVCz/NkMc+SGV9xAt3QFN+Ri5t0joczTRf3
bhKwUcRdmWdrS1ITs713JzDRp9mwhzzBIUo3iUY+r6hZ+G85uaSRXYHfyt7Yipo8xdZotFqIwowD
qScTSBQp45nuywQOmjSOb5gicehbLSHS5cPJS+1O+nVqsp6sXeTzeT72h9PrvLOUdpwFea81QRTy
elEMfiYIp9+VZp32AbOINrar2rKhVqBpSmtAl1eazMsUYPGmyMtLkcxAAqrkg2YYI49q/KIUHO2S
hoRaoHQty3gIDf4elv9z/gUDGqe9Ya4nItKj8xQp0mE4zWdWv1oRgZqz4oMbogrVzXBLv2/rTDkt
2GnwHECxk+2SzAtFOxTSEKZUs/uB7Azmyb1I5y4axPZVtkTNFYdUbEVPhEOHeqSmuLJnFg0saZm3
Mu9BtStVDaqYtUCKMFk6vFl2geE4O+gNv2oL+LoVvmVzoN+NhxPPlrbff1G9yiaL6sWve3n3Dmr3
jgkIiw7sHMjfNkkOWLowTe6WPqZ9K5PisooMLaGF6vVS8xvidWuczj4NJ9Z+xzSS56Pz4fRrSCQk
nX4T6chWdIYGFbA1tFoDBpyslmQdMaeU0do+7hpbrlhF7mtdSng/N68jPguL+xFHTg1lU9qhy1EN
WVqeNSXDyZqavk0lUC4pLtTB4KZkFQHjvcZxg+ynxeKCntoE1NSdLPVroOMnLhkhVc6P1R25oxx3
ZKQxywbGlHffocHT3H+3vs//oP53MfwDlb//cIf+d6P5pLn5mPW/T5pb29tbqP/d3Hj8oP/9e3yA
JvFkL7fBLdThqZiLBIiBP+bpcFQIPGRE534T7oAttcU4kuFZG7YdZ7e4rDLp/Lcin6jv9LzahpPe
vL4+G/ayncab+R4B2nACibWMLGYOjUlnPcwCzX3DLjb4hSxz6A+Kk9AnDuDrF/tiMdSl7pJ4AKkp
FBX8ReMQ+PNLdn2W/XWRTdD0XYWwrVPUdvx3+IUG8M0ZIjx2F3O/Cj4JangbvvR7s3uBnpJdCiyO
J766owjHRhihXate8BrT/JiRuunNS0h0lF7DKZT1YtYxEt4ecczyNxhNDgUc+OqodXCHpz8E58j1
mTOGKx1iJ2UPlKrOrgto/zmQhoyVdfZ1f2E/ZUKkGb+adiulUh3xbWj40BJQBmxfzJHlBWqc5Y2J
8Czv2ORVZzRo/XUNfS4pBf9MJdUOtXXHc0glVsSuUmuUdOcetl6+8q+7F/dSHl2+qcJYEVi3VIUr
K2d7u8edw+Pzg9Nfd486r1AvudXsAOdcWTk+OT98/ltn7+XJ4R6br9JMJCUb4roTGIIfF7FcJCe+
VXFdB3OgsCfqcSn5xEvNWON2mAU/i2V/XPciRhTR4etIY0rQ5JPWtD+ed8gyTSPTinKUbNZg3fTp
bfz9y9b3r1rfn8VsxsFGPyojme3MC7H3W4utshVXurP839a+H69934u+paJhgfaEvXxMLlaOvzRB
sxNwA5Yzul4jyCfgvOjdGiWcbfjv8H0do8BcQnMZvayGrtRqxKzAySH3SoqeScbAadcyIn7f/FiP
NnZq0f+Iml+am66ty+58PhteLObKVtjYDZeNhSVK9IqGfAf+PMhG02wGZ+H+EFV7yrY++8Kcb5IT
Jy7IwPv6LueAGqMx7+/+1jk72DvhQCub29GjaGsHVsL+wa+wAjrPDw+OJAQLK1U51gr+q6MjoxVR
2sU/DAyB3wgrvINgU2T5naoftZWDXw+Oz+1ycaIxEW2GS4vnfRPL+JfXJ6fnHS5KhXHZwBWM/ydH
ABtTAm+gehcNhkxGrBSEvGNgsZRdTZXN1iAFjosInD1taNblWNAcF5XADOTkMyOvPRVGuu4GjCbv
KfqnMctguLsZkkcdoRAopYzUR+dyIlZwxlPGEhcnWYZ5nmocDrXUiAg6YoyZ6KjOsJXOrtsx2Xnh
jIkB0yS7Qv5yrVxJJ/mVZ8okzGOWX4lHOGGJ8n0kAvsAzX+xwOCxdsGNL+Qum6pukQopx3DkcrIF
8rugkERdRFxnBD5MwGikzDuxr3BwXdd+ZvAVB39dQEfkwhs7hBVI9GBhijQviqlSStXbFk+2sliV
MA2IgSYBWLAvSJ5I+gT17ZhPTQilwtjysi9Zro3VmSvBgxXT6TYPg5otYQ41pct2/S/tWMMumCx1
lWzWVSdVrFQrtu/dHpd2OTJAKtTv/QtRoylNuIrWML+1xj9GP0UWJ7m7RBoqN9mAPHTtJei8Fks1
YOgMDYLJNTQIFRdAwClVjWauKv67s/YQQU3tLLm3PQI1HExzWACCu4lmFqubzc2dtY3m2saT8+bT
1sZmq7n1Q5P9VRI2iCZvGXJtf3u+h3s+CCu1Z9HqKvZFrmZ9H/eyg7tiOL5Xiv6CQg9+gVEbT7HR
DSBn+P3vCCxSa0B3xByOEk2zbjuWfmhfHCbAzgwewzgqVuJu3u91u26cYVb7QssQKgdc10Gdeed2
A0rp3MA7W5HmoYaDtnx+Shy4pVmx2W1aNj/1SrdItGUm1qPdmrNDuenMczvkuglr769hevFRhpU2
HD2qTiyAuwaVNkWrKdn7eF5wU3mfbEXwCIHeaShoFDMZRbcka0Sz4IhmZkRlg6Vn8v1jVa+tKARO
p+F42inSfpbYzjNA5RiJF/YAPECSGF6wFboySU+jboaQXbglI70uRmnLQs6g+HOUYTERQ+XoaPdY
Dbu9jCwPG2oC2TuzfyX9ft/a+MhwQm3ckH8gzBv855/xnw8kgnyYxWWRLF6Nox+4DHsO+QF3no1S
YQgSPrHAkWiEOL1CA1KmgYLjVDHC6gGPJfNi3LgzRBKCUWnHi3l/7WkJEA43JaiksT/szskAeZb0
pTIarjbXaxjoFZvLDujoatnv4kTS1isNdDmo5AKBILn53LJmllFQPtejS8qrAlbf1pxhQG2E9PAe
/b+rz1hao7cAFieFQYcxV4GYQGnRHQ6VZAOLAr1VNq1uckeS+MNE8zyWmslxgHzYcS2htfG8TqbW
tmxEptdt/oPrPRSyK/HMTMo232s3FG9o7QbLaX3/2/fj73tr37/8/tX3Z7cNDAdxGxvAjp4j8bOo
zu0ep5+zDrkqJDydalRRsrBVAhhAGgNQqFSCtoTH7Zda0crKDNJiFDqlJFR66pdCNZhTRW63IBOp
xF2xNcCg3fnVHlvfGIttSnOmroh+5gDhs6SkpmlwGiiiCGV8lfeyUCYKValTWTlRF3I+G376BN0K
ZDzO7QR2jYP86sVs2HP7OfCGjYfkbA6T3h0cwU5xJvHeSwBCc+1nwAnI95SnbXQxwomjKeDn6jEW
fnKBgdbQMSuJHcMa18UIUtvkofQmFnYra6RAnNaKxjrI90MKdIWISghllhQod/eyYvhpgqvP9iXq
RWe/vjCgK1P0ohXlXLKx+RQOvZsC8TQdN9DeTIWcxzDm/D9lKU85Wc2XTMfyEDt7CnSfzV7iqVol
aOyCAJeOhin6M1tJ/cD22kjUimhPCX+GzWJgUoldqk7Rm6VXp7g6sx4Fm9+uR9vYl6b8s7mD/xdz
22n+mfFTkp1telyPko0mRqPfxK9PIe2Pj/Hb9qb6hiMDbz8ua7nYC1otR+76pR5x8Ciq1XKBoTaj
vpFagf/HpNVdFpPbexd9MBoNpwWsM1YDJ1R6PXoC//MnYA4rCL5U1y3mtM5w++VzL2o44Ph/lRRF
dIfGSV9MBGNjdLNKOhHVtIOMVhBkvUL+kCjAfRXsWEHkR8eV+PjGu5r1mQiyw3ruJKd1KUNKUcLM
OxQ3Kp2ySeq3/bIl0rtO5sXXYv/qtqDzULRABSfzkezBFZi36dIz9vvnQABl9P/9n03j0FPMc8gt
ef5w0CwegEaGaFkO+pNppYVyKhovrff1wCd1sRJgjUudzzAAlF+Ghl/nMnAIPqMoqfqcYnwhCtyc
ouacQhgsr6gfv53A7s9X9wzqSD5LCunS887nG4FErgmsIyHpMfCEOUM4i/SSMPbHWW8IYsHommeB
ddEcr7qIsKlLXfbZ0MAOFKpiU3PQ6+sOFcjXRZ30EnpF6CFL6ImL9KjqzsifqtqorVvgJrBag/5l
5lepIt55ztFINdFxB/14f5AONndYPGbrdN5BZ8aL8Tu8Qwbu2rRwRElrYN12MD2v6AQiUrmhB0me
sopopL2eSE1qi47pKuBwb/f88OT4zA7RRbIvutjjbo181L008JQfCLmgb5usDd4kwA7usX1S4oS7
Q+yAUuJ5/ukTkjIQ3gR3rFE6vuilEe7nn9uQo+VFuUNIg8+IzeAV5fa6e2E5+JPSy7r4sngSapM7
F/MJ7eH6Hgvm9eB4Pzo/ODuP7GGLyxkb3dEQe6rb75BbQ8esdJpjNVSVU3ovYlhS8+dV+gDJylRh
h7m8D028eXt4cB69PHl76lAE9YEhALz5jl8t5plHfOVA7v5qUEVVUoYfCLHUad1wqzSrEjco4vJ4
iEuowZ0akWFjPKaXRkfu7dB+TYVGxaMTPVEAEC4YQ0UtXml3NWael5qCJFbRkAzPgDaYw7JGqHK+
jRSdJnXwHtOZU3fqGsNC0UEV2ZUYAxecqziW8rq8BpiH34f6yZXDCVa4hDaQS7LHhmKTiYEC2se/
KB+Ltwg8OmJ0IB++hZaTdUke4KCz8DqRvakdGScQK8cSNjppSxR5b59LJjUODGuHZ3CKdWhkdvH7
8KhP2YSCPt1nhl4cHB+c7h6VSN7cnPv86YxjtiPU9iecI7wp5ctRCyiq5jMouzx78MtO+ctaUk2y
OtVSxmaXZSeEhY/oJ28WsMZJaWPhYGG4GgS86sWlZVQaHCqpvNzu5MwWTFdgtQZ7rskvtH17ZXqb
ubo5cCTCgKxttfwcveZ5nH6I4ihJR1fpdYEeDIj8hoaxpCUgnM+aF8jSL+tAJtrSlFRMl2SyKPwe
e0t5yTBeWUAG2Ts6OTuIAwnDMgdaEk4r9w+d+e61ymgfZjPjKJE+pJbsONpEJ6FvCWqVFiDdzxuw
8kBWsA9AkApHeJ8v7J/zLU788mVrPI69ZFj9HtuB+DT11/lyyfCvkDs/I49hXXg5IC3WYnU3vF8R
ZXqYY2artqkln1Rsyn4iU6W/k1XX6K8dS1Ki9HfuvaWKDTZIoNLAidlGE7ErXBqSAT+WpVgDPUdx
UrhKj1MTML8J2cAWPx6ApAxE68PkJvPj0ZaZMcUZZBVG4R3DwhksFohNsPt5jxqEX6jTtrGaSywL
OhnlILhdS5uumfNyS5/av0LFolDxgkRUeUImkaCj0dJsocNNaLmjehlL51x2J+gMezaIr3mPahdW
8QTfG8Bc6o9B24vNm/K5W4NWOznU81J6bAOFSnOiytA7viulRhbBBsqVS28486szb/wKaSMKFTZI
i4689CK+06LGzYbQR8OvEV2902PVmphaudWiZati17PEBLBzUyCZHKKe+jIdJb5ZYTCDACK5WxGv
EIpB6LVDafIxPJCr2a/Qs5CS1MnqpbQ0O8poU0sw9RD8Tc1Ac7b1lHQkQLlX+DQfjTqhsUNpFgh3
WkRWaO9IUJ7QasmFl1CCp4VrVFWRMwWbzWazsknhsdeqB0xYnZd5uT89vnqrDJ7n0/MsQ6/OZGMT
7w2e7DQdaSgnCUEkkPIM7yEicDpS5wtIbtLkFIDR1YQFUlAxOQzXZF68Ir+XItmAluAFDvzZKR8/
+FLQPX3Is0olETmk60ut+Pjg/N3J6S/r66+Pdn97cXry9ng/9lL7d1300ErENdp6IEwQel8WGPVG
FBIad9+en0RbTdg5HHWVk0fvdHTrGtBQlhLClrgsWfDcI2KGOahX9t0pzKujO8rSWVg6Ptg9jU6e
P8coZX5Pda6wqMyvxYLnrobpsrw6RkQmoaadHpwdnEdAGydvz/2WmVzhpsF6gl2EU93VMlNWhTo8
rNk8Pz88fnEW0FjrPOGmoYVDRyW7q212caE9N9Qy2G+i45N3wT26slX2XnNHk6Qcn4WYMxDnC6iU
8in5vUT/YTu+0C/yfHG5CcKTto3vA14rGgMFq3AosIMmqCEWOb7weJ8ktlOEeJ91O22nDF0HMBOL
Xu2+Lp3qsatty1/CZz7wntB5DeButRSIaXnQzkQe9OaPnorZb2XeV/llgL8QKAzCFPYqe8ulwG5Q
s+fHSqIH1pyLEaCvamJG/sSo1HaS+87MgEXf8K7Dsnx22dG7k547NmY/8/YTv98mbzldeVcJlUAi
msiybBnt4nDGZ+llJrFy2SBZonqPriPCXo+SGZlozgtlc41ma2xrXZBF1N7Zr2iD9D/PYLvyADpt
EVssOJ1BdtetL8qIOflFOquWQUwaf7/mNz+ntvzevwzczFll2CnvSwGc8oxxFZLtEk/GMVPKfe2U
VRaldDIyZUDz/EE+goknxVh8xkN/+LouGuxXu3sq+GWj0YBikr35bPTD85Je1Ct5D7dCZtdKpxG8
3zSZULvt63HU6pWRE3cfZ0xKm4ku0Uq2VFuP2q8lI9sX3yR/Dzo5DokTfSUrlJKHxY9+Z5Jd+WmP
D95Fm9svbYICwof9CL2Epnyh4LQNdSSwiNjiX5orCyH2MLydT+K22S1G+vE15UzQM9AqI+B8EHI8
KN193CF5WknE7R+E4qn7vu8qNZ3NvF+pYWWCEhrpl2+r1IDfqcU2RKt0drF2cXN02O4MfFO52tMu
VDBMybcUCtn8Akel7TLE0ETJgD6HHfPeGmLtzprY/q8gpRNfwasxOjY3UtjB0EHN4wb9vLsoOrzM
Le1i0SVBKlz0Achz00wVHeYRUILmxMAJQRLjnqoi3ZQVjbP5GR0G/K0GN1qyYFVaDTZnfR+fne+e
v0U3wPjwNf778uTsHJHj8DvwYOUuVS6ILJDPlAFoFQNl0cnawgc6NoUuqGzjaSVnY1Sq45TO8WSQ
2qzbTsENfnOeq+3s7gI27ltAmfh0w62RqSaCxj6MwDyrR9V57zn91bMPTBr1ekqZWSVGGjFQJ+DD
QaUk2bvojDyBwuRwk91XmqC0AVl//+B89/DINfqZsaaX/cIT74UvDjHEipXIbznlKlEz9UbdXyrt
CZM1Om7SPtLwN087m7rck7simMDTYXdw7lyZBzO9y2e9dzM4uQTkEz/t7mj4aYIBIbB8+nGe41FP
/TrK+ndVhy0ipV1KI/58lH4qsDR8zv1Fuvz5+lW+KO5qjoVoG1ch9zhTUV5DpkA/XYU2SYg8cCh/
fnL64uA84hNHSc7R2ZbcnPopg6f4ylVW7p4pqpLw+4x1UHnms9eZk8SYvz+HmWRr7+3a8iQbaOe8
PMlmPdosaxUUnJ5GzfBMIvJP1adQf/1JYjvFfZlGtvQUmpXOhcJTyFk5Ojp5YXOVrPp8WS7oqw6Y
7PvMQzUYYny164iu6f4NfW4xBfn58qkTQ0x8xelSPNmcwTMCY8anSzcjecIF9/zzQ97faXzCWz+z
Y3v3z/TObZW8bO/O/ta9u6qAe+/dVQVs3nvzL61sq+/Warkkh2Nfo/arOPPUvHS2Sj2fLnlbWjGS
IsQCtu5OtUFLXKXSikWpjHMRR/LOyuLOrHfH0gmcEpRcZxQgbHXyih3Qb5mVy28b6noXU7qU9PeL
WdafZUVpG3GvltQrvjdrFOzVNMjnyRZeFvnaW+SLcqREG3bCJIzSPl4DUarFlNundLJ4naYZpjLi
UO2l04YTlevMMgSiG0jy2juZwul1nQz74c/rdEGhjdDSqhG90xATHBEnEIUQb2ULJ1KXf5frYd40
hoV5sKusm6zBEusnp5hQBDhv4IOVufemcgQzilJEJGwzpI93IUyafqBrfL0r/B5HCgGiIXU5ITSA
fM5KRydgxx0eK1vWTkul0wRM8qtSDSpxZQ0B9T/fdeJc+tXwBI857hfMZbk6J2tVpXyg7lA6k5fs
wbwKkZJKlaiEVcXz++nUnStctFKsGvbKBGrUqhM4/SwnO1MYjkllEaoXvpZArtOJuOiP8nBJgXT7
0Fs4uJWp1zqnEUEGpkUlU9qhe9xOU5aKgx3aQbGRoXofrG9AvrCGyZRyiQHPLEsLx4wKw0DSM1Lt
+XxAnDTrJQaxny+AI+yhkOzpzyT6NbAQ5bVa0xga8uKVsnZNAuARzFOGPZvd4McNGeekttavPQj2
Y4/T6mzHeGQblTYODPNUslhSY/muVJNtm6EsEfGmHMNL9q5dDv8zB2uNLoepMbggVp8sEHqZTGdt
c41hES0m2sQUBUW0zShqDkNXo86lVcV5dwlGjN4Sq6nliT6cMI4F4bc9JUMP022LwQRHOHRDr+lA
v3Ss7HXhir0EC7YNjVBycN+SFam9tdvRWDRMQY04mLNq0D4JzZP8OtXoGgOmuzc7x9ip3EYlhOSl
a0vH/MV5rZphm6RZc62jzdsJYHRPGezBX2yllFcpDMdjx5bna8lK1q0eUZoJAquTZUHCs23FmSsR
xBVJHI5hZtt5vNQC3O6CVOI2mlrSGH6a5DOf1VSxIFvqcSsvRXOuYmwOpwhtDUtuOvQnPquKBd2I
TlEgXSPthcde5jmtqYZnkmpIwTHgLfWoHpUvQirpnhaRdQqjsWbT769clyJHa8PQdd9zBsnMsfnw
F6/nUcp06PS47tro1bURoPH8dKiz1uD4dYbObX8VrsCKjEJTFsdHw0vlmVqAVN8dtBB9xIJIJDQS
MuCQQFS4XRNaAKN3UVioshjvzhvHDZb6cfhMkHc0+ny/SglWP3rcyDarxT8eQw3Fdlk2g66C0A8Y
E7CfMHYaAeOMZVc63nnSVkuWjQDVcVDPG5/lqWvKUxw2d2veuoozdfUjMc33oIOsMPdlyHoPHEgH
/+kavCY/iY4AhGnkh5/IQqGkdBT0yIYOYn9WgljRQOPuukKnewTWuhI8V2dZqQHzFpS6WTURxhUa
nj9viEghVhGieVImEisub7ALE8BAQghsb5UsS23VE6JXIO7JAvYXBF0pqcgIaacuqEmTBeypIL+5
mFDqg8PkYbkgYkmiAZ8aiylbtGtowQ6qyaLYc/HF1Niy57DumKkrZAar/UxyuuxaLbADeT2l1sxI
L1pqpAYXVYhVX1HehhD9vTNsBhogKFgECbjmj8iywrbChRnErK8vcjtcpILWYjjJmq9HUlwIV4SB
daRXxpBfbxxsp1/XRDvNiyH5GSfmplf7FVhVSYgxlAmLxTjZKEGZeTBuptcoLkOuPgW0XiPl000J
Und9PdoAAe62iI3oRpLksMDzMIZoFmA4UwqJ75ZjnvgZ9OMo+o8oujFiIr64jV0plBJzif62pHky
mfc4s9ePb3C5KmZwqztPNaoxulXmJPh0Me0RpOWNwdE1+JBQAuXETt3ecDt1hV8rzfJ4kKfFXYMY
JZy4FjslkIFJ2yD+UhG2n0ZNF+x4b3Ch6A6I83KdzeMyzfvqhZIs1w9IlTfczNsPE3tw+1HFLHCa
DxPqB7alBSnh+63bHn8TxuO2mJqWpDcy7VpXNnW+RtTf3r0NJ7AJ8x2bYxhnbf19W0jCjzZKUzE6
7E8w0MUqXSavVgY7WeWnq06wEwwm9VSFcvGmbllYl1WWF6iwYmlYLvW5vQ33r0U2KsHoNnYlfvZg
3KZ7DpRVrB9tpaoNIhitqoAmgV7FKL4ZVQ4xEyGRqtO5NpCyFAqhc7oWwEIliC3U3UXYuLfWC3KZ
0u0Wemc1XElHYoNay57h2iSiJD2fwSqnQNgWW1UjYZ6ztVVYlXLJijgNWsySros3KmO+LyxgKRKx
i0IcJdkX6N/omkCA2MIO7c6RH3haKoXTV4GhXDEG9WDP63f3OyB/VnU9xGIGrLuhx/4QajlWp84c
g6Ylbp1eSl+GpWrdIxJanrMZqeOQJ8JtzxVuOb9LtNqKlEgtKF5QVT6YIYlO8X/95/+JxOKUkRio
MN6s/us//3fAu4ULCwvB1pnHL80+6vjyHvtko2z2Zt54W2Sz0xyVlohh2yv1ozTCluxczO+beCMg
R/bulHODRYVE5t49pdxggSGx2cFLL5XFciUOFqJz+CJqUF1l6G7msUr1ZrlK0G65AEwmJrOlHiqp
9r3sZM94pjbGhPUaKgyY+LoMC+Er8ChfzFtRL5+sohXGp8GIL2kRkRZPy7N7LdqQfZDxVaiSa8Xn
IUpuzFoOiFo1I1p6W4QSLZXzRECMFS5KhRtmVzJVF17XQSZq46rq3lSwR+dAXwtV4EIBXA2G3YHn
nM+ALbhX0FsG/jVxNnQkDgKWgx0DegwyKzrqjxY94AYp5Mnh+cxlY/hEcWRj7Y7A5lSLDdtOo+iI
Bf5qoNKqN3pd4V0u+iahdcvhUc+SAkN09pUzY9slh2+6XAeJ55h+uXsGrq3d0ciT4yXmhSO9B4yj
5AYM9po5Hpk5zpgdbSNgwcfBJaw9xDey59IqDANcE3u8IhvP64JJwxhI3eISKQ9NraKkAb9qjISE
AMf4Ao2v8A3+rpWcAvi+3Lta9kwXJV3gulxs3jsiWivE5H4bWtlSw5P0a6XOB+6Ylcw4t5a+634k
ww9lf63O7qsEHnUZMijdht1PJRtIyX5Ax7lu7Tidw7JGiVI8tkQSXdfnSGzDgMxdchkG/37Du6OA
9BlrNxK1XbSi+zBrkyT6x3ZkJwjrP2RNJLFyYqkzUTohXpQoquHquQYCoMxqpRkW1WhogperUcuh
W0oTyel/15k8H2SW2Shs0Nl4Or/+hklzB5RbqsbTjmxTD4P/UwAY61ggBRmFvxTl4cbLLJQPmhai
Bm5xGKct8V5gBAj8W7p0JYiYtl/OMlFIcrhh4QhaHTeGo5xvXxLv/T7weLQWL1QCPirOZwm+bwxy
0pvpmnAUZHtHzReyScRoh8PdI2aW2HkYJNpjkZcK0RPb1CmZeepCGWe+Q/b7Osgb3kmgvSw+ITPB
Eh0hxs4B7zQM3o6XV6j3Uxr4W99KVnrFiIa1aL0CZh5XDOJqxDdWd2+fPYONTvehZpVdWiPYoaA6
ADbILl59IWS3n4lahjnhML/o94dffHXjfBD9AKPawDgH0ET9toRw5E1BWV65KxCCkyFsUFMZRMCQ
6N+ApiTTyrjAHpgS1ayiHGVB+KQQW3DgbTQl8HgHUXh75PhchsCp++V90yWjxwMVJaNCDfcMNZq3
Qto3yGJukRHeYJNvY1fgZkGspPDCwA9lJyp1IjrkuBC+eGfDHFEJ75sfGz3vRE2aaS5fwy26Bal7
ElVg4hd/D7Wwts5Sz/0bxpKcUq7F3ENYPSu3WRZhL3i+LLvHLHX80Tnv5VFSRbDhzJ79890KG1Kq
aq1VtVJFv1eaFTPKw7GV3wQDN7Im+iq0rXA5+EmMv2A//lMxTSdswtBeZTXvDf25Xf3pZpWVRqt+
i1ZFYbR6+6d1zP+T79+bsDeCp2vx01i+CkFVip8eXRnrka8k8VOBNLF/cho74eKq0j4/PD07j84O
Do5ZGDExGP1YR6WsR7vVOe3oR1bGjzZNq7GRoGL0Xal1zHWlt1fBdKKRRgayzwaefU5PjsjT48Xu
+cG73d8cF5kRV8JjJbXwD0t7RJeg96zk/OXhWfR6L3YxNN2AkqoOX+eOZUr8MEIIpwKtiJIYQDJx
gkqqeJI1u77BfEwQpX9ilxjcrgv2vG+v7qz+hPtvLLEAPbXOn+azn/4073mUDqsF6fwz0PG8h+9/
urmU7+uQIXbj9UAnjGSBVUEibMdP3sEhyJaw6d6dGsYGQCHaOY0bQ/OqW5Lfx3gwxNg0As4dXnZ2
OuG5e7vHx4fHLxqNkp/lN+26ZKhPgyPxEtyCVXSH904YSaY8cyFfOigH1h3l+RjongYMtKJlcLiG
ysQ62kPJgZqfL8kpcRZCGTv8bllmjNI6qMwub5e12wZpU4ILt1lbnReLkX1aRW6NWwu/aNBPo79h
zol34G1jcGkQ42bAJ3uWH86ii3B2/cVIRRsBIRIoe7aYELauAwNvziYzmNacnJpuYCI/Z9fxxxZM
fPX0m7tJfdZ+b099xroTB64OSyPtJ/XQl0GyCWqTkkED44q4hwJoHZSmGkl2XIFk+ajHuJOYUCgT
g5Zibl8pgR8x8Bs0dLhPaF/Cma0N1CuiZgVgtTtGFlPWSOUXwPUvM2goaf0aZCBj6qqLENBGUUcB
u7QHDf4S0L7yMCvGbwW+luMc1yNF80hAy9mOq+1Yx6meYB6urmwERCMj9EhbG7bb5p7jzLnuYM01
PHm9h88xxBVem18s5hL9BRZAvoAzYS886+OsPJ/+SEIaCjuT8ViOs/BghlQxmUYY5dzBeooy8qiq
zdmlZViqBAtP6jDjaJ7dUb0FlVovZw7xHm2ldCPJVcQhmNjVP6/ekn+FekdBrfppN1Nv4xW7e4HF
+V30C3LrNRfQhq/Fr7JZJnwpwxhei8mcIyiOh0XxTJwBXx2enXXOX54enL08Odr3ysaEaOo1QW+j
/IojR3/KFe5NIzqZyEFYOxoCV0uRpfF9PNv04q6XeUUDKWLosCxKCJV4Oo2u0gIvwq5Ql4rhvChW
9WJCjVf9MnXbwXSiNa/wAvUp89F1PbrIuuSkRgNCDURflaLEbxteCcnuRLSAPDW8dDIy7eIolBzW
CYsk/RtF3pxdo4QyyvrzuOEZW16lM4ILvolxNyoQUCpuRRu3pCwxGwkxgJvbEg8Ls/oyL/KCq+L2
79y3qi2kRm2mMrNJuRhVrc86WS3QQbpI5Ja2Hj16xL0LNEd97mKR9hEqeE4q20F6eMKWlZ2bruxc
G15J/uZN2LNKM7tM71kl1zFAPlIa3wcaq7UIJXiXRZSlEhGIRDJRgLpl+PSy1NmPlSGTnJnL1kx3
yqUIHvl89/DoYL9FrdWAvuVmiuAVvtALiNohjLOgpC3olfZhwviaqtBa6GmB1+6TxdTztXABUyvx
4G3fL67bAX21Y3rYb54/d3138tDlUtiDu4KGlrpS3cOxyfjZ6p6UHHSd3pwCZxs7r+92RPCQRf7u
CjHvPKfQcEoMw2Ioiv3pTOmkuGJ8YksB/NdFVtD9RGlg4Qj/nHotK9hT6vfV2xtqzC3x3CFaydro
Gn/+MEkOUWPJGx+6RUlkPiUPYDQS8pbKJOS9fv+Fd65GpcpfOvSPbo9+y4q7z8IwTzKlMl0lQ6WA
VrasbA1QSmEjkRp7NqQAx5JvN0LcUdz9I8GyUT0fp9OWFCO/WTKIWC2CAHW20Z6JVkwxqjyl80zZ
rvlX5ooaXbQwMsKqBdTOILFzLyoc50K2RLNaKa03F98h2rpykNMXvjUyUGwJvaAiGqnEjA6T2kQg
Qxk7l8yBGysVbbq/uZ9vynSvEoNaFId0eOzu0NQLmdxPP+8A1zp0JqFPWyWK1/J8P57mReuGk9+S
pvjmS6ux0b+t31zTX/uewwaTDu52UDTDW1teFneuEwc92y92YvFTVHuQQ98CY1WfHRwd7J1Heydv
j8+TR7Xo+enJKy1ivHt5cHqgTl7NuNboI7YKrNqk9r7p6GcnSNDNe0g0x7mPdomXQdT4Oy7Fv57d
EjBqpDEbPXbLKHXRDbkG2C1KCvbgh+UwnHns9w9lnWryvplp/sPD5+Hz8Hn4PHwePg+fh8/D5+Hz
8Hn4PHwePg+fh8/D5+Hz8Hn4PHwePg+fh8/D5+Hz8Hn4PHwePg+f/5c+/xcJnrx1AGgBAA==
