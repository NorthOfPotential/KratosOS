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

# The installed Whonix major version. Qubes 4.2 ships Whonix 17; when Qubes
# moves to a newer Whonix, override this once at the top instead of editing
# every template name below. A pillar value (kratos:whonix_version) wins if set.
{% set whonix_version = salt['pillar.get']('kratos:whonix_version', '17') %}
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
    - present:
      - label: red
      - template: {{ whonix_ws }}
      - template_for_dispvms: True
    - prefs:
      - netvm: sys-whonix
      - default_dispvm: ""
      - autostart: False
    # Don't build the persona workstation unless its Tor gateway is present.
    - require:
      - cmd: kratos-require-whonix

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
