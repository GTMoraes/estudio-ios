import SwiftUI
import UniformTypeIdentifiers

// MARK: - presets de imagem

struct PresetImagem: Codable, Identifiable, Equatable {
    var id = UUID()
    var nome: String
    var opcoes: OpcoesImagem
}

@MainActor
@Observable
final class MeusPresetsImagem {
    static let shared = MeusPresetsImagem()
    private(set) var lista: [PresetImagem] = []

    nonisolated private static var arquivo: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("meus-presets-imagem.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.arquivo), let l = try? JSONDecoder().decode([PresetImagem].self, from: d) { lista = l }
    }

    func salvar(nome: String, opcoes: OpcoesImagem) -> UUID {
        var o = opcoes
        o.recorte = nil                        // o recorte é de cada imagem, não do preset
        let n = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = PresetImagem(nome: n.isEmpty ? "Meu preset \(lista.count + 1)" : n, opcoes: o)
        lista.append(p)
        gravar()
        return p.id
    }

    func remover(_ id: UUID) { lista.removeAll { $0.id == id }; gravar() }

    private func gravar() {
        try? FileManager.default.createDirectory(at: Self.arquivo.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(lista) { try? d.write(to: Self.arquivo, options: .atomic) }
    }

    /// Últimos ajustes usados (voltam na próxima vez).
    static var ultimas: OpcoesImagem {
        get {
            guard let d = UserDefaults.standard.data(forKey: "ultimasOpcoesImagem"),
                  var o = try? JSONDecoder().decode(OpcoesImagem.self, from: d) else { return OpcoesImagem() }
            o.recorte = nil
            return o
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "ultimasOpcoesImagem") }
    }
}

// MARK: - painel

/// Conversão de uma ou várias imagens (a aba de imagem do ConversorMidia).
struct PainelImagens: View {
    @Environment(Estudio.self) private var estudio
    let arquivos: [URL]
    var fechar: () -> Void

    @State private var o = MeusPresetsImagem.ultimas
    @State private var infos: [InfoImagem?] = []
    @State private var mini: UIImage?
    @State private var tamanhoTotal: Int64 = 0
    @State private var editandoRecorte = false
    @State private var meus = MeusPresetsImagem.shared
    @State private var pedindoNome = false
    @State private var nomeNovo = ""

    private var formatos: [FormatoImagem] { ConversorImagem.formatosDisponiveis }
    private var primeira: InfoImagem? { infos.first ?? nil }

