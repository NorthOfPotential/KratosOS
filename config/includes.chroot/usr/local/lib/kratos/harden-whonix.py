#!/usr/bin/env python3
"""Prepare and validate Whonix libvirt definitions for KratosOS Stealth Mode.

prepare: take the XML files shipped in the official Whonix KVM archive and
write hardened copies (kx-gw, kx-ws, kx-ext, kx-int) that:
  * use generic names (no "Whonix" in libvirt logs or process lists)
  * point at the disks inside the encrypted stealth vault
  * have no clipboard, file transfer, USB redirection or shared folders
  * have the exact network topology Whonix requires

check: validate already-prepared files. Exits non-zero on any violation, so
Stealth Mode refuses to start a Workstation that could reach the internet
any way other than through the Gateway.
"""
import argparse
import sys
import xml.etree.ElementTree as ET

EXT, INT = "kx-ext", "kx-int"
GW, WS = "kx-gw", "kx-ws"
SPICE_DIR = "/run/kratos/spice"

# Host/guest integration that could carry data across the boundary
REMOVE_DEVICES = ("redirdev", "filesystem", "smartcard", "hostdev", "shmem")


class Violation(Exception):
    pass


def _drop_uuid(root):
    for uuid in root.findall("uuid"):
        root.remove(uuid)


def _set_text(root, tag, text):
    el = root.find(tag)
    if el is None:
        el = ET.SubElement(root, tag)
    el.text = text


def map_network_name(name):
    lname = name.lower()
    if "external" in lname or name == EXT:
        return EXT
    if "internal" in lname or name == INT:
        return INT
    raise Violation(f"unknown network '{name}'")


def harden_domain(root, name, disk, ram_mib):
    root.set("type", "kvm")
    _set_text(root, "name", name)
    _drop_uuid(root)
    for tag in ("memory", "currentMemory"):
        el = root.find(tag)
        if el is not None:
            el.set("unit", "KiB")
            el.text = str(ram_mib * 1024)

    devices = root.find("devices")
    if devices is None:
        raise Violation(f"{name}: no <devices>")

    disks = [d for d in devices.findall("disk") if d.get("device", "disk") == "disk"]
    if len(disks) != 1:
        raise Violation(f"{name}: expected exactly one disk, found {len(disks)}")
    for d in devices.findall("disk"):
        if d.get("device") in ("cdrom", "floppy"):
            devices.remove(d)
    disks[0].set("type", "file")
    src = disks[0].find("source")
    if src is None:
        src = ET.SubElement(disks[0], "source")
    src.attrib.clear()
    src.set("file", disk)

    for tag in REMOVE_DEVICES:
        for el in devices.findall(tag):
            devices.remove(el)
    for ch in devices.findall("channel"):
        target = ch.find("target")
        if ch.get("type") == "spicevmc" or (
            target is not None and target.get("name", "").startswith("com.redhat.spice")
        ):
            devices.remove(ch)

    graphics = devices.findall("graphics")
    for g in graphics[1:]:
        devices.remove(g)
    if graphics:
        g = graphics[0]
        # The display is a private UNIX socket handed to the desktop user:
        # screen and input only, no libvirt control, nothing on the network.
        g.attrib.clear()
        g.set("type", "spice")
        for child in list(g):
            g.remove(child)
        ET.SubElement(g, "listen", type="socket", socket=f"{SPICE_DIR}/{name}.sock")
        ET.SubElement(g, "clipboard", copypaste="no")
        ET.SubElement(g, "filetransfer", enable="no")

    for iface in devices.findall("interface"):
        if iface.get("type") != "network":
            raise Violation(f"{name}: interface of type '{iface.get('type')}' is not allowed")
        src = iface.find("source")
        src.set("network", map_network_name(src.get("network", "")))


