#!/usr/bin/env python3
"""Fail closed on unsafe Ollama release tar entries before root extraction.

This checks *all* headers (not a grep -q pipeline vulnerable to SIGPIPE) and
allows only regular files, directories and relative symlinks confined to the
install root. Even a SHA256-verified tarball needs this defense: transport
integrity does not guarantee all archive entries are extraction-safe.
"""
import posixpath
import subprocess
import sys
import tarfile


class UnsafeArchive(ValueError):
    pass


# The archive is unpacked as root into /usr/local, which also holds KratosOS's
# own privileged tools (/usr/local/bin/kratos*, /usr/local/lib/kratos/). The
# official Ollama layout is exactly bin/ollama + lib/ollama/**, so anything else
# — even a perfectly "relative" path like bin/kratos — is refused: a release
# (or a compromised pin) must never be able to overwrite KratosOS itself.
_LIB = "lib/ollama/"
_ALLOWED_DIRS = {"bin", "lib", "lib/ollama"}


def _norm(name):
    while name.startswith("./"):
        name = name[2:]
    return name.rstrip("/")


def _allowed_path(path, is_dir):
    if is_dir:
        return path in _ALLOWED_DIRS or path.startswith(_LIB)
    return path == "bin/ollama" or path.startswith(_LIB)


def _check_members(archive):
    for member in archive:
        raw = member.name
        # A member with '..' is rejected even if normalization happens to
        # place it back under the root: there is no legitimate need for it.
        if (not raw or posixpath.isabs(raw) or ".." in raw.split("/")
                or "\x00" in raw):
            raise UnsafeArchive(f"unsafe member path: {raw!r}")
        if not (member.isfile() or member.isdir() or member.issym()):
            raise UnsafeArchive(f"unsafe member type: {raw!r}")
        name = _norm(raw)
        if not name or not _allowed_path(name, member.isdir()):
            raise UnsafeArchive(f"member outside the Ollama layout: {raw!r}")
        # setuid/setgid/sticky would survive a root extraction; Ollama needs none.
        if member.mode & 0o7000:
            raise UnsafeArchive(f"setuid/setgid/sticky bit on member: {raw!r}")
        if member.issym():
            link = member.linkname
            if not link or posixpath.isabs(link) or "\x00" in link:
                raise UnsafeArchive(f"unsafe symlink: {raw!r} -> {link!r}")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), link))
            if not (name.startswith(_LIB) and resolved.startswith(_LIB)):
                raise UnsafeArchive(f"symlink leaves lib/ollama/: {raw!r} -> {link!r}")


def validate(archive_path):
    # Current Ollama release bundles are large tar.zst files, not old .tgz.
    # Stream decoding to avoid a second multi-GB uncompressed disk copy; every
    # tar header is still examined before ANY root extraction takes place.
    if str(archive_path).endswith(".tar.zst"):
        with subprocess.Popen(["zstd", "-dc", "--", str(archive_path)],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as proc:
            try:
                with tarfile.open(fileobj=proc.stdout, mode="r|") as archive:
                    _check_members(archive)
            finally:
                proc.stdout.close()
            if proc.wait() != 0:
                raise UnsafeArchive("zstd archive failed decompression")
    elif str(archive_path).endswith(".tgz"):
        with tarfile.open(archive_path, "r:gz") as archive:
            _check_members(archive)
    else:
        raise UnsafeArchive("unsupported archive extension: only .tar.zst/.tgz")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check-ollama-archive.py <archive.tar.zst|archive.tgz>")
    try:
        validate(sys.argv[1])
    except (UnsafeArchive, tarfile.TarError, OSError) as exc:
        sys.exit(f"unsafe Ollama archive: {exc}")
