#include "cb_ort.h"
#include "../MotorVoz/ort/onnxruntime_c_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct CBOrt {
    const OrtApi *api;
    OrtEnv *env;
    OrtMemoryInfo *mem;
    OrtSession *sess;
    char *saida;               /* nome da primeira saída */
    char erro[512];
};

static int falhou(CBOrt *o, OrtStatus *s) {
    if (!s) return 0;
    snprintf(o->erro, sizeof o->erro, "%s", o->api->GetErrorMessage(s));
    o->api->ReleaseStatus(s);
    return 1;
}

CBOrt *cb_ort_abrir(const char *modelo) {
    CBOrt *o = calloc(1, sizeof *o);
    if (!o) return NULL;
    o->api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!o->api) { snprintf(o->erro, sizeof o->erro, "ONNX Runtime incompatível"); return o; }
    const OrtApi *api = o->api;
    if (falhou(o, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "chatterbox", &o->env))) return o;
    if (falhou(o, api->CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &o->mem))) return o;
    OrtSessionOptions *so = NULL;
    if (falhou(o, api->CreateSessionOptions(&so))) return o;
    /* sem a "arena" de memória: o pico cai bastante no iPhone (igual ao motor de voz) */
    int ok = !falhou(o, api->DisableCpuMemArena(so)) && !falhou(o, api->DisableMemPattern(so))
             && !falhou(o, api->SetSessionGraphOptimizationLevel(so, ORT_ENABLE_ALL));
    if (ok) falhou(o, api->CreateSession(o->env, modelo, so, &o->sess));
    api->ReleaseSessionOptions(so);
    if (o->sess) {
        OrtAllocator *al = NULL;
        char *nome = NULL;
        if (!falhou(o, api->GetAllocatorWithDefaultOptions(&al))
            && !falhou(o, api->SessionGetOutputName(o->sess, 0, al, &nome))) {
            o->saida = strdup(nome);
            api->AllocatorFree(al, nome);
        }
    }
    return o;
}

const char *cb_ort_erro(const CBOrt *o) { return o ? o->erro : "sem memória"; }

int cb_ort_decodificar(CBOrt *o,
                       const char *nome_tokens, const int64_t *tokens, int64_t nt,
                       const char *nome_xvec, const float *xvec, int64_t nx,
                       const char *nome_feat, const float *feat, int64_t linhas, int64_t colunas,
                       float **saida, int64_t *n) {
    if (!o || !o->sess || !o->saida) {
        if (o && !o->erro[0]) snprintf(o->erro, sizeof o->erro, "o decodificador não abriu");
        return -1;
    }
    const OrtApi *api = o->api;
    *saida = NULL; *n = 0;
    OrtValue *v[3] = {NULL, NULL, NULL}, *out = NULL;
    OrtTensorTypeAndShapeInfo *info = NULL;
    int r = -1;
    int64_t f0[2] = {1, nt}, f1[2] = {1, nx}, f2[3] = {1, linhas, colunas};
    if (falhou(o, api->CreateTensorWithDataAsOrtValue(o->mem, (void *)tokens, (size_t)nt * 8, f0, 2,
                                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v[0]))) goto fim;
    if (falhou(o, api->CreateTensorWithDataAsOrtValue(o->mem, (void *)xvec, (size_t)nx * 4, f1, 2,
                                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &v[1]))) goto fim;
    if (falhou(o, api->CreateTensorWithDataAsOrtValue(o->mem, (void *)feat, (size_t)(linhas * colunas) * 4, f2, 3,
                                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &v[2]))) goto fim;
    const char *nin[3] = {nome_tokens, nome_xvec, nome_feat};
    const char *nout[1] = {o->saida};
    if (falhou(o, api->Run(o->sess, NULL, nin, (const OrtValue *const *)v, 3, nout, 1, &out))) goto fim;
    if (falhou(o, api->GetTensorTypeAndShape(out, &info))) goto fim;
    size_t cont = 0;
    if (falhou(o, api->GetTensorShapeElementCount(info, &cont))) goto fim;
    float *dados = NULL;
    if (falhou(o, api->GetTensorMutableData(out, (void **)&dados))) goto fim;
    *saida = malloc(cont * sizeof(float) + 1);
    if (!*saida) { snprintf(o->erro, sizeof o->erro, "sem memória para o áudio"); goto fim; }
    memcpy(*saida, dados, cont * sizeof(float));
    *n = (int64_t)cont;
    o->erro[0] = 0;
    r = 0;
fim:
    if (info) api->ReleaseTensorTypeAndShapeInfo(info);
    if (out) api->ReleaseValue(out);
    for (int i = 0; i < 3; i++) if (v[i]) api->ReleaseValue(v[i]);
    return r;
}

void cb_ort_liberar(float *p) { free(p); }

void cb_ort_fechar(CBOrt *o) {
    if (!o) return;
    if (o->sess) o->api->ReleaseSession(o->sess);
    if (o->mem) o->api->ReleaseMemoryInfo(o->mem);
    if (o->env) o->api->ReleaseEnv(o->env);
    free(o->saida);
    free(o);
}
