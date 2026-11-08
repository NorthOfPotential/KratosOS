#!/usr/bin/env bash
# Regenerate the hash-pinned dependency locks that `kratos-ai setup` installs
# Open WebUI from:
#   config/includes.chroot/usr/local/share/kratos/ai/openwebui-cpu.lock
#   config/includes.chroot/usr/local/share/kratos/ai/openwebui-nvidia.lock
#
# Every package (Open WebUI and the ~200 libraries under it) is pinned to one
# version and its SHA256 hashes, so setup installs exactly the files reviewed
# here and pip refuses anything else (a package swapped on PyPI later fails the
# hash check instead of being installed).
#
# The versions it locks come from kratos-ai itself (webui_version, UV_VERSION,
# UV_WHEEL_SHA256) and ai.sh (KRATOS_AI_TORCH_CPU_INDEX), so there is one
# source of truth. Bump webui_version there, run this, review the diff, commit.
#
# Needs Linux x86_64 with python3, python3-venv and network access. Easiest:
#   gh workflow run ci.yml --ref <branch> -f lock_openwebui=true
# then download the "openwebui-locks" artifact from that run.
#
# Usage: tools/lock-openwebui.sh [OUTPUT_DIR]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
inc="$here/../config/includes.chroot"
ai="$inc/usr/local/bin/kratos-ai"
ailib="$inc/usr/local/lib/kratos/ai.sh"
out="${1:-$inc/usr/local/share/kratos/ai}"

die() { echo "lock-openwebui: $*" >&2; exit 1; }

uv_version="$(sed -n 's/^UV_VERSION="\([^"]*\)"$/\1/p' "$ai")"
uv_sha="$(sed -n 's/^UV_WHEEL_SHA256="\([0-9a-f]*\)"$/\1/p' "$ai")"
webui="$(sed -n 's/^[[:space:]]*local webui_version="\([^"]*\)".*/\1/p' "$ai")"
# shellcheck disable=SC2016  # a literal ${ in the sed pattern, not an expansion
cpu_index="$(sed -n 's/^: "\${KRATOS_AI_TORCH_CPU_INDEX:=\(https:[^}]*\)}"$/\1/p' "$ailib")"
[[ -n "$uv_version" && ${#uv_sha} -eq 64 ]] || die "could not read the uv pin from $ai"
[[ -n "$webui" ]] || die "could not read webui_version from $ai"
[[ -n "$cpu_index" ]] || die "could not read KRATOS_AI_TORCH_CPU_INDEX from $ailib"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# uv, installed from the same hash-pinned wheel kratos-ai uses.
python3 -m venv "$work/venv"
printf 'uv==%s --hash=sha256:%s\n' "$uv_version" "$uv_sha" > "$work/uv.txt"
"$work/venv/bin/pip" install --quiet --no-cache-dir --require-hashes --no-deps \
    --only-binary=:all: -r "$work/uv.txt"
uv="$work/venv/bin/uv"

mkdir -p "$out"
out="$(cd "$out" && pwd)"    # absolute: lock() compiles from a temp dir

# lock <variant> <extra pyproject text>
lock() {
    local variant=$1 extra=$2 d="$work/$1"
    mkdir -p "$d"
    cat > "$d/pyproject.toml" <<EOF
[project]
name = "kratos-openwebui-$variant"
version = "0"
requires-python = "==3.12.*"
dependencies = ["open-webui==$webui"$( [[ "$variant" == cpu ]] && printf ', "torch"' )]
$extra
EOF
    # Open WebUI runs on an app-private CPython 3.12 (see kratos-ai); the
    # target is Debian 13 x86_64 (glibc 2.41, so manylinux_2_28 wheels and
    # older all qualify). Wheels only: building an sdist would fetch build
    # tools that no hash covers.
    ( cd "$d" && UV_CACHE_DIR="$work/cache" "$uv" pip compile pyproject.toml \
        --python-version 3.12 --python-platform x86_64-manylinux_2_28 \
        --generate-hashes --only-binary :all: \
        --custom-compile-command "tools/lock-openwebui.sh" \
        -o "$out/openwebui-$variant.lock" )
    grep -qxF "open-webui==$webui \\" "$out/openwebui-$variant.lock" \
        || die "$variant lock does not pin open-webui==$webui"
}

# No NVIDIA GPU: PyTorch's CPU-only build from PyTorch's own index, and only
# torch from there ("explicit"); everything else comes from PyPI.
lock cpu "
[tool.uv.sources]
torch = { index = \"pytorch-cpu\" }

[[tool.uv.index]]
name = \"pytorch-cpu\"
url = \"$cpu_index\"
explicit = true"
grep -Eq '^torch==[^ ]+\+cpu \\$' "$out/openwebui-cpu.lock" \
    || die "the CPU lock did not pick PyTorch's CPU-only build"

# NVIDIA GPU: the regular PyPI torch (with its CUDA libraries).
lock nvidia ""

echo "lock-openwebui: wrote $out/openwebui-cpu.lock and $out/openwebui-nvidia.lock (open-webui $webui)"
