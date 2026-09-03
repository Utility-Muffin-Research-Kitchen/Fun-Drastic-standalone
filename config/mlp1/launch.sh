#!/usr/bin/env bash
set -euo pipefail

# Fun DraStic launch wrapper for Leaf on MLP1.
#
# Fun DraStic is the same closed-source drastic64 binary the primary DraStic
# package ships, with a different frontend attached through an LD_PRELOAD SDL
# interposer (lib/libfundrastic.so). That split decides most of what this
# script does, because runtime data has two owners and neither one is
# virtualized:
#
#   drastic64  resolves config/, system/, microphone/, game_database.xml and
#              usrcheat.dat relative to its working directory, so the working
#              directory is the only lever for those.
#   the hook   resolves fonts/, language/, themes/, Overlays/ and res/cursor/
#              from $FUN_DRASTIC_DIR, with no fallback. A missing font is not
#              a degraded menu, it is an unrendered one.
#   the hook   also rewrites the save and savestate paths before main() runs
#              (it interposes __libc_start_main), sending them to
#              $SDCARD_PATH/Saves/NDS rather than the working directory's
#              backup/ and savestates/. Verified on an MLP1.
#
# The first two are seeded below; the vendor launcher seeds only the first.
# The third is where the shared-save mirror works - see further down.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$ROOT_DIR/../../launcher/env.sh" ]; then
    # shellcheck source=/dev/null
    . "$ROOT_DIR/../../launcher/env.sh"
elif [ -n "${UMRK_ENV_FILE:-}" ] && [ -f "$UMRK_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$UMRK_ENV_FILE"
elif [ -n "${SDCARD_PATH:-}" ] && [ -n "${PLATFORM:-}" ] &&
     [ -f "$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher/env.sh" ]; then
    # shellcheck source=/dev/null
    . "$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher/env.sh"
fi

if [ "$#" -ne 1 ]; then
    echo "usage: $0 ROM" >&2
    exit 2
fi

ROM_PATH="$1"
if [ ! -f "$ROM_PATH" ]; then
    echo "Fun DraStic ROM not found: $ROM_PATH" >&2
    exit 1
fi

: "${PLATFORM:=mlp1}"
: "${SDCARD_PATH:=/mnt/sdcard}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"
: "${BIOS_PATH:=$SDCARD_PATH/BIOS}"
: "${UMRK_RUNTIME_PATH:=${TMPDIR:-/tmp}/jawaka-runtime}"

# Durable state lives under USERDATA_PATH. UMRK_INTERNAL_DATA_PATH is
# launcher-owned control state (catalog/, release.json) and is deliberately not
# used here, even though the primary DraStic package still writes there.
STATE_ROOT="${FUN_DRASTIC_STATE_ROOT:-$USERDATA_PATH/fun-drastic}"
LOG_FILE="$LOGS_PATH/fun-drastic.log"
RUNTIME_DIR="$UMRK_RUNTIME_PATH/fun-drastic"
RUN_LOG="$RUNTIME_DIR/run.log"

DEFAULTS_VERSION_FILE="$ROOT_DIR/defaults/config.version"
INSTALLED_VERSION_FILE="$STATE_ROOT/.umrk-defaults-version"

# The three Nintendo dumps a user may supply. They are never shipped, never
# hashed into an artifact, and their absence is the normal case: drastic64
# falls back to its own free replacement BIOS on its own.
NDS_BIOS_FILES=(nds_bios_arm7.bin nds_bios_arm9.bin nds_firmware.bin)

mkdir -p "$LOGS_PATH" "$RUNTIME_DIR"
: >"$RUN_LOG"

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" \
        >>"$RUN_LOG"
}

log "=== Fun DraStic launch ==="
log "package=$ROOT_DIR"
log "state=$STATE_ROOT"

# --- state tree -------------------------------------------------------------

# drastic64 creates none of these itself; it opens paths inside them directly.
mkdir -p \
    "$STATE_ROOT" \
    "$STATE_ROOT/backup" \
    "$STATE_ROOT/savestates" \
    "$STATE_ROOT/profiles" \
    "$STATE_ROOT/unzip_cache" \
    "$STATE_ROOT/input_record" \
    "$STATE_ROOT/cheats" \
    "$STATE_ROOT/slot2" \
    "$STATE_ROOT/microphone" \
    "$STATE_ROOT/scripts" \
    "$STATE_ROOT/system"

