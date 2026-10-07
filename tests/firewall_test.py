"""Functional firewall tests. Run as root inside a fresh network namespace
(tests/run.sh does this with `unshare -n`).

A bridge with an address, a default route and a static neighbour entry
stands in for the physical network. A raw packet socket on the bridge sees
every frame that is actually transmitted, so each check asks the only
question that matters: did the packet leave the machine?

Forwarding (Stealth Gateway traffic) needs veth pairs, which this test
environment doesn't have, so it isn't covered here.
"""
import os
import socket
import subprocess
import sys
import struct
import tempfile
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config", "includes.chroot",
                    "etc", "kratos")
VPN_ENDPOINT = "10.99.0.50"
VPN_PORT = 51820
FAILURES = []


def sh(cmd):
    subprocess.run(cmd, shell=True, check=True)


def load(mode):
    path = os.path.join(ROOT, "modes", f"{mode}.nft")
    with open(path) as f:
        text = f.read()
    tmp = tempfile.mkdtemp()
    defs = os.path.join(tmp, "vpn.inc")
    with open(defs, "w") as f:
        f.write(f'define WG_IF = "wgtest"\ndefine WG_ENDPOINT = {VPN_ENDPOINT}\ndefine WG_PORT = {VPN_PORT}\n')
    text = text.replace("/run/kratos/vpn.nft", defs)
    rules = os.path.join(tmp, f"{mode}.nft")
    with open(rules, "w") as f:
        f.write(text)
    sh(f"nft -f {rules}")


SNIFFER = None


def sniff_open():
    global SNIFFER
    SNIFFER = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
    SNIFFER.bind(("kxnet", 0))
    SNIFFER.setblocking(False)


def drain():
    """Return (proto, dst, dport) for every IPv4 TCP/UDP frame transmitted."""
    seen = []
    deadline = time.time() + 0.3
    while time.time() < deadline:
        try:
            frame = SNIFFER.recv(65535)
        except BlockingIOError:
            time.sleep(0.01)
            continue
        if len(frame) < 34 or frame[12:14] != b"\x08\x00":
            continue
        ihl = (frame[14] & 0x0F) * 4
        proto = frame[23]
        dst = socket.inet_ntoa(frame[30:34])
        if proto in (6, 17) and len(frame) >= 14 + ihl + 4:
            dport = struct.unpack("!H", frame[14 + ihl + 2:14 + ihl + 4])[0]
            seen.append((proto, dst, dport))
    return seen


def left_machine(proto, dst, port):
    return "LEFT the machine" if (proto, dst, port) in drain() else "blocked"


def udp(dst, port, sport=0):
    drain()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", sport))
        s.sendto(b"x", (dst, port))
    except OSError:
        pass
    finally:
        s.close()
    return left_machine(17, dst, port)


def tcp(dst, port):
    drain()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setblocking(False)
    try:
        s.connect_ex((dst, port))
        result = left_machine(6, dst, port)
    finally:
        s.close()
    return result


def expect(desc, result, allowed):
    ok = (result == "LEFT the machine") == allowed
    print(f"  {'PASS' if ok else 'FAIL'}  {desc}: {result}")
    if not ok:
        FAILURES.append(desc)


def main():
    sh("ip link set lo up")
    sh("ip link add kxnet type bridge && ip addr add 10.99.0.2/24 dev kxnet && ip link set kxnet up")
    sh("ip route add default via 10.99.0.1")
    # Resolve the "router" statically so packets go straight onto the wire
    sh("ip neigh add 10.99.0.1 lladdr 02:00:00:00:00:01 dev kxnet nud permanent")
    for host in ("10.99.0.7", VPN_ENDPOINT, "10.99.0.51"):
        sh(f"ip neigh add {host} lladdr 02:00:00:00:00:02 dev kxnet nud permanent")
    sniff_open()

    print("control: no firewall (proves the sniffer sees leaks)")
    expect("HTTPS leaves with no firewall", tcp("93.184.216.34", 443), True)
    expect("clear-text DNS leaves with no firewall", udp("9.9.9.9", 53), True)

    print("mode: normal")
    load("normal")
    expect("HTTPS to the internet allowed", tcp("93.184.216.34", 443), True)
    expect("DNS over TLS allowed", tcp("9.9.9.9", 853), True)
    expect("clear-text DNS blocked (forced through the resolver)", udp("9.9.9.9", 53), False)
    expect("clear-text DNS over TCP blocked", tcp("9.9.9.9", 53), False)
    expect("mDNS announcement blocked", udp("224.0.0.251", 5353), False)
    expect("LLMNR blocked", udp("224.0.0.252", 5355), False)
    expect("SSDP/UPnP blocked", udp("239.255.255.250", 1900), False)
    expect("SMB to the internet blocked", tcp("93.184.216.34", 445), False)
    expect("SMB on the LAN allowed", tcp("10.99.0.7", 445), True)

    print("mode: vpn (kill switch, tunnel down)")
    load("vpn")
    expect("WireGuard to VPN endpoint allowed", udp(VPN_ENDPOINT, VPN_PORT), True)
    expect("WireGuard to another server blocked", udp("10.99.0.51", VPN_PORT), False)
    expect("clear-text DNS blocked", udp("9.9.9.9", 53), False)
    expect("HTTPS outside the tunnel blocked", tcp("93.184.216.34", 443), False)
    expect("UDP outside the tunnel blocked", udp("93.184.216.34", 443), False)
    expect("DHCP allowed", udp("10.99.0.1", 67, sport=68), True)

    print("mode: offline")
    load("offline")
    expect("HTTPS blocked", tcp("93.184.216.34", 443), False)
    expect("VPN endpoint blocked", udp(VPN_ENDPOINT, VPN_PORT), False)
    expect("DNS blocked", udp("9.9.9.9", 53), False)
    expect("DHCP blocked", udp("10.99.0.1", 67, sport=68), False)

    print("stealth table loads on top of each mode")
    for mode in ("normal", "offline"):
        load(mode)
        sh(f"nft -f {os.path.join(ROOT, 'stealth.nft')}")
        sh("nft delete table inet kratos_stealth")

    if FAILURES:
        print(f"\n{len(FAILURES)} firewall test(s) failed")
        sys.exit(1)
    print("\nall firewall tests passed")


if __name__ == "__main__":
    main()
