# KratosOS-on-Qubes provisioning (Salt, runs in dom0).
#
#   sudo qubesctl --show-output state.apply kratos saltenv=user
#
# Builds the compartment layout KratosOS wants, but with Qubes/Xen as the
# isolation boundary instead of one Linux kernel:
#
#   personal   (AppVM, netvm sys-firewall)   - everyday use
#   vault      (AppVM, no network)           - persona secrets (KeePassXC)
#   sys-whonix (Whonix gateway)              - Tor for the persona
#   kratos-ws  (disposable template, netvm sys-whonix, tagged kratos-persona)
#
# Stealth Mode then launches a *disposable* qube from kratos-ws, so the
# persona workstation is amnesic by construction. The 30-kratos.policy file
# (installed below) blocks clipboard/file/RPC out of anything tagged
# kratos-persona.

# The installed Whonix major version, overridable via the pillar
# (kratos:whonix_version) so you don't edit every template name below.
#
# Default is 18 (finding R6-H9): current stable Qubes (4.3) ships Whonix 18
# (whonix-gateway-18 / whonix-workstation-18); Qubes 4.2 / Whonix 17 is EOL. On
# an older install, set the pillar to the version your Qubes actually has:
#     qubesctl --show-output state.apply kratos saltenv=user \
#         pillar='{"kratos": {"whonix_version": "17"}}'
# We don't auto-pick the "highest installed" template, because only certain
# Qubes/Whonix pairings are supported; the kratos-require-ws-template check
# below fails the run loudly if the selected template isn't actually present,
# rather than silently building against a missing/unsupported one. (Using
# upstream Qubes version discovery is tracked as further follow-up.)
{% set whonix_version = salt['pillar.get']('kratos:whonix_version', '18') %}
{% set whonix_ws = 'whonix-workstation-' ~ whonix_version %}
{% set whonix_gw_template = 'qubes-template-whonix-gateway-' ~ whonix_version %}

# ---- Persona isolation policy into dom0 ----
/etc/qubes/policy.d/30-kratos.policy:
  file.managed:
    - source: salt://kratos/files/30-kratos.policy
    - user: root
    - group: qubes
    # 0644: world-readable (qrexec needs it) but NOT group-writable — the policy
    # is the persona's containment boundary, so only root may rewrite it.
    - mode: '0644'
    - makedirs: True

# ---- Whonix gateway must exist (shipped by qubes-template-whonix-gateway) ----
# Fail the run (don't just warn) if sys-whonix is absent: the persona
# workstation below routes through it, so provisioning without it would build a
# workstation with no Tor gateway. qvm-check is read-only, so this is safe to
# re-run; a non-zero exit makes Salt stop before creating the workstation.
kratos-require-whonix:
  cmd.run:
    - name: 'qvm-check --quiet sys-whonix || { echo "ERROR: sys-whonix not found; install {{ whonix_gw_template }} and create the sys-whonix gateway, then re-apply." >&2; exit 1; }'

# ---- sys-whonix must be the MATCHING Whonix GATEWAY generation (finding R8) ----
# Don't allow a stale mixed-generation system (e.g. Workstation 18 on a Gateway
# 17). Require sys-whonix's template to be whonix-gateway-<same version> as the
# workstation selection.
kratos-require-gw-version:
  cmd.run:
    - name: '[ "$(qvm-prefs sys-whonix template)" = "whonix-gateway-{{ whonix_version }}" ] || { echo "ERROR: sys-whonix is based on $(qvm-prefs sys-whonix template), not whonix-gateway-{{ whonix_version }}. Rebuild sys-whonix on the matching Whonix generation (or set the kratos:whonix_version pillar to the version you actually run), then re-apply." >&2; exit 1; }'
    - require:
      - cmd: kratos-require-whonix

