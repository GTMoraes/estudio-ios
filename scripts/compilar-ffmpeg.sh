#!/bin/bash
# Compila o FFmpeg para iPhone (arm64) como bibliotecas estáticas, na versão enxuta:
# só abrir arquivos e decodificar (sem codificadores, sem rede, sem programas). Licença LGPL.
# Quem grava o vídeo convertido é o codificador de hardware do iPhone (AVFoundation).
# Resultado em vendor-ff/lib e vendor-ff/include. Roda no GitHub Actions (macOS).
set -euo pipefail

FFMPEG=7.1.1
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$RAIZ/vendor-ff"
OBRA="$RAIZ/build-ff"
LIBS=(libavformat libavcodec libswresample libswscale libavutil)

pronto=1
for l in "${LIBS[@]}"; do [ -f "$DEST/lib/$l.a" ] || pronto=0; done
[ -f "$DEST/include/libavcodec/avcodec.h" ] || pronto=0
if [ "$pronto" = 1 ]; then echo "FFmpeg já compilado (cache)"; exit 0; fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
# nada de bibliotecas do macOS (Homebrew) entrando por engano
unset CC CFLAGS CPPFLAGS CPP LDFLAGS
export PKG_CONFIG_LIBDIR="$OBRA/sem-pkgconfig"
export PKG_CONFIG_PATH=""

rm -rf "$OBRA"; mkdir -p "$OBRA" "$DEST"
cd "$OBRA"
curl -fsSL --retry 3 -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz" \
  || { rm -f ffmpeg.tar.xz
       curl -fsSL --retry 3 -o ffmpeg.tar.gz "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG.tar.gz"; }
if [ -s ffmpeg.tar.xz ]; then tar xJf ffmpeg.tar.xz; else tar xzf ffmpeg.tar.gz; fi
FONTE="$(find . -maxdepth 1 -type d -iname 'ffmpeg-*' | head -1)"
[ -n "$FONTE" ] || { echo "::error::não achei a pasta do FFmpeg depois de extrair"; exit 1; }
cd "$FONTE"

MARCAS="-arch arm64 -mios-version-min=26.0"
./configure \
  --prefix="$DEST" \
  --enable-cross-compile --target-os=darwin --arch=arm64 \
  --cc="$CLANG" --as="$CLANG" --sysroot="$SDK" \
  --extra-cflags="$MARCAS -O2" --extra-ldflags="$MARCAS" \
  --enable-static --disable-shared --enable-pic \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter --disable-postproc \
  --disable-network --disable-protocols --enable-protocol=file \
  --disable-encoders --disable-muxers --disable-indevs --disable-outdevs \
  --disable-videotoolbox --disable-audiotoolbox --disable-securetransport \
  --disable-avfoundation --disable-coreimage --disable-appkit \
  --disable-iconv --disable-bzlib --disable-lzma --disable-sdl2 --disable-xlib \
  || { echo "::error::o configure do FFmpeg falhou"; tail -60 ffbuild/config.log; exit 1; }

make -j"$(sysctl -n hw.ncpu)"
make install

for l in "${LIBS[@]}"; do
  [ -f "$DEST/lib/$l.a" ] || { echo "::error::faltou vendor-ff/lib/$l.a"; exit 1; }
  lipo -info "$DEST/lib/$l.a"
done
[ -f "$DEST/include/libavcodec/avcodec.h" ] || { echo "::error::faltaram os cabeçalhos do FFmpeg"; exit 1; }
du -sh "$DEST/lib"
