# Estúdio (iPhone)

App de iPhone que junta o whisper.frx9.com e o ConversorMidia: baixar links (YouTube, Instagram…),
transcrever (texto `.txt` + legenda `.srt`) e tratar voz. Liquid Glass, tema escuro, iOS 26+.

## O que roda onde (versão 0.11)

| Função | No iPhone | Na nuvem |
|---|---|---|
| Baixar vídeo/áudio de link | — | ✅ (yt-dlp no servidor; o arquivo vem para o iPhone) |
| Transcrever arquivo ou link | ✅ WhisperKit (large-v3-turbo, Neural Engine) | ✅ "Processar na nuvem" |
| Tratar voz (fala / só voz / música, eco, clareza, voz à frente, destino Quadra) | ✅ o mesmo motor da nuvem, portado para C; modelos baixados na 1ª vez de `cdn.frx9.com/modelos` | ✅ (Quadra: ainda não) |
| Converter vídeo (presets do ConversorMidia + os seus, HDR, resolução 1080p/personalizada, qualidade/Mb/s/tamanho, velocidade com o som no mesmo tom, corte) | ✅ chip de vídeo (HEVC/H.264) | (AV1: futuro, pela nuvem) |
| Extrair/converter áudio: M4A, WAV, MP3, OGG | ✅ (MP3 = LAME, OGG = Vorbis, compilados no app) | — |
| Converter imagem (WebP, JPG, HEIC, PNG, AVIF se o iOS tiver; tamanho, recorte, metadados, alvo em KB, nomes) | ✅ ImageIO + libwebp 1.5.0 (compilada no app) | — |
| Google Drive: navegar, prévia, baixar (links públicos e, com login, o que foi compartilhado com você) | ✅ direto do Google para o iPhone | — |

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

## Lote de vídeos (0.9)

- Vários áudios/vídeos (Arquivos, Galeria até 20, Compartilhar até 20) abrem `PainelLoteVideos`
  (`App/Telas/LoteView.swift`): ajustes do lote (o mesmo `PainelConverter`, modo `.lote`, sem trecho),
  lista dos vídeos (tocar abre o conversor daquele vídeo, modo `.video`, com trecho; "Aplicar a todos";
  "Voltar aos ajustes do lote") e um nome de saída para todos.
- O enquadramento do lote é desenhado sobre o 1º vídeo e adaptado a cada um (`Enquadramento.adaptado`):
  "preencher" mantém a proporção, o centro e o tamanho relativo.
- Um trabalho só (`Estudio.converterLote` / `executarLote`), um vídeo por vez, galeria no resultado,
  informações × original por arquivo (`Item.origensMidia`). Fora da tela: espera voltar e refaz o vídeo
  em andamento. App fechado: "Continuar" pula os prontos.

## Google Drive (0.10)

- Cole um link do Drive (pasta ou arquivo) em Novo: abre um navegador dentro do app, sem passar pela nuvem.
- Grade (estilo galeria) ou lista (estilo Arquivos), filtro Tudo/Vídeos/Fotos, subpastas, prévia em tela cheia
  (foto grande; vídeo tocando direto do Drive) com informações.
- Selecionar → baixar só os escolhidos; "Baixar tudo"; "⋯ › Baixar tudo, com as subpastas".
- "E converter": depois de baixar, abre o conversor com os vídeos/fotos (lote).
- O download vira um item "Google Drive" em Resultados: galeria de vídeos e imagens, outros arquivos,
  Converter, Salvar no Fotos, Compartilhar/Salvar em Arquivos. Segue fora da tela; "Continuar" pula os já baixados.
- Docs/Planilhas/Apresentações do Google baixam como PDF.
- 0.10.1: prévia com botão (i) em cima para ocultar a caixa de informações; botões empilhados.
  Pastas/arquivos abertos por link ficam em Resultados ("Pasta do Drive", `Item.pastaDrive`); tocar abre
  a pasta direto (lista atualizada na hora). Abrir o mesmo link de novo só sobe o item para o topo.
