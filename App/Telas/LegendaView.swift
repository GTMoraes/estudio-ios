import SwiftUI
import AVFoundation

/// Editor de legendas: o vídeo em cima (com a legenda desenhada pela mesma função que grava o
/// vídeo final) e, embaixo, três abas: blocos, estilo e posição.
struct EditorLegenda: View {
    @Environment(Estudio.self) private var estudio
    @Environment(\.dismiss) private var fechar
    @Environment(\.displayScale) private var escalaTela
    let id: UUID

    enum Aba: String, CaseIterable { case blocos = "Blocos", estilo = "Estilo", posicao = "Posição" }

    @State private var projeto = ProjetoLegenda()
    @State private var carregado = false
    @State private var semVideo = false
    @State private var motivo = ""
    @State private var info: InfoMidia?
    @State private var player = AVPlayer()
    @State private var observador: Any?
    @State private var tempo = 0.0
    @State private var tocando = false
    @State private var aba = Aba.blocos
    @State private var selecionado: Int?
    @State private var editando: Editado?
    @State private var exportando = false
    @State private var aviso: String?
    @State private var margens = true
    @State private var arrasteInicio: CGPoint?
    @State private var fimDoTrecho: Double?          // "tocar o bloco": para aqui

    struct Editado: Identifiable { let id: Int }

