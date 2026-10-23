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
- 0.13.1: buracos na transcrição. Depois da 1ª passada, intervalos de 3 s ou mais sem texto e com som
  (`TranscritorLocal.buracos` / `temSom`, volume médio acima de −38 dB) são transcritos de novo só naquele pedaço
  (`clipTimestamps`, sem divisão por pausas) e encaixados. Vale para a legenda e para a transcrição comum.
- 0.13.3: o buraco de 0:15 a 0:32 só acontecia com o idioma em "Português" (com "Detectar" o mesmo vídeo saía
  inteiro, 3 vezes em 3). Duas diferenças entre os modos, as duas corrigidas, sem saber qual era a culpada:
  (1) com idioma fixo o WhisperKit começa cada janela pelo "prefill" → a 1ª passada agora é sempre no modo
  "detectar" (só repete com o idioma fixo se o modelo detectar outro idioma), e o conserto de buracos idem; (2) o filtro de "outro alfabeto" de `semInvencoes` só
  roda com idioma fixo → agora só descarta quando a maioria das letras é de outra escrita.
- 0.13.3: editor de legenda com Desfazer/Refazer (pilha de projetos, mudanças seguidas contam como uma) e
  "Novo bloco em <tempo>" (`ProjetoLegenda.inserirBloco`: texto à mão a partir de onde o vídeo está parado).
- 0.13.2: o conserto de buracos da 0.13.1 não pegava o caso real (`Video Legendado/`: fala contínua, texto some de
  0:15 a 0:32 no meio de uma frase). Agora: `arrumar` deixa cada trecho justo nas palavras dele e abre um trecho
  novo onde há 3 s ou mais entre palavras (o buraco pode estar DENTRO de um trecho do Whisper); o pedaço é cortado
  para um .wav próprio (`recortar`, até 26 s, corte em `pontoCalmo`) e transcrito sozinho, sem os filtros de
  "trecho duvidoso"; se ainda vier vazio, pede só o texto e o editor reparte o tempo pelas palavras.
- 0.13.1: todo "Apagar" pergunta antes (`Confirmacao` + `.confirmar` em Tema.swift). Linha deslizável das edições:
  o toque é da própria linha (não abre o vídeo no fim do arrasto) e saiu o menu de segurar. Pasta do Drive em
  Resultados: arrastar para a direita ou segurar → "Copiar link".
- 0.14.0: **animações da legenda** (Estilo › Animação). Entrada do bloco: Pulo, Zoom, Aparecer, Subir; "Pulo na
  palavra falada" (a palavra cresce 18% e volta em 0,14 s); "Revelar palavra por palavra". O cálculo é um só
  (`AnimacaoLegenda.estado`), usado na prévia do editor e no vídeo gravado. Campos novos do estilo são opcionais
  (`entrada`, `pulaPalavra`, `revela`), então projetos e estilos antigos abrem igual. Os estilos prontos não mudaram.
- 0.14.0: apagar uma fonte importada (Estilo › Texto, com confirmação). Desfazer/Refazer continua valendo depois de
  fechar o editor (`historico.json` na pasta do projeto, últimos 40 passos de cada lado).
- 0.15.0: **"Usar em nova tarefa"** no resultado pronto e no menu ⋯ da prévia de cada vídeo (`Estudio.usarEmNovaTarefa`):
  o arquivo do resultado entra como se fosse novo (converter, tratar voz, transcrever, legendar). "Editar novamente
  este vídeo" na prévia (`editarNovamente(_, so:)`, um vídeo só de um lote). "Compartilhar todos": os arquivos como
  estão ou dentro de um .zip feito pelo iPhone (`Zip` em Compartilhar.swift, sem biblioteca; também para 1 arquivo).
  "Salvar as N no Fotos" pergunta antes.
