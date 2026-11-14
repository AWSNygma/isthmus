# Third-party software in Isthmus

Isthmus itself (the app, the `isthmus` CLI and IsthmusKit) is licensed under
the GNU General Public License v3.0 or later; see `LICENSE`.

The **engine** archive (`isthmus-engine-*.tar.xz`) is a separate download that
bundles the projects below. Each keeps its own license. Source code for every
component is available from the linked project; the exact Wine tree we build
is CodeWeavers' published source release, fetched by `engine/build.sh` from
<https://media.codeweavers.com/pub/crossover/source/>. On request we will
provide a copy of the corresponding source for any engine release (open an
issue on the repository).

| Component | Used for | License | Source |
|---|---|---|---|
| Wine (CodeWeavers CrossOver source release) | Windows API implementation | LGPL-2.1-or-later | https://www.codeweavers.com/crossover/source |
| vkd3d (inside the Wine tree) | Direct3D 12 → Vulkan | LGPL-2.1-or-later | https://gitlab.winehq.org/wine/vkd3d |
| DXMT | Direct3D 10/11 → Metal | LGPL-2.1-or-later | https://github.com/3Shain/dxmt |
| DXVK (macOS fork) | Direct3D 10/11 → Vulkan | zlib | https://github.com/Gcenx/DXVK-macOS |
| MoltenVK | Vulkan → Metal | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK |
| Wine Mono | .NET Framework implementation | MIT (+ component licenses) | https://github.com/madewokherd/wine-mono |
| Wine Gecko | HTML engine for mshtml | MPL-2.0 | https://gitlab.winehq.org/wine/wine-gecko |
| GStreamer + plugins (base, good, bad, libav) | Media playback for games' video/audio | LGPL-2.1-or-later | https://gstreamer.freedesktop.org |
| FFmpeg (via gst-libav) | Codecs | LGPL-2.1-or-later / GPL-2.0-or-later (conda-forge build) | https://ffmpeg.org |
| GLib | GStreamer dependency | LGPL-2.1-or-later | https://gitlab.gnome.org/GNOME/glib |
| GnuTLS, Nettle, GMP | TLS for Windows networking APIs | LGPL-2.1+ / LGPL-3.0+ or GPL-2.0+ | https://gnutls.org |
| FreeType | Font rendering | FTL or GPL-2.0 | https://freetype.org |
| SDL2 | Game controller input | zlib | https://libsdl.org |
| libffi, PCRE2, libintl, zlib, libpng | Support libraries | MIT / BSD / LGPL / zlib | conda-forge |

The x86_64 macOS builds of the support libraries come from
[conda-forge](https://conda-forge.org); `engine/deps.txt` lists the packages.

## Not included

- **D3DMetal** (Apple Game Porting Toolkit) is proprietary. Isthmus never
  distributes it. Users download the toolkit from Apple and import it locally.
- **CrossOver** is a trademark of CodeWeavers, Inc. Isthmus is not affiliated
  with or endorsed by CodeWeavers. We use only their LGPL source release, never
  code or assets from the CrossOver application.
- **Wine** is a trademark of the Wine project; used here only to describe the
  software Isthmus is built on.
- Store launchers (Steam, Epic, GOG Galaxy, Battle.net, EA app, Ubisoft
  Connect) and Microsoft runtimes are downloaded from their vendors at the
  user's request and are covered by the vendors' own terms.
