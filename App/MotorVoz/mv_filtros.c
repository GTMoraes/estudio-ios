/* Filtros do ffmpeg 6.1 usados pelo motor_voz (af_biquads, af_sidechaincompress,
   af_alimiter, f_ebur128), portados para dar o mesmo resultado sem o ffmpeg. */
#include "mv_interno.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ------------------------------------------------------------------ biquads */

static void bq_normalizar(MVBiquad *f, double a0, double a1, double a2, double b0, double b1, double b2, int dupla) {
    f->a[1] = a1 / a0; f->a[2] = a2 / a0;
    f->b[0] = b0 / a0; f->b[1] = b1 / a0; f->b[2] = b2 / a0;
    f->a[0] = 1.0;
    for (int i = 0; i < 3; i++) { f->af[i] = (float)f->a[i]; f->bf[i] = (float)f->b[i]; }
    memset(f->di, 0, sizeof f->di);
    memset(f->fi, 0, sizeof f->fi);
    f->dupla = dupla;
}

void mv_bq_highpass(MVBiquad *f, double freq, double sr, int dupla) {
    double w0 = 2 * M_PI * freq / sr;
    double alpha = sin(w0) / (2 * 0.707);
    bq_normalizar(f, 1 + alpha, -2 * cos(w0), 1 - alpha,
                  (1 + cos(w0)) / 2, -(1 + cos(w0)), (1 + cos(w0)) / 2, dupla);
}

void mv_bq_equalizer(MVBiquad *f, double freq, double q, double ganho_db, double sr, int dupla) {
    double A = pow(10.0, ganho_db / 40);
    double w0 = 2 * M_PI * freq / sr;
    double alpha = sin(w0) / (2 * q);
    bq_normalizar(f, 1 + alpha / A, -2 * cos(w0), 1 - alpha / A,
                  1 + alpha * A, -2 * cos(w0), 1 - alpha * A, dupla);
}

/* Mesma ordem das somas do ffmpeg: in[-2]*b2 + in[-1]*b1 + in*b0 + out[-2]*a2 + out[-1]*a1 */
#define BQ_LOOP(T, B, A, S)                                                          \
    do {                                                                             \
        T b0 = B[0], b1 = B[1], b2 = B[2], a1 = -A[1], a2 = -A[2];                   \
        T i1 = S[0], i2 = S[1], o1 = S[2], o2 = S[3];                                \
        for (size_t k = 0; k < n; k++) {                                             \
            T in = (T)x[k];                                                          \
            T o0 = i2 * b2 + i1 * b1 + in * b0 + o2 * a2 + o1 * a1;                  \
            i2 = i1; i1 = in; o2 = o1; o1 = o0;                                      \
            x[k] = (float)o0;                                                        \
        }                                                                            \
        S[0] = i1; S[1] = i2; S[2] = o1; S[3] = o2;                                  \
    } while (0)

void mv_bq_processar(MVBiquad *f, float *x, size_t n) {
    if (f->dupla) BQ_LOOP(double, f->b, f->a, f->di);
    else          BQ_LOOP(float, f->bf, f->af, f->fi);
}

/* ------------------------------------------------------------------ acompressor */

static double hermite(double x, double x0, double x1, double p0, double p1, double m0, double m1) {
    double width = x1 - x0, t = (x - x0) / width;
    m0 *= width; m1 *= width;
    double t2 = t * t, t3 = t2 * t;
    double ct0 = p0, ct1 = m0;
    double ct2 = -3 * p0 - 2 * m0 + 3 * p1 - m1;
    double ct3 = 2 * p0 + m0 - 2 * p1 + m1;
    return ct3 * t3 + ct2 * t2 + ct1 * t + ct0;
}

void mv_comp_abrir(MVCompressor *c, double limiar_lin, double ratio, double attack_ms, double release_ms,
                   double makeup, double sr) {
    memset(c, 0, sizeof *c);
    c->knee = 2.82843; c->ratio = ratio; c->makeup = makeup;
    c->thres = log(limiar_lin);
    c->lin_knee_start = limiar_lin / sqrt(c->knee);
    c->lin_knee_stop = limiar_lin * sqrt(c->knee);
    c->adj_knee_start = c->lin_knee_start * c->lin_knee_start;
    c->adj_knee_stop = c->lin_knee_stop * c->lin_knee_stop;
    c->knee_start = log(c->lin_knee_start);
    c->knee_stop = log(c->lin_knee_stop);
    c->compressed_knee_start = (c->knee_start - c->thres) / ratio + c->thres;
    c->compressed_knee_stop = (c->knee_stop - c->thres) / ratio + c->thres;
    c->attack_coeff = fmin(1., 1. / (attack_ms * sr / 4000.));
    c->release_coeff = fmin(1., 1. / (release_ms * sr / 4000.));
}

