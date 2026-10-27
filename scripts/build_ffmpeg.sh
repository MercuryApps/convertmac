#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MIN_MACOS="14.0"
ROOT="$PWD/.ffmpeg-build"
SRC="$ROOT/sources"
JOBS="$(sysctl -n hw.ncpu)"
ARCHS="${ARCHS:-arm64 x86_64}"

for tool in cmake meson ninja pkg-config nasm autoreconf; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. Install with: brew install cmake meson ninja pkgconf nasm autoconf automake libtool"; exit 1; }
done
mkdir -p "$SRC"

fetch() {
  local name="$1" url="$2" sha="$3" file="$SRC/$1"
  if [ ! -f "$file" ] || ! echo "$sha  $file" | shasum -a 256 -c --status; then
    curl -fL --retry 3 -o "$file" "$url"
    echo "$sha  $file" | shasum -a 256 -c
  fi
}

fetch ffmpeg-9.0.2.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
fetch x265_4.3.tar.gz https://github.com/Multicorewareinc/x265/releases/download/4.3/x265_4.3.tar.gz 83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121
fetch lame-4.0.tar.gz https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz 3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
fetch opus-1.6.1.tar.gz https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
fetch libvpx-1.17.0.tar.gz https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz 1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a
fetch SVT-AV1-v4.2.0.tar.bz2 https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.2.0/SVT-AV1-v4.2.0.tar.bz2 512f2ea5649e3e76c2dddcc25c2556fb67a9582baaab207c9c96161c94659dad
fetch dav1d-1.5.4.tar.bz2 https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2 2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011
fetch zimg-3.0.6.tar.gz https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.6.tar.gz be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577
fetch freetype-2.15.0.tar.xz https://downloads.sourceforge.net/project/freetype/freetype2/2.15.0/freetype-2.15.0.tar.xz 93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5
fetch fribidi-1.0.17.tar.xz https://github.com/fribidi/fribidi/releases/download/v1.0.17/fribidi-1.0.17.tar.xz 6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2
fetch harfbuzz-15.0.0.tar.xz https://github.com/harfbuzz/harfbuzz/releases/download/15.0.0/harfbuzz-15.0.0.tar.xz 968536e9abd782f07f7954044c0c4020199fcdd39b41d221ec42d2a3be4a44df
fetch libwebp-1.6.0.tar.gz https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
fetch libass-0.17.5.tar.xz https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz 2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc

X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
if [ ! -f "$SRC/x264-$X264_COMMIT.tar.gz" ]; then
  TMP_GIT="$(mktemp -d)"
  git clone --quiet https://code.videolan.org/videolan/x264.git "$TMP_GIT/x264"
  git -C "$TMP_GIT/x264" archive --format=tar.gz --prefix=x264/ -o "$SRC/x264-$X264_COMMIT.tar.gz" "$X264_COMMIT"
  rm -rf "$TMP_GIT"
fi

