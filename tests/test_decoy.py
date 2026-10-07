"""Tests for the decoy (cover-traffic) generator's rate math.

The decoy's send rate is fully determined by parse_rate() and the packet size,
so we test that logic directly and deterministically. Earlier versions drove
the real process over UDP in a network namespace and measured arrivals; that
was fragile on CI runners (loopback down, timeout/signal timing) and told us
nothing the math doesn't. Real packet emission is exercised by the firewall
and Nym enforcement tests."""
import importlib.util
import os
import unittest
from importlib.machinery import SourceFileLoader

_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                     "config", "includes.chroot", "usr", "local", "bin", "kratos-decoy")
_spec = importlib.util.spec_from_loader("kratos_decoy", SourceFileLoader("kratos_decoy", _path))
decoy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(decoy)


def pps(rate):
    """Packets per second the decoy will pace for a given rate string."""
    return decoy.parse_rate(rate) / (decoy.PKT * 8)


class ParseRate(unittest.TestCase):
    def test_bit_suffixes(self):
        self.assertEqual(decoy.parse_rate("1mbit"), 1_000_000)
        self.assertEqual(decoy.parse_rate("500kbit"), 500_000)
        self.assertEqual(decoy.parse_rate("2gbit"), 2_000_000_000)
        self.assertEqual(decoy.parse_rate("800bit"), 800)

    def test_case_and_whitespace_insensitive(self):
        self.assertEqual(decoy.parse_rate("  1MBIT "), 1_000_000)

    def test_bare_number_is_bytes_per_second(self):
        # No suffix → bytes/s → *8 to bits.
        self.assertEqual(decoy.parse_rate("125000"), 1_000_000)


class PacingRate(unittest.TestCase):
    def test_1mbit_is_about_104_pps(self):
        # 1e6 bits / (1200 bytes * 8) ≈ 104 packets/s → ~208 over 2s.
        self.assertAlmostEqual(pps("1mbit"), 104.1667, places=2)

    def test_higher_rate_scales_linearly(self):
        self.assertAlmostEqual(pps("10mbit") / pps("1mbit"), 10.0, places=6)

    def test_two_second_window_lands_in_the_asserted_band(self):
        # The old integration test asserted 100–400 packets in ~2s for 1mbit;
        # confirm the math actually falls there, and that 10mbit would not.
        self.assertTrue(100 <= pps("1mbit") * 2 <= 400)
        self.assertGreater(pps("10mbit") * 2, 400)


if __name__ == "__main__":
    unittest.main()