- Sem login, usa a chave de API do Google (Ajustes › Drive: chave de API), guardada no Keychain: só links
  públicos ("qualquer pessoa com o link"). Com login (0.11, abaixo), abre também o que foi compartilhado com você.

## Conta Google (0.11)

- `App/Motor/ContaGoogle.swift`: login OAuth com PKCE (cliente do tipo iOS, sem segredo), pela tela do
  Google (`ASWebAuthenticationSession`, retorno `com.googleusercontent.apps.<id>:/oauth2redirect`).
  Escopo `openid email drive.readonly`. ID do cliente, refresh token e e-mail no Keychain
  (`com.gtm.estudio.google`); token de acesso só na memória, renovado sozinho.
- Com login, `Drive.pedido` usa `Authorization: Bearer`; sem login, a chave de API. Logado e a conta não
  enxerga um link público de outra pessoa: tenta com a chave e marca o item `publico` (downloads e
  subpastas seguem pela chave).
- Lugares da conta (pastas "de mentira"): `@meu` (Meu Drive), `@compartilhados` (sharedWithMe, mais
  recentes primeiro), `@drives` (drives compartilhados). Cartão "Google Drive" em Novo quando logado.
  Neles não há "Baixar tudo", só a seleção.
- Miniaturas de arquivos privados: `ImagensDrive` pede o thumbnailLink com o token.
- No Google Cloud: tela de consentimento "Externo", publicada "Em produção" (sem verificação; em "Teste" o
  login expira a cada 7 dias). Publicar exige página inicial e política de privacidade: estão em `site-google/`
  e no ar em https://estudio.frx9.com/ (GT-SRV `~/sites-frx9/sites/estudio/`). Não apagar.

## Legendas e "Editar novamente" (0.12)

- **Legendar** (Novo › arquivo de vídeo › Legendar): transcreve no iPhone com o tempo de cada palavra e cria um item
  "Legenda" em Resultados (.srt + .txt). O vídeo e o projeto ficam em `Application Support/Originais/<id>/`
  (`legenda.json`), enquanto o item existir. "Abrir o editor de legenda" no item.
- Modelo (`App/Motor/LegendaProjeto.swift`): lista única de palavras com tempo; os blocos são marcas nas palavras
  (`fimDeBloco`), então reagrupar (por frase / N palavras), dividir, juntar e corrigir texto não perdem tempos.
- Desenho (`App/Motor/LegendaDesenho.swift`): `DesenhoLegenda.desenhar` é a MESMA função na prévia do editor e no
  vídeo final (medidas em fração do vídeo). Contorno com cantos redondos, sombra, caixa de fundo num caminho só
  (linhas encostadas não escurecem em dobro), destaque da palavra falada, espaçamento entre linhas, letras e palavras.
- Editor (`App/Telas/LegendaView.swift`): abas Blocos, Estilo, Posição; estilos prontos (Clássica, Viral, Caixa,
  Amarela); exportar = uma conversão comum com `OpcoesConversao.legenda` (o Core Image põe a legenda sobre cada
  quadro; `PintorLegenda` guarda as últimas imagens). Com legenda, o enquadramento passa pelo Core Image (Lanczos ao reduzir).
- **Editar novamente**: toda conversão pronta (um vídeo ou lote) guarda os ajustes em `Item.reedicao` e DE ONDE veio
  cada arquivo (`Procedencia`, em `Retomada.procedencias`): galeria (identificador do vídeo; pede leitura do Fotos na
  hora), app Arquivos (marcador/bookmark) ou um arquivo de Resultados (ex.: baixado do Drive). O botão busca o original
  de novo (`Estudio.garantirOriginais`) e abre o conversor com os mesmos ajustes (`Estudio.ajustesGuardados`).
  Só o que chega pelo Compartilhar (ou "Abrir com") não tem referência: aí fica uma cópia em
  `Application Support/Originais/<id>/`, pelo prazo de Ajustes › Editar novamente (7 dias, 30 dias ou indefinido;
  botão Apagar: manter 7 dias / 30 dias / tudo). Original apagado ou movido: o botão explica em vez de falhar.
  A legenda deixa o vídeo à mão na mesma pasta (o editor usa) e o busca de novo se ele sair de lá.
