"""SQLite storage: devices and event history.

The key logic lives in `observe()`: feed it what a scan saw about one device
and it updates the device row and records appear / online / offline /
ip_changed events. Later stages (scanner, monitor) just call `observe()`.
"""

import sqlite3
import time
from pathlib import Path

DB_DIR = Path.home() / ".local" / "share" / "network-playground"
DB_PATH = DB_DIR / "netplay.db"

MISS_THRESHOLD = 2  # consecutive missed scans before a device is marked offline

MAX_NAME_LEN = 64
MAX_TAG_LEN = 32
MAX_TAGS = 20


def normalize_name(text):
    """Trim, squeeze whitespace and control characters, cap the length. '' means 'no custom name'."""
    if not text:
        return ""
    printable = "".join(ch if ch.isprintable() else " " for ch in str(text))
    return " ".join(printable.split())[:MAX_NAME_LEN].strip()


def tag_list(stored):
    """Stored tags ('tv,living room') -> ['tv', 'living room']."""
    return [t for t in (stored or "").split(",") if t]


def format_tags(stored):
    """Stored tags -> the form shown to people: 'tv, living room'."""
    return ", ".join(tag_list(stored))


def normalize_tags(text):
    """'tv, Living  Room,,TV' -> 'tv,Living Room': comma-separated, trimmed, de-duplicated ignoring case."""
    seen, out = set(), []
    for raw in str(text or "").split(","):
        tag = normalize_name(raw)[:MAX_TAG_LEN].strip()
        if tag and tag.casefold() not in seen:
            seen.add(tag.casefold())
            out.append(tag)
        if len(out) >= MAX_TAGS:
            break
    return ",".join(out)


SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    key        TEXT NOT NULL UNIQUE,   -- MAC when known, otherwise IP
    mac        TEXT,
    ip         TEXT,
    hostname   TEXT,
    vendor     TEXT,
    name       TEXT,                    -- custom name chosen by the user
    tags       TEXT,                    -- custom tags, comma-separated
    online     INTEGER NOT NULL DEFAULT 0,
    misses     INTEGER NOT NULL DEFAULT 0,  -- consecutive missed scans
    first_seen REAL NOT NULL,
    last_seen  REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS events (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    ts        REAL NOT NULL,
    device_id INTEGER NOT NULL REFERENCES devices(id),
    kind      TEXT NOT NULL,           -- appeared | online | offline | ip_changed
    detail    TEXT
);
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts DESC);
"""


class Database:
    def __init__(self, path=DB_PATH):
        path = Path(path)
        if str(path) != ":memory:":
            path.parent.mkdir(parents=True, exist_ok=True)
        # One Database object per thread: sqlite connections aren't shared.
        self.conn = sqlite3.connect(str(path))
        self.conn.row_factory = sqlite3.Row
        self.conn.executescript(SCHEMA)
        # Migrations for databases created by older versions (missing columns are added in place).
        cols = {r["name"] for r in self.conn.execute("PRAGMA table_info(devices)")}
        if "misses" not in cols:
            self.conn.execute("ALTER TABLE devices ADD COLUMN misses INTEGER NOT NULL DEFAULT 0")
        if "vendor" not in cols:
            self.conn.execute("ALTER TABLE devices ADD COLUMN vendor TEXT")
        if "name" not in cols:
            self.conn.execute("ALTER TABLE devices ADD COLUMN name TEXT")
        if "tags" not in cols:
            self.conn.execute("ALTER TABLE devices ADD COLUMN tags TEXT")
        self.conn.commit()

    # ---- writes -----------------------------------------------------------
    def _event(self, device_id, kind, detail=None, ts=None):
        self.conn.execute(
            "INSERT INTO events (ts, device_id, kind, detail) VALUES (?,?,?,?)",
            (ts or time.time(), device_id, kind, detail),
        )

    def observe(self, ip, mac=None, hostname=None, online=True, vendor=None):
        """Record one sighting (or a missed check) of a device.

        Returns a list of event kinds generated, e.g. ["appeared"].
        """
        now = time.time()
        mac = mac.lower() if mac else None
        vendor = vendor or None
        key = mac or ip
        events = []

        row = self.conn.execute("SELECT * FROM devices WHERE key = ?", (key,)).fetchone()

        if row is None:
            if not online:
                return events  # never seen it, nothing to record
            cur = self.conn.execute(
                "INSERT INTO devices (key, mac, ip, hostname, vendor, online, first_seen, last_seen)"
                " VALUES (?,?,?,?,?,1,?,?)",
                (key, mac, ip, hostname, vendor, now, now),
            )
            self._event(cur.lastrowid, "appeared", f"{ip}", now)
            self.conn.commit()
            return ["appeared"]

        dev_id = row["id"]
        if online:
            if row["ip"] and ip and row["ip"] != ip:
                self._event(dev_id, "ip_changed", f"{row['ip']} -> {ip}", now)
                events.append("ip_changed")
            if not row["online"]:
                self._event(dev_id, "online", ip, now)
                events.append("online")
            self.conn.execute(
                "UPDATE devices SET ip=?, mac=COALESCE(?, mac),"
                " hostname=COALESCE(?, hostname), vendor=COALESCE(?, vendor),"
                " online=1, misses=0, last_seen=? WHERE id=?",
                (ip or row["ip"], mac, hostname, vendor, now, dev_id),
            )
        else:
            if row["online"]:
                self._event(dev_id, "offline", row["ip"], now)
                events.append("offline")
                self.conn.execute("UPDATE devices SET online=0 WHERE id=?", (dev_id,))
        self.conn.commit()
        return events

    def record_miss(self, device_id, threshold=MISS_THRESHOLD):
        """A scan didn't see this device. Goes offline after `threshold` misses in a row."""
        row = self.device(device_id)
        if row is None or not row["online"]:
            return []
        misses = row["misses"] + 1
        if misses >= threshold:
            self._event(device_id, "offline", row["ip"])
            self.conn.execute("UPDATE devices SET online=0, misses=? WHERE id=?", (misses, device_id))
            self.conn.commit()
            return ["offline"]
        self.conn.execute("UPDATE devices SET misses=? WHERE id=?", (misses, device_id))
        self.conn.commit()
        return []

    def forget_device(self, device_id):
        self.conn.execute("DELETE FROM events WHERE device_id=?", (device_id,))
        self.conn.execute("DELETE FROM devices WHERE id=?", (device_id,))
        self.conn.execute("DELETE FROM meta WHERE key=?", (f"pos:{device_id}",))
        self.conn.commit()

    def forget_offline(self):
        """Delete every offline device and its history. Returns how many were removed."""
        ids = [r["id"] for r in self.conn.execute("SELECT id FROM devices WHERE online=0")]
        for i in ids:
            self.forget_device(i)
        return len(ids)

    def set_name(self, device_id, name):
        """Store a custom name ('' clears it). Scans never touch it. Returns the cleaned-up value stored."""
        name = normalize_name(name)
        self.conn.execute("UPDATE devices SET name=? WHERE id=?", (name or None, device_id))
        self.conn.commit()
        return name

    def set_tags(self, device_id, tags):
        """Store custom tags from comma-separated text ('' clears them). Returns the cleaned-up value stored."""
        tags = normalize_tags(tags)
        self.conn.execute("UPDATE devices SET tags=? WHERE id=?", (tags or None, device_id))
        self.conn.commit()
        return tags

    # ---- small key/value store (gateway ip, own MAC, map positions) ----
    def get_meta(self, key):
        r = self.conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return r["value"] if r else None

    def set_meta(self, key, value):
        self.conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", (key, value))
        self.conn.commit()

    def positions(self):
        """Saved map positions: {device_id: (x, y)}."""
        out = {}
        for r in self.conn.execute("SELECT key, value FROM meta WHERE key LIKE 'pos:%'"):
            try:
                x, y = r["value"].split(",")
                out[int(r["key"][4:])] = (float(x), float(y))
            except ValueError:
                continue
        return out

    def clear_positions(self):
        self.conn.execute("DELETE FROM meta WHERE key LIKE 'pos:%'")
        self.conn.commit()

    # ---- reads ------------------------------------------------------------
    def devices(self):
        return self.conn.execute(
            "SELECT * FROM devices ORDER BY online DESC, ip"
        ).fetchall()

    def device(self, device_id):
        return self.conn.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()

    def events(self, limit=200, device_id=None):
        sql = (
            "SELECT e.*, d.ip AS ip, d.hostname AS hostname, d.mac AS mac, d.name AS name, d.tags AS tags "
            "FROM events e JOIN devices d ON d.id = e.device_id "
        )
        args = []
        if device_id is not None:
            sql += "WHERE e.device_id = ? "
            args.append(device_id)
        sql += "ORDER BY e.ts DESC, e.id DESC LIMIT ?"
        args.append(limit)
        return self.conn.execute(sql, args).fetchall()

    def close(self):
        self.conn.close()
