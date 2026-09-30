#ifndef MV_INTERNO_H
#define MV_INTERNO_H
/* Uso interno do motor de voz: os filtros do ffmpeg 6.1 usados pelo motor_voz, portados
   com a mesma aritmética (mesmos coeficientes, mesma precisão, mesma ordem das contas). */

#include <stddef.h>

/* ---- biquad (highpass / equalizer do ffmpeg, forma direta I) ---- */
typedef struct {
    double b[3], a[3];          /* normalizados (a[0] = 1) */
    float bf[3], af[3];
    double di[4];               /* estado em double: i1 i2 o1 o2 */
    float fi[4];                /* estado em float */
    int dupla;                  /* 1: conta em double; 0: em float */
} MVBiquad;

void mv_bq_highpass(MVBiquad *f, double freq, double sr, int dupla);                 /* Q 0,707 */
void mv_bq_equalizer(MVBiquad *f, double freq, double q, double ganho_db, double sr, int dupla);
void mv_bq_processar(MVBiquad *f, float *x, size_t n);                              /* mono, no lugar */

/* ---- acompressor (mono, detecção RMS) ---- */
typedef struct {
    double thres, knee, ratio, makeup;
    double lin_knee_start, lin_knee_stop, adj_knee_start, adj_knee_stop;
    double knee_start, knee_stop, compressed_knee_start, compressed_knee_stop;
    double attack_coeff, release_coeff, lin_slope;
} MVCompressor;

void mv_comp_abrir(MVCompressor *c, double limiar_lin, double ratio, double attack_ms, double release_ms,
                   double makeup, double sr);
void mv_comp_processar(MVCompressor *c, float *x, size_t quadros, int canais);        /* intercalado, no lugar */

/* ---- alimiter (level=false, latency=1): a saída tem o mesmo tamanho da entrada ---- */
typedef struct {
    double limit, release, att, delta;
    double *buffer, *nextdelta;
    int *nextpos;
    int buffer_size, pos, nextiter, nextlen, canais, sr;
    int trim, pad;
} MVLimitador;

int  mv_lim_abrir(MVLimitador *l, double limite, int sr, int canais);
/* Processa `quadros` quadros intercalados; grava em `saida` e devolve quantos quadros saíram
   (os primeiros são descartados pela compensação de atraso). `saida` precisa de `quadros` quadros. */
size_t mv_lim_processar(MVLimitador *l, const float *entrada, size_t quadros, float *saida);
/* Fim do áudio: grava os quadros que faltam (até buffer_size/canais) e devolve quantos. */
size_t mv_lim_terminar(MVLimitador *l, float *saida);
void mv_lim_fechar(MVLimitador *l);

/* ---- ebur128: volume integrado (LUFS), como o resumo "I:" do ffmpeg ---- */
typedef struct MVLoudness MVLoudness;
MVLoudness *mv_loud_abrir(int sr, int canais);
void mv_loud_processar(MVLoudness *m, const float *x, size_t quadros);              /* intercalado */
double mv_loud_resultado(const MVLoudness *m);                                       /* LUFS, sem arredondar */
void mv_loud_fechar(MVLoudness *m);

#endif