- 0.15.1: resultado pronto na ordem: resumo, galeria, "Salvar no Fotos", ações (Compartilhar todos, Editar novamente,
  Usar em nova tarefa), Apagar. Todo salvar no Fotos pergunta antes, inclusive de um arquivo só. Deslizar para apagar
  em Resultados: a linha sai de lado e o lugar fica vazio até a resposta (`saindo`; `Confirmacao.aoCancelar` devolve).
  Download do Drive guarda a pasta de origem (`Item.pastaDrive` também no tipo `.drive`) para "Copiar link".
  Ajustes › Armazenamento (`CartaoArmazenamento`, `Estudio.arquivosGuardados/limparResultados/apagarArquivoGuardado`).
  O .zip é apagado quando a folha de compartilhar fecha (`Zip.limpar`). Novo: Áudio/vídeo, Imagens, Link, Drive, Compartilhar.
- 0.16.0: vídeo que o iPhone não abre (VP9 do Instagram/YouTube: `Compatibilidade.problema`, por `isDecodable` e pelo
  código do formato). O resultado avisa, some com Salvar no Fotos / Editar novamente / Usar em nova tarefa e deixa
  Compartilhar e "Converter para o iPhone" (HEVC ou H.264). A conversão é na nuvem: `Estudio.converterParaIPhone`
  pede o mesmo link com `compat` (`/api/link/start`), a nuvem recodifica e o arquivo do resultado é trocado; se
  falhar, o original fica. Conversão local (decodificador embutido) fica para depois. "Copiar link" também nos
  resultados baixados por link (`Item.linkDeOrigem`).
- 0.17.0: **FFmpeg embutido (fundação).** `scripts/compilar-ffmpeg.sh` compila o FFmpeg 7.1.1 para arm64 em `vendor-ff/`
  (LGPL, só leitura e decodificação: sem codificadores, muxers, rede ou programas), com cache próprio no Actions.
  Ponte em `App/Codificadores/Decodificador.{h,c}`; Ajustes › Sobre mostra a versão e se há VP9/AV1. Ainda não muda
  nada no uso: a conversão local ("Converter para o iPhone" sem nuvem) vem na 0.17.1.
- 0.17.1: **"Converter para o iPhone" local.** `Decodificador.c` ganhou um leitor (`estudio_abrir/proximo/copiar_video/
  copiar_audio/fechar`): o FFmpeg abre e decodifica; o vídeo sai em NV12 (ou P010 se a fonte tem 10 bits) e o áudio em
  float intercalado. `ConversorCompat` grava com o AVAssetWriter em HEVC (padrão) ou H.264, taxa = 2× a original com
  piso pelo tamanho, cor e rotação preservadas. `Estudio.converterNoIPhone` troca os arquivos incompatíveis do resultado
  (qualquer origem); a nuvem continua como opção no menu para o que veio de link. Vídeo incompatível escolhido em Novo,
  Compartilhar ou "Abrir com" não vai mais ao conversor (falhava): é guardado em Resultados com o botão de converter.
  Testado fora do iPhone: a decodificação do `VideoBugado` (VP9, 14.576 quadros) saiu idêntica à do ffmpeg, vídeo e áudio.
- 0.17.2: conversão local com escolha de qualidade (`ConversorCompat.Qualidade`: taxa de 2×, 1,4× ou 1× a original; a 0.17.1
  usava sempre 2×, por isso o HEVC saía com o dobro do tamanho do VP9). Áudio a 1,5× a taxa original (64 a 192 kb/s) em
  vez de 192 kb/s fixos. Faixa de aviso do app: não diz mais "Convertendo imagens" durante a conversão de vídeo.
- 0.18.0: **posts do Instagram com fotos e carrosséis.** A nuvem identifica o post pelo gallery-dl (`kind: "post"` em
  `/api/link/probe`) e baixa tudo na ordem (`mode: "post"`, arquivos em `/api/post/<id>/<n>`). `Estudio.baixarPost` traz
  os arquivos numerados (`base-01.jpg`, `base-02.mp4`…); o resultado mostra fotos e vídeos em cartões separados e os
  vídeos incompatíveis usam o "Converter para o iPhone". Ajustes › Instagram (`InstagramView.swift`): login na página do
  Instagram dentro do app (WKWebView com sessão descartável) e envio só dos cookies à nuvem; a senha não passa pelo app.
- 0.18.1: resultado com fotos e vídeos juntos numa grade só, na ordem dos arquivos, com filtro Tudo / Fotos / Vídeos
  (`GradeMista.swift`).
