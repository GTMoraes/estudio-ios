#ifndef CB_ORT_H
#define CB_ORT_H
/* Decodificador do Chatterbox (fala em tokens -> áudio 24 kHz) com o ONNX Runtime (API C), na CPU. */
#include <stdint.h>

typedef struct CBOrt CBOrt;

CBOrt *cb_ort_abrir(const char *modelo);
/* Última mensagem de erro ("" se nenhuma). */
const char *cb_ort_erro(const CBOrt *o);
/* tokens int64 [1, nt]; xvec float [1, nx]; feat float [1, linhas, colunas].
   *saida recebe a primeira saída (float, alocada com malloc: libere com cb_ort_liberar) e *n o número de valores.
   Retorna 0 se deu certo. */
int cb_ort_decodificar(CBOrt *o,
                       const char *nome_tokens, const int64_t *tokens, int64_t nt,
                       const char *nome_xvec, const float *xvec, int64_t nx,
                       const char *nome_feat, const float *feat, int64_t linhas, int64_t colunas,
                       float **saida, int64_t *n);
void cb_ort_liberar(float *p);
void cb_ort_fechar(CBOrt *o);

#endif
