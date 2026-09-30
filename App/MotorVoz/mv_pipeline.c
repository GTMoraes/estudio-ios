/* Montagem do tratamento de voz: o mesmo `tratar` do motor_voz (pipeline.py), em C.
   Separação e eco por blocos (com contexto e emendas), clareza, nivelamento, limitadores,
   mix e o destino "quadra". Os arquivos intermediários são float32 intercalado estéreo. */
#include "motorvoz.h"
#include "mv_interno.h"
#include "../Codificadores/Codificadores.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/types.h>

#define SR 44100
#define ALVO_LUFS (-16.0)
#define CONTEXTO_SEG 10.0
#define TRANSICAO_SEG 2.0
#define PEDACO 65536                 /* quadros por leitura na montagem */

static void falha(char *erro, int nerro, const char *fmt, ...) {
    if (!erro || nerro <= 0) return;
    va_list ap; va_start(ap, fmt); vsnprintf(erro, nerro, fmt, ap); va_end(ap);
}

static int64_t quadros_arquivo(const char *p) {
    FILE *f = fopen(p, "rb");
    if (!f) return -1;
    fseeko(f, 0, SEEK_END);
    int64_t b = ftello(f);
    fclose(f);
    return b / 8;
}

/* lê [a, b) do arquivo intercalado para planar [2][b-a] */
static int ler_trecho(FILE *f, size_t a, size_t b, float *planar) {
    size_t n = b - a;
    float *tmp = malloc(sizeof(float) * 2 * (n < PEDACO ? n : PEDACO));
    if (!tmp) return -2;
    if (fseeko(f, (off_t)a * 8, SEEK_SET) != 0) { free(tmp); return -4; }
    for (size_t feito = 0; feito < n;) {
        size_t k = n - feito < PEDACO ? n - feito : PEDACO;
        if (fread(tmp, 8, k, f) != k) { free(tmp); return -4; }
        for (size_t i = 0; i < k; i++) { planar[feito + i] = tmp[2 * i]; planar[n + feito + i] = tmp[2 * i + 1]; }
        feito += k;
    }
    free(tmp);
    return 0;
}

static int gravar_planar(FILE *f, const float *planar, size_t stride, size_t ini, size_t n) {
    float tmp[2 * 4096];
    for (size_t feito = 0; feito < n;) {
        size_t k = n - feito < 4096 ? n - feito : 4096;
        for (size_t i = 0; i < k; i++) {
            tmp[2 * i] = planar[ini + feito + i];
            tmp[2 * i + 1] = planar[stride + ini + feito + i];
        }
        if (fwrite(tmp, 8, k, f) != k) return -4;
        feito += k;
    }
    return 0;
}

/* ------------------------------------------------------------------ blocos e emendas */

typedef struct { size_t ini, fim; } Bloco;

static Bloco *dividir(size_t n, double bloco_seg, int *nb_ret) {
    size_t b = bloco_seg > 0 ? (size_t)(bloco_seg * SR) : n;
    if (b < 1) b = 1;
    size_t nb = (n + b - 1) / b;
    if (nb < 1) nb = 1;
    size_t tam = (n + nb - 1) / nb;
    Bloco *v = malloc(sizeof(Bloco) * nb);
    if (!v) return NULL;
    for (size_t k = 0; k < nb; k++) {
        v[k].ini = k * tam;
        v[k].fim = (k + 1) * tam < n ? (k + 1) * tam : n;
    }
    *nb_ret = (int)nb;
    return v;
}

/* Grava blocos em sequência, com transição linear onde se sobrepõem (_Emendador). */
typedef struct {
    FILE *f;
    size_t F;
    float *cauda;       /* [2][F] */
    int tem_cauda;
} Emendador;

static int em_abrir(Emendador *e, const char *caminho, size_t F) {
    memset(e, 0, sizeof *e);
    e->F = F;
    e->f = fopen(caminho, "wb");
    e->cauda = malloc(sizeof(float) * 2 * F);
    return e->f && e->cauda ? 0 : -4;
}

