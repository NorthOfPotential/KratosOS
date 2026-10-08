"""Tests for the KratosOS-on-Qubes layer: the Stealth driver's command
construction and the persona isolation policy audit. These run off a Qubes
host (the logic is pure); live behaviour needs a real dom0."""
import importlib.util
import os
import re
import unittest
from unittest import mock
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

    def test_provision_targets_dom0_not_all(self):
        # The formula only configures dom0; provisioning must not highstate
        # every qube (--all) — it targets dom0 and applies the kratos state.
        apply_cmds = [c for c in kq.build_provision() if "state.apply" in c]
        self.assertTrue(apply_cmds, "no state.apply command")
        for c in apply_cmds:
            self.assertNotIn("--all", c, "provisioning must not use --all")
            self.assertIn("dom0", c, "provisioning must target dom0 explicitly")
            self.assertIn("kratos", c, "provisioning must apply the kratos state")


class Executor(unittest.TestCase):
    """Transactional on / best-effort off / idempotent reconcile (findings 32-34)."""

    def _fake_subprocess(self, fail_argv0=None, fail_contains=None, exists=()):
        """Return a fake subprocess.run that fails selected commands, plus a log."""
        log = []
        class R:
            def __init__(self, rc): self.returncode = rc; self.stdout = ""; self.stderr = ""
        def fake_run(argv, *a, **k):
            # qvm-check drives domain_exists(): succeed for names in `exists`.
            if argv[:2] == ["qvm-check", "--quiet"]:
                return R(0 if argv[2] in exists else 1)
            log.append(argv)
            bad = (fail_argv0 and argv[0] == fail_argv0) or \
                  (fail_contains and any(fail_contains in x for x in argv))
            return R(1 if bad else 0)
        return fake_run, log

    def _run_quiet(self, fn, *a):
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return fn(*a)

    def test_on_rolls_back_the_disposable_when_a_later_step_fails(self):
        # qvm-run (the last step) fails -> the created disposable must be removed.
        fake, log = self._fake_subprocess(fail_argv0="qvm-run")
        with mock.patch.object(kq.subprocess, "run", fake):
            rc = self._run_quiet(kq.cmd_on, False)
        self.assertNotEqual(rc, 0, "a failed start must report failure")
        self.assertIn(["qvm-remove", "-f", kq.WS_LIVE], log, "disposable not rolled back")

    def test_on_reconciles_a_stale_live_domain(self):
        # kratos-ws-live already exists -> it is torn down before re-creating.
        fake, log = self._fake_subprocess(exists=(kq.WS_LIVE,))
        with mock.patch.object(kq.subprocess, "run", fake):
            self._run_quiet(kq.cmd_on, False)
        first_remove = log.index(["qvm-remove", "-f", kq.WS_LIVE])
        first_create = next(i for i, c in enumerate(log) if kq._is_create(c))
        self.assertLess(first_remove, first_create, "stale domain not reconciled before re-create")

    def test_off_is_best_effort_past_a_failed_kill(self):
        # qvm-kill fails; qvm-remove must still be attempted (finding 33).
        fake, log = self._fake_subprocess(fail_argv0="qvm-kill")
        with mock.patch.object(kq.subprocess, "run", fake):
            rc = self._run_quiet(kq.run_all, kq.build_stealth_off(), False)
        self.assertNotEqual(rc, 0)
        self.assertIn(["qvm-remove", "-f", kq.WS_LIVE], log, "remove skipped after kill failed")


class EffectivePolicy(unittest.TestCase):
    """The lint must see the whole policy directory in load order (finding 4)."""

    def test_earlier_file_allow_is_caught(self):
        import tempfile, os
        with tempfile.TemporaryDirectory() as d:
            # An earlier-sorting file opens a hole the persona policy later denies.
            with open(os.path.join(d, "10-hole.policy"), "w") as f:
                f.write("qubes.Filecopy * @tag:kratos-persona @anyvm allow\n")
            with open(os.path.join(d, "30-kratos.policy"), "w") as f:
                f.write(POLICY)
            text = kq.effective_policy_text(os.path.join(d, "30-kratos.policy"))
            self.assertTrue(any("Filecopy" in p for p in kq.audit_policy(text)),
                            "an earlier file's allow that shadows our deny was not caught")

    def test_single_file_dir_is_unchanged(self):
        import tempfile, os
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "30-kratos.policy")
            with open(p, "w") as f:
                f.write(POLICY)
            self.assertEqual(kq.audit_policy(kq.effective_policy_text(p)), [])

    def test_runtime_policy_dir_is_audited(self):
        """A runtime allow dropped into /run/qubes/policy.d must be caught too
        (finding R4-9): qrexec loads it, so the audit must see it."""
        import tempfile, os
        saved = kq.POLICY_DIRS
        with tempfile.TemporaryDirectory() as etc, tempfile.TemporaryDirectory() as run:
            with open(os.path.join(etc, "30-kratos.policy"), "w") as f:
                f.write(POLICY)
            # A lower-numbered runtime file sorts first => shadows our deny.
            with open(os.path.join(run, "10-runtime.policy"), "w") as f:
                f.write("qubes.Filecopy * @tag:kratos-persona @anyvm allow\n")
            try:
                kq.POLICY_DIRS = (run, etc)   # qrexec order: /run then /etc
                text = kq.effective_policy_text(os.path.join(etc, "30-kratos.policy"))
            finally:
                kq.POLICY_DIRS = saved
            self.assertIn("10-runtime.policy", text, "runtime policy dir was not read")
            self.assertTrue(any("Filecopy" in p for p in kq.audit_policy(text)),
                            "a /run allow that shadows our deny was not caught")

    def test_run_wins_on_filename_collision(self):
        """When the same filename exists in both dirs, qrexec enforces the /run
        copy (it searches /run before /etc, first-occurrence wins). The audit
        must mirror that, or it would lint the safe /etc file while qrexec runs
        the hostile /run one (finding R5-2)."""
        import tempfile, os
        saved = kq.POLICY_DIRS
        with tempfile.TemporaryDirectory() as etc, tempfile.TemporaryDirectory() as run:
            # Same basename in both: /etc is a safe deny, /run is a hostile allow.
            with open(os.path.join(etc, "30-kratos.policy"), "w") as f:
                f.write(POLICY)
            with open(os.path.join(run, "30-kratos.policy"), "w") as f:
                f.write("qubes.Filecopy * @tag:kratos-persona @anyvm allow\n")
            try:
                kq.POLICY_DIRS = (run, etc)   # qrexec order: /run then /etc
                files = kq.effective_policy_files(os.path.join(etc, "30-kratos.policy"))
                text = kq.effective_policy_text(os.path.join(etc, "30-kratos.policy"))
            finally:
                kq.POLICY_DIRS = saved
            chosen = [f for f in files if f.endswith("30-kratos.policy")]
            self.assertEqual(chosen, [os.path.join(run, "30-kratos.policy")],
                             "the /run copy must win a filename collision")
            # And the audit must therefore SEE the hostile /run allow.
            self.assertTrue(any("Filecopy" in p for p in kq.audit_policy(text)),
                            "the enforced /run allow was not audited")


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