- 0.18.2: a tela cheia do resultado misto é uma só (`VisualizadorVideos` passou a abrir imagem também: `ZoomImagem` e
  `PainelInfoImagem` na página de foto, salvar no Fotos conforme o tipo). Deslizar passa por fotos e vídeos na ordem.
- 0.18.3: Ajustes › Instagram mostra se a sessão ainda vale (a nuvem pergunta ao Instagram em `/api/instagram/status`,
  campo `valid`). Na nuvem, o yt-dlp passou a usar a conta conectada em links do Instagram (reels pedindo login) e
  Stories vão pelo gallery-dl.
- 0.18.4: **conversão que parava em 99%.** Quando o áudio acabava antes do vídeo, o gravador segurava os últimos
  quadros à espera de áudio; agora cada trilha é encerrada assim que entrega tudo (`ConversorCompat.executar`), com
  limite de 15 s parado e de 120 s para fechar o arquivo. **Ajustar para o iPhone (sem perda):** vídeo HEVC com etiqueta
  `hev1` (Android) tem a etiqueta trocada por `hvc1` numa cópia, sem regravar (`Etiqueta.swift`, `Estudio.ajustarEtiqueta`).
- 0.18.5: **teste do corte automático no iPhone** (Ajustes › Teste: corte automático). O CrisperWhisper turbo
  convertido para Core ML (workflow `converter-crisper.yml`, pasta `testes/crisper`) fica em
  "No meu iPhone › Estúdio › CrisperWhisper" junto com os .json do modelo. `App/Crisper/`: dicionário (BPE em
  bytes, conferido contra o oficial em 101 frases), decodificação token a token com a lista de suprimidos e a
  atenção das cabeças de alinhamento, o caminho longo oficial (janelas de 30 s a cada 26 s, 12 palavras de
  contexto, descarte das palavras que a próxima janela reouve, reparo de laços), tempos das palavras pelo
  método oficial (Viterbi com atenção + energia do mel; conferido contra o oficial) e a regra de corte
  aprovada ("8-normal-v3"). Grava em "CrisperWhisper-testes" o relatório, palavras.json e o áudio cortado.
  Ainda não portados: recomeço com temperatura para trechos vazios e recuperação de fim prematuro.
- 0.19.0: **editor de vídeo** (`EditorVideoView.swift`, motor em `Motor/Edicao.swift`). Abre por Resultados
  ("Abrir no editor" em vídeos), por Novo (depois de escolher um vídeo) e por vários vídeos ("Unir no editor").
  Prévia que toca a edição como vai ser gravada; linha do tempo com miniaturas e onda do som, cursor fixo no
  meio, pinça para aproximar; Dividir, Remover (sem "Tem certeza?": o Desfazer volta), alças para aparar,
  Velocidade 0,25×–4× por trecho (tom mantido), Áudio (volume por trecho ou em tudo, até 100%: o mixer do iOS
  não amplifica), Ordem (mover/duplicar), + Vídeo (galeria/Arquivos; o que o iPhone não abre é convertido na
  hora para HEVC na qualidade máxima), Desfazer/Refazer. O primeiro vídeo define formato, cor (HDR) e fps;
  os outros entram centrados com barras. Gravar: um vídeo (regravado pelo mesmo motor da conversão), cada
  trecho num arquivo, só o áudio (M4A) ou sem regravar (um trecho, sem velocidade/volume). O resultado guarda
  a edição: "Editar de novo" reabre com os vídeos guardados em Originais. As fontes entram no trabalho por
  ligação direta ao arquivo (sem ocupar espaço de novo).
- 0.22.3: conversão de vídeo incompatível (VP9 etc.) travava quando o áudio acaba antes do vídeo (ex.: vídeo do
  Instagram com 49 s de imagem e 35 s de som): o gravador esperava áudio para intercalar e o vídeo parava. Agora
  `ConversorCompat` completa com silêncio quando o vídeo fica preso esperando áudio; áudio que volte depois de um
  buraco e caia em cima do silêncio é descartado só naquele bloco.
