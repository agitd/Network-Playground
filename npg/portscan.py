"""Basic TCP connect scan of a few common ports - standard library only.

A port counts as open when the TCP handshake completes. Nothing is sent after that: no banner
grabbing, no service probing. Only one device is checked at a time (started by the user with the
SCAN PORTS button) and addresses outside private/local ranges are refused, so this cannot be
pointed at the internet.

No Qt imports: the GUI runs scan_ports() in a worker thread.
"""

import ipaddress
import socket
from concurrent.futures import ThreadPoolExecutor

COMMON_PORTS = {
    21: "FTP",
    22: "SSH",
    23: "Telnet",
    25: "SMTP",
    53: "DNS",
    80: "HTTP",
    110: "POP3",
    139: "NetBIOS",
    143: "IMAP",
    443: "HTTPS",
    445: "SMB",
    548: "AFP",
    631: "IPP",
    1883: "MQTT",
    3389: "RDP",
    5900: "VNC",
    8080: "HTTP-alt",
    8443: "HTTPS-alt",
    9100: "JetDirect",
}

CONNECT_TIMEOUT = 1.0  # seconds to wait for each port
MAX_WORKERS = 16       # ports checked in parallel


def is_local_address(ip):
    """True for private, loopback, link-local and other non-public addresses."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return not (addr.is_global or addr.is_multicast or addr.is_unspecified or addr.is_reserved)


def port_label(port):
    """22 -> '22 SSH'; unknown ports are just the number."""
    name = COMMON_PORTS.get(port)
    return f"{port} {name}" if name else str(port)


def check_port(ip, port, timeout=CONNECT_TIMEOUT):
    """True if a TCP connection to ip:port succeeds (refused and timed-out both count as not open)."""
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def scan_ports(ip, ports=None, timeout=CONNECT_TIMEOUT, connect=check_port):
    """Return the sorted list of open ports among `ports` (default: COMMON_PORTS).

    Raises ValueError, before anything is sent, for an invalid or non-local address or an invalid
    port number. `connect(ip, port, timeout) -> bool` exists so tests can replace the real sockets.
    """
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        raise ValueError(f"'{ip}' is not a valid IP address.") from None
    if not is_local_address(str(addr)):
        raise ValueError(f"Refusing to scan {addr}: only private or local addresses can be scanned.")

    ports = list(COMMON_PORTS if ports is None else ports)
    for p in ports:
        if not isinstance(p, int) or isinstance(p, bool) or not 1 <= p <= 65535:
            raise ValueError(f"Invalid port number: {p!r}")
    ports = sorted(set(ports))
    if not ports:
        return []

    with ThreadPoolExecutor(max_workers=min(MAX_WORKERS, len(ports))) as pool:
        results = list(pool.map(lambda p: connect(str(addr), p, timeout), ports))
    return [p for p, ok in zip(ports, results) if ok]
