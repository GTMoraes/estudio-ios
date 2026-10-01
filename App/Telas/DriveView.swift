import SwiftUI
import AVKit

/// Link do Google Drive colado no app: abre a pasta (ou o arquivo), navega pelas subpastas,
/// mostra as miniaturas e baixa o que for escolhido. O download vira um item em Resultados.
struct NavegadorDrive: View {
    @Environment(Estudio.self) private var estudio
    let link: String
    var fechar: () -> Void

    @State private var raiz: Drive.Item?
    @State private var erro: String?
    @State private var semChave = !Drive.configurado
    @State private var tentativa = 0

    var body: some View {
        NavigationStack {
            Group {
                if semChave {
                    ScrollView {
                        VStack(spacing: 16) {
                            Cartao {
                                Label("Falta configurar o Google Drive", systemImage: "key.fill").font(.headline)
                                Text("Entre com a conta Google ou salve a chave de API. É uma vez só; depois toque em “Abrir”.")
                                    .font(.footnote).foregroundStyle(Tema.texto2)
                            }
                            CartaoContaGoogle()
                            CartaoDrive()
                            BotaoPrincipal(titulo: "Abrir", icone: "arrow.right.circle.fill") {
                                semChave = !Drive.configurado
                                if !semChave { tentativa += 1 }
                            }
                        }
                        .padding()
                    }
                } else if let raiz {
                    PastaDrive(pasta: raiz, fechar: fechar)
                } else if let erro {
                    ContentUnavailableView {
                        Label("Não abriu", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(erro)
                    } actions: {
                        Button("Tentar de novo") { self.erro = nil; tentativa += 1 }.buttonStyle(.glass)
                    }
                } else {
                    ProgressView("Abrindo o Drive…")
                }
            }
            .telaEscura()
            .navigationDestination(for: Drive.Item.self) { p in PastaDrive(pasta: p, fechar: fechar) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar", systemImage: "xmark") { fechar() }
                }
            }
        }
        .task(id: tentativa) { await abrir() }
    }