    var body: some View {
        cabecalho
        presets
        formato
        tamanho
        recorte
        metadados
        nomes
        BotaoPrincipal(titulo: arquivos.count == 1 ? "Converter" : "Converter \(arquivos.count) imagens",
                       icone: "photo.badge.checkmark") {
            MeusPresetsImagem.ultimas = o
            estudio.converterImagens(arquivos, opcoes: o)
            fechar()
        }
        .task { await carregar() }
        .sheet(isPresented: $editandoRecorte) {
            if let u = arquivos.first {
                EditorRecorte(url: u, recorte: $o.recorte, proporcao: $o.proporcaoRecorte)
            }
        }
        .alert("Nome do preset", isPresented: $pedindoNome) {
            TextField("Ex.: WebP para o site", text: $nomeNovo)
            Button("Salvar") { _ = meus.salvar(nome: nomeNovo, opcoes: o); nomeNovo = "" }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private func carregar() async {
        let us = arquivos
        let r = await Task.detached { () -> ([InfoImagem?], CGImage?, Int64) in
            let i = us.map { ConversorImagem.info($0) }
            let m = us.first.flatMap { ConversorImagem.miniatura($0, lado: 300) }
            let t = us.reduce(Int64(0)) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? NSNumber)?.int64Value ?? 0) }
            return (i, m, t)
        }.value
        infos = r.0
        mini = r.1.map { UIImage(cgImage: $0) }
        tamanhoTotal = r.2
    }

    // MARK: partes

    private var cabecalho: some View {
        Cartao {
            HStack(spacing: 12) {
                if let mini {
                    Image(uiImage: mini).resizable().scaledToFill().frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    ProgressView().frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(arquivos.count == 1 ? arquivos[0].lastPathComponent : "\(arquivos.count) imagens")
                        .font(.headline).lineLimit(2)
                    if let p = primeira {
                        Text(arquivos.count == 1 ? "\(p.largura) × \(p.altura)" : "1ª: \(p.largura) × \(p.altura)")
                            .font(.subheadline).foregroundStyle(Tema.texto2)
                    }
                    if tamanhoTotal > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: tamanhoTotal, countStyle: .file))
                            .font(.subheadline).foregroundStyle(Tema.texto2)
                    }
                }
            }
            if infos.contains(where: { $0 == nil }) {
                Label("\(infos.filter { $0 == nil }.count) arquivo(s) não parecem imagens que o iPhone lê; serão pulados.",
                      systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.yellow)
            }
        }
    }

    private var presets: some View {
        Cartao(titulo: "Presets", icone: "bookmark.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Padrão") { o = OpcoesImagem() }.buttonStyle(.glass)
                    ForEach(meus.lista) { p in
                        Button(p.nome) { let r = o.recorte; o = p.opcoes; o.recorte = r }
                            .buttonStyle(.glass)
                            .contextMenu { Button("Apagar", role: .destructive) { meus.remover(p.id) } }
                    }
                    Button { pedindoNome = true } label: { Label("Salvar", systemImage: "plus") }.buttonStyle(.glass)
                }
            }
            Text("Toque e segure um preset seu para apagar.").font(.caption).foregroundStyle(Tema.texto2)
        }
    }

    private var formatoFinal: FormatoImagem {
        ConversorImagem.formatoFinal(o, tipoOriginal: primeira?.tipo)
    }

    private var formato: some View {
        Cartao(titulo: "Formato", icone: "photo") {
            Picker("Formato", selection: $o.formato) {
                ForEach(formatos) { Text($0.nome).tag($0) }
            }
            .pickerStyle(.menu)
            let f = formatoFinal
            if f == .webp {
                Toggle("Sem perdas", isOn: $o.semPerdas)
            }
            if f.comPerdas && !(f == .webp && o.semPerdas) {
                HStack {
                    Text("Qualidade")
                    Slider(value: Binding(get: { Double(o.qualidade) }, set: { o.qualidade = Int($0.rounded()) }), in: 1...100)
                        .disabled(o.usarAlvo)
                    Text("\(o.qualidade)").monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                Toggle("Alvo de tamanho", isOn: $o.usarAlvo)
                if o.usarAlvo {
                    HStack {
                        TextField("KB", value: $o.alvoKB, format: .number).keyboardType(.numberPad)
                            .padding(10).background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
                        Text("KB por imagem").foregroundStyle(Tema.texto2)
                    }
                    Text("Acha a maior qualidade (30 a 95) que cabe no tamanho, em até 7 tentativas.")
                        .font(.footnote).foregroundStyle(Tema.texto2)
                }
            }
            Text(dicaFormato(f)).font(.footnote).foregroundStyle(Tema.texto2)
        }
    }

    private func dicaFormato(_ f: FormatoImagem) -> String {
        switch f {
        case .webp: return o.semPerdas ? "WebP sem perdas: igual ao original, maior que o WebP comum." :
            "WebP: bem menor que o JPG na mesma qualidade; abre em qualquer navegador e no WhatsApp."
        case .jpg: return "JPG: abre em qualquer lugar. Sem transparência (vira fundo branco)."
        case .heic: return "HEIC: o formato das fotos do iPhone; pequeno, mas nem todo site e PC abre."
        case .png: return "PNG: sem perdas e com transparência; arquivos grandes para foto."
        case .avif: return "AVIF: ainda menor que o WebP; nem todo lugar abre."
        case .manter: return "Mantém o formato de cada original."
        }
    }

    private var tamanho: some View {
        Cartao(titulo: "Tamanho", icone: "arrow.up.left.and.arrow.down.right") {
            Picker("Redimensionar", selection: $o.redimensionar) {
                ForEach(ModoRedimensionar.allCases) { Text($0.nome).tag($0) }
            }
            .pickerStyle(.menu)
            switch o.redimensionar {
            case .nenhum: EmptyView()
            case .ladoMaior: campoNumero("Lado maior (px)", $o.ladoMaior)
            case .caixa:
                HStack { campoNumero("Largura", $o.larguraMax); Text("×"); campoNumero("Altura", $o.alturaMax) }
            case .porcentagem:
                HStack {
                    Slider(value: $o.porcentagem, in: 5...200, step: 5)
                    Text("\(Int(o.porcentagem))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            if o.redimensionar != .nenhum { Toggle("Nunca aumentar", isOn: $o.nuncaAumentar) }
            if let p = primeira {
                let t = GeometriaImagem.tamanhoFinal(p.largura, p.altura, o)
                Text("\(p.largura) × \(p.altura) → \(t.0) × \(t.1)\(arquivos.count > 1 ? " (1ª imagem)" : "")")
                    .font(.footnote).foregroundStyle(Tema.texto2)
            }
        }
    }

    private func campoNumero(_ titulo: String, _ v: Binding<Int>) -> some View {
        TextField(titulo, value: v, format: .number).keyboardType(.numberPad)
            .padding(10).background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
    }

    private var recorte: some View {
        Cartao(titulo: "Recorte", icone: "crop") {
            if let r = o.recorte {
                Text(String(format: "Recorte de %.0f%% × %.0f%% da imagem%@", r.largura * 100, r.altura * 100,
                            arquivos.count > 1 ? ", aplicado a todas" : ""))
                    .font(.subheadline)
            } else {
                Text("Sem recorte.").font(.subheadline).foregroundStyle(Tema.texto2)
            }
            HStack {
                Button { editandoRecorte = true } label: { Label("Cortar…", systemImage: "crop") }.buttonStyle(.glass)
                if o.recorte != nil {
                    Button("Tirar recorte", role: .destructive) { o.recorte = nil }.buttonStyle(.glass)
                }
            }
            if arquivos.count > 1 {
                Text("O recorte é marcado na 1ª imagem e vale para todas, na mesma posição relativa.")
                    .font(.footnote).foregroundStyle(Tema.texto2)
            }
        }
    }

    private var metadados: some View {
        Cartao(titulo: "Metadados e cor", icone: "info.circle") {
            Picker("Metadados", selection: $o.metadados) {
                ForEach(ModoMetadados.allCases) { Text($0.nome).tag($0) }
            }
            .pickerStyle(.menu)
            if o.metadados == .tudo { Toggle("Tirar GPS", isOn: $o.tirarGPS) }
            Toggle("Converter cor para sRGB", isOn: $o.paraSRGB)
            Text("sRGB: as fotos do iPhone vêm em Display P3; convertidas, ficam com a mesma cor em qualquer tela. A rotação da foto é sempre aplicada.")
                .font(.footnote).foregroundStyle(Tema.texto2)
        }
    }

    private var nomes: some View {
        Cartao(titulo: "Nome de saída", icone: "character.cursor.ibeam") {
            TextField("{nome}", text: $o.padraoNome)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(10).background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
            Text("{nome} {n} {largura} {altura} {data} {datahora}").font(.caption.monospaced()).foregroundStyle(Tema.texto2)
            ForEach(Array(arquivos.prefix(3).enumerated()), id: \.offset) { k, u in
                if k < infos.count, let i = infos[k] {
                    let t = GeometriaImagem.tamanhoFinal(i.largura, i.altura, o)
                    let f = ConversorImagem.formatoFinal(o, tipoOriginal: i.tipo)
                    let n = Renomear.aplicar(o.padraoNome, nome: (u.lastPathComponent as NSString).deletingPathExtension,
                                             indice: k + 1, largura: t.0, altura: t.1, data: i.data, digitos: o.digitosContador)
                    Text("\(u.lastPathComponent) → \(n).\(f.extensao ?? "jpg")")
                        .font(.caption).foregroundStyle(Tema.texto2).lineLimit(1).truncationMode(.middle)
                }
            }
            if arquivos.count > 3 { Text("…").font(.caption).foregroundStyle(Tema.texto2) }
        }
    }
}

// MARK: - editor de recorte

struct EditorRecorte: View {
    let url: URL
    @Binding var recorte: Recorte?
    @Binding var proporcao: Double
    @Environment(\.dismiss) private var fechar

    @State private var imagem: UIImage?
    @State private var r = Recorte()
    @State private var inicio: Recorte?
    @State private var prop = 0.0

    private let proporcoes: [(String, Double)] = [("Livre", 0), ("1:1", 1), ("4:5", 0.8), ("3:4", 0.75),
                                                   ("16:9", 16.0 / 9), ("9:16", 9.0 / 16)]
    private let minimo = 0.05

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let imagem {
                    GeometryReader { geo in
                        let quadro = encaixe(imagem.size, em: geo.size)
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: imagem).resizable().frame(width: quadro.width, height: quadro.height)
                                .position(x: quadro.midX, y: quadro.midY)
                            moldura(quadro, imagem.size)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(proporcoes, id: \.0) { nome, p in
                            Button(nome) { mudarProporcao(p) }
                                .buttonStyle(.glass)
                                .tint(prop == p ? Tema.acento : .primary)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .telaEscura()
            .navigationTitle("Recorte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { fechar() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        let inteiro = r.x < 0.001 && r.y < 0.001 && r.largura > 0.999 && r.altura > 0.999
                        recorte = inteiro ? nil : r
                        proporcao = prop
                        fechar()
                    }
                }
            }
            .task {
                if let cg = ConversorImagem.miniatura(url, lado: 1600) { imagem = UIImage(cgImage: cg) }
                r = recorte ?? Recorte()
                prop = proporcao
            }
        }
    }

    /// Retângulo onde a imagem aparece, centrada e inteira dentro da área.
    private func encaixe(_ img: CGSize, em area: CGSize) -> CGRect {
        let e = min(area.width / img.width, area.height / img.height)
        let w = img.width * e, h = img.height * e
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    @ViewBuilder
    private func moldura(_ q: CGRect, _ img: CGSize) -> some View {
        let caixa = CGRect(x: q.minX + CGFloat(r.x) * q.width, y: q.minY + CGFloat(r.y) * q.height,
                           width: CGFloat(r.largura) * q.width, height: CGFloat(r.altura) * q.height)
        // escurece fora do recorte
        Path { p in p.addRect(q); p.addRect(caixa) }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
        Rectangle().stroke(Color.white, lineWidth: 2)
            .frame(width: caixa.width, height: caixa.height)
            .contentShape(Rectangle())
            .position(x: caixa.midX, y: caixa.midY)
            .gesture(DragGesture()
                .onChanged { g in
                    if inicio == nil { inicio = r }
                    guard let b = inicio else { return }
                    r.x = min(max(0, b.x + Double(g.translation.width / q.width)), 1 - b.largura)
                    r.y = min(max(0, b.y + Double(g.translation.height / q.height)), 1 - b.altura)
                }
                .onEnded { _ in inicio = nil })
        ForEach(0..<4, id: \.self) { k in
            let sx = k % 2, sy = k / 2
            Circle().fill(Color.white).frame(width: 22, height: 22)
                .overlay(Circle().stroke(Tema.acento, lineWidth: 2))
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .position(x: sx == 0 ? caixa.minX : caixa.maxX, y: sy == 0 ? caixa.minY : caixa.maxY)
                .gesture(DragGesture()
                    .onChanged { g in
                        if inicio == nil { inicio = r }
                        guard let b = inicio else { return }
                        redimensionar(b, sx: sx, sy: sy, dx: Double(g.translation.width / q.width), dy: Double(g.translation.height / q.height),
                                      aspectoImagem: Double(img.width / img.height))
                    }
                    .onEnded { _ in inicio = nil })
        }
    }

    private func redimensionar(_ b: Recorte, sx: Int, sy: Int, dx: Double, dy: Double, aspectoImagem: Double) {
        var x0 = b.x, x1 = b.x + b.largura, y0 = b.y, y1 = b.y + b.altura
        if sx == 0 { x0 = min(max(0, x0 + dx), x1 - minimo) } else { x1 = max(min(1, x1 + dx), x0 + minimo) }
        if sy == 0 { y0 = min(max(0, y0 + dy), y1 - minimo) } else { y1 = max(min(1, y1 + dy), y0 + minimo) }
        if prop > 0 {
            // altura relativa que dá a proporção pedida em pixels: (w·W)/(h·H) = prop
            var w = x1 - x0
            var h = w * aspectoImagem / prop
            let hMax = sy == 0 ? y1 : 1 - y0
            if h > hMax { h = hMax; w = h * prop / aspectoImagem }
            let wMax = sx == 0 ? x1 : 1 - x0
            if w > wMax { w = wMax; h = w * aspectoImagem / prop }
            if sx == 0 { x0 = x1 - w } else { x1 = x0 + w }
            if sy == 0 { y0 = y1 - h } else { y1 = y0 + h }
        }
        r = Recorte(x: x0, y: y0, largura: x1 - x0, altura: y1 - y0)
    }

    /// Ajusta o recorte para a proporção, mantendo o centro (ForcarProporcao do ConversorMidia).
    private func mudarProporcao(_ p: Double) {
        prop = p
        guard p > 0, let img = imagem else { return }
        let W = Double(img.size.width), H = Double(img.size.height)
        let cx = r.x + r.largura / 2, cy = r.y + r.altura / 2
        var lpx = r.largura * W
        var apx = lpx / p
        if apx > H { apx = H; lpx = apx * p }
        if lpx > W { lpx = W; apx = lpx / p }
        let nl = lpx / W, na = apx / H
        r = Recorte(x: min(max(0, cx - nl / 2), 1 - nl), y: min(max(0, cy - na / 2), 1 - na), largura: nl, altura: na)
    }
}
