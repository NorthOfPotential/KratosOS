#!/usr/bin/env bash
# shellcheck disable=SC1091
# A WireGuard config is DATA. wg_validate must reject any file that could make
# wg-quick run commands as root (PreUp/PostUp/PreDown/PostDown) or otherwise
# step outside plain WireGuard settings (Table/SaveConfig), and accept a normal
# provider config.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/../config/includes.chroot/usr/local/lib/kratos"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export KRATOS_ETC="$tmp/etc" KRATOS_RUN="$tmp/run" KRATOS_STATE="$tmp/state" KRATOS_LIB="$lib"
# shellcheck source=/dev/null
. "$lib/common.sh"; . "$lib/net.sh"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# The exact exploit the reviewer called out.
cat > "$tmp/evil.conf" <<'EOF'
[Interface]
PrivateKey = aAaA
Address = 10.0.0.2/32
PostUp = touch /root/KRATOS_PWNED
[Peer]
PublicKey = bBbB
Endpoint = 198.51.100.7:51820
AllowedIPs = 0.0.0.0/0
EOF
if wg_validate "$tmp/evil.conf" 2>/dev/null; then
    flunk "ACCEPTED a config with PostUp (root command execution!)"
else
    pass "rejects PostUp (no root command execution)"
fi

for k in PreUp PreDown PostDown Table SaveConfig; do
    printf '[Interface]\nPrivateKey = a\n%s = whatever\n[Peer]\nPublicKey = b\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n' "$k" > "$tmp/one.conf"
    if wg_validate "$tmp/one.conf" 2>/dev/null; then flunk "ACCEPTED forbidden directive $k"; else pass "rejects $k"; fi
done

# A normal provider config must still import cleanly.
cat > "$tmp/good.conf" <<'EOF'
[Interface]
PrivateKey = SOMEKEY=
Address = 10.66.66.2/32
DNS = 10.66.66.1
[Peer]
PublicKey = PUBKEY=
PresharedKey = PSK=
Endpoint = 198.51.100.7:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
if wg_validate "$tmp/good.conf" 2>/dev/null; then
    pass "accepts a normal WireGuard provider config"
else
    flunk "rejected a clean WireGuard config"
fi

echo
if (( fail )); then echo "WG VALIDATION TESTS FAILED"; exit 1; else echo "WireGuard import is injection-safe"; exit 0; fi
