#ifndef MOTORVOZ_H
#define MOTORVOZ_H

/* Motor de tratamento de voz em C: o mesmo motor_voz (Python) do site e do ConversorMidia,
   portado para rodar no iPhone. Os dois modelos de IA ficam fora: quem chama fornece a
   função `inferir` (no iPhone, ONNX Runtime; nos testes, ONNX Runtime em C).

   Áudio sempre a 44,1 kHz, estéreo. Arquivos intermediários são float32 intercalado (L R L R…). */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { MV_MODELO_SEPARACAO = 0, MV_MODELO_ECO = 1 };

/* Roda um modelo. Separação: entrada e saída (1,4,3072,256). Eco: entrada (1,2,673,512),
   saída (1,2,673,384). Devolve 0 em sucesso. */
typedef int (*MVInferir)(void *ctx, int modelo, const float *entrada, float *saida);

/* etapa: 0 lendo, 1 separação, 2 eco, 3 montando; fracao 0..1 dentro da etapa. */
typedef void (*MVProgresso)(void *ctx, int etapa, double fracao);

/* Devolve 1 para cancelar. */
typedef int (*MVCancelado)(void *ctx);

typedef struct {
    int separar;           /* fala/musica: 1; so_voz: 0 */
    int eco;
    int clareza;
    int mono;              /* fala/so_voz: 1; musica: 0 */
    int nivelar;           /* fala/so_voz: 1; musica: 0 */
    double voz_frente_db;
    int quadra;            /* 1 = saída para quadra/ginásio (mono, sem graves, clareza sem compressor) */
    double bloco_seg;      /* tamanho do bloco (s); 0 = arquivo inteiro */
} MVOpcoes;

typedef struct {
    MVInferir inferir;
    MVProgresso progresso;
    MVCancelado cancelado;
    void *ctx;
} MVHost;

/* Processa `entrada_f32` (float32 intercalado estéreo 44,1 kHz) e grava os MP3 pedidos
   (NULL = não gerar). `pasta_tmp` recebe arquivos intermediários (apagados no fim).
   `saida_f32_prefixo` (opcional, testes): grava também voz/trilha/mix finais em float32.
   Devolve 0 em sucesso, 1 cancelado, <0 erro (mensagem em `erro`). */
int mv_tratar(const char *entrada_f32, const char *pasta_tmp,
              const char *mp3_voz, const char *mp3_trilha, const char *mp3_mix,
              const char *saida_f32_prefixo,
              MVOpcoes op, MVHost host, char *erro, int nerro);

/* ---- peças expostas para os testes ---- */

/* Separação (MDX, Kim_Vocal_2): mix planar [2][n] -> voz planar [2][n] e trilha. pico <= 0: do próprio trecho. */
int mv_separar(const float *mix, size_t n, double pico, float *voz, float *trilha, MVHost *host, double p0, double p1);

/* Remoção de eco (VR 5.1): planar [2][n] -> planar [2][n]. escala <= 0: a do próprio trecho. */
int mv_remover_eco(const float *voz, size_t n, double escala, float *saida, MVHost *host, double p0, double p1);
double mv_escala_eco(const float *voz, size_t n);

/* Volume percebido (LUFS integrado) de um sinal intercalado; retorna < -900 se silêncio. */
double mv_lufs(const float *x, size_t quadros, int canais);

#ifdef __cplusplus
}
#endif
#endif
