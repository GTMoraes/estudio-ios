/* Separação (MDX-Net Kim_Vocal_2) e remoção de eco (VR 5.1 UVR-DeEcho-DeReverb):
   porte fiel de motor_voz/mdx.py e motor_voz/vr.py (que reproduzem o audio-separator 0.47). */
#include "motorvoz.h"
#include "mv_interno.h"
#include "pocketfft.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ------------------------------------------------------------------ FFT real */

typedef struct { rfft_plan plano; int n; double *buf; } FFT;

static int fft_abrir(FFT *f, int n) {
    f->n = n;
    f->plano = make_rfft_plan((size_t)n);
    f->buf = malloc(sizeof(double) * (size_t)n);
    return (f->plano && f->buf) ? 0 : -1;
}
static void fft_fechar(FFT *f) {
    if (f->plano) destroy_rfft_plan(f->plano);
    free(f->buf);
    memset(f, 0, sizeof(*f));
}
/* rfft de f->buf (n reais) -> re[0..n/2], im[0..n/2] */
static void fft_direta(FFT *f, double *re, double *im) {
    int n = f->n, nb = n / 2 + 1;
    rfft_forward(f->plano, f->buf, 1.0);
    re[0] = f->buf[0]; im[0] = 0;
    for (int k = 1; k < nb; k++) {
        if (2 * k - 1 < n) re[k] = f->buf[2 * k - 1]; else re[k] = 0;
        if (2 * k < n) im[k] = f->buf[2 * k]; else im[k] = 0;
    }
    if (n % 2 == 0) { re[nb - 1] = f->buf[n - 1]; im[nb - 1] = 0; }
}
/* irfft (normalizada 1/n, como o numpy) de re/im -> f->buf */
static void fft_inversa(FFT *f, const double *re, const double *im) {
    int n = f->n, nb = n / 2 + 1;
    f->buf[0] = re[0];
    for (int k = 1; k < nb; k++) {
        if (n % 2 == 0 && k == nb - 1) { f->buf[n - 1] = re[k]; break; }
        f->buf[2 * k - 1] = re[k];
        f->buf[2 * k] = im[k];
    }
    rfft_backward(f->plano, f->buf, 1.0 / n);
}

static double *hann_periodica(int n) {
    double *w = malloc(sizeof(double) * (size_t)n);
    if (w) for (int i = 0; i < n; i++) w[i] = (float)(0.5 - 0.5 * cos(2 * M_PI * i / n));   /* float32, como no numpy */
    return w;
}

/* ------------------------------------------------------------------ MDX */

#define MDX_NFFT 7680
#define MDX_DIMF 3072
#define MDX_DIMT 256
#define MDX_HOP 1024
#define MDX_CHUNK (MDX_HOP * (MDX_DIMT - 1))
#define MDX_TRIM (MDX_NFFT / 2)
#define MDX_COMP 1.009

typedef struct { FFT fft; double *win; double *re, *im; } MDXCtx;

static void mdx_stft(MDXCtx *m, const float *parte /* [2][CHUNK] */, float *spec /* [4][DIMF][DIMT] */) {
    const int p = MDX_NFFT / 2, L = MDX_CHUNK;
    for (int ch = 0; ch < 2; ch++) {
        const float *x = parte + (size_t)ch * L;
        for (int t = 0; t < MDX_DIMT; t++) {
            for (int i = 0; i < MDX_NFFT; i++) {
                int j = t * MDX_HOP + i - p;                 /* pad "reflect" */
                if (j < 0) j = -j;
                if (j >= L) j = 2 * (L - 1) - j;
                m->fft.buf[i] = (double)(float)(x[j] * (float)m->win[i]);
            }
            fft_direta(&m->fft, m->re, m->im);
            float *sr = spec + ((size_t)(2 * ch) * MDX_DIMF) * MDX_DIMT;
            float *si = spec + ((size_t)(2 * ch + 1) * MDX_DIMF) * MDX_DIMT;
            for (int f = 0; f < MDX_DIMF; f++) {
                sr[(size_t)f * MDX_DIMT + t] = f < 3 ? 0.f : (float)m->re[f];
                si[(size_t)f * MDX_DIMT + t] = f < 3 ? 0.f : (float)m->im[f];
            }
        }
    }
}

