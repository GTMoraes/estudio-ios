import SwiftUI
import AVKit
import Photos

// MARK: - grade de miniaturas (resultado de vídeo)

struct GradeVideos: View {
    let item: Item
    @State private var aberto: Aberto?
    struct Aberto: Identifiable { let id: Int }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
            ForEach(Array(item.arquivos.enumerated()), id: \.offset) { k, nome in
                Button { aberto = Aberto(id: k) } label: { MiniaturaVideo(url: item.url(nome)) }
                    .buttonStyle(.plain)
            }
        }
        Text("Toque no vídeo para ver em tela cheia, com as informações.")
            .font(.footnote).foregroundStyle(Tema.texto2)
            .fullScreenCover(item: $aberto) { a in
                VisualizadorVideos(item: item, inicio: a.id)
            }
    }
}

struct MiniaturaVideo: View {
    let url: URL
    @State private var imagem: UIImage?
    @State private var duracao: Double?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let imagem {
                    Image(uiImage: imagem).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let d = formatarDuracao(duracao) {
                    Text(d).font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: .capsule)
                        .padding(5)
                }
            }
            .overlay(alignment: .center) {
                if imagem != nil { Image(systemName: "play.fill").font(.title3).foregroundStyle(.white.opacity(0.85)) }
            }
            .clipShape(.rect(cornerRadius: 10))
            .contentShape(.rect)
            .task {
                let asset = AVURLAsset(url: url)
                duracao = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }
                let g = AVAssetImageGenerator(asset: asset)
                g.appliesPreferredTrackTransform = true
                g.maximumSize = CGSize(width: 320, height: 320)
                if let r = try? await g.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)) {
                    imagem = UIImage(cgImage: r.image)
                }
            }
    }
}

// MARK: - tela cheia

struct VisualizadorVideos: View {
    let item: Item
    @State private var atual: Int
    @State private var mostrarInfo = true
    @State private var aviso: String?
    @State private var confirmar: Confirmacao?
    @State private var ocupado = false
    @State private var zipado: ArquivoPronto?
    @Environment(\.dismiss) private var fechar
    @Environment(Estudio.self) private var estudio

    /// Qual entrada do trabalho gerou o vídeo à vista (para "Editar novamente este vídeo").
    private var indiceEdicao: Int? {
        guard let r = item.reedicao, r.tipo != .legenda, !item.arquivos.isEmpty else { return nil }
        let nome = item.arquivos[min(atual, item.arquivos.count - 1)]
        if r.tipo == .loteConversao {
            guard let k = (r.saidas ?? []).firstIndex(where: { $0 == nome }), k < r.entradas.count else { return nil }
            return k
        }
        return r.entradas.isEmpty ? nil : 0
    }

    private func editarEste(_ k: Int) {
        ocupado = true
        Task {
            if let motivo = await estudio.editarNovamente(item.id, so: k, espera: 0.6) { aviso = motivo; ocupado = false }
            else { fechar() }
        }
    }

    private func compactar() {
        let u = urlAtual
        ocupado = true
        Task {
            do { let z = try await Zip.criar([u], nome: u.deletingPathExtension().lastPathComponent); zipado = ArquivoPronto(url: z) }
            catch { aviso = "Não consegui criar o .zip: \(error.localizedDescription)" }
            ocupado = false
        }
    }

    init(item: Item, inicio: Int) {
        self.item = item
        _atual = State(initialValue: inicio)
    }

