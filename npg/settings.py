"""User settings (stored in the database's meta table) and the autostart entry.

No Qt imports here, so it can be tested without a display.
"""

import datetime
import os
import subprocess
import sys
from pathlib import Path

APP_ID = "network-playground"

# Every setting and its default. bool settings are stored as "1"/"0".
DEFAULTS = {
    "theme": "dark",                  # "dark" | "light"
    "notify_appeared": True,
    "notify_offline": True,
    "notify_online": False,
    "notify_ip_changed": False,
    "quiet_enabled": True,
    "quiet_start": "23:00",
    "quiet_end": "08:00",
    "quit_on_close": False,           # False = closing the window hides it to the tray
    "close_hint_shown": False,        # the one-time "still running in the tray" balloon
    "custom_cidr": "",                # "" = scan the local network; e.g. "10.0.20.0/24" = scan that range instead
}
THEMES = ("dark", "light")


def parse_hhmm(text, fallback):
    """'23:00' -> datetime.time(23, 0); anything invalid -> fallback."""
    try:
        h, m = str(text).split(":")
        return datetime.time(int(h), int(m))
    except (ValueError, TypeError):
        return fallback


class Settings:
    """Thin typed wrapper over db.get_meta / db.set_meta."""

    def __init__(self, db):
        self.db = db

    def get(self, key):
        default = DEFAULTS[key]  # KeyError for unknown keys, on purpose
        raw = self.db.get_meta(key)
        if raw is None:
            return default
        if isinstance(default, bool):
            return raw == "1"
        return raw

    def set(self, key, value):
        if key not in DEFAULTS:
            raise KeyError(key)
        if isinstance(DEFAULTS[key], bool):
            value = "1" if value else "0"
        self.db.set_meta(key, str(value))

    @property
    def theme(self):
        name = self.get("theme")
        return name if name in THEMES else "dark"

    def quiet_range(self):
        """(start, end) as datetime.time, falling back to 23:00-08:00 on bad data."""
        return (
            parse_hhmm(self.get("quiet_start"), datetime.time(23, 0)),
            parse_hhmm(self.get("quiet_end"), datetime.time(8, 0)),
        )


# ---- autostart -----------------------------------------------------------------
DESKTOP_TEMPLATE = """[Desktop Entry]
Type=Application
Version=1.0
Name=Network Playground
Comment=Monitor devices on your local network
Exec={exec}
Icon={icon}
Terminal=false
X-GNOME-Autostart-enabled=true
"""


def autostart_path(home=None):
    if home is not None:
        base = Path(home) / ".config"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "autostart" / f"{APP_ID}.desktop"


def app_icon_path(home=None):
    """Installed icon file (made by the installer), or None when running from a source checkout."""
    p = Path(home or Path.home()) / ".local/share/icons/hicolor/scalable/apps" / f"{APP_ID}.svg"
    return str(p) if p.exists() else None


def _default_exec():
    main_py = Path(__file__).resolve().parent.parent / "main.py"
    return f'"{sys.executable}" "{main_py}" --hidden'  # --hidden: start in the tray, no window


def _trust(path):
    """GNOME wants launchers marked trusted; harmless elsewhere. Best effort."""
    try:
        subprocess.run(
            ["gio", "set", str(path), "metadata::trusted", "true"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def autostart_enabled(home=None):
    return autostart_path(home).exists()


def set_autostart(enabled, home=None, exec_line=None):
    """Write or remove ~/.config/autostart/network-playground.desktop.

    Returns the path when enabled, None when disabled. Raises OSError on failure.
    """
    path = autostart_path(home)
    if not enabled:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(DESKTOP_TEMPLATE.format(
        exec=exec_line or _default_exec(),
        icon=app_icon_path(home) or "network-wired",
    ))
    path.chmod(0o755)
    _trust(path)
    return path
