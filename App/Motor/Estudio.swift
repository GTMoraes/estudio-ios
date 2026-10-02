import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// O que chegou para ser processado (compartilhar, "Abrir com", colar link, escolher arquivo).
enum Entrada: Identifiable, Equatable {
    case link(String)
    case arquivo(URL, nome: String)
    case imagens([URL])
    case videos([URL])            // vários áudios/vídeos: um lote do conversor
    case drive(String)            // link do Google Drive

    var id: String {
        switch self {
        case .link(let l): return "link:" + l
        case .arquivo(let u, _): return "arq:" + u.path
        case .imagens(let us): return "img:\(us.count):" + (us.first?.path ?? "")
        case .videos(let us): return "vid:\(us.count):" + (us.first?.path ?? "")
        case .drive(let l): return "drive:" + l
        }
    }
}

/// Arquivo de imagem? (pela extensão; HEIC, JPG, PNG, WebP, AVIF, TIFF…)
func ehImagem(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
}

func ehVideoArquivo(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
}

/// Estado do app e quem executa os trabalhos (no iPhone ou na nuvem).
@MainActor
@Observable
final class Estudio {
    let historico = Historico()
    let nuvem = Nuvem.shared

    var entrada: Entrada?
    private var fila: [Entrada] = []
    private var tarefas: [UUID: Task<Void, Never>] = [:]
    var abaSelecionada = 0
    /// Sobe a cada trabalho novo: a aba Resultados volta para a lista (sai do detalhe aberto).
    var trabalhosCriados = 0
    var logado = Credenciais.ler() != nil