/* x: planar com passo `stride`, trecho [ini, ini+n) — pode ser alterado */
static int em_gravar(Emendador *e, float *x, size_t stride, size_t ini, size_t n, int ultimo) {
    const size_t F = e->F;
    if (e->tem_cauda) {
        for (size_t k = 0; k < F && k < n; k++) {
            float w = (float)(F > 1 ? (double)k / (double)(F - 1) : 1.0);
            for (int c = 0; c < 2; c++) {
                float *p = x + c * stride + ini + k;
                *p = e->cauda[c * F + k] * (1.0f - w) + *p * w;
            }
        }
    }
    if (!ultimo) {
        for (int c = 0; c < 2; c++) memcpy(e->cauda + c * F, x + c * stride + ini + n - F, sizeof(float) * F);
        e->tem_cauda = 1;
        n -= F;
    }
    return gravar_planar(e->f, x, stride, ini, n);
}

static int em_fechar(Emendador *e) {
    int r = 0;
    if (e->f && fclose(e->f) != 0) r = -4;
    free(e->cauda);
    e->f = NULL; e->cauda = NULL;
    return r;
}

/* ------------------------------------------------------------------ ponto de retomada
   Depois de cada bloco: os arquivos de saída vão para o disco e o ponto guarda quantos bytes
   eles têm e a "cauda" da emenda. Se o app for fechado, a etapa continua do bloco seguinte,
   com o mesmo resultado de uma execução sem parar. */
#define PONTO_MAGICO 0x4D565054u   /* "MVPT" */
typedef struct {
    uint32_t magico;
    int32_t nb, feito, completo, nsaidas;
    int32_t tem_cauda[2];
    int64_t bytes[2];
    int64_t F;
} Ponto;

static int ponto_ler(const char *p, Ponto *pt, float *caudas, size_t F) {
    FILE *f = fopen(p, "rb");
    if (!f) return -1;
    int r = fread(pt, sizeof *pt, 1, f) == 1 && pt->magico == PONTO_MAGICO && pt->F == (int64_t)F
            && pt->nsaidas >= 1 && pt->nsaidas <= 2 ? 0 : -1;
    if (!r && !pt->completo && fread(caudas, sizeof(float), (size_t)pt->nsaidas * 2 * F, f) != (size_t)pt->nsaidas * 2 * F) r = -1;
    fclose(f);
    return r;
}

static int ponto_gravar(const char *p, const Ponto *pt, const float *caudas, size_t F) {
    size_t n = strlen(p);
    char *tmp = malloc(n + 5);
    if (!tmp) return -2;
    memcpy(tmp, p, n); memcpy(tmp + n, ".tmp", 5);
    FILE *f = fopen(tmp, "wb");
    int r = f ? 0 : -4;
    if (!r && fwrite(pt, sizeof *pt, 1, f) != 1) r = -4;
    if (!r && caudas && fwrite(caudas, sizeof(float), (size_t)pt->nsaidas * 2 * F, f) != (size_t)pt->nsaidas * 2 * F) r = -4;
    if (f) { fflush(f); fsync(fileno(f)); if (fclose(f) != 0 && !r) r = -4; }
    if (!r && rename(tmp, p) != 0) r = -4;
    free(tmp);
    return r;
}

/* reabre uma saída já começada: corta no último bloco confirmado e restaura a cauda */
static int em_retomar(Emendador *e, const char *caminho, size_t F, int64_t bytes, const float *cauda, int tem_cauda) {
    memset(e, 0, sizeof *e);
    e->F = F;
    if (truncate(caminho, (off_t)bytes) != 0) return -4;
    e->f = fopen(caminho, "ab");
    e->cauda = malloc(sizeof(float) * 2 * F);
    if (!e->f || !e->cauda) return -4;
    memcpy(e->cauda, cauda, sizeof(float) * 2 * F);
    e->tem_cauda = tem_cauda;
    return 0;
}

/* funcao(ctx, seg planar [2][len], len, saidas planar [nsaidas][2][len]) */
typedef int (*FuncBloco)(void *ctx, const float *seg, size_t len, float **saidas, int i);