- 0.12.1: blocos por frase falada. O começo de cada trecho do transcritor fica marcado na palavra (`abreTrecho`;
  projeto antigo usa a maiúscula) e um bloco nunca mistura o fim de uma frase com o começo da outra (vídeo editado,
  sem pausas, não tem outra pista). Frase que não cabe (36 letras × linhas) é repartida em pedaços parecidos, de
  preferência depois de vírgula. `TranscritorLocal.semInvencoes` tira o que o Whisper inventa no silêncio do fim
  (trecho que começa depois do fim do arquivo, ou em outro alfabeto quando o idioma é português).
- 0.13.0: **Edições legendadas.** Gravar a legenda não cria mais um item novo: o vídeo entra em `Item.edicoes`
  (`EdicaoLegenda`), dentro do item da legenda, mais novo primeiro; o projeto usado fica em
  `Originais/<id>/edicao-<uuid>.json`. Na lista: tocar = prévia, canetinha = editor com aquela versão, compartilhar,
  arrastar para a esquerda = excluir (`Deslizavel`). Enquanto grava, o item mostra o progresso; falha ou cancelamento
  devolvem o item ao normal (`Estudio.exportarLegenda`). Ao terminar a transcrição, o editor abre sozinho
  (`Estudio.abrirLegenda`).
- 0.13.0: estilos salvos (`EstilosSalvos`, UserDefaults), fontes importadas (`Fontes`, em Application Support/Fontes,
  registradas com CoreText), tempo de cada palavra no editor de bloco (`moverPalavra`).
- 0.13.0: GIF e WebP animado escolhem os quadros na grade de saída (como o vídeo desde a 0.11.1), sem espaçamento irregular.
- Fora desta versão: animações da legenda (entrada com pulo/zoom).

## Correções (0.11.1)

- 0.11.1: **vídeo saía a 20 fps em vez de 30.** Causa: a composição usava uma grade fixa (instantes n/30) e vídeos
  com tempo em microssegundos (CapCut/ffmpeg: quadros em 0,033333 · 0,066667 · 0,100000 s) têm 1 quadro a cada 3
  um fio depois do instante da grade; ele nunca era mostrado. Agora a composição entrega todos os quadros da fonte
  (`sourceTrackIDForFrameTiming`, com grade de reserva de 2× o fps da fonte) e o `Bombeador.Grade` põe cada um no
  instante de saída (fps constante de verdade: descarta o que sobra, repete o que falta). Conferido por simulação
  com os tempos reais de `Video VRR Original/` (1980 quadros → 1980, antes 1320).
- 0.11.1: em vídeo de fps variável, `InfoMidia.fps` é a taxa de pico (`fpsReal`) e `fpsMedio` a média.
- 0.11.1: todo trabalho novo faz a aba Resultados voltar para a lista (`Estudio.trabalhosCriados`).

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
- `App/` — app: `Motor/` (nuvem, transcrição local, voz, conversores, Drive, conta Google, histórico), `Telas/` (SwiftUI).
- `site-google/` — página inicial e política de privacidade exigidas pelo Google (publicadas em estudio.frx9.com).
- `Compartilhar/` — extensão de compartilhar: guarda o link/arquivo numa caixa do grupo de apps e abre o app.
- `Compartilhado/` — caixa de entrada usada pelos dois.
- `.github/workflows/build-ipa.yml` — compila e gera o IPA com assinatura provisória (a AltStore reassina).

Legenda: mesmas regras do site (até 90 caracteres e 7 s por bloco, quebra em pausa > 0,8 s e em
fim de frase), e a mesma proteção contra loop de alucinação (12 trechos iguais seguidos).
