import SwiftUI
import UIKit
import Photos

// MARK: - grade de miniaturas (resultado de imagens)

struct GradeImagens: View {
    let item: Item
    @State private var aberta: Aberta?
    struct Aberta: Identifiable { let id: Int }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
            ForEach(Array(item.arquivos.enumerated()), id: \.offset) { k, nome in
                Button { aberta = Aberta(id: k) } label: { MiniaturaQuadrada(url: item.url(nome)) }
                    .buttonStyle(.plain)
            }
        }
        Text("Toque numa imagem para ver em tela cheia, com as informações.")
            .font(.footnote).foregroundStyle(Tema.texto2)
            .fullScreenCover(item: $aberta) { a in
                VisualizadorImagens(item: item, inicio: a.id)
            }
    }
}

struct MiniaturaQuadrada: View {
    let url: URL
    @State private var imagem: UIImage?

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
            .clipShape(.rect(cornerRadius: 10))
            .contentShape(.rect)
            .task {
                let u = url
                let cg = await Task.detached(priority: .userInitiated) { ConversorImagem.miniatura(u, lado: 300) }.value
                if let cg { imagem = UIImage(cgImage: cg) }
            }
    }
}

// MARK: - tela cheia

struct VisualizadorImagens: View {
    let item: Item
    @State private var atual: Int
    @State private var mostrarInfo = true
    @State private var aviso: String?
    @Environment(\.dismiss) private var fechar

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
                        ZoomImagem(url: item.url(nome))
                            .ignoresSafeArea(edges: .horizontal)
                            .tag(k)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                if mostrarInfo, !item.arquivos.isEmpty {
                    let nome = item.arquivos[min(atual, item.arquivos.count - 1)]
                    PainelInfoImagem(url: item.url(nome), origem: item.origens?[nome])
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
                }
            }
            .alert("Aviso", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(aviso ?? "") }
        }
        .preferredColorScheme(.dark)
        .tint(Tema.acento)
    }

    private func salvarNoFotos(_ u: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                Task { @MainActor in aviso = "Sem permissão para salvar no Fotos (Ajustes › Privacidade › Fotos)." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: u)
            }) { ok, erro in
                Task { @MainActor in
                    aviso = ok ? "Imagem salva no Fotos." : "Não consegui salvar: \(erro?.localizedDescription ?? "formato não aceito pelo Fotos")"
                }
            }
        }
    }
}

// MARK: - informações (como o "i" do Fotos)

struct PainelInfoImagem: View {
    let url: URL
    let origem: OrigemImagem?
    @State private var d: DetalhesImagem?
    @State private var lido = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let d {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent).font(.headline).lineLimit(2)
                        Text(d.data.map { $0.formatted(date: .complete, time: .shortened) } ?? "Sem data gravada")
                            .font(.subheadline).foregroundStyle(Tema.texto2)
                    }
                    if d.camera != nil || d.exposicao != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let c = d.camera { Label(c, systemImage: "camera.fill").font(.subheadline.weight(.semibold)) }
                            if let l = d.lente { Text(l).font(.caption).foregroundStyle(Tema.texto2) }
                            if let e = d.exposicao { Text(e).font(.caption.monospacedDigit()).foregroundStyle(Tema.texto2) }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                    }
                    linha("Formato", ConversorImagem.nomeFormato(d.tipo),
                          origem.map { o in "Original: " + ConversorImagem.nomeFormato(o.tipo) })
                    linha("Resolução", "\(d.largura) × \(d.altura) · \(mp(d.largura, d.altura))", difResolucao(d))
                    linha("Tamanho", bytes(d.bytes), difTamanho(d))
                    linha("Cor", d.perfil ?? "Sem perfil (lido como sRGB)", nil)
                    if d.alfa { linha("Transparência", "Sim", nil) }
                    linha("Localização", d.gps ? "Tem GPS" : "Sem GPS", nil)
                    if let o = origem {
                        linha("Arquivo original", o.nome,
                              o.data.map { "Tirada em " + $0.formatted(date: .abbreviated, time: .shortened) })
                    }
                } else if lido {
                    Text("Não consegui ler as informações desta imagem.").foregroundStyle(Tema.texto2)
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
            let u = url
            d = await Task.detached(priority: .userInitiated) { ConversorImagem.detalhes(u) }.value
            lido = true
        }
    }

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

    private func difResolucao(_ d: DetalhesImagem) -> String? {
        guard let o = origem else { return nil }
        if o.largura == d.largura && o.altura == d.altura { return "Igual ao original" }
        let p = pct(Double(d.largura * d.altura), Double(o.largura * o.altura))
        return "Original: \(o.largura) × \(o.altura) · \(mp(o.largura, o.altura)) (\(p) em pixels)"
    }

    private func difTamanho(_ d: DetalhesImagem) -> String? {
        guard let o = origem else { return nil }
        return "Original: \(bytes(o.bytes)) (\(pct(Double(d.bytes), Double(o.bytes))))"
    }

    private func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private func mp(_ l: Int, _ a: Int) -> String {
        let v = Double(l * a) / 1_000_000
        return v >= 10 ? String(format: "%.0f MP", v) : String(format: "%.1f MP", v).replacingOccurrences(of: ".", with: ",")
    }

    /// Diferença em relação ao original: "−87%", "+12%", "igual".
    private func pct(_ novo: Double, _ antigo: Double) -> String {
        guard antigo > 0 else { return "—" }
        let p = (novo - antigo) / antigo * 100
        if abs(p) < 0.5 { return "igual" }
        return (p > 0 ? "+" : "−") + String(format: "%.0f%%", abs(p))
    }
}

// MARK: - zoom (pinça e toque duplo)

struct ZoomImagem: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> RolagemZoom {
        let v = RolagemZoom()
        let u = url
        Task { @MainActor in
            let cg = await Task.detached(priority: .userInitiated) { ConversorImagem.miniatura(u, lado: 2800) }.value
            if let cg { v.imagem.image = UIImage(cgImage: cg) }
        }
        return v
    }

    func updateUIView(_ v: RolagemZoom, context: Context) {}
}

final class RolagemZoom: UIScrollView, UIScrollViewDelegate {
    let imagem = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imagem.contentMode = .scaleAspectFit
        addSubview(imagem)
        let duplo = UITapGestureRecognizer(target: self, action: #selector(toqueDuplo(_:)))
        duplo.numberOfTapsRequired = 2
        addGestureRecognizer(duplo)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 {
            imagem.frame = bounds
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imagem }

    @objc private func toqueDuplo(_ g: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imagem)
            let w = bounds.width / 3, h = bounds.height / 3
            zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }
}
