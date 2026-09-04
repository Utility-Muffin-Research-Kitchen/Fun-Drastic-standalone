#!/usr/bin/env bash
set -euo pipefail

# Build the sanitized Fun DraStic MLP1 package from tenlevels' source.
#
# Fun DraStic is tenlevels' work. The hook (lib/libfundrastic.so) is compiled
# here from his src/funhook.c with the MLP1 toolchain, the same way the primary
# DraStic package cross-builds steward-fu-nds, so what ships is built from
# source rather than lifted out of a binary drop.
#
# DraStic itself is not ours and never will be: bin/drastic64, the free BIOS,
# the game database and the cheat database are Exophase's proprietary freeware,
# redistributed as his source tree bundles them and verified here by hash.
#
# Everything that reaches output/ comes from an explicit allowlist, so a file
# added to a future source drop cannot enter a release by accident. The
# launcher, manifest, README and BIOS note are authored here and never taken
# from upstream: the vendor launcher writes beside the installed package,
# hardcodes an input node, and refreshes drastic.cfg on every boot.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/workdir/mlp1}"
BUILD_DIR="$WORK_DIR/build"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/mlp1/fun-drastic}"

# shellcheck disable=SC1091
. "$ROOT_DIR/upstream.env"

die() {
    echo "error: $*" >&2
    exit 1
}

for command_name in jq shasum; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "missing package command: $command_name"
done

# --- resolve the source tree ------------------------------------------------

# Fun DraStic's source is a sibling checkout, the way steward-fu-nds is for the
# primary DraStic package. Point FUN_DRASTIC_SRC_DIR elsewhere to build a
# working tree instead.
SRC="${FUN_DRASTIC_SRC_DIR:-$(cd "$ROOT_DIR/.." && pwd)/Fun-Drastic-src}"
[ -d "$SRC" ] || die "Fun DraStic source not found: $SRC
Clone it next to this repo:

  git clone $FUN_DRASTIC_SOURCE_REPO

or point FUN_DRASTIC_SRC_DIR at your checkout."
[ -f "$SRC/src/funhook.c" ] || die "not a Fun DraStic source tree: $SRC"

# --- verify the DraStic payload ---------------------------------------------

# These five files are Exophase's, not tenlevels' and not ours. We redistribute
# them exactly as his tree bundles them, so each one is pinned: an upstream drop
# that quietly changes the emulator has to be reviewed and re-pinned before it
# can ship.
verify_sha256() {
    local path="$1" expected="$2" label="$3" actual
    [ -f "$path" ] || die "missing $label: $path"
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || die "$label checksum mismatch: $path
  expected $expected
  actual   $actual
A DraStic payload change has to be reviewed and re-pinned in upstream.env."
}

verify_sha256 "$SRC/emulator/bin/drastic64" \
    "$DRASTIC_BINARY_SHA256" "DraStic binary"
verify_sha256 "$SRC/emulator/bin/system/drastic_bios_arm7.bin" \
    "$DRASTIC_BIOS_ARM7_SHA256" "DraStic free ARM7 BIOS"
verify_sha256 "$SRC/emulator/bin/system/drastic_bios_arm9.bin" \
    "$DRASTIC_BIOS_ARM9_SHA256" "DraStic free ARM9 BIOS"
verify_sha256 "$SRC/emulator/bin/game_database.xml" \
    "$DRASTIC_GAME_DATABASE_SHA256" "DraStic game database"
verify_sha256 "$SRC/emulator/usrcheat.dat" \
    "$DRASTIC_USRCHEAT_SHA256" "DS cheat database"

# --- build the hook ---------------------------------------------------------

# One translation unit, cross-compiled against the MLP1 sysroot's SDL2 headers.
# The hook never links SDL2 - it resolves DraStic's own symbols through
# LD_PRELOAD at run time - so headers are all the compile needs.
#
# Set FUN_DRASTIC_BUILD=0 to package a hook built earlier, matching
# DRASTIC_BUILD=0 in the primary DraStic packaging.
TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"
HOOK="$BUILD_DIR/libfundrastic.so"

if [ "${FUN_DRASTIC_BUILD:-1}" = "1" ]; then
    command -v docker >/dev/null 2>&1 ||
        die "docker not found (needed to cross-build the Fun DraStic hook)"
    echo "Building libfundrastic.so from $SRC via $TOOLCHAIN_IMAGE" >&2
    mkdir -p "$BUILD_DIR"
    docker run --rm \
        -v "$SRC":/src -v "$BUILD_DIR":/out \
        "$TOOLCHAIN_IMAGE" \
        bash -lc '
set -eu
${CROSS_COMPILE}gcc -O2 -march=armv8-a -mcpu=cortex-a53 -fPIC -shared \
    -include /src/src/platforms/platform_leaf.h \
    -Wall -Wno-unused-function -Wno-nonnull-compare -Wno-format-truncation \
    -I"$SYSROOT/usr/include" -I"$SYSROOT/usr/include/SDL2" \
    /src/src/funhook.c -o /out/libfundrastic.so \
    -ldl -lpthread -lm
' || die "hook build failed"
else
    echo "FUN_DRASTIC_BUILD=0: using the existing $HOOK" >&2
fi

[ -f "$HOOK" ] || die "hook not built: $HOOK (build failed, or FUN_DRASTIC_BUILD=0 with no prior build)"

hook_sha="$(shasum -a 256 "$HOOK" | awk '{print $1}')"
source_sha="$(shasum -a 256 "$SRC/src/funhook.c" | awk '{print $1}')"
source_commit="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"

# --- the allowlist ----------------------------------------------------------

