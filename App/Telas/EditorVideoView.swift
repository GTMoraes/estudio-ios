import SwiftUI
import Combine
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers

/// O que abrir no editor: os vídeos e, para "Editar de novo", os trechos já feitos.
struct AberturaEditor: Identifiable {
    let id = UUID()
    var fontes: [URL]
    var nomes: [String]
    var projeto: ProjetoEdicao? = nil
    var cortarAoAbrir = false          // corte automático: já propõe os cortes ao abrir
}

struct EditorVideoView: View {
    @Environment(Estudio.self) private var estudio
    @Environment(\.dismiss) private var fechar
    let aberto: AberturaEditor
    var aoGravar: () -> Void

    @State private var fontes: [URL] = []
    @State private var nomes: [String] = []
    @State private var duracoes: [Double] = []
    /// Sempre com posição e na ordem da linha do tempo.
    @State private var trechos: [TrechoEdicao] = []
    @State private var desfazer: [[TrechoEdicao]] = []
    @State private var refazer: [[TrechoEdicao]] = []
    @State private var selecionado: UUID?
    @State private var tempo: Double = 0
    @State private var zoom: CGFloat = 40               // pontos por segundo
    @State private var zoomInicio: CGFloat?
    @State private var player = AVPlayer()
    @State private var tocando = false
    @State private var posicao = ScrollPosition(edge: .leading)
    @State private var rolando = false
    @State private var ondas: [Int: [Float]] = [:]
    @State private var aparando: (id: UUID, inicio: Double, fim: Double, pos: Double)?
    @State private var movendo: (id: UUID, pos: Double)?
    @State private var ima = true
    @State private var painelVolume = false
    @State private var volumeSlider: Double = 1           // 0 … EscalaVolume.maximo (1 = 100%)
    @State private var deslocLinha: CGFloat = 0           // rolagem da linha do tempo (pontos)
    @State private var larguraLinha: CGFloat = 0
    @State private var pegaFixo: CGFloat?                 // posição do pegador enquanto arrasta
    @State private var soAudio = false                     // só áudios (sem vídeo): grava só o áudio
    @State private var cortes: [CorteProposto] = []        // corte automático: o que a regra tiraria
    @State private var cortando: String?                   // corte automático em andamento
    @State private var progressoCorte: Double?
    @State private var tarefaCorte: Task<Void, Never>?
    @State private var previaCortada = true                // a prévia pula as marcas vermelhas
    @State private var cortesAlinhados = true              // os tempos vieram do alinhador
    /// Prévia já cortada: trechos da linha do tempo que a prévia montada NÃO tem (marcas vermelhas ativas).
    /// O player toca a montagem sem eles (sem salto); o cursor converte entre os dois relógios.
    @State private var removidos: [ClosedRange<Double>] = []
    @State private var grudadoEm: Double?
    @State private var espacoTocado: Espaco?
    @State private var versaoPrevia = 0
    @State private var aviso: String?
    @State private var gravar = false
    @State private var confirmarSaida = false
    @State private var escolhendoArquivo = false
    @State private var galeria: [PhotosPickerItem] = []
    @State private var mostrarGaleria = false
    @State private var carregado = false
    @State private var convertendo: String?
    @State private var progressoConversao: Double = 0

    struct Espaco: Identifiable { let id = UUID(); let inicio: Double; let fim: Double }

    private let relogio = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    /// Fim do último trecho.
    private var total: Double { trechos.map { $0.fimNaLinha }.max() ?? 0 }
    /// Largura da linha do tempo: um pouco além do fim, para dar onde soltar trechos.
    private var duracaoLinha: Double { total + max(5, total * 0.25) }
    private var mudou: Bool { !desfazer.isEmpty }

    var body: some View {
        NavigationStack {
            observadores(folhas(principal))
        }
        .preferredColorScheme(.dark)
    }

