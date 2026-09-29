# Estúdio (iPhone)

App de iPhone que junta o whisper.frx9.com e o ConversorMidia: baixar links (YouTube, Instagram…),
transcrever (texto `.txt` + legenda `.srt`) e tratar voz. Liquid Glass, tema escuro, iOS 26+.

## O que roda onde (versão 0.3)

| Função | No iPhone | Na nuvem |
|---|---|---|
| Baixar vídeo/áudio de link | — | ✅ (yt-dlp no servidor; o arquivo vem para o iPhone) |
| Transcrever arquivo ou link | ✅ WhisperKit (large-v3-turbo, Neural Engine) | ✅ "Processar na nuvem" |
| Tratar voz | (próxima versão) | ✅ modos fala / só voz / música |
| Converter vídeo (presets do ConversorMidia + os seus, HDR, resolução 1080p/personalizada, qualidade/Mb/s/tamanho, velocidade com o som no mesmo tom, corte) | ✅ chip de vídeo (HEVC/H.264) | (AV1: futuro, pela nuvem) |
| Extrair/converter áudio: M4A, WAV, MP3, OGG | ✅ (MP3 = LAME, OGG = Vorbis, compilados no app) | — |
| Converter imagem | (próxima versão) | — |

A "nuvem" é o whisper.frx9.com, com o mesmo usuário e senha do site — o app usa a mesma API,
nada muda no servidor. A senha fica no Keychain do iPhone para renovar a sessão sozinho.

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
