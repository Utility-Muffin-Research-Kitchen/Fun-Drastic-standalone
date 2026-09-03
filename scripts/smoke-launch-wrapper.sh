#!/usr/bin/env bash
set -euo pipefail

# Host smoke test for the Fun DraStic launch wrapper.
#
# The upstream archive is not published, so CI cannot build a real package.
# Everything UMRK actually authored is in the wrapper, so the wrapper is
# exercised against a synthetic package with a stub emulator: the seeding
# split, the state and log locations, the BIOS handling, the roster contract,
# the versioned defaults stamp, and the shared-save mirror.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fun-drastic-smoke.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() {
    local description="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $description" >&2
    fi
}

check_contains() {
    local description="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $description (no '$needle' in $file)" >&2
    fi
}

# --- synthetic package ------------------------------------------------------

PKG="$WORK/sd/.system/leaf/platforms/mlp1/emulators/fun-drastic"
mkdir -p "$PKG"/{bin,lib,config,fonts,language,themes,res/cursor,system,microphone,defaults} \
    "$PKG/Overlays/960x720/Template"

install -m 0755 "$ROOT_DIR/config/mlp1/launch.sh" "$PKG/launch.sh"
install -m 0644 "$ROOT_DIR/config/mlp1/defaults/config.version" \
    "$PKG/defaults/config.version"
install -m 0644 "$ROOT_DIR/config/mlp1/defaults/user_emu.cfg" \
    "$PKG/defaults/user_emu.cfg"
install -m 0644 "$ROOT_DIR/config/mlp1/BIOS-README.txt" "$PKG/system/BIOS-README.txt"

for lib in libfundrastic.so libSDL2-2.0.so.0 libxkbcommon.so.0 \
           libwayland-cursor.so.0 libasound.so.2; do
    : >"$PKG/lib/$lib"
    chmod 755 "$PKG/lib/$lib"
done

printf 'controls_b[CONTROL_INDEX_MENU] = 1\nunzip_roms = 1\n' \
    >"$PKG/config/drastic.cfg"
: >"$PKG/config/usrcheat.dat"
: >"$PKG/game_database.xml"
: >"$PKG/drastic_logo_0.raw"
: >"$PKG/drastic_logo_1.raw"
: >"$PKG/fonts/Nunito-Bold.ttf"
: >"$PKG/fonts/Translate.otf"
: >"$PKG/language/template.txt"
: >"$PKG/themes/custom.cfg"
: >"$PKG/res/cursor/1.png"
: >"$PKG/microphone/microphone.wav"
: >"$PKG/Overlays/960x720/Template/aspect_single.png"
head -c 16384 /dev/zero >"$PKG/system/drastic_bios_arm7.bin"
head -c 4096 /dev/zero >"$PKG/system/drastic_bios_arm9.bin"

# Stub emulator: records how it was invoked and writes an in-game save, which
# is what the shared-save mirror has to pick up.
cat >"$PKG/bin/drastic64" <<'STUB'
#!/usr/bin/env bash
{
    echo "argv=$*"
    echo "cwd=$PWD"
    echo "HOME=${HOME:-}"
    echo "FUN_DRASTIC_DIR=${FUN_DRASTIC_DIR:-}"
    echo "SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-}"
    echo "SDL_JOYSTICK_DEVICE=${SDL_JOYSTICK_DEVICE:-<unset>}"
    echo "SDL_JOYSTICK_DISABLE_UDEV=${SDL_JOYSTICK_DISABLE_UDEV:-}"
    echo "LD_PRELOAD=${LD_PRELOAD:-}"
} >"${FUN_DRASTIC_STUB_REPORT:?}"
# The Fun DraStic hook rewrites the save path at startup: in-game saves land in
# $SDCARD_PATH/Saves/NDS/<rom name>.sram, not in backup/<rom name>.dsv. The stub
# writes where the real emulator writes, otherwise the mirror test proves
# nothing.
if [ -n "${FUN_DRASTIC_STUB_WRITE_SAVE:-}" ]; then
    mkdir -p "${SDCARD_PATH:?}/Saves/NDS"
    printf 'fun-drastic-save' >"$SDCARD_PATH/Saves/NDS/$FUN_DRASTIC_STUB_WRITE_SAVE"
