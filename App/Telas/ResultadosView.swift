import Combine
import SwiftUI
import AVKit
import Photos

struct ResultadosView: View {
    @Environment(Estudio.self) private var estudio
    @State private var caminho = NavigationPath()
    @State private var confirmar: Confirmacao?
    /// Linhas que saíram de lado e esperam a resposta do "Apagar?": o lugar delas fica vazio.
    @State private var saindo: Set<UUID> = []

    var body: some View {
        NavigationStack(path: $caminho) {
            Group {
                if estudio.historico.itens.isEmpty {
                    ContentUnavailableView("Nada por aqui ainda", systemImage: "tray",
                                           description: Text("Os resultados aparecem aqui e ficam também no app Arquivos, em “No meu iPhone › Estúdio”."))
                } else {
                    List {
                        ForEach(estudio.historico.itens) { item in
                            NavigationLink(value: item.id) { LinhaItem(item: item) }
                                .offset(x: saindo.contains(item.id) ? -700 : 0)
                                .opacity(saindo.contains(item.id) ? 0 : 1)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    // sem "role: .destructive": a lista só fecha a linha quando o item sai de verdade
                                    Button { pedirApagar(item) } label: { Label("Apagar", systemImage: "trash") }
                                        .tint(.red)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .swipeActions(edge: .leading) {
                                    // pasta do Drive: arrastar para a direita copia o link
                                    if let l = item.linkDeOrigem {
                                        Button { copiarLink(l) } label: { Label("Copiar link", systemImage: "link") }
                                            .tint(Tema.acento)
                                    }
                                }
                                .contextMenu {
                                    if let l = item.linkDeOrigem {
                                        Button("Copiar link", systemImage: "link") { copiarLink(l) }
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .telaEscura()
            .navigationTitle("Resultados")
            .confirmar($confirmar)
            .navigationDestination(for: UUID.self) { id in
                if let it = estudio.historico.item(id), it.tipo == .pastaDrive, let p = it.pastaDrive {
                    // pasta do Drive guardada: abre direto; ao baixar, volta para a lista
                    PastaDrive(pasta: p, fechar: { caminho = NavigationPath() }).telaEscura()
                } else {
                    DetalheView(id: id)
                }
            }
            .onChange(of: estudio.trabalhosCriados) { caminho = NavigationPath() }
            .onChange(of: estudio.abrirLegenda) { _, novo in
                if let novo { caminho = NavigationPath([novo]) }       // abre o item; ele abre o editor
            }
            .navigationDestination(for: Drive.Item.self) { p in
                PastaDrive(pasta: p, fechar: { caminho = NavigationPath() }).telaEscura()
            }
        }
    }
}

extension ResultadosView {
    fileprivate func pedirApagar(_ item: Item) {
        let id = item.id
        withAnimation(.snappy) { _ = saindo.insert(id) }
        var c = Confirmacao(titulo: "Apagar “\(item.titulo)”?", mensagem: "Os arquivos dele saem do app. Isso não pode ser desfeito.") {
            estudio.cancelar(id)
            withAnimation(.snappy) { estudio.historico.remover(id) }      // a linha de baixo sobe
            saindo.remove(id)
        }
        c.aoCancelar = { withAnimation(.snappy) { _ = saindo.remove(id) } }   // volta para o lugar
        confirmar = c
    }

    fileprivate func copiarLink(_ l: String) {
        UIPasteboard.general.string = l
        estudio.aviso = "Link copiado."
    }
}

extension Item {
    /// De onde veio: a pasta do Drive ou o link (YouTube, Instagram…) que foi baixado.
    var linkDeOrigem: String? { pastaDrive?.linkWeb ?? pedidoLink?.info.link }
}

struct LinhaItem: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.icone)
                .font(.title3)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(Tema.acento.opacity(0.35)), in: .circle)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.titulo).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: item.naNuvem ? "cloud.fill" : "iphone")
                    Text(item.criado, format: .dateTime.day().month().hour().minute())
                }
                .font(.caption).foregroundStyle(Tema.texto2)
                switch item.estado {
                case .processando:
                    if let p = item.progresso {
                        ProgressView(value: p).tint(Tema.acento)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(Tema.acento)
                    }
                    Text(item.mensagem ?? "Processando").font(.caption).foregroundStyle(Tema.texto2)
                case .erro:
                    Label(item.mensagem ?? "Erro", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.yellow).lineLimit(3)
                case .pronto:
                    if let r = item.resumo, !r.isEmpty {
                        Text(r).font(.caption).foregroundStyle(Tema.texto2).lineLimit(2)
                    } else {
                        Text(item.arquivos.joined(separator: " · ")).font(.caption).foregroundStyle(Tema.texto2).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct DetalheView: View {
    @Environment(Estudio.self) private var estudio
    @Environment(\.dismiss) private var voltar
    let id: UUID
    @State private var texto: String?
    @State private var aviso: String?
    @State private var editor: EditorAberto?

    struct EditorAberto: Identifiable {
        let id = UUID()
        let edicao: UUID?            // nil = o projeto em andamento; senão, a versão de uma edição gravada
    }
    @State private var buscandoOriginal = false
    /// Formato do vídeo que o iPhone não abre (ex.: "VP9"); nil = abre normalmente.
    @State private var incompativel: String?
    @State private var confirmar: Confirmacao?

    var body: some View {
        if let item = estudio.historico.item(id) {
            ScrollView {
                VStack(spacing: 16) {
                    Cartao {
                        Text(item.titulo).font(.title3.weight(.semibold))
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.naNuvem ? "Processado na nuvem" : "Processado no iPhone",
                                  systemImage: item.naNuvem ? "cloud.fill" : "iphone")
                            if let a = formatarDuracao(item.duracaoAudio) { Label("Áudio de \(a)", systemImage: "clock") }
                            if let p = formatarDuracao(item.duracaoProcesso) { Label("Pronto em \(p)", systemImage: "bolt.fill") }
                        }
                        .font(.subheadline).foregroundStyle(Tema.texto2)
                        if item.estado == .processando {
                            if let p = item.progresso { ProgressView(value: p).tint(Tema.acento) }
                            else { ProgressView().progressViewStyle(.linear).tint(Tema.acento) }
                            Text(item.mensagem ?? "Processando").font(.subheadline)
                            if estudio.rodando(id) {
                                Button("Cancelar", role: .destructive) { estudio.cancelar(id) }.buttonStyle(.glass)
                            }
                        } else if item.estado == .erro {
                            Label(item.mensagem ?? "Erro", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            if item.retomada != nil, !estudio.rodando(id) {
                                Button { estudio.continuar(id) } label: {
                                    Label("Continuar", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                                }
                                .buttonStyle(.glassProminent)
                                Text("Continua de onde parou, com os mesmos ajustes.")
                                    .font(.caption).foregroundStyle(Tema.texto2)
                            } else if item.pedidoLink != nil, !estudio.rodando(id) {
                                Button { estudio.tentarDeNovo(id); voltar() } label: {
                                    Label("Tentar de novo", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).padding(.vertical, 4)
                                }
                                .buttonStyle(.glassProminent)
                                Text("Pede o mesmo link de novo, com as mesmas opções.")
                                    .font(.caption).foregroundStyle(Tema.texto2)
                            }
                        }
                    }

                    if item.estado == .pronto, item.tipo == .drive {
                        PainelResultadoDrive(item: item, aviso: $aviso, salvarNoFotos: salvarTodasNoFotos)
                    }
                    if item.estado == .pronto, item.tipo == .legenda {
                        PainelLegendaResultado(item: item, abrirEditor: { editor = EditorAberto(edicao: $0) })
                    }
                    if item.estado == .pronto, let formato = incompativel {
                        Cartao {
                            Label("O iPhone não abre este vídeo (formato \(formato)).", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                            Text("Dá para compartilhar o arquivo como está, ou converter para um formato que o iPhone abre. A conversão troca este arquivo e perde um pouco de qualidade. Deixe o Estúdio aberto enquanto ela roda.")
                                .font(.footnote).foregroundStyle(Tema.texto2)
                            Menu {
                                Button("HEVC (recomendado)") { pedirConversao(.hevc, "HEVC") }
                                Button("H.264 (mais compatível, arquivo maior)") { pedirConversao(.h264, "H.264") }
                                if item.pedidoLink != nil {
                                    Divider()
                                    Button("Pela nuvem, em HEVC") { pedirConversaoNaNuvem() }
                                }
                            } label: {
                                Label("Converter para o iPhone", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                    if item.estado == .pronto, item.tipo == .imagem {
                        Cartao(titulo: item.arquivos.count == 1 ? "Imagem" : "\(item.arquivos.count) imagens", icone: "photo.on.rectangle") {
                            GradeImagens(item: item)
                        }
                    } else if item.estado == .pronto, item.tipo == .video {
                        Cartao(titulo: item.arquivos.count == 1 ? "Vídeo" : "\(item.arquivos.count) vídeos", icone: "film.stack") {
                            GradeVideos(item: item).id(item.estado)      // arquivo trocado (conversão): refaz as miniaturas
                        }
                    } else if item.estado == .pronto, item.tipo != .drive {
                        Cartao(titulo: "Arquivos", icone: "folder.fill") {
                            ForEach(item.arquivos, id: \.self) { nome in
                                LinhaArquivo(url: item.url(nome), aviso: $aviso)
                            }
                        }
                        if item.tipo == .transcricao, let t = texto {
                            Cartao(titulo: "Texto", icone: "text.quote") {
                                CaixaTexto(texto: t) { UIPasteboard.general.string = t; aviso = "Texto copiado." }
                            }
                        }
                    }
                    if item.estado == .pronto, incompativel == nil, item.tipo == .imagem || item.tipo == .video {
                        Cartao {
                            if let r = item.resumo, !r.isEmpty {
                                Label(r, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.yellow)
                            }
                            Button { salvarTodasNoFotos(item) } label: {
                                Label(item.arquivos.count == 1 ? "Salvar no Fotos" : "Salvar as \(item.arquivos.count) no Fotos",
                                      systemImage: "photo.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                    if item.estado == .pronto, item.tipo != .drive, item.tipo != .pastaDrive, !item.arquivos.isEmpty {
                        let todos = item.arquivos.map { item.url($0) }
                        let midias = todos.filter { ehMidia($0) }
                        Cartao {
                            MenuCompartilhar(urls: todos, nome: item.titulo,
                                             titulo: todos.count == 1 ? "Compartilhar" : "Compartilhar todos", aviso: $aviso)
                            if incompativel == nil, let r = item.reedicao, r.tipo != .legenda {
                                Button {
                                    buscandoOriginal = true
                                    Task {
                                        if let motivo = await estudio.editarNovamente(id) { aviso = motivo }
                                        buscandoOriginal = false
                                    }
                                } label: {
                                    Label(buscandoOriginal ? "Buscando o original…" : "Editar novamente", systemImage: "slider.horizontal.3")
                                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                                }
                                .buttonStyle(.glass)
                                .disabled(buscandoOriginal)
                            }
                            if !midias.isEmpty, incompativel == nil {
                                Button { estudio.usarEmNovaTarefa(midias) } label: {
                                    Label("Usar em nova tarefa", systemImage: "plus.rectangle.on.rectangle")
                                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                                }
                                .buttonStyle(.glass)
                            }
                            if let l = item.pedidoLink?.info.link {
                                Button {
                                    UIPasteboard.general.string = l
                                    aviso = "Link copiado."
                                } label: {
                                    Label("Copiar link de origem", systemImage: "link")
                                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        confirmar = Confirmacao(titulo: "Apagar este resultado?",
                                                mensagem: item.tipo == .legenda
                                                    ? "A legenda, o projeto e todas as edições legendadas saem do app. Isso não pode ser desfeito."
                                                    : "Os arquivos dele saem do app. Isso não pode ser desfeito.") {
                            estudio.cancelar(id); estudio.historico.remover(id); voltar()
                        }
                    } label: {
                        Label("Apagar", systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                }
                .padding()
            }
            .telaEscura()
            .navigationTitle(tituloTipo(item.tipo))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: item.estado.rawValue + "|" + item.arquivos.joined(separator: "|")) {
                var achado: String?
                if item.estado == .pronto {
                    for n in item.arquivos {
                        if let f = await Compatibilidade.problema(item.url(n)) { achado = f; break }
                    }
                }
                incompativel = achado
            }
            .task(id: item.estado) {
                if item.tipo == .transcricao, item.estado == .pronto,
                   let txt = item.arquivos.first(where: { $0.hasSuffix(".txt") }) {
                    texto = try? String(contentsOf: item.url(txt), encoding: .utf8)
                }
            }
            .alert("Aviso", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(aviso ?? "") }
            .confirmar($confirmar)
            .fullScreenCover(item: $editor) { e in EditorLegenda(id: id, edicao: e.edicao) }
            // legenda que acabou de ser transcrita: entra direto no editor
            .task { abrirSePedido() }
            .onChange(of: estudio.abrirLegenda) { abrirSePedido() }
        } else {
            ContentUnavailableView("Item apagado", systemImage: "trash").telaEscura()
        }
    }

    private func pedirConversao(_ codec: ConversorCompat.Codec, _ nome: String) {
        confirmar = Confirmacao(titulo: "Converter para \(nome)?",
                                mensagem: "A conversão roda no iPhone e o vídeo convertido entra no lugar deste. Se algo falhar, o original continua aqui.",
                                botao: "Converter", destrutivo: false) { estudio.converterNoIPhone(id, codec: codec) }
    }

    private func pedirConversaoNaNuvem() {
        confirmar = Confirmacao(titulo: "Converter pela nuvem?",
                                mensagem: "A nuvem baixa o link de novo, converte e entrega no lugar deste arquivo. Se algo falhar, o original continua aqui.",
                                botao: "Converter", destrutivo: false) { estudio.converterPelaNuvem(id, codec: "hevc") }
    }

    private func abrirSePedido() {
        guard estudio.abrirLegenda == id else { return }
        estudio.abrirLegenda = nil
        if editor == nil { editor = EditorAberto(edicao: nil) }
    }

    private func salvarTodasNoFotos(_ item: Item) {
        let urls = item.arquivos.map { item.url($0) }.filter { ehImagem($0) || ehVideoArquivo($0) }
        guard !urls.isEmpty else { return }
        confirmar = Confirmacao(titulo: urls.count == 1 ? "Salvar na galeria do iPhone?" : "Salvar \(urls.count) arquivos na galeria do iPhone?",
                                mensagem: urls.count == 1 ? "O arquivo entra no app Fotos." : "Eles entram no app Fotos, um por um.",
                                botao: "Salvar", destrutivo: false) { gravarNoFotos(urls) }
    }

    private func gravarNoFotos(_ urls: [URL]) {
        let videos = urls.filter(ehVideoArquivo).count
        let fotos = urls.count - videos
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in aviso = "Sem permissão para salvar no Fotos (Ajustes › Privacidade › Fotos)." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for u in urls {
                    if ehVideoArquivo(u) { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: u) }
                    else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u) }
                }
            }) { ok, erro in
                Task { @MainActor in
                    var partes: [String] = []
                    if fotos > 0 { partes.append(fotos == 1 ? "1 imagem" : "\(fotos) imagens") }
                    if videos > 0 { partes.append(videos == 1 ? "1 vídeo" : "\(videos) vídeos") }
                    aviso = ok ? partes.joined(separator: " e ") + " no Fotos."
                               : "Não consegui salvar: \(erro?.localizedDescription ?? "formato não aceito pelo Fotos")"
                }
            }
        }
    }

    private func tituloTipo(_ t: Item.Tipo) -> String {
        switch t {
        case .transcricao: return "Transcrição"
        case .voz: return "Voz tratada"
        case .video: return "Vídeo"
        case .audio: return "Áudio"
        case .imagem: return "Imagens"
        case .drive: return "Google Drive"
        case .pastaDrive: return "Pasta do Drive"
        case .legenda: return "Legenda"
        }
    }
}

/// Um arquivo do resultado: tocar, compartilhar e (vídeo) salvar no Fotos.
struct LinhaArquivo: View {
    let url: URL
    @Binding var aviso: String?
    @State private var player: AVPlayer?
    @State private var tocando = false
    @State private var video: AVPlayer?
    @State private var posicao: Double = 0
    @State private var duracao: Double = 0
    @State private var arrastando = false
    private let relogio = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var ext: String { url.pathExtension.lowercased() }
    private var ehVideo: Bool { ["mp4", "mov", "m4v", "webm", "mkv"].contains(ext) }
    private var ehAudio: Bool { ["mp3", "m4a", "wav", "aac", "flac"].contains(ext) }
    private var ehFoto: Bool { ["jpg", "jpeg", "png", "heic", "webp", "avif", "gif", "tif", "tiff"].contains(ext) }
    @State private var miniatura: UIImage?
    @State private var confirmar: Confirmacao?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if ehFoto, let m = miniatura {
                    Image(uiImage: m).resizable().scaledToFill().frame(width: 44, height: 44)
                        .clipShape(.rect(cornerRadius: 8))
                } else {
                    Image(systemName: ehVideo ? "film" : ehAudio ? "music.note" : ehFoto ? "photo" : "doc.text")
                        .foregroundStyle(Tema.acento)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.subheadline).lineLimit(2).truncationMode(.middle)
                    Text([ext.isEmpty ? nil : ext.uppercased(), tamanho].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.medium)).foregroundStyle(Tema.texto2)
                }
                Spacer()
                if ehAudio {
                    Button { alternarAudio() } label: {
                        Image(systemName: tocando ? "pause.fill" : "play.fill").frame(width: 22, height: 22)
                    }
                    .buttonStyle(.glass)
                }
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
            }
            if ehAudio, player != nil, duracao > 0 {
                VStack(spacing: 2) {
                    Slider(value: $posicao, in: 0...duracao, onEditingChanged: { editando in
                        arrastando = editando
                        if !editando { player?.seek(to: CMTime(seconds: posicao, preferredTimescale: 600),
                                                    toleranceBefore: .zero, toleranceAfter: .zero) }
                    })
                    .tint(Tema.acento)
                    HStack {
                        Text(Self.tempo(posicao)); Spacer(); Text("-" + Self.tempo(duracao - posicao))
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(Tema.texto2)
                }
            }
            if ehVideo {
                VideoPlayer(player: video)
                    .frame(height: 210)
                    .onAppear { if video == nil { video = AVPlayer(url: url) } }
                    .clipShape(.rect(cornerRadius: 16))
                Button { salvarNoFotos() } label: {
                    Label("Salvar no Fotos", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
        .confirmar($confirmar)
        .onDisappear { player?.pause(); video?.pause(); tocando = false }
        .task {
            if ehFoto, miniatura == nil, let cg = ConversorImagem.miniatura(url, lado: 160) { miniatura = UIImage(cgImage: cg) }
        }
        .onReceive(relogio) { _ in
            guard let p = player, !arrastando else { return }
            let t = p.currentTime().seconds
            if t.isFinite { posicao = min(max(0, t), duracao) }
            if tocando, duracao > 0, t >= duracao - 0.05 {       // chegou ao fim: volta ao começo
                tocando = false
                p.pause()
                p.seek(to: .zero); posicao = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.outroTocando)) { n in
            if (n.object as? URL) != url, tocando { player?.pause(); tocando = false }
        }
    }

    /// Avisa as outras linhas para pausarem: um áudio por vez.
    static let outroTocando = Notification.Name("EstudioOutroAudioTocando")

    private static func tempo(_ s: Double) -> String {
        let t = Int(max(0, s).rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var tamanho: String? {
        guard let b = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { return nil }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func alternarAudio() {
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            Task {
                if let d = (try? await item.asset.load(.duration))?.seconds, d.isFinite { duracao = d }
            }
        }
        if tocando {
            player?.pause()
        } else {
            NotificationCenter.default.post(name: Self.outroTocando, object: url)
            player?.play()
        }
        tocando.toggle()
    }

    private func salvarNoFotos() {
        confirmar = Confirmacao(titulo: "Salvar na galeria do iPhone?", mensagem: "O vídeo entra no app Fotos.",
                                botao: "Salvar", destrutivo: false) { gravarNoFotos() }
    }

    private func gravarNoFotos() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { s in
            guard s == .authorized || s == .limited else {
                Task { @MainActor in aviso = "Sem permissão para salvar no Fotos (Ajustes › Privacidade › Fotos)." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, erro in
                Task { @MainActor in
                    aviso = ok ? "Vídeo salvo no Fotos." : "Não consegui salvar: \(erro?.localizedDescription ?? "formato não aceito pelo Fotos")"
                }
            }
        }
    }
}


/// Texto da transcrição: caixa de altura limitada (rola por dentro), "Ver mais" abre inteira.
/// Dá para selecionar trechos (UITextView: o Text do SwiftUI só copia o bloco todo).
struct CaixaTexto: View {
    let texto: String
    var copiar: () -> Void
    @State private var expandido = false
    @State private var alturaTotal: CGFloat = 0
    private let alturaCaixa: CGFloat = 260

    var body: some View {
        TextoSelecionavel(texto: texto, expandido: expandido, alturaMax: alturaCaixa, alturaTotal: $alturaTotal)
            .padding(12)
            .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
        HStack(spacing: 10) {
            Button(action: copiar) { Label("Copiar tudo", systemImage: "doc.on.doc") }
                .buttonStyle(.glass)
            Spacer()
            if alturaTotal > alturaCaixa + 1 {
                Button { withAnimation(.snappy) { expandido.toggle() } } label: {
                    Label(expandido ? "Ver menos" : "Ver mais", systemImage: expandido ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.glass)
            }
        }
        Text("Toque e segure para selecionar um trecho.").font(.caption).foregroundStyle(Tema.texto2)
    }
}

struct TextoSelecionavel: UIViewRepresentable {
    let texto: String
    let expandido: Bool
    let alturaMax: CGFloat
    @Binding var alturaTotal: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.backgroundColor = .clear
        v.textColor = .label
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.dataDetectorTypes = []
        v.text = texto
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != texto { v.text = texto }
        v.isScrollEnabled = !expandido
        if !expandido { v.flashScrollIndicators() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? v.window?.bounds.width ?? 350
        let total = ceil(v.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height)
        if abs(total - alturaTotal) > 0.5 {
            DispatchQueue.main.async { alturaTotal = total }
        }
        return CGSize(width: w, height: expandido ? total : min(total, alturaMax))
    }
}
