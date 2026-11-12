"""Exercise the installer's compiler step without Wine or network access."""

from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "install-pscad.sh"
SECTION = SCRIPT.read_text().split("\nfind_gfortran() {", 1)[1]
SECTION = "find_gfortran() {" + SECTION.split("\n# --------------------------------------------------------------------------", 1)[0]

MOCKS = r'''
set -euo pipefail
PSCAD_ROOT="$1"
PREFIX="$PSCAD_ROOT/prefix"
PSCAD_VERSION="$2"
GFORTRAN_DIR="$3"
MODE="$4"
info() { echo "$*"; }
die() { echo "$*" >&2; exit 1; }
sleep() { :; }
wine_busy() { return 1; }
wait_for_wine() { :; }
find() {
    if [ "$1" = "${HOME}/Downloads" ]; then
        shift
        command find "$PSCAD_ROOT/downloads" "$@"
    else
        command find "$@"
    fi
}
curl() {
    echo "$*" >> "$PSCAD_ROOT/curl.calls"
    [ "$MODE" != network-failure ] || return 6
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then cp "$PSCAD_ROOT/package.zip" "$2"; return; fi
        shift
    done
    return 1
}
wine() {
    echo "$*" >> "$PSCAD_ROOT/wine.calls"
    if [ "$1" = Installer.exe ]; then
        if [ "$MODE" != install-failure ]; then
            local version=13.2
            [[ "$PWD" != *GFortran81 ]] || version=8.1
            mkdir -p "$PREFIX/drive_c/Program Files/GFortran/$version/x64/bin"
            touch "$PREFIX/drive_c/Program Files/GFortran/$version/x64/bin/gfortran.exe"
        fi
        return 205
    fi
    [ "$MODE" != runtime-failure ] || return 1
    echo 'GNU Fortran (test fixture)'
}
# timeout cannot execute a shell function; retain its failure propagation.
timeout() { shift; "$@"; }
'''


class CompilerStep(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pscad-compiler-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for folder in ("prefix/drive_c/Program Files", "prefix/drive_c/Program Files (x86)", "downloads"):
            (self.root / folder).mkdir(parents=True)
        with zipfile.ZipFile(self.root / "package.zip", "w") as archive:
            archive.writestr("Installer.exe", b"fixture")
            archive.writestr("Product/GFortran132.zip", b"fixture")
            archive.writestr("Product/GFortran81.zip", b"fixture")
        self.harness = self.root / "step.sh"
        self.harness.write_text(MOCKS + "\n" + SECTION)

    def run_step(self, version="5.1.0", installer="", mode="ok", success=True):
        result = subprocess.run(
            ["bash", str(self.harness), str(self.root), version, str(installer), mode],
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def local_installer(self, name):
        folder = self.root / "downloads" / "PSCAD_502_U2_installer" / name
        (folder / "Product").mkdir(parents=True)
        (folder / "Installer.exe").touch()
        (folder / "Product" / (name + ".zip")).touch()
        return folder

    def test_missing_compiler_downloads_and_installs(self):
        self.run_step()
        self.assertIn("GFortran132_Installer.zip", (self.root / "curl.calls").read_text())
        self.assertIn("Installer.exe /Silent=true", (self.root / "wine.calls").read_text())

    def test_bundled_81_precedes_download_and_unsupported_46(self):
        self.local_installer("GFortran46")
        self.local_installer("GFortran81")
        self.run_step()
        self.assertFalse((self.root / "curl.calls").exists())
        self.assertTrue((self.root / "prefix/drive_c/Program Files/GFortran/8.1/x64/bin/gfortran.exe").exists())

    def test_explicit_installer_precedes_discovery(self):
        self.local_installer("GFortran132")
        self.run_step(installer=self.local_installer("GFortran81"))
        self.assertFalse((self.root / "curl.calls").exists())
        self.assertTrue((self.root / "prefix/drive_c/Program Files/GFortran/8.1/x64/bin/gfortran.exe").exists())

    def test_existing_compiler_is_reused(self):
        folder = self.root / "prefix/drive_c/Program Files/GFortran/8.1/x64/bin"
        folder.mkdir(parents=True)
        (folder / "gfortran.exe").touch()
        self.run_step()
        self.assertFalse((self.root / "curl.calls").exists())
        self.assertNotIn("Installer.exe", (self.root / "wine.calls").read_text())

    def test_unsupported_existing_compiler_does_not_skip_install(self):
        folder = self.root / "prefix/drive_c/Program Files/GFortran/4.6/x64/bin"
        folder.mkdir(parents=True)
        (folder / "gfortran.exe").touch()
        self.run_step()
        self.assertTrue((self.root / "curl.calls").exists())

    def test_50_downloads_81(self):
        self.run_step(version="5.0.2")
        self.assertIn("GFortran81_Installer.zip", (self.root / "curl.calls").read_text())

    def test_50_uses_81_instead_of_local_132(self):
        self.local_installer("GFortran132")
        self.local_installer("GFortran81")
        self.run_step(version="5.0.2")
        self.assertTrue((self.root / "prefix/drive_c/Program Files/GFortran/8.1/x64/bin/gfortran.exe").exists())

    def test_cached_download_is_reused(self):
        folder = self.root / "installers"
        folder.mkdir()
        (folder / "GFortran132_Installer.zip").write_bytes((self.root / "package.zip").read_bytes())
        self.run_step()
        self.assertFalse((self.root / "curl.calls").exists())

    def test_download_failure_stops_install(self):
        result = self.run_step(mode="network-failure", success=False)
        self.assertIn("Could not download", result.stderr)
        self.assertFalse((self.root / "wine.calls").exists())

    def test_missing_explicit_installer_fails_without_downloading(self):
        self.run_step(installer=self.root / "missing", success=False)
        self.assertFalse((self.root / "curl.calls").exists())

    def test_failed_install_does_not_report_success(self):
        result = self.run_step(mode="install-failure", success=False)
        self.assertIn("No supported GFortran", result.stderr)

    def test_broken_compiler_does_not_report_success(self):
        result = self.run_step(mode="runtime-failure", success=False)
        self.assertIn("will not run", result.stderr)


if __name__ == "__main__":
    unittest.main()
