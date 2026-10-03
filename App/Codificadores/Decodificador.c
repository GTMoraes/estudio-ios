#include "Decodificador.h"
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/display.h>
#include <libavutil/pixdesc.h>
#include <libavutil/channel_layout.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

const char *estudio_ffmpeg_versao(void) {
    return av_version_info();
}

int estudio_ffmpeg_decodifica(const char *nome) {
    if (!nome) return 0;
    const AVCodec *c = avcodec_find_decoder_by_name(nome);
    return c != NULL ? 1 : 0;
}

struct EstudioLeitor {
    AVFormatContext *fmt;
    AVCodecContext *vdec, *adec;
    int vi, ai;                 // índices das trilhas (-1 = não tem)
    AVPacket *pkt;
    AVFrame *vq, *aq;           // último quadro de vídeo / bloco de áudio decodificado
    int pendV, pendA;           // há quadros a retirar do decodificador
    int fimArquivo, fimV, fimA;
    double inicio;              // tempo do começo do arquivo (para os tempos saírem a partir de 0)
    int largura, altura;        // saída (pares)
    // vídeo: conversão para NV12/P010
    struct SwsContext *sws;
    int swsL, swsA, swsFmt, swsDez;
    // áudio: conversão para float intercalado
    SwrContext *swr;
    int canais, taxa;
    float *audio;
    int audioCap, audioN;
    int64_t amostrasEntregues;
    double audioInicio;
    int audioTemInicio;
};

static void anotar(char *erro, int tam, const char *texto, int codigo) {
    if (!erro || tam <= 0) return;
    if (codigo < 0) {
        char b[128]; av_strerror(codigo, b, sizeof b);
        snprintf(erro, tam, "%s: %s", texto, b);
    } else {
        snprintf(erro, tam, "%s", texto);
    }
}

static AVCodecContext *abrirDecodificador(AVStream *st, int tarefas) {
    const AVCodec *c = avcodec_find_decoder(st->codecpar->codec_id);
    if (!c) return NULL;
    AVCodecContext *ctx = avcodec_alloc_context3(c);
    if (!ctx) return NULL;
    if (avcodec_parameters_to_context(ctx, st->codecpar) < 0) { avcodec_free_context(&ctx); return NULL; }
    ctx->pkt_timebase = st->time_base;
    ctx->thread_count = tarefas;            // 0 = o FFmpeg escolhe pelo número de núcleos
    if (avcodec_open2(ctx, c, NULL) < 0) { avcodec_free_context(&ctx); return NULL; }
    return ctx;
}

static int rotacaoDe(AVStream *st) {
    const int32_t *m = NULL;
#if LIBAVCODEC_VERSION_MAJOR >= 61
    const AVPacketSideData *sd = av_packet_side_data_get(st->codecpar->coded_side_data,
                                                         st->codecpar->nb_coded_side_data,
                                                         AV_PKT_DATA_DISPLAYMATRIX);
    if (sd && sd->size >= 9 * 4) m = (const int32_t *)sd->data;
#else
    size_t tam = 0;
    const uint8_t *d = av_stream_get_side_data(st, AV_PKT_DATA_DISPLAYMATRIX, &tam);
    if (d && tam >= 9 * 4) m = (const int32_t *)d;
#endif
    if (!m) return 0;
    double g = av_display_rotation_get(m);       // anti-horário
    if (isnan(g)) return 0;
    int r = (int)lround(-g / 90.0) * 90;
    r %= 360; if (r < 0) r += 360;
    return r;
}