    private func abrir() async {
        guard !semChave, raiz == nil else { return }
        if let r = Drive.raizEspecial(link) { raiz = r; return }       // Meu Drive, Compartilhados comigo…
        guard let l = Drive.analisar(link) else { erro = "Esse link do Drive não foi reconhecido."; return }
        do {
            let r = try await Drive.abrir(l)
            raiz = r
            estudio.lembrarDrive(r)
        } catch { self.erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

// MARK: - pasta

struct PastaDrive: View {
    @Environment(Estudio.self) private var estudio
    let pasta: Drive.Item            // pasta, ou um arquivo só (link de arquivo)
    var fechar: () -> Void

    enum Filtro: String, CaseIterable { case tudo = "Tudo", videos = "Vídeos", fotos = "Fotos" }

    @AppStorage("driveEmLista") private var emLista = false
    @State private var itens: [Drive.Item]?
    @State private var erro: String?
    @State private var filtro = Filtro.tudo
    @State private var selecionando = false
    @State private var selecionados: Set<String> = []
    @State private var previa: Previa?
    @State private var listando = false
    @State private var aviso: String?

    struct Previa: Identifiable { let id: Int }

    private var pastas: [Drive.Item] { (itens ?? []).filter(\.ehPasta) }
    private var arquivos: [Drive.Item] {
        let a = (itens ?? []).filter { !$0.ehPasta }
        switch filtro {
        case .tudo: return a
        case .videos: return a.filter(\.ehVideo)
        case .fotos: return a.filter(\.ehImagem)
        }
    }
    private var especial: Bool { pasta.id.hasPrefix("@") }
    private var temMidia: Bool { (itens ?? []).contains(where: \.ehMidia) }
    private var escolhidos: [Drive.Item] { (itens ?? []).filter { selecionados.contains($0.id) && !$0.ehPasta } }

    var body: some View {
        Group {
            if let itens {
                if itens.isEmpty {
                    ContentUnavailableView(especial ? "Nada aqui" : "Pasta vazia", systemImage: "folder",
                                           description: Text(especial ? "Nada compartilhado nesta parte da sua conta."
                                                             : "Ou o que tem nela não está compartilhado com você."))
                } else {
                    conteudo
                }
            } else if let erro {
                ContentUnavailableView {
                    Label("Não abriu", systemImage: "exclamationmark.icloud")
                } description: { Text(erro) } actions: {
                    Button("Tentar de novo") { self.erro = nil; Task { await carregar() } }.buttonStyle(.glass)
                }
            } else {
                ProgressView("Lendo a pasta…")
            }
        }
        .navigationTitle(pasta.nome)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if itens?.isEmpty == false {
                    Button(selecionando ? "OK" : "Selecionar") {
                        selecionando.toggle()
                        if !selecionando { selecionados = [] }
                    }
                    menuMais
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // nos lugares da conta (Meu Drive…) não há "Baixar tudo": só a seleção
            if let itens, !itens.isEmpty, !especial || selecionando { barraInferior }
        }
        .task { await carregar() }
        .fullScreenCover(item: $previa) { p in
            PreviaDrive(itens: arquivos, inicio: p.id, baixar: { i, conv in baixar([i], titulo: i.nome, converter: conv) })
        }
        .alert("Aviso", isPresented: Binding(get: { aviso != nil }, set: { if !$0 { aviso = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(aviso ?? "") }
    }

    // MARK: conteúdo

    private var conteudo: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                resumo
                if temMidia && pastas.count < (itens?.count ?? 0) {
                    Picker("Mostrar", selection: $filtro) {
                        ForEach(Filtro.allCases, id: \.self) { f in Text(f.rawValue).tag(f) }
                    }
                    .pickerStyle(.segmented)
                }
                if emLista {
                    VStack(spacing: 0) {
                        ForEach(pastas) { p in linhaPasta(p) }
                        ForEach(Array(arquivos.enumerated()), id: \.element.id) { k, a in linhaArquivo(a, k) }
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                } else {
                    if !pastas.isEmpty {
                        VStack(spacing: 0) { ForEach(pastas) { p in linhaPasta(p) } }
                            .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], spacing: 6) {
                        ForEach(Array(arquivos.enumerated()), id: \.element.id) { k, a in celula(a, k) }
                    }
                }
            }
            .padding()
        }
    }

    private var resumo: some View {
        let todos = itens ?? []
        let n = todos.filter { !$0.ehPasta }.count
        let bytes = todos.reduce(Int64(0)) { $0 + ($1.tamanho ?? 0) }
        var partes: [String] = []
        if !pastas.isEmpty { partes.append(pastas.count == 1 ? "1 pasta" : "\(pastas.count) pastas") }
        if n > 0 { partes.append(n == 1 ? "1 arquivo" : "\(n) arquivos") }
        if bytes > 0 { partes.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        return Text(partes.joined(separator: " · ")).font(.subheadline).foregroundStyle(Tema.texto2)
    }

    private func linhaPasta(_ p: Drive.Item) -> some View {
        NavigationLink(value: p) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(Tema.acento)
                    .frame(width: 44, height: 44)
                Text(p.nome).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tema.texto2)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(selecionando)
        .opacity(selecionando ? 0.4 : 1)
    }

    private func linhaArquivo(_ a: Drive.Item, _ k: Int) -> some View {
        Button { tocar(a, k) } label: {
            HStack(spacing: 12) {
                MiniaturaDrive(item: a).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.nome).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    Text(detalhe(a)).font(.caption).foregroundStyle(Tema.texto2).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selecionando { marca(selecionados.contains(a.id)) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu { menuItem(a) }
    }

    private func celula(_ a: Drive.Item, _ k: Int) -> some View {
        Button { tocar(a, k) } label: {
            MiniaturaDrive(item: a)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if selecionando { marca(selecionados.contains(a.id)).padding(6) }
                }
                .overlay {
                    if selecionando && selecionados.contains(a.id) {
                        RoundedRectangle(cornerRadius: 10).stroke(Tema.acento, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu { menuItem(a) }
    }

    private func marca(_ sim: Bool) -> some View {
        Image(systemName: sim ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(sim ? Tema.acento : .white)
            .background(Circle().fill(.black.opacity(0.35)))
    }

    @ViewBuilder private func menuItem(_ a: Drive.Item) -> some View {
        Button("Baixar", systemImage: "arrow.down.circle") { baixar([a], titulo: a.nome, converter: false) }
        if a.ehMidia {
            Button("Baixar e converter", systemImage: "arrow.triangle.2.circlepath") { baixar([a], titulo: a.nome, converter: true) }
        }
        Button("Copiar link", systemImage: "link") { UIPasteboard.general.string = a.linkWeb }
    }

    private var menuMais: some View {
        Menu {
            Picker("Exibir", selection: $emLista) {
                Label("Grade", systemImage: "square.grid.2x2").tag(false)
                Label("Lista", systemImage: "list.bullet").tag(true)
            }
            Divider()
            if !pastas.isEmpty && !especial {
                Button("Baixar tudo, com as subpastas", systemImage: "square.and.arrow.down.on.square") { baixarComSubpastas() }
            }
            if pasta.ehPasta && !especial {
                Button("Copiar link da pasta", systemImage: "link") { UIPasteboard.general.string = pasta.linkWeb }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    // MARK: barra de baixo

    @ViewBuilder private var barraInferior: some View {
        let lista = selecionando ? escolhidos : (itens ?? []).filter { !$0.ehPasta }
        let bytes = lista.reduce(Int64(0)) { $0 + ($1.tamanho ?? 0) }
        let midias = lista.filter(\.ehMidia).count
        VStack(spacing: 10) {
            HStack {
                if selecionando {
                    Text(lista.isEmpty ? "Toque para escolher" : "\(lista.count) selecionado\(lista.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    let visiveis = arquivos.map(\.id)
                    let todosMarcados = !visiveis.isEmpty && visiveis.allSatisfy { selecionados.contains($0) }
                    Button(todosMarcados ? "Nenhum" : "Tudo") {
                        if todosMarcados { selecionados.subtract(visiveis) } else { selecionados.formUnion(visiveis) }
                    }
                    .buttonStyle(.glass)
                } else if listando {
                    ProgressView(); Text("Listando as subpastas…").font(.subheadline)
                    Spacer()
                } else {
                    Text(lista.isEmpty ? "Só subpastas aqui" : "\(lista.count) arquivo\(lista.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.subheadline).foregroundStyle(Tema.texto2)
                    Spacer()
                }
            }
            if !lista.isEmpty && !listando {
                HStack(spacing: 10) {
                    Button {
                        baixar(lista, titulo: tituloDownload(lista), converter: false)
                    } label: {
                        Label(selecionando ? "Baixar" : "Baixar tudo", systemImage: "arrow.down.circle.fill")
                            .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent).tint(Tema.acento)
                    if midias > 0 {
                        Button {
                            baixar(lista, titulo: tituloDownload(lista), converter: true)
                        } label: {
                            Label("E converter", systemImage: "arrow.triangle.2.circlepath").padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal).padding(.bottom, 6)
    }

    // MARK: ações

    private func carregar() async {
        guard itens == nil else { return }
        if !pasta.ehPasta { itens = [pasta]; return }
        do { itens = try await Drive.listar(pasta) }
        catch { erro = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func tocar(_ a: Drive.Item, _ k: Int) {
        if selecionando {
            if selecionados.contains(a.id) { selecionados.remove(a.id) } else { selecionados.insert(a.id) }
        } else {
            previa = Previa(id: k)
        }
    }

    private func tituloDownload(_ lista: [Drive.Item]) -> String {
        if lista.count == 1 { return lista[0].nome }
        return pasta.ehPasta ? "\(pasta.nome) (\(lista.count))" : "\(lista.count) arquivos"
    }

    private func baixar(_ lista: [Drive.Item], titulo: String, converter: Bool) {
        estudio.baixarDrive(lista, titulo: titulo, converterDepois: converter)
        fechar()
    }

    private func baixarComSubpastas() {
        listando = true
        Task {
            do {
                let tudo = try await Drive.listarTudo(pasta)
                listando = false
                if tudo.isEmpty { aviso = "Não há arquivos nas subpastas."; return }
                baixar(tudo, titulo: pasta.nome + " (com subpastas)", converter: false)
            } catch {
                listando = false
                aviso = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func detalhe(_ a: Drive.Item) -> String {
        var p: [String] = []
        if let t = a.tamanho { p.append(ByteCountFormatter.string(fromByteCount: t, countStyle: .file)) }
        if let w = a.largura, let h = a.altura { p.append("\(w)×\(h)") }
        if let d = formatarDuracao(a.duracao) { p.append(d) }
        if a.ehDocGoogle { p.append("vira PDF") }
        if let m = a.modificado { p.append(m.formatted(date: .abbreviated, time: .omitted)) }
        return p.joined(separator: " · ")
    }
}

// MARK: - miniatura

struct MiniaturaDrive: View {
    let item: Drive.Item

    var body: some View {
        Color.white.opacity(0.06)
            .overlay {
                if item.ehPasta || (!item.ehMidia && item.miniaturaLink == nil) {
                    icone
                } else {
                    ImagemDrive(principal: item.miniatura, reserva: item.miniaturaReserva(400), preencher: true) { icone }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.ehVideo {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        if let d = formatarDuracao(item.duracao) { Text(d) }
                    }
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(5)
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .contentShape(.rect)
    }

    private var icone: some View {
        Image(systemName: DriveIcone.de(item)).font(.title2).foregroundStyle(Tema.texto2)
    }
}

/// Imagem do Drive: tenta o thumbnailLink da API e, se não abrir, o endereço público.
struct ImagemDrive<Falha: View>: View {
    let principal: URL?
    let reserva: URL?
    var preencher: Bool
    @ViewBuilder var falha: Falha
    @State private var imagem: UIImage?
    @State private var falhou = false

    var body: some View {
        Group {
            if let imagem {
                if preencher { Image(uiImage: imagem).resizable().scaledToFill() }
                else { Image(uiImage: imagem).resizable().scaledToFit() }
            } else if falhou {
                falha
            } else {
                ProgressView()
            }
        }
        .task(id: principal) {
            if let i = await ImagensDrive.carregar(principal, reserva) { imagem = i } else { falhou = true }
        }
    }
}

/// Miniaturas do Drive: thumbnailLink (com o login, se houver) e, se não abrir, o endereço público.
enum ImagensDrive {
    private static let cache = NSCache<NSURL, UIImage>()

    static func carregar(_ principal: URL?, _ reserva: URL?) async -> UIImage? {
        for (u, comLogin) in [(principal, true), (reserva, false)] {
            guard let u else { continue }
            if let i = cache.object(forKey: u as NSURL) { return i }
            var r = URLRequest(url: u)
            if comLogin, let t = try? await ContaGoogle.shared.tokenAcesso() {
                r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            }
            guard let resposta = try? await URLSession.shared.data(for: r),
                  (resposta.1 as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let d = resposta.0
            guard let i = await Task.detached(operation: { UIImage(data: d)?.preparingForDisplay() }).value else { continue }
            cache.setObject(i, forKey: u as NSURL)
            return i
        }
        return nil
    }
}

enum DriveIcone {
    static func de(_ i: Drive.Item) -> String {
        if i.ehPasta { return "folder.fill" }
        if i.ehVideo { return "film" }
        if i.ehImagem { return "photo" }
        if i.mime.hasPrefix("audio/") { return "waveform" }
        if i.mime == "application/pdf" || i.ehDocGoogle { return "doc.richtext" }
        if i.mime.contains("zip") || i.mime.contains("compressed") { return "doc.zipper" }
        return "doc"
    }
}

// MARK: - prévia em tela cheia

struct PreviaDrive: View {
    let itens: [Drive.Item]
    var baixar: (Drive.Item, Bool) -> Void
    @State private var atual: Int
    @State private var mostrarInfo = true
    @Environment(\.dismiss) private var fechar

    init(itens: [Drive.Item], inicio: Int, baixar: @escaping (Drive.Item, Bool) -> Void) {
        self.itens = itens
        self.baixar = baixar
        _atual = State(initialValue: min(max(0, inicio), max(0, itens.count - 1)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !itens.isEmpty {
                TabView(selection: $atual) {
                    ForEach(Array(itens.enumerated()), id: \.element.id) { k, i in
                        PaginaDrive(item: i, ativa: k == atual)
                            .tag(k)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button { fechar() } label: { Image(systemName: "xmark").font(.headline).padding(10) }
                    .buttonStyle(.glass)
                Spacer()
                if itens.count > 1 {
                    Text("\(atual + 1) de \(itens.count)").font(.subheadline.monospacedDigit())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                }
                Spacer()
                HStack(spacing: 8) {
                    // (i): mostra/oculta a caixa de informações (embaixo ficam os controles do vídeo)
                    Button { withAnimation(.snappy) { mostrarInfo.toggle() } } label: {
                        Image(systemName: mostrarInfo ? "info.circle.fill" : "info.circle").font(.headline).padding(10)
                    }
                    .buttonStyle(.glass)
                    if itens.indices.contains(atual) {
                        ShareLink(item: URL(string: itens[atual].linkWeb)!) {
                            Image(systemName: "link").font(.headline).padding(10)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(.horizontal)
        }
        .overlay(alignment: .bottom) {
            if mostrarInfo, itens.indices.contains(atual) { painel(itens[atual]) }
        }
        .preferredColorScheme(.dark)
    }

    private func painel(_ i: Drive.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(i.nome).font(.headline).lineLimit(2)
            VStack(alignment: .leading, spacing: 3) {
                if let t = i.tamanho { Label(ByteCountFormatter.string(fromByteCount: t, countStyle: .file), systemImage: "internaldrive") }
                if let w = i.largura, let h = i.altura { Label("\(w) × \(h)", systemImage: "aspectratio") }
                if let d = formatarDuracao(i.duracao) { Label(d, systemImage: "clock") }
                if let m = i.modificado {
                    Label(m.formatted(date: .abbreviated, time: .shortened) + (i.modificadoPor.map { " · \($0)" } ?? ""),
                          systemImage: "calendar")
                }
                if i.ehDocGoogle { Label("Documento do Google: baixa como PDF", systemImage: "doc.richtext") }
            }
            .font(.caption).foregroundStyle(Tema.texto2)
            // um embaixo do outro: lado a lado o "Baixar e converter" era cortado
            VStack(spacing: 8) {
                Button { baixar(i, false); fechar() } label: {
                    Label("Baixar", systemImage: "arrow.down.circle.fill")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent).tint(Tema.acento)
                if i.ehMidia {
                    Button { baixar(i, true); fechar() } label: {
                        Label("Baixar e converter", systemImage: "arrow.triangle.2.circlepath")
                            .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal).padding(.bottom, 8)
    }
}

/// Uma página da prévia: foto (miniatura grande do Google) ou vídeo tocando direto do Drive.
struct PaginaDrive: View {
    let item: Drive.Item
    let ativa: Bool
    @State private var player: AVPlayer?
    @State private var erroVideo: String?
    @State private var preparando = false

    var body: some View {
        Group {
            if item.ehVideo {
                if let player {
                    VideoPlayer(player: player)
                } else if let erroVideo {
                    VStack(spacing: 10) {
                        MiniaturaDrive(item: item).frame(width: 220, height: 220)
                        Text(erroVideo).font(.footnote).foregroundStyle(Tema.texto2).multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ZStack {
                        ImagemDrive(principal: item.imagemGrande, reserva: item.miniaturaReserva(2000), preencher: false) { Color.clear }
                        ProgressView()
                    }
                }
            } else if item.ehImagem {
                ImagemDrive(principal: item.imagemGrande, reserva: item.miniaturaReserva(2000), preencher: false) {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(Tema.texto2)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: DriveIcone.de(item)).font(.system(size: 64)).foregroundStyle(Tema.texto2)
                    Text("Sem prévia para este tipo de arquivo.").font(.footnote).foregroundStyle(Tema.texto2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: ativa, initial: true) { _, sim in
            if sim { prepararVideo() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }

    private func prepararVideo() {
        guard item.ehVideo, player == nil, erroVideo == nil else { player?.play(); return }
        guard !preparando else { return }
        preparando = true
        Task {
            defer { preparando = false }
            guard let r = try? await Drive.conteudo(item), let u = r.url else { erroVideo = "Não deu para tocar este vídeo."; return }
            tocar(r, u)
        }
    }

    private func tocar(_ r: URLRequest, _ u: URL) {
        guard ativa else { return }
        var opcoes: [String: Any] = [:]
        if let h = r.allHTTPHeaderFields, !h.isEmpty { opcoes["AVURLAssetHTTPHeaderFieldsKey"] = h }
        let p = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: u, options: opcoes)))
        player = p
        p.play()
        Task {
            try? await Task.sleep(for: .seconds(8))
            if p.currentItem?.status == .failed {
                player = nil
                erroVideo = "O Drive não deixou tocar direto (\(p.currentItem?.error?.localizedDescription ?? "formato")). Baixe para assistir."
            }
        }
    }
}

// MARK: - resultado (Resultados › Google Drive)

struct PainelResultadoDrive: View {
    @Environment(Estudio.self) private var estudio
    let item: Item
    @Binding var aviso: String?
    var salvarNoFotos: (Item) -> Void

    private var imagens: [String] { item.arquivos.filter { ehImagem(item.url($0)) } }
    private var videos: [String] { item.arquivos.filter { ehVideoArquivo(item.url($0)) } }
    private var outros: [String] { item.arquivos.filter { !ehImagem(item.url($0)) && !ehVideoArquivo(item.url($0)) } }

    var body: some View {
        Cartao {
            if let r = item.resumo, !r.isEmpty {
                Label(r, systemImage: r.hasPrefix("Não baixei") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(r.hasPrefix("Não baixei") ? .yellow : Tema.texto2)
            }
            if !videos.isEmpty || !imagens.isEmpty {
                let n = videos.count + imagens.count
                Button {
                    estudio.importarVarios((videos + imagens).map { item.url($0) })
                } label: {
                    Label(textoConverter, systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent).tint(Tema.acento)
                Button { salvarNoFotos(item) } label: {
                    Label(n == 1 ? "Salvar no Fotos" : "Salvar as \(n) no Fotos", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            }
            ShareLink(items: item.arquivos.map { item.url($0) }) {
                Label(item.arquivos.count == 1 ? "Compartilhar / Salvar em Arquivos" : "Compartilhar os \(item.arquivos.count) / Salvar em Arquivos",
                      systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.glass)
        }
        if !videos.isEmpty {
            Cartao(titulo: videos.count == 1 ? "Vídeo" : "\(videos.count) vídeos", icone: "film.stack") {
                GradeVideos(item: copia(videos))
            }
        }
        if !imagens.isEmpty {
            Cartao(titulo: imagens.count == 1 ? "Imagem" : "\(imagens.count) imagens", icone: "photo.on.rectangle") {
                GradeImagens(item: copia(imagens))
            }
        }
        if !outros.isEmpty {
            Cartao(titulo: outros.count == 1 ? "Outro arquivo" : "\(outros.count) outros arquivos", icone: "folder.fill") {
                ForEach(outros, id: \.self) { nome in LinhaArquivo(url: item.url(nome), aviso: $aviso) }
            }
        }
    }

    private var textoConverter: String {
        switch (videos.count, imagens.count) {
        case (0, 1): return "Converter a imagem"
        case (0, let i): return "Converter as \(i) imagens"
        case (1, 0): return "Converter o vídeo"
        case (let v, 0): return "Converter os \(v) vídeos"
        default: return "Converter vídeos e imagens"
        }
    }

    private func copia(_ nomes: [String]) -> Item {
        var c = item
        c.arquivos = nomes
        return c
    }
}
