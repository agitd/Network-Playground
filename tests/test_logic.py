"""Logic tests that need no display or Qt:   python3 tests/test_logic.py"""

import csv
import datetime as dt
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from npg import theme  # noqa: E402
from npg.db import Database  # noqa: E402
from npg.notify import DeviceEvent, Notifier, in_quiet_hours  # noqa: E402
from npg.settings import (  # noqa: E402
    DEFAULTS, Settings, app_icon_path, autostart_enabled, autostart_path, parse_hhmm, set_autostart,
)

_results = []


def test(fn):
    try:
        fn()
        _results.append((fn.__name__, None))
    except Exception as e:  # noqa: BLE001
        _results.append((fn.__name__, e))
    return fn


def T(h, m=0):
    return dt.time(h, m)


# ======================= theme =======================
@test
def theme_palettes_have_same_keys_and_valid_colours():
    assert set(theme.DARK) == set(theme.LIGHT)
    for pal in (theme.DARK, theme.LIGHT):
        for k, v in pal.items():
            assert re.fullmatch(r"#[0-9a-f]{6}", v), (k, v)


@test
def theme_light_palette_matches_spec():
    L = theme.colors("light")
    assert (L["bg"], L["text"], L["accent"], L["online"]) == ("#f6f6f7", "#1a1a1c", "#a8121a", "#2f7d4f")


@test
def theme_colors_fallback_and_names():
    assert theme.colors("dark") is theme.DARK and theme.colors("light") is theme.LIGHT
    assert theme.colors("bogus") is theme.DARK and theme.colors(None) is theme.DARK
    assert theme.THEME_NAMES == ("dark", "light")


@test
def theme_stylesheet_is_fully_resolved_and_differs():
    for name in theme.THEME_NAMES:
        css, c = theme.stylesheet(name), theme.colors(name)
        assert c["bg"] in css and c["accent"] in css and c["text"] in css
        assert not re.search(r"\{[a-z_\"\[\]]+\}", css), "unresolved placeholder"
        assert css.count("{") == css.count("}")
        for widget in ("QCheckBox", "QRadioButton", "QTimeEdit", "QMenu", "QGraphicsView"):
            assert widget in css, widget
    assert theme.stylesheet("dark") != theme.stylesheet("light")


# ======================= settings =======================
def fresh():
    db = Database(":memory:")
    return db, Settings(db)


@test
def settings_defaults_match_spec():
    _, s = fresh()
    assert [s.get(k) for k in ("notify_appeared", "notify_offline", "notify_online", "notify_ip_changed")] \
        == [True, True, False, False]
    assert s.get("quiet_enabled") is True and s.quiet_range() == (T(23), T(8))
    assert s.get("quit_on_close") is False and s.theme == "dark"


@test
def settings_roundtrip_and_meta_theme():
    db, s = fresh()
    s.set("notify_online", True)
    s.set("quit_on_close", True)
    s.set("quiet_start", "22:30")
    s.set("theme", "light")
    assert s.get("notify_online") is True and s.get("quit_on_close") is True
    assert s.quiet_range()[0] == T(22, 30)
    assert db.get_meta("theme") == "light"          # persisted as meta['theme']
    assert Settings(db).theme == "light"            # a new Settings object (= next launch) sees it
    s.set("notify_online", False)
    assert s.get("notify_online") is False


@test
def settings_bad_values_and_keys():
    db, s = fresh()
    db.set_meta("theme", "purple")
    assert s.theme == "dark"
    s.set("quiet_start", "25:99")
    s.set("quiet_end", "abc")
    assert s.quiet_range() == (T(23), T(8))
    for fn in (lambda: s.get("nope"), lambda: s.set("nope", 1)):
        try:
            fn()
            raise AssertionError("expected KeyError")
        except KeyError:
            pass
    assert parse_hhmm("07:05", None) == T(7, 5) and parse_hhmm(None, "fb") == "fb"


# ======================= autostart =======================
@test
def autostart_write_and_remove_in_temp_home():
    saved = os.environ.pop("XDG_CONFIG_HOME", None)
    try:
        with tempfile.TemporaryDirectory() as home:
            exec_line = '"/x/venv/bin/python" "/x/app/main.py" --hidden'
            assert not autostart_enabled(home)
            path = set_autostart(True, home=home, exec_line=exec_line)
            assert path == Path(home) / ".config/autostart/network-playground.desktop" == autostart_path(home)
            text = path.read_text()
            assert text.startswith("[Desktop Entry]\nType=Application")
            assert f"Exec={exec_line}\n" in text and "Terminal=false" in text
            assert "X-GNOME-Autostart-enabled=true" in text and "Icon=network-wired" in text
            assert os.access(path, os.X_OK) and autostart_enabled(home)
            assert set_autostart(False, home=home) is None and not path.exists()
            assert set_autostart(False, home=home) is None           # removing twice is fine
    finally:
        if saved is not None:
            os.environ["XDG_CONFIG_HOME"] = saved


