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

    def test_real_policy_eval_falls_back_closed_off_dom0(self):
        """Off a dom0 (no qrexec library), the upstream-evaluation path must say
        ran=False with no findings, so cmd_audit keeps the lint — never a false
        "engine says safe" (finding R6-H10, fail-closed fallback)."""
        ran, problems = kq.evaluate_with_real_policy()
        self.assertFalse(ran)
        self.assertEqual(problems, [])

    def _fake_engine(self, allow_pairs=(), ask_pairs=(), raise_on_none_resolution=False,
                     allow_arg_pairs=(), allow_target_pairs=None):
        """Build a (policy, Request, AccessDenied, system_info) seam that mimics
        qrexec: deny (raise AccessDenied) unless the request matches. allow_pairs
        and ask_pairs match on (src,tgt,svc) ignoring the argument;
        allow_arg_pairs match on the full (src,tgt,svc,arg) (finding R11-1);
        allow_target_pairs maps (src,tgt,svc) -> resolved target, so an
        `allow target=...` resolution can be modelled (finding R12-1)."""
        allow_target_pairs = allow_target_pairs or {}

        class AccessDenied(Exception):
            pass

        class AllowResolution:  # names matter: verdict() checks the class name
            def __init__(self, target=None):
                self.target = target

        class AskResolution:
            def __init__(self, target=None):
                self.target = target

        class Request:
            def __init__(self, service, argument, source, target, *,
                         system_info, allow_resolution_type=AllowResolution,
                         ask_resolution_type=AskResolution):
                # Reproduce the real bug: constructing an allow with a None
                # resolution type blows up (as Allow.evaluate would).
                if raise_on_none_resolution and allow_resolution_type is None:
                    raise TypeError("None is not callable")
                self.key = (source, target, service)
                self.key_arg = (source, target, service, argument)

        class Policy:
            def evaluate(self, req):
                if req.key in allow_target_pairs:
                    return AllowResolution(target=allow_target_pairs[req.key])
                if req.key_arg in allow_arg_pairs:
                    return AllowResolution()
                if req.key in allow_pairs:
                    return AllowResolution()
                if req.key in ask_pairs:
                    return AskResolution()
                raise AccessDenied()

        # dom0 is always in system_info["domains"]; the evaluator must treat it
        # as an egress target only, never synthesize it as an inbound source.
        # get_system_info() also keys each domain by a 'uuid:<UUID>' alias; those
        # must be canonicalized away, never probed as separate domains.
        system_info = {"domains": {
            "dom0": {}, "kratos-ws-live": {}, "personal": {}, "sys-whonix": {},
            "uuid:0": {}, "uuid:ws-live-uuid": {},
        }}
        return (Policy(), Request, AccessDenied, system_info)

    def test_real_eval_catches_egress_and_inbound_allow(self):
        """With a real engine (faked), an allow in EITHER direction is reported
        (findings R8-2 resolution types, R8-3 both directions)."""
        eng = self._fake_engine(allow_pairs={
            ("kratos-ws-live", "personal", "qubes.Filecopy"),      # egress hole
            ("personal", "kratos-ws-live", "qubes.ClipboardPaste"),  # inbound hole
        })
        ran, problems = kq.evaluate_with_real_policy(_engine=eng)
        self.assertTrue(ran)
        self.assertTrue(any("egress hole" in p and "Filecopy" in p for p in problems),
                        f"egress allow not reported: {problems}")
        self.assertTrue(any("inbound hole" in p and "ClipboardPaste" in p for p in problems),
                        f"inbound allow not reported: {problems}")

    def test_dom0_is_not_probed_as_an_inbound_source(self):
        """dom0/AdminVM originate qrexec calls specially, so a synthesized
        'dom0 -> persona' request would be a FALSE positive (finding R9-5). Even
        if the (faked) engine would 'allow' such a request, the evaluator must
        never construct it, so nothing is reported as an inbound hole."""
        eng = self._fake_engine(allow_pairs={
            ("dom0", "kratos-ws-live", "qubes.Filecopy")})
        ran, problems = kq.evaluate_with_real_policy(_engine=eng)
        self.assertTrue(ran, "evaluator did not run")
        self.assertFalse(any("inbound hole" in p for p in problems),
                         f"dom0 was wrongly probed as an inbound source: {problems}")

    def test_uuid_aliases_are_not_probed(self):
        """get_system_info() lists each domain twice (name + 'uuid:<UUID>').
        The evaluator must canonicalize to names, so no probe is built against a
        uuid: alias — neither as a target nor (for a persona's alias) a source
        slipping past the name-based exclusion (finding R10-9)."""
        eng = self._fake_engine(allow_pairs={
            ("uuid:ws-live-uuid", "personal", "qubes.Filecopy"),  # persona-by-uuid egress
            ("personal", "uuid:ws-live-uuid", "qubes.ClipboardPaste"),  # into persona-by-uuid
        })
        ran, problems = kq.evaluate_with_real_policy(_engine=eng)
        self.assertTrue(ran)
        self.assertFalse(any("uuid:" in p for p in problems),
                         f"a uuid: alias was probed as its own domain: {problems}")

    def test_real_eval_probes_policy_declared_services_and_arguments(self):
        """A concrete service, or a specific +argument, that appears in the
        effective policy must be probed — not just the fixed critical list
        (finding R11-1). Feed the derived token set explicitly and prove both an
        unusual service and an argument-specific exception are caught."""
        eng = self._fake_engine(allow_arg_pairs={
            ("kratos-ws-live", "personal", "some.CustomService", "+"),
            ("kratos-ws-live", "personal", "some.ArgService", "+special"),
        })
        services = {("some.CustomService", "+"), ("some.ArgService", "+special")}
        ran, problems = kq.evaluate_with_real_policy(_engine=eng, _services=services)
        self.assertTrue(ran)
        self.assertTrue(any("some.CustomService" in p for p in problems),
                        f"a policy-declared concrete service was not probed: {problems}")
        self.assertTrue(any("some.ArgService+special" in p for p in problems),
                        f"an argument-specific exception was not probed: {problems}")

    def test_build_probe_tokens_expands_wildcard_argument(self):
        """A '*'-argument rule must be probed with both the empty and a concrete
        argument; a '*'-service rule routes through the synthetic unknown."""
        toks = kq._build_probe_tokens({("some.Svc", "*"), ("*", "+zz")})
        self.assertIn(("some.Svc", "+"), toks)
        self.assertIn(("some.Svc", kq._ARG_PROBE), toks)
        self.assertIn((kq._UNKNOWN_SERVICE, "+zz"), toks)
        # Critical services are always present regardless of the policy.
        self.assertIn(("qubes.VMShell", "+"), toks)

    def test_real_eval_probes_special_targets(self):
        """A persona allow to a SPECIAL selector like @default (not a concrete
        domain) must be exercised and reported (finding R12-1): the audit now
        probes @default/@dispvm, not just concrete domains."""
        eng = self._fake_engine(allow_target_pairs={
            ("kratos-ws-live", "@default", "evil.Service"): "personal"})
        services = {("evil.Service", "*")}
        ran, problems = kq.evaluate_with_real_policy(_engine=eng, _services=services)
        self.assertTrue(ran)
        self.assertTrue(any("evil.Service" in p and "@default" in p for p in problems),
                        f"an @default egress exception was not caught: {problems}")

    def test_egress_specials_excludes_policy_matchers(self):
        """Policy-only MATCHERS must never be probed as request targets
        (finding R13-1): @anyvm / @tag:* / @type: raise on real Qubes and would
        fail the whole authoritative audit. Valid intended-target selectors
        (@default, @adminvm, @dispvm, @dispvm:<tmpl>) are kept."""
        s = kq._egress_specials({
            "@anyvm", "@tag:kratos-persona", "@type:AppVM",
            "@dispvm:whonix-ws-18", "@default", "personal"})
        self.assertNotIn("@anyvm", s)
        self.assertFalse(any(x.startswith("@tag:") or x.startswith("@type:") for x in s),
                         f"a policy matcher leaked into the probe targets: {s}")
        self.assertNotIn("personal", s)   # concrete domains are added separately
        self.assertIn("@dispvm:whonix-ws-18", s)
        self.assertIn("@default", s)
        self.assertIn("@adminvm", s)

    def test_real_eval_never_requests_a_policy_matcher_target(self):
        """End-to-end: even if a rule names @anyvm/@tag:/@type:, the evaluator
        must not construct a Request against it. A fake whose Request raises on
        those selectors must still run cleanly (ran=True)."""
        base = self._fake_engine()
        policy, Request, AccessDenied, system_info = base

        class StrictRequest(Request):
            def __init__(self, service, argument, source, target, **kw):
                if target == "@anyvm" or target.startswith("@tag:") or target.startswith("@type:"):
                    raise ValueError(f"{target} is not a valid intended target")
                super().__init__(service, argument, source, target, **kw)

        eng = (policy, StrictRequest, AccessDenied, system_info)
        # Services derived "from the policy" that also carried matcher targets;
        # the matchers must be filtered before any Request is built.
        ran, problems = kq.evaluate_with_real_policy(
            _engine=eng, _services={("some.Svc", "*")})
        self.assertTrue(ran, "evaluator errored — a matcher target was probed")
        self.assertEqual(problems, [])

    def test_real_eval_allows_intended_updatesproxy(self):
        """The ONE legitimate persona egress — qubes.UpdatesProxy resolving to
        sys-whonix via @default — must NOT be reported as a hole (finding R12-1),
        while the same service resolving ELSEWHERE still is."""
        eng = self._fake_engine(allow_target_pairs={
            ("kratos-ws-live", "@default", "qubes.UpdatesProxy"): "sys-whonix"})
        ran, problems = kq.evaluate_with_real_policy(
            _engine=eng, _services={("qubes.UpdatesProxy", "*")})
        self.assertTrue(ran)
        self.assertFalse(any("UpdatesProxy" in p for p in problems),
                         f"intended UpdatesProxy egress wrongly flagged: {problems}")
        # But the same service resolving to a non-sys-whonix target is a hole.
        eng2 = self._fake_engine(allow_target_pairs={
            ("kratos-ws-live", "@default", "qubes.UpdatesProxy"): "personal"})
        ran2, problems2 = kq.evaluate_with_real_policy(
            _engine=eng2, _services={("qubes.UpdatesProxy", "*")})
        self.assertTrue(ran2)
        self.assertTrue(any("UpdatesProxy" in p for p in problems2),
                        f"UpdatesProxy to the wrong target was not flagged: {problems2}")

    def test_rules_service_args_targets_reads_parsed_rules(self):
        """The audit derives its matrix from Qubes' OWN parsed rules, so
        includes/compat are already expanded (finding R12-1). A minimal fake
        policy object exposing .rules must yield its service/argument/target."""
        class R:
            def __init__(self, s, a, t):
                self.service, self.argument, self.target = s, a, t

        class P:
            rules = [R("custom.Svc", "+x", "personal"), R("qubes.UpdatesProxy", "*", "@default")]
        svc_args, targets = kq._rules_service_args_targets(P())
        self.assertIn(("custom.Svc", "+x"), svc_args)
        self.assertIn("@default", targets)

    def test_real_eval_reports_ask_as_path(self):
        eng = self._fake_engine(ask_pairs={
            ("kratos-ws-live", "sys-whonix", "qubes.OpenURL")})
        ran, problems = kq.evaluate_with_real_policy(_engine=eng)
        self.assertTrue(ran)
        self.assertTrue(any("path" in p and "OpenURL" in p for p in problems))

    def test_real_eval_all_deny_is_clean(self):
        ran, problems = kq.evaluate_with_real_policy(_engine=self._fake_engine())
        self.assertTrue(ran)
        self.assertEqual(problems, [])

    def test_real_eval_does_not_pass_none_resolution_types(self):
        """Regression for R8-2: the loop must NOT pass None resolution types
        (which would make the real engine raise on an allow and self-disable).
        A fake that raises when given None must therefore never be triggered —
        the evaluation still runs and finds the allow."""
        eng = self._fake_engine(
            allow_pairs={("kratos-ws-live", "personal", "qubes.Filecopy")},
            raise_on_none_resolution=True)
        ran, problems = kq.evaluate_with_real_policy(_engine=eng)
        self.assertTrue(ran, "evaluator self-disabled (passed None resolution types?)")
        self.assertTrue(any("Filecopy" in p for p in problems))

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
