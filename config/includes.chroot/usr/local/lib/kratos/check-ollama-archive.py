#!/usr/bin/env python3
"""Fail closed on unsafe Ollama release tar entries before root extraction.

This checks *all* headers (not a grep -q pipeline vulnerable to SIGPIPE) and
allows only regular files, directories and relative symlinks confined to the
install root. Even a SHA256-verified tarball needs this defense: transport
integrity does not guarantee all archive entries are extraction-safe.
"""
import posixpath
import sys
import tarfile


class UnsafeArchive(ValueError):
    pass


def validate(archive_path):
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            name = member.name
            # A member with '..' is rejected even if normalization happens to
            # place it back under the root: there is no legitimate need for it.
            if (not name or posixpath.isabs(name) or ".." in name.split("/")
                    or "\x00" in name):
                raise UnsafeArchive(f"unsafe member path: {name!r}")
            if not (member.isfile() or member.isdir() or member.issym()):
                raise UnsafeArchive(f"unsafe member type: {name!r}")
            if member.issym():
                link = member.linkname
                if not link or posixpath.isabs(link) or "\x00" in link:
                    raise UnsafeArchive(f"unsafe symlink: {name!r} -> {link!r}")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), link))
                if resolved == ".." or resolved.startswith("../") or resolved.startswith("/"):
                    raise UnsafeArchive(f"symlink escapes /usr/local: {name!r} -> {link!r}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: check-ollama-archive.py <archive.tgz>")
    try:
        validate(sys.argv[1])
    except (UnsafeArchive, tarfile.TarError, OSError) as exc:
        sys.exit(f"unsafe Ollama archive: {exc}")