- 0.22.2: o envio ao TestFlight foi recusado por 2 motivos, corrigidos: o `onnxruntime.framework` vem sem
  MinimumOSVersion (o workflow agora preenche no arquivo antes de exportar) e faltavam as 4 orientações para iPad
  (`UISupportedInterfaceOrientations~ipad`; no iPhone segue só em pé).
- 0.22.1: pronto para o TestFlight. Workflows novos (pasta PARA-A-PASTA-.github-workflows): `preparar-assinatura.yml`
  (uma vez: cria o certificado Apple Distribution pela API e devolve o p12 para o secret DIST_P12) e
  `testflight.yml` (compila, recria os perfis App Store pela API, assina e envia). `scripts/asc.py` fala com a API do
  App Store Connect (chave do secret ASC_KEY_P8). `project.yml`: perfis por alvo (`PERFIL_APP`/`PERFIL_EXT`, vazios
  no build do AltStore) e `ITSAppUsesNonExemptEncryption = false`. `App/PrivacyInfo.xcprivacy`: declara UserDefaults
  e datas de arquivo (a Apple recusa o envio sem isso). O `build-ipa.yml` do AltStore continua igual.
- 0.22.0: teste de clonagem de voz (Ajustes › "Teste: clonagem de voz"). Chatterbox v3 no iPhone: o T3 (Llama
  520M) em Core ML com o cache dentro do modelo (estado, float16, `App/Clonagem/MotorChatterbox.swift`), o
  decodificador da onnx-community no ONNX Runtime pela API C (`App/Clonagem/cb_ort.c`), tokenizador refeito em
  Swift (`TokenizadorChatterbox.swift`). O modelo vem de `cdn.frx9.com/modelos/chatterbox/` (gerado no GT-PC por
  `testes/clonagem-voz/rodar-iphone.sh`); o T3 chega como `.mlpackage` e o iPhone compila na 1ª vez. A voz
  (`voz-*.json`, também do rodar-iphone.sh) é importada no próprio teste e fica em "Estúdio › Chatterbox-vozes".
  "Conferir o modelo" compara o tokenizador e os primeiros tokens com o PyTorch. Resultados em
  "Estúdio › Clonagem-testes". `ModeloCrisper.baixar` ganhou `pular:` (não baixa de novo o pacote já compilado).
- 0.21.6: fila de trabalhos corrigida. (1) Sair do app só marca "Pausado" no que está rodando; quem espera a vez
  continua "Na fila" e, ao voltar, reescreve a posição (`repintarFila`). (2) Falha por sair do app só conta se foi
  DEPOIS de o trabalho pegar a vez (`geracaoDaVez`), não conta como tentativa (antes: 3 e erro). (3) Pedidos que
  chegam juntos não se sobrescrevem mais (`entradaConcluida`). (4) Imagens com fila própria (`filaLeve`, só
  processador) e Atividade ao Vivo só depois de pegar a vez; identificador novo a cada vez (registrar o mesmo de novo
  derrubava o app no "Continuar"). (5) "Preparar tudo" entra na fila; o editor só solta o modelo se chegou a usá-lo.
- 0.21.5: corte automático do editor entra na fila dos trabalhos pesados (`Estudio.aguardarVezDoEditor` /
  `liberarVezDoEditor`, a mesma `aguardarVez` dos trabalhos): não roda junto com tratar voz, transcrição etc.
  Enquanto espera, mostra a posição na fila. A tela fica acesa pelo `atualizarTela` (`editorNaVez`).
- 0.21.4: prévia dos cortes sem salto: com "Prévia já cortada", a prévia é montada com os cortes ativos já
  aplicados (`EditorVideoView.cortado`, a mesma conta do "Aplicar cortes") e o cursor converte entre a linha do
  tempo e o relógio da prévia (`removidos`, `previaDaLinha`, `linhaDaPrevia`). Marcar/desmarcar remonta a prévia.
- 0.21.3: o app fechava logo ao começar a alinhar (memória: o alinhador float32 na GPU copia 1,2 GB para a
  GPU). Alinhador agora no processador (`.cpuOnly`: pesos mapeados do arquivo); Diagnóstico registra a memória antes
  e depois. Editor: tela não apaga durante o corte automático; se o app sair da frente (GPU proibida em segundo plano),
  aviso claro em vez de "Unable to compute the prediction".