static void mdx_istft(MDXCtx *m, const float *spec, float *saida /* [2][CHUNK] */, double *acum, double *wsum) {
    const int L = MDX_CHUNK, p = MDX_NFFT / 2, nb = MDX_NFFT / 2 + 1;
    const int total = MDX_NFFT + MDX_HOP * (MDX_DIMT - 1);
    for (int ch = 0; ch < 2; ch++) {
        memset(acum, 0, sizeof(double) * (size_t)total);
        memset(wsum, 0, sizeof(double) * (size_t)total);
        const float *sr = spec + ((size_t)(2 * ch) * MDX_DIMF) * MDX_DIMT;
        const float *si = spec + ((size_t)(2 * ch + 1) * MDX_DIMF) * MDX_DIMT;
        for (int t = 0; t < MDX_DIMT; t++) {
            for (int k = 0; k < nb; k++) {
                m->re[k] = k < MDX_DIMF ? sr[(size_t)k * MDX_DIMT + t] : 0;
                m->im[k] = k < MDX_DIMF ? si[(size_t)k * MDX_DIMT + t] : 0;
            }
            fft_inversa(&m->fft, m->re, m->im);
            int a = t * MDX_HOP;
            for (int i = 0; i < MDX_NFFT; i++) {
                acum[a + i] += m->fft.buf[i] * m->win[i];
                wsum[a + i] += m->win[i] * m->win[i];
            }
        }
        float *y = saida + (size_t)ch * L;
        for (int i = 0; i < L; i++) {
            double w = wsum[p + i] > 1e-11 ? wsum[p + i] : 1e-11;
            y[i] = (float)(acum[p + i] / w);
        }
    }
}

int mv_separar(const float *mix, size_t n, double pico, float *voz, float *trilha, MVHost *host, double p0, double p1) {
    if (pico <= 0) {
        pico = 0;
        for (size_t i = 0; i < 2 * n; i++) { double a = fabs(mix[i]); if (a > pico) pico = a; }
    }
    if (pico <= 0) pico = 1.0;
    const float s = pico > 0.9 ? (float)(0.9 / pico) : 1.0f;

    const size_t gen = MDX_CHUNK - 2 * MDX_TRIM;
    const size_t pad = gen + MDX_TRIM - (n % gen);
    const size_t Ltot = MDX_TRIM + n + pad;
    const size_t passo = (size_t)((1 - 0.25) * MDX_CHUNK);

    MDXCtx m = {0};
    float *mistura = calloc(2 * Ltot, sizeof(float));
    float *res = calloc(2 * Ltot, sizeof(float));
    float *div = calloc(Ltot, sizeof(float));
    float *parte = malloc(sizeof(float) * 2 * MDX_CHUNK);
    float *spec = malloc(sizeof(float) * 4 * MDX_DIMF * MDX_DIMT);
    float *out = malloc(sizeof(float) * 4 * MDX_DIMF * MDX_DIMT);
    float *tar = malloc(sizeof(float) * 2 * MDX_CHUNK);
    float *jan = malloc(sizeof(float) * MDX_CHUNK);
    const int total = MDX_NFFT + MDX_HOP * (MDX_DIMT - 1);
    double *acum = malloc(sizeof(double) * total), *wsum = malloc(sizeof(double) * total);
    m.win = hann_periodica(MDX_NFFT);
    m.re = malloc(sizeof(double) * (MDX_NFFT / 2 + 1));
    m.im = malloc(sizeof(double) * (MDX_NFFT / 2 + 1));
    int erro = 0;
    if (!mistura || !res || !div || !parte || !spec || !out || !tar || !jan || !acum || !wsum || !m.win || !m.re || !m.im
        || fft_abrir(&m.fft, MDX_NFFT) != 0) { erro = -2; goto fim; }

    for (int ch = 0; ch < 2; ch++)
        for (size_t i = 0; i < n; i++)
            mistura[ch * Ltot + MDX_TRIM + i] = mix[ch * n + i] * s;

    size_t npassos = (Ltot + passo - 1) / passo, k = 0;
    for (size_t i = 0; i < Ltot; i += passo, k++) {
        if (host->cancelado && host->cancelado(host->ctx)) { erro = 1; goto fim; }
        size_t fimp = i + MDX_CHUNK < Ltot ? i + MDX_CHUNK : Ltot, nn = fimp - i;
        for (int ch = 0; ch < 2; ch++) {
            memset(parte + ch * MDX_CHUNK, 0, sizeof(float) * MDX_CHUNK);
            memcpy(parte + ch * MDX_CHUNK, mistura + ch * Ltot + i, sizeof(float) * nn);
        }
        mdx_stft(&m, parte, spec);
        if (host->inferir(host->ctx, MV_MODELO_SEPARACAO, spec, out) != 0) { erro = -3; goto fim; }
        mdx_istft(&m, out, tar, acum, wsum);
        for (size_t j = 0; j < nn; j++)                   /* np.hanning(nn): simétrica */
            jan[j] = nn > 1 ? (float)(0.5 - 0.5 * cos(2 * M_PI * (double)j / (double)(nn - 1))) : 1.f;
        for (size_t j = 0; j < nn; j++) {
            div[i + j] += jan[j];
            res[i + j] += tar[j] * jan[j];
            res[Ltot + i + j] += tar[MDX_CHUNK + j] * jan[j];
        }
        if (host->progresso) host->progresso(host->ctx, 1, p0 + (p1 - p0) * (double)(k + 1) / (double)npassos);
    }
    for (int ch = 0; ch < 2; ch++)
        for (size_t i = 0; i < n; i++) {
            float d = div[MDX_TRIM + i];
            float v = res[ch * Ltot + MDX_TRIM + i] / d;
            if (!isfinite(v)) v = 0;
            v /= s;
            voz[ch * n + i] = v;
            if (trilha) trilha[ch * n + i] = (float)(mix[ch * n + i] - v * MDX_COMP);
        }
fim:
    fft_fechar(&m.fft);
    free(m.win); free(m.re); free(m.im);
    free(mistura); free(res); free(div); free(parte); free(spec); free(out); free(tar); free(jan); free(acum); free(wsum);
    return erro;
}

