# Fun DraStic distribution basis

Fun DraStic is proprietary material redistributed with permission. It is not
open source and no open-source license applies to it. This file records the
basis on which the package is built and shipped.

## Permission

tenlevels, the author of Fun DraStic, gave the project written permission to
use and redistribute Fun DraStic as part of Leaf. The permission was given in
a private Discord message; a copy is preserved by the project maintainer with
the sender identity and date. The private message itself is not published.

Permission covers:

- hosting the reviewed source archive or a package derived from it;
- bundling that package in downloadable Leaf releases;
- the packaging-only changes described in this repository (a rewritten launch
  wrapper, an allowlisted file set, generated manifest and notices).

It does not transfer ownership and it does not make the material open source.

> **Release gate.** Before a public Leaf release includes Fun DraStic, confirm
> the preserved permission still covers the list above and record the archival
> reference in the release provenance. If it does not, Fun DraStic stays out of
> the default release list; the same packaging still supports an explicitly
> supplied local archive for authorized device-local use.

## Archival reference

The reviewed archive is hosted on this repository's own releases, under the
hosting permission recorded above:

| Field | Value |
| --- | --- |
| Release | `upstream/drastic-2026-09-01` |
| Asset | `drastic.zip` |
| SHA-256 | `63dcf22d5ab06db0ca797567aa6597ce8b1e99080d1b86f92648cc155641d302` |

`upstream.env` pins that URL and hash together. A new archive needs a new
release and a re-pin of both; the packaging refuses any archive whose hash does
not match.

## Component ownership

The package is not a single work. Each component keeps its own terms.

| Component | Owner / origin | Terms |
| --- | --- | --- |
| `lib/libfundrastic.so` (the Fun DraStic frontend hook) | tenlevels | Proprietary, used with permission |
| `Overlays/`, `themes/`, `res/cursor/` (presentation assets) | tenlevels | Proprietary, used with permission |
| `bin/drastic64` | Exophase / DraStic | Proprietary closed-source emulator; the same prebuilt binary the primary DraStic package ships |
| `system/drastic_bios_arm7.bin`, `system/drastic_bios_arm9.bin` | DraStic | DraStic's own free replacement BIOS, distributed with DraStic |
| `config/usrcheat.dat`, `game_database.xml` | DraStic distribution | Redistributed as part of the DraStic data set |
| `language/*.txt` | tenlevels and contributors | Proprietary, used with permission |
| `fonts/Nunito-Bold.ttf` | The Nunito Project Authors | SIL Open Font License 1.1 |
| `fonts/Translate.otf` | Adobe / the Noto Project (this is Noto Sans CJK SC Regular under another filename) | SIL Open Font License 1.1 |
| `lib/libSDL2-2.0.so.0` | SDL | zlib license |
| `lib/libasound.so.2` | ALSA project | LGPL-2.1-or-later |
| `lib/libxkbcommon.so.0` | xkbcommon | MIT |
| `lib/libwayland-cursor.so.0` | Wayland project | MIT |
| Packaging code in this repository | UMRK | See `LICENSE` |

tenlevels' permission is attributed only to the material tenlevels owns or is
authorized to redistribute. It is not a license for `bin/drastic64`, the
bundled libraries, or the fonts.

## Nintendo BIOS

The Nintendo DS BIOS and firmware dumps (`nds_bios_arm7.bin`,
`nds_bios_arm9.bin`, `nds_firmware.bin`) are never shipped, in any form. The
package gate and the Leaf release gate both reject them.
