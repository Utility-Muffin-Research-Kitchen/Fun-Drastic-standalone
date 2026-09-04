# Fun DraStic distribution basis

**Fun DraStic is tenlevels' work.** This repository packages it for Leaf on the
MLP1; it does not author it. The hook, the menus, the themes, the overlays and
the MLP1 bring-up are his. This file records the terms the package is built and
shipped under.

## Licence

Fun DraStic's own code and packaging are under the **PolyForm Noncommercial
License 1.0.0**, with the required notice:

> Copyright (c) 2026 The Fun Drastic authors

The full text ships in the package as `licenses/FUN-DRASTIC-LICENSE.txt`, taken
verbatim from his source tree. Use, modification and sharing are permitted for
**noncommercial purposes only**.

That is a change from how this package started. It was first built from a
binary drop redistributed under written permission given in a private Discord
message. tenlevels then donated the source under PolyForm Noncommercial, which
supersedes that arrangement: the basis is now a published licence anyone can
read and check, rather than a private message only the maintainer holds.

> **Release gate.** Any Leaf release bundling Fun DraStic inherits the
> noncommercial restriction. Leaf must not be sold, bundled with hardware for
> sale, or otherwise commercially exploited while this package is in the
> release list. If that changes, Fun DraStic comes out of the default release
> list; the packaging still supports a local build for noncommercial use.

## What is built here, and what is not

`lib/libfundrastic.so` is cross-compiled from tenlevels' `src/funhook.c` with
the MLP1 toolchain — the manifest records the source repository, commit and the
SHA-256 of the exact `funhook.c` it came from. Building it from source rather
than shipping his binary is the only reason this repository can claim to know
what is in it.

Everything else that is not ours is redistributed unmodified and pinned by
hash in `upstream.env`, because we do not compile it.

## Component ownership

The package is not a single work. Each component keeps its own terms.

| Component | Owner / origin | Terms |
| --- | --- | --- |
| `lib/libfundrastic.so` (the Fun DraStic hook) | tenlevels | PolyForm Noncommercial 1.0.0; built here from his source |
| `Overlays/`, `themes/`, `res/cursor/`, `language/*.txt` (presentation assets) | tenlevels and contributors | PolyForm Noncommercial 1.0.0 |
| `bin/drastic64` | Exophase / DraStic | Proprietary closed-source emulator; the same prebuilt binary the primary DraStic package ships |
| `system/drastic_bios_arm7.bin`, `system/drastic_bios_arm9.bin` | DraStic | DraStic's own free replacement BIOS, distributed with DraStic |
| `game_database.xml` | DraStic distribution | Redistributed as part of the DraStic data set |
| `config/usrcheat.dat` | the DS cheat scene | Community-maintained cheat database, assembled over many years |
| `fonts/Nunito-Bold.ttf` | The Nunito Project Authors | SIL Open Font License 1.1 |
| `fonts/Translate.otf` | Adobe / the Noto Project (this is Noto Sans CJK SC Regular under another filename) | SIL Open Font License 1.1 |
| `lib/libSDL2-2.0.so.0` | SDL | zlib license |
| `lib/libasound.so.2` | ALSA project | LGPL-2.1-or-later |
| `lib/libxkbcommon.so.0` | xkbcommon | MIT |
| `lib/libwayland-cursor.so.0` | Wayland project | MIT |
| Packaging code in this repository | UMRK | See `LICENSE` |

The PolyForm licence covers what tenlevels owns. It is not a licence for
`bin/drastic64`, the DraStic databases, the bundled libraries, or the fonts —
`licenses/CREDITS.md`, which is his own credits file, is the authoritative list
of what Fun DraStic is built on.

Fun DraStic is not affiliated with or endorsed by Exophase or Nintendo.

## Nintendo BIOS

The Nintendo DS BIOS and firmware dumps (`nds_bios_arm7.bin`,
`nds_bios_arm9.bin`, `nds_firmware.bin`) are never shipped, in any form. The
package gate and the Leaf release gate both reject them.
