#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS="14.0"
ROOT="$PWD/.ffmpeg-build"
SRC="$ROOT/sources"
WORK="$ROOT/work"
PREFIX="$ROOT/prefix"
OUT="$ROOT/out"
JOBS="$(sysctl -n hw.ncpu)"

for tool in cmake meson ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. Install with: brew install cmake meson ninja pkgconf"; exit 1; }
done

mkdir -p "$SRC" "$WORK" "$PREFIX" "$OUT"

export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
export CFLAGS="-mmacosx-version-min=$MIN_MACOS -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-mmacosx-version-min=$MIN_MACOS"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH C_INCLUDE_PATH

fetch() {
  local name="$1" url="$2" sha="$3" file="$SRC/$1"
  if [ ! -f "$file" ] || ! echo "$sha  $file" | shasum -a 256 -c --status; then
    curl -fL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c
  fi
}

built() { [ -f "$ROOT/.built-$1" ] && echo "==> $1 (already built)"; }
mark() { touch "$ROOT/.built-$1"; }

unpack() {
  local file="$SRC/$1" dir="$WORK/$2"
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xf "$file" -C "$dir" --strip-components 1
  cd "$dir"
}

fetch ffmpeg-9.0.2.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
fetch x265_4.3.tar.gz https://github.com/Multicorewareinc/x265/releases/download/4.3/x265_4.3.tar.gz 83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121
fetch lame-4.0.tar.gz https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz 3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
fetch opus-1.6.1.tar.gz https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
fetch libvpx-1.17.0.tar.gz https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz 1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a
fetch SVT-AV1-v4.2.0.tar.bz2 https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.2.0/SVT-AV1-v4.2.0.tar.bz2 512f2ea5649e3e76c2dddcc25c2556fb67a9582baaab207c9c96161c94659dad
fetch dav1d-1.5.4.tar.bz2 https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2 2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011

X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
if [ ! -f "$SRC/x264-$X264_COMMIT.tar.gz" ]; then
  rm -rf "$WORK/x264-git"
  git clone --quiet https://code.videolan.org/videolan/x264.git "$WORK/x264-git"
  git -C "$WORK/x264-git" archive --format=tar.gz --prefix=x264/ -o "$SRC/x264-$X264_COMMIT.tar.gz" "$X264_COMMIT"
  rm -rf "$WORK/x264-git"
fi

if ! built x264; then
echo "==> x264"
unpack "x264-$X264_COMMIT.tar.gz" x264
./configure --prefix="$PREFIX" --enable-static --disable-cli --enable-pic \
  --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" >/dev/null
make -j"$JOBS" >/dev/null && make install >/dev/null

mark x264; fi

if ! built x265; then
echo "==> x265"
unpack x265_4.3.tar.gz x265
cmake -S source -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF >/dev/null
ninja -C build >/dev/null && ninja -C build install >/dev/null

mark x265; fi

if ! built lame; then
echo "==> lame"
unpack lame-4.0.tar.gz lame
./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-frontend --disable-decoder >/dev/null
make -j"$JOBS" >/dev/null && make install >/dev/null

mark lame; fi

if ! built opus; then
echo "==> opus"
unpack opus-1.6.1.tar.gz opus
./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-doc --disable-extra-programs >/dev/null
make -j"$JOBS" >/dev/null && make install >/dev/null

mark opus; fi

if ! built libvpx; then
echo "==> libvpx"
unpack libvpx-1.17.0.tar.gz libvpx
./configure --prefix="$PREFIX" --target=arm64-darwin23-gcc --enable-static --disable-shared --enable-pic \
  --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth >/dev/null
make -j"$JOBS" >/dev/null && make install >/dev/null

mark libvpx; fi

if ! built svt-av1; then
echo "==> svt-av1"
unpack SVT-AV1-v4.2.0.tar.bz2 svtav1
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF >/dev/null
ninja -C build >/dev/null && ninja -C build install >/dev/null

mark svt-av1; fi

if ! built dav1d; then
echo "==> dav1d"
unpack dav1d-1.5.4.tar.bz2 dav1d
meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
  -Denable_tools=false -Denable_tests=false >/dev/null
ninja -C build >/dev/null && ninja -C build install >/dev/null
mark dav1d; fi

echo "==> ffmpeg"
unpack ffmpeg-9.0.2.tar.xz ffmpeg
./configure --prefix="$PREFIX" --pkg-config-flags=--static \
  --enable-gpl --enable-version3 --disable-autodetect \
  --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv \
  --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus \
  --enable-libvpx --enable-libsvtav1 --enable-libdav1d \
  --disable-ffplay --disable-doc --disable-network --disable-indevs --disable-outdevs \
  --extra-cflags="$CFLAGS -I$PREFIX/include" --extra-ldflags="$LDFLAGS -L$PREFIX/lib" --extra-libs="-lc++ -liconv" >/dev/null
make -j"$JOBS" >/dev/null
cp ffmpeg ffprobe "$OUT/"
strip "$OUT/ffmpeg" "$OUT/ffprobe"

echo "==> done"
for b in "$OUT/ffmpeg" "$OUT/ffprobe"; do
  echo "$b: $(otool -l "$b" | awk '/minos/ {print "macOS " $2; exit}')"
  otool -L "$b" | tail -n +2 | grep -v -E "/System/Library/|/usr/lib/" && { echo "Unexpected non-system dependency"; exit 1; } || true
done
