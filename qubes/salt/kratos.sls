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

# ---- The selected Whonix WORKSTATION template must exist (finding R6-H9) ----
# Don't silently build the persona DispVM template against a missing/unsupported
# Whonix version. Fail loudly and name the pillar override if the template for
# the configured version isn't installed, so a stale default can't quietly pin
# the persona to an absent (or EOL) template.
kratos-require-ws-template:
  cmd.run:
    - name: 'qvm-check --quiet {{ whonix_ws }} || { echo "ERROR: template {{ whonix_ws }} is not installed. Install the Whonix workstation template for your Qubes release, or set the kratos:whonix_version pillar to the version you actually have, then re-apply." >&2; exit 1; }'

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
    # selected Whonix workstation template are both present.
    - require:
      - cmd: kratos-require-whonix
      - cmd: kratos-require-ws-template

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
