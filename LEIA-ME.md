# Estúdio (iPhone)

App de iPhone que junta o whisper.frx9.com e o ConversorMidia: baixar links (YouTube, Instagram…),
transcrever (texto `.txt` + legenda `.srt`) e tratar voz. Liquid Glass, tema escuro, iOS 26+.

## O que roda onde (versão 0.8)

| Função | No iPhone | Na nuvem |
|---|---|---|
| Baixar vídeo/áudio de link | — | ✅ (yt-dlp no servidor; o arquivo vem para o iPhone) |
| Transcrever arquivo ou link | ✅ WhisperKit (large-v3-turbo, Neural Engine) | ✅ "Processar na nuvem" |
| Tratar voz (fala / só voz / música, eco, clareza, voz à frente, destino Quadra) | ✅ o mesmo motor da nuvem, portado para C; modelos baixados na 1ª vez de `cdn.frx9.com/modelos` | ✅ (Quadra: ainda não) |
| Converter vídeo (presets do ConversorMidia + os seus, HDR, resolução 1080p/personalizada, qualidade/Mb/s/tamanho, velocidade com o som no mesmo tom, corte) | ✅ chip de vídeo (HEVC/H.264) | (AV1: futuro, pela nuvem) |
| Extrair/converter áudio: M4A, WAV, MP3, OGG | ✅ (MP3 = LAME, OGG = Vorbis, compilados no app) | — |
| Converter imagem (WebP, JPG, HEIC, PNG, AVIF se o iOS tiver; tamanho, recorte, metadados, alvo em KB, nomes) | ✅ ImageIO + libwebp 1.5.0 (compilada no app) | — |

A "nuvem" é o whisper.frx9.com, com o mesmo usuário e senha do site — o app usa a mesma API,
nada muda no servidor. A senha fica no Keychain do iPhone para renovar a sessão sozinho.

## Tratar voz no iPhone

- Código: `App/MotorVoz` (C). `mv_modelos.c` = separação (MDX Kim_Vocal_2) e eco (VR 5.1);
  `mv_filtros.c` = os filtros do ffmpeg usados pelo motor (highpass, equalizer, acompressor,
  alimiter, ebur128), com a mesma aritmética; `mv_pipeline.c` = o `tratar` do `pipeline.py`
  (blocos com 10 s de contexto e emendas de 2 s, nivelamento a −16 LUFS, limitadores, mix, Quadra);
  `mv_ort.c` = ONNX Runtime pela API C (um modelo aberto por vez, sem o "arena" de memória).
- Conferido contra o motor Python (ffmpeg 6.1) no mesmo áudio: trilha e modo música ficam
  idênticos até ~130–140 dB; nos modos com clareza, ~88 dB — é o piso de arredondamento dos
  próprios filtros do ffmpeg (o ffmpeg dá a mesma diferença consigo mesmo quando a entrada muda
  na 7ª casa). Os filtros isolados batem com o ffmpeg em 147 dB ou bit a bit.
- Diferenças em relação à nuvem: blocos de 5 min (a nuvem usa 20 min; só muda onde ficam as
  emendas em áudios longos) e MP3 a 44,1 kHz (a nuvem reamostra para 48 kHz).
- Modelos (290 MB) em `Application Support/modelos-voz`, fora do backup. Ajustes → "Tratar voz
  no iPhone" mostra, baixa e apaga. Acelerador: GPU (padrão, Core ML nativo em float32,
  modelos em `cdn.frx9.com/modelos/coreml/`, conferidos contra o processador uma vez por
  versão do iOS) ou Processador (ONNX Runtime 1.19.2).
- No servidor: os dois `.onnx` ficam em `~/sites-frx9/cdn/modelos/` (permissão 644), servidos
  em `https://cdn.frx9.com/modelos/`.

## Converter imagem

- Código: `App/Motor/ConversorImagem.swift` (motor) e `App/Telas/ImagemView.swift` (tela e recorte).
- Entrada: Arquivos, Fotos (até 50 por vez, no formato original) ou Compartilhar.
- Redimensionar com Lanczos (vImage); cor convertida para sRGB; orientação aplicada.
- Metadados: só a data, tudo (com opção de tirar o GPS) ou nada.
- WebP pela libwebp 1.5.0 (`scripts/compilar-codificadores.sh`), com EXIF e perfil ICC.
- Alvo em KB: busca a maior qualidade (30–95) que cabe no tamanho, em até 7 tentativas.
- JPG/HEIC saem pelo codificador da Apple: não ficam idênticos aos do ConversorMidia no Windows.
- Data: manter a da foto ou gravar a data e hora da conversão (EXIF, TIFF; datas IPTC removidas).
- Resultado: grade de miniaturas; tocar abre em tela cheia (pinça/toque duplo para zoom) com as
  informações e a comparação com o original (formato, resolução, tamanho), guardadas no histórico.

## Resultado de vídeo

- Grade de miniaturas; tocar abre em tela cheia com player e informações comparadas com o
  original (formato, resolução, fps, taxa, tamanho, ambiente do HDR), guardadas no histórico.
- Data: manter a do vídeo original ou usar agora; aparelho (marca/modelo) sempre copiado;
  localização só se pedida.
- HDR do iPhone: a caixa `amve` (ambiente de visualização, luz em que foi gravado) é copiada
  do original para o codificador. Sem ela o iOS mostra o HLG com brilho diferente. O Dolby
  Vision (RPU) é refeito pelo codificador a partir dos quadros: valores próximos, não idênticos.

## Fora da tela e retomada (0.6)