- 0.21.2: **conta do Reddit**. Desde 2025 o yt-dlp (old.reddit) pede conta e a página nova tem verificação
  anti-robô (8 KB sem o post). Ajustes › Reddit (mesmo cartão do Instagram, agora genérico: `SiteConta`,
  `CartaoConta`): login na página do Reddit dentro do app, "Concluir" manda só os cookies (exige `reddit_session`).
  Nuvem: `/api/reddit/status|cookies` (RD_COOKIES=/data/reddit-cookies.txt; validade pelo old.reddit.com/prefs), yt-dlp e
  gallery-dl usam os cookies do Reddit em links do Reddit, mensagens de erro próprias.
- 0.21.1: alinhador convertido em float16 dava -infinito/NaN (o log-softmax em float16). O modelo agora devolve o
  logit cru (`logits`) e o log-softmax é feito em float32 (no app e no `converter.py`). O workflow testa três
  variantes (float16, misto com normalizações em float32, float32) e escolhe a menor que bate com o PyTorch
  (média < 5 ms, máx < 60 ms nas fronteiras das palavras). Resultado: float16 e misto deram NaN (em ~1/3 das janelas); float32 escolhido (1,2 GB): 685 de 688 fronteiras idênticas ao PyTorch, média 0,1 ms. Se o alinhador falhar no iPhone, o corte segue com os
  tempos do CrisperWhisper (painel: "sem alinhador"; motivo no Diagnóstico).
- 0.21.0: **regra v4 + alinhador**. No vídeo de 13 min os cortes comiam palavras: os tempos do próprio
  CrisperWhisper "espremem" palavras em fala rápida ("algumas" com 0,08 s) e a regra antiga tratava o buraco como
  pausa. Regra v4 (`CorteAutomatico.cortes`): pausa só onde o áudio está quieto (≥ 0,30 s abaixo do piso + 10 dB;
  ficam 0,13 s antes e 0,03 s depois); "som", "palavra cortada" e "repetição" como antes, agora com o motivo.
  Alinhador (`App/Crisper/Alinhador.swift`): wav2vec2 large português (jonatasgrosman, o do WhisperX) em Core ML,
  janelas de 24 s (20 + 2 + 2), CTC Viterbi por grupos de ~20 s, cada grupo começa onde o anterior terminou;
  tempos guardados junto da transcrição (`alinhadas`, `Alinhador.versao`). Sem o alinhador no iPhone, usa os
  tempos do CrisperWhisper. Conversão: `testes/alinhador/converter.py` + workflow `converter-alinhador.yml`
  (artefato `alinhador-coreml` → "No meu iPhone › Estúdio › Alinhador"); `alinhar_ref.py` é o mesmo algoritmo em
  numpy. Download pelo app: `ModeloCrisper.baixar(de:para:)` genérico, cdn.frx9.com/modelos/alinhador/
  (`scripts/preparar-modelo-cdn.py`). Editor: a prévia pula as marcas vermelhas (chave "Prévia já cortada"),
  marcas mostram o motivo, painel diz se os tempos são do alinhador. Cada corte grava diagnóstico em
  CrisperWhisper-testes/<data> <nome>/ (palavras.json com os tempos dos dois, cortes.txt).
