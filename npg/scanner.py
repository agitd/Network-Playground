"""Network discovery via arp-scan (ARP only, no port scanning).

scan_network() blocks for several seconds, so call it from a worker thread.
It never touches the database; it only returns what it saw.

Why more than one ARP pass: phones and other Wi-Fi devices often ignore
*broadcast* ARP while their screen is off, but still answer a *unicast* ARP
sent straight to their known MAC. So after the broadcast sweep, every known
device that stayed silent gets a targeted unicast check before it can count
as a miss.
"""

import ipaddress
import re
import shutil
import socket
import subprocess
from concurrent.futures import ThreadPoolExecutor, wait
from dataclasses import dataclass
from typing import Optional

LINE_RE = re.compile(r"^(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\s*(.*)$")

PERMISSION_HINT = (
    "arp-scan needs raw-socket permission. Run once:\n"
    "  sudo setcap cap_net_raw,cap_net_admin+eip $(which arp-scan)"
)


class ScanError(Exception):
    pass


@dataclass
class Host:
    ip: str
    mac: str
    vendor: str = ""
    hostname: Optional[str] = None


@dataclass
class ScanResult:
    hosts: list                       # devices seen on the network (excludes this PC)
    self_host: Optional[Host] = None  # this computer (arp-scan never lists itself)
    gateway_ip: Optional[str] = None
    interface: Optional[str] = None
    network: Optional[str] = None     # e.g. "192.168.0.0/24"


# ---- local network info ------------------------------------------------------
def _run(cmd, timeout=5) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def default_route():
    """(interface, gateway_ip) of the default route, e.g. ('eno1', '192.168.0.1')."""
    out = _run(["ip", "-o", "-4", "route", "show", "default"])
    line = out.splitlines()[0] if out.strip() else ""
    dev = re.search(r"\bdev\s+(\S+)", line)
    via = re.search(r"\bvia\s+(\d+\.\d+\.\d+\.\d+)", line)
    return (dev.group(1) if dev else None, via.group(1) if via else None)


def interface_addr(iface):
    """(own_ip, IPv4Network) of an interface, or (None, None)."""
    out = _run(["ip", "-o", "-4", "addr", "show", "dev", iface])
    m = re.search(r"inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)", out)
    if not m:
        return None, None
    try:
        return m.group(1), ipaddress.ip_network(f"{m.group(1)}/{m.group(2)}", strict=False)
    except ValueError:
        return None, None


def interface_mac(iface):
    try:
        with open(f"/sys/class/net/{iface}/address") as f:
            return f.read().strip().lower() or None
    except OSError:
        return None


# ---- arp-scan ----------------------------------------------------------------
def _find_arp_scan():
    exe = shutil.which("arp-scan")
    if not exe:
        raise ScanError("arp-scan is not installed.\n  sudo apt install arp-scan")
    return exe


def _parse(stdout):
    hosts = []
    for line in stdout.splitlines():
        m = LINE_RE.match(line.strip())
        if m:
            vendor = m.group(3).strip()
            if vendor.startswith("(Unknown"):
                vendor = ""
            hosts.append(Host(ip=m.group(1), mac=m.group(2).lower(), vendor=vendor))
    return hosts


def arp_scan(exe, iface):
    """Broadcast sweep of the whole local subnet."""
    cmd = [exe, "--localnet", "--plain", "--ignoredups", "--retry=3", "--timeout=400"]
    if iface:
        cmd += ["--interface", iface]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        raise ScanError("arp-scan timed out.")
    except OSError as e:
        raise ScanError(f"Could not run arp-scan: {e}")

    if proc.returncode != 0:
        err = (proc.stderr or "").strip()
        low = err.lower()
        if any(w in low for w in ("root", "permitted", "permission", "suid")):
            raise ScanError(PERMISSION_HINT)
        raise ScanError(err or f"arp-scan exited with code {proc.returncode}")
    return _parse(proc.stdout)


def _verify_one(exe, iface, ip, mac):
    """Unicast ARP straight to a known MAC; returns a Host if it answers."""
    cmd = [exe, "--plain", "--retry=3", "--timeout=800", f"--destaddr={mac}"]
    if iface:
        cmd += ["--interface", iface]
    cmd.append(ip)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    for h in _parse(proc.stdout):
        if h.mac == mac and h.ip == ip:
            return h
    return None


def verify_known(exe, iface, candidates):
    """Run unicast checks for [(ip, mac), ...] in parallel; returns the Hosts that answered."""
    if not candidates:
        return []
    ex = ThreadPoolExecutor(max_workers=8)
    futures = [ex.submit(_verify_one, exe, iface, ip, mac) for ip, mac in candidates]
    done, _ = wait(futures, timeout=25)
    ex.shutdown(wait=False, cancel_futures=True)
    return [f.result() for f in done if f.result() is not None]


# ---- hostnames -----------------------------------------------------------------
def _resolve(ip):
    try:
        return socket.gethostbyaddr(ip)[0]
    except OSError:
        return None


def resolve_hostnames(hosts, timeout=3.0):
    """Fill in Host.hostname via reverse DNS, in parallel, with a hard time limit."""
    if not hosts:
        return
    ex = ThreadPoolExecutor(max_workers=16)
    futures = {ex.submit(_resolve, h.ip): h for h in hosts}
    done, _ = wait(futures, timeout=timeout)
    for f in done:
        futures[f].hostname = f.result()
    ex.shutdown(wait=False, cancel_futures=True)  # abandon slow lookups


# ---- entry point -----------------------------------------------------------------
def scan_network(known=None) -> ScanResult:
    """known: [(ip, mac), ...] devices already in the database (used for unicast re-checks)."""
    exe = _find_arp_scan()
    iface, gateway = default_route()
    self_ip, network = interface_addr(iface) if iface else (None, None)
    self_mac = interface_mac(iface) if iface else None

    hosts = [h for h in arp_scan(exe, iface) if h.ip != self_ip]
    found = {h.mac for h in hosts}

    candidates = []
    for ip, mac in known or []:
        if not mac or mac in found or mac == self_mac:
            continue
        if network is not None:
            try:
                if ipaddress.ip_address(ip) not in network:
                    continue  # stale entry from another network
            except ValueError:
                continue
        candidates.append((ip, mac))
    hosts += verify_known(exe, iface, candidates[:32])

    resolve_hostnames(hosts)

    self_host = None
    if self_ip and self_mac:
        self_host = Host(ip=self_ip, mac=self_mac, hostname=socket.gethostname())

    return ScanResult(
        hosts=hosts,
        self_host=self_host,
        gateway_ip=gateway,
        interface=iface,
        network=str(network) if network else None,
    )