seed_if_missing() {
    local src="$1" dst="$2"
    if [ -e "$src" ] && [ ! -e "$dst" ]; then
        if cp -R "$src" "$dst"; then
            log "seeded: ${dst#"$STATE_ROOT/"}"
        else
            log "WARNING: seed failed: $src"
        fi
    fi
}

# Half one: what drastic64 reads relative to the working directory.
seed_if_missing "$ROOT_DIR/config" "$STATE_ROOT/config"
seed_if_missing "$ROOT_DIR/game_database.xml" "$STATE_ROOT/game_database.xml"
seed_if_missing "$ROOT_DIR/config/usrcheat.dat" "$STATE_ROOT/usrcheat.dat"
seed_if_missing "$ROOT_DIR/microphone/microphone.wav" \
    "$STATE_ROOT/microphone/microphone.wav"
seed_if_missing "$ROOT_DIR/drastic_logo_0.raw" "$STATE_ROOT/drastic_logo_0.raw"
seed_if_missing "$ROOT_DIR/drastic_logo_1.raw" "$STATE_ROOT/drastic_logo_1.raw"
for bios in "$ROOT_DIR/system"/drastic_bios_*.bin; do
    [ -e "$bios" ] || continue
    seed_if_missing "$bios" "$STATE_ROOT/system/$(basename "$bios")"
done

# Half two: what the hook reads from $FUN_DRASTIC_DIR. There is no fallback
# path inside libfundrastic.so for any of these, so dropping one of them on the
# assumption that a future hook build embeds its assets breaks the menu.
seed_if_missing "$ROOT_DIR/fonts" "$STATE_ROOT/fonts"
seed_if_missing "$ROOT_DIR/language" "$STATE_ROOT/language"
seed_if_missing "$ROOT_DIR/themes" "$STATE_ROOT/themes"
seed_if_missing "$ROOT_DIR/Overlays" "$STATE_ROOT/Overlays"
seed_if_missing "$ROOT_DIR/res" "$STATE_ROOT/res"

# The hook's own settings file, and the only lever for which theme Fun DraStic
# starts on. It is seeded rather than refreshed: once a player has picked a
# theme, that choice is theirs.
#
# theme 5 is the CUSTOM slot, which themes/custom.cfg names "Leaf". The hook
# indexes its built-in themes 0..4 (MARIO KOOPA PEACH WARIO YOSHI) and puts
# CUSTOM last, so 5 is correct only while there are exactly five built-ins -
# g_theme_names in libfundrastic.so is 40 bytes, five pointers. A hook build
# that adds a theme moves the CUSTOM slot and this default has to move with it.
seed_if_missing "$ROOT_DIR/defaults/user_emu.cfg" "$STATE_ROOT/user_emu.cfg"

for required in fonts/Nunito-Bold.ttf language themes Overlays res/cursor; do
    if [ ! -e "$STATE_ROOT/$required" ]; then
        log "WARNING: hook asset missing after seeding: $required"
    fi
done

# --- versioned defaults migration -------------------------------------------

# drastic.cfg carries both package-owned control bindings and the user's own
# choices, so the vendor launcher's refresh-every-boot is wrong and never
# refreshing is wrong too. Rewrite a key only when it still holds the value a
# previous package shipped, the way the Flycast package handles its mappings.

if [ ! -f "$DEFAULTS_VERSION_FILE" ]; then
    echo "Fun DraStic package is missing defaults/config.version" >&2
    exit 1
fi
DEFAULTS_VERSION="$(tr -d '[:space:]' <"$DEFAULTS_VERSION_FILE")"
case "$DEFAULTS_VERSION" in
    ''|*[!0-9]*)
        echo "invalid Fun DraStic defaults version: $DEFAULTS_VERSION" >&2
        exit 1
        ;;
esac

INSTALLED_VERSION=0
if [ -f "$INSTALLED_VERSION_FILE" ]; then
    INSTALLED_VERSION="$(tr -d '[:space:]' <"$INSTALLED_VERSION_FILE")"
    case "$INSTALLED_VERSION" in
        ''|*[!0-9]*)
            echo "invalid installed Fun DraStic defaults version: $INSTALLED_VERSION" >&2
            exit 1
            ;;
    esac