void mv_comp_processar(MVCompressor *c, float *x, size_t quadros, int canais) {
    for (size_t i = 0; i < quadros; i++) {
        float *src = x + i * canais;
        double gain = 1.0;
        double abs_sample = fabs((double)src[0] * 1.0);
        for (int ch = 1; ch < canais; ch++) abs_sample += fabs((double)src[ch] * 1.0);   /* link=average */
        abs_sample /= canais;
        abs_sample *= abs_sample;                         /* detecção RMS */
        c->lin_slope += (abs_sample - c->lin_slope) * (abs_sample > c->lin_slope ? c->attack_coeff : c->release_coeff);
        if (c->lin_slope > 0.0 && c->lin_slope > c->adj_knee_start) {
            double slope = log(c->lin_slope) * 0.5;
            double g = (slope - c->thres) / c->ratio + c->thres;
            double delta = 1.0 / c->ratio;
            if (c->knee > 1.0 && slope < c->knee_stop)
                g = hermite(slope, c->knee_start, c->knee_stop, c->knee_start, c->compressed_knee_stop, 1.0, delta);
            gain = exp(g - slope);
        }
        for (int ch = 0; ch < canais; ch++)
            src[ch] = (float)((double)src[ch] * 1.0 * (gain * c->makeup * 1.0 + (1. - 1.0)));
    }
}

/* ------------------------------------------------------------------ alimiter */

int mv_lim_abrir(MVLimitador *l, double limite, int sr, int canais) {
    memset(l, 0, sizeof *l);
    l->limit = limite; l->release = 50 / 1000.; l->att = 1.; l->canais = canais; l->sr = sr;
    int obuffer_size = (int)(sr * canais * 100 / 1000. + canais);
    l->buffer = calloc(obuffer_size, sizeof(double));
    l->nextdelta = calloc(obuffer_size, sizeof(double));
    l->nextpos = malloc(sizeof(int) * obuffer_size);
    if (!l->buffer || !l->nextdelta || !l->nextpos) { mv_lim_fechar(l); return -2; }
    memset(l->nextpos, -1, sizeof(int) * obuffer_size);
    double attack = 5 / 1000.;
    l->buffer_size = (int)(sr * attack * canais);
    l->buffer_size -= l->buffer_size % canais;
    l->trim = l->pad = l->buffer_size / canais - 1;
    return 0;
}

void mv_lim_fechar(MVLimitador *l) {
    free(l->buffer); free(l->nextdelta); free(l->nextpos);
    l->buffer = l->nextdelta = NULL; l->nextpos = NULL;
}

