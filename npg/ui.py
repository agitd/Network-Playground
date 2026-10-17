"""Main window: map, device list, details, event log, tray icon and settings dialog."""

import csv
import datetime
import json
import time
from pathlib import Path

from PySide6.QtCore import QPointF, QStandardPaths, QThread, QTime, QTimer, Qt, Signal
from PySide6.QtGui import QAction, QColor, QIcon, QKeySequence, QPainter, QPen, QPixmap, QShortcut
from PySide6.QtWidgets import (
    QAbstractItemView, QApplication, QCheckBox, QDialog, QFileDialog, QFrame, QHBoxLayout,
    QHeaderView, QLabel, QLineEdit, QMainWindow, QMenu, QMessageBox, QPushButton, QRadioButton, QSplitter,
    QSystemTrayIcon, QTableWidget, QTableWidgetItem, QTimeEdit, QVBoxLayout, QWidget,
)

from .db import Database
from .map import NetworkMap
from .notify import DeviceEvent, Notifier
from .scanner import ScanError, scan_network
from .settings import Settings, app_icon_path, autostart_enabled, set_autostart
from .theme import colors, stylesheet

SCAN_INTERVAL_MS = 30_000

NOTIFY_CHOICES = (
    ("notify_appeared", "New device appears"),
    ("notify_offline", "Device goes offline"),
    ("notify_online", "Device comes back online"),
    ("notify_ip_changed", "Device changes IP address"),
)


def fmt_time(ts):
    return time.strftime("%H:%M:%S", time.localtime(ts)) if ts else "-"


def fmt_datetime(ts):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts)) if ts else "-"


def is_random_mac(mac):
    """True for locally-administered (randomized / private Wi-Fi) MAC addresses."""
    try:
        return bool(int(mac.split(":")[0], 16) & 0x02)
    except (AttributeError, ValueError):
        return False


# ---- pure helpers: filtering and export (no Qt, so they can be tested without a display) ----
DAY_SECONDS = 24 * 3600
DEVICE_FIELDS = ("status", "ip", "hostname", "mac", "vendor", "first_seen", "last_seen")
EVENT_FIELDS = ("time", "event", "ip", "hostname", "mac", "detail")
EXPORT_EVENT_LIMIT = 1_000_000  # "the whole log": db.events() only needs a limit


def _haystack(d):
    mac = d["mac"] or ""
    parts = (d["ip"], d["hostname"], mac, mac.replace(":", ""), d["vendor"])
    return " ".join(p for p in parts if p).lower()


def filter_devices(devices, query="", status=None, new_only=False, now=None):
    """Device rows that pass the search box and the filter buttons.

    query:    words separated by spaces; every word must appear in ip / hostname / mac / vendor
    status:   None, "online" or "offline"
    new_only: only devices first seen within the last 24 hours
    """
    now = time.time() if now is None else now
    words = query.lower().split()
    out = []
    for d in devices:
        if status == "online" and not d["online"]:
            continue
        if status == "offline" and d["online"]:
            continue
        if new_only and now - d["first_seen"] > DAY_SECONDS:
            continue
        if words:
            hay = _haystack(d)
            if not all(w in hay for w in words):
                continue
        out.append(d)
    return out


def iso_time(ts):
    """Epoch seconds -> '2026-10-17T08:12:03+03:00' (local time with UTC offset); '' if unknown."""
    if not ts:
        return ""
    return datetime.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def device_records(devices):
    return [
        {
            "status": "online" if d["online"] else "offline",
            "ip": d["ip"], "hostname": d["hostname"], "mac": d["mac"], "vendor": d["vendor"],
            "first_seen": iso_time(d["first_seen"]), "last_seen": iso_time(d["last_seen"]),
        }
        for d in devices
    ]


def event_records(events):
    return [
        {
            "time": iso_time(e["ts"]), "event": e["kind"], "ip": e["ip"],
            "hostname": e["hostname"], "mac": e["mac"], "detail": e["detail"],
        }
        for e in events
    ]


def csv_safe(value):
    """Keep spreadsheets from running a cell as a formula: hostnames come from untrusted LAN devices."""
    if isinstance(value, str) and value[:1] in ("=", "+", "-", "@", "\t", "\r"):
        return "'" + value
    return value


def write_csv(path, fields, records):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in records:
            w.writerow({k: csv_safe(v) for k, v in r.items()})


def write_json(path, records):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False, indent=2)
        f.write("\n")


def export_filename(kind, ext, when=None):
    when = when or datetime.datetime.now()
    return f"network-playground-{kind}-{when:%Y%m%d-%H%M%S}.{ext}"