/* ponto: arquivo do ponto de retomada desta etapa (NULL = sem retomada) */
static int por_blocos(const char *entrada, size_t n, const char **saidas, int nsaidas,
                      const Bloco *blocos, int nb, FuncBloco funcao, void *ctx, const char *ponto) {
    const size_t C = (size_t)(CONTEXTO_SEG * SR), F = (size_t)(TRANSICAO_SEG * SR);
    Emendador em[2];
    float *seg = NULL, *out[2] = {NULL, NULL}, *caudas = NULL;
    int r = 0, abertos = 0, inicio = 0;
    Ponto pt;
    memset(&pt, 0, sizeof pt);
    if (ponto) {
        caudas = malloc(sizeof(float) * 2 * 2 * F);
        if (!caudas) return -2;
        if (ponto_ler(ponto, &pt, caudas, F) == 0 && pt.nb == nb && pt.nsaidas == nsaidas) {
            if (pt.completo) { free(caudas); return 0; }          /* etapa já pronta */
            inicio = pt.feito + 1;
        } else {
            memset(&pt, 0, sizeof pt);
            inicio = 0;
        }
    }
    FILE *f = fopen(entrada, "rb");
    if (!f) { free(caudas); return -4; }
    for (; abertos < nsaidas; abertos++) {
        r = inicio > 0 ? em_retomar(&em[abertos], saidas[abertos], F, pt.bytes[abertos], caudas + (size_t)abertos * 2 * F, pt.tem_cauda[abertos])
                       : em_abrir(&em[abertos], saidas[abertos], F);
        if (r != 0) { abertos++; goto fim; }
    }
    for (int i = inicio; i < nb; i++) {
        int ultimo = i == nb - 1;
        size_t s = blocos[i].ini, e = blocos[i].fim;
        size_t a = s > C ? s - C : 0, b = e + C < n ? e + C : n, len = b - a;
        seg = malloc(sizeof(float) * 2 * len);
        for (int k = 0; k < nsaidas; k++) out[k] = malloc(sizeof(float) * 2 * len);
        if (!seg || !out[0] || (nsaidas > 1 && !out[1])) { r = -2; goto fim; }
        if ((r = ler_trecho(f, a, b, seg)) != 0) goto fim;
        if ((r = funcao(ctx, seg, len, out, i)) != 0) goto fim;
        free(seg); seg = NULL;
        size_t lo = i > 0 ? s - F / 2 : s;
        size_t hi = !ultimo ? e + (F - F / 2) : e;
        for (int k = 0; k < nsaidas; k++) {
            if ((r = em_gravar(&em[k], out[k], len, lo - a, hi - lo, ultimo)) != 0) goto fim;
            free(out[k]); out[k] = NULL;
        }
        if (ponto && !ultimo) {
            pt.magico = PONTO_MAGICO; pt.nb = nb; pt.feito = i; pt.completo = 0; pt.nsaidas = nsaidas; pt.F = (int64_t)F;
            for (int k = 0; k < nsaidas; k++) {
                if (fflush(em[k].f) != 0) { r = -4; goto fim; }
                fsync(fileno(em[k].f));
                pt.bytes[k] = (int64_t)ftello(em[k].f);
                pt.tem_cauda[k] = em[k].tem_cauda;
                memcpy(caudas + (size_t)k * 2 * F, em[k].cauda, sizeof(float) * 2 * F);
            }
            if ((r = ponto_gravar(ponto, &pt, caudas, F)) != 0) goto fim;
        }
    }
fim:
    free(seg); free(out[0]); free(out[1]);
    for (int k = 0; k < abertos; k++) { int r2 = em_fechar(&em[k]); if (!r) r = r2; }
    fclose(f);
    if (!r && ponto) {
        pt.magico = PONTO_MAGICO; pt.nb = nb; pt.feito = nb - 1; pt.completo = 1; pt.nsaidas = nsaidas; pt.F = (int64_t)F;
        r = ponto_gravar(ponto, &pt, NULL, F);
    }
    free(caudas);
    return r;
}

/* ------------------------------------------------------------------ etapas com os modelos */

typedef struct {
    MVHost *host;
    double pico, escala;
    int nb;
} CtxModelos;

static int bloco_separar(void *ctx, const float *seg, size_t len, float **saidas, int i) {
    CtxModelos *c = ctx;
    return mv_separar(seg, len, c->pico, saidas[0], saidas[1], c->host,
                      (double)i / c->nb, (double)(i + 1) / c->nb);
}

static int bloco_eco(void *ctx, const float *seg, size_t len, float **saidas, int i) {
    CtxModelos *c = ctx;
    return mv_remover_eco(seg, len, c->escala, saidas[0], c->host, (double)i / c->nb, (double)(i + 1) / c->nb);
}

/* ------------------------------------------------------------------ montagem */

