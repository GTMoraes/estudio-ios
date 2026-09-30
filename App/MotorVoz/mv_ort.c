#include "mv_ort.h"
#include "motorvoz.h"
#include "ort/onnxruntime_c_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
/* coreml_provider_factory.h (ORT 1.19.2): a biblioteca do iOS exporta esta função */
enum { MV_COREML_FLAG_CREATE_MLPROGRAM = 0x010 };
ORT_EXPORT ORT_API_STATUS(OrtSessionOptionsAppendExecutionProvider_CoreML, _In_ OrtSessionOptions* options,
                          uint32_t coreml_flags);
#endif

struct MVOrt {
    const OrtApi *api;
    OrtEnv *env;
    OrtMemoryInfo *mem;
    OrtSession *sess[2];
    char *caminho[2];
    int neural;
    int neural_ativo;          /* bit 0: separação no Neural Engine; bit 1: eco */
    char erro[512];
};

static int falhou(MVOrt *o, OrtStatus *s) {
    if (!s) return 0;
    snprintf(o->erro, sizeof o->erro, "%s", o->api->GetErrorMessage(s));
    o->api->ReleaseStatus(s);
    return 1;
}

MVOrt *mv_ort_abrir(const char *modelo_separacao, const char *modelo_eco, int neural) {
    MVOrt *o = calloc(1, sizeof *o);
    if (!o) return NULL;
    o->api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!o->api) { snprintf(o->erro, sizeof o->erro, "ONNX Runtime incompatível"); return o; }
    o->neural = neural;
    o->caminho[0] = modelo_separacao ? strdup(modelo_separacao) : NULL;
    o->caminho[1] = modelo_eco ? strdup(modelo_eco) : NULL;
    if (falhou(o, o->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "motorvoz", &o->env))) return o;
    falhou(o, o->api->CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &o->mem));
    return o;
}

const char *mv_ort_erro(const MVOrt *o) { return o ? o->erro : "sem memória"; }

int mv_ort_neural_ativo(const MVOrt *o) { return o ? o->neural_ativo : 0; }

static OrtSession *criar(MVOrt *o, const char *caminho, int neural) {
    const OrtApi *api = o->api;
    OrtSessionOptions *so = NULL;
    OrtSession *s = NULL;
    if (falhou(o, api->CreateSessionOptions(&so))) return NULL;
    int ok = !falhou(o, api->DisableCpuMemArena(so)) && !falhou(o, api->DisableMemPattern(so))
             && !falhou(o, api->AddFreeDimensionOverrideByName(so, "batch_size", 1));
    if (ok && neural) {
#ifdef __APPLE__
        ok = !falhou(o, OrtSessionOptionsAppendExecutionProvider_CoreML(so, MV_COREML_FLAG_CREATE_MLPROGRAM));
#else
        ok = 0;
#endif
    }
    if (ok) falhou(o, api->CreateSession(o->env, caminho, so, &s));
    api->ReleaseSessionOptions(so);
    return s;
}

static OrtSession *sessao(MVOrt *o, int modelo) {
    if (o->sess[modelo]) return o->sess[modelo];
    int outro = 1 - modelo;                       /* libera o modelo da etapa anterior */
    if (o->sess[outro]) { o->api->ReleaseSession(o->sess[outro]); o->sess[outro] = NULL; }
    if (!o->caminho[modelo]) { snprintf(o->erro, sizeof o->erro, "modelo %d não informado", modelo); return NULL; }
    OrtSession *s = o->neural ? criar(o, o->caminho[modelo], 1) : NULL;
    if (s) o->neural_ativo |= 1 << modelo;
    else s = criar(o, o->caminho[modelo], 0);
    if (s) o->erro[0] = 0;
    o->sess[modelo] = s;
    return s;
}

int mv_ort_inferir(void *ctx, int modelo, const float *entrada, float *saida) {
    MVOrt *o = ctx;
    if (!o || !o->env || !o->mem || modelo < 0 || modelo > 1) return -1;
    OrtSession *s = sessao(o, modelo);
    if (!s) return -1;
    const OrtApi *api = o->api;
    int64_t fi[4] = {1, 4, 3072, 256}, fo[4] = {1, 4, 3072, 256};
    if (modelo == MV_MODELO_ECO) { fi[1] = 2; fi[2] = 673; fi[3] = 512; fo[1] = 2; fo[2] = 673; fo[3] = 384; }
    size_t ni = (size_t)(fi[1] * fi[2] * fi[3]), no = (size_t)(fo[1] * fo[2] * fo[3]);
    OrtValue *vi = NULL, *vo = NULL;
    int r = -1;
    if (falhou(o, api->CreateTensorWithDataAsOrtValue(o->mem, (void *)entrada, ni * 4, fi, 4,
                                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &vi))) goto fim;
    if (falhou(o, api->CreateTensorWithDataAsOrtValue(o->mem, saida, no * 4, fo, 4,
                                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &vo))) goto fim;
    const char *nin[1] = { "input" }, *nout[1] = { modelo == MV_MODELO_ECO ? "mask" : "output" };
    if (falhou(o, api->Run(s, NULL, nin, (const OrtValue *const *)&vi, 1, nout, 1, &vo))) goto fim;
    r = 0;
fim:
    if (vi) api->ReleaseValue(vi);
    if (vo) api->ReleaseValue(vo);
    return r;
}

void mv_ort_fechar(MVOrt *o) {
    if (!o) return;
    for (int i = 0; i < 2; i++) { if (o->sess[i]) o->api->ReleaseSession(o->sess[i]); free(o->caminho[i]); }
    if (o->mem) o->api->ReleaseMemoryInfo(o->mem);
    if (o->env) o->api->ReleaseEnv(o->env);
    free(o);
}
