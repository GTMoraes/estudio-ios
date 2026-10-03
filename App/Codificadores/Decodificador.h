#ifndef ESTUDIO_DECODIFICADOR_H
#define ESTUDIO_DECODIFICADOR_H

#include <stdint.h>

// Ponte para o FFmpeg embutido (vendor-ff, compilado por scripts/compilar-ffmpeg.sh).
// O FFmpeg só lê e decodifica; quem grava é o AVFoundation.

/// Versão do FFmpeg que veio no app (ex.: "7.1.1").
const char *estudio_ffmpeg_versao(void);

/// 1 se o decodificador com esse nome existe (ex.: "vp9", "vp8", "av1", "opus").
int estudio_ffmpeg_decodifica(const char *nome);

// ---- leitor: abre qualquer arquivo e entrega vídeo (NV12 ou P010) e áudio (float intercalado)

typedef struct EstudioLeitor EstudioLeitor;

typedef struct {
    int largura, altura;        // já pares (o codificador do iPhone exige)
    double fps;                 // média; 0 = desconhecida
    double duracao;             // segundos; 0 = desconhecida
    int64_t taxaVideo;          // bits/s; 0 = desconhecida
    int dezBits;                // 1 = a fonte tem mais de 8 bits por canal
    int rotacao;                // graus no sentido horário para exibir (0, 90, 180, 270)
    int primarias, transferencia, matriz;   // códigos H.273 (1 = BT.709, 9 = BT.2020, 16 = PQ, 18 = HLG…); 2 = não informado
    int temVideo, temAudio;
    int taxaAudio;              // Hz
    int canais;                 // 1 ou 2 (mais que isso é reduzido para estéreo)
    int64_t taxaBitsAudio;      // bits/s do áudio original; 0 = desconhecida
    char codecVideo[32];
    char codecAudio[32];
} EstudioInfo;

typedef struct {
    int tipo;                   // 1 = vídeo, 2 = áudio
    double tempo;               // segundos desde o começo do arquivo
    int amostras;               // áudio: quantas amostras (por canal) estão prontas
} EstudioQuadro;

/// Abre o arquivo. NULL se não der; `erro` recebe o motivo.
EstudioLeitor *estudio_abrir(const char *caminho, EstudioInfo *info, char *erro, int tamErro);

/// Decodifica o próximo quadro de vídeo ou bloco de áudio. 1 = entregou, 0 = acabou, <0 = erro.
int estudio_proximo(EstudioLeitor *l, EstudioQuadro *q);

/// Copia o quadro de vídeo atual para os dois planos do destino (Y e CbCr intercalado).
/// dezBits = 0: NV12 (8 bits). dezBits = 1: P010 (10 bits em palavras de 16). 0 = ok.
int estudio_copiar_video(EstudioLeitor *l, uint8_t *y, int passoY, uint8_t *cbcr, int passoCbCr, int dezBits);

/// Copia o bloco de áudio atual (float de 32 bits, canais intercalados). Devolve as amostras copiadas.
int estudio_copiar_audio(EstudioLeitor *l, float *destino, int maxAmostras);

void estudio_fechar(EstudioLeitor *l);

#endif