/* LUFS como o motor_voz lê do ffmpeg: arredondado a 0,1; "sem valor" abaixo de -70 */
static int lufs_lido(double bruto, double *v) {
    char s[32];
    snprintf(s, sizeof s, "%.1f", bruto);
    double x = strtod(s, NULL);
    if (x < -70) return 0;
    *v = x;
    return 1;
}

/* ganho em dB escrito com 2 casas (como no filtro volume=X.XXdB) -> fator float */
static float fator_volume(double db) {
    char s[32];
    snprintf(s, sizeof s, "%.2f", db);
    return (float)pow(10.0, strtod(s, NULL) / 20.0);
}

static int lufs_arquivo(const char *p, double *v) {
    FILE *f = fopen(p, "rb");
    if (!f) return -4;
    MVLoudness *m = mv_loud_abrir(SR, 2);
    float *buf = malloc(sizeof(float) * 2 * PEDACO);
    if (!m || !buf) { fclose(f); mv_loud_fechar(m); free(buf); return -2; }
    size_t k;
    while ((k = fread(buf, 8, PEDACO, f)) > 0) mv_loud_processar(m, buf, k);
    *v = mv_loud_resultado(m);
    mv_loud_fechar(m); free(buf); fclose(f);
    return 0;
}

double mv_lufs(const float *x, size_t quadros, int canais) {
    MVLoudness *m = mv_loud_abrir(SR, canais);
    if (!m) return -999;
    mv_loud_processar(m, x, quadros);
    double v = mv_loud_resultado(m);
    mv_loud_fechar(m);
    return v;
}

/* Clareza (+ mono): voz -> voz filtrada estéreo, medindo o LUFS da saída no caminho */
static int filtrar_voz(const char *entrada, const char *saida, const MVOpcoes *op, double *lufs_saida) {
    MVBiquad bq[2][7];
    MVCompressor comp;
    const int nbq = op->clareza ? 7 : 0;
    const int canais = op->mono ? 1 : 2;
    for (int c = 0; c < canais; c++) {
        mv_bq_highpass(&bq[c][0], 80, SR, 0);
        mv_bq_highpass(&bq[c][1], 80, SR, 0);
        mv_bq_equalizer(&bq[c][2], 1050, 0.8, 7, SR, 0);
        mv_bq_equalizer(&bq[c][3], 2000, 1, 2, SR, 0);
        mv_bq_equalizer(&bq[c][4], 3800, 1, 4, SR, 0);
        mv_bq_equalizer(&bq[c][5], 6600, 1.2, -6, SR, 0);
        mv_bq_equalizer(&bq[c][6], 9000, 1, -2, SR, 0);
    }
    const int usar_comp = op->clareza && !op->quadra;
    mv_comp_abrir(&comp, pow(10.0, -24 / 20.0), 2.5, 10, 150, 1, SR);

    FILE *fi = fopen(entrada, "rb"), *fo = fopen(saida, "wb");
    MVLoudness *m = mv_loud_abrir(SR, 2);
    float *buf = malloc(sizeof(float) * 2 * PEDACO), *pl = malloc(sizeof(float) * 2 * PEDACO);
    int r = 0;
    if (!fi || !fo || !m || !buf || !pl) { r = fi && fo ? -2 : -4; goto fim; }
    size_t k;
    while ((k = fread(buf, 8, PEDACO, fi)) > 0) {
        /* planar: mono (pan 0,5·L + 0,5·R) ou L/R */
        if (canais == 1) for (size_t i = 0; i < k; i++) pl[i] = buf[2 * i] * 0.5f + buf[2 * i + 1] * 0.5f;
        else for (size_t i = 0; i < k; i++) { pl[i] = buf[2 * i]; pl[PEDACO + i] = buf[2 * i + 1]; }
        for (int c = 0; c < canais; c++)
            for (int j = 0; j < nbq; j++) mv_bq_processar(&bq[c][j], pl + c * PEDACO, k);
        if (canais == 1) {
            if (usar_comp) mv_comp_processar(&comp, pl, k, 1);
            for (size_t i = 0; i < k; i++) buf[2 * i] = buf[2 * i + 1] = pl[i] * 0.70710677f;   /* -ac 2 */
        } else {
            for (size_t i = 0; i < k; i++) { buf[2 * i] = pl[i]; buf[2 * i + 1] = pl[PEDACO + i]; }
            if (usar_comp) mv_comp_processar(&comp, buf, k, 2);
        }
        mv_loud_processar(m, buf, k);
        if (fwrite(buf, 8, k, fo) != k) { r = -4; goto fim; }
    }
    *lufs_saida = mv_loud_resultado(m);
fim:
    if (fi) fclose(fi);
    if (fo && fclose(fo) != 0 && !r) r = -4;
    mv_loud_fechar(m); free(buf); free(pl);
    return r;
}