@test
def autostart_default_exec_and_installed_icon():
    with tempfile.TemporaryDirectory() as home:
        icon = Path(home) / ".local/share/icons/hicolor/scalable/apps/network-playground.svg"
        assert app_icon_path(home) is None
        icon.parent.mkdir(parents=True)
        icon.write_text("<svg/>")
        assert app_icon_path(home) == str(icon)
        text = set_autostart(True, home=home).read_text()
        assert f"Icon={icon}" in text
        exec_line = re.search(r"^Exec=(.*)$", text, re.M).group(1)
        assert sys.executable in exec_line and exec_line.endswith("main.py\" --hidden")


@test
def autostart_respects_xdg_config_home():
    saved = os.environ.get("XDG_CONFIG_HOME")
    try:
        with tempfile.TemporaryDirectory() as d:
            os.environ["XDG_CONFIG_HOME"] = d
            assert autostart_path() == Path(d) / "autostart/network-playground.desktop"
    finally:
        os.environ.pop("XDG_CONFIG_HOME", None)
        if saved is not None:
            os.environ["XDG_CONFIG_HOME"] = saved


# ======================= notify =======================
@test
def quiet_hours_function():
    assert [in_quiet_hours(t, T(23), T(8)) for t in (T(23), T(23, 59), T(0), T(7, 59), T(8), T(12), T(22, 59))] \
        == [True, True, True, True, False, False, False]
    assert [in_quiet_hours(t, T(13), T(14)) for t in (T(12, 59), T(13), T(13, 30), T(14))] \
        == [False, True, True, False]
    assert in_quiet_hours(T(3), T(5), T(5)) is False


class FakeProc:
    def __init__(self, code=None):
        self.code = code

    def poll(self):
        return self.code


class Rig:
    """A Notifier with a fake clock, fake notify-send and recorded tray fallback."""

    def __init__(self, hour=12, minute=0, has_ns=True, popen_raises=False, icon=None):
        self.db, self.settings = fresh()
        self.now = dt.datetime(2026, 10, 17, hour, minute)
        self.popen_calls, self.fallback_calls, self.procs = [], [], []
        self.popen_raises = popen_raises

        def popen(cmd, **kw):
            if self.popen_raises:
                raise OSError("boom")
            self.popen_calls.append((cmd, kw))
            p = FakeProc()
            self.procs.append(p)
            return p

        self.n = Notifier(
            self.settings, clock=lambda: self.now,
            which=(lambda name: "/usr/bin/notify-send") if has_ns else (lambda name: None),
            popen=popen, icon=icon, fallback=lambda t, b: self.fallback_calls.append((t, b)),
        )

    def prime(self):
        assert self.n.process([DeviceEvent("appeared", "10.0.0.1")]) == []


APPEARED = DeviceEvent("appeared", "192.168.0.42", "phone")
OFFLINE = DeviceEvent("offline", "192.168.0.31", "laptop")
ONLINE = DeviceEvent("online", "192.168.0.31", "laptop")
IPCHG = DeviceEvent("ip_changed", "192.168.0.99", "nas", old_ip="192.168.0.20")


@test
def notify_first_scan_is_silent_second_is_not():
    r = Rig()
    assert not r.n.primed
    assert r.n.process([APPEARED, OFFLINE]) == [] and r.popen_calls == [] and r.n.primed
    msgs = r.n.process([APPEARED])
    assert msgs == [("New device on your network", "phone (192.168.0.42)")]
    cmd, kw = r.popen_calls[0]
    assert cmd[0] == "/usr/bin/notify-send" and "--app-name=Network Playground" in cmd
    assert cmd[-2:] == list(msgs[0])
    assert kw["stdout"] is not None and kw["stderr"] is not None  # detached, output discarded


@test
def notify_default_kinds_only_appeared_and_offline():
    r = Rig()
    r.prime()
    msgs = r.n.process([APPEARED, OFFLINE, ONLINE, IPCHG])
    assert [m[0] for m in msgs] == ["New device on your network", "Device went offline"]


@test
def notify_settings_apply_live_without_restart():
    r = Rig()
    r.prime()
    r.settings.set("notify_online", True)
    r.settings.set("notify_ip_changed", True)
    r.settings.set("notify_appeared", False)
    msgs = r.n.process([APPEARED, ONLINE, IPCHG])
    assert [m[0] for m in msgs] == ["Device back online", "Device changed IP"]
    assert msgs[1][1] == "nas: 192.168.0.20 \u2192 192.168.0.99"


