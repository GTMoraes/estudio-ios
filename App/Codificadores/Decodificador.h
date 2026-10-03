#ifndef ESTUDIO_DECODIFICADOR_H
#define ESTUDIO_DECODIFICADOR_H

// Ponte para o FFmpeg embutido (vendor-ff, compilado por scripts/compilar-ffmpeg.sh).
// O FFmpeg só lê e decodifica; quem grava é o AVFoundation.

/// Versão do FFmpeg que veio no app (ex.: "7.1.1").
const char *estudio_ffmpeg_versao(void);

/// 1 se o decodificador com esse nome existe (ex.: "vp9", "vp8", "av1", "opus").
int estudio_ffmpeg_decodifica(const char *nome);

#endif