fi
exit "${FUN_DRASTIC_STUB_RC:-0}"
STUB
chmod 755 "$PKG/bin/drastic64"

# --- synthetic SD -----------------------------------------------------------

SD="$WORK/sd"
mkdir -p "$SD/Roms/NDS" "$SD/BIOS/NDS" "$SD/.userdata/mlp1/logs" \
    "$SD/.umrk/mlp1/drastic/backup" "$SD/Saves/NDS"
ROM="$SD/Roms/NDS/A Game's Demo.nds"
printf 'rom' >"$ROM"

STATE="$SD/.userdata/mlp1/fun-drastic"
LOG="$SD/.userdata/mlp1/logs/fun-drastic.log"
REPORT="$WORK/report.txt"

run_launcher() {
    env -u SDL_JOYSTICK_DEVICE \
        PLATFORM=mlp1 \
        SDCARD_PATH="$SD" \
        USERDATA_PATH="$SD/.userdata/mlp1" \
        LOGS_PATH="$SD/.userdata/mlp1/logs" \
        BIOS_PATH="$SD/BIOS" \
        UMRK_INTERNAL_DATA_PATH="$SD/.umrk/mlp1" \
        UMRK_RUNTIME_PATH="$WORK/runtime" \
        FUN_HOOK=0 \
        FUN_DRASTIC_STUB_REPORT="$REPORT" \
        "$@" \
        "$PKG/launch.sh" "$ROM"
}

# --- first launch, clean state, no Nintendo BIOS ----------------------------

# A runtime write into the release-managed emulator directory survives until
# the next update replaces it, so the package is checksummed before and after.
package_before="$(cd "$PKG" && find . -type f | LC_ALL=C sort | xargs shasum -a 256)"

run_launcher >/dev/null 2>&1

echo "== first launch on a clean state root =="
check "state root created under USERDATA_PATH" test -d "$STATE"
check "no state under UMRK_INTERNAL_DATA_PATH/fun-drastic" \
    test ! -e "$SD/.umrk/mlp1/fun-drastic"
check "support log written to LOGS_PATH" test -f "$LOG"
check "no log beside the installed package" test ! -e "$PKG/fundrastic.log"

echo "== drastic64 working-directory assets =="
for relative in config/drastic.cfg game_database.xml usrcheat.dat \
                drastic_logo_0.raw microphone/microphone.wav \
                system/drastic_bios_arm7.bin system/drastic_bios_arm9.bin \
                backup savestates profiles unzip_cache input_record cheats \
                slot2 scripts; do
    check "seeded $relative" test -e "$STATE/$relative"
done

echo "== hook assets resolved from FUN_DRASTIC_DIR =="
# This is the half the vendor launcher omits. Without it the menu has no font.
for relative in fonts/Nunito-Bold.ttf fonts/Translate.otf language/template.txt \
                themes/custom.cfg Overlays/960x720/Template/aspect_single.png \
                res/cursor/1.png user_emu.cfg; do
    check "seeded $relative" test -e "$STATE/$relative"
done

# The theme default only means anything if it survives seeding verbatim, and it
# must never be re-applied over a player's own choice.
check "seeded theme default is the Leaf slot" \
    grep -qx "theme 5" "$STATE/user_emu.cfg"
printf 'theme 2\n' >"$STATE/user_emu.cfg"
run_launcher >/dev/null 2>&1
check "an existing theme choice is left alone" \
    grep -qx "theme 2" "$STATE/user_emu.cfg"