fi

# Replace a single drastic.cfg key, but only where it still equals the value an
# earlier package shipped. Future migration blocks call this; leaving it unused
# at version 1 is expected.
# Unused at defaults version 1 by design - there is no earlier shipped default
# to recognize yet. The version 2 migration block below will call it.
# shellcheck disable=SC2317,SC2329
cfg_migrate_key() {
    local key="$1" previous_default="$2" new_default="$3"
    local cfg="$STATE_ROOT/config/drastic.cfg"
    [ -f "$cfg" ] || return 0
    grep -q "^${key} = ${previous_default}\$" "$cfg" || return 0
    local updated="$cfg.umrk-new"
    # Write-and-rename: sed -i is not portable, and this wrapper is exercised
    # on the host by the launch smoke test.
    if sed "s|^${key} = ${previous_default}\$|${key} = ${new_default}|" \
            "$cfg" >"$updated"; then
        mv "$updated" "$cfg"
        log "migrated drastic.cfg key: $key"
    else
        rm -f "$updated"
        log "WARNING: drastic.cfg migration failed: $key"
    fi
}

if [ "$INSTALLED_VERSION" -lt "$DEFAULTS_VERSION" ]; then
    # Version 1 is the first shipped package. There is no earlier default to
    # recognize, so it only records the stamp; version 2 and later add a
    # cfg_migrate_key block here for each key whose shipped default changed.
    printf '%s\n' "$DEFAULTS_VERSION" >"$INSTALLED_VERSION_FILE"
    log "defaults version: $INSTALLED_VERSION -> $DEFAULTS_VERSION"
fi

# --- optional Nintendo BIOS -------------------------------------------------

# Copy in whichever of the three dumps the user supplied, and launch either
# way. Most games never need them; the firmware user settings and a handful of
# titles that refuse to start on the free BIOS do.
bios_found=()
bios_absent=()
for bios_name in "${NDS_BIOS_FILES[@]}"; do
    source_bios="$BIOS_PATH/NDS/$bios_name"
    target_bios="$STATE_ROOT/system/$bios_name"
    if [ -f "$source_bios" ]; then
        bios_found+=("$bios_name")
        if [ ! -f "$target_bios" ] || [ "${FUN_DRASTIC_BIOS_REFRESH:-0}" = "1" ]; then
            if cp -f "$source_bios" "$target_bios" 2>/dev/null; then
                log "installed user BIOS: $bios_name"
            else
                log "WARNING: could not install user BIOS: $bios_name"
            fi
        fi
    else
        bios_absent+=("$bios_name")
    fi
done
if [ "${#bios_absent[@]}" -gt 0 ]; then
    log "optional Nintendo BIOS not supplied (${bios_absent[*]}); using DraStic's free BIOS"
fi
if [ "${#bios_found[@]}" -gt 0 ]; then
    log "optional Nintendo BIOS present (${bios_found[*]})"
fi

# --- shared in-game saves ---------------------------------------------------

# drastic64 is byte-identical in both NDS packages, so the in-game save format
# is identical too and a game switched between them should keep its progress.
# Where each package puts that save is not identical:
#
#   primary DraStic   <its state root>/backup/<rom name>.dsv
#   Fun DraStic       $SDCARD_PATH/Saves/NDS/<rom name>.sram
#
# The hook rewrites the save and savestate paths at startup - it carries the
# literals "Saves/NDS", "Saves/NDS/states", "Saves/NDS/previews" and reads
# SDCARD_PATH - so Fun DraStic writes into Leaf's public Saves folder and never
# touches backup/. The two files are the same DeSmuME format byte for byte,
# footer included; only the directory and the extension differ.
#
# The SD card is FAT32, so there is no symlink or hardlink to make one file
# serve both names. The wrapper mirrors instead: newest-wins in before launch,
# newest-wins out after exit, matched on the ROM base name. Fun DraStic owns
# both directions, which is what keeps the primary DraStic package unmodified.
# Configuration and savestates stay separate and are never mirrored.
#
# This tracks the hook's own rule ($SDCARD_PATH/Saves/NDS) rather than
# SAVES_PATH, so the mirror cannot drift from where the emulator actually
# writes if the two ever diverge.
FUN_DRASTIC_SAVES_DIR="${FUN_DRASTIC_SAVES_DIR:-$SDCARD_PATH/Saves/NDS}"
PRIMARY_DRASTIC_STATE_ROOT="${PRIMARY_DRASTIC_STATE_ROOT:-${UMRK_INTERNAL_DATA_PATH:-$SDCARD_PATH/.umrk/$PLATFORM}/drastic}"
PRIMARY_BACKUP_DIR="$PRIMARY_DRASTIC_STATE_ROOT/backup"
SHARE_SAVES="${FUN_DRASTIC_SHARE_SAVES:-1}"