    static var pastaRecebidos: URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("Recebidos", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: - ajustes

    var idioma: String { UserDefaults.standard.string(forKey: "idioma") ?? "pt" }
    var modeloLocal: String { UserDefaults.standard.string(forKey: "modeloLocal") ?? TranscritorLocal.modeloPadrao }
    var nuvemPorPadrao: Bool { UserDefaults.standard.bool(forKey: "nuvemPorPadrao") }

    // MARK: - entradas

    func receber(_ e: Entrada) {
        var e = e
        // link do Google Drive: abre o navegador do Drive (não a nuvem)
        if case .link(let l) = e, Drive.ehDrive(l) { e = .drive(l) }
        if entrada == nil { entrada = e } else { fila.append(e) }
    }

    func entradaConcluida() {
        entrada = nil
        if !fila.isEmpty {
            let prox = fila.removeFirst()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)   // deixa a folha fechar
                self.entrada = prox
            }
        }
    }

    /// Lê o que a extensão de compartilhar deixou na caixa.
    func lerCaixa() {
        var imagens: [URL] = []
        var midias: [(URL, String)] = []
        for r in Caixa.pendentes() {
            switch r.tipo {
            case .link:
                if let l = r.link { receber(.link(l)) }
            case .arquivo:
                if let origem = Caixa.url(doArquivo: r) {
                    let destino = Nuvem.semColisao(Self.pastaRecebidos.appendingPathComponent(r.nome))
                    if (try? FileManager.default.moveItem(at: origem, to: destino)) != nil {
                        if ehImagem(destino) { imagens.append(destino) }      // várias fotos viram um lote só
                        else { midias.append((destino, r.nome)) }             // vários vídeos também
                    }
                }
            }
            Caixa.remover(r)
        }
        if !imagens.isEmpty { receber(.imagens(imagens)) }
        receberMidias(midias)
    }

    /// Um áudio/vídeo abre o conversor normal; vários viram um lote.
    private func receberMidias(_ m: [(URL, String)]) {
        if m.count == 1 { receber(.arquivo(m[0].0, nome: m[0].1)) }
        else if m.count > 1 { receber(.videos(m.map { $0.0 })) }
    }

    /// estudio://caixa (vindo da extensão) ou arquivo aberto com "Abrir com".
    func abrir(_ url: URL) {
        if url.scheme == "estudio" { lerCaixa(); return }
        guard url.isFileURL else { return }
        let acesso = url.startAccessingSecurityScopedResource()
        defer { if acesso { url.stopAccessingSecurityScopedResource() } }
        let destino = Nuvem.semColisao(Self.pastaRecebidos.appendingPathComponent(url.lastPathComponent))
        if (try? FileManager.default.copyItem(at: url, to: destino)) != nil {
            receber(ehImagem(destino) ? .imagens([destino]) : .arquivo(destino, nome: url.lastPathComponent))
        }
        // "Abrir com" deixa uma cópia em Documentos/Inbox (visível no app Arquivos): apaga
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
    }

    /// Arquivo escolhido dentro do app (Arquivos/Fotos): copia para a área do app.
    func importar(_ url: URL, nome: String? = nil) {
        let acesso = url.startAccessingSecurityScopedResource()
        defer { if acesso { url.stopAccessingSecurityScopedResource() } }
        let n = nome ?? url.lastPathComponent
        let destino = Nuvem.semColisao(Self.pastaRecebidos.appendingPathComponent(n))
        do {
            try FileManager.default.copyItem(at: url, to: destino)
            procedencias[destino.path] = procedencia(de: url, comAcesso: acesso)
            receber(.arquivo(destino, nome: n))
        } catch {
            aviso = "Não consegui abrir o arquivo: \(error.localizedDescription)"
        }
    }

    /// Vários arquivos de uma vez (Arquivos ou Galeria): as imagens viram um lote só.
    /// nomes: nome original de cada arquivo (a galeria entrega com nome temporário).
    /// origens: de onde veio cada arquivo, quando quem chama sabe (galeria); senão é deduzido (Arquivos, Resultados).
    func importarVarios(_ urls: [URL], nomes: [String]? = nil, origens: [Procedencia?]? = nil) {
        var imagens: [URL] = []
        var midias: [(URL, String)] = []
        for (k, u) in urls.enumerated() {
            let acesso = u.startAccessingSecurityScopedResource()
            defer { if acesso { u.stopAccessingSecurityScopedResource() } }
            let nome = nomes.map { k < $0.count ? $0[k] : u.lastPathComponent } ?? u.lastPathComponent
            let destino = Nuvem.semColisao(Self.pastaRecebidos.appendingPathComponent(nome))
            do {
                try FileManager.default.copyItem(at: u, to: destino)
                let dada: Procedencia? = origens.flatMap { k < $0.count ? $0[k] : nil }
                procedencias[destino.path] = dada ?? procedencia(de: u, comAcesso: acesso)
                if ehImagem(destino) { imagens.append(destino) } else { midias.append((destino, nome)) }
            } catch {
                aviso = "Não consegui abrir \(nome): \(error.localizedDescription)"
            }
        }
        if !imagens.isEmpty { receber(.imagens(imagens)) }
        receberMidias(midias)
    }

    var aviso: String?

    /// De onde veio cada arquivo recebido (pelo caminho em Recebidos): é o que permite ao
    /// "Editar novamente" buscar o original de volta sem o app guardar uma cópia.
    var procedencias: [String: Procedencia] = [:]

    private func procedencia(de url: URL, comAcesso: Bool) -> Procedencia? {
        // arquivo de um item de Resultados (ex.: baixado do Drive): Resultados/<id>/<nome>
        let partes = url.standardizedFileURL.pathComponents
        let raiz = Historico.pastaResultados.standardizedFileURL.pathComponents
        if partes.count == raiz.count + 2, Array(partes.prefix(raiz.count)) == raiz, let id = UUID(uuidString: partes[raiz.count]) {
            return Procedencia(tipo: .resultado, item: id, nome: partes[raiz.count + 1])
        }
        // escolhido no app Arquivos: um marcador que abre o mesmo arquivo depois
        if comAcesso, let m = try? url.bookmarkData() { return Procedencia(tipo: .arquivo, marcador: m, nome: url.lastPathComponent) }
        return nil
    }

    // MARK: - trabalhos

    private static func base(_ nome: String) -> String {
        let b = (nome as NSString).deletingPathExtension
        return Nuvem.limpar(b.isEmpty ? "arquivo" : b)
    }

    private func novoItem(_ tipo: Item.Tipo, _ titulo: String, nuvem: Bool, mensagem: String, base: String? = nil) -> UUID {
        var i = Item(tipo: tipo, titulo: titulo, naNuvem: nuvem)
        i.mensagem = mensagem
        i.baseSaida = base
        historico.adicionar(i)
        abaSelecionada = 1
        trabalhosCriados += 1          // Resultados volta para a lista
        return i.id
    }

    private func etapa(_ id: UUID, _ msg: String, _ p: Double? = nil) {
        historico.atualizar(id, salvarAgora: false) { $0.mensagem = msg; $0.progresso = p }
        SegundoPlano.shared.progresso(id, p, msg)
    }

    private func concluir(_ id: UUID, arquivos: [String], resumo: String? = nil, inicio: Date, duracao: Double? = nil) {
        guardarOriginais(id)
        historico.atualizar(id) {
            $0.estado = .pronto; $0.mensagem = nil; $0.progresso = nil
            $0.arquivos = arquivos; $0.resumo = resumo; $0.trabalho = nil
            $0.duracaoProcesso = Date().timeIntervalSince(inicio)
            if let duracao { $0.duracaoAudio = duracao }
            $0.retomada = nil
        }
        Trabalhos.apagar(id)
        atualizarTela()
    }

    /// Conversão (e legenda) pronta: guarda os ajustes usados para "Editar novamente". O original só
    /// fica guardado (em Originais/<id>) quando não há como buscá-lo de volta (veio pelo Compartilhar);
    /// os da galeria, do app Arquivos e de Resultados são buscados de novo na hora.
    private func guardarOriginais(_ id: UUID) {
        guard let r = historico.item(id)?.retomada,
              r.tipo == .conversao || r.tipo == .loteConversao || r.tipo == .legenda else { return }
        let destino = Originais.pasta(id)
        for (k, n) in r.entradas.enumerated() {
            let temOrigem = (r.procedencias.flatMap { k < $0.count ? $0[k] : nil }) != nil
            if temOrigem && r.tipo != .legenda { continue }        // a legenda fica com o vídeo à mão (o editor usa)
            try? FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: entrada(id, n), to: destino.appendingPathComponent(n))
        }
        historico.atualizar(id, salvarAgora: false) { $0.reedicao = r }
        limparOriginaisAntigos()
    }

    /// Limpeza automática, pelo prazo escolhido em Ajustes (indefinido = não apaga).
    func limparOriginaisAntigos() {
        if Originais.dias > 0 { limparOriginais(manterDias: Originais.dias) }
    }

    /// Apaga os vídeos guardados (nil = todos; N = mantém os dos últimos N dias). O projeto da
    /// legenda (texto e estilo) nunca é apagado aqui, só o vídeo.
    func limparOriginais(manterDias: Int?) {
        let limite = manterDias.map { Date().addingTimeInterval(-Double($0) * 86400) }
        let fm = FileManager.default
        for pasta in (try? fm.contentsOfDirectory(at: Originais.raiz, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: pasta.lastPathComponent), let item = historico.item(id) else {
                try? fm.removeItem(at: pasta); continue                 // sobra de um item já apagado
            }
            if let limite, item.criado >= limite { continue }
            for f in (try? fm.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension.lowercased() != "json" {              // os projetos de legenda ficam
                try? fm.removeItem(at: f)
            }
        }
    }

    /// Os originais de um item, na pasta Originais/<id>: os que não estão lá são buscados de volta
    /// (galeria, Arquivos, Resultados). Erro com explicação quando não dá.
    func garantirOriginais(_ id: UUID) async throws -> [URL] {
        guard let r = historico.item(id)?.reedicao, !r.entradas.isEmpty else {
            throw ErroApp("Este resultado não guardou os ajustes da conversão.")
        }
        var urls: [URL] = []
        for (k, n) in r.entradas.enumerated() {
            let alvo = Originais.arquivo(id, n)
            if !FileManager.default.fileExists(atPath: alvo.path) {
                guard let origem = r.procedencias.flatMap({ k < $0.count ? $0[k] : nil }) else {
                    throw ErroApp("A cópia do original (\(r.nomes.flatMap { k < $0.count ? $0[k] : nil } ?? r.nome)) já foi apagada do app. Escolha o arquivo de novo em Novo.")
                }
                try FileManager.default.createDirectory(at: Originais.pasta(id), withIntermediateDirectories: true)
                let resultado: URL? = origem.tipo == .resultado
                    ? origem.item.flatMap { historico.item($0) }.flatMap { i in origem.nome.map { i.url($0) } } : nil
                try await origem.trazer(para: alvo, arquivoDoResultado: resultado)
            }
            urls.append(alvo)
        }
        return urls
    }

    /// Ajustes guardados de uma conversão, entregues ao conversor quando o arquivo abre de novo.
    var ajustesGuardados: [String: AjusteConversao] = [:]

    /// "Editar novamente": abre o conversor com o original e os ajustes que foram usados.
    /// Devolve o motivo quando não dá (original apagado ou movido).
    func editarNovamente(_ id: UUID) async -> String? {
        let originais: [URL]
        do { originais = try await garantirOriginais(id) }
        catch { return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        guard let r = historico.item(id)?.reedicao else { return "Este resultado foi apagado." }
        // o conversor fica com o arquivo que recebe: trabalha numa cópia
        var copias: [URL] = []
        for (k, u) in originais.enumerated() {
            let nome = r.tipo == .loteConversao ? (r.nomes.flatMap { k < $0.count ? $0[k] : nil } ?? u.lastPathComponent) : r.nome
            let c = Nuvem.semColisao(Self.pastaRecebidos.appendingPathComponent(nome))
            let origem = r.procedencias.flatMap { k < $0.count ? $0[k] : nil }
            do {
                // buscado só para esta edição: vai direto para o conversor, sem deixar cópia guardada
                if origem != nil && r.tipo != .legenda { try FileManager.default.moveItem(at: u, to: c) }
                else { try FileManager.default.copyItem(at: u, to: c) }
            } catch { return "Não consegui abrir o original: \(error.localizedDescription)" }
            procedencias[c.path] = origem
            let o = r.tipo == .loteConversao ? r.conversoes.flatMap { k < $0.count ? $0[k] : nil } : r.conversao
            if let o { ajustesGuardados[c.path] = AjusteConversao(opcoes: o, selecao: "p:" + PresetConversao.personalizado.rawValue) }
            copias.append(c)
        }
        if copias.count == 1 { receber(.arquivo(copias[0], nome: copias[0].lastPathComponent)) }
        else { receber(.videos(copias)) }
        return nil
    }

    private func falhar(_ id: UUID, _ erro: Error) {
        let msg = (erro as? LocalizedError)?.errorDescription ?? erro.localizedDescription
        historico.atualizar(id) { $0.estado = .erro; $0.mensagem = msg; $0.progresso = nil }
        atualizarTela()
    }

    /// segundoPlano: título da Atividade ao Vivo (só trabalhos sem GPU: imagens e nuvem).
    /// recomecar: se falhar porque o app saiu da tela, espera ele voltar e recomeça (vídeo, transcrição).
    private func rodar(_ id: UUID, segundoPlano: String? = nil, recomecar: Bool = false,
                       _ corpo: @escaping @MainActor () async throws -> Void) {
        descartar.remove(id)
        if let titulo = segundoPlano {
            // o sistema (ou você, pela Atividade ao Vivo) encerrou o segundo plano: no iPhone, para e
            // fica para continuar; na nuvem, o trabalho segue lá e o app retoma ao voltar
            SegundoPlano.shared.iniciar(id, titulo: titulo) { [weak self] in
                guard let self, self.historico.item(id)?.naNuvem == false else { return }
                self.pausar(id)
            }
        }
        tarefas[id] = Task { @MainActor in
            var ok = false
            var tentativas = 0
            while true {
                let geracao = EstadoApp.shared.geracao
                do { try await corpo(); ok = true; break }
                catch is CancellationError { self.interrompido(id); break }
                catch {
                    if recomecar, tentativas < 3, EstadoApp.shared.geracao != geracao, !Task.isCancelled {
                        tentativas += 1
                        self.etapa(id, "Pausado: volte ao Estúdio para continuar")
                        await EstadoApp.shared.aguardarAtivo()
                        self.limparResultado(id)
                        continue
                    }
                    self.falhar(id, error)
                    break
                }
            }
            SegundoPlano.shared.terminar(id, ok: ok)
            self.liberarVez(id)
            self.tarefas[id] = nil
            self.atualizarTela()
        }
        atualizarTela()
    }

    /// Cancelado: pelo botão (descarta) ou pelo sistema (fica para continuar depois).
    private func interrompido(_ id: UUID) {
        let podeContinuar = !descartar.contains(id) && historico.item(id)?.retomada != nil && Trabalhos.existe(id)
        historico.atualizar(id) {
            $0.estado = .erro
            $0.progresso = nil
            $0.mensagem = podeContinuar ? "Interrompido. Toque em Continuar." : "Cancelado"
            if !podeContinuar { $0.retomada = nil }
        }
        if !podeContinuar { Trabalhos.apagar(id) }
        descartar.remove(id)
    }

    private func limparResultado(_ id: UUID) {
        guard let item = historico.item(id) else { return }
        try? FileManager.default.removeItem(at: item.pasta)
        try? FileManager.default.createDirectory(at: item.pasta, withIntermediateDirectories: true)
    }

    private var descartar = Set<UUID>()

    // --- fila do iPhone: um trabalho pesado por vez (dois modelos juntos estouram a memória
    // e disputam a GPU/Neural Engine). Os trabalhos na nuvem não entram na fila.
    private var filaLocal: [UUID] = []
    private var vezDe: UUID?

    /// Espera a vez de usar o iPhone. Cancelável (o Task.sleep lança ao cancelar).
    private func aguardarVez(_ id: UUID) async throws {
        if vezDe == id { return }
        if !filaLocal.contains(id) { filaLocal.append(id) }
        var ultimaPos = -1
        while true {
            try Task.checkCancellation()
            if vezDe == nil, filaLocal.first == id {
                filaLocal.removeFirst()
                vezDe = id
                return
            }
            let pos = (filaLocal.firstIndex(of: id) ?? 0) + (vezDe == nil ? 0 : 1)
            if pos != ultimaPos {
                ultimaPos = pos
                etapa(id, pos <= 1 ? "Na fila: começa quando o trabalho atual terminar"
                                   : "Na fila (\(pos)º): começa quando os anteriores terminarem")
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func liberarVez(_ id: UUID) {
        filaLocal.removeAll { $0 == id }
        if vezDe == id { vezDe = nil }
    }

    /// Cancelar pelo app: para e apaga o que estava guardado para continuar.
    func cancelar(_ id: UUID) {
        descartar.insert(id)
        tarefas[id]?.cancel()
        if tarefas[id] == nil, historico.item(id)?.retomada != nil {
            historico.atualizar(id) { $0.retomada = nil; $0.mensagem = "Cancelado" }
            Trabalhos.apagar(id)
        }
    }
    /// Parar sem descartar (sistema encerrou a tarefa em segundo plano).
    private func pausar(_ id: UUID) { tarefas[id]?.cancel() }
    func rodando(_ id: UUID) -> Bool { tarefas[id] != nil }

    /// Há trabalho rodando no iPhone (mostra o aviso para não sair do app).
    var processandoLocal: Bool {
        historico.itens.contains { !$0.naNuvem && $0.estado == .processando && tarefas[$0.id] != nil }
    }

    /// Tela sempre acesa enquanto houver trabalho no iPhone (fora da tela o iOS pausa o app).
    private func atualizarTela() {
        UIApplication.shared.isIdleTimerDisabled = processandoLocal
    }

    /// Trabalhos que o iOS interrompeu (app fechado): o aviso ao abrir oferece continuar.
    var interrompidos: [UUID] = []

    /// O app saiu ou voltou para a tela.
    func faseMudou(ativo: Bool) {
        EstadoApp.shared.mudar(ativo: ativo)
        if ativo {
            Notificacoes.limpar()
            return
        }
        let locais = historico.itens.filter { !$0.naNuvem && $0.estado == .processando && tarefas[$0.id] != nil }
        guard !locais.isEmpty else { return }
        // imagens e downloads do Drive seguem em segundo plano (Atividade ao Vivo)
        let seguem: (Item) -> Bool = { $0.tipo == .imagem || $0.tipo == .drive }
        if locais.allSatisfy(seguem) { return }
        for i in locais where !seguem(i) {
            historico.atualizar(i.id, salvarAgora: false) { $0.mensagem = "Pausado: volte ao Estúdio para continuar" }
        }
        Notificacoes.avisar("Processamento pausado",
                            "O Estúdio precisa ficar aberto para processar. Volte ao app para continuar de onde parou.")
    }

    /// Continua um trabalho interrompido, com o que ficou guardado.
    func continuar(_ id: UUID) {
        guard tarefas[id] == nil, let item = historico.item(id), let r = item.retomada else { return }
        guard Trabalhos.existe(id) else {
            historico.atualizar(id) { $0.retomada = nil; $0.mensagem = "Os arquivos de entrada não existem mais. Envie de novo." }
            return
        }
        interrompidos.removeAll { $0 == id }
        historico.atualizar(id) { $0.estado = .processando; $0.mensagem = "Continuando"; $0.progresso = nil }
        switch r.tipo {
        case .voz: executarVoz(id)
        case .conversao: executarConversao(id)
        case .imagens: executarImagens(id)
        case .transcricao: executarTranscricao(id)
        case .loteConversao: executarLote(id)
        case .drive: executarDrive(id)
        case .legenda: executarLegenda(id)
        }
    }

    /// Link que falhou: faz o mesmo pedido de novo (o item com erro sai da lista).
    func tentarDeNovo(_ id: UUID) {
        guard tarefas[id] == nil, let p = historico.item(id)?.pedidoLink else { return }
        historico.remover(id)
        switch p.acao {
        case .video: baixarLink(p.info, modo: "video", padrao: p.padrao)
        case .audio: baixarLink(p.info, modo: "audio", padrao: p.padrao)
        case .transcrever: transcreverLink(p.info, naNuvem: p.naNuvem, idioma: p.idioma, padrao: p.padrao)
        }
    }

    func continuarInterrompidos() {
        let ids = interrompidos
        interrompidos = []
        ids.forEach { continuar($0) }
    }

    /// Guarda a entrada na pasta de trabalho e o que é preciso para continuar depois.
    private func prepararTrabalho(_ id: UUID, _ arquivos: [URL], _ r: Retomada) -> Bool {
        var r = r
        do {
            r.entradas = try Trabalhos.guardar(id, arquivos)
        } catch {
            falhar(id, ErroApp("Não consegui guardar o arquivo para processar: \(error.localizedDescription)"))
            return false
        }
        historico.atualizar(id) { $0.retomada = r }
        Notificacoes.pedirPermissao()
        return true
    }

    private func entrada(_ id: UUID, _ nome: String) -> URL {
        Trabalhos.entradas(id).appendingPathComponent(nome)
    }

    // --- transcrição

    func transcrever(_ arquivo: URL, nome: String, naNuvem: Bool, idioma: String,
                     padrao: String = Renomear.padrao, data: Date = Date()) {
        let base = PadraoNome.base(nome, padrao: padrao, data: data)
        let id = novoItem(.transcricao, nome, nuvem: naNuvem, mensagem: naNuvem ? "Enviando para a nuvem" : "Preparando", base: base)
        let inicio = Date()
        if !naNuvem {
            let r = Retomada(tipo: .transcricao, entradas: [], nome: nome, base: base, data: data, idioma: idioma)
            if prepararTrabalho(id, [arquivo], r) { executarTranscricao(id) }
            return
        }
        rodar(id, segundoPlano: "Transcrição na nuvem") {
            do {
                let uid = try await self.nuvem.enviar(arquivo, nome: nome) { p in
                    Task { @MainActor in self.etapa(id, "Enviando para a nuvem", p) }
                }
                let job = try await self.nuvem.iniciarTranscricao(uploadID: uid, idioma: idioma)
                self.historico.atualizar(id) { $0.trabalho = job }
                let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
                try await self.guardarTranscricaoDaNuvem(id, r, base: base, inicio: inicio)
            }
            try? FileManager.default.removeItem(at: arquivo)
        }
    }

    private func executarTranscricao(_ id: UUID) {
        guard let r = historico.item(id)?.retomada, let nomeEntrada = r.entradas.first else { return }
        let arquivo = entrada(id, nomeEntrada)
        let base = r.base ?? Self.base(r.nome)
        let idioma = r.idioma ?? "pt"
        let inicio = Date()
        rodar(id, recomecar: true) {
            try await self.aguardarVez(id)
            let segs = try await TranscritorLocal.shared.transcrever(
                arquivo, modelo: self.modeloLocal, idioma: idioma == "auto" ? nil : idioma
            ) { msg, p in Task { @MainActor in self.etapa(id, msg, p) } }
            let dur = await AudioUtil.duracao(arquivo)
            try self.guardarTranscricao(id, segs, base: base, inicio: inicio, duracao: dur)
        }
    }

    // --- legenda (editor): transcreve guardando o tempo de cada palavra; o vídeo fica guardado

    func legendar(_ arquivo: URL, nome: String, idioma: String, preset: String, data: Date = Date()) {
        let id = novoItem(.legenda, nome, nuvem: false, mensagem: "Preparando", base: Self.base(nome))
        var r = Retomada(tipo: .legenda, entradas: [], nome: nome, base: Self.base(nome), data: data, idioma: idioma)
        r.falhas = [preset]                      // estilo pronto escolhido na entrada
        r.procedencias = [procedencias[arquivo.path]]
        if prepararTrabalho(id, [arquivo], r) { executarLegenda(id) }
    }

    private func executarLegenda(_ id: UUID) {
        guard let r = historico.item(id)?.retomada, let nomeEntrada = r.entradas.first else { return }
        let arquivo = entrada(id, nomeEntrada)
        let base = r.base ?? Self.base(r.nome)
        let idioma = r.idioma ?? "pt"
        let inicio = Date()
        rodar(id, recomecar: true) {
            try await self.aguardarVez(id)
            let segs = try await TranscritorLocal.shared.transcrever(
                arquivo, modelo: self.modeloLocal, idioma: idioma == "auto" ? nil : idioma
            ) { msg, p in Task { @MainActor in self.etapa(id, msg, p) } }
            var projeto = ProjetoLegenda.criar(segs)
            if projeto.palavras.isEmpty { throw ErroApp("Não encontrei fala nesse vídeo.") }
            if let p = PresetLegenda.achar(r.falhas?.first) { projeto.aplicar(p) }
            Originais.gravarProjeto(id, projeto)
            let dur = await AudioUtil.duracao(arquivo)
            guard let item = self.historico.item(id) else { return }
            try FileManager.default.createDirectory(at: item.pasta, withIntermediateDirectories: true)
            let nomes = try self.gravarArquivosDaLegenda(item, projeto, base: base)
            self.concluir(id, arquivos: nomes, resumo: String(projeto.textoCorrido.prefix(400)), inicio: inicio, duracao: dur)
            // terminou e não há outra folha aberta: já entra no editor
            if self.entrada == nil { self.abaSelecionada = 1; self.abrirLegenda = id }
        }
    }

    /// Legenda que acabou de ficar pronta: Resultados abre o item e o editor.
    var abrirLegenda: UUID?

    private func gravarArquivosDaLegenda(_ item: Item, _ p: ProjetoLegenda, base: String) throws -> [String] {
        let nomes = ["\(base).srt", "\(base).txt"]
        try p.srt.write(to: item.url(nomes[0]), atomically: true, encoding: .utf8)
        try p.textoCorrido.write(to: item.url(nomes[1]), atomically: true, encoding: .utf8)
        return nomes
    }

    /// Vídeo de um item de legenda (buscado de volta se a cópia local já saiu).
    func videoDaLegenda(_ id: UUID) async throws -> URL {
        guard let u = try await garantirOriginais(id).first else { throw ErroApp("O vídeo desta legenda não foi encontrado.") }
        return u
    }

    /// Editor fechado ou exportando: guarda o projeto e refaz o .srt/.txt com as correções.
    func salvarLegenda(_ id: UUID, _ p: ProjetoLegenda) {
        Originais.gravarProjeto(id, p)
        guard let item = historico.item(id), item.estado == .pronto else { return }
        let base = item.baseSaida ?? Self.base(item.titulo)
        if let nomes = try? gravarArquivosDaLegenda(item, p, base: base) {
            let outros = item.arquivos.filter { !nomes.contains($0) }
            historico.atualizar(id) { $0.arquivos = nomes + outros; $0.resumo = String(p.textoCorrido.prefix(400)) }
        }
    }

    /// Grava a legenda no vídeo. O resultado fica DENTRO do item da legenda, na lista "Edições
    /// legendadas" (a mais nova primeiro), com o projeto usado guardado ao lado para reabrir depois.
    /// Enquanto grava, o item mostra o progresso; se falhar ou for cancelado, ele volta ao normal.
    func exportarLegenda(_ id: UUID, _ p: ProjetoLegenda, opcoes: OpcoesConversao) async -> String? {
        guard let item = historico.item(id), item.estado == .pronto, tarefas[id] == nil else {
            return "Este item ainda está gravando outra edição. Espere terminar."
        }
        salvarLegenda(id, p)
        let original: URL
        do { original = try await videoDaLegenda(id) }
        catch { return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        let edicao = UUID()
        Originais.gravarProjeto(id, p, edicao: edicao)
        var o = opcoes
        o.legenda = p
        let base = (item.baseSaida ?? Self.base(item.titulo)) + "-legendado"
        let pasta = item.pasta
        let nomeOriginal = item.reedicao?.nome ?? item.titulo
        let aviso = "Gravando a legenda no vídeo"
        historico.atualizar(id) { $0.estado = .processando; $0.mensagem = aviso; $0.progresso = nil }
        rodar(id) {
            var falha: String?
            var gravado = false
            do {
                try await self.aguardarVez(id)
                while true {
                    let geracao = EstadoApp.shared.geracao
                    do {
                        self.etapa(id, aviso, 0)
                        let info = try await InfoMidia.ler(original)
                        var lux: Double?
                        if info.hdr != .sdr { lux = await DetalhesVideo.ambienteLux(original) }
                        let saida = try await ConversorVideo.converter(original, info: info, opcoes: o, pasta: pasta, base: base) { pr in
                            Task { @MainActor in self.etapa(id, aviso, pr) }
                        }
                        let nome = saida.lastPathComponent
                        let origem = OrigemMidia(nome: nomeOriginal, largura: info.largura, altura: info.altura,
                                                 bytes: info.tamanhoBytes, duracao: info.duracao, fps: info.fps,
                                                 codec: info.codecVideo, hdr: info.hdr.rawValue, dolbyVision: info.dolbyVision,
                                                 ambienteLux: lux, data: nil)
                        self.historico.atualizar(id) {
                            var lista = $0.edicoes ?? []
                            lista.insert(EdicaoLegenda(id: edicao, arquivo: nome, estilo: p.resumo), at: 0)
                            $0.edicoes = lista
                            var og = $0.origensMidia ?? [:]; og[nome] = origem; $0.origensMidia = og
                        }
                        gravado = true
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if EstadoApp.shared.geracao != geracao, !Task.isCancelled {
                            // o app saiu da tela no meio: espera voltar e grava de novo
                            self.etapa(id, "Pausado: volte ao Estúdio para continuar")
                            await EstadoApp.shared.aguardarAtivo()
                            continue
                        }
                        falha = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        break
                    }
                }
            } catch {
                // cancelado (pelo botão ou pelo sistema): o item só volta ao normal
            }
            if !gravado { Originais.apagarProjeto(id, edicao: edicao) }
            self.historico.atualizar(id) { $0.estado = .pronto; $0.mensagem = nil; $0.progresso = nil }
            if let falha { self.aviso = "Não consegui gravar a legenda no vídeo: \(falha)" }
        }
        return nil
    }

    /// Apaga um vídeo legendado (e o projeto guardado dele) do item da legenda.
    func apagarEdicao(_ id: UUID, _ edicao: EdicaoLegenda) {
        guard let item = historico.item(id) else { return }
        try? FileManager.default.removeItem(at: item.url(edicao.arquivo))
        Originais.apagarProjeto(id, edicao: edicao.id)
        historico.atualizar(id) {
            $0.edicoes = ($0.edicoes ?? []).filter { $0.id != edicao.id }
            $0.origensMidia?[edicao.arquivo] = nil
        }
    }

    private func guardarTranscricao(_ id: UUID, _ segs: [Segmento], base: String, inicio: Date, duracao: Double?) throws {
        guard let item = historico.item(id) else { return }
        let r = Legenda.resultado(segs)
        var nomes = ["\(base).txt"]
        try r.texto.write(to: item.url(nomes[0]), atomically: true, encoding: .utf8)
        if let srt = r.srt {
            nomes.append("\(base).srt")
            try srt.write(to: item.url(nomes[1]), atomically: true, encoding: .utf8)
        }
        concluir(id, arquivos: nomes, resumo: String(r.texto.prefix(400)), inicio: inicio, duracao: duracao)
    }

    private func guardarTranscricaoDaNuvem(_ id: UUID, _ r: [String: Any], base: String, inicio: Date) async throws {
        guard let item = historico.item(id) else { return }
        let texto = r["text"] as? String ?? ""
        var nomes = ["\(base).txt"]
        try texto.write(to: item.url(nomes[0]), atomically: true, encoding: .utf8)
        if let tid = r["id"] as? Int, (r["has_srt"] as? Bool) == true {
            etapa(id, "Baixando a legenda")
            let u = try await nuvem.baixar("api/transcripts/\(tid)/srt", para: item.pasta, nomePadrao: "\(base).srt") { _ in }
            let final = item.url("\(base).srt")
            if u != final, !FileManager.default.fileExists(atPath: final.path) { try? FileManager.default.moveItem(at: u, to: final) }
            nomes.append(FileManager.default.fileExists(atPath: final.path) ? final.lastPathComponent : u.lastPathComponent)
        }
        concluir(id, arquivos: nomes, resumo: String(texto.prefix(400)), inicio: inicio, duracao: r["audio_secs"] as? Double)
    }

    // --- tratar voz (no iPhone ou na nuvem)

    func tratarVoz(_ arquivo: URL, nome: String, opcoes: OpcoesVoz, quadra: Bool, naNuvem: Bool,
                   padrao: String = Renomear.padrao, data: Date = Date()) {
        let base = PadraoNome.base(nome, padrao: padrao, data: data)
        let personalizado = PadraoNome.personalizado(padrao)
        let id = novoItem(.voz, nome, nuvem: naNuvem, mensagem: naNuvem ? "Enviando para a nuvem" : "Preparando",
                          base: personalizado ? base : nil)
        let inicio = Date()
        if !naNuvem {
            let r = Retomada(tipo: .voz, entradas: [], nome: nome, base: base, data: data, voz: opcoes, quadra: quadra)
            if prepararTrabalho(id, [arquivo], r) { executarVoz(id) }
            return
        }
        rodar(id, segundoPlano: "Tratar voz na nuvem") {
            let uid = try await self.nuvem.enviar(arquivo, nome: nome) { p in
                Task { @MainActor in self.etapa(id, "Enviando para a nuvem", p) }
            }
            let job = try await self.nuvem.iniciarVoz(uploadID: uid, opcoes: opcoes)
            self.historico.atualizar(id) { $0.trabalho = job }
            let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
            try await self.guardarVozDaNuvem(id, r, inicio: inicio, base: personalizado ? base : nil)
            try? FileManager.default.removeItem(at: arquivo)
        }
    }

    /// Voz no iPhone. Pausa fora da tela (a GPU não roda em segundo plano) e, se o app for
    /// fechado, continua do último bloco de 5 min pronto (os intermediários ficam em Trabalhos/<id>/voz).
    private func executarVoz(_ id: UUID) {
        guard let r = historico.item(id)?.retomada, let voz = r.voz, let nomeEntrada = r.entradas.first else { return }
        let arquivo = entrada(id, nomeEntrada)
        let base = r.base ?? Self.base(r.nome)
        let quadra = r.quadra ?? false
        let inicio = Date()
        rodar(id) {
            try await self.aguardarVez(id)
            guard let item = self.historico.item(id) else { return }
            let res = try await VozLocal.tratar(arquivo, opcoes: OpcoesVozLocal(voz: voz, quadra: quadra),
                                                pasta: item.pasta, base: base,
                                                trabalho: Trabalhos.pasta(id).appendingPathComponent("voz", isDirectory: true)) { msg, p in
                Task { @MainActor in self.etapa(id, msg, p) }
            }
            self.concluir(id, arquivos: res.arquivos, inicio: inicio, duracao: res.duracao)
        }
    }

    /// base: nome de saída personalizado (os arquivos ficam base-mix-tratado.mp3 etc., como no iPhone).
    private func guardarVozDaNuvem(_ id: UUID, _ r: [String: Any], inicio: Date, base: String? = nil) async throws {
        guard let item = historico.item(id), let vid = r["id"] as? Int else { throw ErroApp("Resposta incompleta da nuvem.") }
        let tipos = (r["arquivos"] as? [String]) ?? ["mix", "voz", "trilha"]
        var nomes: [String] = []
        for (k, t) in tipos.enumerated() {
            var u = try await nuvem.baixar("api/voz/\(vid)/\(t)", para: item.pasta, nomePadrao: "\(t).mp3") { p in
                Task { @MainActor in self.etapa(id, "Baixando o resultado (\(k + 1) de \(tipos.count))", p) }
            }
            if let base {
                let sufixo = ["mix": "-mix-tratado", "voz": "-voz-tratada", "trilha": "-trilha-separada"][t] ?? "-\(t)"
                u = PadraoNome.renomear(u, base: base, sufixo: sufixo)
            }
            nomes.append(u.lastPathComponent)
        }
        concluir(id, arquivos: nomes, inicio: inicio, duracao: r["audio_secs"] as? Double)
    }

    // --- conversão (no iPhone)

    func converter(_ arquivo: URL, nome: String, info: InfoMidia, opcoes: OpcoesConversao,
                   padrao: String = Renomear.padrao, data: Date = Date()) {
        let tipo: Item.Tipo = opcoes.animado && info.temVideo ? .imagem
            : opcoes.acao == .audio || !info.temVideo ? .audio : .video
        let dims: (Int, Int)? = tipo == .audio ? nil : PlanoConversao.dimensoesSaida(info, opcoes)
        let base = PadraoNome.base(nome, padrao: padrao, data: opcoes.usarDataAtual && tipo != .audio ? Date() : data,
                                  largura: dims?.0, altura: dims?.1)
        let id = novoItem(tipo, nome, nuvem: false, mensagem: "Convertendo no iPhone")
        if info.temVideo && tipo == .video {
            historico.atualizar(id) {
                $0.origemMidia = OrigemMidia(nome: nome, largura: info.largura, altura: info.altura, bytes: info.tamanhoBytes,
                                             duracao: info.duracao, fps: info.fps, codec: info.codecVideo,
                                             hdr: info.hdr.rawValue, dolbyVision: info.dolbyVision, ambienteLux: nil, data: data)
            }
        }
        var r = Retomada(tipo: .conversao, entradas: [], nome: nome, base: base, data: data, conversao: opcoes)
        r.procedencias = [procedencias[arquivo.path]]
        if prepararTrabalho(id, [arquivo], r) { executarConversao(id) }
    }

    /// Conversão no iPhone. Se falhar porque o app saiu da tela, recomeça quando ele volta
    /// (o codificador de vídeo não permite continuar no meio).
    private func executarConversao(_ id: UUID) {
        guard let r = historico.item(id)?.retomada, let opcoes = r.conversao, let nomeEntrada = r.entradas.first else { return }
        let arquivo = entrada(id, nomeEntrada)
        let base = r.base ?? Self.base(r.nome)
        let inicio = Date()
        rodar(id, recomecar: true) {
            try await self.aguardarVez(id)
            guard let item = self.historico.item(id) else { return }
            let info = try await InfoMidia.ler(arquivo)
            if info.temVideo, item.origemMidia?.ambienteLux == nil, info.hdr != .sdr {
                let lux = await DetalhesVideo.ambienteLux(arquivo)
                self.historico.atualizar(id) { $0.origemMidia?.ambienteLux = lux }
            }
            let saida = try await ConversorVideo.converter(arquivo, info: info, opcoes: opcoes, pasta: item.pasta,
                                                           base: base) { p in
                Task { @MainActor in self.etapa(id, "Convertendo no iPhone", p) }
            }
            self.concluir(id, arquivos: [saida.lastPathComponent], inicio: inicio,
                          duracao: PlanoConversao.duracao(info, opcoes))
        }
    }

    // --- lote de vídeos (no iPhone): um trabalho só, com a galeria dos resultados

    struct VideoDoLote {
        var url: URL
        var nome: String
        var info: InfoMidia
        var opcoes: OpcoesConversao
        var data: Date
    }

    func converterLote(_ videos: [VideoDoLote], padrao: String) {
        guard !videos.isEmpty else { return }
        let todosAnimados = videos.allSatisfy { $0.opcoes.animado && $0.info.temVideo }
        let todosAudio = videos.allSatisfy { $0.opcoes.acao == .audio || !$0.info.temVideo }
        let tipo: Item.Tipo = todosAnimados ? .imagem : todosAudio ? .audio : .video
        let id = novoItem(tipo, "\(videos.count) \(todosAudio ? "áudios" : "vídeos")", nuvem: false, mensagem: "Convertendo no iPhone")
        var bases: [String] = []
        var usados = Set<String>()
        for v in videos {
            let dims: (Int, Int)? = v.info.temVideo && v.opcoes.acao != .audio ? PlanoConversao.dimensoesSaida(v.info, v.opcoes) : nil
            var b = PadraoNome.base(v.nome, padrao: padrao, data: v.opcoes.usarDataAtual ? Date() : v.data,
                                    largura: dims?.0, altura: dims?.1)
            // dois vídeos com o mesmo nome de saída: numera
            var n = 2
            let original = b
            while usados.contains(b.lowercased()) { b = "\(original) (\(n))"; n += 1 }
            usados.insert(b.lowercased())
            bases.append(b)
        }
        historico.atualizar(id) { $0.origensMidia = [:] }
        var r = Retomada(tipo: .loteConversao, entradas: [], nome: "\(videos.count) vídeos")
        r.saidas = Array(repeating: nil, count: videos.count)
        r.falhas = []
        r.conversoes = videos.map { $0.opcoes }
        r.bases = bases
        r.nomes = videos.map { $0.nome }
        r.datas = videos.map { $0.data }
        r.procedencias = videos.map { procedencias[$0.url.path] }
        if prepararTrabalho(id, videos.map { $0.url }, r) { executarLote(id) }
    }

    /// Converte os vídeos do lote um por um. Se o app sair da tela no meio de um, espera voltar
    /// e refaz aquele; se for fechado, "Continuar" pula os que já ficaram prontos.
    private func executarLote(_ id: UUID) {
        guard let r0 = historico.item(id)?.retomada, let conv = r0.conversoes else { return }
        let total = r0.entradas.count
        let inicio = Date()
        rodar(id) {
            try await self.aguardarVez(id)
            guard let item = self.historico.item(id) else { return }
            try FileManager.default.createDirectory(at: item.pasta, withIntermediateDirectories: true)
            var duracaoTotal = 0.0
            for k in 0..<total {
                try Task.checkCancellation()
                guard let r = self.historico.item(id)?.retomada else { return }
                if let feita = r.saidas?[k] ?? nil, !feita.isEmpty { continue }
                let u = self.entrada(id, r.entradas[k])
                let nomeOriginal = r.nomes?[k] ?? r.entradas[k]
                let base = r.bases?[k] ?? Self.base(nomeOriginal)
                let opcoes = conv[k]
                while true {
                    let geracao = EstadoApp.shared.geracao
                    do {
                        self.etapa(id, "Convertendo \(k + 1) de \(total)", Double(k) / Double(total))
                        let info = try await InfoMidia.ler(u)
                        var lux: Double?
                        if info.temVideo && info.hdr != .sdr { lux = await DetalhesVideo.ambienteLux(u) }
                        let saida = try await ConversorVideo.converter(u, info: info, opcoes: opcoes, pasta: item.pasta, base: base) { p in
                            Task { @MainActor in
                                self.etapa(id, "Convertendo \(k + 1) de \(total)", (Double(k) + p) / Double(total))
                            }
                        }
                        duracaoTotal += PlanoConversao.duracao(info, opcoes)
                        let nome = saida.lastPathComponent
                        let origem = OrigemMidia(nome: nomeOriginal, largura: info.largura, altura: info.altura,
                                                 bytes: info.tamanhoBytes, duracao: info.duracao, fps: info.fps,
                                                 codec: info.codecVideo, hdr: info.hdr.rawValue, dolbyVision: info.dolbyVision,
                                                 ambienteLux: lux, data: r.datas?[k])
                        self.historico.atualizar(id) {
                            $0.retomada?.saidas?[k] = nome
                            var o = $0.origensMidia ?? [:]; o[nome] = origem; $0.origensMidia = o
                        }
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if EstadoApp.shared.geracao != geracao, !Task.isCancelled {
                            // saiu da tela no meio deste vídeo: espera voltar e refaz só ele
                            self.etapa(id, "Pausado: volte ao Estúdio para continuar")
                            await EstadoApp.shared.aguardarAtivo()
                            self.apagarSobras(id)
                            continue
                        }
                        self.apagarSobras(id)
                        let msg = "\(nomeOriginal): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                        self.historico.atualizar(id) {
                            $0.retomada?.saidas?[k] = ""
                            $0.retomada?.falhas?.append(msg)
                        }
                        break
                    }
                }
            }
            let fim = self.historico.item(id)?.retomada
            let nomes = (fim?.saidas ?? []).compactMap { $0 }.filter { !$0.isEmpty }
            let falhas = fim?.falhas ?? []
            if nomes.isEmpty { throw ErroApp(falhas.first ?? "Nenhum vídeo convertido.") }
            self.concluir(id, arquivos: nomes,
                          resumo: falhas.isEmpty ? nil : "Não converti \(falhas.count): " + falhas.joined(separator: "; "),
                          inicio: inicio, duracao: duracaoTotal > 0 ? duracaoTotal : nil)
        }
    }

    /// Apaga da pasta do resultado o que não é saída pronta (arquivo pela metade de uma tentativa).
    private func apagarSobras(_ id: UUID) {
        guard let item = historico.item(id) else { return }
        let prontos = Set((item.retomada?.saidas ?? []).compactMap { $0 })
        let arquivos = (try? FileManager.default.contentsOfDirectory(atPath: item.pasta.path)) ?? []
        for a in arquivos where !prontos.contains(a) {
            try? FileManager.default.removeItem(at: item.pasta.appendingPathComponent(a))
        }
    }

    // --- Google Drive: baixar (direto do Google para o iPhone)

    /// Pasta (ou arquivo) do Drive aberta pelo link: fica em Resultados para abrir de novo.
    /// Se já estava lá, sobe para o topo.
    func lembrarDrive(_ d: Drive.Item) {
        let velhos = historico.itens.filter { $0.tipo == .pastaDrive && $0.pastaDrive?.id == d.id }.map(\.id)
        velhos.forEach { historico.remover($0) }
        var n = Item(tipo: .pastaDrive, titulo: d.nome, naNuvem: false)
        n.estado = .pronto
        n.pastaDrive = d
        n.resumo = d.ehPasta ? "Pasta do Google Drive · toque para abrir" : "Arquivo do Google Drive · toque para abrir"
        historico.adicionar(n)
    }

    func baixarDrive(_ itens: [Drive.Item], titulo: String, converterDepois: Bool = false) {
        let arquivos = itens.filter { !$0.ehPasta }
        guard !arquivos.isEmpty else { return }
        let id = novoItem(.drive, "Drive: " + titulo, nuvem: false, mensagem: "Baixando do Drive")
        var r = Retomada(tipo: .drive, entradas: [], nome: titulo)
        r.drive = arquivos
        r.saidas = Array(repeating: nil, count: arquivos.count)
        r.falhas = []
        r.converterDepois = converterDepois
        historico.atualizar(id) { $0.retomada = r }
        // não há entrada local; a pasta de trabalho só marca que dá para continuar
        try? FileManager.default.createDirectory(at: Trabalhos.entradas(id), withIntermediateDirectories: true)
        executarDrive(id)
    }

    /// Um arquivo por vez; segue fora da tela (só rede). "Continuar" pula os já baixados.
    private func executarDrive(_ id: UUID) {
        guard let r0 = historico.item(id)?.retomada, let lista = r0.drive else { return }
        let total = lista.count
        let bytesTotal = lista.reduce(Int64(0)) { $0 + ($1.tamanho ?? 0) }
        let inicio = Date()
        rodar(id, segundoPlano: total == 1 ? "Baixando do Drive" : "Baixando \(total) arquivos do Drive") {
            guard let item = self.historico.item(id) else { return }
            try FileManager.default.createDirectory(at: item.pasta, withIntermediateDirectories: true)
            var feitos: Int64 = lista.enumerated().reduce(0) { t, e in
                let pronto = (r0.saidas?[e.offset] ?? nil).map { !$0.isEmpty } ?? false
                return t + (pronto ? (e.element.tamanho ?? 0) : 0)
            }
            let fmt = ByteCountFormatter()
            for (k, d) in lista.enumerated() {
                try Task.checkCancellation()
                guard let r = self.historico.item(id)?.retomada else { return }
                if let feita = r.saidas?[k] ?? nil, !feita.isEmpty { continue }
                let destino = Nuvem.semColisao(item.pasta.appendingPathComponent(Nuvem.limpar(d.nomeArquivo)))
                let antes = feitos
                do {
                    try await Drive.baixar(d, para: destino) { b in
                        Task { @MainActor in
                            let agora = antes + b
                            let frac = bytesTotal > 0 ? Double(agora) / Double(bytesTotal) : Double(k) / Double(total)
                            self.etapa(id, "Baixando \(k + 1) de \(total) · \(fmt.string(fromByteCount: agora)) de \(fmt.string(fromByteCount: bytesTotal))", min(1, frac))
                        }
                    }
                    feitos += d.tamanho ?? 0
                    self.historico.atualizar(id) { $0.retomada?.saidas?[k] = destino.lastPathComponent }
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: destino)
                    throw CancellationError()
                } catch let e as URLError where e.code == .cancelled {
                    try? FileManager.default.removeItem(at: destino)
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: destino)
                    let msg = "\(d.nome): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    self.historico.atualizar(id) {
                        $0.retomada?.saidas?[k] = ""
                        $0.retomada?.falhas?.append(msg)
                    }
                }
            }
            let fim = self.historico.item(id)?.retomada
            let nomes = (fim?.saidas ?? []).compactMap { $0 }.filter { !$0.isEmpty }
            let falhas = fim?.falhas ?? []
            let converter = fim?.converterDepois ?? false
            if nomes.isEmpty { throw ErroApp(falhas.first ?? "Nada foi baixado.") }
            self.concluir(id, arquivos: nomes,
                          resumo: falhas.isEmpty ? "\(fmt.string(fromByteCount: feitos)) · baixado em \(formatarDuracao(Date().timeIntervalSince(inicio)) ?? "—")"
                                                 : "Não baixei \(falhas.count): " + falhas.joined(separator: "; "),
                          inicio: inicio)
            if converter, let it = self.historico.item(id) {
                // só fotos, vídeos e áudios vão para o conversor
                let midias = lista.enumerated().compactMap { e -> URL? in
                    guard let n = fim?.saidas?[e.offset] ?? nil, !n.isEmpty,
                          e.element.ehMidia || e.element.mime.hasPrefix("audio/") else { return nil }
                    return it.url(n)
                }
                if !midias.isEmpty { self.importarVarios(midias) }
            }
        }
    }

    // --- imagens (no iPhone)

    func converterImagens(_ arquivos: [URL], opcoes: OpcoesImagem) {
        let titulo = arquivos.count == 1 ? arquivos[0].lastPathComponent : "\(arquivos.count) imagens"
        let id = novoItem(.imagem, titulo, nuvem: false, mensagem: "Convertendo no iPhone")
        var r = Retomada(tipo: .imagens, entradas: [], nome: titulo, imagem: opcoes)
        r.saidas = Array(repeating: nil, count: arquivos.count)
        r.falhas = []
        if prepararTrabalho(id, arquivos, r) { executarImagens(id) }
    }

    /// Imagens no iPhone: seguem em segundo plano (só processador). Se o app for fechado,
    /// continuar pula as que já ficaram prontas.
    private func executarImagens(_ id: UUID) {
        guard let r0 = historico.item(id)?.retomada, let opcoes = r0.imagem else { return }
        let total = r0.entradas.count
        let inicio = Date()
        rodar(id, segundoPlano: total == 1 ? "Convertendo 1 imagem" : "Convertendo \(total) imagens") {
            try await self.aguardarVez(id)
            guard let item = self.historico.item(id) else { return }
            try FileManager.default.createDirectory(at: item.pasta, withIntermediateDirectories: true)
            for k in 0..<total {
                try Task.checkCancellation()
                guard let r = self.historico.item(id)?.retomada else { return }
                if let feita = r.saidas?[k] ?? nil, !feita.isEmpty { continue }
                let u = self.entrada(id, r.entradas[k])
                self.etapa(id, "Convertendo \(k + 1) de \(total)", Double(k) / Double(total))
                let pasta = item.pasta
                let jaUsados = Set((r.saidas ?? []).compactMap { $0?.lowercased() })
                do {
                    let (nome, origem): (String, OrigemImagem) = try await Task.detached(priority: .userInitiated) {
                        guard let info = ConversorImagem.info(u) else { throw ErroApp("não é uma imagem que o iPhone lê") }
                        let formato = ConversorImagem.formatoFinal(opcoes, tipoOriginal: info.tipo)
                        let (l, a) = GeometriaImagem.tamanhoFinal(info.largura, info.altura, opcoes)
                        let base = Renomear.aplicar(opcoes.padraoNome, nome: (u.lastPathComponent as NSString).deletingPathExtension,
                                                    indice: k + 1, largura: l, altura: a,
                                                    data: opcoes.usarDataAtual ? Date() : info.data, digitos: opcoes.digitosContador)
                        let bytes = ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? 0
                        let origem = OrigemImagem(nome: u.lastPathComponent, largura: info.largura, altura: info.altura,
                                                  bytes: bytes, tipo: info.tipo, data: info.data)
                        let ext = formato.extensao ?? "jpg"
                        var nome = base + "." + ext, n = 2
                        while jaUsados.contains(nome.lowercased()) || FileManager.default.fileExists(atPath: pasta.appendingPathComponent(nome).path) {
                            nome = "\(base) (\(n)).\(ext)"; n += 1
                        }
                        try ConversorImagem.converter(u, opcoes, destino: pasta.appendingPathComponent(nome))
                        return (nome, origem)
                    }.value
                    self.historico.atualizar(id) {
                        $0.retomada?.saidas?[k] = nome
                        var o = $0.origens ?? [:]; o[nome] = origem; $0.origens = o
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let msg = "\(u.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    self.historico.atualizar(id) {
                        $0.retomada?.saidas?[k] = ""          // "" = tentou e falhou
                        $0.retomada?.falhas?.append(msg)
                    }
                }
            }
            let fim = self.historico.item(id)?.retomada
            let nomes = (fim?.saidas ?? []).compactMap { $0 }.filter { !$0.isEmpty }
            let falhas = fim?.falhas ?? []
            if nomes.isEmpty { throw ErroApp(falhas.first ?? "Nenhuma imagem convertida.") }
            self.concluir(id, arquivos: nomes,
                          resumo: falhas.isEmpty ? nil : "Não converti \(falhas.count): " + falhas.joined(separator: "; "),
                          inicio: inicio)
        }
    }

    // --- links (baixados sempre pela nuvem)

    /// modo: "video" ou "audio"
    func baixarLink(_ info: InfoLink, modo: String, padrao: String = Renomear.padrao) {
        let personalizado = PadraoNome.personalizado(padrao)
        let base = PadraoNome.base(info.titulo, padrao: padrao, data: Date())
        let id = novoItem(modo == "video" ? .video : .audio, info.titulo, nuvem: true, mensagem: "Pedindo à nuvem",
                          base: personalizado ? base : nil)
        historico.atualizar(id) {
            $0.pedidoLink = PedidoLink(info: info, acao: modo == "video" ? .video : .audio, naNuvem: true, idioma: self.idioma, padrao: padrao)
        }
        let inicio = Date()
        rodar(id, segundoPlano: modo == "video" ? "Baixando vídeo pela nuvem" : "Baixando áudio pela nuvem") {
            let job = try await self.nuvem.iniciarLink(info.link, modo: modo, idioma: self.idioma, titulo: info.titulo)
            self.historico.atualizar(id) { $0.trabalho = job }
            let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
            guard let tid = r["id"] as? Int, let item = self.historico.item(id) else { throw ErroApp("Resposta incompleta da nuvem.") }
            var u = try await self.nuvem.baixar("api/transcripts/\(tid)/\(modo)", para: item.pasta,
                                                nomePadrao: base + (modo == "video" ? ".mp4" : ".m4a")) { p in
                Task { @MainActor in self.etapa(id, "Baixando para o iPhone", p) }
            }
            if personalizado { u = PadraoNome.renomear(u, base: base) }
            self.concluir(id, arquivos: [u.lastPathComponent], inicio: inicio, duracao: info.duracao)
        }
    }

    func transcreverLink(_ info: InfoLink, naNuvem: Bool, idioma: String, padrao: String = Renomear.padrao) {
        let base = PadraoNome.base(info.titulo, padrao: padrao, data: Date())
        let id = novoItem(.transcricao, info.titulo, nuvem: naNuvem, mensagem: "Pedindo à nuvem", base: base)
        historico.atualizar(id) {
            $0.pedidoLink = PedidoLink(info: info, acao: .transcrever, naNuvem: naNuvem, idioma: idioma, padrao: padrao)
        }
        let inicio = Date()
        rodar(id, segundoPlano: naNuvem ? "Transcrição na nuvem" : nil, recomecar: !naNuvem) {
            if naNuvem {
                let job = try await self.nuvem.iniciarLink(info.link, modo: "transcribe", idioma: idioma, titulo: info.titulo)
                self.historico.atualizar(id) { $0.trabalho = job }
                let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
                try await self.guardarTranscricaoDaNuvem(id, r, base: base, inicio: inicio)
            } else {
                // a nuvem baixa só o áudio; a transcrição roda no iPhone
                let job = try await self.nuvem.iniciarLink(info.link, modo: "audio", idioma: idioma, titulo: info.titulo)
                let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
                guard let tid = r["id"] as? Int else { throw ErroApp("Resposta incompleta da nuvem.") }
                let audio = try await self.nuvem.baixar("api/transcripts/\(tid)/audio", para: Self.pastaRecebidos,
                                                        nomePadrao: base + ".m4a") { p in
                    Task { @MainActor in self.etapa(id, "Baixando o áudio", p) }
                }
                defer { try? FileManager.default.removeItem(at: audio) }
                try await self.aguardarVez(id)
                let segs = try await TranscritorLocal.shared.transcrever(
                    audio, modelo: self.modeloLocal, idioma: idioma == "auto" ? nil : idioma
                ) { msg, p in Task { @MainActor in self.etapa(id, msg, p) } }
                try self.guardarTranscricao(id, segs, base: base, inicio: inicio, duracao: info.duracao)
            }
        }
    }

    // MARK: - ao abrir o app

    /// Trabalhos da nuvem continuam lá mesmo com o app fechado: retoma o
    /// acompanhamento. Os do iPhone foram interrompidos junto com o app.
    func retomar() {
        if VozLocal.neuralDerrubouOApp() {
            aviso = "A GPU fechou o app no último tratamento de voz e foi desligada (Ajustes › Tratar voz no iPhone). O tratamento volta a rodar no processador, com o mesmo resultado, só que mais devagar."
        }
        for i in historico.itens where i.estado == .processando && tarefas[i.id] == nil {
            if i.tipo == .legenda, i.reedicao != nil {
                // já transcrita; o app fechou enquanto gravava uma edição: o item volta ao normal
                historico.atualizar(i.id) { $0.estado = .pronto; $0.mensagem = nil; $0.progresso = nil }
                continue
            }
            if i.naNuvem, let job = i.trabalho {
                let id = i.id, inicio = i.criado, base = i.baseSaida ?? Self.base(i.titulo), tipo = i.tipo
                let personalizado = i.baseSaida != nil
                rodar(id) {
                    let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
                    switch tipo {
                    case .transcricao: try await self.guardarTranscricaoDaNuvem(id, r, base: base, inicio: inicio)
                    case .voz: try await self.guardarVozDaNuvem(id, r, inicio: inicio, base: personalizado ? base : nil)
                    case .imagem, .drive, .pastaDrive, .legenda: break   // nunca vão para a nuvem
                    case .video, .audio:
                        guard let tid = r["id"] as? Int, let item = self.historico.item(id) else { throw ErroApp("Resposta incompleta da nuvem.") }
                        let modo = tipo == .video ? "video" : "audio"
                        var u = try await self.nuvem.baixar("api/transcripts/\(tid)/\(modo)", para: item.pasta,
                                                            nomePadrao: base + (tipo == .video ? ".mp4" : ".m4a")) { p in
                            Task { @MainActor in self.etapa(id, "Baixando para o iPhone", p) }
                        }
                        if personalizado { u = PadraoNome.renomear(u, base: base) }
                        self.concluir(id, arquivos: [u.lastPathComponent], inicio: inicio)
                    }
                }
            } else if !i.naNuvem, i.retomada != nil, Trabalhos.existe(i.id) {
                historico.atualizar(i.id) {
                    $0.estado = .erro
                    $0.mensagem = "Interrompido: o app foi fechado. Toque em Continuar."
                    $0.progresso = nil
                }
                interrompidos.append(i.id)
            } else {
                historico.atualizar(i.id) {
                    $0.estado = .erro
                    $0.mensagem = i.naNuvem ? "Interrompido antes de chegar à nuvem — envie de novo."
                                            : "Interrompido: o app foi fechado durante o processamento."
                    $0.progresso = nil
                }
            }
        }
    }
}
