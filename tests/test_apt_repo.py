import datetime
import gzip
import hashlib
import importlib.util
import io
import pathlib
import sys
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_apt_repo", ROOT / "tools" / "build_apt_repo.py")
REPO = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = REPO
SPEC.loader.exec_module(REPO)


def tar_gz(name, data):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def ar(members):
    out = b"!<arch>\n"
    for name, data in members:
        out += f"{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}`\n".encode("ascii")
        out += data + (b"\n" if len(data) & 1 else b"")
    return out


def deb(version, package="dev.manual7.camera"):
    control = (f"Package: {package}\nName: Manual7\nVersion: {version}\n"
               "Architecture: iphoneos-arm64\nDepends: mobilesubstrate, openssh-server\n"
               "Description: Teste.\n").encode()
    return ar([("debian-binary", b"2.0\n"), ("control.tar.gz", tar_gz("./control", control)),
               ("data.tar.gz", tar_gz("./x", b"x"))])


class AptRepoTests(unittest.TestCase):
    def test_builds_flat_repository_with_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for version in ("0.7.6", "0.7.10"):
                (root / f"m7_{version}.deb").write_bytes(deb(version))
            out = root / "repo"
            date = datetime.datetime(2026, 10, 30, tzinfo=datetime.timezone.utc)
            REPO.build(out, [root / "m7_0.7.6.deb", root / "m7_0.7.10.deb"], date)

            packages = (out / "Packages").read_text()
            self.assertEqual(gzip.decompress((out / "Packages.gz").read_bytes()).decode(), packages)
            self.assertLess(packages.index("Version: 0.7.10"), packages.index("Version: 0.7.6"))
            self.assertIn("Filename: debs/m7_0.7.10.deb", packages)
            self.assertIn("Depends: mobilesubstrate, openssh-server", packages)
            digest = hashlib.sha256((out / "debs" / "m7_0.7.10.deb").read_bytes()).hexdigest()
            self.assertIn(f"SHA256: {digest}", packages)

            release = (out / "Release").read_text()
            self.assertIn("Architectures: iphoneos-arm64", release)
            self.assertIn("Date: Fri, 30 Oct 2026 00:00:00 GMT", release)
            index = hashlib.sha256((out / "Packages.xz").read_bytes()).hexdigest()
            self.assertIn(f" {index} {(out / 'Packages.xz').stat().st_size} Packages.xz", release)
            self.assertTrue((out / ".nojekyll").exists())
            page = (out / "index.html").read_text()
            self.assertIn(f"sileo://source/{REPO.DEFAULT_URL}", page)
            self.assertIn("<b>Manual7</b> 0.7.10 — Teste.", page)

    def test_keeps_existing_packages_and_adds_other_projects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            out = root / "repo"
            (root / "m7.deb").write_bytes(deb("0.7.7"))
            (root / "other.deb").write_bytes(deb("1.0", "dev.raidzap.other"))
            REPO.build(out, [root / "m7.deb"])
            REPO.build(out, [root / "other.deb"])
            REPO.build(out, [out / "debs" / "m7.deb"])
            packages = (out / "Packages").read_text()
            self.assertIn("Package: dev.manual7.camera", packages)
            self.assertIn("Package: dev.raidzap.other", packages)
            self.assertEqual(packages.count("Package: "), 2)
            self.assertEqual(REPO.main([str(out)]), 0)
            self.assertEqual((out / "Packages").read_text(), packages)

    def test_rejects_files_that_are_not_debs(self):
        with tempfile.TemporaryDirectory() as directory:
            bogus = pathlib.Path(directory) / "x.deb"
            bogus.write_bytes(b"<html>")
            self.assertEqual(REPO.main([str(pathlib.Path(directory) / "repo"), str(bogus)]), 1)


if __name__ == "__main__":
    unittest.main()