/* ------------------------------------------------------------------ reamostragem (scipy resample_poly) */

static const double FIR_2[41] = {-7.158970950886459e-19, -0.0010514587726751215, 1.8542998243319006e-18, 0.0025089668121477146, -3.494145233950968e-18, -0.004894834339287572, 5.60645116237481e-18, 0.008556559002481406, -8.091013094452995e-18, -0.01398997323843515, 1.0781132014374604e-17, 0.022023120574074614, -1.3459677422897392e-17, -0.03434017988174492, 1.5884600682954174e-17, 0.05528828391185702, -1.78202070879486e-17, -0.10093019739773386, 1.9069296838463637e-17, 0.31670034568030075, 0.5002587352980301, 0.31670034568030075, 1.9069296838463637e-17, -0.10093019739773386, -1.78202070879486e-17, 0.05528828391185702, 1.5884600682954174e-17, -0.03434017988174492, -1.3459677422897392e-17, 0.022023120574074614, 1.0781132014374604e-17, -0.01398997323843515, -8.091013094452995e-18, 0.008556559002481406, 5.60645116237481e-18, -0.004894834339287572, -3.494145233950968e-18, 0.0025089668121477146, 1.8542998243319006e-18, -0.0010514587726751215, -7.158970950886459e-19};
static const double FIR_3[61] = {-4.7730704295658725e-19, -0.0005075758102200313, -0.0007171615080117002, 1.236309480760199e-18, 0.0012758309278842026, 0.0016363257536276235, -2.3296366764436676e-18, -0.0025516902081487085, -0.0031211659077244767, 3.737965475977085e-18, 0.004526422701358553, 0.005382747080070106, -5.394486946700331e-18, -0.00746728859359711, -0.008729113144086137, 7.188058558707442e-18, 0.011807636463532887, 0.013690670311138468, -8.973913812399522e-18, -0.01839848841497541, -0.021385829642969294, 1.059067264351481e-17, 0.02934103840854192, 0.03484133879872257, -1.1881191316986062e-17, -0.05182809185364537, -0.06626323877512581, 1.2713991644429615e-17, 0.13655221514239765, 0.2751477226789338, 0.3335353911845924, 0.2751477226789338, 0.13655221514239765, 1.2713991644429615e-17, -0.06626323877512581, -0.05182809185364537, -1.1881191316986062e-17, 0.03484133879872257, 0.02934103840854192, 1.059067264351481e-17, -0.021385829642969294, -0.01839848841497541, -8.973913812399522e-18, 0.013690670311138468, 0.011807636463532887, 7.188058558707442e-18, -0.008729113144086137, -0.00746728859359711, -5.394486946700331e-18, 0.005382747080070106, 0.004526422701358553, 3.737965475977085e-18, -0.0031211659077244767, -0.0025516902081487085, -2.3296366764436676e-18, 0.0016363257536276235, 0.0012758309278842026, 1.236309480760199e-18, -0.0007171615080117002, -0.0005075758102200313, -4.7730704295658725e-19};