/* Uma saída final: [volume] -> [quadra] -> limitador -> MP3 e/ou f32 */
typedef struct {
    float ganho;            /* 1 = sem volume */
    int quadra;
    MVBiquad hp[2][2];
    MVLimitador lim;
    CodMP3 *mp3;
    FILE *f32;
    float *tmp;
} Saida;

static int saida_abrir(Saida *s, float ganho, int quadra, double limite, const char *mp3, const char *f32) {
    memset(s, 0, sizeof *s);
    s->ganho = ganho; s->quadra = quadra;
    for (int c = 0; c < 2; c++) { mv_bq_highpass(&s->hp[c][0], 110, SR, 0); mv_bq_highpass(&s->hp[c][1], 110, SR, 0); }
    if (mv_lim_abrir(&s->lim, limite, SR, 2) != 0) return -2;
    s->tmp = malloc(sizeof(float) * 2 * PEDACO);
    if (!s->tmp) return -2;
    if (mp3 && !(s->mp3 = cod_mp3_abrir(mp3, SR, 2, 320))) return -5;
    if (f32 && !(s->f32 = fopen(f32, "wb"))) return -4;
    return 0;
}

static int saida_emitir(Saida *s, const float *x, size_t k) {
    if (!k) return 0;
    if (s->mp3 && cod_mp3_escrever(s->mp3, x, (int)k) != 0) return -5;
    if (s->f32 && fwrite(x, 8, k, s->f32) != k) return -4;
    return 0;
}

/* x intercalado (k <= PEDACO quadros), alterado no lugar */
static int saida_processar(Saida *s, float *x, size_t k) {
    if (s->ganho != 1.0f) for (size_t i = 0; i < 2 * k; i++) x[i] *= s->ganho;
    if (s->quadra) {
        float *l = s->tmp, *r = s->tmp + PEDACO;
        for (size_t i = 0; i < k; i++) { l[i] = x[2 * i]; r[i] = x[2 * i + 1]; }
        for (int j = 0; j < 2; j++) { mv_bq_processar(&s->hp[0][j], l, k); mv_bq_processar(&s->hp[1][j], r, k); }
        for (size_t i = 0; i < k; i++) x[2 * i] = x[2 * i + 1] = l[i] * 0.5f + r[i] * 0.5f;
    }
    size_t o = mv_lim_processar(&s->lim, x, k, s->tmp);
    return saida_emitir(s, s->tmp, o);
}

static int saida_fechar(Saida *s, int ok) {
    int r = 0;
    if (ok && s->tmp) {
        size_t o = mv_lim_terminar(&s->lim, s->tmp);
        r = saida_emitir(s, s->tmp, o);
    }
    if (s->mp3 && cod_mp3_fechar(s->mp3) != 0 && !r) r = -5;
    if (s->f32 && fclose(s->f32) != 0 && !r) r = -4;
    mv_lim_fechar(&s->lim);
    free(s->tmp);
    memset(s, 0, sizeof *s);
    return r;
}

static char *juntar(const char *a, const char *b) {
    size_t n = strlen(a) + strlen(b) + 2;
    char *s = malloc(n);
    if (s) snprintf(s, n, "%s%s", a, b);
    return s;
}

/* ------------------------------------------------------------------ mv_tratar */