@test
def notify_quiet_hours_default_23_to_08():
    for hour, minute, expect_sent in [(23, 0, False), (23, 30, False), (0, 15, False), (7, 59, False),
                                      (8, 0, True), (12, 0, True), (22, 59, True)]:
        r = Rig(hour, minute)
        r.prime()
        assert bool(r.n.process([APPEARED])) is expect_sent, (hour, minute)


@test
def notify_quiet_hours_configurable_and_can_be_disabled():
    r = Rig(12, 30)
    r.prime()
    r.settings.set("quiet_start", "12:00")
    r.settings.set("quiet_end", "13:00")
    assert r.n.process([APPEARED]) == []                      # inside the custom window
    r.now = dt.datetime(2026, 10, 17, 14, 0)
    assert len(r.n.process([APPEARED])) == 1                  # outside it
    r.now = dt.datetime(2026, 10, 17, 12, 30)
    r.settings.set("quiet_enabled", False)
    assert len(r.n.process([APPEARED])) == 1                  # toggle off
    assert len(r.popen_calls) == 2


@test
def notify_quiet_events_are_dropped_not_queued():
    r = Rig(23, 30)
    r.prime()
    assert r.n.process([APPEARED]) == []
    r.now = dt.datetime(2026, 10, 18, 9, 0)
    assert r.n.process([]) == [] and r.popen_calls == []


@test
def notify_grouping_over_three_events():
    r = Rig()
    r.prime()
    five = [DeviceEvent("offline", f"10.0.0.{i}", f"h{i}") for i in range(5)]
    msgs = r.n.process(five)
    assert msgs == [("5 devices went offline", "h0, h1, h2 and 2 more")]
    assert len(r.popen_calls) == 1
    three = [DeviceEvent("offline", f"10.0.0.{i}", f"h{i}") for i in range(3)]
    assert len(r.n.process(three)) == 3


@test
def notify_markup_is_escaped_and_icon_passed():
    r = Rig(icon="/tmp/i.svg")
    r.prime()
    r.n.process([DeviceEvent("appeared", "10.0.0.5", "A&B<x>")])
    cmd = r.popen_calls[0][0]
    assert "--icon=/tmp/i.svg" in cmd and "A&amp;B&lt;x&gt; (10.0.0.5)" == cmd[-1]


@test
def notify_unknown_event_kind_is_ignored():
    r = Rig()
    r.prime()
    assert r.n.process([DeviceEvent("bogus", "1.1.1.1")]) == []


@test
def notify_falls_back_to_tray_when_notify_send_missing_or_unstartable():
    for kwargs in ({"has_ns": False}, {"popen_raises": True}):
        r = Rig(**kwargs)
        r.prime()
        msgs = r.n.process([APPEARED])
        assert r.fallback_calls == msgs and r.popen_calls == []


@test
def notify_falls_back_when_notify_send_exits_with_error():
    r = Rig()
    r.prime()
    r.n.process([APPEARED, OFFLINE])
    assert len(r.n._procs) == 2 and r.fallback_calls == []
    r.n.poll()
    assert len(r.n._procs) == 2                               # still running: nothing happens
    r.procs[0].code = 0                                       # delivered fine
    r.procs[1].code = 1                                       # no notification daemon
    r.n.poll()
    assert r.n._procs == [] and r.fallback_calls == [("Device went offline", "laptop (192.168.0.31)")]


@test
def notify_never_raises_without_or_with_broken_fallback():
    r = Rig(has_ns=False)
    r.n.fallback = None
    r.prime()
    assert len(r.n.process([APPEARED])) == 1                  # nowhere to show it, still no crash
    r.n.fallback = lambda t, b: 1 / 0
    assert len(r.n.process([APPEARED])) == 1


@test
def notify_test_button_ignores_quiet_hours_and_priming():
    r = Rig(23, 30)
    assert not r.n.primed
    assert len(r.n.send_test()) == 1 and len(r.popen_calls) == 1
    assert not r.n.primed                                      # a test must not consume the first-scan rule


@test
def db_threshold_one_marks_stale_device_offline_immediately():
    db = Database(":memory:")
    db.observe("10.0.0.2", "aa:aa:aa:aa:aa:01", "a")
    did = db.devices()[0]["id"]
    assert db.record_miss(did, threshold=1) == ["offline"] and not db.device(did)["online"]
    db.observe("10.0.0.3", "aa:aa:aa:aa:aa:02", "b")
    did2 = db.devices()[0]["id"]
    assert db.record_miss(did2) == []                          # normal path still needs 2 misses