build_arch() {
  local ARCH="$1"
  local PREFIX="$ROOT/prefix-$ARCH" WORK="$ROOT/work-$ARCH" OUT="$ROOT/out-$ARCH"
  local HOST="" VPX_TARGET="arm64-darwin23-gcc"
  local CROSS_MESON=() CROSS_CMAKE=() FF_CROSS=()
  mkdir -p "$PREFIX" "$WORK" "$OUT"

  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS -O2"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  unset PKG_CONFIG_PATH CPATH LIBRARY_PATH C_INCLUDE_PATH
  local CC_ARCH="clang -arch $ARCH" CXX_ARCH="clang++ -arch $ARCH"

  if [ "$ARCH" != "$(uname -m)" ]; then
    HOST="--host=$ARCH-apple-darwin"
    VPX_TARGET="$ARCH-darwin23-gcc"
    CROSS_CMAKE=(-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$ARCH" -DCMAKE_ASM_NASM_COMPILER=nasm)
    cat > "$WORK/cross.ini" <<EOF
[binaries]
c = ['clang', '-arch', '$ARCH']
cpp = ['clang++', '-arch', '$ARCH']
objc = ['clang', '-arch', '$ARCH']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
nasm = 'nasm'

[host_machine]
system = 'darwin'
cpu_family = '$ARCH'
cpu = '$ARCH'
endian = 'little'
EOF
    CROSS_MESON=(--cross-file "$WORK/cross.ini")
    FF_CROSS=(--arch="$ARCH" --enable-cross-compile --target-os=darwin --cc="$CC_ARCH" --cxx="$CXX_ARCH" --x86asmexe=nasm)
  fi

  built() { [ -f "$ROOT/.built-$ARCH-$1" ] && echo "==> [$ARCH] $1 (already built)"; }
  mark() { touch "$ROOT/.built-$ARCH-$1"; }
  unpack() {
    rm -rf "$WORK/$2"; mkdir -p "$WORK/$2"
    tar -xf "$SRC/$1" -C "$WORK/$2" --strip-components 1
    cd "$WORK/$2"
  }
  cmake_build() {
    CC=clang CXX=clang++ cmake -S "$1" -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" ${CROSS_CMAKE[@]+"${CROSS_CMAKE[@]}"} "${@:2}" >/dev/null
    ninja -C build >/dev/null && ninja -C build install >/dev/null
  }
  meson_build() {
    meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
      ${CROSS_MESON[@]+"${CROSS_MESON[@]}"} "$@" >/dev/null
    ninja -C build >/dev/null && ninja -C build install >/dev/null
  }
  autotools_build() {
    CC="$CC_ARCH" CXX="$CXX_ARCH" ./configure --prefix="$PREFIX" $HOST --enable-static --disable-shared "$@" >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
  }

  if ! built x264; then
    echo "==> [$ARCH] x264"
    unpack "x264-$X264_COMMIT.tar.gz" x264
    CC=clang ./configure --prefix="$PREFIX" $HOST --enable-static --disable-cli --enable-pic \
      --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
    mark x264
  fi

  if ! built x265; then
    echo "==> [$ARCH] x265"
    unpack x265_4.3.tar.gz x265
    X265_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_ARCHITECTURES="$ARCH"
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" ${CROSS_CMAKE[@]+"${CROSS_CMAKE[@]}"} -DENABLE_SHARED=OFF -DENABLE_CLI=OFF)
    CC=clang CXX=clang++ cmake -S source -B build10 "${X265_COMMON[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF >/dev/null
    ninja -C build10 >/dev/null
    cp build10/libx265.a build10/libx265_main10.a
    CC=clang CXX=clang++ cmake -S source -B build "${X265_COMMON[@]}" -DEXTRA_LIB="x265_main10.a" \
      -DEXTRA_LINK_FLAGS="-L$WORK/x265/build10" -DLINKED_10BIT=ON >/dev/null
    ninja -C build >/dev/null && ninja -C build install >/dev/null
    libtool -static -o "$PREFIX/lib/libx265.a" build/libx265.a build10/libx265_main10.a 2>/dev/null
    mark x265
  fi

  if ! built lame; then
    echo "==> [$ARCH] lame"
    unpack lame-4.0.tar.gz lame
    autotools_build --disable-frontend --disable-decoder
    mark lame
  fi

  if ! built opus; then
    echo "==> [$ARCH] opus"
    unpack opus-1.6.1.tar.gz opus
    autotools_build --disable-doc --disable-extra-programs
    mark opus
  fi

  if ! built libvpx; then
    echo "==> [$ARCH] libvpx"
    unpack libvpx-1.17.0.tar.gz libvpx
    ./configure --prefix="$PREFIX" --target="$VPX_TARGET" --enable-static --disable-shared --enable-pic \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth >/dev/null
    make -j"$JOBS" >/dev/null && make install >/dev/null
    mark libvpx
  fi

  if ! built svt-av1; then
    echo "==> [$ARCH] svt-av1"
    unpack SVT-AV1-v4.2.0.tar.bz2 svtav1
    cmake_build . -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF
    mark svt-av1
  fi

  if ! built dav1d; then
    echo "==> [$ARCH] dav1d"
    unpack dav1d-1.5.4.tar.bz2 dav1d
    meson_build -Denable_tools=false -Denable_tests=false
    mark dav1d
  fi

  if ! built zimg; then
    echo "==> [$ARCH] zimg"
    unpack zimg-3.0.6.tar.gz zimg
    ./autogen.sh >/dev/null 2>&1
    autotools_build
    mark zimg
  fi

  if ! built freetype; then
    echo "==> [$ARCH] freetype"
    unpack freetype-2.15.0.tar.xz freetype
    meson_build -Dzlib=disabled -Dbzip2=disabled -Dpng=disabled -Dharfbuzz=disabled -Dbrotli=disabled
    mark freetype
  fi

  if ! built fribidi; then
    echo "==> [$ARCH] fribidi"
    unpack fribidi-1.0.17.tar.xz fribidi
    meson_build -Ddocs=false -Dbin=false -Dtests=false
    mark fribidi
  fi

  if ! built harfbuzz; then
    echo "==> [$ARCH] harfbuzz"
    unpack harfbuzz-15.0.0.tar.xz harfbuzz
    meson_build -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
      -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled
    mark harfbuzz
  fi

  if ! built libass; then
    echo "==> [$ARCH] libass"
    unpack libass-0.17.5.tar.xz libass
    autotools_build --disable-fontconfig --disable-require-system-font-provider
    mark libass
  fi

  if ! built libwebp; then
    echo "==> [$ARCH] libwebp"
    unpack libwebp-1.6.0.tar.gz libwebp
    cmake_build . -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
      -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
      -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
    mark libwebp
  fi

  echo "==> [$ARCH] ffmpeg"
  unpack ffmpeg-9.0.2.tar.xz ffmpeg
  ./configure --prefix="$PREFIX" --pkg-config-flags=--static ${FF_CROSS[@]+"${FF_CROSS[@]}"} \
    --enable-gpl --enable-version3 --disable-autodetect \
    --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv \
    --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus \
    --enable-libvpx --enable-libsvtav1 --enable-libdav1d \
    --enable-libwebp --enable-libzimg --enable-libass --enable-libfreetype --enable-libharfbuzz --enable-libfribidi \
    --disable-ffplay --disable-doc --disable-network --disable-indevs --disable-outdevs \
    --extra-cflags="$CFLAGS -I$PREFIX/include" --extra-ldflags="$LDFLAGS -L$PREFIX/lib" \
    --extra-libs="-lc++ -liconv" >/dev/null
  make -j"$JOBS" >/dev/null
  cp ffmpeg ffprobe "$OUT/"
  strip "$OUT/ffmpeg" "$OUT/ffprobe"
}

for a in $ARCHS; do (build_arch "$a"); done

OUT="$ROOT/out"
mkdir -p "$OUT"
for b in ffmpeg ffprobe; do
  inputs=()
  for a in $ARCHS; do inputs+=("$ROOT/out-$a/$b"); done
  lipo -create "${inputs[@]}" -output "$OUT/$b"
  echo "$OUT/$b: $(lipo -archs "$OUT/$b") · macOS $(otool -l "$OUT/$b" | awk '/minos/ {print $2; exit}')"
  if otool -L "$OUT/$b" | grep -E "^[[:space:]]" | grep -v -E "/System/Library/|/usr/lib/"; then
    echo "Unexpected non-system dependency"; exit 1
  fi
done
echo "==> done"
