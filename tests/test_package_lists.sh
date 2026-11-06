#!/usr/bin/env bash
# live-build treats every whitespace-separated word on a non-comment line of a
# package list as a package name, so a trailing "# comment" turns into
# "Unable to locate package #" and fails the ISO build (CI run #239). Comments
# must sit on their own line; each package line must be a plain package name.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
for f in "$here"/../config/package-lists/*.list*; do
    n=0; name="$(basename "$f")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[a-z0-9][a-z0-9+.:-]*$ ]]; then
            echo "  FAIL  $name:$n is not a single package name: $line"
            fail=1
        fi
    done < "$f"
done
(( fail )) || echo "  PASS  package lists contain only package names and full-line comments"
exit "$fail"
