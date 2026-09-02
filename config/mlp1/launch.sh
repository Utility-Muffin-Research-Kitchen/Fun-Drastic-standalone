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
#   drastic64  resolves config/, system/, savestates/, backup/, microphone/,
#              game_database.xml and usrcheat.dat relative to its working
#              directory. It interposes no file I/O, so the working directory
#              is the only lever.
#   the hook   resolves fonts/, language/, themes/, Overlays/ and res/cursor/
#              from $FUN_DRASTIC_DIR, with no fallback. A missing font is not
#              a degraded menu, it is an unrendered one.
#
# Both halves are seeded below. The vendor launcher seeds only the first.

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
            cp -f "$source_bios" "$target_bios" 2>/dev/null &&
                log "installed user BIOS: $bios_name" ||
                log "WARNING: could not install user BIOS: $bios_name"
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

# drastic64 is byte-identical in both NDS packages, so the .dsv format is
# guaranteed compatible and a game switched between the two emulators should
# keep its progress. The binary resolves backup/ relative to its working
# directory with no override, and the SD card is FAT32 (no symlinks), so the
# shared root is maintained by mirroring rather than by a shared inode.
#
# Fun DraStic owns both directions of the mirror: newer-wins in before launch,
# newer-wins out after exit. That keeps the primary DraStic package unmodified
# and still leaves both directories current whichever emulator ran last.
# Configuration and savestates stay separate; only .dsv files move.
PRIMARY_DRASTIC_STATE_ROOT="${PRIMARY_DRASTIC_STATE_ROOT:-${UMRK_INTERNAL_DATA_PATH:-$SDCARD_PATH/.umrk/$PLATFORM}/drastic}"
PRIMARY_BACKUP_DIR="$PRIMARY_DRASTIC_STATE_ROOT/backup"
SHARE_SAVES="${FUN_DRASTIC_SHARE_SAVES:-1}"

mirror_saves() {
    local from="$1" to="$2" direction="$3"
    [ -d "$from" ] || return 0
    [ -d "$to" ] || return 0
    local source_file base target
    for source_file in "$from"/*.dsv; do
        [ -f "$source_file" ] || continue
        base="$(basename "$source_file")"
        target="$to/$base"
        if [ -f "$target" ] && [ ! "$source_file" -nt "$target" ]; then
            continue
        fi
        if cp -f "$source_file" "$target" 2>/dev/null; then
            log "save $direction: $base"
        else
            log "WARNING: save $direction failed: $base"
        fi
    done
}

if [ "$SHARE_SAVES" = "1" ] && [ -d "$PRIMARY_BACKUP_DIR" ]; then
    mirror_saves "$PRIMARY_BACKUP_DIR" "$STATE_ROOT/backup" "imported"
elif [ "$SHARE_SAVES" = "1" ]; then
    log "primary DraStic saves not present at $PRIMARY_BACKUP_DIR; nothing to import"
fi

export_saves() {
    [ "$SHARE_SAVES" = "1" ] || return 0
    [ -d "$PRIMARY_BACKUP_DIR" ] || return 0
    mirror_saves "$STATE_ROOT/backup" "$PRIMARY_BACKUP_DIR" "exported"
}

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
        /^$/ {
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
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^event[0-9]+$/) {
                    event = $i
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
