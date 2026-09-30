import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// O que chegou para ser processado (compartilhar, "Abrir com", colar link, escolher arquivo).
enum Entrada: Identifiable, Equatable {
    case link(String)
    case arquivo(URL, nome: String)
    case imagens([URL])

    var id: String {
        switch self {
        case .link(let l): return "link:" + l
        case .arquivo(let u, _): return "arq:" + u.path
        case .imagens(let us): return "img:\(us.count):" + (us.first?.path ?? "")
        }
    }
}

/// Arquivo de imagem? (pela extensão; HEIC, JPG, PNG, WebP, AVIF, TIFF…)
func ehImagem(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
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
        for r in Caixa.pendentes() {
            switch r.tipo {
            case .link:
                if let l = r.link { receber(.link(l)) }
            case .arquivo:
                if let origem = Caixa.url(doArquivo: r) {
                    let destino = Nuvem.semColisao(Self.pastaRecebidos.appendingPathComponent(r.nome))
                    if (try? FileManager.default.moveItem(at: origem, to: destino)) != nil {
                        if ehImagem(destino) { imagens.append(destino) }      // várias fotos viram um lote só
                        else { receber(.arquivo(destino, nome: r.nome)) }
                    }
                }
            }
            Caixa.remover(r)
        }
        if !imagens.isEmpty { receber(.imagens(imagens)) }
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
            receber(.arquivo(destino, nome: n))
        } catch {
            aviso = "Não consegui abrir o arquivo: \(error.localizedDescription)"
        }
    }

    /// Vários arquivos de uma vez (Arquivos ou Galeria): as imagens viram um lote só.
    func importarVarios(_ urls: [URL]) {
        var imagens: [URL] = []
        for u in urls {
            let acesso = u.startAccessingSecurityScopedResource()
            defer { if acesso { u.stopAccessingSecurityScopedResource() } }
            let destino = Nuvem.semColisao(Self.pastaRecebidos.appendingPathComponent(u.lastPathComponent))
            do {
                try FileManager.default.copyItem(at: u, to: destino)
                if ehImagem(destino) { imagens.append(destino) } else { receber(.arquivo(destino, nome: u.lastPathComponent)) }
            } catch {
                aviso = "Não consegui abrir \(u.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if !imagens.isEmpty { receber(.imagens(imagens)) }
    }

    var aviso: String?

    // MARK: - trabalhos

    private static func base(_ nome: String) -> String {
        let b = (nome as NSString).deletingPathExtension
        return Nuvem.limpar(b.isEmpty ? "arquivo" : b)
    }

    private func novoItem(_ tipo: Item.Tipo, _ titulo: String, nuvem: Bool, mensagem: String) -> UUID {
        var i = Item(tipo: tipo, titulo: titulo, naNuvem: nuvem)
        i.mensagem = mensagem
        historico.adicionar(i)
        abaSelecionada = 1
        return i.id
    }

    private func etapa(_ id: UUID, _ msg: String, _ p: Double? = nil) {
        historico.atualizar(id, salvarAgora: false) { $0.mensagem = msg; $0.progresso = p }
    }

    private func concluir(_ id: UUID, arquivos: [String], resumo: String? = nil, inicio: Date, duracao: Double? = nil) {
        historico.atualizar(id) {
            $0.estado = .pronto; $0.mensagem = nil; $0.progresso = nil
            $0.arquivos = arquivos; $0.resumo = resumo; $0.trabalho = nil
            $0.duracaoProcesso = Date().timeIntervalSince(inicio)
            if let duracao { $0.duracaoAudio = duracao }
        }
        atualizarTela()
    }

    private func falhar(_ id: UUID, _ erro: Error) {
        let msg = (erro as? LocalizedError)?.errorDescription ?? erro.localizedDescription
        historico.atualizar(id) { $0.estado = .erro; $0.mensagem = msg; $0.progresso = nil }
        atualizarTela()
    }

    private func rodar(_ id: UUID, _ corpo: @escaping @MainActor () async throws -> Void) {
        tarefas[id] = Task { @MainActor in
            do { try await corpo() }
            catch is CancellationError { self.historico.atualizar(id) { $0.estado = .erro; $0.mensagem = "Cancelado" } }
            catch { self.falhar(id, error) }
            self.tarefas[id] = nil
            self.atualizarTela()
        }
        atualizarTela()
    }

    func cancelar(_ id: UUID) { tarefas[id]?.cancel() }
    func rodando(_ id: UUID) -> Bool { tarefas[id] != nil }

    /// Tela sempre acesa enquanto houver trabalho no iPhone (o iOS pausa apps em segundo plano).
    private func atualizarTela() {
        let local = historico.itens.contains { !$0.naNuvem && $0.estado == .processando && tarefas[$0.id] != nil }
        UIApplication.shared.isIdleTimerDisabled = local
    }

    // --- transcrição

    func transcrever(_ arquivo: URL, nome: String, naNuvem: Bool, idioma: String) {
        let id = novoItem(.transcricao, nome, nuvem: naNuvem, mensagem: naNuvem ? "Enviando para a nuvem" : "Preparando")
        let inicio = Date()
        rodar(id) {
            let base = Self.base(nome)
            if naNuvem {
                let uid = try await self.nuvem.enviar(arquivo, nome: nome) { p in
                    Task { @MainActor in self.etapa(id, "Enviando para a nuvem", p) }
                }
                let job = try await self.nuvem.iniciarTranscricao(uploadID: uid, idioma: idioma)
                self.historico.atualizar(id) { $0.trabalho = job }
                let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
                try await self.guardarTranscricaoDaNuvem(id, r, base: base, inicio: inicio)
            } else {
                let segs = try await TranscritorLocal.shared.transcrever(
                    arquivo, modelo: self.modeloLocal, idioma: idioma == "auto" ? nil : idioma
                ) { msg, p in Task { @MainActor in self.etapa(id, msg, p) } }
                let dur = await AudioUtil.duracao(arquivo)
                try self.guardarTranscricao(id, segs, base: base, inicio: inicio, duracao: dur)
            }
            try? FileManager.default.removeItem(at: arquivo)
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

    func tratarVoz(_ arquivo: URL, nome: String, opcoes: OpcoesVoz, quadra: Bool, naNuvem: Bool) {
        let id = novoItem(.voz, nome, nuvem: naNuvem, mensagem: naNuvem ? "Enviando para a nuvem" : "Preparando")
        let inicio = Date()
        if !naNuvem {
            rodar(id) {
                guard let item = self.historico.item(id) else { return }
                let r = try await VozLocal.tratar(arquivo, opcoes: OpcoesVozLocal(voz: opcoes, quadra: quadra),
                                                  pasta: item.pasta, base: Self.base(nome)) { msg, p in
                    Task { @MainActor in self.etapa(id, msg, p) }
                }
                self.concluir(id, arquivos: r.arquivos, inicio: inicio, duracao: r.duracao)
                try? FileManager.default.removeItem(at: arquivo)
            }
            return
        }
        rodar(id) {
            let uid = try await self.nuvem.enviar(arquivo, nome: nome) { p in
                Task { @MainActor in self.etapa(id, "Enviando para a nuvem", p) }
            }
            let job = try await self.nuvem.iniciarVoz(uploadID: uid, opcoes: opcoes)
            self.historico.atualizar(id) { $0.trabalho = job }
            let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
            try await self.guardarVozDaNuvem(id, r, inicio: inicio)
            try? FileManager.default.removeItem(at: arquivo)
        }
    }

    private func guardarVozDaNuvem(_ id: UUID, _ r: [String: Any], inicio: Date) async throws {
        guard let item = historico.item(id), let vid = r["id"] as? Int else { throw ErroApp("Resposta incompleta da nuvem.") }
        let tipos = (r["arquivos"] as? [String]) ?? ["mix", "voz", "trilha"]
        var nomes: [String] = []
        for (k, t) in tipos.enumerated() {
            let u = try await nuvem.baixar("api/voz/\(vid)/\(t)", para: item.pasta, nomePadrao: "\(t).mp3") { p in
                Task { @MainActor in self.etapa(id, "Baixando o resultado (\(k + 1) de \(tipos.count))", p) }
            }
            nomes.append(u.lastPathComponent)
        }
        concluir(id, arquivos: nomes, inicio: inicio, duracao: r["audio_secs"] as? Double)
    }

    // --- conversão (no iPhone)

    func converter(_ arquivo: URL, nome: String, info: InfoMidia, opcoes: OpcoesConversao) {
        let tipo: Item.Tipo = opcoes.acao == .audio || !info.temVideo ? .audio : .video
        let id = novoItem(tipo, nome, nuvem: false, mensagem: "Convertendo no iPhone")
        let inicio = Date()
        rodar(id) {
            guard let item = self.historico.item(id) else { return }
            let saida = try await ConversorVideo.converter(arquivo, info: info, opcoes: opcoes, pasta: item.pasta,
                                                           base: Self.base(nome)) { p in
                Task { @MainActor in self.etapa(id, "Convertendo no iPhone", p) }
            }
            self.concluir(id, arquivos: [saida.lastPathComponent], inicio: inicio,
                          duracao: PlanoConversao.duracao(info, opcoes))
            try? FileManager.default.removeItem(at: arquivo)
        }
    }

    // --- imagens (no iPhone)

    func converterImagens(_ arquivos: [URL], opcoes: OpcoesImagem) {
        let titulo = arquivos.count == 1 ? arquivos[0].lastPathComponent : "\(arquivos.count) imagens"
        let id = novoItem(.imagem, titulo, nuvem: false, mensagem: "Convertendo no iPhone")
        let inicio = Date()
        rodar(id) {
            guard let item = self.historico.item(id) else { return }
            try FileManager.default.createDirectory(at: item.pasta, withIntermediateDirectories: true)
            var nomes: [String] = []
            var usados = Set<String>()
            var falhas: [String] = []
            for (k, u) in arquivos.enumerated() {
                try Task.checkCancellation()
                self.etapa(id, "Convertendo \(k + 1) de \(arquivos.count)", Double(k) / Double(arquivos.count))
                let pasta = item.pasta
                let jaUsados = usados
                do {
                    let nome: String = try await Task.detached(priority: .userInitiated) {
                        guard let info = ConversorImagem.info(u) else { throw ErroApp("não é uma imagem que o iPhone lê") }
                        let formato = ConversorImagem.formatoFinal(opcoes, tipoOriginal: info.tipo)
                        let (l, a) = GeometriaImagem.tamanhoFinal(info.largura, info.altura, opcoes)
                        let base = Renomear.aplicar(opcoes.padraoNome, nome: (u.lastPathComponent as NSString).deletingPathExtension,
                                                    indice: k + 1, largura: l, altura: a, data: info.data, digitos: opcoes.digitosContador)
                        let ext = formato.extensao ?? "jpg"
                        var nome = base + "." + ext, n = 2
                        while jaUsados.contains(nome.lowercased()) || FileManager.default.fileExists(atPath: pasta.appendingPathComponent(nome).path) {
                            nome = "\(base) (\(n)).\(ext)"; n += 1
                        }
                        try ConversorImagem.converter(u, opcoes, destino: pasta.appendingPathComponent(nome))
                        return nome
                    }.value
                    usados.insert(nome.lowercased())
                    nomes.append(nome)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    falhas.append("\(u.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
            }
            if nomes.isEmpty { throw ErroApp(falhas.first ?? "Nenhuma imagem convertida.") }
            self.concluir(id, arquivos: nomes,
                          resumo: falhas.isEmpty ? nil : "Não converti \(falhas.count): " + falhas.joined(separator: "; "),
                          inicio: inicio)
            arquivos.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    // --- links (baixados sempre pela nuvem)

    /// modo: "video" ou "audio"
    func baixarLink(_ info: InfoLink, modo: String) {
        let id = novoItem(modo == "video" ? .video : .audio, info.titulo, nuvem: true, mensagem: "Pedindo à nuvem")
        let inicio = Date()
        rodar(id) {
            let job = try await self.nuvem.iniciarLink(info.link, modo: modo, idioma: self.idioma, titulo: info.titulo)
            self.historico.atualizar(id) { $0.trabalho = job }
            let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
            guard let tid = r["id"] as? Int, let item = self.historico.item(id) else { throw ErroApp("Resposta incompleta da nuvem.") }
            let u = try await self.nuvem.baixar("api/transcripts/\(tid)/\(modo)", para: item.pasta,
                                                nomePadrao: Self.base(info.titulo) + (modo == "video" ? ".mp4" : ".m4a")) { p in
                Task { @MainActor in self.etapa(id, "Baixando para o iPhone", p) }
            }
            self.concluir(id, arquivos: [u.lastPathComponent], inicio: inicio, duracao: info.duracao)
        }
    }

    func transcreverLink(_ info: InfoLink, naNuvem: Bool, idioma: String) {
        let id = novoItem(.transcricao, info.titulo, nuvem: naNuvem, mensagem: "Pedindo à nuvem")
        let inicio = Date()
        let base = Self.base(info.titulo)
        rodar(id) {
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
            if i.naNuvem, let job = i.trabalho {
                let id = i.id, inicio = i.criado, base = Self.base(i.titulo), tipo = i.tipo
                rodar(id) {
                    let r = try await self.nuvem.aguardar(job) { m in Task { @MainActor in self.etapa(id, m) } }
                    switch tipo {
                    case .transcricao: try await self.guardarTranscricaoDaNuvem(id, r, base: base, inicio: inicio)
                    case .voz: try await self.guardarVozDaNuvem(id, r, inicio: inicio)
                    case .imagem: break           // imagens nunca vão para a nuvem
                    case .video, .audio:
                        guard let tid = r["id"] as? Int, let item = self.historico.item(id) else { throw ErroApp("Resposta incompleta da nuvem.") }
                        let modo = tipo == .video ? "video" : "audio"
                        let u = try await self.nuvem.baixar("api/transcripts/\(tid)/\(modo)", para: item.pasta,
                                                            nomePadrao: base + (tipo == .video ? ".mp4" : ".m4a")) { p in
                            Task { @MainActor in self.etapa(id, "Baixando para o iPhone", p) }
                        }
                        self.concluir(id, arquivos: [u.lastPathComponent], inicio: inicio)
                    }
                }
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
