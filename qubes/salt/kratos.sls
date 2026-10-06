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

# ---- Persona isolation policy into dom0 ----
/etc/qubes/policy.d/30-kratos.policy:
  file.managed:
    - source: salt://kratos/files/30-kratos.policy
    - user: root
    - group: qubes
    - mode: '0664'
    - makedirs: True

# ---- Whonix gateway must exist (shipped by qubes-template-whonix-gateway) ----
kratos-require-whonix:
  cmd.run:
    - name: qvm-check --quiet sys-whonix || echo "install qubes-template-whonix-gateway-17 and create sys-whonix first" >&2
    - stateful: False

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
      - template: whonix-workstation-17
      - template_for_dispvms: True
    - prefs:
      - netvm: sys-whonix
      - default_dispvm: ""
      - autostart: False

# Tag the disposable template (and thus its disposables) as the persona.
kratos-ws-tag:
  cmd.run:
    - name: qvm-tags kratos-ws add kratos-persona
    - require:
      - qvm: kratos-ws-dvm
    - unless: qvm-tags kratos-ws list | grep -qx kratos-persona

# ---- Personal everyday qube (ordinary network path) ----
kratos-personal:
  qvm.vm:
    - name: personal
    - present:
      - label: blue
    - prefs:
      - netvm: sys-firewall