# "package path|source path". Nothing reaches the package except through this
# list, so a file added to a future source drop cannot ship by accident.
#
# The package layout is flat because that is what drastic64 and the hook expect
# at run time; upstream keeps the same content split across emulator/, shared/
# and targets/leaf/.

# Executables: mode 0755 in the package.
ALLOWED_EXEC=(
    "bin/drastic64|emulator/bin/drastic64"
    "lib/libSDL2-2.0.so.0|targets/leaf/lib_own/libSDL2-2.0.so.0"
    "lib/libasound.so.2|targets/leaf/lib_own/libasound.so.2"
    "lib/libwayland-cursor.so.0|targets/leaf/lib_own/libwayland-cursor.so.0"
    "lib/libxkbcommon.so.0|targets/leaf/lib_own/libxkbcommon.so.0"
)
# lib/libfundrastic.so is deliberately absent: it is built above, not copied.

# Data files: mode 0644. Every one is load-bearing given that neither the
# binary nor the hook virtualizes file I/O.
ALLOWED_DATA=(
    "config/drastic.cfg|targets/leaf/config_mlp1/drastic.cfg"
    "config/usrcheat.dat|emulator/usrcheat.dat"
    "drastic_logo_0.raw|shared/drastic_logo_0.raw"
    "drastic_logo_1.raw|shared/drastic_logo_1.raw"
    "fonts/Nunito-Bold.ttf|targets/leaf/theme/Nunito-Bold.ttf"
    "fonts/Translate.otf|shared/fonts/Translate.otf"
    "game_database.xml|emulator/bin/game_database.xml"
    "language/chinese.txt|shared/language/chinese.txt"
    "language/spanish.txt|shared/language/spanish.txt"
    "language/template.txt|shared/language/template.txt"
    "microphone/microphone.wav|shared/microphone/microphone.wav"
    "res/cursor/1.png|shared/res/cursor/1.png"
    "system/drastic_bios_arm7.bin|emulator/bin/system/drastic_bios_arm7.bin"
    "system/drastic_bios_arm9.bin|emulator/bin/system/drastic_bios_arm9.bin"
    "themes/custom.cfg|targets/leaf/theme/custom.cfg"
    "themes/custom.cfg.example|targets/template/theme/custom.cfg.example"
)

# Overlay packs are copied as a tree: the hook's "NO OVERLAYS FOUND" path exists
# so users can add their own, and the shipped set is a starting point rather
# than a fixed inventory. Upstream ships nine resolutions; only the MLP1 panel's
# own is packaged, because the other eight are dead weight on this device.
OVERLAY_SRC="shared/overlays/960x720"
OVERLAY_DST="Overlays/960x720"

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

install_allowed() {
    local mode="$1" pair="$2"
    local dest="${pair%%|*}" from="${pair#*|}"
    [ -f "$SRC/$from" ] || die "missing source file: $from"
    mkdir -p "$OUTPUT_DIR/$(dirname "$dest")"
    install -m "$mode" "$SRC/$from" "$OUTPUT_DIR/$dest"
}

for pair in "${ALLOWED_EXEC[@]}"; do
    install_allowed 0755 "$pair"
done

for pair in "${ALLOWED_DATA[@]}"; do
    install_allowed 0644 "$pair"
done

# The one artifact this repository actually builds.
mkdir -p "$OUTPUT_DIR/lib"
install -m 0755 "$HOOK" "$OUTPUT_DIR/lib/libfundrastic.so"

[ -d "$SRC/$OVERLAY_SRC" ] || die "missing overlay pack: $OVERLAY_SRC"
mkdir -p "$OUTPUT_DIR/$OVERLAY_DST"
# Read from a process substitution rather than a pipeline: a die() inside a
# piped while-loop only kills the subshell, which would let a bad file type
# through instead of failing the build.
while IFS= read -r -d '' relative; do
    relative="${relative#./}"
    case "$relative" in
        *.png) ;;
        *) die "unexpected file type in $OVERLAY_SRC: $relative" ;;
    esac
    mkdir -p "$OUTPUT_DIR/$OVERLAY_DST/$(dirname "$relative")"
    install -m 0644 "$SRC/$OVERLAY_SRC/$relative" \
        "$OUTPUT_DIR/$OVERLAY_DST/$relative"
done < <(cd "$SRC/$OVERLAY_SRC" && find . -type f -print0)

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

# tenlevels' own licence and credits travel with the package, verbatim. The
# PolyForm licence carries a required notice, and CREDITS.md is his statement
# of what Fun DraStic is built on - neither is ours to paraphrase.
install -m 0644 "$SRC/LICENSE" "$OUTPUT_DIR/licenses/FUN-DRASTIC-LICENSE.txt"
install -m 0644 "$SRC/CREDITS.md" "$OUTPUT_DIR/licenses/CREDITS.md"

config_version="$(tr -d '[:space:]' <"$OUTPUT_DIR/defaults/config.version")"
binary_sha="$(shasum -a 256 "$OUTPUT_DIR/bin/drastic64" | awk '{print $1}')"

sed \
    -e "s|@SOURCE_REPO@|$FUN_DRASTIC_SOURCE_REPO|g" \
    -e "s|@SOURCE_COMMIT@|$source_commit|g" \
    -e "s|@FUNHOOK_SHA256@|$source_sha|g" \
    -e "s|@HOOK_SHA256@|$hook_sha|g" \
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
    -e "s|@SOURCE_REPO@|$FUN_DRASTIC_SOURCE_REPO|g" \
    -e "s|@SOURCE_COMMIT@|$source_commit|g" \
    -e "s|@FUNHOOK_SHA256@|$source_sha|g" \
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
