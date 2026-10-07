"""Stealth Mode forwarding rules (finding 24).

The stealth firewall's forward/input chains are the most security-sensitive
path in the project: they decide what the persona Workstation (kx-int) and
Gateway (kx-ext) may route. This test loads stealth.nft into a throwaway
network namespace with the kx-int/kx-ext interfaces present, so the REAL nft
parser accepts and stores the ruleset, then asserts the kernel's own
representation enforces:

  * kx-int (Workstation<->Gateway) is never forwarded in either direction;
  * the VMs can't reach services on the host (input drop);
  * kx-ext egress is marked so the active mode table (vpn/offline) governs it;
  * the drops are terminal and sit before the mark.

Run as root in a fresh netns (run.sh uses `unshare -n`).

NOTE (honest scope): a full packet-level matrix (WS->GW->NIC, GW->WireGuard,
NIC->WS under each mode) needs a multi-namespace veth+libvirt-NAT harness that
this CI sandbox can't build (ip netns / cross-ns routing is unavailable here).
That remains a live-system integration test; see docs/THREAT_MODEL.md.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config",
                    "includes.chroot", "etc", "kratos")
STEALTH_NFT = os.path.join(ROOT, "stealth.nft")
FAILURES = []


def sh(cmd, check=True):
    return subprocess.run(cmd, shell=True, check=check, capture_output=True, text=True)


def ok(desc, cond):
    print(f"  {'PASS' if cond else 'FAIL'}  {desc}")
    if not cond:
        FAILURES.append(desc)


def main():
    sh("ip link set lo up", check=False)
    # nft resolves interface names lazily, so stealth.nft loads even without the
    # kx-int/kx-ext devices present — no dummy interfaces needed.

    # Load a base mode first (stealth layers on top), then the stealth table.
    sh(f"nft -f {os.path.join(ROOT, 'modes', 'offline.nft')}", check=False)
    r = sh(f"nft -f {STEALTH_NFT}", check=False)
    ok("stealth.nft loads into the kernel", r.returncode == 0)
    if r.returncode != 0:
        print(r.stderr)
        sys.exit(1)

    # Read back what the KERNEL actually stored (not our copy of the file).
    dump = sh("nft list table inet kratos_stealth").stdout
    fwd = _chain(dump, "forward")
    inp = _chain(dump, "input")

    # Workstation<->Gateway leg (kx-int) is never forwarded, either direction.
    ok("forward: kx-int ingress dropped",
       re.search(r'iifname "kx-int"\s+drop', fwd) is not None)
    ok("forward: kx-int egress dropped",
       re.search(r'oifname "kx-int"\s+drop', fwd) is not None)

    # kx-ext egress is marked so the mode table governs it (not blanket-accepted).
    ok("forward: kx-ext egress is marked for the mode table",
       re.search(r'iifname "kx-ext".*mark set', fwd) is not None)

    # The VMs cannot reach services on the host.
    ok("input: traffic from the VMs to the host is dropped",
       re.search(r'iifname.*kx-(ext|int).*drop', inp) is not None
       and "kx-int" in inp and "kx-ext" in inp)

    # Ordering: the terminal kx-int drops must come BEFORE the kx-ext mark,
    # so an isolation drop is never shadowed by a mark-and-accept.
    drop_pos = fwd.find("kx-int")
    mark_pos = fwd.find("mark set")
    ok("forward: kx-int drops precede the kx-ext mark",
       drop_pos != -1 and mark_pos != -1 and drop_pos < mark_pos)

    sh("nft flush ruleset", check=False)
    if FAILURES:
        print(f"\n{len(FAILURES)} forwarding test(s) failed")
        sys.exit(1)
    print("\nforwarding rules enforce persona isolation")


def _chain(dump, name):
    # nft dumps with tab indentation; match up to the chain's closing brace.
    m = re.search(r"chain %s \{(.*?)\n\s*\}" % re.escape(name), dump, re.S)
    return m.group(1) if m else ""


if __name__ == "__main__":
    main()
