import Foundation
import Security

/// Cliente do whisper.frx9.com — "a nuvem" no app. Usa a mesma API do site
/// (login por cookie de sessão), então nada muda no servidor.
final class Nuvem: @unchecked Sendable {
    static let shared = Nuvem()
    static let base = URL(string: "https://whisper.frx9.com")!
    static let tamanhoPedaco = 32 * 1024 * 1024       // Cloudflare corta corpos > 100 MB

    private let sessao: URLSession

    init() {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = .shared
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 4 * 3600
        c.waitsForConnectivity = true
        sessao = URLSession(configuration: c)
    }

    // MARK: - login

    var usuario: String? { Credenciais.ler()?.usuario }

    func entrar(usuario: String, senha: String) async throws {
        var req = URLRequest(url: Self.base.appendingPathComponent("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["username": usuario, "password": senha])
        let (dados, resp) = try await sessao.data(for: req)
        try Self.conferir(dados, resp)
        Credenciais.salvar(usuario: usuario, senha: senha)
    }

    func sair() async {
        _ = try? await pedir("api/logout", metodo: "POST", json: [:], relogar: false)
        Credenciais.apagar()
        for c in HTTPCookieStorage.shared.cookies(for: Self.base) ?? [] {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
    }

    private func relogar() async throws {
        guard let c = Credenciais.ler() else { throw ErroApp("Entre com seu usuário da nuvem em Ajustes.") }
        try await entrar(usuario: c.usuario, senha: c.senha)
    }

    // MARK: - requisições

    /// Faz a requisição; se a sessão expirou (401), entra de novo e repete uma vez.
    @discardableResult
    func pedir(_ caminho: String, metodo: String = "GET", json: [String: Any]? = nil,
               corpo: Data? = nil, consulta: [String: String] = [:], relogar podeRelogar: Bool = true) async throws -> Data {
        var comp = URLComponents(url: Self.base.appendingPathComponent(caminho), resolvingAgainstBaseURL: false)!
        if !consulta.isEmpty { comp.queryItems = consulta.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comp.url!)
        req.httpMethod = metodo
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let corpo {
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = corpo
        }
        let (dados, resp) = try await sessao.data(for: req)
        if (resp as? HTTPURLResponse)?.statusCode == 401, podeRelogar {
            try await relogar()
            return try await pedir(caminho, metodo: metodo, json: json, corpo: corpo, consulta: consulta, relogar: false)
        }
        try Self.conferir(dados, resp)
        return dados
    }

    func objeto(_ caminho: String, metodo: String = "GET", json: [String: Any]? = nil) async throws -> [String: Any] {
        let d = try await pedir(caminho, metodo: metodo, json: json)
        return (try JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func lista(_ caminho: String) async throws -> [[String: Any]] {
        let d = try await pedir(caminho)
        return (try JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []
    }

    static func conferir(_ dados: Data, _ resp: URLResponse) throws {
        guard let h = resp as? HTTPURLResponse else { throw ErroApp("Resposta inválida da nuvem.") }
        guard (200..<300).contains(h.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with: dados) as? [String: Any]
            if let det = obj?["detail"] as? String { throw ErroApp(det.prefix(1).uppercased() + det.dropFirst()) }
            switch h.statusCode {
            case 401: throw ErroApp("Usuário ou senha da nuvem inválidos.")
            case 413: throw ErroApp("Arquivo grande demais para a nuvem.")
            case 502, 503, 504, 530: throw ErroApp("A nuvem não está respondendo agora (erro \(h.statusCode)).")
            default: throw ErroApp("A nuvem respondeu com erro \(h.statusCode).")
            }
        }
    }

    // MARK: - envio em pedaços

    /// Envia o arquivo em pedaços de 32 MB. Devolve o upload_id.
    func enviar(_ arquivo: URL, nome: String, progresso: @escaping @Sendable (Double) -> Void) async throws -> String {
        let ini = try await objeto("api/upload/init", metodo: "POST", json: ["filename": nome])
        guard let uid = ini["upload_id"] as? String else { throw ErroApp("A nuvem não aceitou o envio.") }
        let total = Double((try? FileManager.default.attributesOfItem(atPath: arquivo.path)[.size] as? NSNumber)?.int64Value ?? 1)
        let fh = try FileHandle(forReadingFrom: arquivo)
        defer { try? fh.close() }
        var enviado = 0.0
        while true {
            let pedaco = try fh.read(upToCount: Self.tamanhoPedaco) ?? Data()
            if pedaco.isEmpty { break }
            try await pedir("api/upload/chunk", metodo: "POST", corpo: pedaco, consulta: ["upload_id": uid])
            enviado += Double(pedaco.count)
            progresso(min(1, enviado / max(total, 1)))
        }
        return uid
    }

    // MARK: - trabalhos

    func iniciarTranscricao(uploadID: String, idioma: String) async throws -> String {
        let r = try await objeto("api/transcribe/start", metodo: "POST", json: ["upload_id": uploadID, "language": idioma])
        guard let j = r["job_id"] as? String else { throw ErroApp("A nuvem não iniciou a transcrição.") }
        return j
    }

    func iniciarVoz(uploadID: String, opcoes: OpcoesVoz) async throws -> String {
        var corpo: [String: Any] = ["upload_id": uploadID, "modo": opcoes.modo.rawValue,
                                    "eco": opcoes.eco, "clareza": opcoes.clareza]
        if opcoes.modo != .soVoz { corpo["voz_frente"] = opcoes.vozFrente }
        let r = try await objeto("api/voz/start", metodo: "POST", json: corpo)
        guard let j = r["job_id"] as? String else { throw ErroApp("A nuvem não iniciou o tratamento.") }
        return j
    }

    func identificar(link: String) async throws -> InfoLink {
        let r = try await objeto("api/link/probe", metodo: "POST", json: ["url": link])
        return InfoLink(titulo: r["title"] as? String ?? "(sem título)",
                        autor: r["uploader"] as? String ?? "",
                        site: r["site"] as? String ?? "",
                        duracao: r["duration"] as? Double,
                        link: (r["webpage_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? link)
    }

    /// modo: "video", "audio" ou "transcribe"
    func iniciarLink(_ link: String, modo: String, idioma: String, titulo: String) async throws -> String {
        let r = try await objeto("api/link/start", metodo: "POST",
                                 json: ["url": link, "mode": modo, "language": idioma, "title": titulo])
        guard let j = r["job_id"] as? String else { throw ErroApp("A nuvem não iniciou o download.") }
        return j
    }

    struct EstadoTrabalho {
        var status: String
        var motivo: String?
        var erro: String?
        var resultado: [String: Any]?

        var descricao: String {
            switch status {
            case "queued": return "Na fila da nuvem"
            case "downloading": return "Baixando na nuvem"
            case "processing": return "Processando na nuvem"
            case "waiting":
                return motivo == "offline" ? "Aguardando a nuvem ligar — continua sozinho"
                                           : "Aguardando liberação na nuvem"
            default: return status
            }
        }
    }

    func estado(_ job: String) async throws -> EstadoTrabalho {
        let r = try await objeto("api/jobs/\(job)")
        return EstadoTrabalho(status: r["status"] as? String ?? "?", motivo: r["reason"] as? String,
                              erro: r["error"] as? String, resultado: r["result"] as? [String: Any])
    }

    /// Acompanha o trabalho até terminar. Devolve o "result" do servidor.
    func aguardar(_ job: String, avisar: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        var falhas = 0
        while true {
            try Task.checkCancellation()
            do {
                let e = try await estado(job)
                falhas = 0
                switch e.status {
                case "done": return e.resultado ?? [:]
                case "error": throw ErroApp(e.erro ?? "A nuvem não conseguiu concluir.")
                default: avisar(e.descricao)
                }
            } catch let erro as ErroApp {
                throw erro
            } catch {
                falhas += 1                        // rede oscilando: tenta de novo
                if falhas > 20 { throw error }
                avisar("Sem conexão com a nuvem — tentando de novo")
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    // MARK: - downloads

    /// Baixa um arquivo da nuvem para `pasta`, com o nome sugerido pelo servidor.
    func baixar(_ caminho: String, para pasta: URL, nomePadrao: String,
                progresso: @escaping @Sendable (Double) -> Void, relogar podeRelogar: Bool = true) async throws -> URL {
        let req = URLRequest(url: Self.base.appendingPathComponent(caminho))
        let (tmp, resp) = try await baixarComProgresso(req, progresso: progresso)
        if resp.statusCode == 401, podeRelogar {
            try? FileManager.default.removeItem(at: tmp)
            try await relogar()
            return try await baixar(caminho, para: pasta, nomePadrao: nomePadrao, progresso: progresso, relogar: false)
        }
        if !(200..<300).contains(resp.statusCode) {
            let dados = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            try Self.conferir(dados, resp)
        }
        let nome = Self.nomeSugerido(resp) ?? nomePadrao
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let destino = Self.semColisao(pasta.appendingPathComponent(nome))
        try FileManager.default.moveItem(at: tmp, to: destino)
        return destino
    }

    private func baixarComProgresso(_ req: URLRequest, progresso: @escaping @Sendable (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        final class Caixinha: @unchecked Sendable { var obs: NSKeyValueObservation? }
        let caixa = Caixinha()
        return try await withCheckedThrowingContinuation { cont in
            let tarefa = sessao.downloadTask(with: req) { tmp, resp, erro in
                caixa.obs = nil
                if let erro { cont.resume(throwing: erro); return }
                guard let tmp, let h = resp as? HTTPURLResponse else {
                    cont.resume(throwing: ErroApp("Download interrompido.")); return
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do { try FileManager.default.moveItem(at: tmp, to: dest); cont.resume(returning: (dest, h)) }
                catch { cont.resume(throwing: error) }
            }
            caixa.obs = tarefa.progress.observe(\.fractionCompleted) { p, _ in progresso(p.fractionCompleted) }
            tarefa.resume()
        }
    }

    static func nomeSugerido(_ resp: HTTPURLResponse) -> String? {
        guard let cd = resp.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        // filename*=utf-8''nome%20x.mp4  ou  filename="nome.mp4"
        if let r = cd.range(of: "filename*=") {
            var v = String(cd[r.upperBound...]).components(separatedBy: ";")[0]
            if let aspas = v.range(of: "''") { v = String(v[aspas.upperBound...]) }
            if let dec = v.removingPercentEncoding, !dec.isEmpty { return limpar(dec) }
        }
        if let r = cd.range(of: "filename=") {
            let v = String(cd[r.upperBound...]).components(separatedBy: ";")[0]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !v.isEmpty { return limpar(v) }
        }
        return nil
    }

    static func limpar(_ nome: String) -> String {
        let proibidos = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let n = nome.components(separatedBy: proibidos).joined(separator: "_")
        return n.isEmpty ? "arquivo" : n
    }

    static func semColisao(_ url: URL) -> URL {
        var u = url, n = 1
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: u.path) {
            u = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            n += 1
        }
        return u
    }

    // MARK: - histórico da nuvem

    func transcricoes() async throws -> [[String: Any]] { try await lista("api/transcripts") }
    func tratamentosDeVoz() async throws -> [[String: Any]] { try await lista("api/voz") }
}

struct InfoLink: Codable, Equatable {
    var titulo: String
    var autor: String
    var site: String
    var duracao: Double?
    var link: String
}

struct OpcoesVoz: Codable, Equatable {
    enum Modo: String, Codable, CaseIterable, Identifiable {
        case fala, soVoz = "so_voz", musica
        var id: String { rawValue }
        var nome: String {
            switch self {
            case .fala: return "Fala com trilha"
            case .soVoz: return "Só voz"
            case .musica: return "Música"
            }
        }
    }
    var modo: Modo = .fala
    var eco = true
    var clareza = true
    var vozFrente = 3

    static func padrao(_ m: Modo) -> OpcoesVoz {
        switch m {
        case .fala: return OpcoesVoz(modo: .fala, eco: true, clareza: true, vozFrente: 3)
        case .soVoz: return OpcoesVoz(modo: .soVoz, eco: true, clareza: true, vozFrente: 0)
        case .musica: return OpcoesVoz(modo: .musica, eco: false, clareza: false, vozFrente: 0)
        }
    }
}

/// Usuário e senha da nuvem no Keychain (para renovar a sessão sozinho).
enum Credenciais {
    private static let servico = "com.gtm.estudio.nuvem"

    static func salvar(usuario: String, senha: String) {
        apagar()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: servico,
                                kSecAttrAccount as String: usuario,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                                kSecValueData as String: Data(senha.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func ler() -> (usuario: String, senha: String)? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: servico,
                                kSecReturnAttributes as String: true,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var r: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess,
              let item = r as? [String: Any],
              let conta = item[kSecAttrAccount as String] as? String,
              let dados = item[kSecValueData as String] as? Data,
              let senha = String(data: dados, encoding: .utf8) else { return nil }
        return (conta, senha)
    }

    static func apagar() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: servico]
        SecItemDelete(q as CFDictionary)
    }
}