/* y = resample_poly(x, up, down) ajustado a ceil(n*up/down) amostras (librosa fix=True). */
static float *reamostrar(const float *x, size_t nin, int up, int down, size_t *nout_ret) {
    int mr = up > down ? up : down;
    const double *fir = mr == 3 ? FIR_3 : FIR_2;
    int half = 10 * mr, nh = 2 * half + 1;
    int pre = down - half % down;
    size_t pre_remove = (size_t)(half + pre) / (size_t)down;
    size_t nout = (nin * up + down - 1) / down;
    float *y = calloc(nout ? nout : 1, sizeof(float));
    if (!y) return NULL;
    for (size_t q = 0; q < nout; q++) {
        long long m = (long long)(q + pre_remove) * down;       /* índice na saída cheia do upfirdn */
        /* hpad[j] = fir[j - pre] * up (0 fora); y = sum_i x[i] * hpad[m - i*up] */
        long long imin = (m - (pre + nh - 1) + up - 1) / up; if (imin < 0) imin = 0;
        long long imax = (m - pre) / up;
        if (m - pre < 0) imax = -1;
        if (imax >= (long long)nin) imax = (long long)nin - 1;
        double acc = 0;
        for (long long i = imin; i <= imax; i++) {
            long long j = m - i * up - pre;
            if (j >= 0 && j < nh) acc += x[i] * fir[j] * up;
        }
        y[q] = (float)acc;
    }
    *nout_ret = nout;
    return y;
}

/* ------------------------------------------------------------------ VR (4band_v3) */

typedef struct { int sr, hl, n_fft, crop_start, crop_stop, lpf_start, lpf_stop, hpf_start, hpf_stop; } Banda;
static const Banda BANDAS[5] = {
    {0},
    {7350, 80, 640, 0, 85, 25, 53, 0, 0},
    {7350, 80, 320, 4, 87, 31, 62, 25, 12},
    {14700, 160, 512, 17, 216, 139, 210, 48, 24},
    {44100, 480, 960, 78, 383, 0, 0, 130, 86},
};
#define VR_BINS 672
#define VR_LINHAS (VR_BINS + 1)
#define VR_JANELA 512
#define VR_OFFSET 64
#define VR_ROI (VR_JANELA - 2 * VR_OFFSET)
#define VR_AGGR 0.05

/* espectro combinado: re/im [2][673][T] */
typedef struct { size_t T; float *re, *im; } Espectro;

static size_t n_quadros(size_t n, int n_fft, int hop) {
    size_t p = (size_t)n_fft / 2;
    return 1 + (n + 2 * p - (size_t)n_fft) / (size_t)hop;
}

/* STFT estilo librosa (center, pad de zeros) de um canal, copiando as linhas [crop_start, crop_stop)
   para as linhas off.. do espectro combinado (só os T primeiros quadros). */
static int stft_banda(const float *x, size_t n, const Banda *b, Espectro *e, int ch, int off) {
    FFT f; if (fft_abrir(&f, b->n_fft) != 0) return -2;
    double *w = hann_periodica(b->n_fft);
    int nb = b->n_fft / 2 + 1;
    double *re = malloc(sizeof(double) * nb), *im = malloc(sizeof(double) * nb);
    if (!w || !re || !im) { fft_fechar(&f); free(w); free(re); free(im); return -2; }
    long p = b->n_fft / 2;
    for (size_t t = 0; t < e->T; t++) {
        for (int i = 0; i < b->n_fft; i++) {
            long j = (long)(t * b->hl) + i - p;
            float v = (j >= 0 && j < (long)n) ? x[j] : 0.f;
            f.buf[i] = (double)(float)(v * (float)w[i]);
        }
        fft_direta(&f, re, im);
        for (int r = b->crop_start; r < b->crop_stop; r++) {
            size_t idx = ((size_t)ch * VR_LINHAS + (size_t)(off + r - b->crop_start)) * e->T + t;
            e->re[idx] = (float)re[r];
            e->im[idx] = (float)im[r];
        }
    }
    fft_fechar(&f); free(w); free(re); free(im);
    return 0;
}