# Copy one save across, keeping the modification time. Preserving it is what
# makes the mirror idempotent: a copy that inherited the copy time would look
# newer than its own source on the way back, so every exit would rewrite the
# other package's saves whether or not anything was played. It also makes the
# newest-wins comparison mean "last saved" rather than "last copied", which is
# the question being asked.
mirror_one_save() {
    local source_file="$1" target="$2" direction="$3"
    if [ -f "$target" ] && [ ! "$source_file" -nt "$target" ]; then
        return 0
    fi
    if cp -p -f "$source_file" "$target" 2>/dev/null ||
       cp -f "$source_file" "$target" 2>/dev/null; then
        log "save $direction: $(basename "$source_file")"
    else
        log "WARNING: save $direction failed: $(basename "$source_file")"
    fi
}

# Only the game being launched is mirrored, never the whole directory. Two
# reasons, both learned on the device:
#
#  * Blast radius. These are the user's real saves. A per-ROM mirror cannot
#    touch a game this session has nothing to do with.
#  * Fun DraStic truncates the save name for a ROM launched from an archive -
#    "Game (USA) (En,Fr).zip" saves as "Game (USA.sram" - so a whole-directory
#    export copies that mangled name back into the other package's save folder
#    as a junk .dsv that nothing will ever read. Scoping to the launched ROM's
#    own base name leaves it alone. See the archive caveat in README.txt.
ROM_BASE_NAME="$(basename "$ROM_PATH")"
ROM_BASE_NAME="${ROM_BASE_NAME%.*}"

# Fun DraStic does not name the save after the ROM. It cuts the name at the
# first ") (" - what looks like an attempt to strip No-Intro region and
# language tags, one character short of the closing bracket. Observed on an
# MLP1, for both a raw .nds and the same ROM inside a .zip:
#
#   "ZZ Fun DraStic Test (raw)"                 -> "ZZ Fun DraStic Test (raw)"
#   "Mario Kart DS (USA Australia) (EnFrDeEsIt)" -> "Mario Kart DS (USA Australia"
#
# The rule is reverse-engineered, so it is used for the import (where a name
# has to be chosen up front) and then checked against what the emulator
# actually wrote. A mismatch is logged loudly rather than silently skipping the
# save, and the export falls back to whatever .sram the session really touched.
fun_drastic_save_name() {
    local name="$1"
    case "$name" in
        *") ("*) printf '%s' "${name%%") ("*}" ;;
        *)       printf '%s' "$name" ;;
    esac
}
FUN_SAVE_NAME="$(fun_drastic_save_name "$ROM_BASE_NAME")"
if [ "$FUN_SAVE_NAME" != "$ROM_BASE_NAME" ]; then
    log "Fun DraStic will name this game's save '$FUN_SAVE_NAME'"
fi

import_saves() {
    [ "$SHARE_SAVES" = "1" ] || return 0
    local source_file="$PRIMARY_BACKUP_DIR/$ROM_BASE_NAME.dsv"
    if [ ! -f "$source_file" ]; then
        log "no primary DraStic save for this game; nothing to import"
        return 0
    fi
    mkdir -p "$FUN_DRASTIC_SAVES_DIR" 2>/dev/null || return 0
    mirror_one_save "$source_file" \
        "$FUN_DRASTIC_SAVES_DIR/$FUN_SAVE_NAME.sram" imported
}

