import Combine
import SwiftUI
import AVKit
import Photos

struct ResultadosView: View {
    @Environment(Estudio.self) private var estudio

    var body: some View {
        NavigationStack {
            Group {
                if estudio.historico.itens.isEmpty {
                    ContentUnavailableView("Nada por aqui ainda", systemImage: "tray",
                                           description: Text("Os resultados aparecem aqui e ficam também no app Arquivos, em “No meu iPhone › Estúdio”."))
                } else {
                    List {
                        ForEach(estudio.historico.itens) { item in
                            NavigationLink(value: item.id) { LinhaItem(item: item) }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                        .onDelete { idx in
                            let ids = idx.map { estudio.historico.itens[$0].id }
                            for id in ids {
                                estudio.cancelar(id)
                                estudio.historico.remover(id)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .telaEscura()
            .navigationTitle("Resultados")
            .navigationDestination(for: UUID.self) { id in DetalheView(id: id) }
        }
    }
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
                        }
                    }

                    if item.estado == .pronto, item.tipo == .imagem || item.tipo == .video {
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
                    if item.estado == .pronto, item.tipo == .imagem {
                        Cartao(titulo: item.arquivos.count == 1 ? "Imagem" : "\(item.arquivos.count) imagens", icone: "photo.on.rectangle") {
                            GradeImagens(item: item)
                        }
                    } else if item.estado == .pronto, item.tipo == .video {
                        Cartao(titulo: item.arquivos.count == 1 ? "Vídeo" : "\(item.arquivos.count) vídeos", icone: "film.stack") {
                            GradeVideos(item: item)
                        }
                    } else if item.estado == .pronto {
                        Cartao(titulo: "Arquivos", icone: "folder.fill") {
                            ForEach(item.arquivos, id: \.self) { nome in
                                LinhaArquivo(url: item.url(nome), aviso: $aviso)
                            }
                        }
                        if item.tipo == .transcricao, let t = texto {
                            Cartao(titulo: "Texto", icone: "text.quote") {
                                Button { UIPasteboard.general.string = t; aviso = "Texto copiado." } label: {
                                    Label("Copiar tudo", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.glass)
                                Text(t).font(.body).textSelection(.enabled)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        estudio.cancelar(id); estudio.historico.remover(id); voltar()
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
            .task(id: item.estado) {
                if item.tipo == .transcricao, item.estado == .pronto,
                   let txt = item.arquivos.first(where: { $0.hasSuffix(".txt") }) {
                    texto = try? String(contentsOf: item.url(txt), encoding: .utf8)
                }
            }
            .alert("Aviso", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(aviso ?? "") }
        } else {
            ContentUnavailableView("Item apagado", systemImage: "trash").telaEscura()
        }
    }

    private func salvarTodasNoFotos(_ item: Item) {
        let urls = item.arquivos.map { item.url($0) }
        let video = item.tipo == .video
        let (um, varios) = video ? ("Vídeo salvo no Fotos.", "vídeos salvos no Fotos.") : ("Imagem salva no Fotos.", "imagens salvas no Fotos.")
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in aviso = "Sem permissão para salvar no Fotos (Ajustes › Privacidade › Fotos)." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for u in urls {
                    if video { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: u) }
                    else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u) }
                }
            }) { ok, erro in
                Task { @MainActor in
                    aviso = ok ? (urls.count == 1 ? um : "\(urls.count) " + varios)
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
    private var ehFoto: Bool { ["jpg", "jpeg", "png", "heic", "webp", "avif", "tif", "tiff"].contains(ext) }
    @State private var miniatura: UIImage?

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
                    Text(url.lastPathComponent).font(.subheadline).lineLimit(2)
                    if let t = tamanho { Text(t).font(.caption).foregroundStyle(Tema.texto2) }
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
