# Fun-Drastic-standalone

Packaging for **Fun DraStic by tenlevels** as a second Nintendo DS standalone
emulator on the Miniloong Pocket 1, alongside - not instead of - the DraStic
package Leaf already ships.

Fun DraStic is tenlevels' project: he wrote the hook, designed the menus,
themes and overlays, brought up the MLP1 target, and donated the source so this
package can be built from it rather than from a binary. Nothing in this
repository is a fork of his work - it is packaging around it. His source is
mirrored at
[Fun-Drastic-src](https://github.com/Utility-Muffin-Research-Kitchen/Fun-Drastic-src),
and his own credits and licence ship inside every package.

| Role | Core id | Runtime path |
| --- | --- | --- |
| Default | `drastic` | `emulators/drastic/launch.sh` |
| Alternate | `fun_drastic` | `emulators/fun-drastic/launch.sh` |

## What this actually is

`bin/drastic64` in this package is byte-identical to the DraStic binary the
primary DraStic package already ships. Fun DraStic is not a different emulator:
it is a frontend - menus, overlays, screen layouts, themes - implemented in
`lib/libfundrastic.so`, an `LD_PRELOAD` SDL interposer. Compatibility, accuracy
and speed are the same in both packages. The interface is what differs.

Two properties of that hook drive most of the packaging:

1. **The whole frontend lives in the hook.** None of the steward package's
   `res/` menu arrangement or its `SDL_VIDEODRIVER=NDS` custom backend applies.
   Fun DraStic runs the stock SDL2 Wayland driver.
2. **Runtime data has three owners, not one.** The hook's exported symbols are
   all SDL, so it looks at first like it cannot touch file paths - but it also
   interposes `__libc_start_main`, and it rewrites where saves and savestates
   go before `main` runs. Confirmed on an MLP1: `drastic64` still resolves most
   of its data relative to the working directory, the hook resolves its own
   assets from `$FUN_DRASTIC_DIR`, and saves land in Leaf's public `Saves/`
   folder instead of the working directory's `backup/`.

That splits runtime data three ways, and the launch wrapper has to serve all of
it:

| Owner | Paths |
| --- | --- |
| `drastic64`, via the working directory | `config/`, `system/`, `microphone/`, `game_database.xml`, `usrcheat.dat`, and the `profiles/` `unzip_cache/` `input_record/` `cheats/` `slot2/` `scripts/` chain |
| the hook, via `$FUN_DRASTIC_DIR` | `fonts/`, `language/`, `themes/`, `Overlays/`, `res/cursor/` |
| the hook, via the working directory | `user_emu.cfg`, `user_controls.cfg`, `user_shortcuts.cfg` |
| the hook, via `$SDCARD_PATH` | `Saves/NDS/<rom>.sram`, `Saves/NDS/states/`, `Saves/NDS/previews/` |

The vendor launcher seeds only the first group. On a clean state root that
leaves the menu with no font and no translations, which is why the second is
not optional and has no fallback. The third is not seeded at all - the emulator
creates it - but it is where the shared-save mirror has to work, and it is
`$SDCARD_PATH`-relative rather than state-root-relative, so it follows the card
Leaf resolved rather than the emulator's private tree.

## Build

The hook is compiled from source. `src/funhook.c` lives in the sibling
`Fun-Drastic-src` checkout - a verbatim mirror of what tenlevels donated - and
is cross-built with the MLP1 toolchain, the same way the primary DraStic
package cross-builds `steward-fu-nds`:

```sh
make package-mlp1                       # sibling ../Fun-Drastic-src
make package-mlp1 FUN_DRASTIC_SRC_DIR=/path/to/a/working/tree
```

Docker is required, for the toolchain image only. `FUN_DRASTIC_BUILD=0`
packages a hook built earlier, matching `DRASTIC_BUILD=0` in the primary
DraStic packaging. Output lands in the ignored `output/mlp1/fun-drastic/`; the
build tree stays in the ignored `workdir/`.

DraStic itself is never built here and never will be: `bin/drastic64`, the free
BIOS, the game database and the cheat database are Exophase's proprietary
freeware, redistributed as tenlevels' tree bundles them. Each is pinned by
SHA-256 in `upstream.env`, so a source drop that quietly swaps the emulator
fails the build until it is reviewed and re-pinned.

Normally you do not run this directly. Leaf dispatches to it:

```sh
make stage-emulator EMULATOR=fun-drastic DEVICE=mlp1
```

### What gets packaged

An explicit allowlist in `package-mlp1.sh` mapping each package path to its
source path, so a file added to a future source drop cannot enter a release by
accident. The launcher, manifest, `README.txt` and `system/BIOS-README.txt` are
generated here and never taken from upstream. tenlevels' `LICENSE` and
`CREDITS.md` are copied in verbatim and are release-gated: a package that loses
them does not ship.

The package is about 35 MB, of which `fonts/Translate.otf` is 16.4 MB and
`config/usrcheat.dat` is 13.7 MB. The cheat database duplicates one the primary
DraStic package already ships, so staging both NDS emulators costs roughly
13.7 MB of pure duplication. Check that against the release ZIP budget before
enabling the package by default.

## BIOS

The package ships DraStic's own **free replacement BIOS**
(`drastic_bios_arm7.bin`, `drastic_bios_arm9.bin`), exactly as the primary
DraStic package does. Most games run on it with no setup.

The **Nintendo dumps** (`nds_bios_arm7.bin`, `nds_bios_arm9.bin`,
`nds_firmware.bin`) are user-supplied and never shipped, in any form. Users put
them in `BIOS/NDS/` and the wrapper copies whichever it finds into Fun DraStic's
private runtime `system/` directory. A missing dump is the normal case and never
fails a launch. Both this repo's package gate and Leaf's release gate reject the
three filenames outright.

## Saves

In-game saves are **shared** with the primary DraStic package. The two
emulators are the same binary, so the format is byte-for-byte identical, and a
game switched between them keeps its progress.

Where each one puts that save is not identical, which is the whole difficulty:

| | in-game save | savestates |
| --- | --- | --- |
| primary DraStic | `<its state root>/backup/<rom name>.dsv` | `<its state root>/savestates/` |
| Fun DraStic | `$SDCARD_PATH/Saves/NDS/<rom name>.sram` | `$SDCARD_PATH/Saves/NDS/states/` |

The hook rewrites the save and savestate paths at startup, so Fun DraStic
writes into Leaf's public `Saves/` folder and never touches `backup/`. Both
files carry the same DeSmuME footer and the same length; only the directory and
the extension differ. The card is FAT32, so no symlink can make one file serve
both names.

The wrapper mirrors instead: newest-wins in before launch, newest-wins out
after exit, and **only for the ROM being launched** - these are real saves, and
a session for one game has no business touching another's. Modification times
are preserved so an unplayed session rewrites nothing. Fun DraStic owns both
directions, which is why the primary DraStic package needs no change. Set
`FUN_DRASTIC_SHARE_SAVES=0` to keep them apart.

Configuration and savestates are **not** shared, and are not mirrored.

### The save-name caveat

Fun DraStic does not name the save after the ROM. It cuts the name at the first
`) (`, which looks like an attempt to strip No-Intro region and language tags
that stops one character short of the bracket:

```text
Mario Kart DS (USA, Australia) (En,Fr,De,Es,It).nds
  -> Saves/NDS/Mario Kart DS (USA, Australia.sram
```

A name with one bracketed tag, or none, is left alone. The wrapper reproduces
this rule so the import lands where the emulator will look for it, and always
writes the export back under the ROM's own name so the other package finds it.

The rule is reverse-engineered from an MLP1, not documented, so the wrapper
also checks it: if the session writes a `.sram` under a name it did not
predict, that file is exported anyway and a warning naming both goes in the
log. A rule change degrades to a logged surprise rather than silently losing a
save. Upstream fixing the truncation is on the wishlist.

## Wrapper corrections

The vendor launcher is kept only as a reference; the shipped wrapper is written
here. Upstream is frozen, so these are permanent, not stopgaps:

| Vendor launcher | This wrapper |
| --- | --- |
| State under `.umrk/mlp1/fundrastic` (`UMRK_INTERNAL_DATA_PATH`, launcher-owned control state) | `USERDATA_PATH/fun-drastic` |
| Support log written beside the installed package | `LOGS_PATH/fun-drastic.log`, scratch under `UMRK_RUNTIME_PATH` |
| `drastic.cfg` refreshed from the package every boot | Versioned migration through `defaults/config.version` |
| menu starts on the hook's own first theme | `defaults/user_emu.cfg` seeds `theme 5`, the CUSTOM slot that `themes/custom.cfg` names "Leaf" |
| hands `drastic64` the archive, leaving the hook unable to read the game code | Extracts a `.zip` first, keeping the ROM's base name, so the cheat menu resolves |
| `SDL_JOYSTICK_DEVICE` overwritten with `/dev/input/event5` | Inherited roster always wins; the direct-launch fallback resolves the calibrated virtual pad dynamically |
| Seeds only the `drastic64` half | Seeds both halves |

`SDL_JOYSTICK_DISABLE_UDEV=1` is the one thing the vendor launcher got right
about input, and it stays: Jawaka's frozen paired-controller roster contract
requires it.

## Tests

```sh
make smoke-launch-wrapper
```

The archive is not public, so CI cannot build a package. The smoke test builds
a synthetic package with a stub emulator and exercises the parts UMRK wrote:
the seeding split, state and log locations, BIOS handling, the roster contract,
the defaults stamp, the shared-save mirror, and exit-status propagation.

`scripts/validate-package.py` runs at the end of every package build. Leaf runs
its own gate again over the assembled release payload; the duplication is
deliberate, because the two catch different mistakes.

## Licensing

Fun DraStic is proprietary material redistributed with written permission from
tenlevels. It is not open source. `licenses/DISTRIBUTION-BASIS.md` records the
permission and the per-component ownership table;
`licenses/THIRD-PARTY-NOTICES.txt` carries the notices the bundled libraries and
fonts require. This repository's own `LICENSE` covers the UMRK-authored
packaging code only.

Before a public Leaf release includes Fun DraStic, confirm the preserved
permission still covers hosting, bundling and redistribution, and record the
archival reference in the release provenance.
