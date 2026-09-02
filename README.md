# Fun-Drastic-standalone

Packaging for **Fun DraStic by tenlevels** as a second Nintendo DS standalone
emulator on the Miniloong Pocket 1, alongside - not instead of - the DraStic
package Leaf already ships.

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
2. **File I/O is not intercepted.** The hook interposes SDL calls only - no
   `open`, `fopen`, `stat`, or `access`. So `drastic64` still resolves its data
   relative to the working directory, and the hook resolves its own assets from
   `$FUN_DRASTIC_DIR`. Nothing can be virtualized away.

That splits runtime data between two owners, and the launch wrapper seeds both:

| Owner | Paths, relative to the state root |
| --- | --- |
| `drastic64`, via the working directory | `config/`, `system/`, `savestates/`, `backup/`, `microphone/`, `game_database.xml`, `usrcheat.dat` |
| the hook, via `$FUN_DRASTIC_DIR` | `fonts/`, `language/`, `themes/`, `Overlays/`, `res/cursor/` |

The vendor launcher seeds only the first half. On a clean state root that
leaves the menu with no font and no translations, which is why the second half
is not optional and has no fallback.

## Build

Upstream is frozen - tenlevels is not working on Fun DraStic in the near
future - and the archive has no authorized public home yet. `upstream.env`
therefore pins the SHA-256 only, and the reviewed archive is supplied
explicitly:

```sh
make package-mlp1 FUN_DRASTIC_ARCHIVE=/absolute/path/to/drastic.zip
```

The build refuses an archive whose hash does not match the pin. Output lands in
the ignored `output/mlp1/fun-drastic/`; downloads and extraction stay in the
ignored `workdir/`.

Normally you do not run this directly. Leaf dispatches to it:

```sh
make stage-emulator EMULATOR=fun-drastic DEVICE=mlp1
```

### What gets packaged

An explicit allowlist in `package-mlp1.sh`, so a file added to a future archive
cannot enter a release by accident. The launcher, manifest, `README.txt` and
`system/BIOS-README.txt` are generated here and never taken from the archive.

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

In-game `.dsv` saves are **shared** with the primary DraStic package. The two
emulators are the same binary, so the format is guaranteed compatible, and a
game switched between them keeps its progress.

`drastic64` resolves `backup/` relative to its working directory with no
override, and the SD card is FAT32, so there is no shared inode to point both
at. The wrapper mirrors instead: newest-wins in before launch, newest-wins out
after exit. Fun DraStic owns both directions, which is why the primary DraStic
package needs no change. Set `FUN_DRASTIC_SHARE_SAVES=0` to keep them apart.

Configuration and savestates are **not** shared, and are not mirrored.

## Wrapper corrections

The vendor launcher is kept only as a reference; the shipped wrapper is written
here. Upstream is frozen, so these are permanent, not stopgaps:

| Vendor launcher | This wrapper |
| --- | --- |
| State under `.umrk/mlp1/fundrastic` (`UMRK_INTERNAL_DATA_PATH`, launcher-owned control state) | `USERDATA_PATH/fun-drastic` |
| Support log written beside the installed package | `LOGS_PATH/fun-drastic.log`, scratch under `UMRK_RUNTIME_PATH` |
| `drastic.cfg` refreshed from the package every boot | Versioned migration through `defaults/config.version` |
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