- A GPU do iPhone não roda em segundo plano (no iOS 26 só o iPad tem). Por isso voz, vídeo e
  transcrição **pausam** quando o app sai da tela; uma notificação avisa para voltar. Enquanto
  algo roda no iPhone, uma faixa no topo pede para não trocar de app e a tela não apaga sozinha.
- Imagens e trabalhos na nuvem usam a tarefa contínua do iOS 26 (`App/Motor/SegundoPlano.swift`):
  seguem fora da tela, com o progresso na Atividade ao Vivo.
- A entrada de cada trabalho no iPhone fica em `Application Support/Trabalhos/<id>` até terminar.
  Se o app for fechado: ao abrir, "Continuar". Voz continua do último bloco de 5 min pronto
  (ponto de retomada em `mv_pipeline.c`, resultado idêntico bit a bit ao de uma execução sem
  parar — conferido); imagens pulam as prontas; vídeo e transcrição recomeçam.

## Deixar o app pronto (0.7)

Ajustes › "Deixar o app pronto" (`App/Motor/Preparar.swift`): lista o que o iPhone precisa
baixar/compilar (modelo de transcrição + compilação no Neural Engine; modelos de voz do
processador; modelos de voz da GPU + preparação na GPU), com o estado de cada um e botões para
preparar um ou todos. A compilação fica no cache do iOS e é refeita depois de instalar uma versão
nova do app ou atualizar o iOS (a chave é a pasta do app + a versão do iOS).

## Enquadramento, GIF e WebP animado (0.8)

- Conversor › Enquadramento (`App/Telas/EnquadramentoView.swift`): preencher (recorte no formato
  9:16, 4:5, 1:1, 4:3, 16:9, arrastável), caber (barras pretas), desfocado (fundo = o próprio vídeo
  ampliado e desfocado, via Core Image) e livre (qualquer retângulo). Fixo para o vídeo inteiro.
  Montagem em `ConversorVideo.composicao` (camada com transformação; Core Image só no desfocado).
- GIF (ImageIO) e WebP animado (WebPAnimEncoder da libwebpmux, `cod_webpanim_*` em Codificadores.c):
  `App/Motor/Animacao.swift`. Quadros SDR 8 bits da mesma composição (giro, enquadramento,
  velocidade, trecho), largura 320–800, 10–24 fps. Resultado vai para a galeria de imagens,
  que toca a animação.

## Nome de saída

Todos os trabalhos têm o cartão "Nome de saída" (`App/Telas/NomeSaidaView.swift`,
`App/Motor/NomeSaida.swift`). Tokens: `{nome}` `{data}` `{datahora}`; na conversão de vídeo
também `{largura}` `{altura}` (do resultado); nas imagens também `{n}`. Em áudio/vídeo, `{data}`
é a data de gravação do arquivo; em links, agora. O padrão fica guardado por tipo de trabalho.
Na voz, os sufixos (`-mix-tratado`, `-voz-tratada`, `-trilha-separada`) continuam depois do nome.

## Como gerar o IPA (sem Mac)

1. Crie um repositório **privado** no GitHub (ex.: `estudio-ios`) e suba o conteúdo desta pasta
   (inclusive a pasta oculta `.github`).
2. A aba **Actions** roda o "Gerar IPA" a cada envio (~10–15 min; a 1ª vez baixa o WhisperKit e compila o LAME e o Vorbis, depois fica em cache).
3. Ao terminar, baixe o artefato **Estudio-ipa** (é um .zip com o `Estudio.ipa` dentro).
4. Se falhar, baixe o artefato **xcodebuild-log** e me mande — ou copie as linhas `error:` do passo
   "Resumo dos erros".

Repositório privado gasta minutos de macOS do plano gratuito (cada minuto de Mac conta como 10).

## Como instalar

1. Na AltStore: **My Apps**, segure o Ventilador → **Deactivate** (libera a vaga na hora; os dados
   ficam guardados pela AltStore).
2. Abra o `Estudio.ipa` no iPhone (Arquivos → Compartilhar → AltStore) e instale.
   Ele usa 2 App IDs (app + extensão de compartilhar).
3. Abra o Estúdio → **Ajustes** → entre com o usuário do site.
4. Para aparecer no Compartilhar: em qualquer app, Compartilhar → role os ícones até **Mais** →
   ative o **Estúdio** (e arraste para o começo, se quiser).

## Testando pelo LiveContainer (antes de ocupar a vaga)

Dá para usar o mesmo `Estudio.ipa`. Funciona igual: transcrição no iPhone, nuvem, links, tratar voz,
resultados. Não funciona lá dentro:

- aparecer no **Compartilhar** (o LiveContainer não registra extensões);
- **"Abrir com"** a partir do app Arquivos;
- os resultados não aparecem em “No meu iPhone › Estúdio” no app Arquivos (ficam dentro do LiveContainer).

Ao passar para a instalação pela AltStore, o que ficou no LiveContainer não migra: é preciso entrar de
novo na nuvem e baixar o modelo de transcrição outra vez (~630 MB).

## Estrutura

- `project.yml` — projeto (XcodeGen); o `.xcodeproj` é gerado no GitHub Actions.
- `App/` — app: `Motor/` (nuvem, transcrição local, legenda, histórico), `Telas/` (SwiftUI).
- `Compartilhar/` — extensão de compartilhar: guarda o link/arquivo numa caixa do grupo de apps e abre o app.
- `Compartilhado/` — caixa de entrada usada pelos dois.
- `.github/workflows/build-ipa.yml` — compila e gera o IPA com assinatura provisória (a AltStore reassina).

Legenda: mesmas regras do site (até 90 caracteres e 7 s por bloco, quebra em pausa > 0,8 s e em
fim de frase), e a mesma proteção contra loop de alucinação (12 trechos iguais seguidos).