/* um quadro: src (canais) -> dst (canais) */
static void lim_quadro(MVLimitador *l, const double *src, double *dst) {
    const int channels = l->canais, buffer_size = l->buffer_size;
    const double limit = l->limit, release = l->release;
    double *buffer = l->buffer, *nextdelta = l->nextdelta;
    int *nextpos = l->nextpos;
    double peak = 0;
    int c, i;

    for (c = 0; c < channels; c++) {
        double sample = src[c] * 1.0;
        buffer[l->pos + c] = sample;
        peak = fmax(peak, fabs(sample));
    }
    if (peak > limit) {
        double patt = fmin(limit / peak, 1.);
        double rdelta = (1.0 - patt) / (l->sr * release);
        double delta = (limit / peak - l->att) / buffer_size * channels;
        int found = 0;
        if (delta < l->delta) {
            l->delta = delta;
            nextpos[0] = l->pos;
            nextpos[1] = -1;
            nextdelta[0] = rdelta;
            l->nextlen = 1;
            l->nextiter = 0;
        } else {
            for (i = l->nextiter; i < l->nextiter + l->nextlen; i++) {
                int j = i % buffer_size;
                double ppeak = 0, pdelta;
                if (nextpos[j] >= 0)
                    for (c = 0; c < channels; c++) ppeak = fmax(ppeak, fabs(buffer[nextpos[j] + c]));
                pdelta = (limit / peak - limit / ppeak) / (((buffer_size - nextpos[j] + l->pos) % buffer_size) / channels);
                if (pdelta < nextdelta[j]) {
                    nextdelta[j] = pdelta;
                    found = 1;
                    break;
                }
            }
            if (found) {
                l->nextlen = i - l->nextiter + 1;
                nextpos[(l->nextiter + l->nextlen) % buffer_size] = l->pos;
                nextdelta[(l->nextiter + l->nextlen) % buffer_size] = rdelta;
                nextpos[(l->nextiter + l->nextlen + 1) % buffer_size] = -1;
                l->nextlen++;
            }
        }
    }

    double *buf = &buffer[(l->pos + channels) % buffer_size];
    peak = 0;
    for (c = 0; c < channels; c++) peak = fmax(peak, fabs(buf[c]));

    l->att += l->delta;
    for (c = 0; c < channels; c++) dst[c] = buf[c] * l->att;

    if ((l->pos + channels) % buffer_size == nextpos[l->nextiter]) {
        l->delta = nextdelta[l->nextiter];
        l->att = limit / peak;
        l->nextlen -= 1;
        nextpos[l->nextiter] = -1;
        l->nextiter = (l->nextiter + 1) % buffer_size;
    }
    if (l->att > 1.) {
        l->att = 1.; l->delta = 0.; l->nextiter = 0; l->nextlen = 0; nextpos[0] = -1;
    }
    if (l->att <= 0.) {
        l->att = 0.0000000000001;
        l->delta = (1.0 - l->att) / (l->sr * release);
    }
    if (l->att != 1. && (1. - l->att) < 0.0000000000001) l->att = 1.;
    if (l->delta != 0. && fabs(l->delta) < 0.00000000000001) l->delta = 0.;

    for (c = 0; c < channels; c++) {
        double v = dst[c];
        v = v < -limit ? -limit : v > limit ? limit : v;
        dst[c] = v * 1 * 1.0;
    }
    l->pos = (l->pos + channels) % buffer_size;
}

size_t mv_lim_processar(MVLimitador *l, const float *entrada, size_t quadros, float *saida) {
    double src[8], dst[8];
    size_t nout = 0;
    for (size_t q = 0; q < quadros; q++) {
        for (int c = 0; c < l->canais; c++) src[c] = entrada[q * l->canais + c];
        lim_quadro(l, src, dst);
        if (l->trim > 0) { l->trim--; continue; }
        for (int c = 0; c < l->canais; c++) saida[nout * l->canais + c] = (float)dst[c];
        nout++;
    }
    return nout;
}

size_t mv_lim_terminar(MVLimitador *l, float *saida) {
    double src[8] = {0}, dst[8];
    size_t nout = 0;
    while (l->pad > 0) {
        l->pad--;
        lim_quadro(l, src, dst);
        if (l->trim > 0) { l->trim--; continue; }
        for (int c = 0; c < l->canais; c++) saida[nout * l->canais + c] = (float)dst[c];
        nout++;
    }
    return nout;
}

/* ------------------------------------------------------------------ ebur128 (I) */

#define ABS_THRES   -70
#define ABS_UP_THRES 10
#define HIST_GRAIN  100
#define HIST_SIZE   ((ABS_UP_THRES - ABS_THRES) * HIST_GRAIN + 1)
#define ENERGY(l)   (pow(10.0, ((l) + 0.691) / 10.))
#define LOUDNESS(e) (-0.691 + 10 * log10(e))
#define HIST_POS(p) (int)(((p) - ABS_THRES) * HIST_GRAIN)

struct MVLoudness {
    int sr, canais, cache_size, cache_pos, filled, sample_count;
    double pre_b[3], pre_a[3], rlb_b[3], rlb_a[3];
    double x[3 * 8], y[3 * 8], z[3 * 8];
    double sum[8];
    double *cache[8];
    unsigned count[HIST_SIZE];
    double energy[HIST_SIZE];
    double sum_kept_powers;
    unsigned long long nb_kept_powers;
    double integrated;
};

