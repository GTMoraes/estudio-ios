#!/bin/bash
# Compila LAME (MP3), libogg e libvorbis (OGG) como bibliotecas estáticas para iPhone (arm64).
# Resultado em vendor/lib e vendor/include. Roda no GitHub Actions (macOS).
set -euo pipefail

LAME=3.100
OGG=1.3.5
VORBIS=1.3.7
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$RAIZ/vendor"
OBRA="$RAIZ/build-vendor"

if [ -f "$DEST/lib/libmp3lame.a" ] && [ -f "$DEST/lib/libvorbisenc.a" ] && [ -f "$DEST/lib/libogg.a" ] \
   && [ -f "$DEST/include/lame/lame.h" ] && [ -f "$DEST/include/vorbis/vorbisenc.h" ]; then
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

ls -la "$DEST/lib"
for a in libmp3lame libogg libvorbis libvorbisenc; do
  lipo -info "$DEST/lib/$a.a"
done