EstudioLeitor *estudio_abrir(const char *caminho, EstudioInfo *info, char *erro, int tamErro) {
    if (info) memset(info, 0, sizeof *info);
    EstudioLeitor *l = calloc(1, sizeof *l);
    if (!l) { anotar(erro, tamErro, "sem memória", 0); return NULL; }
    l->vi = l->ai = -1;
    av_log_set_level(AV_LOG_QUIET);
    int r = avformat_open_input(&l->fmt, caminho, NULL, NULL);
    if (r < 0) { anotar(erro, tamErro, "não consegui abrir o arquivo", r); free(l); return NULL; }
    r = avformat_find_stream_info(l->fmt, NULL);
    if (r < 0) { anotar(erro, tamErro, "não consegui ler as trilhas", r); estudio_fechar(l); return NULL; }

    l->vi = av_find_best_stream(l->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (l->vi >= 0 && (l->fmt->streams[l->vi]->disposition & AV_DISPOSITION_ATTACHED_PIC)) l->vi = -1;
    l->ai = av_find_best_stream(l->fmt, AVMEDIA_TYPE_AUDIO, -1, l->vi, NULL, 0);
    if (l->vi < 0 && l->ai < 0) { anotar(erro, tamErro, "o arquivo não tem vídeo nem áudio", 0); estudio_fechar(l); return NULL; }

    if (l->vi >= 0) {
        l->vdec = abrirDecodificador(l->fmt->streams[l->vi], 0);
        if (!l->vdec) { anotar(erro, tamErro, "não há decodificador para o vídeo deste arquivo", 0); estudio_fechar(l); return NULL; }
    }
    if (l->ai >= 0) {
        l->adec = abrirDecodificador(l->fmt->streams[l->ai], 1);
        if (!l->adec) l->ai = -1;               // áudio que não abre: segue só com o vídeo
    }
    for (unsigned i = 0; i < l->fmt->nb_streams; i++)
        if ((int)i != l->vi && (int)i != l->ai) l->fmt->streams[i]->discard = AVDISCARD_ALL;

    l->pkt = av_packet_alloc(); l->vq = av_frame_alloc(); l->aq = av_frame_alloc();
    if (!l->pkt || !l->vq || !l->aq) { anotar(erro, tamErro, "sem memória", 0); estudio_fechar(l); return NULL; }
    l->inicio = l->fmt->start_time != AV_NOPTS_VALUE ? l->fmt->start_time / (double)AV_TIME_BASE : 0;
    l->fimV = l->vi < 0; l->fimA = l->ai < 0;

    if (l->vi >= 0) {
        l->largura = l->vdec->width & ~1;
        l->altura = l->vdec->height & ~1;
        if (l->largura < 2 || l->altura < 2) { anotar(erro, tamErro, "tamanho de vídeo inválido", 0); estudio_fechar(l); return NULL; }
    }
    if (l->ai >= 0) {
        l->taxa = l->adec->sample_rate;
        l->canais = l->adec->ch_layout.nb_channels >= 2 ? 2 : 1;
        if (l->taxa <= 0) { avcodec_free_context(&l->adec); l->ai = -1; l->fimA = 1; }
    }

    if (info) {
        info->temVideo = l->vi >= 0; info->temAudio = l->ai >= 0;
        if (l->fmt->duration != AV_NOPTS_VALUE) info->duracao = l->fmt->duration / (double)AV_TIME_BASE;
        if (l->vi >= 0) {
            AVStream *st = l->fmt->streams[l->vi];
            info->largura = l->largura; info->altura = l->altura;
            AVRational f = st->avg_frame_rate.num > 0 && st->avg_frame_rate.den > 0 ? st->avg_frame_rate : st->r_frame_rate;
            if (f.num > 0 && f.den > 0) info->fps = av_q2d(f);
            info->taxaVideo = st->codecpar->bit_rate > 0 ? st->codecpar->bit_rate
                             : (l->ai < 0 && l->fmt->bit_rate > 0 ? l->fmt->bit_rate : 0);
            const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(l->vdec->pix_fmt);
            info->dezBits = d && d->comp[0].depth > 8;
            info->rotacao = rotacaoDe(st);
            info->primarias = l->vdec->color_primaries;
            info->transferencia = l->vdec->color_trc;
            info->matriz = l->vdec->colorspace;
            snprintf(info->codecVideo, sizeof info->codecVideo, "%s", avcodec_get_name(st->codecpar->codec_id));
        }
        if (l->ai >= 0) {
            info->taxaAudio = l->taxa; info->canais = l->canais;
            snprintf(info->codecAudio, sizeof info->codecAudio, "%s", avcodec_get_name(l->fmt->streams[l->ai]->codecpar->codec_id));
        }
    }
    return l;
}

static double tempoDe(EstudioLeitor *l, AVFrame *q, int trilha) {
    int64_t t = q->best_effort_timestamp != AV_NOPTS_VALUE ? q->best_effort_timestamp : q->pts;
    if (t == AV_NOPTS_VALUE) return -1;
    return t * av_q2d(l->fmt->streams[trilha]->time_base) - l->inicio;
}

/// Converte o bloco de áudio em l->aq para float intercalado em l->audio.
static int prepararAudio(EstudioLeitor *l) {
    AVFrame *q = l->aq;
    if (!l->swr) {
        AVChannelLayout saida; av_channel_layout_default(&saida, l->canais);
        AVChannelLayout entrada;
        if (q->ch_layout.nb_channels > 0 && q->ch_layout.order != AV_CHANNEL_ORDER_UNSPEC) av_channel_layout_copy(&entrada, &q->ch_layout);
        else av_channel_layout_default(&entrada, q->ch_layout.nb_channels > 0 ? q->ch_layout.nb_channels : l->canais);
        int r = swr_alloc_set_opts2(&l->swr, &saida, AV_SAMPLE_FMT_FLT, l->taxa,
                                    &entrada, (enum AVSampleFormat)q->format, q->sample_rate, 0, NULL);
        av_channel_layout_uninit(&entrada); av_channel_layout_uninit(&saida);
        if (r < 0 || swr_init(l->swr) < 0) { swr_free(&l->swr); return -1; }
    }
    int max = swr_get_out_samples(l->swr, q->nb_samples);
    if (max < 0) return -1;
    if (max > l->audioCap) {
        float *n = realloc(l->audio, sizeof(float) * (size_t)max * (size_t)l->canais);
        if (!n) return -1;
        l->audio = n; l->audioCap = max;
    }
    uint8_t *destino[1] = { (uint8_t *)l->audio };
    int n = swr_convert(l->swr, destino, max, (const uint8_t **)q->extended_data, q->nb_samples);
    if (n < 0) return -1;
    l->audioN = n;
    return 0;
}

int estudio_proximo(EstudioLeitor *l, EstudioQuadro *q) {
    if (!l || !q) return -1;
    memset(q, 0, sizeof *q);
    for (;;) {
        if (l->pendV && !l->fimV) {
            int r = avcodec_receive_frame(l->vdec, l->vq);
            if (r == 0) {
                if (l->vq->width < l->largura || l->vq->height < l->altura) continue;   // mudou de tamanho no meio: pula
                q->tipo = 1; q->tempo = tempoDe(l, l->vq, l->vi);
                return 1;
            }
            if (r == AVERROR_EOF) l->fimV = 1;
            l->pendV = 0;
        }
        if (l->pendA && !l->fimA) {
            int r = avcodec_receive_frame(l->adec, l->aq);
            if (r == 0) {
                if (prepararAudio(l) < 0 || l->audioN <= 0) continue;
                // o tempo do áudio é contado pelas amostras já entregues: sem saltos de arredondamento
                if (!l->audioTemInicio) {
                    double t = tempoDe(l, l->aq, l->ai);
                    l->audioInicio = t > 0 ? t : 0; l->audioTemInicio = 1;
                }
                q->tipo = 2;
                q->tempo = l->audioInicio + l->amostrasEntregues / (double)l->taxa;
                q->amostras = l->audioN;
                l->amostrasEntregues += l->audioN;
                return 1;
            }
            if (r == AVERROR_EOF) l->fimA = 1;
            l->pendA = 0;
        }
        if (l->fimArquivo) {
            if (l->fimV && l->fimA) return 0;
            if (!l->pendV && !l->pendA) return 0;      // os decodificadores já foram esvaziados
            continue;
        }
        int r = av_read_frame(l->fmt, l->pkt);
        if (r < 0) {
            l->fimArquivo = 1;                         // esvazia o que ficou dentro dos decodificadores
            if (!l->fimV) { avcodec_send_packet(l->vdec, NULL); l->pendV = 1; }
            if (!l->fimA) { avcodec_send_packet(l->adec, NULL); l->pendA = 1; }
            continue;
        }
        if (l->pkt->stream_index == l->vi && !l->fimV) {
            if (avcodec_send_packet(l->vdec, l->pkt) == 0) l->pendV = 1;      // pacote estragado: ignora
        } else if (l->pkt->stream_index == l->ai && !l->fimA) {
            if (avcodec_send_packet(l->adec, l->pkt) == 0) l->pendA = 1;
        }
        av_packet_unref(l->pkt);
    }
}

int estudio_copiar_video(EstudioLeitor *l, uint8_t *y, int passoY, uint8_t *cbcr, int passoCbCr, int dezBits) {
    if (!l || !l->vq || !l->vq->data[0] || !y || !cbcr) return -1;
    AVFrame *q = l->vq;
    if (!l->sws || l->swsL != q->width || l->swsA != q->height || l->swsFmt != q->format || l->swsDez != dezBits) {
        sws_freeContext(l->sws);
        l->sws = sws_getContext(q->width, q->height, (enum AVPixelFormat)q->format,
                                l->largura, l->altura, dezBits ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12,
                                SWS_BICUBIC | SWS_ACCURATE_RND | SWS_FULL_CHR_H_INT, NULL, NULL, NULL);
        if (!l->sws) return -1;
        // mesma matriz dos dois lados (não mexe na cor); só a faixa completa vira faixa de vídeo
        int cs = q->colorspace == AVCOL_SPC_BT2020_NCL || q->colorspace == AVCOL_SPC_BT2020_CL ? SWS_CS_BT2020
               : q->colorspace == AVCOL_SPC_BT470BG || q->colorspace == AVCOL_SPC_SMPTE170M ? SWS_CS_ITU601
               : q->colorspace == AVCOL_SPC_UNSPECIFIED && q->height < 720 ? SWS_CS_ITU601 : SWS_CS_ITU709;
        const int *coef = sws_getCoefficients(cs);
        sws_setColorspaceDetails(l->sws, coef, q->color_range == AVCOL_RANGE_JPEG, coef, 0, 0, 1 << 16, 1 << 16);
        l->swsL = q->width; l->swsA = q->height; l->swsFmt = q->format; l->swsDez = dezBits;
    }
    uint8_t *planos[4] = { y, cbcr, NULL, NULL };
    int passos[4] = { passoY, passoCbCr, 0, 0 };
    int r = sws_scale(l->sws, (const uint8_t *const *)q->data, q->linesize, 0, q->height, planos, passos);
    return r > 0 ? 0 : -1;
}

int estudio_copiar_audio(EstudioLeitor *l, float *destino, int maxAmostras) {
    if (!l || !destino || l->audioN <= 0) return 0;
    int n = l->audioN < maxAmostras ? l->audioN : maxAmostras;
    memcpy(destino, l->audio, sizeof(float) * (size_t)n * (size_t)l->canais);
    return n;
}

void estudio_fechar(EstudioLeitor *l) {
    if (!l) return;
    sws_freeContext(l->sws);
    swr_free(&l->swr);
    free(l->audio);
    av_frame_free(&l->vq); av_frame_free(&l->aq);
    av_packet_free(&l->pkt);
    avcodec_free_context(&l->vdec); avcodec_free_context(&l->adec);
    avformat_close_input(&l->fmt);
    free(l);
}