# ---- end pure helpers ----


def make_table(headers):
    t = QTableWidget(0, len(headers))
    t.setHorizontalHeaderLabels(headers)
    t.verticalHeader().setVisible(False)
    t.setAlternatingRowColors(True)
    t.setSelectionBehavior(QAbstractItemView.SelectRows)
    t.setSelectionMode(QAbstractItemView.SingleSelection)
    t.setEditTriggers(QAbstractItemView.NoEditTriggers)
    t.setShowGrid(False)
    t.horizontalHeader().setStretchLastSection(True)
    return t


def section(text):
    lbl = QLabel(text)
    lbl.setObjectName("sectionHeader")
    return lbl


def make_app_icon():
    """Window / tray icon, painted in code (same design as the installed SVG)."""
    pm = QPixmap(128, 128)
    pm.fill(QColor(0, 0, 0, 0))
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    p.setPen(QPen(QColor("#26262b"), 3))
    p.setBrush(QColor("#0a0a0b"))
    p.drawRoundedRect(4, 4, 120, 120, 26, 26)
    spokes = [(64, 26), (100, 52), (86, 95), (42, 95), (28, 52)]
    p.setPen(QPen(QColor("#a8121a"), 3))
    for x, y in spokes:
        p.drawLine(64, 64, x, y)
    p.setBrush(QColor("#111113"))
    for x, y in spokes:
        p.drawEllipse(QPointF(x, y), 7, 7)
    p.setPen(Qt.NoPen)
    p.setBrush(QColor("#e0222d"))
    p.drawEllipse(QPointF(64, 64), 12, 12)
    p.end()
    return QIcon(pm)


class ScanThread(QThread):
    """Runs one network scan off the GUI thread. Never touches the database."""

    scanned = Signal(object)
    failed = Signal(str)

    def __init__(self, known):
        super().__init__()
        self.known = known  # [(ip, mac)] read on the GUI thread; the worker never touches the DB

    def run(self):
        try:
            self.scanned.emit(scan_network(self.known))
        except ScanError as e:
            self.failed.emit(str(e))
        except Exception as e:  # keep the GUI alive no matter what
            self.failed.emit(f"Unexpected scan error: {e}")


class SettingsDialog(QDialog):
    """Every control saves immediately; the theme applies live."""

    def __init__(self, parent, settings, notifier, apply_theme, tray_available):
        super().__init__(parent)
        self.settings = settings
        self.notifier = notifier
        self.apply_theme = apply_theme
        self.setWindowTitle("Settings")
        self.setModal(True)
        self.setMinimumWidth(420)
        lay = QVBoxLayout(self)

        # ---- notifications ----
        lay.addWidget(section("NOTIFICATIONS"))
        for key, text in NOTIFY_CHOICES:
            cb = QCheckBox(text)
            cb.setChecked(settings.get(key))
            cb.toggled.connect(lambda on, k=key: self.settings.set(k, on))
            lay.addWidget(cb)
        row = QHBoxLayout()
        test_btn = QPushButton("SEND TEST NOTIFICATION")
        test_btn.clicked.connect(self.notifier.send_test)
        row.addWidget(test_btn)
        row.addStretch()
        lay.addLayout(row)

        # ---- quiet hours ----
        lay.addWidget(section("QUIET HOURS"))
        self.quiet_cb = QCheckBox("Mute notifications during quiet hours")
        self.quiet_cb.setChecked(settings.get("quiet_enabled"))
        lay.addWidget(self.quiet_cb)
        start, end = settings.quiet_range()
        row = QHBoxLayout()
        row.addWidget(QLabel("from"))
        self.start_edit = self._time_edit(start, "quiet_start")
        row.addWidget(self.start_edit)
        row.addWidget(QLabel("to"))
        self.end_edit = self._time_edit(end, "quiet_end")
        row.addWidget(self.end_edit)
        row.addStretch()
        lay.addLayout(row)
        self._set_quiet_enabled(self.quiet_cb.isChecked())
        self.quiet_cb.toggled.connect(self._on_quiet_toggled)

        # ---- theme ----
        lay.addWidget(section("THEME"))
        row = QHBoxLayout()
        for name, text in (("dark", "Dark"), ("light", "Light")):
            rb = QRadioButton(text)
            rb.setChecked(settings.theme == name)
            rb.toggled.connect(lambda on, n=name: self.apply_theme(n) if on else None)
            row.addWidget(rb)
        row.addStretch()
        lay.addLayout(row)

        # ---- general ----
        lay.addWidget(section("GENERAL"))
        self.autostart_cb = QCheckBox("Start on login (minimized to the tray)")
        self.autostart_cb.setChecked(autostart_enabled())
        self.autostart_cb.toggled.connect(self._on_autostart)
        lay.addWidget(self.autostart_cb)
        label = "Quit when the window is closed"
        self.quit_cb = QCheckBox(label)
        self.quit_cb.setChecked(settings.get("quit_on_close"))
        self.quit_cb.toggled.connect(lambda on: self.settings.set("quit_on_close", on))
        if not tray_available:
            self.quit_cb.setText(label + " (always: no system tray found)")
            self.quit_cb.setEnabled(False)
        lay.addWidget(self.quit_cb)

        row = QHBoxLayout()
        row.addStretch()
        close_btn = QPushButton("CLOSE")
        close_btn.clicked.connect(self.accept)
        row.addWidget(close_btn)
        lay.addLayout(row)

    def _time_edit(self, t, key):
        edit = QTimeEdit(QTime(t.hour, t.minute))
        edit.setDisplayFormat("HH:mm")
        edit.timeChanged.connect(lambda qt, k=key: self.settings.set(k, qt.toString("HH:mm")))
        return edit

    def _set_quiet_enabled(self, on):
        self.start_edit.setEnabled(on)
        self.end_edit.setEnabled(on)

    def _on_quiet_toggled(self, on):
        self.settings.set("quiet_enabled", on)
        self._set_quiet_enabled(on)

    def _on_autostart(self, on):
        try:
            set_autostart(on)
        except OSError as e:
            QMessageBox.warning(self, "Start on login", f"Could not change the autostart setting:\n{e}")
            self.autostart_cb.blockSignals(True)
            self.autostart_cb.setChecked(not on)
            self.autostart_cb.blockSignals(False)


