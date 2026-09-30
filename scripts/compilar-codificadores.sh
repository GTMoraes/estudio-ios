#!/bin/bash
# Compila LAME (MP3), libogg e libvorbis (OGG) e libwebp (WebP) como bibliotecas estáticas
# para iPhone (arm64).
# Resultado em vendor/lib e vendor/include. Roda no GitHub Actions (macOS).
set -euo pipefail

LAME=3.100
OGG=1.3.5
VORBIS=1.3.7
WEBP=1.5.0
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$RAIZ/vendor"
OBRA="$RAIZ/build-vendor"

if [ -f "$DEST/lib/libmp3lame.a" ] && [ -f "$DEST/lib/libvorbisenc.a" ] && [ -f "$DEST/lib/libogg.a" ] \
   && [ -f "$DEST/include/lame/lame.h" ] && [ -f "$DEST/include/vorbis/vorbisenc.h" ] \
   && [ -f "$DEST/lib/libwebp.a" ] && [ -f "$DEST/lib/libwebpmux.a" ] && [ -f "$DEST/include/webp/encode.h" ]; then
  echo "codificadores já compilados (cache)"; exit 0
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC="$(xcrun --sdk iphoneos -f clang)"
export CFLAGS="-arch arm64 -isysroot $SDK -mios-version-min=26.0 -O2 -Wno-error=implicit-function-declaration"
# o pré-processador também precisa do SDK do iPhone: sem isto o configure acha que
# errno.h/string.h "não existem" e o LAME cai em funções antigas (bcopy) que não compilam
export CPPFLAGS="-arch arm64 -isysroot $SDK -mios-version-min=26.0"
export CPP="$CC -E"
export LDFLAGS="-arch arm64 -isysroot $SDK"
# arm-apple-darwin: o config.sub antigo do LAME 3.100 pode não conhecer "aarch64-apple";
# a arquitetura real vem do -arch arm64 no CFLAGS
HOST=arm-apple-darwin
COMUM=(--host=$HOST --prefix="$DEST" --enable-static --disable-shared)
# pkg-config só enxerga o que compilamos aqui (não um libogg de macOS do Homebrew)
export PKG_CONFIG_PATH="$DEST/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$DEST/lib/pkgconfig"

mkdir -p "$OBRA" "$DEST"
cd "$OBRA"
baixar() { curl -fsSL --retry 3 -o "$2" "$1"; tar xzf "$2"; }

baixar "https://downloads.sourceforge.net/project/lame/lame/$LAME/lame-$LAME.tar.gz" lame.tgz
baixar "https://downloads.xiph.org/releases/ogg/libogg-$OGG.tar.gz" ogg.tgz
baixar "https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS.tar.gz" vorbis.tgz

echo "== LAME"
cd "lame-$LAME"
# lame 3.100 exporta um símbolo que não existe; só atrapalha em alguns linkers
sed -i '' '/lame_init_old/d' include/libmp3lame.sym || true
./configure "${COMUM[@]}" --disable-frontend --disable-decoder --disable-analyzer-hooks --disable-gtktest
make -j"$(sysctl -n hw.ncpu)"
make install
cd ..

echo "== libogg"
cd "libogg-$OGG"
./configure "${COMUM[@]}"
make -j"$(sysctl -n hw.ncpu)"
make install
cd ..

echo "== libvorbis"
cd "libvorbis-$VORBIS"
# o configure põe -force_cpusubtype_ALL em *-darwin*, que o clang de arm64 não aceita
sed -i '' 's/-force_cpusubtype_ALL//g' configure
./configure "${COMUM[@]}" --with-ogg="$DEST" --disable-examples --disable-docs --disable-oggtest
make -j"$(sysctl -n hw.ncpu)"
make install
cd ..

echo "== libwebp"
# o GitHub não traz o configure pronto; o libwebp também compila com CMake, que já sabe gerar para iOS
baixar "https://github.com/webmproject/libwebp/archive/refs/tags/v$WEBP.tar.gz" webp.tgz
cmake -S "libwebp-$WEBP" -B webp-obra \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEST" \
  -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
cmake --build webp-obra -j"$(sysctl -n hw.ncpu)"
cmake --install webp-obra

ls -la "$DEST/lib"
for f in include/webp/encode.h include/webp/mux.h lib/libwebp.a lib/libwebpmux.a lib/libsharpyuv.a; do
  [ -f "$DEST/$f" ] || { echo "::error::faltou vendor/$f"; exit 1; }
done
for a in libmp3lame libogg libvorbis libvorbisenc libwebp libwebpmux libsharpyuv; do
  lipo -info "$DEST/lib/$a.a"
done
