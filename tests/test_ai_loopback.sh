#!/usr/bin/env bash
# /etc/kratos/ai-loopback.nft: only root, people's accounts (uid 1000-59999)
# and the ollama / kratos-ai service accounts may connect to Ollama's
# unauthenticated API on 127.0.0.1:11434; any other account is reset.
# Run as root inside a throwaway network namespace (tests/run.sh uses
# `unshare -n`), with the users ollama, kratos-ai, mallory (uid >= 1000) and
# kratos-nym (a system account) present (CI creates them).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
inc="$here/../config/includes.chroot"
rules="$inc/etc/kratos/ai-loopback.nft"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

for u in ollama kratos-ai mallory kratos-nym; do
    getent passwd "$u" >/dev/null || { flunk "test user $u missing (CI creates it)"; exit 1; }
done
(( $(id -u mallory) >= 1000 && $(id -u kratos-nym) < 1000 )) \
    || { flunk "mallory must be a person account and kratos-nym a system account"; exit 1; }

ip link set lo up
if nft -f "$rules" && nft -f "$rules"; then pass "ai-loopback.nft loads (and reloads)"
else flunk "ai-loopback.nft does not load"; exit 1; fi

# Listeners for Ollama's port and an unrelated port.
python3 - <<'PY' &
import socket, threading
def serve(port):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(16)
    while True:
        c, _ = s.accept(); c.close()
for p in (11434, 18080):
    threading.Thread(target=serve, args=(p,), daemon=True).start()
threading.Event().wait()
PY
srv=$!
trap 'kill "$srv" 2>/dev/null' EXIT
for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/18080) 2>/dev/null && break; sleep 0.1; done

connects() {  # <user|root> <port>
    local probe='import socket,sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3).close()
except OSError:
    sys.exit(1)'
    if [[ "$1" == root ]]; then (cd / && python3 -c "$probe" "$2")
    else (cd / && runuser -u "$1" -- python3 -c "$probe" "$2"); fi
}

for u in root ollama kratos-ai mallory; do
    if connects "$u" 11434; then pass "$u may reach Ollama's port"
    else flunk "$u was refused on Ollama's port"; fi
done
if connects kratos-nym 11434; then flunk "system account kratos-nym reached Ollama's unauthenticated API"
else pass "other system accounts are refused on Ollama's port"; fi
if connects kratos-nym 18080; then pass "the rule is specific to Ollama's port (other loopback ports unaffected)"
else flunk "kratos-nym was refused on an unrelated loopback port"; fi

# Network-mode switches replace "inet kratos" only; this table must survive.
if nft -f "$inc/etc/kratos/modes/normal.nft" && nft list table inet kratos_ai >/dev/null 2>&1 \
   && ! connects kratos-nym 11434; then
    pass "still enforced after a network-mode switch"
else
    flunk "a mode switch removed the Ollama port rule"
fi

svc="$inc/etc/systemd/system/kratos-firewall.service"
if grep -qx 'ExecStartPost=-/usr/sbin/nft -f /etc/kratos/ai-loopback.nft' "$svc"; then
    pass "kratos-firewall.service loads it at boot (a failure can't block networking)"
else
    flunk "ai-loopback.nft is not loaded at boot"
fi
hook="$here/../config/hooks/live/0100-kratos.hook.chroot"
if grep -q 'useradd --system --home-dir /var/lib/kratos/ai/models --shell /usr/sbin/nologin -g ollama ollama' "$hook" \
   && grep -q 'useradd --system --home-dir /opt/kratos-ai --shell /usr/sbin/nologin -g kratos-ai kratos-ai' "$hook"; then
    pass "the image creates both service accounts (the table's names resolve from first boot)"
else
    flunk "service accounts are not in the image; the table would fail to load until kratos-ai setup"
fi

exit "$fail"