static int clip(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

MVLoudness *mv_loud_abrir(int sr, int canais) {
    if (canais < 1 || canais > 8) return NULL;
    MVLoudness *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->sr = sr; m->canais = canais;
    double f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
    double K = tan(M_PI * f0 / (double)sr);
    double Vh = pow(10.0, G / 20.0), Vb = pow(Vh, 0.4996667741545416);
    double a0 = 1.0 + K / Q + K * K;
    m->pre_b[0] = (Vh + Vb * K / Q + K * K) / a0;
    m->pre_b[1] = 2.0 * (K * K - Vh) / a0;
    m->pre_b[2] = (Vh - Vb * K / Q + K * K) / a0;
    m->pre_a[1] = 2.0 * (K * K - 1.0) / a0;
    m->pre_a[2] = (1.0 - K / Q + K * K) / a0;
    f0 = 38.13547087602444; Q = 0.5003270373238773;
    K = tan(M_PI * f0 / (double)sr);
    m->rlb_b[0] = 1.0; m->rlb_b[1] = -2.0; m->rlb_b[2] = 1.0;
    m->rlb_a[1] = 2.0 * (K * K - 1.0) / (1.0 + K / Q + K * K);
    m->rlb_a[2] = (1.0 - K / Q + K * K) / (1.0 + K / Q + K * K);
    m->cache_size = sr * 4 / 10;
    for (int c = 0; c < canais; c++)
        if (!(m->cache[c] = calloc(m->cache_size, sizeof(double)))) { mv_loud_fechar(m); return NULL; }
    for (int i = 0; i < HIST_SIZE; i++) m->energy[i] = ENERGY(i / (double)HIST_GRAIN + ABS_THRES);
    m->integrated = ABS_THRES;
    return m;
}

void mv_loud_fechar(MVLoudness *m) {
    if (!m) return;
    for (int c = 0; c < m->canais; c++) free(m->cache[c]);
    free(m);
}

#define FILTRO(Y, X, NUM, DEN) do {                                               \
        double *dst = m->Y + ch * 3, *src = m->X + ch * 3;                        \
        dst[2] = dst[1]; dst[1] = dst[0];                                         \
        dst[0] = src[0] * NUM[0] + src[1] * NUM[1] + src[2] * NUM[2]              \
                 - dst[1] * DEN[1] - dst[2] * DEN[2];                             \
    } while (0)

void mv_loud_processar(MVLoudness *m, const float *x, size_t quadros) {
    const int nc = m->canais;
    for (size_t q = 0; q < quadros; q++) {
        const int bin_id = m->cache_pos;
        if (++m->cache_pos == m->cache_size) { m->filled = 1; m->cache_pos = 0; }
        for (int ch = 0; ch < nc; ch++) {
            m->x[ch * 3] = (double)x[q * nc + ch];
            FILTRO(y, x, m->pre_b, m->pre_a);
            m->x[ch * 3 + 2] = m->x[ch * 3 + 1];
            m->x[ch * 3 + 1] = m->x[ch * 3];
            FILTRO(z, y, m->rlb_b, m->rlb_a);
            double bin = m->z[ch * 3] * m->z[ch * 3];
            m->sum[ch] = m->sum[ch] + bin - m->cache[ch][bin_id];
            m->cache[ch][bin_id] = bin;
        }
        if (++m->sample_count == m->sr / 10) {
            double power = 1e-12;
            m->sample_count = 0;
            if (m->filled) {
                for (int ch = 0; ch < nc; ch++) power += 1.0 * m->sum[ch];
                power /= m->cache_size;
            }
            double loud = LOUDNESS(power);
            if (loud >= ABS_THRES) {
                m->count[clip(HIST_POS(loud), 0, HIST_SIZE - 1)]++;
                m->sum_kept_powers += power;
                m->nb_kept_powers++;
                double rel = m->sum_kept_powers / m->nb_kept_powers;
                if (!rel) rel = 1e-12;
                int gate = clip(HIST_POS(LOUDNESS(rel) + -10), 0, HIST_SIZE - 1);
                double s = 0.0;
                unsigned long long nb = 0;
                for (int i = gate; i < HIST_SIZE; i++) { nb += m->count[i]; s += m->count[i] * m->energy[i]; }
                if (nb) m->integrated = LOUDNESS(s / nb);
            }
        }
    }
}

double mv_loud_resultado(const MVLoudness *m) { return m->integrated; }