    private var urlAtual: URL { item.url(item.arquivos[min(atual, item.arquivos.count - 1)]) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $atual) {
                    ForEach(Array(item.arquivos.enumerated()), id: \.offset) { k, nome in
                        PaginaVideo(url: item.url(nome), ativo: atual == k).tag(k)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                if mostrarInfo, !item.arquivos.isEmpty {
                    let nome = item.arquivos[min(atual, item.arquivos.count - 1)]
                    PainelInfoVideo(url: item.url(nome), origem: item.origensMidia?[nome] ?? item.origemMidia)
                        .id(nome)
                        .frame(maxHeight: 340)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(item.arquivos.count > 1 ? "\(atual + 1) de \(item.arquivos.count)" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar", systemImage: "xmark") { fechar() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    ShareLink(item: urlAtual) { Image(systemName: "square.and.arrow.up") }
                    Spacer()
                    Button { withAnimation(.snappy) { mostrarInfo.toggle() } } label: {
                        Image(systemName: mostrarInfo ? "info.circle.fill" : "info.circle")
                    }
                    Spacer()
                    Button { salvarNoFotos(urlAtual) } label: { Image(systemName: "photo.badge.plus") }
                    Spacer()
                    Menu {
                        if let k = indiceEdicao {
                            Button { editarEste(k) } label: { Label("Editar novamente este vídeo", systemImage: "slider.horizontal.3") }
                        }
                        Button {
                            let u = urlAtual
                            fechar()
                            estudio.usarEmNovaTarefa([u], espera: 0.6)
                        } label: { Label("Usar em nova tarefa", systemImage: "plus.rectangle.on.rectangle") }
                        Button { compactar() } label: { Label("Compartilhar como .zip", systemImage: "doc.zipper") }
                    } label: {
                        Image(systemName: ocupado ? "hourglass" : "ellipsis.circle")
                    }
                    .disabled(ocupado)
                }
            }
            .sheet(item: $zipado, onDismiss: { Zip.limpar() }) { z in FolhaCompartilhar(itens: [z.url]).presentationDetents([.medium, .large]) }
            .alert("Aviso", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(aviso ?? "") }
            .confirmar($confirmar)
        }
        .preferredColorScheme(.dark)
        .tint(Tema.acento)
    }

    private func salvarNoFotos(_ u: URL) {
        confirmar = Confirmacao(titulo: "Salvar na galeria do iPhone?", mensagem: "O vídeo entra no app Fotos.",
                                botao: "Salvar", destrutivo: false) { gravarNoFotos(u) }
    }

    private func gravarNoFotos(_ u: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in aviso = "Sem permissão para salvar no Fotos (Ajustes › Privacidade › Fotos)." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: u)
            }) { ok, erro in
                Task { @MainActor in
                    aviso = ok ? "Vídeo salvo no Fotos." : "Não consegui salvar: \(erro?.localizedDescription ?? "formato não aceito pelo Fotos")"
                }
            }
        }
    }
}

/// Um vídeo da galeria: o player só existe enquanto a página está à vista.
struct PaginaVideo: View {
    let url: URL
    let ativo: Bool
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onChange(of: ativo) { _, sim in if !sim { player?.pause() } }
            .onDisappear { player?.pause() }
    }
}

// MARK: - informações

