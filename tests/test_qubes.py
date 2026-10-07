"""Tests for the KratosOS-on-Qubes layer: the Stealth driver's command
construction and the persona isolation policy audit. These run off a Qubes
host (the logic is pure); live behaviour needs a real dom0."""
import importlib.util
import os
import re
import unittest
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
_path = os.path.join(ROOT, "qubes", "dom0", "kratos-q")
SPEC = importlib.util.spec_from_loader("kratos_q", SourceFileLoader("kratos_q", _path))
kq = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(kq)
POLICY = open(os.path.join(ROOT, "qubes", "policy", "30-kratos.policy"), encoding="utf-8").read()


class DriverCommands(unittest.TestCase):
    def test_on_starts_gateway_before_workstation(self):
        cmds = kq.build_stealth_on()
        joined = [" ".join(c) for c in cmds]
        gw = next(i for i, c in enumerate(joined) if "qvm-start --skip-if-running sys-whonix" in c)
        ws = next(i for i, c in enumerate(joined) if c.startswith("qvm-start " + kq.WS_LIVE))
        self.assertLess(gw, ws, "gateway (Tor) must come up before the workstation")

    def test_on_creates_a_disposable(self):
        cmds = kq.build_stealth_on()
        self.assertTrue(any(c[:3] == ["qvm-create", "--class", "DispVM"] for c in cmds))
        create = next(c for c in cmds if c[:3] == ["qvm-create", "--class", "DispVM"])
        self.assertIn(kq.WS_TEMPLATE, create)

    def test_on_pins_workstation_netvm_to_gateway(self):
        cmds = kq.build_stealth_on()
        self.assertIn(["qvm-prefs", kq.WS_LIVE, "netvm", kq.GATEWAY], cmds)

    def test_off_kills_then_removes_for_amnesia(self):
        cmds = kq.build_stealth_off()
        self.assertEqual(cmds[0][0], "qvm-kill")
        self.assertTrue(any(c[0] == "qvm-remove" for c in cmds))

    def test_off_removes_the_live_disposable(self):
        names = [c[-1] for c in kq.build_stealth_off()]
        self.assertTrue(all(n == kq.WS_LIVE for n in names))


class PolicyAudit(unittest.TestCase):
    def test_shipped_policy_passes(self):
        self.assertEqual(kq.audit_policy(POLICY), [])

    def test_required_services_are_denied(self):
        for svc in kq.REQUIRED_DENIES:
            self.assertIn(f"{svc} ", POLICY, f"{svc} not mentioned in policy")

    def test_detects_a_hole(self):
        # Flip the explicit clipboard deny to allow (it sits before the catch-all,
        # so first-match makes it a real hole): the audit must catch it.
        holed = re.sub(
            r"(qubes\.ClipboardPaste\s+\*\s+@tag:kratos-persona\s+@anyvm\s+)deny",
            r"\1allow", POLICY, count=1)
        self.assertNotEqual(holed, POLICY, "test setup: deny line not found")
        self.assertTrue(any("ClipboardPaste" in p for p in kq.audit_policy(holed)))

    def test_detects_earlier_allow_shadowing_the_deny(self):
        # qrexec is first-match: an allow before the deny is a real hole.
        shadowed = "qubes.Filecopy  *  @tag:kratos-persona  @anyvm  allow\n" + POLICY
        self.assertTrue(any("Filecopy" in p for p in kq.audit_policy(shadowed)))

    def test_rejects_invalid_service_wildcard(self):
        # A fake prefix wildcard (admin.vm.*) is INVALID qrexec syntax and must
        # be flagged — this is exactly what slipped through before.
        bad = POLICY + "\nadmin.vm.*  *  @tag:kratos-persona  @anyvm  deny\n"
        self.assertTrue(any("invalid service token" in p for p in kq.audit_policy(bad)))

    def test_requires_catchall_to_anyvm_and_adminvm(self):
        # Removing either catch-all deny must be caught (dom0 isn't covered by
        # @anyvm, so it needs its own rule).
        for target in ("@anyvm", "@adminvm"):
            stripped = re.sub(
                rf"^\*\s+\*\s+@tag:kratos-persona\s+{re.escape(target)}\s+deny\s*$",
                "", POLICY, count=1, flags=re.MULTILINE)
            self.assertNotEqual(stripped, POLICY, f"test setup: {target} catch-all not found")
            problems = kq.audit_policy(stripped)
            self.assertTrue(any("catch-all" in p and target in p for p in problems),
                            f"missing {target} catch-all not detected: {problems}")


if __name__ == "__main__":
    unittest.main()
