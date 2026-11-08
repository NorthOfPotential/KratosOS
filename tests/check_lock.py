"""Check a hash-pinned pip requirements lock (tools/lock-openwebui.sh output).

Every requirement must be exactly `name==version \\` followed by one or more
`--hash=sha256:<64 hex>` lines. Anything else (a range, a URL, a VCS or
editable install, an option or index line, an entry without a hash) fails.
Prints the number of packages; exits 1 on any violation.
"""
import re
import sys

REQ = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*==[A-Za-z0-9.+!_-]+ \\")
HASH = re.compile(r"\s+--hash=sha256:[0-9a-f]{64}( \\)?")


def main(path):
    bad, pkgs, cur, hashes = [], 0, None, 0
    for line in open(path, encoding="utf-8").read().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[0].isspace():
            if cur is not None and HASH.fullmatch(line):
                hashes += 1
            else:
                bad.append(line.strip())
            continue
        if cur is not None and hashes == 0:
            bad.append(cur + " (no hash)")
        if not REQ.fullmatch(line):
            bad.append(line)
        cur, hashes = line, 0
        pkgs += 1
    if cur is not None and hashes == 0:
        bad.append(cur + " (no hash)")
    if bad:
        print("; ".join(bad[:5]))
        return 1
    print(pkgs)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