# ======================= stage 6: search, filters, export (pure helpers from ui.py) =======================
def load_ui_helpers():
    """ui.py needs Qt to import, so run just its Qt-free helper block."""
    src = (Path(__file__).resolve().parent.parent / "npg" / "ui.py").read_text()
    a, b = src.index("# ---- pure helpers"), src.index("# ---- end pure helpers ----")
    ns = {"time": time, "datetime": dt, "csv": csv, "json": json}
    exec(src[a:b], ns)
    return ns


H = load_ui_helpers()


def make_devices():
    db = Database(":memory:")
    now = time.time()
    db.observe("192.168.0.1", "c0:b3:c8:a3:8f:e4", "_gateway", vendor="TP-Link")
    db.observe("192.168.0.42", "aa:bb:cc:00:00:42", "Phone", vendor="Apple, Inc.")
    db.observe("192.168.0.31", "aa:bb:cc:00:00:31", "laptop", vendor="Dell")
    db.observe("192.168.0.55", "aa:bb:cc:00:00:55", None)
    ages = {"c0:b3:c8:a3:8f:e4": 10 * 86400, "aa:bb:cc:00:00:42": 2 * 3600,
            "aa:bb:cc:00:00:31": 3 * 86400, "aa:bb:cc:00:00:55": 23 * 3600}
    for mac, age in ages.items():
        db.conn.execute("UPDATE devices SET first_seen=? WHERE mac=?", (now - age, mac))
    for mac in ("aa:bb:cc:00:00:31", "aa:bb:cc:00:00:55"):   # laptop and the unnamed one go offline
        db.record_miss(db.conn.execute("SELECT id FROM devices WHERE mac=?", (mac,)).fetchone()["id"], threshold=1)
    db.conn.commit()
    return db, now


def names(rows):
    return sorted((r["hostname"] or r["ip"]) for r in rows)


@test
def search_matches_ip_name_mac_vendor_case_insensitively():
    db, now = make_devices()
    rows = db.devices()
    f = lambda q, **kw: names(H["filter_devices"](rows, q, now=now, **kw))  # noqa: E731
    assert len(f("")) == 4 and len(f("   ")) == 4
    assert f("192.168.0.4") == ["Phone"]
    assert f("PHONE") == ["Phone"] and f("pHoNe") == ["Phone"]
    assert f("aabbcc000031") == ["laptop"]                    # MAC without colons
    assert f("AA:BB:CC") == ["192.168.0.55", "Phone", "laptop"]
    assert f("tp-link") == ["_gateway"] and f("apple") == ["Phone"] and f("apple, inc") == ["Phone"]
    assert f("zzz") == []


@test
def search_words_are_anded():
    db, now = make_devices()
    rows = db.devices()
    assert names(H["filter_devices"](rows, "apple phone", now=now)) == ["Phone"]
    assert names(H["filter_devices"](rows, "apple laptop", now=now)) == []
    assert names(H["filter_devices"](rows, "  192.168   dell ", now=now)) == ["laptop"]


@test
def status_and_new_filters_and_combinations():
    db, now = make_devices()
    rows = db.devices()
    F = lambda **kw: names(H["filter_devices"](rows, now=now, **kw))  # noqa: E731
    assert F(status="online") == ["Phone", "_gateway"]
    assert F(status="offline") == ["192.168.0.55", "laptop"]
    assert F(new_only=True) == ["192.168.0.55", "Phone"]       # first seen < 24h ago
    assert F(status="online", new_only=True) == ["Phone"]
    assert F(status="offline", new_only=True) == ["192.168.0.55"]
    assert F(status="online", query="tp-link") == ["_gateway"]
    assert F(status="offline", query="phone") == []


@test
def new_24h_boundary_is_inclusive_and_clock_skew_safe():
    db, now = make_devices()
    for age, expected in ((86400, True), (86401, False), (0, True), (-500, True)):  # -500: first_seen in the future
        db.conn.execute("UPDATE devices SET first_seen=? WHERE mac='aa:bb:cc:00:00:42'", (now - age,))
        rows = [r for r in db.devices() if r["mac"] == "aa:bb:cc:00:00:42"]
        assert bool(H["filter_devices"](rows, new_only=True, now=now)) is expected, age


@test
def iso_time_format():
    assert H["iso_time"](None) == "" and H["iso_time"](0) == ""
    ts = 1_800_000_000
    s = H["iso_time"](ts)
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d", s), s
    assert int(dt.datetime.fromisoformat(s).timestamp()) == ts


