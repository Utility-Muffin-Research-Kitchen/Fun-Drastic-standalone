#!/usr/bin/env bash
set -euo pipefail

# Build the sanitized Fun DraStic MLP1 package from the pinned upstream
# archive.
#
# Everything that reaches output/ comes from an explicit allowlist, so a file
# added to a future archive cannot enter a release by accident. The generated
# launcher, manifest, README and BIOS note are authored here and never taken
# from the archive: the vendor launcher writes beside the installed package,
# hardcodes an input node, and refreshes drastic.cfg on every boot.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/workdir/mlp1}"
EXTRACT_DIR="$WORK_DIR/extracted"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/mlp1/fun-drastic}"

# shellcheck disable=SC1091
. "$ROOT_DIR/upstream.env"

die() {
    echo "error: $*" >&2
    exit 1
}

for command_name in jq shasum unzip; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "missing package command: $command_name"
done

# --- resolve and verify the upstream archive --------------------------------

ARCHIVE="${FUN_DRASTIC_ARCHIVE:-}"
if [ -z "$ARCHIVE" ]; then
    if [ -n "${FUN_DRASTIC_ARCHIVE_URL:-}" ]; then
        mkdir -p "$WORK_DIR"
        ARCHIVE="$WORK_DIR/$FUN_DRASTIC_ARCHIVE_NAME"
        if [ ! -f "$ARCHIVE" ]; then
            echo "Fetching $FUN_DRASTIC_ARCHIVE_URL" >&2
            curl -fsSL "$FUN_DRASTIC_ARCHIVE_URL" -o "$ARCHIVE" ||
                die "could not fetch $FUN_DRASTIC_ARCHIVE_URL"
        fi
    else
        die "no archive available.
Upstream is frozen and the archive has no authorized public home yet, so it
must be supplied explicitly:

  make package-mlp1 FUN_DRASTIC_ARCHIVE=/absolute/path/to/$FUN_DRASTIC_ARCHIVE_NAME"
    fi
fi

[ -f "$ARCHIVE" ] || die "missing Fun DraStic archive: $ARCHIVE"
archive_sha="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$archive_sha" != "$FUN_DRASTIC_ARCHIVE_SHA256" ]; then
    die "archive checksum mismatch.
  expected $FUN_DRASTIC_ARCHIVE_SHA256
  actual   $archive_sha
An archive change has to be reviewed and re-pinned in upstream.env before it
can be packaged."
fi

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
unzip -q "$ARCHIVE" -d "$EXTRACT_DIR"

SRC="$EXTRACT_DIR/drastic"
[ -d "$SRC" ] || die "unexpected archive layout: no drastic/ directory"

# --- the allowlist ----------------------------------------------------------

# Executables: mode 0755 in the package.
ALLOWED_EXEC=(
    bin/drastic64
    lib/libSDL2-2.0.so.0
    lib/libasound.so.2
    lib/libfundrastic.so
    lib/libwayland-cursor.so.0
    lib/libxkbcommon.so.0
)

# Data files: mode 0644. Every one is load-bearing given that neither the
# binary nor the hook virtualizes file I/O.
ALLOWED_DATA=(
    config/drastic.cfg
    config/usrcheat.dat
    drastic_logo_0.raw
    drastic_logo_1.raw
    fonts/Nunito-Bold.ttf
    fonts/Translate.otf
    game_database.xml
    language/chinese.txt
    language/spanish.txt
    language/template.txt
    microphone/microphone.wav
    res/cursor/1.png
    system/drastic_bios_arm7.bin
    system/drastic_bios_arm9.bin
    themes/custom.cfg
    themes/custom.cfg.example
)

# Overlay packs are copied as a tree: the hook's "NO OVERLAYS FOUND" path
# exists so users can add their own, and the shipped set is a starting point
# rather than a fixed inventory.
ALLOWED_TREES=(
    Overlays
)

# Never shipped, under any circumstances. Checked even though the allowlist
# already excludes them, because the allowlist is the thing a future change
# might loosen.
FORBIDDEN_NAMES=(
    nds_bios_arm7.bin
    nds_bios_arm9.bin
    nds_firmware.bin
)

# --- assemble ---------------------------------------------------------------

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

for relative in "${ALLOWED_EXEC[@]}"; do
    [ -f "$SRC/$relative" ] || die "missing archive file: $relative"
    mkdir -p "$OUTPUT_DIR/$(dirname "$relative")"
    install -m 0755 "$SRC/$relative" "$OUTPUT_DIR/$relative"
done

for relative in "${ALLOWED_DATA[@]}"; do
    [ -f "$SRC/$relative" ] || die "missing archive file: $relative"
    mkdir -p "$OUTPUT_DIR/$(dirname "$relative")"
    install -m 0644 "$SRC/$relative" "$OUTPUT_DIR/$relative"
