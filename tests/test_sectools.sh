#!/usr/bin/env bash
# shellcheck disable=SC2015
# Validate the KratosOS security toolset: the catalog is well-formed, the menu
# generator produces a valid XDG menu and valid .desktop launchers, and the
# custom helper tools are present and parse.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
inc="$here/../config/includes.chroot"
lib="$inc/usr/local/lib/kratos"
tsv="$inc/usr/share/kratos-assets/sectools.tsv"
fail=0
pass() { echo "  PASS  $1"; }
flunk() { echo "  FAIL  $1"; fail=1; }

# ── Catalog format: every non-comment row has >=7 tab-separated fields and a
#    known Menu / Kind ─────────────────────────────────────────────────────
badrows="$(awk -F'\t' '
    /^#/ || /^[[:space:]]*$/ { next }
    { if (NF < 7) { print "fields:" NR; next }
      m=$1; k=$5
      if (m!="Recon"&&m!="Scanning"&&m!="Web"&&m!="Wireless"&&m!="Passwords"&&m!="Sniffing"&&m!="Forensics"&&m!="RevEng"&&m!="Exploitation"&&m!="Anonymity"&&m!="Logging"&&m!="Scripting") print "menu:" NR
      if (k!="cli"&&k!="gui") print "kind:" NR }
' "$tsv")"
if [[ -z "$badrows" ]]; then
    pass "catalog rows are well-formed (7 fields, known Menu + Kind)"
else
    flunk "catalog has malformed rows: $badrows"
fi
nrows="$(awk -F'\t' '!/^#/ && NF>=7 {n++} END{print n+0}' "$tsv")"
[[ "$nrows" -ge 50 ]] && pass "catalog lists $nrows tools" || flunk "catalog unexpectedly small ($nrows)"

# ── Generator produces a well-formed menu + valid .desktop files ───────────
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
mkdir -p "$out/apps" "$out/dirs" "$out/menu"
if bash "$lib/sectools-gen" --tsv "$tsv" --appdir "$out/apps" --dirdir "$out/dirs" \
        --menufile "$out/menu/kratos-security.menu" >/dev/null 2>&1; then
    pass "sectools-gen ran"
else
    flunk "sectools-gen failed"
fi
if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('$out/menu/kratos-security.menu')" 2>/dev/null; then
    pass "generated applications-merged menu is well-formed XML"
else
    flunk "generated menu is not well-formed XML"
fi
if python3 - "$out/apps" <<'PY'
import configparser, glob, os, sys
d=sys.argv[1]; bad=0; n=0
for f in glob.glob(os.path.join(d,'*.desktop')):
    n+=1
    c=configparser.ConfigParser(interpolation=None)
    try:
        c.read(f); e=c['Desktop Entry']
        for k in ('Type','Name','Exec','Categories'):
            assert k in e, f'{k} missing in {f}'
        assert e['Categories'].startswith('X-Kratos-'), f
    except Exception as ex:
        print(ex); bad+=1
sys.exit(1 if (bad or n==0) else 0)
PY
then
    pass "every generated .desktop is valid and categorised under X-Kratos-*"
else
    flunk "a generated .desktop is invalid"
fi

# Each submenu referenced in the menu has a matching .directory file.
missing_dir=0
while read -r d; do
    [[ -f "$out/dirs/$d" ]] || { echo "    missing $d"; missing_dir=1; }
done < <(grep -oE '<Directory>[^<]+</Directory>' "$out/menu/kratos-security.menu" | sed 's/<[^>]*>//g' | sort -u)
(( missing_dir == 0 )) && pass "every menu <Directory> has a .directory file" \
                       || flunk "a menu references a missing .directory"

# ── Custom helper tools present + parse ────────────────────────────────────
for t in sec-shell sectools-gen; do
    bash -n "$lib/$t" 2>/dev/null && : || { flunk "$t has a syntax error"; }
done
for t in kratos-logwatch kratos-runscript kratos-sec; do
    [[ -x "$inc/usr/local/bin/$t" ]] && bash -n "$inc/usr/local/bin/$t" 2>/dev/null \
        || { flunk "$t missing or has a syntax error"; }
done
pass "custom security helpers (sec-shell, logwatch, runscript, kratos-sec) parse"

# ── Install hook wires the catalog + generator ─────────────────────────────
hook="$here/../config/hooks/live/0090-kratos-sectools.hook.chroot"
if grep -q 'sectools-gen --check-binaries' "$hook" && grep -q 'sectools.tsv' "$hook"; then
    pass "build hook installs tools and generates the menu"
else
    flunk "build hook does not wire the catalog/generator"
fi

echo
if (( fail )); then echo "SECTOOLS TESTS FAILED"; exit 1; else echo "security toolset OK"; exit 0; fi