# The save this session actually wrote. Normally the predicted name; if the
# prediction was wrong it is whichever .sram changed while the emulator ran,
# which keeps the round trip working even when the naming rule shifts.
find_session_save() {
    local predicted="$FUN_DRASTIC_SAVES_DIR/$FUN_SAVE_NAME.sram"

    # "Written this run" is the test, not "exists": the import leaves a file at
    # the predicted name with the source's own timestamp, so presence alone
    # would always match and the fallback would never run.
    local candidate newest=""
    for candidate in "$FUN_DRASTIC_SAVES_DIR"/*.sram; do
        [ -f "$candidate" ] || continue
        [ "$candidate" -nt "$SESSION_MARKER" ] || continue
        if [ "$candidate" = "$predicted" ]; then
            printf '%s' "$predicted"
            return 0
        fi
        if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
            newest="$candidate"
        fi
    done

    if [ -n "$newest" ]; then
        log "WARNING: expected save '$FUN_SAVE_NAME.sram' but the session wrote '$(basename "$newest")'; the naming rule has changed"
        printf '%s' "$newest"
        return 0
    fi

    # Nothing was written. Naming the predicted file keeps the caller simple:
    # the newest-wins check in mirror_one_save skips it.
    [ -f "$predicted" ] || return 1
    printf '%s' "$predicted"
}

export_saves() {
    [ "$SHARE_SAVES" = "1" ] || return 0
    [ -d "$PRIMARY_BACKUP_DIR" ] || return 0
    local source_file
    if ! source_file="$(find_session_save)" || [ -z "$source_file" ]; then
        log "no Fun DraStic save for this game; nothing to export"
        return 0
    fi
    # Always land under the ROM's own base name: that is what the primary
    # DraStic package looks for, whatever Fun DraStic called its own copy.
    mirror_one_save "$source_file" \
        "$PRIMARY_BACKUP_DIR/$ROM_BASE_NAME.dsv" exported
}

# Timestamp reference for find_session_save; created before the emulator runs.
SESSION_MARKER="$RUNTIME_DIR/session.stamp"
: >"$SESSION_MARKER"

import_saves

# --- environment ------------------------------------------------------------

export HOME="$STATE_ROOT"
export FUN_DRASTIC_DIR="$STATE_ROOT"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
export TMPDIR="$RUNTIME_DIR"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

# Fun DraStic runs the stock SDL2 Wayland driver; the steward package's custom
# "NDS" video backend belongs to the other NDS emulator and is not involved.
export SDL_VIDEODRIVER="${FUN_DRASTIC_SDL_VIDEODRIVER:-wayland}"
export SDL_VIDEO_WAYLAND_WMCLASS="${FUN_DRASTIC_WMCLASS:-fun-drastic}"
# Jawaka sets this itself as part of the frozen paired-controller roster
# contract; the vendor launcher was right to set it and it stays.
export SDL_JOYSTICK_DISABLE_UDEV=1

# Maintainer diagnostics, off by default.
export FUN_EVLOG="${FUN_EVLOG:-0}"
FUN_HOOK="${FUN_HOOK:-1}"
if [ -n "${FUN_FF_SPEED:-}" ]; then
    export FUN_FF_SPEED
fi

# Jawaka freezes a controller roster per launch and publishes it in
# SDL_JOYSTICK_DEVICE in player order. An inherited roster always wins. The
# fallback below only exists for a direct invocation outside Jawaka, and it
# resolves the calibrated virtual pad dynamically -- both Loong pads report the
# same name, so the uinput clone is identified by its virtual sysfs path.
resolve_mlp1_virtual_gamepad() {
    awk '
        # Reset on the record header, not on the blank line between records.
        # Every record starts with "I:", so this cannot be skipped; a
        # separator-based reset leaks state into the next record if the blank
        # line is ever absent, and the leak is silent -- it yields a real,
        # existing event node belonging to the previous device, which passes
        # the [ -e ] guard below.
        # (No apostrophes in here: the whole program is single-quoted.)
        /^I:/ {
            name = 0
            virtual = 0
            event = ""
        }
        /^N: Name="Loong Gamepad"/ {
            name = 1
        }
        /^S: Sysfs=\/devices\/virtual\/input\// {
            virtual = 1
        }
        /^H: Handlers=/ {
            # "H: Handlers=event6 dmcfreq" glues the first handler to the key,
            # so the field is "Handlers=event6" and a bare /^event[0-9]+$/ test
            # silently misses any device whose event node happens to come
            # first. Strip the key before matching.
            for (i = 1; i <= NF; i++) {
                handler = $i
                sub(/^Handlers=/, "", handler)
                if (handler ~ /^event[0-9]+$/) {
                    event = handler
                }
            }
        }
        name && virtual && event != "" {
            print "/dev/input/" event
            exit
        }
    ' /proc/bus/input/devices 2>/dev/null
}

if [ -z "${SDL_JOYSTICK_DEVICE:-}" ]; then
    if [ -n "${JAWAKA_RETROARCH_VIRTUAL_EVENT:-}" ] &&
       [ -e "$JAWAKA_RETROARCH_VIRTUAL_EVENT" ]; then
        fun_drastic_pad="$JAWAKA_RETROARCH_VIRTUAL_EVENT"
    else
        fun_drastic_pad="$(resolve_mlp1_virtual_gamepad || true)"
    fi
    if [ -n "$fun_drastic_pad" ] && [ -e "$fun_drastic_pad" ]; then
        export SDL_JOYSTICK_DEVICE="$fun_drastic_pad"
        log "no inherited roster; using calibrated virtual gamepad"
    else
        log "no inherited roster and no calibrated virtual gamepad; SDL scans for itself"
    fi
else
    log "using inherited Jawaka roster"
fi

# --- launch -----------------------------------------------------------------

DRASTIC_BIN="$ROOT_DIR/bin/drastic64"
for required in "$DRASTIC_BIN" "$ROOT_DIR/lib/libfundrastic.so" \
                "$ROOT_DIR/lib/libSDL2-2.0.so.0" "$ROOT_DIR/lib/libxkbcommon.so.0" \
                "$ROOT_DIR/lib/libwayland-cursor.so.0" "$ROOT_DIR/lib/libasound.so.2"; do
    if [ ! -e "$required" ]; then
        echo "Fun DraStic package is incomplete: $required" >&2
        exit 1
    fi
done

PRELOAD=""
if [ "$FUN_HOOK" = "1" ]; then
    PRELOAD="$ROOT_DIR/lib/libfundrastic.so"
fi

# The working directory is the whole of drastic64's path resolution.
cd "$STATE_ROOT"

log "launching drastic64 (hook=$FUN_HOOK driver=$SDL_VIDEODRIVER)"

# Not exec: the shared-save mirror has to run after the emulator exits, and a
# .dsv written during the session is exactly the thing that has to reach the
# other NDS package. Jawaka supervises the launcher's process group, so the
# emulator is still tracked and still killed with the session. Signals are
# forwarded so a Jawaka stop reaches drastic64 rather than only this shell.
emulator_pid=""
# Invoked only from the traps below, which shellcheck cannot see.
# shellcheck disable=SC2317,SC2329
forward_signal() {
    if [ -n "$emulator_pid" ]; then
        kill -"$1" "$emulator_pid" 2>/dev/null || true
    fi
}
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal HUP' HUP

set +e
LD_LIBRARY_PATH="$ROOT_DIR/lib" LD_PRELOAD="$PRELOAD" \
    "$DRASTIC_BIN" "$ROM_PATH" >>"$RUN_LOG" 2>&1 &
emulator_pid=$!
wait "$emulator_pid"
rc=$?
# A signalled wait returns before the child does; collect it properly.
if [ "$rc" -gt 128 ]; then
    wait "$emulator_pid" 2>/dev/null
    rc=$?
fi
set -e
trap - TERM INT HUP

log "drastic64 exited: rc=$rc"

export_saves

# One SD write at the end. Per-frame pacing lines from FUN_EVLOG are dropped;
# they are a maintainer diagnostic, not support evidence.
grep -v -e '^vf ticks' -e '^ticks_delta:' "$RUN_LOG" >"$LOG_FILE" 2>/dev/null ||
    cp -f "$RUN_LOG" "$LOG_FILE" 2>/dev/null || true
rm -f "$RUN_LOG" 2>/dev/null || true

exit "$rc"
