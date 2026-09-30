#ifndef CODIFICADORES_H
#define CODIFICADORES_H

/* Codificadores de áudio que o iOS não tem: MP3 (LAME) e OGG Vorbis (libvorbis).
   Entrada: PCM float intercalado (-1..1). Devolvem 0 em sucesso. */

#include <stddef.h>

typedef struct CodMP3 CodMP3;
CodMP3 *cod_mp3_abrir(const char *caminho, int taxa, int canais, int kbps);
int cod_mp3_escrever(CodMP3 *c, const float *pcm, int quadros);
int cod_mp3_fechar(CodMP3 *c);

typedef struct CodOGG CodOGG;
/* qualidade: 0..10 (como o -q:a do ffmpeg) */
CodOGG *cod_ogg_abrir(const char *caminho, int taxa, int canais, float qualidade);
int cod_ogg_escrever(CodOGG *c, const float *pcm, int quadros);
int cod_ogg_fechar(CodOGG *c);

/* WebP (libwebp). rgba: pixels RGBA 8 bits NÃO pré-multiplicados. qualidade 0..100 (como o
   -quality do ImageMagick); sem_perdas = 1 liga o modo lossless. exif/icc opcionais (NULL, 0).
   Em sucesso devolve 0 e *saida/*tam com o arquivo pronto; liberar com cod_webp_liberar. */
int cod_webp(const unsigned char *rgba, int largura, int altura, int passo, int com_alfa,
             float qualidade, int sem_perdas,
             const unsigned char *exif, size_t nexif, const unsigned char *icc, size_t nicc,
             unsigned char **saida, size_t *tam);
void cod_webp_liberar(unsigned char *p);

/* WebP animado (libwebpmux / WebPAnimEncoder). Quadros BGRA 8 bits, opacos, todos do mesmo tamanho.
   tempo_ms = instante do quadro desde o início. laco: 0 = repete para sempre, 1 = toca uma vez. */
typedef struct CodWebPAnim CodWebPAnim;
CodWebPAnim *cod_webpanim_abrir(int largura, int altura, float qualidade, int laco);
int cod_webpanim_quadro(CodWebPAnim *a, const unsigned char *bgra, int passo, int tempo_ms);
/* fecha e entrega o arquivo (liberar com cod_webp_liberar); tempo_fim_ms = fim do último quadro.
   Libera o codificador em qualquer caso. */
int cod_webpanim_fechar(CodWebPAnim *a, int tempo_fim_ms, unsigned char **saida, size_t *tam);

#endif
