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
            VStack(spacing: 0) {
                previa
                barraTempo
                linhaDoTempo
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
                            Text("Ímã").font(.footnote.bold())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(ima ? Color.yellow : Color.white.opacity(0.15), in: .capsule)
                                .foregroundStyle(ima ? Color.black : Color.white)
                        }
                        .accessibilityLabel(ima ? "Ímã ligado" : "Ímã desligado")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gravar") { player.pause(); tocando = false; gravar = true }
                        .disabled(trechos.isEmpty)
                }
            }
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
                FolhaGravarEdicao(fontes: fontes, nomes: nomes, trechos: trechos) { opcoes, modo, base in
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
            .task { await carregar() }
            .onReceive(relogio) { _ in
                guard tocando, !rolando else { return }
                let t = CMTimeGetSeconds(player.currentTime())
                if t.isFinite {
                    tempo = min(t, total)
                    posicao.scrollTo(x: CGFloat(tempo) * zoom)
                    if t >= total - 0.02 { tocando = false; player.pause() }
                }
            }
            .onChange(of: trechos) { _, _ in
                // arrastando uma alça ou um trecho: a prévia é montada só ao soltar
                guard aparando == nil, movendo == nil else { return }
                Task { await atualizarPrevia() }
            }
            .onChange(of: selecionado) { _, _ in movendo = nil; aparando = nil; grudadoEm = nil }
            .onDisappear { player.pause() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: prévia

    private var previa: some View {
        ZStack {
            CamadaPlayer(player: player)
            if !carregado { ProgressView() }
            if let c = convertendo {
                VStack(spacing: 8) {
                    Text(c).font(.footnote).multilineTextAlignment(.center)
                    ProgressView(value: progressoConversao).frame(width: 200)
                }
                .padding(14)
                .background(.black.opacity(0.75), in: .rect(cornerRadius: 14))
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
        .overlay(alignment: .leading) { if sel && !arrastando { alca(t, inicio: true) } }
        .overlay(alignment: .trailing) { if sel && !arrastando { alca(t, inicio: false) } }
        .overlay(alignment: .topLeading) {
            if abs(t.velocidade - 1) > 0.001 {
                Text(Velocidade.nome(t.velocidade)).font(.caption2.bold()).padding(3)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 4)).padding(4)
            }
        }
        .overlay(alignment: .top) { if sel { alcaMover(t) } }
        .scaleEffect(arrastando ? 1.04 : 1)
        .contentShape(Rectangle())
        .onTapGesture { selecionado = sel ? nil : t.id }
    }

    /// Pegador no meio do trecho selecionado: arrastar move o trecho pela linha do tempo.
    /// (Só ele recebe o arrasto, para o resto do trecho continuar rolando a linha do tempo.)
    private func alcaMover(_ t: TrechoEdicao) -> some View {
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
                            movendo = (t.id, t.naLinha)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        guard let m = movendo else { return }
                        mover(m.id, de: m.pos, delta: Double(g.translation.width / zoom))
                    }
                    .onEnded { _ in
                        movendo = nil; grudadoEm = nil
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
                Menu {
                    Section("Neste trecho") {
                        ForEach([1.0, 0.75, 0.5, 0.25, 0], id: \.self) { v in
                            Button(v == 0 ? "Mudo" : "\(Int(v * 100))%") { mudarVolume(v, todos: false) }
                        }
                    }
                    Section("Em tudo") {
                        ForEach([1.0, 0.5, 0], id: \.self) { v in
                            Button(v == 0 ? "Tudo mudo" : "Tudo \(Int(v * 100))%") { mudarVolume(v, todos: true) }
                        }
                    }
                } label: { rotulo("Áudio", "speaker.wave.2") }
                .buttonStyle(.glass)
                Menu {
                    Button("Mover para a esquerda", systemImage: "arrow.left") { if let id = alvo() { trocar(id, -1) } }
                    Button("Mover para a direita", systemImage: "arrow.right") { if let id = alvo() { trocar(id, 1) } }
                    Button("Duplicar", systemImage: "plus.square.on.square") { if let id = alvo() { duplicar(id) } }
                    Button("Fechar todos os espaços", systemImage: "arrow.left.to.line") { fecharTodosEspacos() }
                } label: { rotulo("Ordem", "arrow.left.arrow.right") }
                .buttonStyle(.glass)
                Menu {
                    Button("Da galeria", systemImage: "photo.on.rectangle") { mostrarGaleria = true }
                    Button("Do app Arquivos", systemImage: "folder") { escolhendoArquivo = true }
                } label: { rotulo("+ Vídeo", "plus.rectangle.on.rectangle") }
                .buttonStyle(.glass)
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

    private func mudarVolume(_ v: Double, todos: Bool) {
        registrar()
        if todos { for k in trechos.indices { trechos[k].volume = v } }
        else if let k = indiceSelecionado() ?? indiceNoCursor() { trechos[k].volume = v }
    }

    private func alternar() {
        if tocando { player.pause(); tocando = false; return }
        if tempo >= total - 0.05 { tempo = 0; buscar(0); posicao.scrollTo(x: 0) }
        player.play(); tocando = true
    }

    private func buscar(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func rotuloTrecho(_ k: Int) -> String {
        let t = trechos[k]
        var r = "Trecho \(k + 1)"
        if abs(t.velocidade - 1) > 0.001 { r += " · " + Velocidade.nome(t.velocidade) }
        if t.volume < 0.999 { r += t.volume == 0 ? " · mudo" : " · \(Int(t.volume * 100))%" }
        return r
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
        let lista = trechos
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
                let h = max(1, CGFloat(m) * tam.height)
                let r = CGRect(x: CGFloat(i) * 3, y: (tam.height - h) / 2, width: 2, height: h)
                ctx.fill(Path(r), with: .color(.cyan.opacity(0.8)))
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
    var gravar: (OpcoesConversao, ModoGravacaoEdicao, String) -> Void

    @State private var modo: ModoGravacaoEdicao = .video
    @State private var semRegravar = false
    @State private var o = OpcoesConversao()
    @State private var info: InfoMidia?
    @State private var base = ""

    private var podeSemRegravar: Bool {
        trechos.count == 1 && trechos[0].naLinha < 0.01
            && abs(trechos[0].velocidade - 1) < 0.001 && trechos[0].volume > 0.999
    }
    private var duracao: Double { ProjetoEdicao(fontes: [], trechos: trechos).duracao }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Cartao(titulo: "Gravar", icone: "square.and.arrow.down") {
                        Picker("Saída", selection: $modo) {
                            ForEach([ModoGravacaoEdicao.video, .separados, .audio]) { Text($0.nome).tag($0) }
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
