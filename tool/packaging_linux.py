#!/usr/bin/env python3
"""Package one Flutter Linux release bundle as native DEB and RPM installers.

Run on Ubuntu 22.04 after `flutter build linux --release`. Only temporary
staging trees are modified; the original Flutter bundle is left intact.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
APP_ID = "com.bshare.bshare"
MAINTAINER = "BShare maintainers <maintainers@bshare.invalid>"
# Audio and graphics backends can be loaded dynamically, outside ELF NEEDED.
DEB_DYNAMIC_DEPENDENCIES = [
    "libasound2", "libpulse0", "libgl1", "libegl1", "xdg-utils",
    "network-manager", "wpasupplicant", "dnsmasq-base", "polkitd | policykit-1",
    "udev",
    "v4l2loopback-dkms", "v4l2loopback-utils", "python3",
    "gstreamer1.0-plugins-good", "gstreamer1.0-plugins-bad",
]
RPM_DYNAMIC_DEPENDENCIES = [
    "libasound.so.2()(64bit)", "libpulse.so.0()(64bit)",
    "libGL.so.1()(64bit)", "libEGL.so.1()(64bit)", "/usr/bin/xdg-open",
    "NetworkManager", "wpa_supplicant", "dnsmasq", "polkit",
    "systemd-udev",
    "python3", "gstreamer1-plugins-good", "gstreamer1-plugins-bad-free",
    # Fedora's noopenh264 satisfies the shared-library ABI with a stub. Require
    # the real implementation from the distribution's normal codec repository.
    "gstreamer1-plugin-openh264", "openh264",
]


def run(command: list[str], *, cwd: Path | None = None) -> str:
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if result.stderr:
        print(result.stderr, end="", flush=True)
    result.check_returncode()
    return result.stdout


def require_tools(names: list[str]) -> None:
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        raise RuntimeError("Required packaging tools are missing: " + ", ".join(missing))


def version() -> tuple[str, str]:
    match = re.search(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$",
        (ROOT / "pubspec.yaml").read_text(), re.MULTILINE,
    )
    if not match:
        raise RuntimeError("pubspec.yaml must contain a numeric version: x.y.z+build")
    return match.group(1), match.group(2)


def elf_files(directory: Path) -> list[Path]:
    result = []
    for path in sorted(directory.rglob("*")):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as handle:
                if handle.read(4) == b"\x7fELF":
                    result.append(path)
    return result


def stage_bundle(bundle: Path, stage: Path) -> list[Path]:
    required = [
        "bshare", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin",
        "lib/libapp.so", "lib/libflutter_linux_gtk.so",
        "lib/libflutter_webrtc_plugin.so", "lib/libwebrtc.so", "bshare-camera",
    ]
    for relative in required:
        if not (bundle / relative).is_file():
            raise RuntimeError(f"Incomplete release bundle: {relative} is missing")
    if (bundle / "data/flutter_assets/kernel_blob.bin").exists():
        raise RuntimeError("The supplied bundle contains a debug Dart kernel")
    for path in bundle.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(bundle):
            raise RuntimeError(f"Bundle symlink escapes its directory: {path}")

    app = stage / "opt/bshare"
    shutil.copytree(bundle, app, symlinks=False)
    run([sys.executable, str(ROOT / "packaging/prepare_adb.py"),
         "--platform", "linux", "--architecture", "x64",
         "--destination", str(app / "tools/platform-tools"), "--verify-executable"])
    # The bundle's launcher metadata belongs in /usr/share in native packages.
    shutil.rmtree(app / "share", ignore_errors=True)
    assets = {
        ROOT / "packaging/debian/bshare-wrapper": stage / "usr/bin/bshare",
        ROOT / f"packaging/linux/{APP_ID}.desktop":
            stage / f"usr/share/applications/{APP_ID}.desktop",
        ROOT / "assets/brand/app_icon.png":
            stage / f"usr/share/icons/hicolor/512x512/apps/{APP_ID}.png",
        ROOT / "LICENSE": stage / "usr/share/licenses/bshare/LICENSE",
        ROOT / "third_party/flutter_webrtc/LICENSE":
            stage / "usr/share/licenses/bshare/flutter_webrtc.LICENSE",
        ROOT / "third_party/flutter_webrtc/NOTICE":
            stage / "usr/share/licenses/bshare/flutter_webrtc.NOTICE",
        ROOT / "packaging/linux/70-bshare-adb.rules":
            stage / "usr/lib/udev/rules.d/70-bshare-adb.rules",
        ROOT / "plugins/virtual-camera/linux/70-bshare-virtual-camera.rules":
            stage / "usr/lib/udev/rules.d/70-bshare-virtual-camera.rules",
        ROOT / "plugins/virtual-camera/linux/bshare-virtual-camera.service":
            stage / "usr/lib/systemd/user/bshare-virtual-camera.service",
        ROOT / "plugins/virtual-camera/linux/bshare-virtual-camera-setup.service":
            stage / "usr/lib/systemd/system/bshare-virtual-camera-setup.service",
        ROOT / "plugins/virtual-camera/linux/setup.py":
            app / "virtual-camera/linux/setup.py",
        ROOT / "plugins/virtual-camera/linux/README.md":
            app / "virtual-camera/linux/README.md",
    }
    for source, destination in assets.items():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    for path in stage.rglob("*"):
        path.chmod(0o755 if path.is_dir() else 0o644)
    (app / "bshare").chmod(0o755)
    (app / "bshare-camera").chmod(0o755)
    (stage / "usr/bin/bshare").chmod(0o755)
    files = elf_files(app)
    for path in files:
        # RPM's ELF generator uses the executable bit for shared objects too.
        path.chmod(0o755)
        header = run(["readelf", "-h", str(path)])
        if "Advanced Micro Devices X86-64" not in header:
            raise RuntimeError(f"Expected an x86_64 ELF: {path}")
        # Plugins copied by CMake can retain absolute build-machine RUNPATHs.
        if path != app / "tools/platform-tools/adb":
            origin = "$ORIGIN/lib" if path == app / "bshare" else "$ORIGIN"
            run(["patchelf", "--set-rpath", origin, str(path)])
        dependencies = run(["ldd", str(path)])
        if "not found" in dependencies:
            raise RuntimeError(f"Unresolved runtime library in {path}")
    run(["desktop-file-validate", str(stage / f"usr/share/applications/{APP_ID}.desktop")])
    return files


def make_deb(stage: Path, files: list[Path], work: Path, output: Path,
             app_version: str, build: str) -> tuple[Path, list[str]]:
    debian = work / "debian"
    debian.mkdir()
    (debian / "control").write_text(
        "Source: bshare\nSection: net\nPriority: optional\n"
        f"Maintainer: {MAINTAINER}\n\n"
        "Package: bshare\nArchitecture: amd64\nDescription: Local network sharing\n"
    )
    # Tell dpkg that the bundled libraries are private parts of this package.
    # All external libraries must still resolve and have package metadata.
    private_shlibs = []
    for path in files:
        dynamic = run(["readelf", "-d", str(path)])
        match = re.search(r"\(SONAME\).*\[([^\]]+)\]", dynamic)
        if match:
            soname = match.group(1)
            library, separator, suffix = soname.partition(".so")
            if separator:
                private_shlibs.append(f"{library} {suffix.lstrip('.') or '0'} bshare")
    (debian / "shlibs.local").write_text("\n".join(private_shlibs) + "\n")
    result = run([
        "dpkg-shlibdeps", "-O", "-xbshare", f"-l{stage / 'opt/bshare/lib'}",
        *[f"-e{path}" for path in files],
    ], cwd=work)
    line = next((line for line in result.splitlines()
                 if line.startswith("shlibs:Depends=")), None)
    if line is None:
        raise RuntimeError("dpkg-shlibdeps did not produce runtime dependencies")
    dependencies = sorted(set(line.partition("=")[2].split(", "))
                          | set(DEB_DYNAMIC_DEPENDENCIES))
    control = stage / "DEBIAN"
    control.mkdir()
    installed_kib = sum(path.stat().st_size for path in stage.rglob("*")
                        if path.is_file()) // 1024 + 1
    template = (ROOT / "packaging/debian/control.in").read_text()
    for key, value in {
        "VERSION": f"{app_version}-{build}", "DEPENDS": ", ".join(dependencies),
        "INSTALLED_SIZE": str(installed_kib),
    }.items():
        template = template.replace(f"@{key}@", value)
    (control / "control").write_text(template)
    for name in ["postinst", "postrm", "prerm"]:
        shutil.copy2(ROOT / f"packaging/debian/{name}", control / name)
        (control / name).chmod(0o755)
    package = output / f"bshare_{app_version}-{build}_amd64.deb"
    run(["dpkg-deb", "--root-owner-group", "--build", str(stage), str(package)])
    run(["dpkg-deb", "--info", str(package)])
    listing = run(["dpkg-deb", "--contents", str(package)])
    if "./opt/bshare/bshare" not in listing or "./usr/bin/bshare" not in listing:
        raise RuntimeError("DEB is missing its launcher or bundled executable")
    shutil.rmtree(control)
    return package, dependencies


def make_rpm(stage: Path, work: Path, output: Path,
             app_version: str, build: str) -> tuple[Path, list[str]]:
    top = work / "rpm"
    for name in ["BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS"]:
        (top / name).mkdir(parents=True)
    # Private libraries must neither become global system providers nor require
    # an additional system package. Keep automatic external ELF requirements.
    private_names = "|".join(re.escape(path.name) for path in (stage / "opt/bshare/lib").rglob("*.so*"))
    spec = top / "SPECS/bshare.spec"
    spec.write_text(
        "%global debug_package %{nil}\n"
        "%global __os_install_post %{nil}\n"
        "%global __provides_exclude_from ^/opt/bshare/.*$\n"
        f"%global __requires_exclude ^({private_names}).*$\n"
        f"Name: bshare\nVersion: {app_version}\nRelease: {build}\n"
        "Summary: Share files, screens and device cameras on your local network\n"
        "License: MIT\nBuildArch: x86_64\n"
        f"Requires: {', '.join(RPM_DYNAMIC_DEPENDENCIES)}\n\n"
        "Suggests: akmod-v4l2loopback, v4l2loopback\n\n"
        "%description\nBShare connects nearby devices directly over your local network.\n\n"
        "%prep\n%build\n%install\n"
        f"mkdir -p %{{buildroot}}\ncp -a '{stage}/.' %{{buildroot}}/\n\n"
        "%files\n%defattr(-,root,root,-)\n/opt/bshare\n/usr/bin/bshare\n"
        f"/usr/share/applications/{APP_ID}.desktop\n"
        f"/usr/share/icons/hicolor/512x512/apps/{APP_ID}.png\n"
        "%license /usr/share/licenses/bshare\n"
        "/usr/lib/udev/rules.d/70-bshare-adb.rules\n"
        "/usr/lib/udev/rules.d/70-bshare-virtual-camera.rules\n"
        "/usr/lib/systemd/user/bshare-virtual-camera.service\n"
        "/usr/lib/systemd/system/bshare-virtual-camera-setup.service\n"
        "%post\nif command -v udevadm >/dev/null 2>&1; then udevadm control --reload-rules || :; fi\n"
        "/usr/bin/python3 /opt/bshare/virtual-camera/linux/setup.py ensure || :\n"
        "%preun\nif [ \"$1\" = 0 ]; then /usr/bin/python3 /opt/bshare/virtual-camera/linux/setup.py remove || :; fi\n"
        "%postun\nif command -v udevadm >/dev/null 2>&1; then udevadm control --reload-rules || :; fi\n"
        "if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || :; fi\n"
    )
    run(["rpmbuild", "-bb", "--define", f"_topdir {top}", str(spec)])
    packages = list((top / "RPMS/x86_64").glob("*.rpm"))
    if len(packages) != 1:
        raise RuntimeError("Expected exactly one x86_64 RPM")
    package = output / f"bshare-{app_version}-{build}.x86_64.rpm"
    shutil.copy2(packages[0], package)
    dependencies = run(["rpm", "--query", "--package", "--requires", str(package)]).splitlines()
    if any(re.match(r"(libflutter|libwebrtc|libapp)\S*\.so", item) for item in dependencies):
        raise RuntimeError("RPM incorrectly requires a private bundled library")
    if not any("libc.so.6" in item for item in dependencies):
        raise RuntimeError("RPM automatic external ELF dependencies are missing")
    listing = run(["rpm", "--query", "--package", "--list", str(package)])
    if "/opt/bshare/bshare" not in listing or "/usr/bin/bshare" not in listing:
        raise RuntimeError("RPM is missing its launcher or bundled executable")
    return package, dependencies


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=ROOT / "build/linux/x64/release/bundle")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/linux")
    parser.add_argument("--formats", nargs="+", choices=["deb", "rpm"], default=["deb", "rpm"])
    parser.add_argument("--version", help="Override the numeric pubspec release version")
    parser.add_argument("--build-number", help="Override the numeric pubspec build number")
    args = parser.parse_args()
    tools = ["readelf", "ldd", "patchelf", "desktop-file-validate"]
    if "deb" in args.formats:
        tools += ["dpkg-deb", "dpkg-shlibdeps"]
    if "rpm" in args.formats:
        tools += ["rpmbuild", "rpm"]
    require_tools(tools)
    bundle = args.bundle.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app_version, build = version()
    app_version, build = args.version or app_version, args.build_number or build
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", app_version) or not re.fullmatch(r"[0-9]+", build):
        raise RuntimeError("Expected numeric version x.y.z and build number")
    manifest = {"version": f"{app_version}+{build}", "architecture": "x86_64", "packages": []}
    with tempfile.TemporaryDirectory(prefix="bshare-linux-package-") as temporary:
        work = Path(temporary)
        stage = work / "stage"
        stage.mkdir()
        files = stage_bundle(bundle, stage)
        for package_format in dict.fromkeys(args.formats):
            if package_format == "deb":
                package, dependencies = make_deb(stage, files, work, output, app_version, build)
            else:
                package, dependencies = make_rpm(stage, work, output, app_version, build)
            manifest["packages"].append({
                "file": package.name,
                "sha256": hashlib.sha256(package.read_bytes()).hexdigest(),
                "bytes": package.stat().st_size,
                "dependencies": dependencies,
            })
    (output / "linux-packages.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