done

for tree in "${ALLOWED_TREES[@]}"; do
    [ -d "$SRC/$tree" ] || die "missing archive directory: $tree"
    mkdir -p "$OUTPUT_DIR/$tree"
    (cd "$SRC/$tree" && find . -type f -print0) |
        while IFS= read -r -d '' relative; do
            relative="${relative#./}"
            case "$relative" in
                *.png|*.cfg|*.txt) ;;
                *) die "unexpected file type in $tree: $relative" ;;
            esac
            mkdir -p "$OUTPUT_DIR/$tree/$(dirname "$relative")"
            install -m 0644 "$SRC/$tree/$relative" "$OUTPUT_DIR/$tree/$relative"
        done
done

# --- generated files --------------------------------------------------------

install -m 0755 "$ROOT_DIR/config/mlp1/launch.sh" "$OUTPUT_DIR/launch.sh"
mkdir -p "$OUTPUT_DIR/defaults"
install -m 0644 "$ROOT_DIR/config/mlp1/defaults/config.version" \
    "$OUTPUT_DIR/defaults/config.version"
install -m 0644 "$ROOT_DIR/config/mlp1/defaults/user_emu.cfg" \
    "$OUTPUT_DIR/defaults/user_emu.cfg"
install -m 0644 "$ROOT_DIR/config/mlp1/BIOS-README.txt" \
    "$OUTPUT_DIR/system/BIOS-README.txt"

mkdir -p "$OUTPUT_DIR/licenses"
for notice in "$ROOT_DIR/licenses"/*; do
    [ -f "$notice" ] || continue
    install -m 0644 "$notice" "$OUTPUT_DIR/licenses/$(basename "$notice")"
done

config_version="$(tr -d '[:space:]' <"$OUTPUT_DIR/defaults/config.version")"
binary_sha="$(shasum -a 256 "$OUTPUT_DIR/bin/drastic64" | awk '{print $1}')"

sed \
    -e "s|@ARCHIVE_NAME@|$FUN_DRASTIC_ARCHIVE_NAME|g" \
    -e "s|@ARCHIVE_SHA256@|$FUN_DRASTIC_ARCHIVE_SHA256|g" \
    "$ROOT_DIR/config/mlp1/README.txt.in" >"$OUTPUT_DIR/README.txt"
chmod 644 "$OUTPUT_DIR/README.txt"

# --- forbidden-content gate -------------------------------------------------

for forbidden in "${FORBIDDEN_NAMES[@]}"; do
    if find "$OUTPUT_DIR" -name "$forbidden" -print -quit | grep -q .; then
        die "Nintendo BIOS file must never be packaged: $forbidden"
    fi
done

# --- manifest ---------------------------------------------------------------

checksums_file="$(mktemp)"
trap 'rm -f "$checksums_file"' EXIT
(
    cd "$OUTPUT_DIR"
    find . -type f ! -path './manifest.json' -print | LC_ALL=C sort |
        while IFS= read -r relative; do
            relative="${relative#./}"
            printf '%s\t%s\n' \
                "$(shasum -a 256 "$relative" | awk '{print $1}')" "$relative"
        done
) >"$checksums_file"

files_json="$(jq -Rn '[inputs | split("\t") | {sha256: .[0], path: .[1]}]' \
    <"$checksums_file")"

sed \
    -e "s|@AUTHOR@|$FUN_DRASTIC_AUTHOR|g" \
    -e "s|@VERSION@|$FUN_DRASTIC_VERSION|g" \
    -e "s|@CONFIG_VERSION@|$config_version|g" \
    -e "s|@ARCHIVE_NAME@|$FUN_DRASTIC_ARCHIVE_NAME|g" \
    -e "s|@ARCHIVE_SHA256@|$FUN_DRASTIC_ARCHIVE_SHA256|g" \
    -e "s|@BINARY_SHA256@|$binary_sha|g" \
    "$ROOT_DIR/config/mlp1/manifest.json.in" |
    jq --argjson files "$files_json" '. + {files: $files}' \
    >"$OUTPUT_DIR/manifest.json"
chmod 644 "$OUTPUT_DIR/manifest.json"

python3 "$ROOT_DIR/scripts/validate-package.py" "$OUTPUT_DIR"

package_bytes="$(find "$OUTPUT_DIR" -type f -exec cat {} + | wc -c | tr -d ' ')"
printf 'Packaged Fun DraStic: %s (%s files, %s MB)\n' \
    "$OUTPUT_DIR" \
    "$(jq '.files | length' "$OUTPUT_DIR/manifest.json")" \
    "$((package_bytes / 1048576))"
