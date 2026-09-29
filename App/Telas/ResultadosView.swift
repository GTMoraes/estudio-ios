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

                    if item.estado == .pronto {
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

    private func tituloTipo(_ t: Item.Tipo) -> String {
        switch t {
        case .transcricao: return "Transcrição"
        case .voz: return "Voz tratada"
        case .video: return "Vídeo"
        case .audio: return "Áudio"
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

    private var ext: String { url.pathExtension.lowercased() }
    private var ehVideo: Bool { ["mp4", "mov", "m4v", "webm", "mkv"].contains(ext) }
    private var ehAudio: Bool { ["mp3", "m4a", "wav", "aac", "flac"].contains(ext) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: ehVideo ? "film" : ehAudio ? "music.note" : "doc.text")
                    .foregroundStyle(Tema.acento)
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
    }

    private var tamanho: String? {
        guard let b = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { return nil }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func alternarAudio() {
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = AVPlayer(url: url)
        }
        if tocando { player?.pause() } else { player?.play() }
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