    private var proporcao: CGFloat {
        guard let i = info, i.altura > 0, i.largura > 0 else { return 9.0 / 16 }
        return CGFloat(i.largura) / CGFloat(i.altura)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    if semVideo {
                        ContentUnavailableView("Vídeo não encontrado", systemImage: "film.stack",
                                               description: Text(motivo + " O .srt e o .txt continuam em Resultados."))
                    } else if !carregado {
                        ProgressView("Abrindo o vídeo…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        previa.frame(height: geo.size.height * (aba == .posicao ? 0.52 : 0.38))
                        transporte
                        Picker("Aba", selection: $aba) {
                            ForEach(Aba.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal).padding(.bottom, 8)
                        painel
                    }
                }
            }
            .telaEscura()
            .navigationTitle("Legenda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar", systemImage: "xmark") { fechar() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Exportar") { player.pause(); exportando = true }.disabled(!carregado || info == nil)
                }
            }
        }
        .task { await carregar() }
        .onDisappear {
            player.pause()
            if let observador { player.removeTimeObserver(observador) }
            observador = nil
            if carregado { estudio.salvarLegenda(id, projeto) }
        }
        .sheet(item: $editando) { e in
            EditarBlocoLegenda(projeto: projeto, bloco: e.id,
                               salvar: { projeto = $0 },
                               tocar: { b in tocarTrecho(b.inicio, b.fimExibicao) })
        }
        .sheet(isPresented: $exportando) {
            if let info {
                ExportarLegenda(info: info, projeto: projeto,
                                gravar: { o in exportar(o) },
                                soArquivos: { estudio.salvarLegenda(id, projeto); aviso = "O .srt e o .txt foram atualizados em Resultados." })
            }
        }
        .alert("Aviso", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(aviso ?? "") }
        .preferredColorScheme(.dark)
    }

    // MARK: prévia

    private var blocos: [BlocoLegenda] { projeto.blocos }

    private func ativo(_ bs: [BlocoLegenda]) -> (bloco: Int, palavra: Int)? {
        PintorLegenda.ativo(bs, projeto.palavras, em: tempo)
    }

    private var previa: some View {
        ZStack {
            Color.black
            CamadaPlayer(player: player)
                .aspectRatio(proporcao, contentMode: .fit)
                .overlay { GeometryReader { g in sobreposicao(g.size) } }
        }
        .clipped()
    }

    @ViewBuilder private func sobreposicao(_ tam: CGSize) -> some View {
        let bs = blocos
        let a = ativo(bs)
        // na aba Posição a legenda aparece sempre (a do bloco selecionado ou a primeira), para arrastar
        let k: Int? = a?.bloco ?? (aba == .posicao || !tocando ? indiceParaMostrar(bs) : nil)
        ZStack(alignment: .topLeading) {
            if margens && aba == .posicao && proporcao < 0.7 {
                faixa("nome do perfil").frame(height: tam.height * 0.11)
                faixa("botões e descrição do Reels").frame(height: tam.height * 0.19)
                    .offset(y: tam.height * 0.81)
            }
            if aba == .posicao && abs(projeto.estilo.x - 0.5) < 0.001 {
                Rectangle().fill(.white.opacity(0.6)).frame(width: 1, height: tam.height).offset(x: tam.width / 2)
            }
            if let k, bs.indices.contains(k) {
                let b = bs[k]
                let saida = DesenhoLegenda.desenhar(Array(projeto.palavras[b.indices]),
                                                    ativa: projeto.estilo.destaque ? (a?.bloco == k ? a?.palavra : 0) : nil,
                                                    estilo: projeto.estilo, linhasMax: projeto.linhas,
                                                    tela: CGSize(width: tam.width * escalaTela, height: tam.height * escalaTela))
                if let saida {
                    Image(decorative: saida.imagem, scale: escalaTela)
                        .overlay {
                            if aba == .posicao { RoundedRectangle(cornerRadius: 6).stroke(Tema.acento, lineWidth: 1.5) }
                        }
                        .offset(x: saida.quadro.minX / escalaTela, y: saida.quadro.minY / escalaTela)
                }
            }
        }
        .frame(width: tam.width, height: tam.height, alignment: .topLeading)
        .contentShape(.rect)
        .gesture(aba == .posicao ? arrastar(tam) : nil)
        .onTapGesture { if aba != .posicao { alternar() } }
    }

    private func indiceParaMostrar(_ bs: [BlocoLegenda]) -> Int? {
        if let s = selecionado, let k = bs.firstIndex(where: { $0.id == s }) { return k }
        // parado fora de um bloco: mostra o mais próximo, para dar para ver o estilo
        return bs.indices.min(by: { abs(bs[$0].inicio - tempo) < abs(bs[$1].inicio - tempo) })
    }

    private func faixa(_ texto: String) -> some View {
        Text(texto).font(.caption2).foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tema.acento.opacity(0.28))
    }

    private func arrastar(_ tam: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                let base = arrasteInicio ?? CGPoint(x: projeto.estilo.x, y: projeto.estilo.y)
                if arrasteInicio == nil { arrasteInicio = base }
                var x = Double(base.x) + Double(v.translation.width / max(tam.width, 1))
                let y = Double(base.y) + Double(v.translation.height / max(tam.height, 1))
                if abs(x - 0.5) < 0.025 { x = 0.5 }                 // gruda no centro
                projeto.estilo.x = min(0.95, max(0.05, x))
                projeto.estilo.y = min(0.97, max(0.03, y))
            }
            .onEnded { _ in arrasteInicio = nil }
    }

    // MARK: tocar

    private var transporte: some View {
        HStack(spacing: 12) {
            Button { alternar() } label: {
                Image(systemName: tocando ? "pause.fill" : "play.fill").frame(width: 26, height: 26)
            }
            .buttonStyle(.glass)
            Slider(value: Binding(get: { tempo }, set: { ir($0) }), in: 0...max(0.1, info?.duracao ?? 0.1))
                .tint(Tema.acento)
            Text(relogio(tempo)).font(.caption.monospacedDigit()).foregroundStyle(Tema.texto2)
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func relogio(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)).replacingOccurrences(of: ".", with: ",")
    }

    private func alternar() {
        fimDoTrecho = nil
        if tocando { player.pause() } else {
            if let d = info?.duracao, tempo >= d - 0.05 { ir(0) }
            player.play()
        }
    }

    private func ir(_ t: Double) {
        tempo = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tocarTrecho(_ ini: Double, _ fim: Double) {
        ir(ini); fimDoTrecho = fim; player.play()
    }

    private func carregar() async {
        guard !carregado else { return }
        guard let p = Originais.lerProjeto(id) else { semVideo = true; motivo = "O projeto desta legenda não foi encontrado."; return }
        let u: URL
        do { u = try await estudio.videoDaLegenda(id) }
        catch { semVideo = true; motivo = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return }
        projeto = p
        info = try? await InfoMidia.ler(u)
        player.replaceCurrentItem(with: AVPlayerItem(url: u))
        let tocador = player
        observador = tocador.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: DispatchQueue.main) { t in
            let s = CMTimeGetSeconds(t)
            MainActor.assumeIsolated {
                if s.isFinite { tempo = s }
                tocando = tocador.rate != 0
                if let f = fimDoTrecho, s >= f { tocador.pause(); fimDoTrecho = nil }
            }
        }
        carregado = true
    }

    private func exportar(_ o: OpcoesConversao) {
        let p = projeto
        Task {
            if let e = await estudio.exportarLegenda(id, p, opcoes: o) { aviso = e } else { fechar() }
        }
    }

    // MARK: abas

    @ViewBuilder private var painel: some View {
        switch aba {
        case .blocos: abaBlocos
        case .estilo: ScrollView { PainelEstiloLegenda(projeto: $projeto).padding(.horizontal).padding(.bottom, 24) }
        case .posicao: ScrollView { abaPosicao.padding(.horizontal).padding(.bottom, 24) }
        }
    }

    private var abaBlocos: some View {
        let bs = blocos
        let atual = ativo(bs)?.bloco
        return VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([0, 1, 2, 3, 4, 5, 6], id: \.self) { n in
                        ficha(n == 0 ? "Por frase" : "\(n)", ligada: projeto.palavrasPorBloco == n) {
                            projeto.palavrasPorBloco = n; projeto.reagrupar(); selecionado = nil
                        }
                    }
                    Menu {
                        ForEach(1...3, id: \.self) { n in
                            Button("\(n) \(n == 1 ? "linha" : "linhas")") { projeto.linhas = n; if projeto.palavrasPorBloco == 0 { projeto.reagrupar() } }
                        }
                    } label: {
                        Text("Linhas: \(projeto.linhas)").font(.footnote).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.white.opacity(0.08), in: .capsule)
                    }
                }
                .padding(.horizontal)
            }
            ScrollViewReader { rolo in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(bs.enumerated()), id: \.element.id) { k, b in
                            linhaBloco(b, noAr: atual == k)
                        }
                        Text("Trocar “Por frase / 1 / 2…” refaz os blocos: divisões e junções feitas à mão se perdem (o texto corrigido fica).")
                            .font(.caption).foregroundStyle(Tema.texto2).padding(.top, 4)
                    }
                    .padding(.horizontal).padding(.bottom, 12)
                }
                .onChange(of: atual) { _, novo in
                    if tocando, let novo, bs.indices.contains(novo) { withAnimation { rolo.scrollTo(bs[novo].id, anchor: .center) } }
                }
            }
            if let s = selecionado, let b = bs.first(where: { $0.id == s }) {
                HStack(spacing: 8) {
                    botaoFerramenta("Editar", "pencil") { player.pause(); editando = Editado(id: b.id) }
                    botaoFerramenta("Tocar", "play.circle") { tocarTrecho(b.inicio, b.fimExibicao) }
                    botaoFerramenta("Juntar", "arrow.down.to.line") { projeto.juntar(b) }
                    botaoFerramenta("Apagar", "trash") { projeto.apagar(b); selecionado = nil }
                }
                .padding(.horizontal).padding(.bottom, 8)
            }
        }
    }

    private func linhaBloco(_ b: BlocoLegenda, noAr: Bool) -> some View {
        Button {
            selecionado = b.id
            fimDoTrecho = nil
            ir(b.inicio + 0.01)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(relogio(b.inicio)).font(.caption.monospacedDigit()).foregroundStyle(Tema.texto2)
                    .frame(width: 52, alignment: .leading)
                Text(projeto.texto(b)).font(.subheadline).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(selecionado == b.id ? Tema.acento.opacity(0.28) : .white.opacity(noAr ? 0.14 : 0.06),
                        in: .rect(cornerRadius: 14))
            .overlay {
                if selecionado == b.id { RoundedRectangle(cornerRadius: 14).stroke(Tema.acento, lineWidth: 1) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(b.id)
    }

    private func ficha(_ t: String, ligada: Bool, _ acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Text(t).font(.footnote.weight(ligada ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(ligada ? Tema.acento : .white.opacity(0.08), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func botaoFerramenta(_ t: String, _ icone: String, _ acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            Label(t, systemImage: icone).font(.footnote).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 2)
        }
        .buttonStyle(.glass)
    }

    private var abaPosicao: some View {
        Cartao {
            Text("Arraste a legenda no vídeo. Ela gruda no centro.").font(.footnote).foregroundStyle(Tema.texto2)
            HStack(spacing: 8) {
                botaoFerramenta("Topo", "arrow.up.to.line") { projeto.estilo.y = 0.16 }
                botaoFerramenta("Meio", "arrow.up.and.down") { projeto.estilo.y = 0.5 }
                botaoFerramenta("Base", "arrow.down.to.line") { projeto.estilo.y = 0.76 }
                botaoFerramenta("Centro", "arrow.left.and.right") { projeto.estilo.x = 0.5 }
            }
            Regua(titulo: "Largura máxima", valor: $projeto.estilo.larguraMax, faixa: 0.4...1, porcento: true)
            Toggle("Mostrar onde o Instagram cobre o vídeo", isOn: $margens)
            Text("A legenda quebra em mais linhas (até o limite da aba Blocos) ou diminui a letra para caber na largura.")
                .font(.caption).foregroundStyle(Tema.texto2)
        }
    }
}

// MARK: - estilo

struct PainelEstiloLegenda: View {
    @Binding var projeto: ProjetoLegenda

    private func cor(_ kp: WritableKeyPath<EstiloLegenda, String>) -> Binding<Color> {
        Binding(get: { Color(uiColor: UIColor(hex: projeto.estilo[keyPath: kp])) },
                set: { projeto.estilo[keyPath: kp] = UIColor($0).hex })
    }

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PresetLegenda.todos) { p in
                        Button { projeto.aplicar(p) } label: {
                            Text(p.nome).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.white.opacity(0.1), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Cartao(titulo: "Texto", icone: "textformat") {
                Picker("Fonte", selection: $projeto.estilo.fonte) {
                    ForEach(EstiloLegenda.fontes, id: \.valor) { f in Text(f.nome).tag(f.valor) }
                }
                Picker("Peso", selection: $projeto.estilo.peso) {
                    ForEach(Array(EstiloLegenda.pesos.enumerated()), id: \.offset) { k, n in Text(n).tag(k) }
                }
                .pickerStyle(.segmented)
                Regua(titulo: "Tamanho", valor: $projeto.estilo.tamanho, faixa: 0.025...0.18, porcento: true, vezes: 1000)
                ColorPicker("Cor", selection: cor(\.cor), supportsOpacity: false)
                Toggle("MAIÚSCULAS", isOn: $projeto.estilo.maiusculas)
                Toggle("Destacar a palavra falada", isOn: $projeto.estilo.destaque)
                if projeto.estilo.destaque {
                    ColorPicker("Cor do destaque", selection: cor(\.corDestaque), supportsOpacity: false)
                }
            }
            Cartao(titulo: "Contorno e fundo", icone: "square.dashed") {
                Regua(titulo: "Espessura do contorno", valor: $projeto.estilo.contorno, faixa: 0...0.3, porcento: true)
                ColorPicker("Cor do contorno", selection: cor(\.corContorno), supportsOpacity: false)
                Toggle("Sombra", isOn: $projeto.estilo.sombra)
                Toggle("Caixa de fundo", isOn: $projeto.estilo.caixa)
                if projeto.estilo.caixa {
                    ColorPicker("Cor da caixa", selection: cor(\.corCaixa), supportsOpacity: false)
                    Regua(titulo: "Opacidade da caixa", valor: $projeto.estilo.opacidadeCaixa, faixa: 0.2...1, porcento: true)
                }
            }
            Cartao(titulo: "Espaçamento", icone: "arrow.up.and.down.text.horizontal") {
                Regua(titulo: "Entre linhas", valor: $projeto.estilo.espacoLinhas, faixa: 0.7...2.4, porcento: true)
                Regua(titulo: "Entre letras", valor: $projeto.estilo.espacoLetras, faixa: -0.08...0.4, porcento: true)
                Regua(titulo: "Entre palavras", valor: $projeto.estilo.espacoPalavras, faixa: -0.2...1, porcento: true)
                Button("Voltar ao espaçamento normal") {
                    projeto.estilo.espacoLinhas = projeto.estilo.caixa ? 1.38 : 1
                    projeto.estilo.espacoLetras = 0; projeto.estilo.espacoPalavras = 0
                }
                .buttonStyle(.glass)
            }
        }
    }
}

/// Régua com título e valor (em % ou em milésimos).
struct Regua: View {
    let titulo: String
    @Binding var valor: Double
    let faixa: ClosedRange<Double>
    var porcento = false
    var vezes = 100.0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(titulo).font(.subheadline)
                Spacer()
                Text(String(format: "%.0f", valor * vezes) + (porcento && vezes == 100 ? " %" : ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(Tema.texto2)
            }
            Slider(value: $valor, in: faixa).tint(Tema.acento)
        }
    }
}

// MARK: - editar um bloco

struct EditarBlocoLegenda: View {
    @State var projeto: ProjetoLegenda
    let bloco: Int
    var salvar: (ProjetoLegenda) -> Void
    var tocar: (BlocoLegenda) -> Void
    @Environment(\.dismiss) private var fechar
    @State private var texto = ""
    @State private var lido = false
    @State private var cortar: Int?

    private var atual: BlocoLegenda? { projeto.blocos.first { $0.id == bloco } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let b = atual {
                    VStack(spacing: 16) {
                        Cartao(titulo: "Texto", icone: "pencil") {
                            TextEditor(text: $texto)
                                .frame(minHeight: 90)
                                .scrollContentBackground(.hidden)
                                .padding(8).background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                            Text("Enter quebra a linha onde você quiser. Corrigir palavras não muda os tempos; mudando a quantidade de palavras, o tempo do bloco é repartido entre elas.")
                                .font(.caption).foregroundStyle(Tema.texto2)
                        }
                        Cartao(titulo: "Tempo", icone: "clock") {
                            passo("Início", b.inicio) { d in aplicarTexto(); if let n = atual { projeto.moverInicio(n, para: n.inicio + d) } }
                            passo("Fim", b.fim) { d in aplicarTexto(); if let n = atual { projeto.moverFim(n, para: n.fim + d) } }
                            Button { aplicarTexto(); salvar(projeto); if let n = atual { tocar(n) }; fechar() } label: {
                                Label("Salvar e tocar o bloco", systemImage: "play.circle").frame(maxWidth: .infinity).padding(.vertical, 4)
                            }
                            .buttonStyle(.glass)
                        }
                        if b.indices.count > 1 {
                            Cartao(titulo: "Dividir o bloco", icone: "scissors") {
                                Text("Toque na última palavra da primeira parte.").font(.footnote).foregroundStyle(Tema.texto2)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
                                    ForEach(Array(b.indices.dropLast()), id: \.self) { i in
                                        Button { cortar = i } label: {
                                            Text(projeto.palavras[i].texto).font(.footnote).lineLimit(1)
                                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                                .background(cortar == i ? Tema.acento : .white.opacity(0.08), in: .capsule)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                if let c = cortar, projeto.palavras.indices.contains(c) {
                                    BotaoPrincipal(titulo: "Dividir depois de “\(projeto.palavras[c].texto)”", icone: "scissors") {
                                        projeto.dividir(depoisDe: c); salvar(projeto); fechar()
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                } else {
                    ContentUnavailableView("Bloco apagado", systemImage: "trash")
                }
            }
            .telaEscura()
            .navigationTitle("Editar bloco")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { fechar() } }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { aplicarTexto(); salvar(projeto); fechar() } }
            }
            .onAppear {
                if !lido, let b = atual { texto = projeto.texto(b); lido = true }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Passa o texto digitado para o projeto (só se mudou; a divisão usa os índices das palavras).
    private func aplicarTexto() {
        guard let b = atual, texto != projeto.texto(b) else { return }
        projeto.trocarTexto(b, por: texto)
        cortar = nil
    }

    private func passo(_ titulo: String, _ valor: Double, _ mover: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(titulo)
            Spacer()
            Button { mover(-0.05) } label: { Image(systemName: "minus").frame(width: 22, height: 22) }.buttonStyle(.glass)
            Text(String(format: "%d:%05.2f", Int(valor) / 60, valor.truncatingRemainder(dividingBy: 60)))
                .font(.body.monospacedDigit()).frame(width: 78)
            Button { mover(0.05) } label: { Image(systemName: "plus").frame(width: 22, height: 22) }.buttonStyle(.glass)
        }
    }
}

// MARK: - exportar

struct ExportarLegenda: View {
    let info: InfoMidia
    let projeto: ProjetoLegenda
    var gravar: (OpcoesConversao) -> Void
    var soArquivos: () -> Void
    @Environment(\.dismiss) private var fechar
    @State private var preset: PresetConversao = .instagramSDR
    @State private var escolhido = false

    private static let presets: [PresetConversao] = [.instagramHDR, .instagramSDR, .qualidade, .menor]

    private var opcoes: OpcoesConversao {
        var o = OpcoesConversao()
        preset.aplicar(&o)
        return o
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Cartao(titulo: "Vídeo com a legenda gravada", icone: "captions.bubble.fill") {
                        Picker("Preset", selection: $preset) {
                            ForEach(Self.presets) { p in Text(p.nome).tag(p) }
                        }
                        Text(preset.dica).font(.footnote).foregroundStyle(Tema.texto2)
                        let o = opcoes
                        let dims = PlanoConversao.dimensoesSaida(info, o)
                        linha("Resolução", "\(dims.0) × \(dims.1)")
                        linha("Quadros", String(format: "%.0f fps", PlanoConversao.fpsSaida(info, o)))
                        linha("Taxa do vídeo", String(format: "%.1f Mb/s", PlanoConversao.taxaVideo(info, o) / 1_000_000))
                        linha("Tamanho estimado", ByteCountFormatter.string(fromByteCount: PlanoConversao.tamanhoEstimado(info, o), countStyle: .file))
                        BotaoPrincipal(titulo: "Gravar a legenda no vídeo", icone: "film") { gravar(opcoes); fechar() }
                        Text("Vira um vídeo novo em Resultados. A legenda gravada sempre recodifica o vídeo; para outros ajustes (corte, formato, velocidade), use “Editar novamente” no resultado.")
                            .font(.caption).foregroundStyle(Tema.texto2)
                    }
                    Cartao(titulo: "Só os arquivos de legenda", icone: "doc.text") {
                        Text("Atualiza o .srt e o .txt deste item com os blocos e as correções (\(projeto.blocos.count) blocos).")
                            .font(.footnote).foregroundStyle(Tema.texto2)
                        Button { soArquivos(); fechar() } label: {
                            Label("Atualizar .srt e .txt", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding()
            }
            .telaEscura()
            .navigationTitle("Exportar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { fechar() } } }
            .onAppear {
                if !escolhido { preset = info.hdr != .sdr ? .instagramHDR : .instagramSDR; escolhido = true }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func linha(_ a: String, _ b: String) -> some View {
        HStack { Text(a).foregroundStyle(Tema.texto2); Spacer(); Text(b).monospacedDigit() }.font(.subheadline)
    }
}

// MARK: - camada do player

/// O vídeo sem controles (a prévia tem os dela).
struct CamadaPlayer: UIViewRepresentable {
    let player: AVPlayer

    final class Tela: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var camada: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Tela {
        let v = Tela()
        v.camada.player = player
        v.camada.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: Tela, context: Context) {
        if v.camada.player !== player { v.camada.player = player }
    }
}