struct PainelInfoVideo: View {
    let url: URL
    let origem: OrigemMidia?
    @State private var d: DetalhesVideo?
    @State private var lido = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let d {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent).font(.headline).lineLimit(2)
                        Text(d.data.map { $0.formatted(date: .complete, time: .shortened) } ?? "Sem data gravada")
                            .font(.subheadline).foregroundStyle(Tema.texto2)
                        if let c = d.camera { Label(c, systemImage: "camera.fill").font(.caption).foregroundStyle(Tema.texto2) }
                    }
                    linha("Formato", formato(d.info.codecVideo, d.info.hdr.rawValue, d.info.dolbyVision), difFormato)
                    linha("Resolução", "\(d.info.largura) × \(d.info.altura)", difResolucao(d))
                    linha("Quadros", fpsTexto(d.info.fps), difFps(d))
                    linha("Duração", formatarDuracao(d.info.duracao) ?? "—", difDuracao(d))
                    linha("Taxa do vídeo", mbps(d.taxaVideo), difTaxa(d))
                    linha("Tamanho", bytes(d.info.tamanhoBytes), difTamanho(d))
                    if d.info.temAudio {
                        linha("Áudio", audio(d), nil)
                    }
                    if d.info.hdr != .sdr {
                        linha("Ambiente do HDR", d.ambienteLux.map { luxTexto($0) } ?? "Não gravado", difAmbiente(d))
                    }
                    linha("Localização", d.local ? "Tem GPS" : "Sem GPS", nil)
                    if let o = origem {
                        linha("Arquivo original", o.nome,
                              o.data.map { "Gravado em " + $0.formatted(date: .abbreviated, time: .shortened) })
                    }
                } else if lido {
                    Text("Não consegui ler as informações deste vídeo.").foregroundStyle(Tema.texto2)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .task {
            d = await DetalhesVideo.ler(url)
            lido = true
        }
    }

    // MARK: textos

    private func linha(_ titulo: String, _ valor: String, _ detalhe: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(titulo).foregroundStyle(Tema.texto2)
                Spacer(minLength: 12)
                Text(valor).multilineTextAlignment(.trailing)
            }
            .font(.subheadline)
            if let detalhe {
                Text(detalhe).font(.caption).foregroundStyle(Tema.texto2)
                    .frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
            }
        }
    }

    private func formato(_ codec: String, _ hdr: String, _ dv: Bool) -> String {
        [codec, dv ? "Dolby Vision" : hdr].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var difFormato: String? {
        origem.map { "Original: " + formato($0.codec, $0.hdr, $0.dolbyVision) }
    }

    private func difResolucao(_ d: DetalhesVideo) -> String? {
        guard let o = origem else { return nil }
        if o.largura == d.info.largura && o.altura == d.info.altura { return "Igual ao original" }
        let p = pct(Double(d.info.largura * d.info.altura), Double(o.largura * o.altura))
        return "Original: \(o.largura) × \(o.altura) (\(p) em pixels)"
    }

    private func difFps(_ d: DetalhesVideo) -> String? {
        guard let o = origem, o.fps > 0 else { return nil }
        return abs(o.fps - d.info.fps) < 0.05 ? "Igual ao original" : "Original: " + fpsTexto(o.fps)
    }

    private func difDuracao(_ d: DetalhesVideo) -> String? {
        guard let o = origem else { return nil }
        return abs(o.duracao - d.info.duracao) < 0.1 ? nil : "Original: " + (formatarDuracao(o.duracao) ?? "—")
    }

    private func difTaxa(_ d: DetalhesVideo) -> String? {
        guard let o = origem, o.duracao > 0 else { return nil }
        let taxaOrig = Double(o.bytes) * 8 / o.duracao           // total do arquivo (vídeo + áudio)
        return "Original: ~" + mbps(taxaOrig) + " (arquivo todo)"
    }

    private func difTamanho(_ d: DetalhesVideo) -> String? {
        guard let o = origem else { return nil }
        return "Original: \(bytes(o.bytes)) (\(pct(Double(d.info.tamanhoBytes), Double(o.bytes))))"
    }

    private func difAmbiente(_ d: DetalhesVideo) -> String? {
        guard let o = origem, o.hdr != InfoMidia.Transferencia.sdr.rawValue else { return nil }
        guard let lo = o.ambienteLux else { return "O original também não tinha" }
        if let la = d.ambienteLux, abs(la - lo) < 0.5 { return "Igual ao original" }
        return "Original: " + luxTexto(lo)
    }

    private func audio(_ d: DetalhesVideo) -> String {
        var p: [String] = [d.info.audioAAC ? "AAC" : "Áudio"]
        p.append(d.info.canais == 1 ? "mono" : d.info.canais == 2 ? "estéreo" : "\(d.info.canais) canais")
        if d.taxaAudio > 0 { p.append("\(Int((d.taxaAudio / 1000).rounded())) kb/s") }
        return p.joined(separator: " · ")
    }

    private func fpsTexto(_ f: Double) -> String {
        let n = NumberFormatter(); n.maximumFractionDigits = 2
        return (n.string(from: NSNumber(value: f)) ?? "\(f)") + " fps"
    }

    private func luxTexto(_ l: Double) -> String { "\(Int(l.rounded())) lux" }

    private func mbps(_ b: Double) -> String {
        b <= 0 ? "—" : String(format: "%.1f Mb/s", b / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }

    private func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private func pct(_ novo: Double, _ antigo: Double) -> String {
        guard antigo > 0 else { return "—" }
        let p = (novo - antigo) / antigo * 100
        if abs(p) < 0.5 { return "igual" }
        return (p > 0 ? "+" : "−") + String(format: "%.0f%%", abs(p))
    }
}