@test
def records_use_the_existing_db_queries():
    db, now = make_devices()
    db.observe("192.168.0.77", "aa:bb:cc:00:00:42", "Phone")      # same MAC, new IP -> ip_changed event
    recs = H["device_records"](db.devices())
    assert len(recs) == 4 and all(tuple(r) == H["DEVICE_FIELDS"] for r in recs)
    phone = next(r for r in recs if r["hostname"] == "Phone")
    assert phone["status"] == "online" and phone["ip"] == "192.168.0.77" and phone["vendor"] == "Apple, Inc."
    assert re.match(r"\d{4}-\d\d-\d\dT", phone["first_seen"])
    assert next(r for r in recs if r["mac"] == "aa:bb:cc:00:00:55")["hostname"] is None   # None stays None
    assert next(r for r in recs if r["hostname"] == "laptop")["status"] == "offline"
    ev = H["event_records"](db.events())
    assert all(tuple(r) == H["EVENT_FIELDS"] for r in ev)
    chg = next(r for r in ev if r["event"] == "ip_changed")
    assert chg["detail"] == "192.168.0.42 -> 192.168.0.77" and chg["mac"] == "aa:bb:cc:00:00:42"


@test
def csv_safe_neutralises_formula_prefixes_only():
    cs = H["csv_safe"]
    assert [cs(v) for v in ("=1+1", "+cmd", "-cmd", "@SUM(A1)", "\tx", "\rx")] == \
        ["'=1+1", "'+cmd", "'-cmd", "'@SUM(A1)", "'\tx", "'\rx"]
    assert [cs(v) for v in ("laptop", "192.168.0.1", "a=b", "", None, 5)] == ["laptop", "192.168.0.1", "a=b", "", None, 5]


@test
def csv_export_roundtrip_with_nasty_values():
    recs = H["device_records"](make_devices()[0].devices())
    recs[0]["hostname"] = '=HYPERLINK("http://evil","click")'
    recs[1]["hostname"] = 'He said "hi", ok\nbye'
    recs[2]["hostname"] = "Телефон \U0001F4F1"
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "out.csv"
        H["write_csv"](p, H["DEVICE_FIELDS"], recs)
        with open(p, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
    assert list(rows[0]) == list(H["DEVICE_FIELDS"]) and len(rows) == 4
    assert rows[0]["hostname"].startswith("'=")               # defused
    assert rows[1]["hostname"] == 'He said "hi", ok\nbye'      # quotes, comma, newline survive
    assert rows[2]["hostname"] == "Телефон \U0001F4F1"
    assert any(r["hostname"] == "" for r in rows)              # None -> empty cell


@test
def json_export_roundtrip_keeps_nulls_and_unicode():
    recs = H["device_records"](make_devices()[0].devices())
    recs[0]["hostname"] = "Телефон"
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "out.json"
        H["write_json"](p, recs)
        raw = p.read_text(encoding="utf-8")
    assert json.loads(raw) == recs and "Телефон" in raw and raw.endswith("]\n")
    assert any(r["hostname"] is None for r in json.loads(raw))   # null, not "None"


@test
def event_export_covers_the_whole_log_not_just_200_rows():
    db = Database(":memory:")
    db.observe("10.0.0.2", "aa:aa:aa:aa:aa:01", "a")
    did = db.devices()[0]["id"]
    for _ in range(300):
        db._event(did, "online", "10.0.0.2")
    db.conn.commit()
    assert len(db.events()) == 200                               # the default limit
    full = db.events(limit=H["EXPORT_EVENT_LIMIT"])
    assert len(full) == 301 and len(H["event_records"](full)) == 301


@test
def export_filename_pattern():
    assert H["export_filename"]("events", "json", dt.datetime(2026, 10, 17, 8, 5, 9)) \
        == "network-playground-events-20261017-080509.json"
    assert re.fullmatch(r"network-playground-devices-\d{8}-\d{6}\.csv", H["export_filename"]("devices", "csv"))


@test
def helper_block_has_no_qt():
    src = (Path(__file__).resolve().parent.parent / "npg" / "ui.py").read_text()
    block = src[src.index("# ---- pure helpers"):src.index("# ---- end pure helpers ----")]
    assert not re.findall(r"\bQ[A-Z]\w+", block) and "PySide" not in block



if __name__ == "__main__":
    failed = 0
    for name, err in _results:
        print(("PASS " if err is None else "FAIL ") + name + ("" if err is None else f"  -> {type(err).__name__}: {err}"))
        failed += err is not None
    print(f"\n{len(_results) - failed}/{len(_results)} passed")
    sys.exit(1 if failed else 0)