static float lp_val(int k, int n, int a, int b) {         /* _lp(n, a, b)[k] */
    (void)n;
    if (k < a - 1) return 1.f;
    if (k <= b - 1) { int cnt = b - a + 1; return cnt > 1 ? (float)(1.0 - (double)(k - (a - 1)) / (cnt - 1)) : 1.f; }
    return 0.f;
}
static float hp_val(int k, int n, int a, int b) {         /* _hp(n, a, b)[k] */
    (void)n;
    if (k < b + 1) return 0.f;
    if (k <= a) { int cnt = 1 + a - b; return cnt > 1 ? (float)((double)(k - (b + 1)) / (cnt - 1)) : 1.f; }
    return 1.f;
}

static int espectro_vr(const float *wave, size_t n, Espectro *e) {
    /* reamostragens: 44100 -> 14700 -> 7350 (a banda 1 usa a mesma de 7350) */
    size_t n3, n2;
    float *w3[2] = {0}, *w2[2] = {0};
    for (int c = 0; c < 2; c++) {
        w3[c] = reamostrar(wave + c * n, n, 1, 3, &n3);
        w2[c] = w3[c] ? reamostrar(w3[c], n3, 1, 2, &n2) : NULL;
    }
    int erro = 0;
    if (!w3[0] || !w3[1] || !w2[0] || !w2[1]) { erro = -2; goto fim; }
    size_t Tb[5];
    Tb[4] = n_quadros(n, BANDAS[4].n_fft, BANDAS[4].hl);
    Tb[3] = n_quadros(n3, BANDAS[3].n_fft, BANDAS[3].hl);
    Tb[2] = n_quadros(n2, BANDAS[2].n_fft, BANDAS[2].hl);
    Tb[1] = n_quadros(n2, BANDAS[1].n_fft, BANDAS[1].hl);
    size_t T = Tb[1];
    for (int d = 2; d <= 4; d++) if (Tb[d] < T) T = Tb[d];
    e->T = T;
    e->re = calloc((size_t)2 * VR_LINHAS * T, sizeof(float));
    e->im = calloc((size_t)2 * VR_LINHAS * T, sizeof(float));
    if (!e->re || !e->im) { erro = -2; goto fim; }
    int off = 0;
    for (int d = 1; d <= 4; d++) {
        for (int c = 0; c < 2; c++) {
            const float *x; size_t nn;
            if (d == 4) { x = wave + c * n; nn = n; }
            else if (d == 3) { x = w3[c]; nn = n3; }
            else { x = w2[c]; nn = n2; }
            if ((erro = stft_banda(x, nn, &BANDAS[d], e, c, off)) != 0) goto fim;
        }
        off += BANDAS[d].crop_stop - BANDAS[d].crop_start;
    }
    /* pré-filtro: _lp(673, 668, 672) */
    for (int c = 0; c < 2; c++)
        for (int r = 0; r < VR_LINHAS; r++) {
            float g = lp_val(r, VR_LINHAS, 668, 672);
            if (g == 1.f) continue;
            for (size_t t = 0; t < T; t++) {
                size_t idx = ((size_t)c * VR_LINHAS + r) * T + t;
                e->re[idx] *= g; e->im[idx] *= g;
            }
        }
fim:
    for (int c = 0; c < 2; c++) { free(w3[c]); free(w2[c]); }
    return erro;
}