int mv_tratar(const char *entrada_f32, const char *pasta_tmp,
              const char *mp3_voz, const char *mp3_trilha, const char *mp3_mix,
              const char *saida_f32_prefixo,
              MVOpcoes op, MVHost host, char *erro, int nerro) {
    int r = 0, nb = 0;
    Bloco *blocos = NULL;
    float *seg = NULL, *bv = NULL, *bt = NULL;
    FILE *fv = NULL, *ft = NULL;
    Saida sv, st, sm;
    memset(&sv, 0, sizeof sv); memset(&st, 0, sizeof st); memset(&sm, 0, sizeof sm);
    char *f_voz_orig = juntar(pasta_tmp, "/voz_original.f32");
    char *f_tri = juntar(pasta_tmp, "/trilha.f32");
    char *f_voz = juntar(pasta_tmp, "/voz.f32");
    char *f_voz_f = juntar(pasta_tmp, "/voz_filtrada.f32");
    char *p_sep = juntar(pasta_tmp, "/ponto_separacao.bin");
    char *p_eco = juntar(pasta_tmp, "/ponto_eco.bin");
    char *o_voz = NULL, *o_tri = NULL, *o_mix = NULL;
    if (saida_f32_prefixo) {
        o_voz = juntar(saida_f32_prefixo, "voz.f32");
        o_tri = juntar(saida_f32_prefixo, "trilha.f32");
        o_mix = juntar(saida_f32_prefixo, "mix.f32");
    }
    const char *voz_orig, *tri = NULL, *voz;

    int64_t n64 = quadros_arquivo(entrada_f32);
    if (n64 < 0) { falha(erro, nerro, "não consegui ler o áudio"); r = -4; goto fim; }
    size_t n = (size_t)n64;
    if (n < SR / 2) { falha(erro, nerro, "áudio curto demais (menos de meio segundo)"); r = -1; goto fim; }
    if (!(blocos = dividir(n, op.bloco_seg, &nb))) { r = -2; goto fim; }

    CtxModelos cm = { &host, 0, 0, nb };

    /* 1. separação voz/trilha, por blocos, com o pico do arquivo inteiro */
    if (op.separar) {
        FILE *f = fopen(entrada_f32, "rb");
        float *buf = malloc(sizeof(float) * 2 * PEDACO);
        if (!f || !buf) { if (f) fclose(f); free(buf); r = -4; goto fim; }
        size_t k; double pico = 0;
        while ((k = fread(buf, 4, 2 * PEDACO, f)) > 0)
            for (size_t i = 0; i < k; i++) { double a = fabs(buf[i]); if (a > pico) pico = a; }
        fclose(f); free(buf);
        cm.pico = pico;
        const char *said[2] = { f_voz_orig, f_tri };
        if ((r = por_blocos(entrada_f32, n, said, 2, blocos, nb, bloco_separar, &cm, p_sep)) != 0) goto fim;
        voz_orig = f_voz_orig; tri = f_tri;
    } else {
        voz_orig = entrada_f32;
    }
    if (host.cancelado && host.cancelado(host.ctx)) { r = 1; goto fim; }

    /* 2. eco, por blocos, com a escala do arquivo inteiro */
    if (op.eco) {
        cm.escala = 0;
        if (nb > 1) {
            FILE *f = fopen(voz_orig, "rb");
            if (!f) { r = -4; goto fim; }
            for (int i = 0; i < nb && !r; i++) {
                size_t len = blocos[i].fim - blocos[i].ini;
                seg = malloc(sizeof(float) * 2 * len);
                if (!seg) r = -2;
                else if (!(r = ler_trecho(f, blocos[i].ini, blocos[i].fim, seg))) {
                    double e = mv_escala_eco(seg, len);
                    if (e > cm.escala) cm.escala = e;
                }
                free(seg); seg = NULL;
            }
            fclose(f);
            if (r) goto fim;
        }
        const char *said[1] = { f_voz };
        if ((r = por_blocos(voz_orig, n, said, 1, blocos, nb, bloco_eco, &cm, p_eco)) != 0) goto fim;
        voz = f_voz;
    } else {
        voz = voz_orig;
    }
    if (host.cancelado && host.cancelado(host.ctx)) { r = 1; goto fim; }

    /* 3. clareza / mono */
    if (host.progresso) host.progresso(host.ctx, 3, 0);
    double lv_bruto, lv = 0, lo = 0;
    if ((r = filtrar_voz(voz, f_voz_f, &op, &lv_bruto)) != 0) goto fim;
    /* (voz.f32 fica até o fim: se o app for fechado depois daqui, a retomada ainda precisa dele) */
    int tem_lv = lufs_lido(lv_bruto, &lv);
    int tem_lo = 0;
    if (tri) {
        double lo_bruto;
        if ((r = lufs_arquivo(voz_orig, &lo_bruto)) != 0) goto fim;
        tem_lo = lufs_lido(lo_bruto, &lo);
    }
    if (host.progresso) host.progresso(host.ctx, 3, 0.2);

    /* 4. saídas: voz nivelada, trilha e mix */
    int nivelar = op.nivelar && tem_lv;
    float ganho_mix = 1.0f;
    if ((mp3_voz || o_voz) &&
        (r = saida_abrir(&sv, nivelar ? fator_volume(ALVO_LUFS - lv) : 1.0f, op.quadra,
                         nivelar ? 0.84 : 0.97, mp3_voz, o_voz)) != 0) goto fim;
    if (tri && (mp3_trilha || o_tri) &&
        (r = saida_abrir(&st, 1.0f, op.quadra, 0.97, mp3_trilha, o_tri)) != 0) goto fim;
    if (tri && (mp3_mix || o_mix)) {
        double gv = (tem_lo && tem_lv) ? lo + op.voz_frente_db - lv : op.voz_frente_db;
        ganho_mix = fator_volume(gv);          /* só na voz, antes da soma */
        if ((r = saida_abrir(&sm, 1.0f, op.quadra, 0.89, mp3_mix, o_mix)) != 0) goto fim;
    }
    fv = fopen(f_voz_f, "rb");
    ft = tri ? fopen(tri, "rb") : NULL;
    bv = malloc(sizeof(float) * 2 * PEDACO);
    bt = malloc(sizeof(float) * 2 * PEDACO);
    seg = malloc(sizeof(float) * 2 * PEDACO);
    if (!fv || (tri && !ft) || !bv || !bt || !seg) { r = -4; goto fim; }
    size_t feito = 0;
    for (;;) {
        size_t k = fread(bv, 8, PEDACO, fv);
        if (!k) break;
        if (ft && fread(bt, 8, k, ft) != k) { r = -4; goto fim; }
        if (sm.lim.buffer) {                   /* mix = voz·gv + trilha */
            for (size_t i = 0; i < 2 * k; i++) seg[i] = bv[i] * ganho_mix + bt[i];
            if ((r = saida_processar(&sm, seg, k)) != 0) goto fim;
        }
        if (sv.lim.buffer && (r = saida_processar(&sv, bv, k)) != 0) goto fim;
        if (st.lim.buffer && (r = saida_processar(&st, bt, k)) != 0) goto fim;
        feito += k;
        if (host.progresso) host.progresso(host.ctx, 3, 0.2 + 0.8 * (double)feito / (double)n);
        if (host.cancelado && host.cancelado(host.ctx)) { r = 1; goto fim; }
    }

fim:
    {
        int ok = r == 0;
        int r1 = sv.lim.buffer || sv.tmp ? saida_fechar(&sv, ok) : 0;
        int r2 = st.lim.buffer || st.tmp ? saida_fechar(&st, ok) : 0;
        int r3 = sm.lim.buffer || sm.tmp ? saida_fechar(&sm, ok) : 0;
        if (!r) r = r1 ? r1 : r2 ? r2 : r3;
    }
    if (fv) fclose(fv);
    if (ft) fclose(ft);
    free(bv); free(bt); free(seg); free(blocos);
    /* intermediários só saem quando deu certo: interrompido, eles servem para continuar */
    if (r == 0) {
        if (f_voz_orig) remove(f_voz_orig);
        if (f_tri) remove(f_tri);
        if (f_voz) remove(f_voz);
        if (f_voz_f) remove(f_voz_f);
        if (p_sep) remove(p_sep);
        if (p_eco) remove(p_eco);
    }
    if (r && erro && nerro > 0 && !erro[0]) {
        if (r == 1) falha(erro, nerro, "cancelado");
        else if (r == -2) falha(erro, nerro, "memória insuficiente");
        else if (r == -3) falha(erro, nerro, "falha ao rodar o modelo de IA");
        else if (r == -4) falha(erro, nerro, "falha ao ler ou gravar arquivo temporário");
        else if (r == -5) falha(erro, nerro, "falha ao gravar o MP3");
        else falha(erro, nerro, "erro %d", r);
    }
    free(f_voz_orig); free(f_tri); free(f_voz); free(f_voz_f); free(p_sep); free(p_eco);
    free(o_voz); free(o_tri); free(o_mix);
    return r;
}