echo "== emulator environment =="
check_contains "working directory is the state root" "$REPORT" "cwd=$STATE"
check_contains "HOME is the state root" "$REPORT" "HOME=$STATE"
check_contains "FUN_DRASTIC_DIR is the state root" "$REPORT" "FUN_DRASTIC_DIR=$STATE"
check_contains "stock SDL Wayland driver" "$REPORT" "SDL_VIDEODRIVER=wayland"
check_contains "udev joystick scan stays disabled" "$REPORT" \
    "SDL_JOYSTICK_DISABLE_UDEV=1"
check_contains "ROM path with a space and apostrophe survives" "$REPORT" \
    "argv=$ROM"

echo "== optional Nintendo BIOS =="
check "launch succeeds with no Nintendo BIOS present" test -f "$REPORT"
check_contains "absent Nintendo BIOS is logged, not fatal" "$LOG" \
    "using DraStic's free BIOS"
for forbidden in nds_bios_arm7.bin nds_bios_arm9.bin nds_firmware.bin; do
    check "no $forbidden in the package" test ! -e "$PKG/system/$forbidden"
    check "no $forbidden in the state root" test ! -e "$STATE/system/$forbidden"
done

echo "== versioned defaults stamp =="
check "defaults version recorded" test -f "$STATE/.umrk-defaults-version"
check "stamp matches the shipped version" test \
    "$(cat "$STATE/.umrk-defaults-version")" = "$(cat "$PKG/defaults/config.version")"

echo "== nothing written into the release-managed package =="
package_after="$(cd "$PKG" && find . -type f | LC_ALL=C sort | xargs shasum -a 256)"
check "package directory untouched at runtime" \
    test "$package_after" = "$package_before"

# --- user configuration survives a relaunch ---------------------------------

echo "== user configuration is not refreshed on every boot =="
printf 'controls_b[CONTROL_INDEX_MENU] = 99\nunzip_roms = 0\n' \
    >"$STATE/config/drastic.cfg"
run_launcher >/dev/null 2>&1
check_contains "user drastic.cfg preserved" "$STATE/config/drastic.cfg" \
    "controls_b[CONTROL_INDEX_MENU] = 99"

# --- user-supplied Nintendo BIOS --------------------------------------------

echo "== user-supplied Nintendo BIOS is imported into private state =="
head -c 16384 /dev/zero >"$SD/BIOS/NDS/nds_bios_arm7.bin"
head -c 4096 /dev/zero >"$SD/BIOS/NDS/nds_bios_arm9.bin"
run_launcher >/dev/null 2>&1
check "arm7 dump imported" test -f "$STATE/system/nds_bios_arm7.bin"
check "arm9 dump imported" test -f "$STATE/system/nds_bios_arm9.bin"
check "firmware still absent" test ! -e "$STATE/system/nds_firmware.bin"
check "dumps not copied into the package" \
    test ! -e "$PKG/system/nds_bios_arm7.bin"
rm -f "$SD/BIOS/NDS/nds_bios_arm7.bin" "$SD/BIOS/NDS/nds_bios_arm9.bin"

# --- inherited controller roster --------------------------------------------

echo "== inherited Jawaka roster wins =="
roster="/dev/input/event9:/dev/input/event3"
env PLATFORM=mlp1 \
    SDCARD_PATH="$SD" \
    USERDATA_PATH="$SD/.userdata/mlp1" \
    LOGS_PATH="$SD/.userdata/mlp1/logs" \
    BIOS_PATH="$SD/BIOS" \
    UMRK_INTERNAL_DATA_PATH="$SD/.umrk/mlp1" \
    UMRK_RUNTIME_PATH="$WORK/runtime" \
    FUN_HOOK=0 \
    FUN_DRASTIC_STUB_REPORT="$REPORT" \
    SDL_JOYSTICK_DEVICE="$roster" \
    "$PKG/launch.sh" "$ROM" >/dev/null 2>&1
check_contains "roster passed through unchanged" "$REPORT" \
    "SDL_JOYSTICK_DEVICE=$roster"

# --- shared in-game saves ---------------------------------------------------

