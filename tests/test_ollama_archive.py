"""Regression tests for hostile-but-checksummed Ollama release tarballs."""
import importlib.util
import io
import pathlib
import subprocess
import tarfile
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[1] / (
    "config/includes.chroot/usr/local/lib/kratos/check-ollama-archive.py"
)
spec = importlib.util.spec_from_file_location("check_ollama_archive", SOURCE)
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class OllamaArchiveTests(unittest.TestCase):
    def check(self, members, should_pass):
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / "release.tgz"
            with tarfile.open(path, "w:gz") as tf:
                for entry in members:
                    name, kind, target = entry[:3]
                    member = tarfile.TarInfo(name)
                    if len(entry) > 3:
                        member.mode = entry[3]
                    if kind == "file":
                        member.size = 1
                        tf.addfile(member, io.BytesIO(b"x"))
                    elif kind == "dir":
                        member.type = tarfile.DIRTYPE
                        tf.addfile(member)
                    elif kind == "link":
                        member.type = tarfile.SYMTYPE
                        member.linkname = target
                        tf.addfile(member)
                    elif kind == "hardlink":
                        member.type = tarfile.LNKTYPE
                        member.linkname = target
                        tf.addfile(member)
                    elif kind == "device":
                        member.type = tarfile.CHRTYPE
                        tf.addfile(member)
            if should_pass:
                validator.validate(path)
            else:
                with self.assertRaises(validator.UnsafeArchive):
                    validator.validate(path)

    def test_expected_vendor_layout(self):
        self.check([
            ("bin/", "dir", ""),
            ("bin/ollama", "file", ""),
            ("lib/ollama/", "dir", ""),
            ("lib/ollama/libcuda.so.1", "file", ""),
            ("lib/ollama/libcuda.so", "link", "libcuda.so.1"),
        ], True)

    def test_absolute_member_refused(self):
        self.check([("/etc/sudoers.d/evil", "file", "")], False)

    def test_parent_path_refused(self):
        self.check([("lib/../../../etc/evil", "file", "")], False)

    def test_symlink_escape_refused(self):
        self.check([("lib/ollama/escape", "link", "../../../etc")], False)

    def test_absolute_symlink_refused(self):
        self.check([("lib/ollama/escape", "link", "/etc")], False)

    def test_hardlinks_refused(self):
        self.check([("bin/ollama", "hardlink", "lib/ollama/other")], False)

    def test_devices_refused(self):
        self.check([("bin/odd", "device", "")], False)

    def test_dot_slash_prefixed_layout_ok(self):
        self.check([("./bin/ollama", "file", ""), ("./lib/ollama/x.so", "file", "")], True)

    def test_cannot_overwrite_kratos_cli(self):
        # A "relative", traversal-free path that would clobber KratosOS's own
        # root tool in /usr/local/bin. Must be refused by the layout allowlist.
        self.check([("bin/kratos", "file", "")], False)

    def test_cannot_overwrite_kratos_libs(self):
        self.check([("lib/kratos/common.sh", "file", "")], False)

    def test_unexpected_top_level_refused(self):
        self.check([("etc/profile.d/evil.sh", "file", "")], False)

    def test_setuid_member_refused(self):
        self.check([("bin/ollama", "file", "", 0o4755)], False)

    def test_setgid_member_refused(self):
        self.check([("lib/ollama/x.so", "file", "", 0o2755)], False)

    def test_symlink_outside_lib_refused(self):
        # Even a link that stays inside /usr/local is refused outside lib/ollama/.
        self.check([("bin/ollama", "link", "../lib/ollama/real")], False)

    def test_symlink_into_bin_refused(self):
        self.check([("lib/ollama/x", "link", "../../bin/ollama")], False)

    def test_modern_zstd_release(self):
        # The published Ollama 0.40.3 Linux bundle is tar.zst, not tar.gz.
        with tempfile.TemporaryDirectory() as d:
            plain = pathlib.Path(d) / "vendor.tar"
            compressed = pathlib.Path(d) / "vendor.tar.zst"
            with tarfile.open(plain, "w") as tf:
                member = tarfile.TarInfo("bin/ollama")
                member.size = 1
                tf.addfile(member, io.BytesIO(b"x"))
            subprocess.run(["zstd", "-q", "-f", str(plain), "-o", str(compressed)], check=True)
            validator.validate(compressed)

    def test_modern_zstd_escaping_link_refused(self):
        with tempfile.TemporaryDirectory() as d:
            plain = pathlib.Path(d) / "malicious.tar"
            compressed = pathlib.Path(d) / "malicious.tar.zst"
            with tarfile.open(plain, "w") as tf:
                link = tarfile.TarInfo("lib/ollama/unsafe")
                link.type = tarfile.SYMTYPE
                link.linkname = "../../../etc"
                tf.addfile(link)
            subprocess.run(["zstd", "-q", "-f", str(plain), "-o", str(compressed)], check=True)
            with self.assertRaises(validator.UnsafeArchive):
                validator.validate(compressed)


if __name__ == "__main__":
    unittest.main()