/* ISTFT estilo librosa (center, sem length): s re/im [nb][T] -> T-1 * hop amostras */
static float *istft_banda(const float *sre, const float *sim, int nb, size_t T, int hop, size_t *nret) {
    int n_fft = 2 * (nb - 1);
    size_t total = (size_t)n_fft + (size_t)hop * (T - 1);
    double *y = calloc(total, sizeof(double)), *ws = calloc(total, sizeof(double));
    double *w = hann_periodica(n_fft);
    double *re = malloc(sizeof(double) * nb), *im = malloc(sizeof(double) * nb);
    FFT f; int ok = fft_abrir(&f, n_fft) == 0;
    float *saida = NULL;
    if (!y || !ws || !w || !re || !im || !ok) goto fim;
    for (size_t t = 0; t < T; t++) {
        for (int k = 0; k < nb; k++) { re[k] = sre[(size_t)k * T + t]; im[k] = sim[(size_t)k * T + t]; }
        fft_inversa(&f, re, im);
        size_t a = t * (size_t)hop;
        for (int i = 0; i < n_fft; i++) { y[a + i] += f.buf[i] * w[i]; ws[a + i] += w[i] * w[i]; }
    }
    size_t nout = total - (size_t)n_fft;
    saida = malloc(sizeof(float) * (nout ? nout : 1));
    if (saida) {
        for (size_t i = 0; i < nout; i++) {
            size_t j = i + (size_t)n_fft / 2;
            double v = ws[j] > 1.1754943508222875e-38 ? y[j] / ws[j] : y[j];
            saida[i] = (float)v;
        }
        *nret = nout;
    }
fim:
    if (ok) fft_fechar(&f);
    free(y); free(ws); free(w); free(re); free(im);
    return saida;
}

/* espectro (já mascarado) -> onda 44.1k [2][*nret] */
static int onda_vr(const Espectro *e, float **saida, size_t *nret) {
    size_t T = e->T;
    float *onda[2] = {0};
    size_t nonda = 0;
    int off = 0, erro = 0;
    for (int d = 1; d <= 4; d++) {
        const Banda *b = &BANDAS[d];
        int nb = b->n_fft / 2 + 1, h = b->crop_stop - b->crop_start;
        float *sre = calloc((size_t)nb * T, sizeof(float)), *sim = calloc((size_t)nb * T, sizeof(float));
        if (!sre || !sim) { free(sre); free(sim); erro = -2; goto fim; }
        const size_t nanterior = nonda;               /* comprimento das ondas das bandas de baixo */
        size_t nnova = 0;
        for (int c = 0; c < 2; c++) {
            memset(sre, 0, sizeof(float) * nb * T); memset(sim, 0, sizeof(float) * nb * T);
            for (int r = 0; r < h; r++) {
                int k = b->crop_start + r;
                float g = 1.f;
                if (d == 1) g = lp_val(k, nb, b->lpf_start, b->lpf_stop);
                else if (d == 4) g = hp_val(k, nb, b->hpf_start, b->hpf_stop - 1);
                else g = hp_val(k, nb, b->hpf_start, b->hpf_stop - 1) * lp_val(k, nb, b->lpf_start, b->lpf_stop);
                const float *er = e->re + ((size_t)c * VR_LINHAS + off + r) * T;
                const float *ei = e->im + ((size_t)c * VR_LINHAS + off + r) * T;
                for (size_t t = 0; t < T; t++) { sre[(size_t)k * T + t] = er[t] * g; sim[(size_t)k * T + t] = ei[t] * g; }
            }
            size_t ni = 0;
            float *y = istft_banda(sre, sim, nb, T, b->hl, &ni);
            if (!y) { free(sre); free(sim); erro = -2; goto fim; }
            if (d > 1) {                                 /* soma com o que veio das bandas de baixo */
                size_t m = ni < nanterior ? ni : nanterior;
                for (size_t i = 0; i < m; i++) y[i] += onda[c][i];
            }
            free(onda[c]);
            if (d < 4) {
                int up = BANDAS[d + 1].sr / b->sr;
                size_t nr;
                float *r = up == 1 ? y : reamostrar(y, ni, up, 1, &nr);
                if (up == 1) nr = ni; else free(y);
                if (!r) { free(sre); free(sim); erro = -2; goto fim; }
                onda[c] = r; nnova = nr;
            } else {
                onda[c] = y; nnova = ni;
            }
        }
        nonda = nnova;
        free(sre); free(sim);
        off += h;
    }
    *saida = malloc(sizeof(float) * 2 * nonda);
    if (!*saida) { erro = -2; goto fim; }
    for (int c = 0; c < 2; c++) {
        for (size_t i = 0; i < nonda; i++) {
            float v = onda[c][i];
            (*saida)[c * nonda + i] = isfinite(v) ? v : 0.f;
        }
    }
    *nret = nonda;
fim:
    free(onda[0]); free(onda[1]);
    return erro;
}

