#!/usr/bin/env python3
"""Network Playground - entry point.

    python main.py            normal start
    python main.py --hidden   start minimized to the tray (used by "Start on login")
"""

import os
import sys
import traceback
from pathlib import Path

DATA_DIR = Path.home() / ".local" / "share" / "network-playground"
LOG_FILE = DATA_DIR / "last-run.log"
LOCK_FILE = DATA_DIR / "app.lock"


def _log_to_file():
    """Started from a menu icon there is no console, so keep all output in a log file."""
    if sys.stderr is not None and sys.stderr.isatty():
        return  # started from a terminal: leave output alone
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.close(fd)
        sys.stdout = open(1, "w", buffering=1, closefd=False)
        sys.stderr = open(2, "w", buffering=1, closefd=False)
    except OSError:
        pass


_log_to_file()

from PySide6.QtCore import QLockFile  # noqa: E402
from PySide6.QtWidgets import QApplication, QMessageBox  # noqa: E402

from npg.db import Database  # noqa: E402
from npg.settings import Settings  # noqa: E402
from npg.theme import stylesheet  # noqa: E402
from npg.ui import MainWindow  # noqa: E402

_shown_errors = set()


def _excepthook(exc_type, exc, tb):
    """No console to read errors from, so show them in a dialog (once per distinct error)."""
    text = "".join(traceback.format_exception(exc_type, exc, tb))
    if sys.stderr is not None:
        sys.stderr.write(text)
    if text in _shown_errors or QApplication.instance() is None:
        return
    _shown_errors.add(text)
    QMessageBox.critical(
        None, "Network Playground - error",
        f"Something went wrong:\n\n{text[-1200:]}\nFull log: {LOG_FILE}",
    )


def main():
    hidden = "--hidden" in sys.argv
    app = QApplication([a for a in sys.argv if a != "--hidden"])
    app.setApplicationName("network-playground")
    app.setApplicationDisplayName("Network Playground")
    app.setDesktopFileName("network-playground")  # matches the .desktop file / icon
    # With a tray icon the window is only hidden when closed; quitting is always explicit.
    app.setQuitOnLastWindowClosed(False)
    sys.excepthook = _excepthook

    # Only one copy at a time: two windows scanning and writing the same database would clash.
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    lock = QLockFile(str(LOCK_FILE))
    if not lock.tryLock(200):
        QMessageBox.information(
            None, "Network Playground",
            "Network Playground is already running.\nLook for its icon in the system tray or the dock.",
        )
        return 0

    db = Database()
    settings = Settings(db)
    app.setStyleSheet(stylesheet(settings.theme))  # saved theme is applied before the window exists

    win = MainWindow(db, settings)
    if not (hidden and win.has_tray):  # --hidden only makes sense when there is a tray to find it in
        win.show()
    code = app.exec()
    db.close()
    lock.unlock()
    return code


if __name__ == "__main__":
    sys.exit(main())
