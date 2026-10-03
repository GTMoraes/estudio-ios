#include "Decodificador.h"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>

const char *estudio_ffmpeg_versao(void) {
    return av_version_info();
}

int estudio_ffmpeg_decodifica(const char *nome) {
    if (!nome) return 0;
    const AVCodec *c = avcodec_find_decoder_by_name(nome);
    return c != NULL ? 1 : 0;
}