- 0.20.0: **corte automático** (CrisperWhisper 2.0 turbo na GPU, regra "8-normal-v3"). `App/Crisper/ServicoCorte.swift`:
  `ModeloCrisper` (modelo em Documents/CrisperWhisper; usa o que já estiver lá; se faltar, baixa de
  cdn.frx9.com/modelos/crisperwhisper/ pelo `manifesto.json`, partes de 19 MB, continua de onde parou, SHA-256 por
  arquivo, marca `.incompleto` enquanto baixa), `TranscricoesGuardadas` (Application Support/CorteAutomatico, chave =
  tamanho + 1º e último MB; refeita se `CrisperTranscritor.versao` mudar), `ServicoCorte.propor` (transcreve ou usa a
  guardada, aplica a regra e devolve o que fica e o que sai). Transcritor: recomeço com temperatura (0,4/0,6/0,8/1,0 ×
  3 sorteios, só quando a janela "desaba" e o modo intended confirma) e recuperação de fim precoce (P(fim) < 0,7 com
  ≥ 4 s de fala depois da última palavra, ou 2 s na última janela; aceita se terminar com P ≥ 0,9), como no pacote
  oficial; o decodificador ganhou temperatura com semente, fim proibido nos N primeiros tokens e P(fim).
  Editor: ferramenta "Corte auto" marca em vermelho o que sai (toque = manter, tracejado), "Aplicar cortes" divide e
  fecha os buracos dos cortes (espaços vazios que já existiam ficam), com Desfazer. Áudio sozinho: Processar › Cortar
  › "Cortar e gravar" (gera `-cortado.m4a` + `-cortes.txt`, trabalho `Retomada.Tipo.corte`) ou "Revisar no editor"
  (o editor aceita só áudio: grava só áudio, sem "+ Vídeo"). Vídeo: Processar › Cortar abre o editor já propondo.
  Ajustes: cartão "Corte automático" (baixar/pausar, apagar modelo, apagar transcrições guardadas); o cartão de teste saiu.
  `scripts/preparar-crisper-cdn.py` monta a pasta do cdn a partir da pasta do modelo.
- 0.19.3: **volume do editor com slider** (0% a 200%) na escala do ouvido: cada 10 dB soa como o dobro/metade,
  então 50% = -10 dB, 25% = -20 dB, 200% = +10 dB (`EscalaVolume`; `TrechoEdicao.volume` continua sendo ganho de
  amplitude, projetos antigos valem). Antes 25/50/75% eram de amplitude (-12/-6/-2,5 dB) e quase não mudavam
  nada. `ProcessadorGanho` aplica volume e, acima de 100%, um limitador (teto -0,3 dBFS, ataque imediato,
  soltura 80 ms) na gravação (amostras) e na prévia (MTAudioProcessingTap: o mixer não aceita volume > 1). A onda
  do trecho acompanha o volume (laranja onde o limitador age). Botão "Volume" abre o painel (Mudo, 100%, Usar em
  todos; gruda em 100%). Pegador de mover fica no meio da parte **visível** do trecho e anda junto ao arrastar.
  Ímã virou ícone de ferradura vazado (branco ligado; apagado e riscado desligado).
- 0.19.2: gestos do editor. Tocar num trecho seleciona (antes o "segurar" do mover e o menu de contexto
  engoliam o toque); a linha do tempo rola com o dedo em cima dos trechos; mover passou para o **pegador
  ciano** no topo do trecho selecionado (o menu de contexto saiu; Duplicar/Remover/etc. continuam na barra e
  em "Ordem"); trocar a seleção zera o estado de arrasto preso; tocar no pegador ou nas alças sem arrastar não
  tira a seleção.
- 0.19.1: editor com **linha do tempo livre**: cada trecho tem posição própria (`TrechoEdicao.posicao`; projetos
  da 0.19.0 abrem com os trechos em sequência). Aparar o começo come o vídeo pela esquerda e deixa espaço vazio;
  as alças estendem além do recorte até o começo/fim do vídeo original; Remover deixa o espaço; segurar e arrastar
  move o trecho entre os vizinhos; tocar num espaço oferece "Fechar espaço" (e Ordem › "Fechar todos os
  espaços"); velocidade e Duplicar empurram os seguintes só o necessário. **Ímã** (botão ao lado de
  Desfazer/Refazer): bordas grudam no recorte original (`corteInicio/corteFim`), nas bordas dos vizinhos, no
  cursor e no início, com vibração. Na gravação os espaços viram tela preta e silêncio (grade fixa de quadros
  quando há espaços). **Volume**: o AVAudioMix não era aplicado (nem na prévia nem na gravação); agora o trecho
  mudo nem leva o som, e o volume parcial é aplicado nas amostras na gravação (`GanhoAudio`, via
  `Bombeador.bombear(ajustes:)`) e por rampas na prévia. A prévia descarta montagens antigas que terminem depois.
- 0.14.0: o seletor de idioma ficou. Sem ele, um vídeo em outra língua seria tratado como português.

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
