#ifndef CODIFICADORES_H
#define CODIFICADORES_H

/* Codificadores de áudio que o iOS não tem: MP3 (LAME) e OGG Vorbis (libvorbis).
   Entrada: PCM float intercalado (-1..1). Devolvem 0 em sucesso. */

typedef struct CodMP3 CodMP3;
CodMP3 *cod_mp3_abrir(const char *caminho, int taxa, int canais, int kbps);
int cod_mp3_escrever(CodMP3 *c, const float *pcm, int quadros);
int cod_mp3_fechar(CodMP3 *c);

typedef struct CodOGG CodOGG;
/* qualidade: 0..10 (como o -q:a do ffmpeg) */
CodOGG *cod_ogg_abrir(const char *caminho, int taxa, int canais, float qualidade);
int cod_ogg_escrever(CodOGG *c, const float *pcm, int quadros);
int cod_ogg_fechar(CodOGG *c);

#endif