class MainWindow(QMainWindow):
    def __init__(self, db: Database, settings: Settings):
        super().__init__()
        self.db = db
        self.settings = settings
        self.theme_name = settings.theme
        self.c = colors(self.theme_name)
        self.selected_id = None
        self.scan_thread = None
        self.gateway_ip = db.get_meta("gateway_ip")
        self.self_mac = db.get_meta("self_mac")
        self.scan_info = ""
        self.last_scan_ts = None
        self.export_dir = db.get_meta("export_dir")
        self.tray = None
        self.has_tray = False
        self._quitting = False
        self._shut_down = False

        self.timer = QTimer(self)
        self.timer.setInterval(SCAN_INTERVAL_MS)
        self.timer.timeout.connect(self.start_scan)

        self.app_icon = make_app_icon()
        self.setWindowIcon(self.app_icon)
        self.notifier = Notifier(settings, icon=app_icon_path(), fallback=self.tray_message)
        self.poll_timer = QTimer(self)  # reaps notify-send processes, falls back to the tray on failure
        self.poll_timer.setInterval(2000)
        self.poll_timer.timeout.connect(self.notifier.poll)
        self.poll_timer.start()

        self.setWindowTitle("Network Playground")
        self.resize(1200, 760)

        root = QWidget()
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)
        outer.setContentsMargins(10, 8, 10, 6)

        # ---- header ----
        header = QHBoxLayout()
        title = QLabel("NETWORK//PLAYGROUND")
        title.setObjectName("title")
        header.addWidget(title)
        header.addStretch()
        self.auto_btn = QPushButton("AUTO 30s: ON")
        self.auto_btn.setCheckable(True)
        self.auto_btn.setChecked(True)
        self.auto_btn.toggled.connect(self.on_auto_toggled)
        header.addWidget(self.auto_btn)
        self.clear_btn = QPushButton("CLEAR OFFLINE")
        self.clear_btn.clicked.connect(self.clear_offline)
        header.addWidget(self.clear_btn)
        self.layout_btn = QPushButton("RESET LAYOUT")
        self.layout_btn.clicked.connect(self.reset_layout)
        header.addWidget(self.layout_btn)
        self.settings_btn = QPushButton("SETTINGS")
        self.settings_btn.clicked.connect(self.open_settings)
        header.addWidget(self.settings_btn)
        self.scan_btn = QPushButton("SCAN NOW")
        self.scan_btn.clicked.connect(self.start_scan)
        header.addWidget(self.scan_btn)
        outer.addLayout(header)

        # ---- top: map | device list | details ----
        top = QSplitter(Qt.Horizontal)

        map_box = QWidget()
        mb = QVBoxLayout(map_box)
        mb.setContentsMargins(0, 0, 0, 0)
        mb.addWidget(section("NETWORK MAP"))
        self.map = NetworkMap()
        self.map.set_theme(self.theme_name)
        self.map.deviceSelected.connect(self.select_device)
        self.map.deviceMoved.connect(self.on_node_moved)
        mb.addWidget(self.map, 1)
        top.addWidget(map_box)

        list_box = QWidget()
        lb = QVBoxLayout(list_box)
        lb.setContentsMargins(0, 0, 0, 0)
        head = QHBoxLayout()
        self.dev_header = section("DEVICES")
        head.addWidget(self.dev_header)
        head.addStretch()
        head.addWidget(self.make_export_button(
            "Save the devices currently shown (respects search and filters) as CSV or JSON",
            self.export_devices))
        lb.addLayout(head)

        self.filter_bar = QWidget()
        self.filter_bar.setObjectName("filterBar")
        fv = QVBoxLayout(self.filter_bar)
        fv.setContentsMargins(0, 0, 0, 0)
        fv.setSpacing(4)
        self.search_edit = QLineEdit()
        self.search_edit.setPlaceholderText("Search IP, name, MAC, vendor...   (Ctrl+F)")
        self.search_edit.setClearButtonEnabled(True)
        self.search_edit.textChanged.connect(self.on_filter_changed)
        fv.addWidget(self.search_edit)
        frow = QHBoxLayout()
        frow.setSpacing(4)
        self.f_online = QPushButton("ONLINE")
        self.f_offline = QPushButton("OFFLINE")
        self.f_new = QPushButton("NEW 24H")
        for btn, tip in ((self.f_online, "Show only online devices"),
                         (self.f_offline, "Show only offline devices"),
                         (self.f_new, "Show only devices first seen in the last 24 hours")):
            btn.setCheckable(True)
            btn.setToolTip(tip)
            frow.addWidget(btn)
        frow.addStretch()
        fv.addLayout(frow)
        self.f_online.toggled.connect(lambda on: self.on_filter_toggled("online", on))
        self.f_offline.toggled.connect(lambda on: self.on_filter_toggled("offline", on))
        self.f_new.toggled.connect(lambda on: self.on_filter_toggled("new", on))
        lb.addWidget(self.filter_bar)
        self._style_filter_bar()
        QShortcut(QKeySequence("Ctrl+F"), self).activated.connect(self.focus_search)
        esc = QShortcut(QKeySequence("Escape"), self.search_edit)
        esc.setContext(Qt.WidgetShortcut)
        esc.activated.connect(self.search_edit.clear)

        self.dev_table = make_table(["STATUS", "IP", "HOSTNAME", "MAC"])
        self.dev_table.itemSelectionChanged.connect(self.on_select)
        hh = self.dev_table.horizontalHeader()
        hh.setSectionResizeMode(0, QHeaderView.ResizeToContents)
        hh.setSectionResizeMode(1, QHeaderView.ResizeToContents)
        lb.addWidget(self.dev_table)
        sc = QShortcut(QKeySequence.Delete, self.dev_table)
        sc.setContext(Qt.WidgetShortcut)
        sc.activated.connect(self.forget_selected)
        top.addWidget(list_box)

        detail_box = QWidget()
        db_l = QVBoxLayout(detail_box)
        db_l.setContentsMargins(0, 0, 0, 0)
        db_l.addWidget(section("DETAILS"))
        frame = QFrame()
        frame.setObjectName("panel")
        fl = QVBoxLayout(frame)
        self.detail_label = QLabel("Select a device.")
        self.detail_label.setTextFormat(Qt.RichText)
        self.detail_label.setWordWrap(True)
        self.detail_label.setAlignment(Qt.AlignTop | Qt.AlignLeft)
        self.detail_label.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.detail_label.setStyleSheet("background: transparent;")
        fl.addWidget(self.detail_label)
        fl.addStretch()
        self.forget_btn = QPushButton("FORGET DEVICE")
        self.forget_btn.setEnabled(False)
        self.forget_btn.clicked.connect(self.forget_selected)
        fl.addWidget(self.forget_btn)
        db_l.addWidget(frame, 1)
        top.addWidget(detail_box)

        top.setStretchFactor(0, 4)
        top.setStretchFactor(1, 3)
        top.setStretchFactor(2, 2)

        # ---- bottom: event log ----
        log_box = QWidget()
        ll = QVBoxLayout(log_box)
        ll.setContentsMargins(0, 0, 0, 0)
        ehead = QHBoxLayout()
        ehead.addWidget(section("EVENT LOG"))
        ehead.addStretch()
        ehead.addWidget(self.make_export_button(
            "Save the whole event history (not just the rows shown here) as CSV or JSON",
            self.export_events))
        ll.addLayout(ehead)
        self.event_table = make_table(["TIME", "EVENT", "IP", "HOSTNAME", "DETAIL"])
        eh = self.event_table.horizontalHeader()
        eh.setSectionResizeMode(0, QHeaderView.ResizeToContents)
        eh.setSectionResizeMode(1, QHeaderView.ResizeToContents)
        eh.setSectionResizeMode(2, QHeaderView.ResizeToContents)
        ll.addWidget(self.event_table)

        vsplit = QSplitter(Qt.Vertical)
        vsplit.addWidget(top)
        vsplit.addWidget(log_box)
        vsplit.setStretchFactor(0, 3)
        vsplit.setStretchFactor(1, 2)
        outer.addWidget(vsplit, 1)

        self.status = QLabel("")
        self.status.setObjectName("statusBar")
        self.status.setWordWrap(True)
        outer.addWidget(self.status)

        self._setup_tray()
        self.refresh()
        self.timer.start()
        QTimer.singleShot(300, self.start_scan)  # first scan right after startup

    # ---- tray ----
    def _setup_tray(self):
        """System tray icon with Open / Scan / Pause / Quit. Without a tray, closing the window quits."""
        self.has_tray = QSystemTrayIcon.isSystemTrayAvailable()
        if not self.has_tray:
            return
        self.tray = QSystemTrayIcon(self.app_icon, self)
        menu = QMenu(self)
        open_act = QAction("Open", menu)
        open_act.triggered.connect(self.show_window)
        scan_act = QAction("Scan now", menu)
        scan_act.triggered.connect(self.start_scan)
        self.pause_act = QAction("Pause monitoring", menu)
        self.pause_act.triggered.connect(self.toggle_pause)
        quit_act = QAction("Quit", menu)
        quit_act.triggered.connect(self.quit_app)
        menu.addAction(open_act)
        menu.addAction(scan_act)
        menu.addAction(self.pause_act)
        menu.addSeparator()
        menu.addAction(quit_act)
        self._tray_menu = menu  # keep a reference
        self.tray.setContextMenu(menu)
        self.tray.setToolTip("Network Playground")
        self.tray.activated.connect(self._on_tray_activated)
        self.tray.show()

    def _on_tray_activated(self, reason):
        if reason in (QSystemTrayIcon.Trigger, QSystemTrayIcon.DoubleClick):
            if self.isVisible() and not self.isMinimized():
                self.hide()
            else:
                self.show_window()

    def show_window(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def tray_message(self, title, body):
        """Balloon via the tray icon (used when notify-send is unavailable or fails)."""
        if self.tray is not None:
            self.tray.showMessage(title, body, QSystemTrayIcon.Information, 8000)

    def toggle_pause(self):
        self.auto_btn.setChecked(not self.auto_btn.isChecked())

    def quit_app(self):
        self._quitting = True
        self.close()
        QApplication.instance().quit()

    def _shutdown(self):
        if self._shut_down:
            return
        self._shut_down = True
        self.timer.stop()
        self.poll_timer.stop()
        if self.scan_thread is not None and self.scan_thread.isRunning():
            self.scan_thread.wait(5000)
        if self.tray is not None:
            self.tray.hide()

    def closeEvent(self, event):
        to_tray = self.has_tray and not self._quitting and not self.settings.get("quit_on_close")
        if to_tray:
            event.ignore()
            self.hide()
            if not self.settings.get("close_hint_shown"):
                self.tray_message("Network Playground",
                                  "Still running in the tray. Right-click the tray icon to quit.")
                self.settings.set("close_hint_shown", True)
            return
        self._shutdown()
        event.accept()
        QApplication.instance().quit()

    # ---- settings / theme ----
    def open_settings(self):
        SettingsDialog(self, self.settings, self.notifier, self.apply_theme, self.has_tray).exec()

    def apply_theme(self, name):
        """Live theme switch: new stylesheet, new map palette, repaint everything."""
        self.settings.set("theme", name)  # stored as meta['theme']
        self.theme_name = name
        self.c = colors(name)
        QApplication.instance().setStyleSheet(stylesheet(name))
        self.map.set_theme(name)
        self._style_filter_bar()
        self.status.setStyleSheet("")
        self.refresh()

    def event_color(self, kind):
        c = self.c
        return {
            "appeared": c["accent_bright"],
            "online": c["online"],
            "offline": c["offline"],
            "ip_changed": c["warn"],
        }.get(kind, c["text"])

    # ---- data -> widgets ----
    def refresh(self):
        devices = self.db.devices()
        self._fill_device_table(devices)

        events = self.db.events(limit=300)
        self.event_table.setRowCount(len(events))
        for r, e in enumerate(events):
            kind = QTableWidgetItem(e["kind"].upper().replace("_", " "))
            kind.setForeground(QColor(self.event_color(e["kind"])))
            self.event_table.setItem(r, 0, QTableWidgetItem(fmt_time(e["ts"])))
            self.event_table.setItem(r, 1, kind)
            self.event_table.setItem(r, 2, QTableWidgetItem(e["ip"] or "-"))
            self.event_table.setItem(r, 3, QTableWidgetItem(e["hostname"] or "-"))
            self.event_table.setItem(r, 4, QTableWidgetItem(e["detail"] or ""))

        self.map.set_data(devices, self.gateway_ip, self.self_mac, self.db.positions(), self.selected_id)

        online_n = sum(1 for d in devices if d["online"])
        auto = f"auto-scan {SCAN_INTERVAL_MS // 1000}s" if self.timer.isActive() else "auto-scan paused"
        info = f"  |  {self.scan_info}" if self.scan_info else ""
        self.status.setText(
            f"{len(devices)} devices  |  {online_n} online  |  updated {fmt_time(time.time())}  |  {auto}{info}"
        )
        if self.tray is not None:
            paused = "" if self.timer.isActive() else " (paused)"
            last = fmt_time(self.last_scan_ts) if self.last_scan_ts else "no scan yet"
            self.tray.setToolTip(
                f"Network Playground{paused}\n{online_n} of {len(devices)} devices online\nlast scan: {last}"
            )
        self.show_details()

    # ---- search / filters ----
    def _style_filter_bar(self):
        c = self.c
        self.filter_bar.setStyleSheet(f"""
            QLineEdit {{
                background-color: {c['panel']}; border: 1px solid {c['border']}; padding: 4px 8px;
                selection-background-color: {c['accent']}; selection-color: #ffffff;
            }}
            QLineEdit:focus {{ border-color: {c['accent']}; }}
            QPushButton:checked {{
                background-color: {c['accent']}; color: #ffffff; border-color: {c['accent_bright']};
            }}
        """)

    def status_filter(self):
        if self.f_online.isChecked():
            return "online"
        if self.f_offline.isChecked():
            return "offline"
        return None

    def filters_active(self):
        return bool(self.search_edit.text().strip() or self.status_filter() or self.f_new.isChecked())

    def visible_devices(self, devices):
        """Devices that pass the search box and filter buttons (exactly what the list shows)."""
        return filter_devices(devices, self.search_edit.text(), self.status_filter(), self.f_new.isChecked())

    def _fill_device_table(self, devices):
        c = self.c
        shown = self.visible_devices(devices)
        self.dev_table.blockSignals(True)
        self.dev_table.setRowCount(len(shown))
        select_row = None
        for r, d in enumerate(shown):
            online = bool(d["online"])
            st = QTableWidgetItem("● ONLINE" if online else "○ OFFLINE")
            st.setForeground(QColor(c["online"] if online else c["offline"]))
            st.setData(Qt.UserRole, d["id"])
            self.dev_table.setItem(r, 0, st)
            self.dev_table.setItem(r, 1, QTableWidgetItem(d["ip"] or "-"))
            self.dev_table.setItem(r, 2, QTableWidgetItem(d["hostname"] or "-"))
            self.dev_table.setItem(r, 3, QTableWidgetItem(d["mac"] or "-"))
            if d["id"] == self.selected_id:
                select_row = r
        if select_row is not None:
            self.dev_table.selectRow(select_row)
        else:
            self.dev_table.clearSelection()  # selected device is filtered out: don't highlight a stranger
        self.dev_table.blockSignals(False)
        self.dev_header.setText(
            f"DEVICES ({len(shown)} of {len(devices)})" if self.filters_active() else "DEVICES"
        )
        return shown

    def on_filter_changed(self, _text=None):
        self._fill_device_table(self.db.devices())

    def on_filter_toggled(self, which, on):
        if on and which in ("online", "offline"):  # these two exclude each other
            other = self.f_offline if which == "online" else self.f_online
            if other.isChecked():
                other.blockSignals(True)
                other.setChecked(False)
                other.blockSignals(False)
        self._fill_device_table(self.db.devices())

    def focus_search(self):
        self.search_edit.setFocus()
        self.search_edit.selectAll()

    # ---- export ----
    def make_export_button(self, tooltip, handler):
        btn = QPushButton("EXPORT")
        btn.setToolTip(tooltip)
        menu = QMenu(btn)
        for fmt, label in (("csv", "CSV  (.csv)"), ("json", "JSON  (.json)")):
            act = menu.addAction(label)
            act.triggered.connect(lambda _checked=False, f=fmt: handler(f))
        btn.setMenu(menu)
        return btn

    def export_devices(self, fmt):
        devices = self.db.devices()
        shown = self.visible_devices(devices)
        if not shown:
            self.status.setStyleSheet("")
            self.status.setText("No devices match the current search/filters - nothing to export.")
            return
        note = f" (filtered: {len(shown)} of {len(devices)})" if len(shown) != len(devices) else ""
        self._export("devices", fmt, DEVICE_FIELDS, device_records(shown), note)

    def export_events(self, fmt):
        events = self.db.events(limit=EXPORT_EVENT_LIMIT)
        if not events:
            self.status.setStyleSheet("")
            self.status.setText("The event log is empty - nothing to export.")
            return
        self._export("events", fmt, EVENT_FIELDS, event_records(events), "")

    def _export(self, kind, fmt, fields, records, note):
        if self.export_dir and Path(self.export_dir).is_dir():
            start = self.export_dir
        else:
            start = QStandardPaths.writableLocation(QStandardPaths.DocumentsLocation) or str(Path.home())
        kind_filter = "CSV files (*.csv)" if fmt == "csv" else "JSON files (*.json)"
        path, _ = QFileDialog.getSaveFileName(
            self, f"Export {kind} as {fmt.upper()}",
            str(Path(start) / export_filename(kind, fmt)), f"{kind_filter};;All files (*)",
        )
        if not path:
            return  # cancelled
        if not Path(path).suffix:
            path += "." + fmt
        try:
            if fmt == "csv":
                write_csv(path, fields, records)
            else:
                write_json(path, records)
        except OSError as e:
            QMessageBox.warning(self, "Export failed", f"Could not write the file:\n{e}")
            return
        self.export_dir = str(Path(path).parent)
        self.db.set_meta("export_dir", self.export_dir)
        self.status.setStyleSheet("")
        self.status.setText(f"Exported {len(records)} {kind}{note} to {path}")

    def on_select(self):
        items = self.dev_table.selectedItems()
        self.selected_id = items[0].data(Qt.UserRole) if items else None
        self.map.set_selected(self.selected_id)
        self.show_details()

    def show_details(self):
        d = self.db.device(self.selected_id) if self.selected_id else None
        if not d:
            self.detail_label.setText("Select a device.")
            self.forget_btn.setEnabled(False)
            return
        self.forget_btn.setEnabled(True)
        online = bool(d["online"])
        color = self.c["online"] if online else self.c["offline"]
        dim = self.c["text_dim"]
        rows = [
            ("STATUS", f"<span style='color:{color}'>{'ONLINE' if online else 'OFFLINE'}</span>"),
            ("IP", d["ip"] or "-"),
            ("HOSTNAME", d["hostname"] or "-"),
            ("MAC", d["mac"] or "-"),
            ("VENDOR", d["vendor"] or "-"),
            ("FIRST SEEN", fmt_datetime(d["first_seen"])),
            ("LAST SEEN", fmt_datetime(d["last_seen"])),
        ]
        if d["ip"] and d["ip"] == self.gateway_ip:
            rows.insert(1, ("ROLE", "GATEWAY"))
        elif d["mac"] and d["mac"] == self.self_mac:
            rows.insert(1, ("ROLE", "THIS PC"))
        if is_random_mac(d["mac"]):
            rows.append(("NOTE", "randomized MAC (private Wi-Fi address)"))
        html = "<table cellspacing='6'>" + "".join(
            f"<tr><td style='color:{dim}'>{k}</td><td>{v}</td></tr>" for k, v in rows
        ) + "</table>"
        self.detail_label.setText(html)

    # ---- scanning ----
    def start_scan(self):
        if self.scan_thread is not None and self.scan_thread.isRunning():
            return
        self.scan_btn.setEnabled(False)
        self.scan_btn.setText("SCANNING...")
        self.status.setStyleSheet("")
        self.status.setText("Scanning network...")
        known = [(d["ip"], d["mac"]) for d in self.db.devices() if d["ip"] and d["mac"]]
        self.scan_thread = ScanThread(known)
        self.scan_thread.scanned.connect(self.on_scanned)
        self.scan_thread.failed.connect(self.on_scan_failed)
        self.scan_thread.finished.connect(self.on_scan_finished)
        self.scan_thread.start()

    def on_scanned(self, result):
        hosts = result.hosts
        first_scan = not self.notifier.primed  # first successful scan of this run: no notifications
        previous = {d["key"]: d for d in self.db.devices()}
        events = []
        seen = set()

        for h in hosts:
            seen.add(h.mac)
            prev = previous.get(h.mac)
            old_ip = prev["ip"] if prev else ""
            name = h.hostname or (prev["hostname"] if prev else "") or ""
            for kind in self.db.observe(h.ip, h.mac, h.hostname, online=True, vendor=h.vendor):
                events.append(DeviceEvent(kind, h.ip, name, old_ip if kind == "ip_changed" else "", h.vendor or ""))

        me = result.self_host
        if me is not None:  # this PC is tracked but never announced
            seen.add(me.mac)
            self.db.observe(me.ip, me.mac, me.hostname, online=True)
            self.self_mac = me.mac
            self.db.set_meta("self_mac", me.mac)
        if result.gateway_ip:
            self.gateway_ip = result.gateway_ip
            self.db.set_meta("gateway_ip", result.gateway_ip)
        self.scan_info = f"{result.network or '?'} via {result.interface or '?'}"

        if hosts:
            # Known-online devices that were not seen count as a miss; after MISS_THRESHOLD
            # misses in a row they go offline. On the first scan of a run the stored state
            # is stale (the app wasn't watching), so unseen devices go offline immediately -
            # silently, because that scan sends no notifications.
            # (An empty result is treated as a failed scan, not "everyone left".)
            kwargs = {"threshold": 1} if first_scan else {}
            for d in self.db.devices():
                if d["online"] and (d["mac"] or d["key"]) not in seen:
                    for kind in self.db.record_miss(d["id"], **kwargs):
                        events.append(DeviceEvent(kind, d["ip"] or "", d["hostname"] or ""))

        self.last_scan_ts = time.time()
        self.refresh()
        if hosts:
            self.notifier.process(events)
        else:
            self.status.setText("Scan found no other devices on " + self.scan_info)

    def on_scan_failed(self, message):
        self.status.setStyleSheet(f"color: {self.c['accent_bright']};")
        self.status.setText("SCAN FAILED: " + message)

    def on_scan_finished(self):
        self.scan_btn.setEnabled(True)
        self.scan_btn.setText("SCAN NOW")

    # ---- monitoring controls / cleanup ----
    def on_auto_toggled(self, on):
        self.auto_btn.setText("AUTO 30s: ON" if on else "AUTO 30s: OFF")
        if on:
            self.timer.start()
        else:
            self.timer.stop()
        if self.tray is not None:
            self.pause_act.setText("Pause monitoring" if on else "Resume monitoring")
        self.refresh()

    def forget_selected(self):
        d = self.db.device(self.selected_id) if self.selected_id else None
        if not d:
            return
        label = d["hostname"] or d["ip"] or d["mac"]
        answer = QMessageBox.question(
            self, "Forget device",
            f"Forget {label} and its event history?\n(If it is still on the network it will reappear on the next scan.)",
        )
        if answer != QMessageBox.Yes:
            return
        self.db.forget_device(d["id"])
        self.selected_id = None
        self.refresh()

    def select_device(self, dev_id):
        """A node was clicked on the map: select the matching table row."""
        for r in range(self.dev_table.rowCount()):
            if self.dev_table.item(r, 0).data(Qt.UserRole) == dev_id:
                self.dev_table.selectRow(r)
                return
        # Not in the (filtered) list: still show it on the map and in the details panel.
        self.dev_table.blockSignals(True)
        self.dev_table.clearSelection()
        self.dev_table.blockSignals(False)
        self.selected_id = dev_id
        self.map.set_selected(dev_id)
        self.show_details()

    def on_node_moved(self, dev_id, x, y):
        self.db.set_meta(f"pos:{dev_id}", f"{x:.1f},{y:.1f}")

    def reset_layout(self):
        self.db.clear_positions()
        self.refresh()

    def clear_offline(self):
        n = self.db.conn.execute("SELECT COUNT(*) FROM devices WHERE online=0").fetchone()[0]
        if n == 0:
            self.status.setText("No offline devices to clear.")
            return
        answer = QMessageBox.question(
            self, "Clear offline",
            f"Delete {n} offline device(s) and their event history?",
        )
        if answer != QMessageBox.Yes:
            return
        self.db.forget_offline()
        self.selected_id = None
        self.refresh()
