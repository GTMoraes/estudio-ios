#include "Codificadores.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <lame/lame.h>
#include <vorbis/vorbisenc.h>

/* ---------------------------------------------------------------- MP3 */

struct CodMP3 {
    lame_t lame;
    FILE *f;
    int canais;
    unsigned char *buf;
    int tambuf;
};

CodMP3 *cod_mp3_abrir(const char *caminho, int taxa, int canais, int kbps) {
    CodMP3 *c = calloc(1, sizeof(CodMP3));
    if (!c) return NULL;
    c->f = fopen(caminho, "wb");
    c->lame = lame_init();
    if (!c->f || !c->lame) { cod_mp3_fechar(c); return NULL; }
    c->canais = canais;
    lame_set_in_samplerate(c->lame, taxa);
    lame_set_out_samplerate(c->lame, taxa);
    lame_set_num_channels(c->lame, canais);
    lame_set_mode(c->lame, canais == 1 ? MONO : JOINT_STEREO);
    lame_set_brate(c->lame, kbps);
    lame_set_VBR(c->lame, vbr_off);
    lame_set_quality(c->lame, 2);            /* 2 = alta qualidade, ainda rápido */
    if (lame_init_params(c->lame) < 0) { cod_mp3_fechar(c); return NULL; }
    c->tambuf = 1 << 18;
    c->buf = malloc(c->tambuf);
    if (!c->buf) { cod_mp3_fechar(c); return NULL; }
    return c;
}

int cod_mp3_escrever(CodMP3 *c, const float *pcm, int quadros) {
    int feitos = 0;
    while (feitos < quadros) {
        int n = quadros - feitos;
        if (n > 8192) n = 8192;
        int need = (int)(1.25 * n) + 7200;
        if (need > c->tambuf) return -1;
        int r;
        if (c->canais == 1)
            r = lame_encode_buffer_ieee_float(c->lame, pcm + feitos, NULL, n, c->buf, c->tambuf);
        else
            r = lame_encode_buffer_interleaved_ieee_float(c->lame, pcm + (size_t)feitos * 2, n, c->buf, c->tambuf);
        if (r < 0) return r;
        if (r > 0 && fwrite(c->buf, 1, (size_t)r, c->f) != (size_t)r) return -2;
        feitos += n;
    }
    return 0;
}

int cod_mp3_fechar(CodMP3 *c) {
    if (!c) return 0;
    int erro = 0;
    if (c->lame && c->f && c->buf) {
        int r = lame_encode_flush(c->lame, c->buf, c->tambuf);
        if (r > 0 && fwrite(c->buf, 1, (size_t)r, c->f) != (size_t)r) erro = -2;
    }
    if (c->lame) lame_close(c->lame);
    if (c->f && fclose(c->f) != 0) erro = -3;
    free(c->buf);
    free(c);
    return erro;
}

/* ---------------------------------------------------------------- OGG Vorbis */

struct CodOGG {
    FILE *f;
    int canais;
    ogg_stream_state os;
    vorbis_info vi;
    vorbis_comment vc;
    vorbis_dsp_state vd;
    vorbis_block vb;
    int iniciado;
};

static int ogg_gravar_paginas(CodOGG *c, int forcar) {
    ogg_page og;
    for (;;) {
        int r = forcar ? ogg_stream_flush(&c->os, &og) : ogg_stream_pageout(&c->os, &og);
        if (r == 0) break;
        if (fwrite(og.header, 1, (size_t)og.header_len, c->f) != (size_t)og.header_len) return -2;
        if (fwrite(og.body, 1, (size_t)og.body_len, c->f) != (size_t)og.body_len) return -2;
    }
    return 0;
}

static int ogg_drenar(CodOGG *c) {
    ogg_packet op;
    while (vorbis_analysis_blockout(&c->vd, &c->vb) == 1) {
        vorbis_analysis(&c->vb, NULL);
        vorbis_bitrate_addblock(&c->vb);
        while (vorbis_bitrate_flushpacket(&c->vd, &op)) {
            ogg_stream_packetin(&c->os, &op);
            if (ogg_gravar_paginas(c, 0) != 0) return -2;
        }
    }
    return 0;
}

CodOGG *cod_ogg_abrir(const char *caminho, int taxa, int canais, float qualidade) {
    CodOGG *c = calloc(1, sizeof(CodOGG));
    if (!c) return NULL;
    c->f = fopen(caminho, "wb");
    if (!c->f) { free(c); return NULL; }
    c->canais = canais;
    vorbis_info_init(&c->vi);
    float q = qualidade / 10.0f;               /* libvorbis: -0.1 .. 1.0 */
    if (q < -0.1f) q = -0.1f;
    if (q > 1.0f) q = 1.0f;
    if (vorbis_encode_init_vbr(&c->vi, canais, taxa, q) != 0) {
        vorbis_info_clear(&c->vi); fclose(c->f); free(c); return NULL;
    }
    vorbis_comment_init(&c->vc);
    vorbis_comment_add_tag(&c->vc, "ENCODER", "Estudio");
    vorbis_analysis_init(&c->vd, &c->vi);
    vorbis_block_init(&c->vd, &c->vb);
    srand((unsigned)time(NULL));
    ogg_stream_init(&c->os, rand());
    c->iniciado = 1;

    ogg_packet h, hc, hk;
    vorbis_analysis_headerout(&c->vd, &c->vc, &h, &hc, &hk);
    ogg_stream_packetin(&c->os, &h);
    ogg_stream_packetin(&c->os, &hc);
    ogg_stream_packetin(&c->os, &hk);
    if (ogg_gravar_paginas(c, 1) != 0) { cod_ogg_fechar(c); return NULL; }
    return c;
}

int cod_ogg_escrever(CodOGG *c, const float *pcm, int quadros) {
    int feitos = 0;
    while (feitos < quadros) {
        int n = quadros - feitos;
        if (n > 4096) n = 4096;
        float **buf = vorbis_analysis_buffer(&c->vd, n);
        for (int i = 0; i < n; i++)
            for (int ch = 0; ch < c->canais; ch++)
                buf[ch][i] = pcm[(size_t)(feitos + i) * c->canais + ch];
        vorbis_analysis_wrote(&c->vd, n);
        if (ogg_drenar(c) != 0) return -2;
        feitos += n;
    }
    return 0;
}

int cod_ogg_fechar(CodOGG *c) {
    if (!c) return 0;
    int erro = 0;
    if (c->iniciado) {
        vorbis_analysis_wrote(&c->vd, 0);       /* fim do fluxo */
        if (ogg_drenar(c) != 0) erro = -2;
        if (ogg_gravar_paginas(c, 1) != 0) erro = -2;
        ogg_stream_clear(&c->os);
        vorbis_block_clear(&c->vb);
        vorbis_dsp_clear(&c->vd);
        vorbis_comment_clear(&c->vc);
        vorbis_info_clear(&c->vi);
    }
    if (c->f && fclose(c->f) != 0) erro = -3;
    free(c);
    return erro;
}