double mv_escala_eco(const float *voz, size_t n) {
    Espectro e = {0};
    if (espectro_vr(voz, n, &e) != 0) { free(e.re); free(e.im); return 0; }
    double m = 0;
    size_t tot = (size_t)2 * VR_LINHAS * e.T;
    for (size_t i = 0; i < tot; i++) {
        double a = hypot((double)e.re[i], (double)e.im[i]);
        if (a > m) m = a;
    }
    free(e.re); free(e.im);
    return m;
}

int mv_remover_eco(const float *voz, size_t n, double escala, float *saida, MVHost *host, double p0, double p1) {
    Espectro e = {0};
    int erro = espectro_vr(voz, n, &e);
    float *entrada = NULL, *mask = NULL, *mag = NULL, *onda = NULL;
    if (erro) goto fim;
    size_t T = e.T, tot = (size_t)2 * VR_LINHAS * T;
    mag = malloc(sizeof(float) * tot);
    if (!mag) { erro = -2; goto fim; }
    double maxv = 0;
    for (size_t i = 0; i < tot; i++) {
        float a = (float)hypot((double)e.re[i], (double)e.im[i]);
        mag[i] = a; if (a > maxv) maxv = a;
    }
    double ref = escala > 0 ? escala : maxv;
    if (ref <= 0 || maxv <= 0) {                         /* silêncio: nada a tirar */
        memcpy(saida, voz, sizeof(float) * 2 * n);
        goto fim;
    }
    size_t pad_r = VR_ROI - (T % VR_ROI) + VR_OFFSET;
    size_t Tp = VR_OFFSET + T + pad_r;
    size_t patches = (Tp - 2 * VR_OFFSET) / VR_ROI;
    entrada = malloc(sizeof(float) * 2 * VR_LINHAS * VR_JANELA);
    mask = malloc(sizeof(float) * 2 * VR_LINHAS * VR_ROI);
    if (!entrada || !mask) { erro = -2; goto fim; }
    const int split = BANDAS[1].crop_stop;
    const double a = VR_AGGR * 2;
    for (size_t pi = 0; pi < patches; pi++) {
        if (host->cancelado && host->cancelado(host->ctx)) { erro = 1; goto fim; }
        for (int c = 0; c < 2; c++)
            for (int r = 0; r < VR_LINHAS; r++)
                for (int j = 0; j < VR_JANELA; j++) {
                    long t = (long)(pi * VR_ROI) + j - VR_OFFSET;
                    float v = (t >= 0 && t < (long)T) ? mag[((size_t)c * VR_LINHAS + r) * T + t] : 0.f;
                    entrada[((size_t)c * VR_LINHAS + r) * VR_JANELA + j] = (float)(v / ref);
                }
        if (host->inferir(host->ctx, MV_MODELO_ECO, entrada, mask) != 0) { erro = -3; goto fim; }
        for (int c = 0; c < 2; c++)
            for (int r = 0; r < VR_LINHAS; r++) {
                double ex = r < split ? 1 + a / 3 : 1 + a;
                for (int j = 0; j < VR_ROI; j++) {
                    size_t t = pi * VR_ROI + j;
                    if (t >= T) break;
                    float mk = (float)pow((double)mask[((size_t)c * VR_LINHAS + r) * VR_ROI + j], ex);
                    size_t idx = ((size_t)c * VR_LINHAS + r) * T + t;
                    e.re[idx] *= mk; e.im[idx] *= mk;
                }
            }
        if (host->progresso) host->progresso(host->ctx, 2, p0 + (p1 - p0) * (double)(pi + 1) / (double)patches);
    }
    free(mag); mag = NULL;
    size_t no;
    if ((erro = onda_vr(&e, &onda, &no)) != 0) goto fim;
    for (int c = 0; c < 2; c++)
        for (size_t i = 0; i < n; i++)
            saida[c * n + i] = i < no ? onda[c * no + i] : 0.f;
fim:
    free(e.re); free(e.im); free(entrada); free(mask); free(mag); free(onda);
    return erro;
}
