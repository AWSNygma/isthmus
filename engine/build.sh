#!/usr/bin/env bash
# Build the Isthmus engine: CodeWeavers' LGPL Wine tree + bundled x86_64
# dependencies + DXMT/DXVK/wine-mono/wine-gecko, packaged as a relocatable
# tarball that the Isthmus app installs into
#   ~/Library/Application Support/Isthmus/Engines/<version>/
#
# Usage: engine/build.sh [fetch|deps|configure|build|install|bundle|all]
#
# Wine runs as x86_64 under Rosetta 2 on Apple Silicon; 32-bit Windows code
# runs through Wine's WoW64 layer (--enable-archs=i386,x86_64), so no
# 32-bit macOS libraries are needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=engine.env
source "$HERE/engine.env"

WORK="${ISTHMUS_WORK:-$HERE/../.work}"
CACHE="$WORK/cache"
SRC="$WORK/src"
BUILD="$WORK/build"
DEPS="$WORK/deps-x64"
STAGE="$WORK/stage/isthmus-engine-$ENGINE_VERSION"
OUT="$WORK/out"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"
UA="Mozilla/5.0 (Macintosh) isthmus-engine-build"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

fetch_one() { # url dest
  local url="$1" dest="$2"
  [[ -s "$dest" ]] && return 0
  log "download $(basename "$dest")"
  curl -fL --retry 3 -A "$UA" -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

step_fetch() {
  mkdir -p "$CACHE" "$SRC"
  fetch_one "$CX_SOURCE_URL" "$CACHE/crossover-sources-$CX_SOURCE_VERSION.tar.gz"
  fetch_one "https://dl.winehq.org/wine/wine-mono/$WINE_MONO_VERSION/wine-mono-$WINE_MONO_VERSION-x86.tar.xz" \
            "$CACHE/wine-mono-$WINE_MONO_VERSION-x86.tar.xz"
  for a in x86 x86_64; do
    fetch_one "https://dl.winehq.org/wine/wine-gecko/$WINE_GECKO_VERSION/wine-gecko-$WINE_GECKO_VERSION-$a.tar.xz" \
              "$CACHE/wine-gecko-$WINE_GECKO_VERSION-$a.tar.xz"
  done
  fetch_one "https://github.com/3Shain/dxmt/releases/download/$DXMT_VERSION/dxmt-$DXMT_VERSION-builtin.tar.gz" \
            "$CACHE/dxmt-$DXMT_VERSION-builtin.tar.gz"
  fetch_one "https://github.com/Gcenx/DXVK-macOS/releases/download/$DXVK_MACOS_VERSION/dxvk-macOS-async-$DXVK_MACOS_VERSION-builtin.tar.gz" \
            "$CACHE/dxvk-macos-$DXVK_MACOS_VERSION-builtin.tar.gz"

  if [[ ! -d "$SRC/wine" ]]; then
    log "extract CrossOver $CX_SOURCE_VERSION sources"
    rm -rf "$SRC/tmp" && mkdir -p "$SRC/tmp"
    tar -xzf "$CACHE/crossover-sources-$CX_SOURCE_VERSION.tar.gz" -C "$SRC/tmp"
    mv "$SRC/tmp/sources/wine" "$SRC/wine"
    rm -rf "$SRC/tmp"
    local p
    shopt -s nullglob
    for p in "$HERE"/patches/*.patch; do
      log "apply $(basename "$p")"
      patch -d "$SRC/wine" -p1 --forward --no-backup-if-mismatch < "$p"
    done
    shopt -u nullglob
  fi
}

step_deps() {
  command -v micromamba >/dev/null || die "micromamba not found (brew install micromamba)"
  if [[ -x "$DEPS/lib/libfreetype.dylib" || -e "$DEPS/lib/libfreetype.dylib" ]]; then
    log "deps already present at $DEPS"; return 0
  fi
  log "create osx-64 dependency prefix"
  local pkgs; pkgs=$(grep -vE '^\s*(#|$)' "$HERE/deps.txt" | tr '\n' ' ')
  MAMBA_ROOT_PREFIX="$WORK/mamba" micromamba create -y -p "$DEPS" \
    --platform osx-64 -c conda-forge $pkgs
}

# Everything that compiles host code runs under Rosetta so configure's test
# programs execute. mingw (PE cross compiler) is an arm64 binary; that's fine.
x86() { arch -x86_64 /usr/bin/env "$@"; }

build_env() {
  local bison; bison="$(brew --prefix bison)/bin"
  local gettext; gettext="$(brew --prefix gettext)/bin"
  export PATH="$bison:$gettext:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export CC="ccache clang -arch x86_64"
  export CXX="ccache clang++ -arch x86_64"
  export i386_CC="ccache i686-w64-mingw32-gcc"
  export x86_64_CC="ccache x86_64-w64-mingw32-gcc"
  export PKG_CONFIG="$(command -v pkgconf || command -v pkg-config)"
  export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig"
  export CPPFLAGS="-I$DEPS/include"
  # Unix-side .so modules live in lib/wine/x86_64-unix; bundled dylibs in lib/.
  export LDFLAGS="-L$DEPS/lib -Wl,-rpath,@loader_path/../.. -Wl,-rpath,$DEPS/lib -Wl,-headerpad_max_install_names"
  export CFLAGS="-O2 -g"
  export CROSSCFLAGS="-O2 -g"
  export MACOSX_DEPLOYMENT_TARGET=13.0
  export CCACHE_DIR="$WORK/ccache"
  # Newer SDKs declare functions that older macOS releases lack at runtime.
  # Wine weak-links them, so they resolve to NULL and crash on call
  # (pipe2: in the Xcode 27 SDK, missing on macOS 26). Force the fallbacks.
  export ac_cv_func_pipe2=no
  # Link winevulkan straight to MoltenVK instead of the Khronos loader: the
  # loader hides portability drivers (MoltenVK) unless the app opts in, and
  # Windows games never do.
  export ac_cv_lib_soname_vulkan=""
}

step_configure() {
  build_env
  mkdir -p "$BUILD"
  log "configure wine (x86_64 host, i386+x86_64 PE, WoW64)"
  (cd "$BUILD" && x86 "$SRC/wine/configure" \
    --prefix=/ \
    --disable-tests \
    --enable-win64 \
    --enable-archs=i386,x86_64 \
    --with-mingw \
    --with-coreaudio --with-freetype --with-gnutls --with-gstreamer \
    --with-sdl --with-unwind --with-vulkan --with-pthread \
    --without-x --without-wayland --without-alsa --without-pulse --without-oss \
    --without-capi --without-dbus --without-fontconfig --without-gphoto \
    --without-gssapi --without-krb5 --without-netapi --without-sane \
    --without-udev --without-usb --without-v4l2 --without-inotify \
    2>&1 | tee "$WORK/configure.log")
  grep -E "^configure: (WARNING|error)" "$WORK/configure.log" || true
}

step_build() {
  build_env
  log "make -j$JOBS"
  if ! (cd "$BUILD" && x86 make -j"$JOBS" >"$WORK/make.log" 2>&1); then
    grep -E "error:|Error [0-9]" "$WORK/make.log" | head -20 >&2
    die "make failed; see $WORK/make.log"
  fi
  [[ -x "$BUILD/loader/wine" || -e "$BUILD/wine" ]] || die "no wine loader produced; see $WORK/make.log"
}

step_install() {
  build_env
  rm -rf "$STAGE" && mkdir -p "$STAGE"
  log "install into stage"
  (cd "$BUILD" && x86 make install-lib DESTDIR="$STAGE" -j"$JOBS" >"$WORK/install.log" 2>&1) \
    || die "install failed; see $WORK/install.log"
}

# Copy a dylib and its non-system dependency closure into $STAGE/lib.
bundle_dylib_closure() {
  local queue=("$@") seen=" " lib name dep
  while ((${#queue[@]})); do
    lib="${queue[0]}"; queue=("${queue[@]:1}")
    name="$(basename "$lib")"
    [[ "$seen" == *" $name "* ]] && continue
    seen+="$name "
    [[ -e "$DEPS/lib/$name" ]] || continue
    cp -a "$DEPS/lib/$name" "$STAGE/lib/" 2>/dev/null || true
    # follow symlink target too
    if [[ -L "$DEPS/lib/$name" ]]; then
      local tgt; tgt="$(readlink "$DEPS/lib/$name")"; cp -a "$DEPS/lib/$tgt" "$STAGE/lib/" 2>/dev/null || true
      queue+=("$tgt")
    fi
    while read -r dep; do
      case "$dep" in
        @rpath/*) queue+=("${dep#@rpath/}") ;;
        "$DEPS"/lib/*) queue+=("$(basename "$dep")") ;;
      esac
    done < <(otool -L "$DEPS/lib/$name" | tail -n +2 | awk '{print $1}')
  done
}

step_bundle() {
  [[ -d "$STAGE/lib/wine" ]] || die "run install first"
  log "bundle dependency dylibs"
  bundle_dylib_closure \
    libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libMoltenVK.dylib \
    libgstreamer-1.0.0.dylib libgstbase-1.0.0.dylib libgstaudio-1.0.0.dylib \
    libgstvideo-1.0.0.dylib libgsttag-1.0.0.dylib libgstapp-1.0.0.dylib \
    libgstpbutils-1.0.0.dylib libglib-2.0.0.dylib libgobject-2.0.0.dylib \
    libgio-2.0.0.dylib libgmodule-2.0.0.dylib libintl.8.dylib libpcap.dylib
  # Make sure Wine's unix modules find bundled libs (dlopen by leaf name uses
  # DYLD_FALLBACK_LIBRARY_PATH, set by the launcher; @rpath links use rpath).
  # Strip absolute build-machine rpaths so the engine is relocatable.
  local so rp
  for so in "$STAGE"/lib/wine/x86_64-unix/*.so "$STAGE"/lib/*.dylib; do
    [[ -L "$so" ]] && continue
    while read -r rp; do
      install_name_tool -delete_rpath "$rp" "$so" 2>/dev/null || true
    done < <(otool -l "$so" | awk '/LC_RPATH/{getline; getline; print $2}' | grep -E "^/(Users|opt|private|var|tmp)" || true)
  done
  for so in "$STAGE"/lib/wine/x86_64-unix/*.so; do
    otool -l "$so" | grep -q "@loader_path/../.." || \
      install_name_tool -add_rpath "@loader_path/../.." "$so" 2>/dev/null || true
  done

  log "bundle GStreamer plugins"
  mkdir -p "$STAGE/lib/gstreamer-1.0"
  local plug
  for plug in coreelements app audioconvert audioresample audioparsers videoconvertscale \
              playback typefindfunctions isomp4 matroska libav wavparse id3demux \
              autodetect volume videoparsersbad asf ogg vorbis opus theora vpx; do
    [[ -e "$DEPS/lib/gstreamer-1.0/libgst$plug.dylib" ]] || continue
    cp -a "$DEPS/lib/gstreamer-1.0/libgst$plug.dylib" "$STAGE/lib/gstreamer-1.0/"
    bundle_dylib_closure $(otool -L "$DEPS/lib/gstreamer-1.0/libgst$plug.dylib" | tail -n +2 | awk '{print $1}' | sed 's#@rpath/##' | xargs -n1 basename)
  done

  log "MoltenVK ICD"
  mkdir -p "$STAGE/share/vulkan/icd.d"
  cat > "$STAGE/share/vulkan/icd.d/MoltenVK_icd.json" <<'JSON'
{ "file_format_version": "1.0.0",
  "ICD": { "library_path": "../../../lib/libMoltenVK.dylib", "api_version": "1.2.0", "is_portability_driver": true } }
JSON

  log "wine-mono / wine-gecko"
  mkdir -p "$STAGE/share/wine/mono" "$STAGE/share/wine/gecko"
  tar -xJf "$CACHE/wine-mono-$WINE_MONO_VERSION-x86.tar.xz" -C "$STAGE/share/wine/mono"
  for a in x86 x86_64; do tar -xJf "$CACHE/wine-gecko-$WINE_GECKO_VERSION-$a.tar.xz" -C "$STAGE/share/wine/gecko"; done

  log "DXMT $DXMT_VERSION"
  local t; t="$(mktemp -d)"
  tar -xzf "$CACHE/dxmt-$DXMT_VERSION-builtin.tar.gz" -C "$t"
  mkdir -p "$STAGE/lib/dxmt"
  cp -R "$t"/*/* "$STAGE/lib/dxmt/" 2>/dev/null || cp -R "$t"/* "$STAGE/lib/dxmt/"
  rm -rf "$t"

  log "DXVK-macOS $DXVK_MACOS_VERSION"
  t="$(mktemp -d)"
  tar -xzf "$CACHE/dxvk-macos-$DXVK_MACOS_VERSION-builtin.tar.gz" -C "$t"
  mkdir -p "$STAGE/lib/dxvk"
  cp -R "$t"/*/* "$STAGE/lib/dxvk/" 2>/dev/null || cp -R "$t"/* "$STAGE/lib/dxvk/"
  rm -rf "$t"

  log "licenses + manifest"
  mkdir -p "$STAGE/share/licenses"
  cp "$SRC/wine/COPYING.LIB" "$STAGE/share/licenses/wine-COPYING.LIB"
  cp "$SRC/wine/LICENSE" "$STAGE/share/licenses/wine-LICENSE"
  cp "$HERE/../THIRD_PARTY_NOTICES.md" "$STAGE/share/licenses/" 2>/dev/null || true
  cat > "$STAGE/engine.json" <<JSON
{
  "name": "isthmus-engine",
  "version": "$ENGINE_VERSION",
  "wine": "$(sed 's/Wine version //' "$SRC/wine/VERSION")",
  "source": "CodeWeavers CrossOver $CX_SOURCE_VERSION LGPL source release",
  "arch": "x86_64",
  "components": {
    "wine-mono": "$WINE_MONO_VERSION",
    "wine-gecko": "$WINE_GECKO_VERSION",
    "dxmt": "$DXMT_VERSION",
    "dxvk-macos": "$DXVK_MACOS_VERSION",
    "moltenvk": "$(ls "$DEPS"/conda-meta | grep '^moltenvk-' | sed -E 's/^moltenvk-([^-]+)-.*/\1/')"
  },
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

  log "strip debug info"
  find "$STAGE/lib" \( -name "*.so" -o -name "*.dylib" \) -type f | while read -r f; do strip -S "$f" 2>/dev/null || true; done
  # PE modules carry DWARF from -g; release engines don't need it (~1.1 GB).
  local pe
  for pe in "$STAGE"/lib/wine/x86_64-windows/* "$STAGE"/lib/wine/i386-windows/*; do
    [[ -f "$pe" ]] || continue
    case "$pe" in *.a) continue ;; esac
    if [[ "$pe" == *i386-windows* ]]; then i686-w64-mingw32-strip --strip-debug "$pe" 2>/dev/null || true
    else x86_64-w64-mingw32-strip --strip-debug "$pe" 2>/dev/null || true; fi
  done

  mkdir -p "$OUT"
  local tarball="$OUT/isthmus-engine-$ENGINE_VERSION.tar.xz"
  log "pack $tarball"
  tar -C "$(dirname "$STAGE")" -cf - "$(basename "$STAGE")" | xz -T0 -6 > "$tarball.part"
  mv "$tarball.part" "$tarball"
  shasum -a 256 "$tarball" | tee "$tarball.sha256"
}

case "${1:-all}" in
  fetch) step_fetch ;;
  deps) step_deps ;;
  configure) step_configure ;;
  build) step_build ;;
  install) step_install ;;
  bundle) step_bundle ;;
  all) step_fetch; step_deps; step_configure; step_build; step_install; step_bundle ;;
  *) die "unknown step $1" ;;
esac