echo "== in-game saves are shared with the primary DraStic package =="
# The two packages store the same DeSmuME bytes under different names:
# primary DraStic backup/<name>.dsv, Fun DraStic Saves/NDS/<name>.sram.
# The mirror is scoped to the ROM being launched, so it is keyed on the test
# ROM's own base name.
PRIMARY_BACKUP="$SD/.umrk/mlp1/drastic/backup"
FD_SAVES="$SD/Saves/NDS"
ROM_BASE="A Game's Demo"
printf 'primary-save' >"$PRIMARY_BACKUP/$ROM_BASE.dsv"
run_launcher FUN_DRASTIC_STUB_WRITE_SAVE="$ROM_BASE.sram" >/dev/null 2>&1
check "primary .dsv imported as .sram before launch" \
    test -f "$FD_SAVES/$ROM_BASE.sram"
check "Fun DraStic .sram exported as .dsv after exit" \
    test -f "$PRIMARY_BACKUP/$ROM_BASE.dsv"
check_contains "exported save has the emulator's bytes" \
    "$PRIMARY_BACKUP/$ROM_BASE.dsv" "fun-drastic-save"
check "savestates are not shared" test ! -e "$SD/.umrk/mlp1/drastic/savestates"

echo "== the mirror never touches another game's save =="
# These are the user's real saves in production. A session for one game must
# not read, rewrite, or invent a file for any other.
printf 'other-game' >"$PRIMARY_BACKUP/Some Other Game.dsv"
other_before="$(shasum -a 256 "$PRIMARY_BACKUP/Some Other Game.dsv" | cut -d" " -f1)"
# A save the emulator wrote under a mangled name, as it does for archived ROMs.
printf 'truncated' >"$FD_SAVES/A Game's Demo (USA.sram"
run_launcher >/dev/null 2>&1
other_after="$(shasum -a 256 "$PRIMARY_BACKUP/Some Other Game.dsv" | cut -d" " -f1)"
check "an unrelated game's save is untouched" test "$other_before" = "$other_after"
check "no .sram for an unrelated game is created" \
    test ! -e "$FD_SAVES/Some Other Game.sram"
check "a truncated archive save is not exported as junk" \
    test ! -e "$PRIMARY_BACKUP/A Game's Demo (USA.dsv"

echo "== the mirror is idempotent =="
# Preserving mtime is what stops every launch from rewriting the other
# package's saves when nothing was played.
before="$(ls -lT "$PRIMARY_BACKUP/$ROM_BASE.dsv" 2>/dev/null || ls -l --full-time "$PRIMARY_BACKUP/$ROM_BASE.dsv")"
run_launcher >/dev/null 2>&1
after="$(ls -lT "$PRIMARY_BACKUP/$ROM_BASE.dsv" 2>/dev/null || ls -l --full-time "$PRIMARY_BACKUP/$ROM_BASE.dsv")"
check "an unplayed session does not rewrite the primary save" \
    test "$before" = "$after"

echo "== the save-name rule matches what Fun DraStic actually does =="
# Fun DraStic cuts the save name at the first ") (". A ROM with No-Intro style
# region and language tags therefore saves under a different name than its own,
# and the mirror has to follow that or sharing silently does nothing.
TAGGED="$SD/Roms/NDS/Mario Kart DS (USA Australia) (EnFrDeEsIt).nds"
printf 'rom' >"$TAGGED"
printf 'tagged-primary' >"$PRIMARY_BACKUP/Mario Kart DS (USA Australia) (EnFrDeEsIt).dsv"
env -u SDL_JOYSTICK_DEVICE PLATFORM=mlp1 SDCARD_PATH="$SD" \
    USERDATA_PATH="$SD/.userdata/mlp1" LOGS_PATH="$SD/.userdata/mlp1/logs" \
    BIOS_PATH="$SD/BIOS" UMRK_INTERNAL_DATA_PATH="$SD/.umrk/mlp1" \
    UMRK_RUNTIME_PATH="$WORK/runtime" FUN_HOOK=0 \
    FUN_DRASTIC_STUB_REPORT="$REPORT" \
    FUN_DRASTIC_STUB_WRITE_SAVE="Mario Kart DS (USA Australia.sram" \
    "$PKG/launch.sh" "$TAGGED" >/dev/null 2>&1
