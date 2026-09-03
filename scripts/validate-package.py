#!/usr/bin/env python3
"""Validate a built Fun DraStic MLP1 package.

This runs at the end of package-mlp1.sh, so a bad package never reaches Leaf
staging. Leaf runs its own gate again over the assembled release payload; the
duplication is deliberate, because the two catch different mistakes (a bad
build here, a bad copy there).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path, PurePosixPath


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

# Neither drastic64 nor the hook virtualizes file I/O, so every one of these is
# resolved from disk at runtime and a missing entry is a runtime failure, not a
# degraded feature.
REQUIRED_FILES = (
    "launch.sh",
    "manifest.json",
    "README.txt",
    "defaults/config.version",
    "defaults/user_emu.cfg",
    "bin/drastic64",
    "lib/libSDL2-2.0.so.0",
    "lib/libasound.so.2",
    "lib/libfundrastic.so",
    "lib/libwayland-cursor.so.0",
    "lib/libxkbcommon.so.0",
    "config/drastic.cfg",
    "config/usrcheat.dat",
    "fonts/Nunito-Bold.ttf",
    "fonts/Translate.otf",
    "language/template.txt",
    "microphone/microphone.wav",
    "res/cursor/1.png",
    "themes/custom.cfg",
    "system/drastic_bios_arm7.bin",
    "system/drastic_bios_arm9.bin",
    "system/BIOS-README.txt",
    "game_database.xml",
    "drastic_logo_0.raw",
    "drastic_logo_1.raw",
    "licenses/DISTRIBUTION-BASIS.md",
    "licenses/THIRD-PARTY-NOTICES.txt",
)

EXECUTABLE_FILES = (
    "launch.sh",
    "bin/drastic64",
    "lib/libSDL2-2.0.so.0",
    "lib/libasound.so.2",
    "lib/libfundrastic.so",
    "lib/libwayland-cursor.so.0",
    "lib/libxkbcommon.so.0",
)

# DraStic's own free replacement BIOS ships, exactly as the primary DraStic
# package already ships it. The Nintendo dumps never do.
BUNDLED_BIOS = ("drastic_bios_arm7.bin", "drastic_bios_arm9.bin")
FORBIDDEN_BIOS = ("nds_bios_arm7.bin", "nds_bios_arm9.bin", "nds_firmware.bin")

# Runtime state belongs under USERDATA_PATH, never inside the package.
FORBIDDEN_TOP_LEVEL = {
    "backup",
    "savestates",
    "profiles",
    "unzip_cache",
    "input_record",
    "cheats",
    "slot2",
    "roms",
    "saves",
    "states",
    "bios",
    ".userdata",
}
FORBIDDEN_NAMES = {"fundrastic.log", "fun-drastic.log", "debug.txt", "game.log"}

BIOS_SIZES = {"drastic_bios_arm7.bin": 16384, "drastic_bios_arm9.bin": 4096}


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_aarch64_elf(path: Path) -> None:
    header = path.read_bytes()[:20]
    if (
        len(header) < 20
        or header[:4] != b"\x7fELF"
        or header[4] != 2
        or header[5] != 1
        or int.from_bytes(header[18:20], "little") != 183
    ):
        fail(f"not a little-endian AArch64 ELF: {path}")


def safe_manifest_path(value: object) -> str:
    if not isinstance(value, str) or not value or "\\" in value:
        fail(f"invalid manifest path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or "." in path.parts or ".." in path.parts:
        fail(f"unsafe manifest path: {value}")
    return value


def validate(package_dir: Path) -> None:
    for relative in REQUIRED_FILES:
        if not (package_dir / relative).is_file():
            fail(f"missing package file: {relative}")

    for relative in EXECUTABLE_FILES:
        if not os.access(package_dir / relative, os.X_OK):
            fail(f"package file is not executable: {relative}")

    validate_aarch64_elf(package_dir / "bin/drastic64")
    validate_aarch64_elf(package_dir / "lib/libfundrastic.so")

    for name, expected_size in BIOS_SIZES.items():
        actual_size = (package_dir / "system" / name).stat().st_size
        if actual_size != expected_size:
            fail(f"{name} is {actual_size} bytes, expected {expected_size}")

    for name in FORBIDDEN_BIOS:
        if any(package_dir.rglob(name)):
            fail(f"Nintendo BIOS file must never be packaged: {name}")

    for path in package_dir.rglob("*"):
        if path.is_symlink():
            fail(f"package is not FAT32-safe; symlink found: {path}")
        relative = path.relative_to(package_dir)
        if relative.parts and relative.parts[0].casefold() in FORBIDDEN_TOP_LEVEL:
            fail(f"runtime state found in package: {relative}")
        if path.name in FORBIDDEN_NAMES:
            fail(f"runtime file found in package: {relative}")

    # The vendor launcher's three defects, gated so a future refactor cannot
    # quietly reintroduce them.
    launcher = (package_dir / "launch.sh").read_text(encoding="utf-8")
    if re.search(r"/dev/input/event\d", launcher):
        fail("launcher hardcodes a physical input node")
    if "UMRK_INTERNAL_DATA_PATH" in launcher and "USERDATA_PATH" not in launcher:
        fail("launcher stores durable state under launcher-owned control state")
    if "SDL_JOYSTICK_DISABLE_UDEV=1" not in launcher:
        fail("launcher must keep SDL_JOYSTICK_DISABLE_UDEV=1")
    if "$SELF_DIR/fundrastic.log" in launcher:
        fail("launcher writes its support log beside the installed package")

    manifest_path = package_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        fail("manifest must be a JSON object")

    expected_fields = {
        "id": "fun_drastic",
        "name": "Fun DraStic",
        "platform": "mlp1",
        "kind": "standalone-emulator",
        "binary": "bin/drastic64",
        "entrypoint": "launch.sh",
        "sdl_video_driver": "wayland",
        "package_schema_version": 1,
    }
    for key, expected in expected_fields.items():
        if manifest.get(key) != expected:
            fail(f"manifest {key} must be {expected!r}")

    if not SHA256_RE.fullmatch(str(manifest.get("source_archive_sha256", ""))):
        fail("manifest must record the source archive SHA-256")

    config_version = int(
        (package_dir / "defaults/config.version").read_text(encoding="utf-8").strip()
    )
    if manifest.get("config_schema_version") != config_version:
        fail("manifest config_schema_version does not match defaults/config.version")

    if sorted(manifest.get("bundled_bios") or []) != sorted(
        f"system/{name}" for name in BUNDLED_BIOS
    ):
        fail("manifest must inventory exactly DraStic's free replacement BIOS")

    reasons = " ".join(
        str(row.get("reason", "")) for row in manifest.get("exceptions") or []
    )
    if "drastic64" not in str(manifest.get("exceptions")):
        fail("manifest must record the prebuilt drastic64 exception")
    if "not built by UMRK" not in reasons:
        fail("manifest must not imply UMRK built the prebuilt binaries")

    file_rows = manifest.get("files")
    if not isinstance(file_rows, list) or not file_rows:
        fail("manifest must contain a non-empty files array")
    expected_files: dict[str, str] = {}
    for row in file_rows:
        if not isinstance(row, dict):
            fail("manifest file rows must be objects")
        relative = safe_manifest_path(row.get("path"))
        expected_sha = row.get("sha256")
        if not isinstance(expected_sha, str) or not SHA256_RE.fullmatch(expected_sha):
            fail(f"invalid checksum for package path: {relative}")
        if relative == "manifest.json" or relative in expected_files:
            fail(f"duplicate or self-referential manifest path: {relative}")
        expected_files[relative] = expected_sha

    actual_files = {
        path.relative_to(package_dir).as_posix()
        for path in package_dir.rglob("*")
        if path.is_file() and path != manifest_path
    }
    if set(expected_files) != actual_files:
        unlisted = sorted(actual_files - set(expected_files))
        missing = sorted(set(expected_files) - actual_files)
        fail(f"manifest inventory mismatch; unlisted={unlisted}, missing={missing}")
    for relative, expected_sha in expected_files.items():
        if sha256(package_dir / relative) != expected_sha:
            fail(f"package checksum mismatch: {relative}")

    if manifest.get("binary_sha256") != sha256(package_dir / "bin/drastic64"):
        fail("manifest binary_sha256 does not match bin/drastic64")

    print(
        f"Fun DraStic package gate: {len(expected_files)} checksummed files, "
        f"binary {manifest['binary_sha256']}"
    )


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} <package-dir>")
    package_dir = Path(sys.argv[1])
    if not package_dir.is_dir():
        fail(f"missing package directory: {package_dir}")
    validate(package_dir)


if __name__ == "__main__":
    main()