def check_domain(root):
    name = root.findtext("name")
    if name not in (GW, WS):
        raise Violation(f"unexpected domain name '{name}'")
    devices = root.find("devices")
    nets = []
    for iface in devices.findall("interface"):
        if iface.get("type") != "network":
            raise Violation(f"{name}: interface of type '{iface.get('type')}' is not allowed")
        nets.append(iface.find("source").get("network"))
    expected = [INT] if name == WS else [EXT, INT]
    if sorted(nets) != sorted(expected):
        raise Violation(f"{name}: networks {nets}, expected {expected}")
    for tag in REMOVE_DEVICES:
        if devices.find(tag) is not None:
            raise Violation(f"{name}: <{tag}> must not be present")
    for ch in devices.findall("channel"):
        if ch.get("type") == "spicevmc":
            raise Violation(f"{name}: spice agent channel (clipboard) must not be present")
    for g in devices.findall("graphics"):
        if g.get("type") != "spice":
            raise Violation(f"{name}: only a SPICE display on a private socket is allowed")
        cb = g.find("clipboard")
        if cb is None or cb.get("copypaste") != "no":
            raise Violation(f"{name}: clipboard sharing must be disabled")
        ft = g.find("filetransfer")
        if ft is None or ft.get("enable") != "no":
            raise Violation(f"{name}: file transfer must be disabled")
        listens = g.findall("listen")
        if len(listens) != 1 or listens[0].get("type") != "socket" \
                or listens[0].get("socket") != f"{SPICE_DIR}/{name}.sock":
            raise Violation(f"{name}: display must listen only on {SPICE_DIR}/{name}.sock")


def harden_network(root, name):
    _set_text(root, "name", name)
    _drop_uuid(root)
    for mac in root.findall("mac"):
        root.remove(mac)
    bridge = root.find("bridge")
    if bridge is None:
        bridge = ET.SubElement(root, "bridge")
    bridge.attrib.clear()
    bridge.set("name", name)
    bridge.set("stp", "on")
    bridge.set("delay", "0")


def check_network(root):
    name = root.findtext("name")
    bridge = root.find("bridge")
    if bridge is None or bridge.get("name") != name:
        raise Violation(f"network {name}: bridge must be named {name}")
    forward = root.find("forward")
    if name == INT:
        if forward is not None:
            raise Violation(f"{INT}: internal network must not forward anywhere")
        if root.find("ip") is not None:
            raise Violation(f"{INT}: host must not have an address on the internal network")
    elif name == EXT:
        if forward is None or forward.get("mode") != "nat":
            raise Violation(f"{EXT}: external network must be NAT")
    else:
        raise Violation(f"unexpected network '{name}'")


def write(root, path):
    ET.indent(root)
    ET.ElementTree(root).write(path, encoding="unicode")


def cmd_prepare(a):
    gw = ET.parse(a.gw_xml).getroot()
    ws = ET.parse(a.ws_xml).getroot()
    ext = ET.parse(a.ext_xml).getroot()
    int_ = ET.parse(a.int_xml).getroot()
    harden_domain(gw, GW, a.gw_disk, a.gw_ram)
    harden_domain(ws, WS, a.ws_disk, a.ws_ram)
    harden_network(ext, EXT)
    harden_network(int_, INT)
    for root, check in ((gw, check_domain), (ws, check_domain), (ext, check_network), (int_, check_network)):
        check(root)
    write(gw, f"{a.outdir}/{GW}.xml")
    write(ws, f"{a.outdir}/{WS}.xml")
    write(ext, f"{a.outdir}/{EXT}.xml")
    write(int_, f"{a.outdir}/{INT}.xml")


def cmd_check(a):
    check_domain(ET.parse(f"{a.dir}/{GW}.xml").getroot())
    check_domain(ET.parse(f"{a.dir}/{WS}.xml").getroot())
    check_network(ET.parse(f"{a.dir}/{EXT}.xml").getroot())
    check_network(ET.parse(f"{a.dir}/{INT}.xml").getroot())


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("prepare")
    for opt in ("gw-xml", "ws-xml", "ext-xml", "int-xml", "gw-disk", "ws-disk", "outdir"):
        pr.add_argument(f"--{opt}", required=True)
    pr.add_argument("--gw-ram", type=int, default=1024)
    pr.add_argument("--ws-ram", type=int, default=4096)
    ch = sub.add_parser("check")
    ch.add_argument("dir")
    a = p.parse_args()
    try:
        (cmd_prepare if a.cmd == "prepare" else cmd_check)(a)
    except (Violation, ET.ParseError) as e:
        print(f"harden-whonix: REFUSED: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