# ---- The selected Whonix WORKSTATION template must exist (finding R6-H9) ----
# Don't silently build the persona DispVM template against a missing/unsupported
# Whonix version. Fail loudly and name the pillar override if the template for
# the configured version isn't installed, so a stale default can't quietly pin
# the persona to an absent (or EOL) template.
kratos-require-ws-template:
  cmd.run:
    - name: 'qvm-check --quiet {{ whonix_ws }} || { echo "ERROR: template {{ whonix_ws }} is not installed. Install the Whonix workstation template for your Qubes release, or set the kratos:whonix_version pillar to the version you actually have, then re-apply." >&2; exit 1; }'

# ---- If kratos-ws ALREADY exists, it MUST be based on the Whonix workstation
#      template (finding R8-4). qvm.vm `present` does NOT recreate an existing
#      qube, so a pre-existing kratos-ws on a non-Whonix base (e.g. debian-13)
#      would otherwise be pinned to sys-whonix + tagged persona while NOT being
#      a Whonix Workstation. Fail loudly instead of silently mis-provisioning.
kratos-ws-template-must-match:
  cmd.run:
    - name: '! qvm-check --quiet kratos-ws || [ "$(qvm-prefs kratos-ws template)" = "{{ whonix_ws }}" ] || { echo "ERROR: existing kratos-ws is based on $(qvm-prefs kratos-ws template), not {{ whonix_ws }}. Remove it (qvm-remove kratos-ws) and re-apply so it is rebuilt on the correct Whonix template." >&2; exit 1; }'
    - require:
      - cmd: kratos-require-ws-template

# ---- Record the provisioned Whonix generation for the audit (finding R9-6) ----
# `kratos-q audit` reads this file so its expected Whonix version is the SAME
# value provisioning built against — one source of truth, instead of a separate
# KRATOS_WHONIX_VERSION the operator must remember to keep in sync. An explicit
# KRATOS_WHONIX_VERSION env var still overrides it at audit time.
#
# It REQUIRES the gateway+workstation version checks (finding R10-8): the file
# must record the version that actually CONVERGED, not one a failed provisioning
# attempt merely requested. If the selected templates aren't present, those
# checks fail first and this file is never (re)written — so the audit can't be
# left expecting a version the machine was never provisioned to.
/etc/kratos-q/whonix-version:
  file.managed:
    - contents: '{{ whonix_version }}'
    - user: root
    - group: qubes
    - mode: '0644'
    - makedirs: True
    - require:
      - cmd: kratos-require-gw-version
      - cmd: kratos-require-ws-template
      - cmd: kratos-ws-template-must-match

# ---- Vault qube: persona secrets, no network ever ----
kratos-vault:
  qvm.vm:
    - name: vault
    - present:
      - label: black
    - prefs:
      - netvm: ""
      - autostart: False

# ---- Disposable template for the persona workstation ----
kratos-ws-dvm:
  qvm.vm:
    - name: kratos-ws
    # `present` only accepts CREATION options (template, label, class, memory,
    # vcpus, ...). template_for_dispvms is a VM PREFERENCE, not a creation arg
    # (finding R6-H8): the upstream qvm.create parser would reject it here, so
    # kratos-ws would never actually become a DispVM template and
    # `qvm-create --class DispVM --template kratos-ws` would fail. Set it in
    # prefs, matching the upstream Qubes formula.
    - present:
      - label: red
      - template: {{ whonix_ws }}
    - prefs:
      - netvm: sys-whonix
      - template_for_dispvms: True
      - default_dispvm: ""
      - autostart: False
    # Don't build the persona workstation unless its Tor gateway AND the
    # selected Whonix workstation template are present, AND any existing
    # kratos-ws is already on the correct template.
    - require:
      - cmd: kratos-require-whonix
      - cmd: kratos-require-gw-version
      - cmd: kratos-require-ws-template
      - cmd: kratos-ws-template-must-match

# Tag the disposable template (and thus its disposables) as the persona, using
# the official qvm.tags state — idempotent, and no shelling out to qvm-tags.
kratos-ws-tag:
  qvm.tags:
    - name: kratos-ws
    - add:
      - kratos-persona
    - require:
      - qvm: kratos-ws-dvm

# ---- Personal everyday qube (ordinary network path) ----
kratos-personal:
  qvm.vm:
    - name: personal
    - present:
      - label: blue
    - prefs:
      - netvm: sys-firewall