    /// A tela, a barra e as folhas (dividido do `body` para o compilador conferir os tipos a tempo).
    private var principal: some View {
            VStack(spacing: 0) {
                previa
                barraTempo
                linhaDoTempo
                if !cortes.isEmpty { painelCortes }
                if painelVolume { painelDeVolume }
                ferramentas
            }
            .background(Color.black)
            .navigationTitle("Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar", systemImage: "xmark") {
                        if mudou { confirmarSaida = true } else { fechar() }
                    }
                }
                ToolbarItemGroup(placement: .principal) {
                    HStack(spacing: 16) {
                        Button { voltar() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(desfazer.isEmpty)
                        Button { avancar() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(refazer.isEmpty)
                        Button { ima.toggle() } label: {
                            IconeIma(ligado: ima).frame(width: 22, height: 22)
                        }
                        .accessibilityLabel(ima ? "Ímã ligado" : "Ímã desligado")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gravar") { player.pause(); tocando = false; gravar = true }
                        .disabled(trechos.isEmpty)
                }
            }
    }

    /// Avisos, confirmações, gravação e escolha de arquivos.
    private func folhas(_ v: some View) -> some View {
        v
            .alert("Sair sem gravar?", isPresented: $confirmarSaida) {
                Button("Sair", role: .destructive) { fechar() }
                Button("Continuar editando", role: .cancel) {}
            } message: { Text("As mudanças desta edição serão perdidas.") }
            .alert("Aviso", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(aviso ?? "") }
            .confirmationDialog("Espaço vazio", isPresented: Binding(get: { espacoTocado != nil }, set: { if !$0 { espacoTocado = nil } }),
                                titleVisibility: .visible) {
                Button("Fechar espaço") { if let e = espacoTocado { fecharEspaco(e) } }
                Button("Deixar", role: .cancel) {}
            } message: {
                Text("Espaço de \(String(format: "%.1f", (espacoTocado?.fim ?? 0) - (espacoTocado?.inicio ?? 0))) s: na gravação vira tela preta e silêncio.")
            }
            .sheet(isPresented: $gravar) {
                FolhaGravarEdicao(fontes: fontes, nomes: nomes, trechos: trechos, soAudio: soAudio) { opcoes, modo, base in
                    let p = ProjetoEdicao(fontes: fontes.map { $0.lastPathComponent }, trechos: trechos)
                    estudio.gravarEdicao(fontes: fontes, projeto: p, opcoes: opcoes, modo: modo,
                                         titulo: (nomes.first ?? "Edição") + " (editado)", base: base)
                    gravar = false
                    player.pause()
                    fechar()
                    aoGravar()
                }
            }
            .fileImporter(isPresented: $escolhendoArquivo, allowedContentTypes: [.movie], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r else { return }
                Task { await acrescentar(urls.compactMap { copiarDeFora($0) }) }
            }
            .onChange(of: galeria) { _, novos in
                guard !novos.isEmpty else { return }
                Task {
                    var urls: [URL] = []
                    for item in novos {
                        if let v = try? await item.loadTransferable(type: VideoDaGaleria.self) { urls.append(v.url) }
                    }
                    galeria = []
                    await acrescentar(urls)
                }
            }
    }

    /// Carregar, relógio da prévia e reações às mudanças.
    private func observadores(_ v: some View) -> some View {
        v
            .task { await carregar() }
            .onReceive(relogio) { _ in
                guard tocando, !rolando else { return }
                let p = CMTimeGetSeconds(player.currentTime())
                if p.isFinite {
                    let t = linhaDaPrevia(p)
                    tempo = min(t, total)
                    posicao.scrollTo(x: CGFloat(tempo) * zoom)
                    if t >= total - 0.02 { tocando = false; player.pause() }
                }
            }
            .onChange(of: trechos) { _, _ in
                if painelVolume { sincronizarVolume() }     // desfazer/refazer também mexe no volume
                // arrastando uma alça ou um trecho: a prévia é montada só ao soltar
                guard aparando == nil, movendo == nil else { return }
                Task { await atualizarPrevia() }
            }
            .onChange(of: selecionado) { _, _ in movendo = nil; aparando = nil; grudadoEm = nil; pegaFixo = nil }
            .onChange(of: cortes) { _, _ in Task { await atualizarPrevia() } }
            .onChange(of: previaCortada) { _, _ in Task { await atualizarPrevia() } }
            .onChange(of: alvoVolume) { _, _ in sincronizarVolume() }
            .onDisappear { player.pause(); tarefaCorte?.cancel() }
    }

    // MARK: prévia

    private var previa: some View {
        ZStack {
            CamadaPlayer(player: player)
            if !carregado { ProgressView() }
            if soAudio && carregado {
                Image(systemName: "waveform").font(.system(size: 54)).foregroundStyle(Tema.texto2).allowsHitTesting(false)
            }
            if let c = convertendo {
                VStack(spacing: 8) {
                    Text(c).font(.footnote).multilineTextAlignment(.center)
                    ProgressView(value: progressoConversao).frame(width: 200)
                }
                .padding(14)
                .background(.black.opacity(0.75), in: .rect(cornerRadius: 14))
            }
            if let c = cortando {
                VStack(spacing: 10) {
                    Text("Corte automático").font(.footnote.bold())
                    Text(c).font(.footnote).multilineTextAlignment(.center)
                    if let p = progressoCorte { ProgressView(value: p).frame(width: 200) } else { ProgressView() }
                    Button("Cancelar", role: .cancel) { tarefaCorte?.cancel() }.buttonStyle(.glass).font(.footnote)
                }
                .padding(14)
                .background(.black.opacity(0.8), in: .rect(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220)
        .layoutPriority(1)
        .onTapGesture { alternar() }
    }

    private var barraTempo: some View {
        HStack {
            Button { alternar() } label: {
                Image(systemName: tocando ? "pause.fill" : "play.fill").frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            Text("\(relogioTexto(tempo)) / \(relogioTexto(total))").font(.footnote.monospacedDigit()).foregroundStyle(Tema.texto2)
            Spacer()
            if let k = indiceSelecionado() {
                Text(rotuloTrecho(k)).font(.footnote).foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    // MARK: linha do tempo

    private var linhaDoTempo: some View {
        GeometryReader { g in
            let meia = g.size.width / 2
            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: meia)
                        ZStack(alignment: .topLeading) {
                            // fundo: tocar num espaço vazio oferece "Fechar espaço"
                            Color.white.opacity(0.001)
                                .frame(width: CGFloat(duracaoLinha) * zoom, height: 92)
                                .contentShape(Rectangle())
                                .onTapGesture(coordinateSpace: .local) { p in
                                    let t = Double(p.x / zoom)
                                    if let e = espaco(em: t) { espacoTocado = e } else { selecionado = nil }
                                }
                            ForEach(Array(trechos.enumerated()), id: \.element.id) { k, t in
                                bloco(k, t).offset(x: CGFloat(t.naLinha) * zoom)
                            }
                        }
                        .frame(width: CGFloat(duracaoLinha) * zoom, height: 92, alignment: .topLeading)
                        Color.clear.frame(width: meia)
                    }
                    .frame(height: 96)
                }
                .scrollPosition($posicao)
                .scrollDisabled(movendo != nil || aparando != nil)
                .onScrollPhaseChange { _, fase in
                    rolando = fase != .idle
                    if rolando && tocando { tocando = false; player.pause() }
                }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                    deslocLinha = x
                    guard rolando else { return }
                    tempo = min(max(0, Double(x / zoom)), duracaoLinha)
                    buscar(min(tempo, total))
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            if zoomInicio == nil { zoomInicio = zoom }
                            zoom = min(400, max(5, zoomInicio! * v.magnification))
                            posicao.scrollTo(x: CGFloat(tempo) * zoom)
                        }
                        .onEnded { _ in zoomInicio = nil }
                )
                // cursor fixo no meio
                Rectangle().fill(Color.white).frame(width: 2, height: 110).allowsHitTesting(false)
            }
            .onAppear { larguraLinha = g.size.width }
            .onChange(of: g.size.width) { _, w in larguraLinha = w }
        }
        .frame(height: 116)
        .background(Color(white: 0.08))
    }

    @ViewBuilder private func bloco(_ k: Int, _ t: TrechoEdicao) -> some View {
        let largura = max(8, CGFloat(t.duracao) * zoom)
        let sel = t.id == selecionado
        let arrastando = movendo?.id == t.id
        ZStack(alignment: .bottom) {
            MiniaturasTrecho(url: fontes.indices.contains(t.fonte) ? fontes[t.fonte] : nil, trecho: t, largura: largura)
                .frame(width: largura, height: 64)
                .clipped()
                .frame(maxHeight: .infinity, alignment: .top)
            OndaTrecho(onda: ondas[t.fonte] ?? [], trecho: t)
                .frame(width: largura, height: 26)
                .opacity(t.volume == 0 ? 0.25 : 1)
        }
        .frame(width: largura, height: 92)
        .background(Color(white: 0.16))
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(arrastando ? Color.cyan : (sel ? Color.yellow : Color.clear), lineWidth: 3)
        }
        .overlay(alignment: .topLeading) { if !cortes.isEmpty { marcasCorte(t) } }
        .overlay(alignment: .leading) { if sel && !arrastando { alca(t, inicio: true) } }
        .overlay(alignment: .trailing) { if sel && !arrastando { alca(t, inicio: false) } }
        .overlay(alignment: .topLeading) {
            if abs(t.velocidade - 1) > 0.001 {
                Text(Velocidade.nome(t.velocidade)).font(.caption2.bold()).padding(3)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 4)).padding(4)
            }
        }
        .overlay(alignment: .topLeading) {
            if sel {
                let x = (arrastando ? pegaFixo : nil) ?? posicaoPegador(t, largura: largura)
                alcaMover(t, x: x).offset(x: x)
            }
        }
        .scaleEffect(arrastando ? 1.04 : 1)
        .contentShape(Rectangle())
        .onTapGesture { selecionado = sel ? nil : t.id }
    }

    /// Onde fica o pegador (x dentro do trecho): no meio da parte do trecho que aparece na tela, para
    /// estar sempre ao alcance mesmo em trecho longo.
    private func posicaoPegador(_ t: TrechoEdicao, largura: CGFloat) -> CGFloat {
        let w: CGFloat = 44
        guard largura > w else { return (largura - w) / 2 }
        let meia = larguraLinha / 2
        let visIni = Double((deslocLinha - meia) / zoom), visFim = Double((deslocLinha + larguraLinha - meia) / zoom)
        let a = max(t.naLinha, visIni), b = min(t.fimNaLinha, visFim)
        let centro = larguraLinha > 0 && b > a ? (a + b) / 2 : (t.naLinha + t.fimNaLinha) / 2
        return min(max(CGFloat(centro - t.naLinha) * zoom - w / 2, 0), largura - w)
    }

    /// Pegador do trecho selecionado: arrastar move o trecho pela linha do tempo.
    /// (Só ele recebe o arrasto, para o resto do trecho continuar rolando a linha do tempo.)
    private func alcaMover(_ t: TrechoEdicao, x: CGFloat) -> some View {
        Image(systemName: "arrow.left.and.right")
            .font(.caption.bold())
            .foregroundStyle(.black)
            .frame(width: 44, height: 24)
            .background(Color.cyan, in: .capsule)
            .padding(.top, 4)
            .contentShape(Rectangle())
            .onTapGesture {}   // tocar sem arrastar não tira a seleção
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if movendo?.id != t.id {
                            registrar()
                            pegaFixo = x            // o pegador anda junto com o trecho, sob o dedo
                            movendo = (t.id, t.naLinha)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        guard let m = movendo else { return }
                        mover(m.id, de: m.pos, delta: Double(g.translation.width / zoom))
                    }
                    .onEnded { _ in
                        movendo = nil; grudadoEm = nil; pegaFixo = nil
                        Task { await atualizarPrevia() }
                    }
            )
    }

    /// Alça para aparar o começo ou o fim do trecho. O começo "come" o vídeo pela esquerda (a borda
    /// anda e fica espaço vazio antes); dá para estender até o começo/fim do vídeo original.
    private func alca(_ t: TrechoEdicao, inicio: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.yellow)
            .frame(width: 14, height: 92)
            .overlay(Image(systemName: inicio ? "chevron.compact.left" : "chevron.compact.right").font(.caption.bold()).foregroundStyle(.black))
            .contentShape(Rectangle())
            .onTapGesture {}   // tocar sem arrastar não tira a seleção
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if aparando?.id != t.id {
                            registrar()
                            aparando = (t.id, t.inicio, t.fim, t.naLinha)
                        }
                        guard let a = aparando else { return }
                        aparar(a, inicio: inicio, delta: Double(g.translation.width / zoom))
                    }
                    .onEnded { _ in aparando = nil; grudadoEm = nil; Task { await atualizarPrevia() } }
            )
    }

    // MARK: ferramentas

    private var ferramentas: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ferramenta("Corte auto", "scissors.circle") { proporCortes() }
                    .disabled(cortando != nil)
                ferramenta("Dividir", "scissors") { dividir() }
                ferramenta("Remover", "trash") {
                    if let k = indiceSelecionado() ?? indiceNoCursor() { remover(trechos[k].id) }
                }
                .disabled(trechos.count < 2)
                Menu {
                    ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { v in
                        Button(Velocidade.nome(v)) { mudarVelocidade(v) }
                    }
                } label: { rotulo("Velocidade", "gauge.with.dots.needle.67percent") }
                .buttonStyle(.glass)
                Button {
                    painelVolume.toggle()
                    if painelVolume { sincronizarVolume() }
                } label: { rotulo("Volume", painelVolume ? "speaker.wave.2.fill" : "speaker.wave.2") }
                .buttonStyle(.glass)
                Menu {
                    Button("Mover para a esquerda", systemImage: "arrow.left") { if let id = alvo() { trocar(id, -1) } }
                    Button("Mover para a direita", systemImage: "arrow.right") { if let id = alvo() { trocar(id, 1) } }
                    Button("Duplicar", systemImage: "plus.square.on.square") { if let id = alvo() { duplicar(id) } }
                    Button("Fechar todos os espaços", systemImage: "arrow.left.to.line") { fecharTodosEspacos() }
                } label: { rotulo("Ordem", "arrow.left.arrow.right") }
                .buttonStyle(.glass)
                if !soAudio {
                Menu {
                    Button("Da galeria", systemImage: "photo.on.rectangle") { mostrarGaleria = true }
                    Button("Do app Arquivos", systemImage: "folder") { escolhendoArquivo = true }
                } label: { rotulo("+ Vídeo", "plus.rectangle.on.rectangle") }
                .buttonStyle(.glass)
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
        .photosPicker(isPresented: $mostrarGaleria, selection: $galeria, maxSelectionCount: 10, matching: .videos,
                      preferredItemEncoding: .current)
    }

    private func ferramenta(_ titulo: String, _ icone: String, _ acao: @escaping () -> Void) -> some View {
        Button(action: acao) { rotulo(titulo, icone) }.buttonStyle(.glass)
    }

    private func rotulo(_ titulo: String, _ icone: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icone).font(.title3)
            Text(titulo).font(.caption2)
        }
        .frame(minWidth: 58)
        .padding(.vertical, 2)
    }

    // MARK: ímã

    /// Pontos em que bordas grudam: começo da linha do tempo, cursor e as bordas dos outros trechos.
    private func alvosIma(exceto id: UUID) -> [Double] {
        var a: [Double] = [0, tempo]
        for t in trechos where t.id != id { a.append(t.naLinha); a.append(t.fimNaLinha) }
        return a
    }

    /// Com o ímã ligado, o ponto mais próximo de `x` (até ~12 pontos na tela); senão, nil.
    private func grudar(_ x: Double, em alvos: [Double]) -> Double? {
        guard ima else { return nil }
        let limite = Double(12 / zoom)
        var melhor: Double?
        for a in alvos where abs(a - x) <= limite {
            if melhor == nil || abs(a - x) < abs(melhor! - x) { melhor = a }
        }
        return melhor
    }

    private func vibrarSeGrudou(_ alvo: Double?) {
        if let alvo, grudadoEm == nil || abs(grudadoEm! - alvo) > 0.0001 {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        grudadoEm = alvo
    }

    // MARK: ações

    private func registrar() {
        desfazer.append(trechos)
        if desfazer.count > 100 { desfazer.removeFirst() }
        refazer = []
    }
    private func voltar() {
        guard let a = desfazer.popLast() else { return }
        refazer.append(trechos); trechos = a
        if let s = selecionado, !trechos.contains(where: { $0.id == s }) { selecionado = nil }
    }
    private func avancar() {
        guard let p = refazer.popLast() else { return }
        desfazer.append(trechos); trechos = p
    }

    /// Põe na ordem da linha do tempo e empurra para a direita o que ficou sobreposto.
    private func ajeitar() {
        trechos.sort { $0.naLinha < $1.naLinha }
        guard trechos.count > 1 else { return }
        for j in 1..<trechos.count where trechos[j].naLinha < trechos[j - 1].fimNaLinha - 0.0001 {
            trechos[j].posicao = trechos[j - 1].fimNaLinha
        }
    }

    private func indiceSelecionado() -> Int? {
        guard let s = selecionado else { return nil }
        return trechos.firstIndex { $0.id == s }
    }
    /// Trecho sob o cursor (nil num espaço vazio).
    private func indiceNoCursor() -> Int? {
        trechos.firstIndex { tempo >= $0.naLinha - 0.0001 && tempo < $0.fimNaLinha - 0.0001 }
            ?? trechos.lastIndex { abs(tempo - $0.fimNaLinha) < 0.0001 }
    }
    /// Trecho em que a ação vale: o selecionado ou o que está sob o cursor.
    private func alvo() -> UUID? {
        if let k = indiceSelecionado() ?? indiceNoCursor() { return trechos[k].id }
        return nil
    }

    private func espaco(em t: Double) -> Espaco? {
        var fim = 0.0
        for x in trechos {
            if t >= fim && t < x.naLinha {
                return x.naLinha - fim > 0.02 ? Espaco(inicio: fim, fim: x.naLinha) : nil
            }
            fim = max(fim, x.fimNaLinha)
        }
        return nil
    }

    private func fecharEspaco(_ e: Espaco) {
        registrar()
        let d = e.fim - e.inicio
        for k in trechos.indices where trechos[k].naLinha >= e.fim - 0.0001 {
            trechos[k].posicao = trechos[k].naLinha - d
        }
        ajeitar()
        if tempo > e.fim { tempo -= d; buscar(tempo); posicao.scrollTo(x: CGFloat(tempo) * zoom) }
    }

    private func fecharTodosEspacos() {
        registrar()
        var fim = 0.0
        for k in trechos.indices {
            trechos[k].posicao = fim
            fim = trechos[k].fimNaLinha
        }
    }

    /// Arrasto do trecho inteiro: fica entre os vizinhos (não passa por cima deles).
    private func mover(_ id: UUID, de pos0: Double, delta: Double) {
        guard let k = trechos.firstIndex(where: { $0.id == id }) else { return }
        let dur = trechos[k].duracao
        let minimo = k > 0 ? trechos[k - 1].fimNaLinha : 0
        let maximo = k + 1 < trechos.count ? trechos[k + 1].naLinha - dur : duracaoLinha
        var novo = pos0 + delta
        let alvos = alvosIma(exceto: id)
        let gEsq = grudar(novo, em: alvos)
        let gDir = grudar(novo + dur, em: alvos)
        var grudou: Double?
        if let a = gEsq, gDir == nil || abs(a - novo) <= abs(gDir! - (novo + dur)) { novo = a; grudou = a }
        else if let b = gDir { novo = b - dur; grudou = b }
        novo = min(max(minimo, novo), max(minimo, maximo))
        vibrarSeGrudou(grudou)
        trechos[k].posicao = novo
    }

    private func aparar(_ a: (id: UUID, inicio: Double, fim: Double, pos: Double), inicio: Bool, delta: Double) {
        guard let k = trechos.firstIndex(where: { $0.id == a.id }) else { return }
        let t = trechos[k]
        let vel = max(0.1, t.velocidade)
        let maxFonte = duracoes.indices.contains(t.fonte) ? duracoes[t.fonte] : a.fim
        var alvos = alvosIma(exceto: a.id)
        if inicio {
            // a borda direita fica parada; a esquerda anda junto com o começo do vídeo
            let fimLinha = a.pos + (a.fim - a.inicio) / vel
            if let c = t.corteInicio { alvos.append(a.pos + (c - a.inicio) / vel) }
            var borda = a.pos + delta
            let g = grudar(borda, em: alvos)
            if let g { borda = g }
            let minBorda = max(k > 0 ? trechos[k - 1].fimNaLinha : 0, a.pos - a.inicio / vel)
            borda = min(max(borda, minBorda), fimLinha - 0.1 / vel)
            vibrarSeGrudou(g)
            trechos[k].inicio = a.inicio + (borda - a.pos) * vel
            trechos[k].posicao = borda
        } else {
            if let c = t.corteFim { alvos.append(a.pos + (c - a.inicio) / vel) }
            var borda = a.pos + (a.fim - a.inicio) / vel + delta
            let g = grudar(borda, em: alvos)
            if let g { borda = g }
            let limite = k + 1 < trechos.count ? trechos[k + 1].naLinha : .infinity
            let maxBorda = min(limite, a.pos + (maxFonte - a.inicio) / vel)
            borda = max(min(borda, maxBorda), a.pos + 0.1 / vel)
            vibrarSeGrudou(g)
            trechos[k].fim = a.inicio + (borda - a.pos) * vel
            trechos[k].posicao = a.pos
        }
    }

    private func dividir() {
        guard let k = indiceNoCursor() else {
            aviso = "Ponha o cursor em cima de um trecho para dividir."
            return
        }
        let t = trechos[k]
        let corte = t.inicio + (tempo - t.naLinha) * t.velocidade
        guard corte - t.inicio > 0.05, t.fim - corte > 0.05 else {
            aviso = "Ponha o cursor no meio de um trecho para dividir."
            return
        }
        registrar()
        var a = t, b = t
        a.id = UUID(); b.id = UUID()
        a.fim = corte; a.corteFim = corte
        b.inicio = corte; b.corteInicio = corte
        b.posicao = a.fimNaLinha
        trechos.replaceSubrange(k...k, with: [a, b])
        selecionado = b.id
    }

    /// Remove o trecho e deixa o espaço vazio no lugar.
    private func remover(_ id: UUID) {
        guard trechos.count > 1, let k = trechos.firstIndex(where: { $0.id == id }) else { return }
        registrar()
        trechos.remove(at: k)
        selecionado = nil
        tempo = min(tempo, duracaoLinha)
        buscar(min(tempo, total))
    }

    /// Troca de lugar com o vizinho (o espaço que havia entre os dois continua entre eles).
    private func trocar(_ id: UUID, _ passo: Int) {
        guard let k = trechos.firstIndex(where: { $0.id == id }) else { return }
        let n = k + passo
        guard n >= 0 && n < trechos.count else { return }
        registrar()
        let i = min(k, n), j = max(k, n)
        let espacoEntre = max(0, trechos[j].naLinha - trechos[i].fimNaLinha)
        let inicio = trechos[i].naLinha
        trechos[j].posicao = inicio
        trechos[i].posicao = inicio + trechos[j].duracao + espacoEntre
        ajeitar()
    }

    private func duplicar(_ id: UUID) {
        guard let k = trechos.firstIndex(where: { $0.id == id }) else { return }
        registrar()
        var c = trechos[k]; c.id = UUID()
        c.posicao = trechos[k].fimNaLinha
        trechos.insert(c, at: k + 1)
        ajeitar()
    }

    private func mudarVelocidade(_ v: Double) {
        guard let k = indiceSelecionado() ?? indiceNoCursor() else { return }
        registrar()
        trechos[k].velocidade = v
        ajeitar()          // ficou mais longo: empurra os seguintes só o necessário
    }

    /// Trecho que o painel de volume ajusta: o selecionado ou, sem seleção, o que está no cursor.
    private var alvoVolume: UUID? {
        guard let k = indiceSelecionado() ?? indiceNoCursor() else { return nil }
        return trechos[k].id
    }

    private func sincronizarVolume() {
        guard let id = alvoVolume, let t = trechos.first(where: { $0.id == id }) else { return }
        volumeSlider = min(EscalaVolume.maximo, EscalaVolume.porcento(ganho: t.volume))
    }

    /// `s`: porcentagem na escala do ouvido (1 = 100%).
    private func mudarVolume(porcento s: Double, todos: Bool) {
        let g = EscalaVolume.ganho(porcento: s)
        if todos {
            guard trechos.contains(where: { abs($0.volume - g) > 1e-6 }) else { return }
            registrar()
            for k in trechos.indices { trechos[k].volume = g }
        } else if let k = indiceSelecionado() ?? indiceNoCursor() {
            guard abs(trechos[k].volume - g) > 1e-6 else { return }
            registrar()
            trechos[k].volume = g
        }
    }

    private var painelDeVolume: some View {
        VStack(spacing: 8) {
            HStack {
                Text(alvoVolume.flatMap { id in trechos.firstIndex(where: { $0.id == id }) }.map { "Trecho \($0 + 1)" }
                     ?? "Ponha o cursor num trecho")
                    .font(.footnote.bold())
                Spacer()
                Text(EscalaVolume.texto(porcento: volumeSlider))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(volumeSlider > 1.005 ? Color.orange : Color.white)
                Button { painelVolume = false } label: { Image(systemName: "xmark").font(.footnote.bold()) }
                    .buttonStyle(.plain).padding(.leading, 6)
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(Tema.texto2)
                Slider(value: $volumeSlider, in: 0...EscalaVolume.maximo, onEditingChanged: { editando in
                    if !editando { mudarVolume(porcento: volumeSlider, todos: false) }
                })
                .tint(volumeSlider > 1.005 ? Color.orange : Color.cyan)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(Tema.texto2)
            }
            .disabled(alvoVolume == nil)
            .onChange(of: volumeSlider) { _, v in
                // gruda em 100% (o volume original)
                if v != 1 && abs(v - 1) < 0.04 { volumeSlider = 1; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
            HStack(spacing: 8) {
                Button("Mudo") { volumeSlider = 0; mudarVolume(porcento: 0, todos: false) }
                Button("100%") { volumeSlider = 1; mudarVolume(porcento: 1, todos: false) }
                Spacer()
                Button("Usar em todos") { mudarVolume(porcento: volumeSlider, todos: true) }
            }
            .font(.footnote)
            .buttonStyle(.glass)
            .disabled(alvoVolume == nil)
            if volumeSlider > 1.005 {
                Text("Acima de 100% um limitador segura os picos para o som não estourar.")
                    .font(.caption2).foregroundStyle(Tema.texto2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(Color(white: 0.11))
    }

    private func alternar() {
        if tocando { player.pause(); tocando = false; return }
        if tempo >= total - 0.05 { tempo = 0; buscar(0); posicao.scrollTo(x: 0) }
        player.play(); tocando = true
    }

    private func buscar(_ t: Double) {
        player.seek(to: CMTime(seconds: previaDaLinha(t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Linha do tempo -> relógio da prévia (dentro de um corte ativo, vai para o fim dele).
    private func previaDaLinha(_ t: Double) -> Double {
        var tirado = 0.0
        for r in removidos {
            if t >= r.upperBound { tirado += r.upperBound - r.lowerBound }
            else if t > r.lowerBound { return r.lowerBound - tirado }
            else { break }
        }
        return t - tirado
    }

    /// Relógio da prévia -> linha do tempo.
    private func linhaDaPrevia(_ p: Double) -> Double {
        var t = p
        for r in removidos {
            if r.lowerBound <= t + 0.0005 { t += r.upperBound - r.lowerBound } else { break }
        }
        return t
    }

    /// Os cortes ativos, em segundos da linha do tempo (juntos quando encostam).
    private func faixasRemovidas(_ lista: [TrechoEdicao]) -> [ClosedRange<Double>] {
        let ativos = cortes.filter { !$0.manter }
        guard !ativos.isEmpty else { return [] }
        var r: [ClosedRange<Double>] = []
        for tr in lista {
            let v = max(0.1, tr.velocidade)
            for c in ativos where c.fonte == tr.fonte && c.f > tr.inicio && c.i < tr.fim {
                let a = tr.naLinha + (max(c.i, tr.inicio) - tr.inicio) / v
                let b = tr.naLinha + (min(c.f, tr.fim) - tr.inicio) / v
                if b > a { r.append(a...b) }
            }
        }
        r.sort { $0.lowerBound < $1.lowerBound }
        var juntas: [ClosedRange<Double>] = []
        for x in r {
            if let u = juntas.last, x.lowerBound <= u.upperBound + 0.02 {
                juntas[juntas.count - 1] = u.lowerBound...max(u.upperBound, x.upperBound)
            } else { juntas.append(x) }
        }
        return juntas
    }

    private func rotuloTrecho(_ k: Int) -> String {
        let t = trechos[k]
        var r = "Trecho \(k + 1)"
        if abs(t.velocidade - 1) > 0.001 { r += " · " + Velocidade.nome(t.velocidade) }
        if abs(t.volume - 1) > 0.001 { r += t.volume == 0 ? " · mudo" : " · " + EscalaVolume.texto(ganho: t.volume) }
        return r
    }

    // MARK: corte automático

    /// Transcreve cada arquivo usado (ou pega a transcrição guardada) e marca em vermelho o que a
    /// regra aprovada tiraria. Nada muda nos trechos até "Aplicar cortes".
    private func proporCortes() {
        guard tarefaCorte == nil else { return }
        guard ModeloCrisper.pronto else {
            aviso = "Falta o modelo do corte automático. Baixe em Ajustes › Deixar o app pronto (1,2 GB)."
            return
        }
        player.pause(); tocando = false
        let usadas = Array(Set(trechos.map { $0.fonte })).sorted()
        let urls = fontes
        cortando = "Preparando"; progressoCorte = nil
        let dono = UUID()
        tarefaCorte = Task {
            var pegouAVez = false
            defer {
                cortando = nil; progressoCorte = nil; tarefaCorte = nil
                // só solta o modelo se chegou a usá-lo (senão soltaria o de um corte que está rodando)
                if pegouAVez { ServicoCorte.shared.liberar() }
                estudio.liberarVezDoEditor(dono)       // a tela pode voltar a apagar
            }
            do {
                // um trabalho pesado por vez: espera tratar voz, transcrição etc. terminarem
                try await estudio.aguardarVezDoEditor(dono) { pos in
                    cortando = pos <= 1 ? "Na fila: começa quando o trabalho atual terminar"
                                        : "Na fila (\(pos)º): começa quando os anteriores terminarem"
                }
                pegouAVez = true
                cortando = "Preparando"
                var novas: [CorteProposto] = []
                var alinhou = true
                for (n, k) in usadas.enumerated() where urls.indices.contains(k) {
                    let rotulo = usadas.count > 1 ? "Arquivo \(n + 1) de \(usadas.count): " : ""
                    let prop = try await ServicoCorte.shared.propor(urls[k]) { msg, p in
                        Task { @MainActor in
                            if cortando != nil { cortando = rotulo + msg; progressoCorte = p }
                        }
                    }
                    novas += prop.tirar.map { CorteProposto(fonte: k, i: $0.i, f: $0.f, texto: $0.texto) }
                    alinhou = alinhou && prop.alinhado
                }
                let atuais = trechos
                cortesAlinhados = alinhou
                cortes = novas.filter { c in atuais.contains { $0.fonte == c.fonte && $0.fim > c.i + 0.005 && $0.inicio < c.f - 0.005 } }
                if cortes.isEmpty { aviso = "Não achei nada para cortar." }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    aviso = msg.contains("Unable to compute the prediction")
                        ? "Corte automático parou: a tela apagou ou o app saiu da frente, e o iPhone não deixa usar a GPU em segundo plano. Rode de novo com o app aberto (o que já foi transcrito fica guardado)."
                        : "Corte automático: \(msg)"
                }
            }
        }
    }

    /// Marcas vermelhas dos cortes propostos dentro de um trecho (toque = manter aquele pedaço).
    private func marcasCorte(_ t: TrechoEdicao) -> some View {
        let v = max(0.1, t.velocidade)
        let aqui = cortes.filter { $0.fonte == t.fonte && $0.f > t.inicio && $0.i < t.fim }
        return ZStack(alignment: .topLeading) {
            ForEach(aqui) { c in
                let a = max(c.i, t.inicio), b = min(c.f, t.fim)
                let x = CGFloat((a - t.inicio) / v) * zoom
                let w = max(3, CGFloat((b - a) / v) * zoom)
                ZStack {
                    if c.manter {
                        Rectangle().strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    } else {
                        Rectangle().fill(Color.red.opacity(0.5))
                        if w > 30 {
                            Text(c.texto).font(.system(size: 9, weight: .semibold)).lineLimit(2)
                                .foregroundStyle(.white).padding(2)
                        }
                    }
                }
                .frame(width: w, height: 92)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let k = cortes.firstIndex(where: { $0.id == c.id }) { cortes[k].manter.toggle() }
                }
                .offset(x: x)
            }
        }
    }

    private var painelCortes: some View {
        let ativos = cortes.filter { !$0.manter }
        let tira = ativos.reduce(0.0) { soma, c in
            soma + trechos.filter { $0.fonte == c.fonte }.reduce(0.0) { s, t in
                s + max(0, min(c.f, t.fim) - max(c.i, t.inicio)) / max(0.1, t.velocidade)
            }
        }
        return VStack(spacing: 8) {
            HStack {
                Label("\(ativos.count) cortes · tira \(String(format: "%.1f", tira).replacingOccurrences(of: ".", with: ",")) s",
                      systemImage: "scissors").font(.footnote.bold())
                Spacer()
                Text(cortesAlinhados ? "tempos do alinhador" : "sem alinhador")
                    .font(.caption2).foregroundStyle(cortesAlinhados ? Tema.texto2 : Color.orange)
            }
            Text("Vermelho sai. Toque numa marca para manter aquele pedaço (fica tracejada).")
                .font(.caption2).foregroundStyle(Tema.texto2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Prévia já cortada (toca como vai ficar)", isOn: $previaCortada)
                .font(.footnote)
            HStack(spacing: 8) {
                Button("Descartar") { cortes = [] }
                Spacer()
                Button { aplicarCortes() } label: { Label("Aplicar cortes", systemImage: "checkmark") }
                    .buttonStyle(.glassProminent).tint(Tema.acento)
                    .disabled(ativos.isEmpty)
            }
            .font(.footnote)
            .buttonStyle(.glass)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(Color(white: 0.11))
    }

    /// Divide os trechos nos cortes e fecha os buracos deles; os espaços vazios que já existiam ficam.
    private func aplicarCortes() {
        let ativos = cortes.filter { !$0.manter }
        guard !ativos.isEmpty else { cortes = []; return }
        registrar()
        let nova = Self.cortado(trechos, ativos: ativos)
        removidos = []
        trechos = nova
        cortes = []
        selecionado = nil
    }

    /// Os trechos com os cortes aplicados (buracos dos cortes fechados; espaços que já existiam ficam).
    static func cortado(_ trechos: [TrechoEdicao], ativos: [CorteProposto]) -> [TrechoEdicao] {
        var nova: [TrechoEdicao] = []
        var desloc = 0.0
        for t in ProjetoEdicao.posicionados(trechos) {
            let v = max(0.1, t.velocidade)
            let cs = ativos.filter { $0.fonte == t.fonte && $0.f > t.inicio && $0.i < t.fim }.sorted { $0.i < $1.i }
            var pos = t.naLinha - desloc
            guard !cs.isEmpty else {
                var c = t; c.posicao = pos; nova.append(c); continue
            }
            var pedacos: [(Double, Double)] = []
            var a = t.inicio
            for c in cs {
                if c.i > a { pedacos.append((a, min(c.i, t.fim))) }
                a = max(a, c.f)
            }
            if a < t.fim { pedacos.append((a, t.fim)) }
            pedacos = pedacos.filter { $0.1 - $0.0 > 0.02 }
            var fica = 0.0
            for (n, (i0, f0)) in pedacos.enumerated() {
                var c = t
                if n > 0 { c.id = UUID() }
                c.inicio = i0; c.fim = f0
                c.corteInicio = i0; c.corteFim = f0
                c.posicao = pos
                nova.append(c)
                pos += (f0 - i0) / v
                fica += (f0 - i0) / v
            }
            desloc += t.duracao - fica
        }
        return nova
    }

    // MARK: carregar e prévia

    private func carregar() async {
        guard !carregado else { return }
        fontes = aberto.fontes
        nomes = aberto.nomes
        var d: [Double] = []
        for u in fontes {
            let s = (try? await AVURLAsset(url: u).load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            d.append(s.isFinite ? s : 0)
        }
        duracoes = d
        var algumVideo = false
        for u in fontes where !((try? await AVURLAsset(url: u).loadTracks(withMediaType: .video)) ?? []).isEmpty {
            algumVideo = true; break
        }
        soAudio = !algumVideo
        if let p = aberto.projeto {
            trechos = ProjetoEdicao.posicionados(p.trechos)
        } else {
            var fim = 0.0
            trechos = fontes.indices.compactMap { k in
                guard d[k] > 0.05 else { return nil }
                let t = TrechoEdicao(fonte: k, inicio: 0, fim: d[k], posicao: fim, corteInicio: 0, corteFim: d[k])
                fim += d[k]
                return t
            }
        }
        // zoom inicial: a edição inteira em ~3 telas
        let largura = UIScreen.main.bounds.width
        zoom = min(200, max(5, largura * 3 / CGFloat(max(total, 1))))
        await atualizarPrevia()
        carregado = true
        if aberto.cortarAoAbrir { proporCortes() }
        for (k, u) in fontes.enumerated() {
            let o = await AmostrasEdicao.shared.onda(u)
            ondas[k] = o
        }
    }

    private func acrescentar(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var novos: [TrechoEdicao] = []
        var fim = total
        for original in urls {
            var u = original
            if let f = await Compatibilidade.problema(original) {
                // o iPhone não abre (VP9 etc.): converte agora para HEVC, na qualidade máxima
                let base = original.deletingPathExtension().lastPathComponent
                let destino = Nuvem.semColisao(Estudio.pastaRecebidos.appendingPathComponent(base + ".mp4"))
                convertendo = "Convertendo “\(original.lastPathComponent)” (\(f)) para o iPhone"
                progressoConversao = 0
                do {
                    try await ConversorCompat.converter(original, para: destino, codec: .hevc, qualidade: .maxima) { p in
                        Task { @MainActor in progressoConversao = p }
                    }
                    u = destino
                    convertendo = nil
                } catch {
                    convertendo = nil
                    if !(error is CancellationError) {
                        aviso = "Não consegui converter “\(original.lastPathComponent)”: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    }
                    continue
                }
            }
            let s = (try? await AVURLAsset(url: u).load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            guard s.isFinite, s > 0.05 else { continue }
            fontes.append(u); nomes.append(u.lastPathComponent); duracoes.append(s)
            novos.append(TrechoEdicao(fonte: fontes.count - 1, inicio: 0, fim: s, posicao: fim, corteInicio: 0, corteFim: s))
            fim += s
            let k = fontes.count - 1
            Task { let o = await AmostrasEdicao.shared.onda(u); ondas[k] = o }
        }
        guard !novos.isEmpty else { return }
        registrar()
        trechos += novos
        ajeitar()
    }

    private func copiarDeFora(_ u: URL) -> URL? {
        let acesso = u.startAccessingSecurityScopedResource()
        defer { if acesso { u.stopAccessingSecurityScopedResource() } }
        let destino = Nuvem.semColisao(Estudio.pastaRecebidos.appendingPathComponent(u.lastPathComponent))
        return (try? FileManager.default.copyItem(at: u, to: destino)) != nil ? destino : nil
    }

    /// Remonta a prévia. Só a montagem mais recente vale (uma mais antiga que termine depois é descartada).
    private func atualizarPrevia() async {
        versaoPrevia += 1
        let minha = versaoPrevia
        let ativos = cortes.filter { !$0.manter }
        let cortar = previaCortada && !ativos.isEmpty
        let base = ProjetoEdicao.posicionados(trechos)
        let lista = cortar ? Self.cortado(base, ativos: ativos) : trechos
        let faixas = cortar ? faixasRemovidas(base) : []
        guard let primeiro = lista.first, fontes.indices.contains(primeiro.fonte) else { return }
        do {
            let tam = (try await MontagemEdicao.tamanhoExibicao(AVURLAsset(url: fontes[primeiro.fonte]))) ?? CGSize(width: 1280, height: 720)
            let escala = min(1, 1280 / max(tam.width, tam.height))
            let tela = CGSize(width: max(2, (tam.width * escala / 2).rounded() * 2), height: max(2, (tam.height * escala / 2).rounded() * 2))
            let m = try await MontagemEdicao.montar(fontes: fontes, trechos: lista, tela: tela, fps: 30, cor: nil)
            guard minha == versaoPrevia else { return }
            let item = AVPlayerItem(asset: m.composicao)
            item.videoComposition = m.videoComposition
            item.audioMix = m.audioMix
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            removidos = faixas
            buscar(min(tempo, total))
            if tocando { player.play() }
        } catch {
            guard minha == versaoPrevia else { return }
            aviso = "Não consegui montar a prévia: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func relogioTexto(_ s: Double) -> String {
        let v = max(0, s)
        return String(format: "%d:%04.1f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - miniaturas e onda de um trecho

struct MiniaturasTrecho: View {
    let url: URL?
    let trecho: TrechoEdicao
    let largura: CGFloat
    @State private var imagens: [Int: UIImage] = [:]

    private var quantas: Int { max(1, Int((largura / 56).rounded(.up))) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<quantas, id: \.self) { i in
                ZStack {
                    Color(white: 0.2)
                    if let img = imagens[i] { Image(uiImage: img).resizable().scaledToFill() }
                }
                .frame(width: largura / CGFloat(quantas), height: 64)
                .clipped()
            }
        }
        .task(id: "\(trecho.inicio)-\(trecho.fim)-\(quantas)") {
            guard let url else { return }
            var novas: [Int: UIImage] = [:]
            for i in 0..<quantas {
                let t = trecho.inicio + (Double(i) + 0.5) / Double(quantas) * trecho.duracaoOrigem
                if let img = await AmostrasEdicao.shared.miniatura(url, t) { novas[i] = img; imagens = novas }
                if Task.isCancelled { return }
            }
        }
    }
}

struct OndaTrecho: View {
    let onda: [Float]          // 20 pontos por segundo do arquivo de origem
    let trecho: TrechoEdicao

    var body: some View {
        Canvas { ctx, tam in
            guard !onda.isEmpty, tam.width > 1 else { return }
            let a = Int(trecho.inicio * 20), b = min(onda.count, Int(trecho.fim * 20))
            guard b > a else { return }
            let barras = max(1, Int(tam.width / 3))
            for i in 0..<barras {
                let ini = a + (b - a) * i / barras, fim = max(ini + 1, a + (b - a) * (i + 1) / barras)
                var m: Float = 0
                for k in ini..<min(fim, onda.count) { m = max(m, onda[k]) }
                // a onda acompanha o volume (mudo mostra a original, apagada); laranja = limitador agindo
                let v = m * (trecho.volume == 0 ? 1 : Float(trecho.volume))
                let h = max(1, CGFloat(min(1, v)) * tam.height)
                let r = CGRect(x: CGFloat(i) * 3, y: (tam.height - h) / 2, width: 2, height: h)
                ctx.fill(Path(r), with: .color(v > 0.966 && trecho.volume > 1.0001 ? .orange : .cyan.opacity(0.8)))
            }
        }
    }
}

// MARK: - gravar

struct FolhaGravarEdicao: View {
    @Environment(\.dismiss) private var fechar
    let fontes: [URL]
    let nomes: [String]
    let trechos: [TrechoEdicao]
    var soAudio = false
    var gravar: (OpcoesConversao, ModoGravacaoEdicao, String) -> Void

    @State private var modo: ModoGravacaoEdicao = .video
    @State private var semRegravar = false
    @State private var o = OpcoesConversao()
    @State private var info: InfoMidia?
    @State private var base = ""

    private var podeSemRegravar: Bool {
        trechos.count == 1 && trechos[0].naLinha < 0.01
            && abs(trechos[0].velocidade - 1) < 0.001 && abs(trechos[0].volume - 1) < 0.001
    }
    private var duracao: Double { ProjetoEdicao(fontes: [], trechos: trechos).duracao }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Cartao(titulo: "Gravar", icone: "square.and.arrow.down") {
                        Picker("Saída", selection: $modo) {
                            ForEach(soAudio ? [ModoGravacaoEdicao.audio] : [.video, .separados, .audio]) { Text($0.nome).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(textoModo).font(.footnote).foregroundStyle(Tema.texto2)
                        if modo == .video && podeSemRegravar {
                            Toggle("Sem regravar (mais rápido, sem perda)", isOn: $semRegravar)
                            if semRegravar {
                                Text("O corte cai no quadro-chave mais próximo: pode sobrar ou faltar até 1 a 2 s nas pontas.")
                                    .font(.footnote).foregroundStyle(.yellow)
                            }
                        }
                    }
                    if modo != .audio && !(modo == .video && semRegravar && podeSemRegravar) {
                        Cartao(titulo: "Vídeo", icone: "film") {
                            Picker("Formato", selection: $o.codec) {
                                Text("HEVC").tag(OpcoesConversao.Codec.hevc)
                                Text("H.264").tag(OpcoesConversao.Codec.h264)
                            }
                            .pickerStyle(.segmented)
                            Picker("Resolução", selection: $o.ladoMenor) {
                                Text("Original").tag(0)
                                Text("1080p").tag(1080)
                                Text("720p").tag(720)
                            }
                            .pickerStyle(.segmented)
                            if let info, info.hdr != .sdr {
                                Toggle("Manter HDR", isOn: Binding(get: { o.saida == .manterHDR && o.codec == .hevc },
                                                                   set: { o.saida = $0 ? .manterHDR : .sdr }))
                                    .disabled(o.codec == .h264)
                            }
                            VStack(alignment: .leading) {
                                Text("Qualidade: \(nomeQualidade)").font(.subheadline)
                                Slider(value: $o.qualidade, in: 0.25...1)
                            }
                            if let info {
                                let (w, h) = dimensoes(info)
                                Text("\(w)×\(h) · \(formatarDuracao(duracao) ?? "") · o formato vem do primeiro vídeo")
                                    .font(.footnote).foregroundStyle(Tema.texto2)
                            }
                        }
                    }
                    Cartao(titulo: "Nome", icone: "textformat") {
                        TextField("Nome do arquivo", text: $base)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(12).background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                    }
                    BotaoPrincipal(titulo: "Gravar", icone: "checkmark") {
                        let m: ModoGravacaoEdicao = (modo == .video && semRegravar && podeSemRegravar) ? .semRecodificar : modo
                        let b = Nuvem.limpar(base.trimmingCharacters(in: .whitespaces))
                        gravar(o, m, b.isEmpty ? "edicao" : b)
                    }
                }
                .padding()
            }
            .telaEscura()
            .navigationTitle("Gravar edição")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Voltar", systemImage: "chevron.left") { fechar() } }
            }
            .task {
                if soAudio { modo = .audio }
                o.ladoMenor = 0
                o.qualidade = 0.75
                if base.isEmpty {
                    let n = ((nomes.first ?? "video") as NSString).deletingPathExtension
                    base = Nuvem.limpar(n) + "-editado"
                }
                if let p = trechos.first, fontes.indices.contains(p.fonte) { info = try? await InfoMidia.ler(fontes[p.fonte]) }
            }
        }
    }

    private var textoModo: String {
        switch modo {
        case .video, .semRecodificar:
            return ProjetoEdicao.temEspacos(trechos)
                ? "Todos os trechos num vídeo só, como na linha do tempo. Os espaços vazios viram tela preta e silêncio."
                : "Todos os trechos num vídeo só, como na linha do tempo."
        case .separados: return "Cada trecho vira um vídeo separado (\(trechos.count) arquivos); os espaços não entram."
        case .audio: return "Só o som da edição, em M4A (AAC)."
        }
    }

    private var nomeQualidade: String {
        o.qualidade >= 0.9 ? "máxima" : o.qualidade >= 0.65 ? "alta" : o.qualidade >= 0.45 ? "média" : "menor arquivo"
    }

    private func dimensoes(_ i: InfoMidia) -> (Int, Int) {
        var oc = o
        oc.acao = .video; oc.enquadramento = nil
        return PlanoConversao.dimensoes(i, oc)
    }
}


// MARK: - ímã

/// Ímã em ferradura, só o contorno: branco ligado, apagado e riscado desligado.
struct IconeIma: View {
    let ligado: Bool

    var body: some View {
        ZStack {
            FormaIma()
                .stroke(Color.white.opacity(ligado ? 1 : 0.4), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .rotationEffect(.degrees(45))
            if !ligado {
                Path { p in p.move(to: CGPoint(x: 2, y: 2)); p.addLine(to: CGPoint(x: 20, y: 20)) }
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .accessibilityLabel(ligado ? "Ímã ligado" : "Ímã desligado")
    }
}

/// Contorno de um ímã em U (aberto para cima), com a marca dos polos nas pontas. Desenhado numa grade 20×20.
struct FormaIma: Shape {
    func path(in r: CGRect) -> Path {
        let e = min(r.width, r.height) / 20
        let ox = r.midX - 10 * e, oy = r.midY - 10 * e
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * e, y: oy + y * e) }
        let c = pt(10, 10.5)
        var p = Path()
        p.move(to: pt(2.5, 2))
        p.addLine(to: pt(2.5, 10.5))
        p.addArc(center: c, radius: 7.5 * e, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: pt(17.5, 2))
        p.addLine(to: pt(13, 2))
        p.addLine(to: pt(13, 10.5))
        p.addArc(center: c, radius: 3 * e, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: pt(7, 2))
        p.closeSubpath()
        // polos
        p.move(to: pt(2.5, 5.5)); p.addLine(to: pt(7, 5.5))
        p.move(to: pt(13, 5.5)); p.addLine(to: pt(17.5, 5.5))
        return p
    }
}


/// Um pedaço que o corte automático tiraria (tempos no arquivo de origem).
struct CorteProposto: Identifiable, Equatable {
    let id = UUID()
    var fonte: Int
    var i: Double
    var f: Double
    var texto: String
    var manter = false
}