check "import uses the truncated name the emulator will look for" \
    test -f "$FD_SAVES/Mario Kart DS (USA Australia.sram"
check "import does not use the full ROM name" \
    test ! -e "$FD_SAVES/Mario Kart DS (USA Australia) (EnFrDeEsIt).sram"
check_contains "export lands under the full ROM name the other package reads" \
    "$PRIMARY_BACKUP/Mario Kart DS (USA Australia) (EnFrDeEsIt).dsv" "fun-drastic-save"
check "no junk save under the truncated name" \
    test ! -e "$PRIMARY_BACKUP/Mario Kart DS (USA Australia.dsv"

echo "== a changed naming rule is caught, not silently skipped =="
rm -f "$FD_SAVES"/*.sram "$PRIMARY_BACKUP/Unexpected Name.dsv"
UNEXPECTED="$SD/Roms/NDS/Unexpected Name.nds"
printf 'rom' >"$UNEXPECTED"
printf 'primary' >"$PRIMARY_BACKUP/Unexpected Name.dsv"
env -u SDL_JOYSTICK_DEVICE PLATFORM=mlp1 SDCARD_PATH="$SD" \
    USERDATA_PATH="$SD/.userdata/mlp1" LOGS_PATH="$SD/.userdata/mlp1/logs" \
    BIOS_PATH="$SD/BIOS" UMRK_INTERNAL_DATA_PATH="$SD/.umrk/mlp1" \
    UMRK_RUNTIME_PATH="$WORK/runtime" FUN_HOOK=0 \
    FUN_DRASTIC_STUB_REPORT="$REPORT" \
    FUN_DRASTIC_STUB_WRITE_SAVE="Something Else Entirely.sram" \
    "$PKG/launch.sh" "$UNEXPECTED" >/dev/null 2>&1
check_contains "the mismatch is logged" "$LOG" "the naming rule has changed"
check_contains "the round trip still completes" \
    "$PRIMARY_BACKUP/Unexpected Name.dsv" "fun-drastic-save"

echo "== sharing can be switched off =="
rm -f "$PRIMARY_BACKUP/$ROM_BASE.dsv" "$FD_SAVES/$ROM_BASE.sram"
run_launcher FUN_DRASTIC_SHARE_SAVES=0 \
    FUN_DRASTIC_STUB_WRITE_SAVE="$ROM_BASE.sram" >/dev/null 2>&1
check "no export when sharing is disabled" \
    test ! -e "$PRIMARY_BACKUP/$ROM_BASE.dsv"

# --- exit status ------------------------------------------------------------

echo "== emulator exit status is propagated =="
set +e
run_launcher FUN_DRASTIC_STUB_RC=3 >/dev/null 2>&1
rc=$?
set -e
check "non-zero exit code reaches Jawaka" test "$rc" -eq 3

# --- argument handling ------------------------------------------------------

echo "== argument handling =="
set +e
"$PKG/launch.sh" >/dev/null 2>&1
no_args_rc=$?
"$PKG/launch.sh" "$WORK/does-not-exist.nds" >/dev/null 2>&1
missing_rom_rc=$?
set -e
check "missing argument is rejected" test "$no_args_rc" -eq 2
check "missing ROM is rejected" test "$missing_rom_rc" -eq 1

# --- input roster policy ----------------------------------------------------

if [ -f "$ROOT_DIR/../Leaf/scripts/validate-input-roster-policy.py" ]; then
    echo "== Leaf input-roster policy =="
    check "wrapper passes the roster policy" python3 \
        "$ROOT_DIR/../Leaf/scripts/validate-input-roster-policy.py" \
        "$ROOT_DIR/config/mlp1/launch.sh"
fi

echo
printf '%s checks passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
