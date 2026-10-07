"""Anti-fingerprint audit.

A privacy OS that is itself *detectable* defeats its own purpose: standing out
is the opposite of anonymity. These tests assert that the SHIPPED DEFAULTS make
KratosOS blend in — anything that adds a unique signature must be strictly
opt-in. They read the real config files, so a change that flips a
fingerprinting knob on by default fails here.
"""
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                    "config", "includes.chroot")


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def conf_value(text, key):
    m = re.search(rf"^{re.escape(key)}=(\S+)", text, re.M)
    return m.group(1) if m else None


class DefaultsBlendIn(unittest.TestCase):
    def setUp(self):
        self.kconf = read("etc/kratos/kratos.conf")

    def test_custom_link_shaping_is_off_by_default(self):
        # Bespoke shaping/decoy is a unique signature; must be opt-in.
        self.assertEqual(conf_value(self.kconf, "CORR_LINK_SHAPING"), "off")
        self.assertEqual(conf_value(self.kconf, "CORR_DECOY"), "off")

    def test_persona_path_defaults_to_the_crowd(self):
        # tor = the large anonymity set, not a KratosOS-only path.
        self.assertEqual(conf_value(self.kconf, "CORR_MODE"), "tor")

    def test_no_unusual_start_delay_by_default(self):
        self.assertEqual(conf_value(self.kconf, "GUARD_START_JITTER"), "0")

    def test_mac_randomized(self):
        nm = read("etc/NetworkManager/conf.d/00-kratos-privacy.conf")
        self.assertIn("wifi.cloned-mac-address=random", nm)
        self.assertIn("ethernet.cloned-mac-address=random", nm)
        self.assertIn("wifi.scan-rand-mac-address=yes", nm)

    def test_hostname_not_leaked(self):
        nm = read("etc/NetworkManager/conf.d/00-kratos-privacy.conf")
        self.assertIn("ipv4.dhcp-send-hostname=false", nm)
        self.assertIn("hostname-mode=none", nm)

    def test_no_kratos_identifier_in_network_config(self):
        # The word "kratos" must not ride onto the wire as a hostname/DHCP id.
        nm = read("etc/NetworkManager/conf.d/00-kratos-privacy.conf").lower()
        for line in nm.splitlines():
            line = line.strip()
            if line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            if any(t in key for t in ("hostname", "dhcp-client-id", "mac-address", "dhcp-hostname")):
                self.assertNotIn("kratos", value, f"'{line}' puts 'kratos' on the wire")

    def test_tcp_stack_normalized(self):
        sysctl = read("etc/sysctl.d/99-kratos.conf")
        # TCP timestamps off (uptime/stack fingerprint) and IPv6 off (leak + fp).
        self.assertIn("net.ipv4.tcp_timestamps = 0", sysctl)
        self.assertIn("net.ipv6.conf.all.disable_ipv6 = 1", sysctl)

    def test_connectivity_check_disabled(self):
        # NM connectivity pings a fixed URL and advertise the OS; must be off.
        nm = read("etc/NetworkManager/conf.d/00-kratos-privacy.conf")
        self.assertRegex(nm, r"\[connectivity\][\s\S]*enabled=false")


if __name__ == "__main__":
    unittest.main()
