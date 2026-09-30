#ifndef MV_ORT_H
#define MV_ORT_H
/* Roda os dois modelos do motor de voz com o ONNX Runtime (API C).
   Abre cada modelo só quando é usado e fecha o outro (a separação termina antes do eco),
   sem o "arena" de memória do ORT: no iPhone o pico cai pela metade, na mesma velocidade. */

typedef struct MVOrt MVOrt;

/* neural = 1: tenta o CoreML (Neural Engine); se o modelo não abrir assim, usa a CPU. */
MVOrt *mv_ort_abrir(const char *modelo_separacao, const char *modelo_eco, int neural);
/* Mesma assinatura de MVInferir (ctx = MVOrt*). */
int mv_ort_inferir(void *ctx, int modelo, const float *entrada, float *saida);
/* Última mensagem de erro ("" se nenhuma). */
const char *mv_ort_erro(const MVOrt *o);
/* Quais modelos abriram no Neural Engine (CoreML): bit 0 separação, bit 1 eco. */
int mv_ort_neural_ativo(const MVOrt *o);
void mv_ort_fechar(MVOrt *o);

#endif
