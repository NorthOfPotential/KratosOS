"""Tests for harden-whonix.py: the guard that keeps the Workstation isolated."""
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "config", "includes.chroot", "usr", "local", "lib", "kratos",
                      "harden-whonix.py")
FIX = os.path.join(HERE, "fixtures")


def run(*args):
    return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True)


class HardenWhonixTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def prepare(self, ws_xml=None, int_xml=None):
        return run(
            "prepare",
            "--gw-xml", f"{FIX}/Whonix-Gateway-Xfce.xml",
            "--ws-xml", ws_xml or f"{FIX}/Whonix-Workstation-Xfce.xml",
            "--ext-xml", f"{FIX}/Whonix_external_network.xml",
            "--int-xml", int_xml or f"{FIX}/Whonix_internal_network.xml",
            "--gw-disk", "/vault/gateway.qcow2",
            "--ws-disk", "/vault/workstation.qcow2",
            "--ws-ram", "3072",
            "--outdir", self.out,
        )

    def load(self, name):
        return ET.parse(os.path.join(self.out, f"{name}.xml")).getroot()

    def variant(self, src, transform):
        """Write a modified copy of a fixture and return its path."""
        with open(os.path.join(FIX, src)) as f:
            text = transform(f.read())
        path = os.path.join(self.out, "variant-" + src)
        with open(path, "w") as f:
            f.write(text)
        return path

    # ── prepare ────────────────────────────────────────────────

    def test_prepare_outputs_pass_check(self):
        r = self.prepare()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(run("check", self.out).returncode, 0)

    def test_generic_names_and_no_uuid(self):
        self.prepare()
        for name in ("kx-gw", "kx-ws", "kx-ext", "kx-int"):
            root = self.load(name)
            self.assertEqual(root.findtext("name"), name)
            self.assertIsNone(root.find("uuid"))
            self.assertNotIn("Whonix", ET.tostring(root, encoding="unicode"))

    def test_workstation_only_on_internal_network(self):
        self.prepare()
        nets = [i.find("source").get("network") for i in self.load("kx-ws").iter("interface")]
        self.assertEqual(nets, ["kx-int"])
        gw_nets = sorted(i.find("source").get("network") for i in self.load("kx-gw").iter("interface"))
        self.assertEqual(gw_nets, ["kx-ext", "kx-int"])

    def test_integration_channels_removed(self):
        self.prepare()
        ws = self.load("kx-ws")
        self.assertEqual(ws.findall("devices/redirdev"), [])
        self.assertEqual([c for c in ws.iter("channel") if c.get("type") == "spicevmc"], [])
        g = ws.find("devices/graphics")
        self.assertEqual(g.find("clipboard").get("copypaste"), "no")
        self.assertEqual(g.find("filetransfer").get("enable"), "no")
        listen = g.findall("listen")
        self.assertEqual(len(listen), 1)
        self.assertEqual(listen[0].get("type"), "socket")
        self.assertEqual(listen[0].get("socket"), "/run/kratos/spice/kx-ws.sock")

    def test_disk_and_memory_rewritten(self):
        self.prepare()
        ws = self.load("kx-ws")
        self.assertEqual(ws.find("devices/disk/source").get("file"), "/vault/workstation.qcow2")
        self.assertEqual(ws.findtext("memory"), str(3072 * 1024))

    def test_bridges_renamed(self):
        self.prepare()
        self.assertEqual(self.load("kx-ext").find("bridge").get("name"), "kx-ext")
        self.assertEqual(self.load("kx-int").find("bridge").get("name"), "kx-int")

    # ── refusals ───────────────────────────────────────────────

    def test_refuses_workstation_with_direct_internet(self):
        ws = self.variant("Whonix-Workstation-Xfce.xml", lambda s: s.replace(
            "<channel", '<interface type="network"><source network="default"/></interface><channel', 1))
        r = self.prepare(ws_xml=ws)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stderr)

    def test_refuses_workstation_on_external_network(self):
        ws = self.variant("Whonix-Workstation-Xfce.xml",
                          lambda s: s.replace("Whonix-Internal", "Whonix-External"))
        self.assertNotEqual(self.prepare(ws_xml=ws).returncode, 0)

    def test_refuses_bridged_interface(self):
        ws = self.variant("Whonix-Workstation-Xfce.xml", lambda s: s.replace(
            "<channel", '<interface type="bridge"><source bridge="br0"/></interface><channel', 1))
        self.assertNotEqual(self.prepare(ws_xml=ws).returncode, 0)

    def test_refuses_internal_network_that_forwards(self):
        net = self.variant("Whonix_internal_network.xml",
                           lambda s: s.replace("<bridge", '<forward mode="nat"/><bridge'))
        self.assertNotEqual(self.prepare(int_xml=net).returncode, 0)

    def test_refuses_host_address_on_internal_network(self):
        net = self.variant("Whonix_internal_network.xml", lambda s: s.replace(
            "</network>", '<ip address="10.152.152.1" netmask="255.255.192.0"/></network>'))
        self.assertNotEqual(self.prepare(int_xml=net).returncode, 0)

    # ── check catches tampering after setup ────────────────────

    def tamper(self, name, transform):
        path = os.path.join(self.out, f"{name}.xml")
        with open(path) as f:
            text = f.read()
        with open(path, "w") as f:
            f.write(transform(text))

    def test_check_detects_added_interface(self):
        self.prepare()
        self.tamper("kx-ws", lambda s: s.replace(
            "</devices>", '<interface type="network"><source network="kx-ext"/></interface></devices>'))
        self.assertNotEqual(run("check", self.out).returncode, 0)

    def test_check_detects_clipboard_reenabled(self):
        self.prepare()
        self.tamper("kx-ws", lambda s: s.replace('copypaste="no"', 'copypaste="yes"'))
        self.assertNotEqual(run("check", self.out).returncode, 0)

    def test_check_detects_shared_folder(self):
        self.prepare()
        self.tamper("kx-ws", lambda s: s.replace(
            "</devices>", '<filesystem type="mount"><source dir="/home"/><target dir="h"/></filesystem></devices>'))
        self.assertNotEqual(run("check", self.out).returncode, 0)

    def test_check_detects_network_display(self):
        self.prepare()
        self.tamper("kx-ws", lambda s: s.replace(
            '<listen type="socket" socket="/run/kratos/spice/kx-ws.sock" />',
            '<listen type="address" address="0.0.0.0" />'))
        self.assertNotEqual(run("check", self.out).returncode, 0)

    # ── compartmentalization (sVirt / blast-radius reduction) ──

    def test_svirt_seclabel_added(self):
        self.prepare()
        for name in ("kx-gw", "kx-ws"):
            sl = self.load(name).find("seclabel")
            self.assertIsNotNone(sl, f"{name} has no <seclabel>")
            self.assertEqual(sl.get("type"), "dynamic")
            self.assertEqual(sl.get("relabel"), "yes")

    def test_check_detects_svirt_removed(self):
        self.prepare()
        self.tamper("kx-ws", lambda s: s.replace("dynamic", "none"))
        self.assertNotEqual(run("check", self.out).returncode, 0)

    def test_check_detects_shareable_disk(self):
        self.prepare()
        self.tamper("kx-ws", lambda s: s.replace("</disk>", "<shareable/></disk>", 1))
        self.assertNotEqual(run("check", self.out).returncode, 0)

    def test_check_detects_shared_disk_between_vms(self):
        self.prepare()
        # Point the Workstation at the Gateway's disk: a cross-compartment bridge.
        self.tamper("kx-ws", lambda s: s.replace("workstation.qcow2", "gateway.qcow2"))
        self.assertNotEqual(run("check", self.out).returncode, 0)


if __name__ == "__main__":
    unittest.main()
